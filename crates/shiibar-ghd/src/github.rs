//! Read-only calls to the GitHub REST and GraphQL APIs, and what every
//! response says about its token and the rate limits. Nothing here writes to
//! GitHub: only GET for REST, and only queries for GraphQL.
//!
//! Headers: docs/tasks/M2.md, "Tokens and the Keychain" (token expiry,
//! `X-OAuth-Scopes`, `X-GitHub-SSO`), "Rate limits" (`x-ratelimit-*`,
//! `retry-after`) and "REST version".

use crate::model::LimitRec;
use crate::plan::TokenObs;
use reqwest::header::HeaderMap;
use serde_json::{Value, json};
use std::time::Duration;

pub const DEFAULT_BASE: &str = "https://api.github.com";
/// docs/tasks/M2.md, "REST version".
pub const REST_VERSION: &str = "2026-03-10";
const TIMEOUT: Duration = Duration::from_secs(30);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Without `retry-after` or a reset time, a secondary limit waits this long.
const SECONDARY_WAIT: i64 = 60;
const HOUR: i64 = 3_600;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CallError {
    /// Network failure, timeout or 5xx: retried at the next interval.
    Network(String),
    /// 401.
    Unauthorized,
    /// A permission error. `accepted` is `x-accepted-github-permissions`.
    Forbidden {
        accepted: Option<String>,
        message: String,
    },
    NotFound,
    /// A primary or secondary limit: every fetch of the account stops.
    RateLimited {
        until: i64,
        reason: String,
    },
    /// Anything else that makes the answer unusable.
    Other(String),
}

impl std::fmt::Display for CallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CallError::Network(m) => write!(f, "network: {m}"),
            CallError::Unauthorized => write!(f, "the token was rejected (401)"),
            CallError::Forbidden { message, .. } => write!(f, "forbidden: {message}"),
            CallError::NotFound => write!(f, "not found"),
            CallError::RateLimited { reason, .. } => write!(f, "{reason}"),
            CallError::Other(m) => write!(f, "{m}"),
        }
    }
}

/// A successful REST answer, 304 included.
#[derive(Debug, Clone)]
pub struct Rest {
    pub status: u16,
    pub headers: HeaderMap,
    pub body: Value,
}

impl Rest {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name).and_then(|v| v.to_str().ok())
    }
}

/// One GraphQL error as GitHub returns it: `type` and `path`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GqlError {
    pub kind: String,
    pub path: Vec<String>,
    pub message: String,
}

impl GqlError {
    pub fn is_permission(&self) -> bool {
        matches!(self.kind.as_str(), "FORBIDDEN" | "INSUFFICIENT_SCOPES")
    }

    pub fn is_not_found(&self) -> bool {
        self.kind == "NOT_FOUND"
    }
}

/// A GraphQL answer that has data. Errors next to the data are partial
/// failures for the caller to judge.
#[derive(Debug, Clone)]
pub struct Gql {
    pub data: Value,
    pub errors: Vec<GqlError>,
}

/// What the responses of one run of an account said about its token, and
/// the rate limit bookkeeping of that account.
#[derive(Debug, Default)]
pub struct Recorder {
    pub now: i64,
    pub token: TokenObs,
    pub rest: Option<LimitRec>,
    pub graphql: Option<LimitRec>,
    /// Every fetch of the account stops until this time.
    pub stop: Option<i64>,
    /// At least one call was answered.
    pub answered: bool,
}

impl Recorder {
    pub fn new(now: i64) -> Self {
        Self {
            now,
            ..Self::default()
        }
    }

    /// Stop everything until `until`. The earliest stop wins.
    pub fn stop(&mut self, until: i64) -> CallError {
        let until = *self.stop.get_or_insert(until);
        CallError::RateLimited {
            until,
            reason: "GitHub's limit reached".into(),
        }
    }

    /// Refuse a call once the run stopped.
    fn admit(&mut self) -> Result<(), CallError> {
        match self.stop {
            Some(until) => Err(CallError::RateLimited {
                until,
                reason: "GitHub's limit reached".into(),
            }),
            None => Ok(()),
        }
    }

    fn observe(&mut self, status: u16, headers: &HeaderMap) {
        let text = |name: &str| headers.get(name).and_then(|v| v.to_str().ok());
        self.answered = true;
        if let Some(expires) = text("github-authentication-token-expiration").and_then(parse_expiry)
        {
            self.token.expires_at = Some(expires);
        }
        if let Some(scopes) = text("x-oauth-scopes") {
            self.token.scopes = Some(
                scopes
                    .split(',')
                    .map(|scope| scope.trim().to_string())
                    .filter(|scope| !scope.is_empty())
                    .collect(),
            );
        }
        if let Some(sso) = text("x-github-sso") {
            self.token.sso = true;
            for org in sso_orgs(sso) {
                if !self.token.sso_orgs.contains(&org) {
                    self.token.sso_orgs.push(org);
                }
            }
            if let Some(url) = sso_url(sso)
                && !self.token.sso_urls.contains(&url)
            {
                self.token.sso_urls.push(url);
            }
        }
        self.token.invalid = Some(status == 401);
        let number = |name: &str| text(name).and_then(|v| v.trim().parse::<i64>().ok());
        if let (Some(remaining), Some(limit)) =
            (number("x-ratelimit-remaining"), number("x-ratelimit-limit"))
        {
            let record = LimitRec {
                limit,
                remaining,
                reset_at: number("x-ratelimit-reset"),
            };
            match text("x-ratelimit-resource") {
                Some("graphql") => self.graphql = Some(record),
                Some("core") | None => {
                    self.rest = Some(record);
                    // DESIGN.md, "Rate limits": the REST budget ran out.
                    if remaining == 0 && (200..300).contains(&status) {
                        let reset = record.reset_at.unwrap_or(self.now + HOUR);
                        self.stop(reset.max(self.now + 1));
                    }
                }
                Some(_) => {}
            }
        }
    }

    /// DESIGN.md, "Rate limits": a primary limit stops until its reset, a
    /// secondary one for `retry-after`, else until the reset when nothing
    /// remains, else one minute.
    fn limit_from(&mut self, headers: &HeaderMap) -> CallError {
        let number = |name: &str| {
            headers
                .get(name)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.trim().parse::<i64>().ok())
        };
        if let Some(after) = number("retry-after") {
            return self.stop(self.now + after.max(1));
        }
        if number("x-ratelimit-remaining") == Some(0)
            && let Some(reset) = number("x-ratelimit-reset")
        {
            return self.stop(reset.max(self.now + 1));
        }
        self.stop(self.now + SECONDARY_WAIT)
    }
}

/// The organization ids of `partial-results; organizations=21955855,20582480`
/// (docs.github.com/en/rest/authentication/authenticating-to-the-rest-api).
pub fn sso_orgs(header: &str) -> Vec<i64> {
    header
        .split(';')
        .map(str::trim)
        .filter_map(|part| part.strip_prefix("organizations="))
        .flat_map(|ids| ids.split(','))
        .filter_map(|id| id.trim().parse().ok())
        .collect()
}

/// `https://…` from `required; url=https://…`.
pub fn sso_url(header: &str) -> Option<String> {
    header
        .split(';')
        .map(str::trim)
        .find_map(|part| part.strip_prefix("url="))
        .map(str::to_string)
}

/// `2026-12-03 13:03:23 UTC`, the form the owner saw, or with a numeric
/// offset in place of `UTC`.
pub fn parse_expiry(text: &str) -> Option<i64> {
    let text = text.trim();
    if let Some(utc) = text.strip_suffix(" UTC") {
        let civil = jiff::civil::DateTime::strptime("%Y-%m-%d %H:%M:%S", utc).ok()?;
        return civil
            .to_zoned(jiff::tz::TimeZone::UTC)
            .ok()
            .map(|z| z.timestamp().as_second());
    }
    jiff::Timestamp::strptime("%Y-%m-%d %H:%M:%S %z", text)
        .ok()
        .map(|t| t.as_second())
}

/// An ISO 8601 timestamp from GitHub as epoch seconds.
pub fn parse_time(text: &str) -> Option<i64> {
    text.parse::<jiff::Timestamp>().ok().map(|t| t.as_second())
}

/// Epoch seconds as GitHub's `DateTime`.
pub fn format_time(at: i64) -> String {
    jiff::Timestamp::from_second(at)
        .map(|t| t.strftime("%Y-%m-%dT%H:%M:%SZ").to_string())
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into())
}

pub struct Api {
    client: reqwest::Client,
    base: String,
}

impl Api {
    /// `loopback` builds a client that never uses a proxy, for the test
    /// server of a `dev-ingest` build.
    pub fn new(base: &str, loopback: bool) -> anyhow::Result<Self> {
        let mut builder = reqwest::Client::builder()
            .user_agent(concat!("shiibar-gh/", env!("CARGO_PKG_VERSION")))
            .timeout(TIMEOUT)
            .connect_timeout(CONNECT_TIMEOUT);
        if loopback {
            builder = builder.no_proxy();
        }
        Ok(Self {
            client: builder.build()?,
            base: base.trim_end_matches('/').to_string(),
        })
    }

    async fn send(
        &self,
        rec: &mut Recorder,
        request: reqwest::RequestBuilder,
    ) -> Result<(u16, HeaderMap, String), CallError> {
        let response = request
            .send()
            .await
            .map_err(|e| CallError::Network(describe(&e)))?;
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        let body = response
            .text()
            .await
            .map_err(|e| CallError::Network(describe(&e)))?;
        rec.observe(status, &headers);
        match status {
            401 => Err(CallError::Unauthorized),
            403 | 429 => {
                let message = serde_json::from_str::<Value>(&body)
                    .ok()
                    .and_then(|v| v["message"].as_str().map(str::to_string))
                    .unwrap_or_default();
                let limited = headers.contains_key("retry-after")
                    || headers
                        .get("x-ratelimit-remaining")
                        .is_some_and(|v| v.as_bytes() == b"0")
                    || message.to_lowercase().contains("rate limit");
                if limited {
                    return Err(rec.limit_from(&headers));
                }
                Err(CallError::Forbidden {
                    accepted: headers
                        .get("x-accepted-github-permissions")
                        .and_then(|v| v.to_str().ok())
                        .map(str::to_string),
                    message,
                })
            }
            404 => Err(CallError::NotFound),
            500..=599 => Err(CallError::Network(format!("GitHub answered {status}"))),
            200..=299 | 304 => Ok((status, headers, body)),
            other => Err(CallError::Other(format!("GitHub answered {other}"))),
        }
    }

    /// `GET` a REST path such as `/notifications?all=true`.
    pub async fn rest(
        &self,
        rec: &mut Recorder,
        token: &str,
        path: &str,
        if_modified_since: Option<&str>,
    ) -> Result<Rest, CallError> {
        rec.admit()?;
        let url = if path.starts_with("http") {
            path.to_string()
        } else {
            format!("{}{path}", self.base)
        };
        let mut request = self
            .client
            .get(url)
            .header("Accept", "application/vnd.github+json")
            .header("X-GitHub-Api-Version", REST_VERSION);
        // An empty token asks without authentication (`owner_lookup` of an
        // account without a token).
        if !token.is_empty() {
            request = request.bearer_auth(token);
        }
        if let Some(since) = if_modified_since {
            request = request.header("If-Modified-Since", since);
        }
        let (status, headers, body) = self.send(rec, request).await?;
        let body = if body.trim().is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&body)
                .map_err(|e| CallError::Other(format!("unreadable REST answer: {e}")))?
        };
        Ok(Rest {
            status,
            headers,
            body,
        })
    }

    /// A GraphQL query. Every query asks for `rateLimit`, which is recorded.
    pub async fn graphql(
        &self,
        rec: &mut Recorder,
        token: &str,
        query: &str,
        variables: Value,
    ) -> Result<Gql, CallError> {
        rec.admit()?;
        let request = self
            .client
            .post(format!("{}/graphql", self.base))
            .bearer_auth(token)
            .json(&json!({"query": query, "variables": variables}));
        let (_, headers, body) = self.send(rec, request).await?;
        let value: Value = serde_json::from_str(&body)
            .map_err(|e| CallError::Other(format!("unreadable GraphQL answer: {e}")))?;
        let errors: Vec<GqlError> = value["errors"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|e| GqlError {
                kind: e["type"].as_str().unwrap_or_default().to_string(),
                path: e["path"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|p| match p {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    })
                    .collect(),
                message: e["message"].as_str().unwrap_or_default().to_string(),
            })
            .collect();
        let rate = &value["data"]["rateLimit"];
        if let (Some(remaining), Some(limit)) = (rate["remaining"].as_i64(), rate["limit"].as_i64())
        {
            let reset_at = rate["resetAt"].as_str().and_then(parse_time);
            rec.graphql = Some(LimitRec {
                limit,
                remaining,
                reset_at,
            });
            if remaining == 0 {
                rec.stop(reset_at.unwrap_or(rec.now + HOUR));
            }
        }
        if errors.iter().any(|e| e.kind == "RATE_LIMITED") {
            return Err(rec.limit_from(&headers));
        }
        if value["data"].is_null() {
            let message = errors
                .first()
                .map(|e| format!("{}: {}", e.kind, e.message))
                .unwrap_or_else(|| "GraphQL answered without data".into());
            if errors.iter().all(GqlError::is_permission) && !errors.is_empty() {
                return Err(CallError::Forbidden {
                    accepted: None,
                    message,
                });
            }
            return Err(CallError::Other(message));
        }
        Ok(Gql {
            data: value["data"].clone(),
            errors,
        })
    }
}

/// A short description. URLs carry nothing secret; tokens travel only in the
/// `Authorization` header, which no error message includes.
fn describe(error: &reqwest::Error) -> String {
    if error.is_timeout() {
        "timed out".into()
    } else if error.is_connect() {
        "cannot connect".into()
    } else {
        error.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_expiry_header_reads_as_utc() {
        assert_eq!(
            parse_expiry("2026-12-03 13:03:23 UTC"),
            Some(
                jiff::Timestamp::strptime("%Y-%m-%d %H:%M:%S %z", "2026-12-03 13:03:23 +0000")
                    .unwrap()
                    .as_second()
            )
        );
        assert_eq!(parse_expiry("never"), None);
    }

    #[test]
    fn times_round_trip() {
        assert_eq!(format_time(1_800_000_000), "2027-01-15T08:00:00Z");
        assert_eq!(parse_time("2027-01-15T08:00:00Z"), Some(1_800_000_000));
    }

    #[test]
    fn the_sso_url_is_taken_from_the_header() {
        assert_eq!(
            sso_url("required; url=https://github.com/orgs/x/sso?authorization_request=1"),
            Some("https://github.com/orgs/x/sso?authorization_request=1".into())
        );
        assert_eq!(
            sso_url("partial-results; organizations=21955855,20582480"),
            None
        );
    }

    #[test]
    fn the_sso_organizations_are_read_from_the_header() {
        assert_eq!(
            sso_orgs("partial-results; organizations=21955855,20582480"),
            vec![21955855, 20582480]
        );
        assert!(sso_orgs("required; url=https://github.com/orgs/x/sso").is_empty());
    }
}
