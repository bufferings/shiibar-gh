//! `token_test`: whether a token has each permission, one question per item.
//! The data itself does not matter: an answer without a permission error is
//! OK, a permission error is Failed with the permission's name, and nothing
//! to ask about is Unverifiable. docs/tasks/M2.md, "Token test procedure".

use crate::fetch::{encode, owner_kind};
use crate::github::{Api, CallError, Gql, Recorder};
use crate::model::{NOTIFICATIONS, PUBLIC, ScopeKind};
use serde_json::{Value, json};
use shiibar_gh_proto::{Lenient, TestOutcome, TestResult};

pub const PRS: &str = "PRs, reviews, comments";
pub const CHECKS: &str = "Checks";
pub const BEHIND: &str = "Behind base";
pub const TEAMS: &str = "Team membership";
pub const MERGE_QUEUE: &str = "Merge queue";
pub const NOTIFICATIONS_ITEM: &str = "Notifications";
pub const SCOPES: &str = "Scopes";

/// What the test of one token found.
#[derive(Debug, Default)]
pub struct Report {
    pub results: Vec<TestResult>,
    pub owner: Option<String>,
    pub kind: Option<ScopeKind>,
    pub name: Option<String>,
}

fn result(
    item: &str,
    outcome: TestOutcome,
    missing: Option<&str>,
    reason: Option<&str>,
) -> TestResult {
    TestResult {
        item: item.to_string(),
        outcome: Lenient::Known(outcome),
        missing: missing.map(str::to_string),
        reason: reason.map(str::to_string),
    }
}

fn ok(item: &str) -> TestResult {
    result(item, TestOutcome::Ok, None, None)
}

fn unverifiable(item: &str, reason: &str) -> TestResult {
    result(item, TestOutcome::Unverifiable, None, Some(reason))
}

fn failed(item: &str, missing: &str) -> TestResult {
    result(
        item,
        TestOutcome::Failed,
        Some(missing),
        Some("permission error"),
    )
}

/// One item from a GraphQL answer: a permission error anywhere fails it.
fn judge_gql(
    item: &str,
    missing: &str,
    answer: Result<Gql, CallError>,
) -> Result<TestResult, CallError> {
    match answer {
        Ok(answer) if answer.errors.iter().any(|e| e.is_permission()) => Ok(failed(item, missing)),
        Ok(_) | Err(CallError::NotFound) => Ok(ok(item)),
        Err(CallError::Forbidden { .. }) => Ok(failed(item, missing)),
        Err(e) => Err(e),
    }
}

/// The repository the scope items ask about.
struct Probe {
    owner: String,
    name: String,
    branch: Option<String>,
    oid: Option<String>,
}

fn probe_of(repo: &Value) -> Option<Probe> {
    Some(Probe {
        owner: repo["owner"]["login"].as_str()?.to_string(),
        name: repo["name"].as_str()?.to_string(),
        branch: repo["defaultBranchRef"]["name"]
            .as_str()
            .map(str::to_string),
        oid: repo["defaultBranchRef"]["target"]["oid"]
            .as_str()
            .map(str::to_string),
    })
}

const REPO_FIELDS: &str = "name owner { login } defaultBranchRef { name target { oid } }";

pub struct Tester<'a> {
    pub api: &'a Api,
    pub rec: &'a mut Recorder,
    /// The token record key, for the recorder.
    pub key: &'a str,
    pub token: &'a str,
    /// The classic PAT, for Public's Team membership item.
    pub classic: Option<&'a str>,
}

impl Tester<'_> {
    async fn gql(&mut self, query: &str, vars: Value) -> Result<Gql, CallError> {
        let query = query.replacen('{', "{ rateLimit { cost limit remaining resetAt } ", 1);
        self.api
            .graphql(self.rec, self.key, self.token, &query, vars)
            .await
    }

    async fn rest(&mut self, path: &str) -> Result<crate::github::Rest, CallError> {
        self.api
            .rest(self.rec, self.key, self.token, path, None)
            .await
    }

    /// Every item Failed: the token itself was rejected.
    fn rejected(items: &[&str]) -> Report {
        Report {
            results: items
                .iter()
                .map(|item| {
                    result(
                        item,
                        TestOutcome::Failed,
                        None,
                        Some("the token was rejected"),
                    )
                })
                .collect(),
            ..Report::default()
        }
    }

    pub async fn run(&mut self, target: &str, owner: Option<&str>) -> Result<Report, CallError> {
        match target {
            NOTIFICATIONS => self.classic().await,
            PUBLIC => self.public().await,
            _ => self.owner_scope(owner.unwrap_or(target)).await,
        }
    }

    /// Notifications, Team membership (`read:org`) and Scopes.
    async fn classic(&mut self) -> Result<Report, CallError> {
        let items = [NOTIFICATIONS_ITEM, TEAMS, SCOPES];
        let user = match self.rest("/user").await {
            Ok(answer) => answer,
            Err(CallError::Unauthorized) => return Ok(Self::rejected(&items)),
            Err(e) => return Err(e),
        };
        let mut report = Report {
            owner: user.body["login"].as_str().map(str::to_string),
            ..Report::default()
        };
        let granted: Option<Vec<String>> = user.header("x-oauth-scopes").map(|s| {
            s.split(',')
                .map(|scope| scope.trim().to_string())
                .filter(|scope| !scope.is_empty())
                .collect()
        });
        report
            .results
            .push(match self.rest("/notifications?per_page=1").await {
                Ok(_) | Err(CallError::NotFound) => ok(NOTIFICATIONS_ITEM),
                Err(CallError::Forbidden { accepted, .. }) => failed(
                    NOTIFICATIONS_ITEM,
                    accepted.as_deref().unwrap_or("notifications"),
                ),
                Err(e) => return Err(e),
            });
        report
            .results
            .push(match self.rest("/user/teams?per_page=1").await {
                Ok(_) | Err(CallError::NotFound) => ok(TEAMS),
                Err(CallError::Forbidden { accepted, .. }) => {
                    failed(TEAMS, accepted.as_deref().unwrap_or("read:org"))
                }
                Err(e) => return Err(e),
            });
        report.results.push(match granted {
            None => unverifiable(SCOPES, "GitHub did not list the scopes"),
            Some(granted) => {
                let lacking: Vec<&str> = ["notifications", "read:org"]
                    .into_iter()
                    .filter(|scope| !granted.iter().any(|g| g == scope))
                    .collect();
                if lacking.is_empty() {
                    ok(SCOPES)
                } else {
                    failed(SCOPES, &lacking.join(", "))
                }
            }
        });
        Ok(report)
    }

    /// Public: a repository of a public PR the viewer is involved in, else
    /// one of the viewer's own public repositories.
    async fn public(&mut self) -> Result<Report, CallError> {
        let items = [PRS, CHECKS, BEHIND, TEAMS, MERGE_QUEUE];
        let query = format!(
            "query Probe {{ viewer {{ login repositories(first: 1, privacy: PUBLIC, ownerAffiliations: [OWNER]) {{ nodes {{ {REPO_FIELDS} }} }} }} \
             involved: search(type: ISSUE, query: \"is:pr is:public involves:@me\", first: 1) {{ nodes {{ ... on PullRequest {{ repository {{ {REPO_FIELDS} }} }} }} }} }}"
        );
        let answer = match self.gql(&query, json!({})).await {
            Ok(answer) => answer,
            Err(CallError::Unauthorized) => return Ok(Self::rejected(&items)),
            Err(e) => return Err(e),
        };
        let owner = answer.data["viewer"]["login"].as_str().map(str::to_string);
        let repo = answer.data["involved"]["nodes"][0]["repository"].clone();
        let repo = if repo.is_object() {
            repo
        } else {
            answer.data["viewer"]["repositories"]["nodes"][0].clone()
        };
        let mut report = Report {
            owner,
            ..Report::default()
        };
        match probe_of(&repo) {
            None => {
                for item in [PRS, CHECKS, BEHIND, MERGE_QUEUE] {
                    report
                        .results
                        .push(unverifiable(item, "no public repository to check against"));
                }
            }
            Some(probe) => self.repository_items(&probe, &mut report).await?,
        }
        // DESIGN.md, "Token registration and test": Public's team membership
        // is read with the classic PAT (`read:org`).
        let teams = match self.classic {
            None => unverifiable(TEAMS, "no notifications token"),
            Some(classic) => match self
                .api
                .rest(
                    self.rec,
                    NOTIFICATIONS,
                    classic,
                    "/user/teams?per_page=1",
                    None,
                )
                .await
            {
                Ok(_) | Err(CallError::NotFound) => ok(TEAMS),
                Err(CallError::Forbidden { accepted, .. }) => {
                    failed(TEAMS, accepted.as_deref().unwrap_or("read:org"))
                }
                Err(e) => return Err(e),
            },
        };
        report.results.insert(3.min(report.results.len()), teams);
        Ok(report)
    }

    async fn owner_scope(&mut self, owner: &str) -> Result<Report, CallError> {
        let query = format!(
            "query Probe($owner: String!) {{ viewer {{ login }} owner: repositoryOwner(login: $owner) {{ __typename login \
             repositories(first: 1, orderBy: {{field: PUSHED_AT, direction: DESC}}) {{ nodes {{ {REPO_FIELDS} }} }} }} }}"
        );
        let answer = match self.gql(&query, json!({"owner": owner})).await {
            Ok(answer) => answer,
            Err(CallError::Unauthorized) => {
                return Ok(Self::rejected(&[PRS, CHECKS, BEHIND, TEAMS, MERGE_QUEUE]));
            }
            Err(e) => return Err(e),
        };
        let kind = owner_kind(&answer.data["owner"]);
        let mut report = Report {
            owner: answer.data["viewer"]["login"].as_str().map(str::to_string),
            kind,
            name: answer.data["owner"]["login"].as_str().map(str::to_string),
            ..Report::default()
        };
        let Some(kind) = kind else {
            for item in [PRS, CHECKS, BEHIND, TEAMS, MERGE_QUEUE] {
                report.results.push(unverifiable(item, "owner not found"));
            }
            return Ok(report);
        };
        match probe_of(&answer.data["owner"]["repositories"]["nodes"][0]) {
            None => {
                for item in [PRS, CHECKS, BEHIND, MERGE_QUEUE] {
                    report
                        .results
                        .push(unverifiable(item, "no repository to check against"));
                }
            }
            Some(probe) => self.repository_items(&probe, &mut report).await?,
        }
        if kind == ScopeKind::Org {
            let viewer = report.owner.clone().unwrap_or_default();
            let answer = self
                .gql(
                    "query Teams($owner: String!, $viewer: String!) { organization(login: $owner) { teams(first: 1, userLogins: [$viewer]) { totalCount } } }",
                    json!({"owner": owner, "viewer": viewer}),
                )
                .await;
            let item = judge_gql(TEAMS, "Members", answer)?;
            report.results.insert(3.min(report.results.len()), item);
        }
        Ok(report)
    }

    /// PRs, Checks, Behind base and Merge queue against one repository.
    async fn repository_items(
        &mut self,
        probe: &Probe,
        report: &mut Report,
    ) -> Result<(), CallError> {
        let vars = json!({"owner": probe.owner, "name": probe.name});
        let answer = self
            .gql(
                "query Pulls($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { pullRequests(first: 1) { nodes { id } } } }",
                vars.clone(),
            )
            .await;
        report
            .results
            .push(judge_gql(PRS, "Pull requests", answer)?);

        let Some(oid) = probe.oid.clone() else {
            report
                .results
                .push(unverifiable(CHECKS, "no commit to check against"));
            report
                .results
                .push(unverifiable(BEHIND, "no commit to check against"));
            report
                .results
                .push(unverifiable(MERGE_QUEUE, "no default branch"));
            return Ok(());
        };
        let repo = format!("/repos/{}/{}", encode(&probe.owner), encode(&probe.name));
        let mut lacking = Vec::new();
        match self
            .rest(&format!("{repo}/commits/{}/status", encode(&oid)))
            .await
        {
            Ok(_) | Err(CallError::NotFound) => {}
            Err(CallError::Forbidden { accepted, .. }) => {
                lacking.push(accepted.unwrap_or_else(|| "Commit statuses".into()))
            }
            Err(e) => return Err(e),
        }
        match self
            .rest(&format!(
                "{repo}/actions/runs?head_sha={}&per_page=1",
                encode(&oid)
            ))
            .await
        {
            Ok(_) | Err(CallError::NotFound) => {}
            Err(CallError::Forbidden { accepted, .. }) => {
                lacking.push(accepted.unwrap_or_else(|| "Actions".into()))
            }
            Err(e) => return Err(e),
        }
        report.results.push(if lacking.is_empty() {
            ok(CHECKS)
        } else {
            failed(CHECKS, &lacking.join(", "))
        });

        let branch = probe.branch.clone().unwrap_or_default();
        let vars = json!({"owner": probe.owner, "name": probe.name, "branch": branch});
        let answer = self
            .gql(
                "query Behind($owner: String!, $name: String!, $branch: String!) { repository(owner: $owner, name: $name) { defaultBranchRef { compare(headRef: $branch) { behindBy } } } }",
                vars.clone(),
            )
            .await;
        report.results.push(judge_gql(BEHIND, "Contents", answer)?);
        let answer = self
            .gql(
                "query Queue($owner: String!, $name: String!, $branch: String!) { repository(owner: $owner, name: $name) { mergeQueue(branch: $branch) { id } } }",
                vars,
            )
            .await;
        // The permission a private repository's merge queue needs is not
        // known (DESIGN.md, open questions).
        report
            .results
            .push(judge_gql(MERGE_QUEUE, "unknown", answer)?);
        Ok(())
    }
}
