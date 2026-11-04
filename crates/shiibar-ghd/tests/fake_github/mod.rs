//! A fake GitHub for the black-box tests: a minimal HTTP/1.1 server on the
//! loopback interface, built on tokio's TcpListener (docs/tasks/M2.md, "How
//! to test"). It answers REST and GraphQL from a small world the test edits,
//! records every request, and lets a test override any answer.
#![allow(dead_code)]

use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

/// 2027-01-15T08:00:00Z, the tests' `T0`.
const T0: i64 = 1_800_000_000;

pub fn iso(at: i64) -> String {
    jiff::Timestamp::from_second(at)
        .unwrap()
        .strftime("%Y-%m-%dT%H:%M:%SZ")
        .to_string()
}

#[derive(Debug, Clone)]
pub struct Req {
    pub method: String,
    pub path: String,
    pub headers: BTreeMap<String, String>,
    pub body: Value,
    /// The token of the `Authorization` header.
    pub token: String,
    /// The GraphQL operation name.
    pub op: Option<String>,
}

impl Req {
    pub fn vars(&self) -> &Value {
        &self.body["variables"]
    }

    pub fn query(&self) -> &str {
        self.body["query"].as_str().unwrap_or_default()
    }
}

#[derive(Debug, Clone)]
pub struct Resp {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl Resp {
    pub fn json(status: u16, body: Value) -> Self {
        Self {
            status,
            headers: vec![],
            body: body.to_string(),
        }
    }

    pub fn header(mut self, name: &str, value: impl Into<String>) -> Self {
        self.headers.push((name.to_string(), value.into()));
        self
    }
}

type Override = Box<dyn Fn(&Req) -> Option<Resp> + Send>;

#[derive(Default)]
pub struct World {
    /// Token to the login it belongs to.
    pub logins: BTreeMap<String, String>,
    pub unauthorized: BTreeSet<String>,
    /// Owner login (lowercase) to `Organization` or `User`.
    pub owners: BTreeMap<String, String>,
    /// PR status nodes.
    pub prs: Vec<Value>,
    pub timeline: BTreeMap<String, Vec<Value>>,
    pub threads: BTreeMap<String, Vec<Value>>,
    /// The viewer's teams in an organization: the first page, then the next.
    pub teams: Vec<Value>,
    pub more_teams: Vec<Value>,
    /// Reactable id to its node.
    pub reactables: BTreeMap<String, Value>,
    pub notifications: Vec<Value>,
    pub last_modified: String,
    pub poll_interval: i64,
    /// Extra headers on every answer, such as the token expiry.
    pub extra_headers: Vec<(String, String)>,
    pub requests: Vec<Req>,
    overrides: Vec<Override>,
}

pub struct FakeGitHub {
    pub url: String,
    world: Arc<Mutex<World>>,
}

impl FakeGitHub {
    pub fn start() -> Self {
        let world = Arc::new(Mutex::new(World {
            last_modified: "Fri, 15 Jan 2027 08:00:00 GMT".into(),
            poll_interval: 60,
            ..World::default()
        }));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let shared = world.clone();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async move {
                let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                loop {
                    let Ok((stream, _)) = listener.accept().await else {
                        continue;
                    };
                    let world = shared.clone();
                    tokio::spawn(async move {
                        let _ = serve(stream, world).await;
                    });
                }
            });
        });
        Self { url, world }
    }

    pub fn with<T>(&self, f: impl FnOnce(&mut World) -> T) -> T {
        f(&mut self.world.lock().unwrap())
    }

    pub fn requests(&self) -> Vec<Req> {
        self.with(|w| w.requests.clone())
    }

    pub fn clear_requests(&self) {
        self.with(|w| w.requests.clear());
    }

    /// Answers this override gives win over the world's.
    pub fn intercept(&self, f: impl Fn(&Req) -> Option<Resp> + Send + 'static) {
        self.with(|w| w.overrides.push(Box::new(f)));
    }

    pub fn clear_overrides(&self) {
        self.with(|w| w.overrides.clear());
    }

    /// Requests made with this token.
    pub fn by_token(&self, token: &str) -> Vec<Req> {
        self.requests()
            .into_iter()
            .filter(|r| r.token == token)
            .collect()
    }

    pub fn ops(&self) -> Vec<String> {
        self.requests()
            .into_iter()
            .map(|r| r.op.unwrap_or_else(|| format!("{} {}", r.method, r.path)))
            .collect()
    }
}

async fn serve(stream: tokio::net::TcpStream, world: Arc<Mutex<World>>) -> std::io::Result<()> {
    let (read, mut write) = stream.into_split();
    let mut reader = BufReader::new(read);
    let mut line = String::new();
    reader.read_line(&mut line).await?;
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_string();
    let path = parts.next().unwrap_or_default().to_string();
    let mut headers = BTreeMap::new();
    loop {
        let mut header = String::new();
        reader.read_line(&mut header).await?;
        let header = header.trim_end();
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':') {
            headers.insert(name.trim().to_lowercase(), value.trim().to_string());
        }
    }
    let length: usize = headers
        .get("content-length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let mut body = vec![0; length];
    reader.read_exact(&mut body).await?;
    let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let token = headers
        .get("authorization")
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or_default()
        .to_string();
    let op = body["query"].as_str().and_then(operation);
    let req = Req {
        method,
        path,
        headers,
        body,
        token,
        op,
    };
    let resp = {
        let mut world = world.lock().unwrap();
        world.requests.push(req.clone());
        let mut resp = world
            .overrides
            .iter()
            .find_map(|f| f(&req))
            .unwrap_or_else(|| answer(&world, &req));
        resp.headers.extend(world.extra_headers.clone());
        resp
    };
    let mut text = format!("HTTP/1.1 {} X\r\n", resp.status);
    let mut has_type = false;
    for (name, value) in &resp.headers {
        has_type |= name.eq_ignore_ascii_case("content-type");
        text.push_str(&format!("{name}: {value}\r\n"));
    }
    if !has_type {
        text.push_str("Content-Type: application/json\r\n");
    }
    text.push_str(&format!(
        "Content-Length: {}\r\nConnection: close\r\n\r\n{}",
        resp.body.len(),
        resp.body
    ));
    write.write_all(text.as_bytes()).await?;
    write.shutdown().await
}

/// `Name` from `query Name(...) {` or `query Name {`.
fn operation(query: &str) -> Option<String> {
    let rest = query.trim_start().strip_prefix("query ")?;
    let end = rest.find(['(', ' ', '{']).unwrap_or(rest.len());
    Some(rest[..end].to_string())
}

fn rate() -> Value {
    json!({"cost":1,"limit":5000,"remaining":4999,"resetAt":iso(T0 + 3600)})
}

fn gql(data: Value) -> Resp {
    let mut data = data;
    data["rateLimit"] = rate();
    Resp::json(200, json!({ "data": data }))
        .header("x-ratelimit-resource", "graphql")
        .header("x-ratelimit-remaining", "4999")
        .header("x-ratelimit-limit", "5000")
}

fn rest(body: Value) -> Resp {
    Resp::json(200, body)
        .header("x-ratelimit-resource", "core")
        .header("x-ratelimit-remaining", "4990")
        .header("x-ratelimit-limit", "5000")
}

fn pr_by_id<'a>(world: &'a World, id: &str) -> Option<&'a Value> {
    world.prs.iter().find(|p| p["id"] == id)
}

fn search(world: &World, query: &str) -> Value {
    let words: Vec<&str> = query.split_whitespace().collect();
    let public = words.contains(&"is:public");
    let owner = words
        .iter()
        .find_map(|w| w.strip_prefix("org:").or_else(|| w.strip_prefix("user:")))
        .map(str::to_lowercase);
    let nodes: Vec<Value> = world
        .prs
        .iter()
        .filter(|p| p["state"] == "OPEN")
        .filter(|p| {
            let login = p["repository"]["owner"]["login"].as_str().unwrap_or_default();
            match &owner {
                Some(owner) => login.to_lowercase() == *owner,
                None => !public || p["repository"]["isPrivate"] == false,
            }
        })
        .map(|p| json!({"id":p["id"],"repository":{"owner":{"login":p["repository"]["owner"]["login"]}}}))
        .collect();
    json!({"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":nodes})
}

fn threads(world: &World, id: &str) -> Value {
    let list: Vec<Value> = world
        .threads
        .get(id)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|t| {
            json!({"id":t["id"],"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":t["comments"]}})
        })
        .collect();
    json!({"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":list})
}

fn event_node(world: &World, id: &str) -> Value {
    let Some(pr) = pr_by_id(world, id) else {
        return Value::Null;
    };
    json!({
        "id":id,"url":pr["url"],"createdAt":pr["createdAt"],"bodyHTML":pr["bodyHTML"],
        "bodyText":pr["bodyText"],"author":pr["author"],
        "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},
                         "nodes":world.timeline.get(id).cloned().unwrap_or_default()},
        "reviewThreads":threads(world, id)
    })
}

fn not_found(index: usize) -> Value {
    json!({"type":"NOT_FOUND","path":["nodes",index],"message":"Could not resolve to a node"})
}

/// The world's answer to a request.
fn answer(world: &World, req: &Req) -> Resp {
    if world.unauthorized.contains(&req.token) {
        return Resp::json(401, json!({"message":"Bad credentials"}));
    }
    let login = world.logins.get(&req.token).cloned().unwrap_or_default();
    if req.method == "POST" && req.path == "/graphql" {
        let vars = req.vars();
        let ids: Vec<String> = vars["ids"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect();
        let nodes_of = |make: &dyn Fn(&str) -> Value| {
            let mut errors = vec![];
            let nodes: Vec<Value> = ids
                .iter()
                .enumerate()
                .map(|(i, id)| {
                    let node = make(id);
                    if node.is_null() {
                        errors.push(not_found(i));
                    }
                    node
                })
                .collect();
            (nodes, errors)
        };
        let with_errors = |data: Value, errors: Vec<Value>| {
            let mut resp = gql(data);
            if !errors.is_empty() {
                let mut body: Value = serde_json::from_str(&resp.body).unwrap();
                body["errors"] = json!(errors);
                resp.body = body.to_string();
            }
            resp
        };
        return match req.op.as_deref().unwrap_or_default() {
            "Viewer" | "Who" => gql(json!({"viewer":{"login":login}})),
            "MergeQueue" => {
                let id = vars["id"].as_str().unwrap_or_default();
                let queue: Vec<Value> = world
                    .timeline
                    .get(id)
                    .into_iter()
                    .flatten()
                    .filter(|e| {
                        matches!(
                            e["__typename"].as_str(),
                            Some("AddedToMergeQueueEvent" | "RemovedFromMergeQueueEvent")
                        )
                    })
                    .cloned()
                    .collect();
                gql(json!({"node":{"timelineItems":{"nodes":queue}}}))
            }
            "TeamsPage" => gql(json!({"org":{"teams":{
                "pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":world.more_teams}}})),
            "Owner" => {
                let owner = vars["owner"].as_str().unwrap_or_default();
                let kind = world.owners.get(&owner.to_lowercase());
                gql(json!({"owner": kind.map(|k| json!({"__typename":k,"login":owner}))}))
            }
            "Scope" => {
                let mut data = json!({"viewer":{"login":login}});
                if let Some(owner) = vars["owner"].as_str() {
                    let kind = world.owners.get(&owner.to_lowercase());
                    data["owner"] = json!(kind.map(|k| json!({"__typename":k,"login":owner})));
                    data["org"] = json!({"teams":{
                        "pageInfo":{"hasNextPage":!world.more_teams.is_empty(),"endCursor":"c1"},
                        "nodes":world.teams}});
                }
                for i in 0..4 {
                    let query = vars[format!("q{i}")].as_str().unwrap_or_default();
                    data[format!("s{i}")] = if i == 0 {
                        search(world, query)
                    } else {
                        json!({"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]})
                    };
                }
                gql(data)
            }
            "Status" => {
                let (nodes, errors) =
                    nodes_of(&|id| pr_by_id(world, id).cloned().unwrap_or(Value::Null));
                with_errors(json!({"nodes":nodes}), errors)
            }
            "Compare" => {
                let mut data = json!({});
                for i in 0..100 {
                    if vars.get(format!("i{i}")).is_some() {
                        data[format!("c{i}")] = json!({"baseRef":{"compare":{"behindBy":0}}});
                    }
                }
                gql(data)
            }
            "Resolve" => {
                let mut data = json!({});
                for i in 0..100 {
                    let Some(owner) = vars[format!("o{i}")].as_str() else {
                        continue;
                    };
                    let repo = vars[format!("r{i}")].as_str().unwrap_or_default();
                    let number = vars[format!("n{i}")].as_i64().unwrap_or_default();
                    let found = world.prs.iter().find(|p| {
                        p["repository"]["owner"]["login"]
                            .as_str()
                            .unwrap_or_default()
                            .eq_ignore_ascii_case(owner)
                            && p["repository"]["name"]
                                .as_str()
                                .unwrap_or_default()
                                .eq_ignore_ascii_case(repo)
                            && p["number"] == number
                    });
                    data[format!("p{i}")] = match found {
                        Some(pr) => json!({"pullRequest":{"id":pr["id"]}}),
                        None => Value::Null,
                    };
                }
                gql(data)
            }
            "Events" => {
                let (nodes, errors) = nodes_of(&|id| event_node(world, id));
                with_errors(json!({"nodes":nodes}), errors)
            }
            "Collect" => {
                let id = vars["id"].as_str().unwrap_or_default();
                let Some(pr) = pr_by_id(world, id) else {
                    return gql(json!({"node":null}));
                };
                let requests: Vec<Value> = world
                    .timeline
                    .get(id)
                    .into_iter()
                    .flatten()
                    .filter(|e| e["__typename"] == "ReviewRequestedEvent")
                    .cloned()
                    .collect();
                let empty = json!({"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]});
                gql(json!({"node":{
                    "id":id,"url":pr["url"],"createdAt":pr["createdAt"],"bodyHTML":pr["bodyHTML"],
                    "bodyText":pr["bodyText"],"author":pr["author"],
                    "comments":empty,"reviews":empty,"reviewThreads":threads(world, id),
                    "reviewRequests":pr["reviewRequests"],"requestEvents":{"nodes":requests}
                }}))
            }
            "Reactions" => {
                let (nodes, errors) =
                    nodes_of(&|id| world.reactables.get(id).cloned().unwrap_or(Value::Null));
                with_errors(json!({"nodes":nodes}), errors)
            }
            "Contexts" | "Requests" => {
                let (nodes, _) = nodes_of(&|id| {
                    json!({"id":id,"statusCheckRollup":null,
                    "reviewRequests":{"nodes":[]},"requestEvents":{"nodes":[]}})
                });
                gql(json!({"nodes":nodes}))
            }
            "Probe" => gql(json!({
                "viewer":{"login":login,"repositories":{"nodes":[]}},
                "owner":{"__typename":"Organization","login":vars["owner"],
                         "repositories":{"nodes":[{"name":"app","owner":{"login":vars["owner"]},
                         "defaultBranchRef":{"name":"main","target":{"oid":"abc"}}}]}},
                "involved":{"nodes":[]}
            })),
            "Pulls" => gql(json!({"repository":{"pullRequests":{"nodes":[]}}})),
            "Behind" => gql(json!({"repository":{"defaultBranchRef":{"compare":{"behindBy":0}}}})),
            "Queue" => gql(json!({"repository":{"mergeQueue":null}})),
            "Teams" => gql(json!({"organization":{"teams":{"totalCount":0}}})),
            _ => gql(json!({})),
        };
    }
    let path = req.path.split('?').next().unwrap_or_default();
    match path {
        "/notifications" => {
            let unchanged = req.headers.get("if-modified-since") == Some(&world.last_modified);
            let resp = if unchanged {
                Resp::json(304, json!(null))
            } else {
                rest(json!(world.notifications))
                    .header("Last-Modified", world.last_modified.clone())
            };
            resp.header("X-Poll-Interval", world.poll_interval.to_string())
        }
        "/user" => rest(json!({"login":login})).header("X-OAuth-Scopes", "notifications, read:org"),
        "/user/teams" => rest(json!([])),
        p if p.ends_with("/jobs") => rest(json!({"jobs":[]})),
        p if p.ends_with("/actions/runs") => rest(json!({"workflow_runs":[]})),
        p if p.ends_with("/status") => rest(json!({"state":"success"})),
        _ => Resp::json(404, json!({"message":"Not Found"})),
    }
}

/// A PR status node with every field the status query asks for.
pub fn pr_node(id: &str, owner: &str, number: u64, author: &str, patch: Value) -> Value {
    let mut node = json!({
        "id":id,"number":number,"url":format!("https://github.com/{owner}/app/pull/{number}"),
        "title":format!("Title {id}"),"state":"OPEN","isDraft":false,"updatedAt":iso(T0),
        "createdAt":iso(T0 - 86_400),"isCrossRepository":false,
        "author":{"__typename":"User","login":author},
        "repository":{"name":"app","isPrivate":false,"owner":{"login":owner}},
        "baseRefName":"main","headRefName":"topic","headRefOid":"abc",
        "reviewDecision":null,"latestOpinionatedReviews":{"nodes":[]},
        "statusCheckRollup":null,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED",
        "reviewRequests":{"nodes":[]},"bodyHTML":"","bodyText":""
    });
    for (key, value) in patch.as_object().unwrap() {
        node[key] = value.clone();
    }
    node
}

pub fn issue_comment(id: &str, author: &str, at: i64, html: &str) -> Value {
    json!({"__typename":"IssueComment","id":id,"url":format!("https://github.com/c/{id}"),
           "createdAt":iso(at),"bodyText":format!("text {id}"),"bodyHTML":html,
           "author":{"__typename":"User","login":author}})
}

pub fn mention_link(login: &str) -> String {
    format!(
        "<a class=\"user-mention notranslate\" href=\"https://github.com/{login}\">@{login}</a>"
    )
}
