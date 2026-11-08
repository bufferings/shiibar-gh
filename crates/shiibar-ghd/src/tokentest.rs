//! `token_test`: the items of DESIGN.md, "Token registration and test", one
//! question per item: Account (`viewer { databaseId login }`), Scopes
//! (`X-OAuth-Scopes`), Notifications (`GET /notifications`), Team
//! membership (`GET /user/teams`), and one search per registered owner.

use crate::engine::missing_scopes;
use crate::github::{Api, CallError, Recorder};
use crate::model::OwnerKind;
use serde_json::json;
use shiibar_gh_proto::{Lenient, TestItem, TestOutcome, TestResult};

pub const ACCOUNT: &str = "Account";
pub const SCOPES: &str = "Scopes";
pub const NOTIFICATIONS: &str = "Notifications";
pub const TEAMS: &str = "Team membership";
pub const UNREACHABLE: &str = "Couldn't reach GitHub";
pub const CANT_CHECK: &str = "Can't check";
/// Why `viewer` gave no account: `databaseId` came back `null`.
pub const NO_NUMERIC_ID: &str = "GitHub gave no numeric id (databaseId) for the token owner";

/// DESIGN.md, "Token registration and test": an item that could not be
/// asked is `Can't check (<why>)`; an HTTP answer that is not a success is
/// `Failed (HTTP <status>)`.
fn call_failed(item: TestItem, label: &str, owner: Option<&str>, error: &CallError) -> TestResult {
    let (outcome, text) = match error {
        CallError::Network(_) => (
            TestOutcome::CantCheck,
            format!("{CANT_CHECK} ({UNREACHABLE})"),
        ),
        CallError::RateLimited { .. } => (
            TestOutcome::CantCheck,
            format!("{CANT_CHECK} (rate limited)"),
        ),
        CallError::Unauthorized => (TestOutcome::Failed, "Failed (HTTP 401)".to_string()),
        CallError::Forbidden { .. } => (TestOutcome::Failed, "Failed (HTTP 403)".to_string()),
        CallError::NotFound => (TestOutcome::Failed, "Failed (HTTP 404)".to_string()),
        CallError::Other(message) => match message.strip_prefix("GitHub answered ") {
            Some(status) if status.bytes().all(|b| b.is_ascii_digit()) => {
                (TestOutcome::Failed, format!("Failed (HTTP {status})"))
            }
            _ => (TestOutcome::Failed, "Failed".to_string()),
        },
    };
    result(item, label, owner, outcome, &text, None)
}

fn result(
    item: TestItem,
    label: &str,
    owner: Option<&str>,
    outcome: TestOutcome,
    text: &str,
    url: Option<String>,
) -> TestResult {
    TestResult {
        item: Lenient::Known(item),
        label: label.to_string(),
        owner: owner.map(str::to_string),
        outcome: Lenient::Known(outcome),
        text: text.to_string(),
        url,
    }
}

/// An owner to test, as the daemon knows it.
#[derive(Debug, Clone)]
pub struct OwnerProbe {
    pub id: String,
    pub name: String,
    pub kind: OwnerKind,
    pub github_id: Option<i64>,
}

/// Who the token has to belong to.
#[derive(Debug, Clone)]
pub enum Expect {
    /// Edit…: the account's own id.
    Account { id: String },
    /// Add account: any id not added yet; `taken` maps ids to logins.
    New { taken: Vec<(String, String)> },
}

/// What a test found besides the results.
#[derive(Debug, Default)]
pub struct Report {
    pub results: Vec<TestResult>,
    /// `viewer { databaseId login }`, when it answered: the numeric id as
    /// a decimal string, and the login.
    pub viewer: Option<(String, String)>,
}

/// The owner of a token: `viewer { databaseId login }`. The account id is
/// GitHub's numeric user id (`User.databaseId`, the `id` of REST `GET
/// /user`) as a decimal string; node ids are moving to a new format
/// (DESIGN.md, "Tokens"). Used by `account_add`, `token_set` and the
/// Account item.
pub async fn viewer(
    api: &Api,
    rec: &mut Recorder,
    token: &str,
) -> Result<(String, String), CallError> {
    let answer = api
        .graphql(
            rec,
            token,
            "query Viewer { rateLimit { cost limit remaining resetAt } viewer { databaseId login } }",
            json!({}),
        )
        .await?;
    let login = answer.data["viewer"]["login"].as_str().unwrap_or_default();
    // `databaseId` is nullable in the public schema.
    let Some(id) = answer.data["viewer"]["databaseId"].as_i64() else {
        return Err(CallError::Other(NO_NUMERIC_ID.into()));
    };
    if login.is_empty() {
        return Err(CallError::Other(
            "GitHub did not name the token owner".into(),
        ));
    }
    Ok((id.to_string(), login.to_string()))
}

pub async fn run(
    api: &Api,
    rec: &mut Recorder,
    token: &str,
    expect: &Expect,
    owners: &[OwnerProbe],
) -> Report {
    let mut report = Report::default();
    let cant_check = |report: &mut Report, text: &str| {
        for (item, label) in [
            (TestItem::Scopes, SCOPES),
            (TestItem::Notifications, NOTIFICATIONS),
            (TestItem::TeamMembership, TEAMS),
        ] {
            report.results.push(result(
                item,
                label,
                None,
                TestOutcome::CantCheck,
                text,
                None,
            ));
        }
        for owner in owners {
            report.results.push(result(
                TestItem::Owner,
                &owner.name,
                Some(&owner.id),
                TestOutcome::CantCheck,
                text,
                None,
            ));
        }
    };
    let failed_account = |report: &mut Report, text: &str| {
        report.results.push(result(
            TestItem::Account,
            ACCOUNT,
            None,
            TestOutcome::Failed,
            text,
            None,
        ));
    };
    match viewer(api, rec, token).await {
        Ok((id, login)) => {
            let wrong = match expect {
                Expect::Account { id: expected } if *expected != id => {
                    Some(format!("Belongs to {login}"))
                }
                Expect::New { taken } => taken
                    .iter()
                    .find(|(taken, _)| *taken == id)
                    .map(|(_, known)| format!("{known} is already added")),
                _ => None,
            };
            match wrong {
                Some(text) => failed_account(&mut report, &text),
                None => report.results.push(result(
                    TestItem::Account,
                    ACCOUNT,
                    None,
                    TestOutcome::Ok,
                    &login,
                    None,
                )),
            }
            report.viewer = Some((id, login));
        }
        Err(CallError::Unauthorized) => {
            failed_account(&mut report, "Token is invalid");
            cant_check(&mut report, CANT_CHECK);
            return report;
        }
        // DESIGN.md, "Token registration and test": a rate limit is
        // `✗ Rate limited` with every other item `Can't check`.
        Err(CallError::RateLimited { .. }) => {
            failed_account(&mut report, "Rate limited");
            cant_check(&mut report, CANT_CHECK);
            return report;
        }
        // GitHub answered, without the numeric id the account needs.
        Err(CallError::Other(message)) if message == NO_NUMERIC_ID => {
            failed_account(&mut report, "Failed (no numeric id)");
            cant_check(&mut report, CANT_CHECK);
            return report;
        }
        Err(_) => {
            failed_account(&mut report, UNREACHABLE);
            cant_check(&mut report, &format!("{CANT_CHECK} ({UNREACHABLE})"));
            return report;
        }
    }

    // Scopes: `X-OAuth-Scopes` of `GET /user`, as 0.1 read it.
    report
        .results
        .push(match api.rest(rec, token, "/user", None).await {
            Ok(answer) => match answer.header("x-oauth-scopes") {
                None => result(
                    TestItem::Scopes,
                    SCOPES,
                    None,
                    TestOutcome::CantCheck,
                    "Can't check",
                    None,
                ),
                Some(header) => {
                    let granted: Vec<String> = header
                        .split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect();
                    let missing = missing_scopes(&granted);
                    if missing.is_empty() {
                        result(TestItem::Scopes, SCOPES, None, TestOutcome::Ok, "OK", None)
                    } else {
                        result(
                            TestItem::Scopes,
                            SCOPES,
                            None,
                            TestOutcome::Failed,
                            &format!("Missing ({})", missing.join(", ")),
                            None,
                        )
                    }
                }
            },
            Err(e) => call_failed(TestItem::Scopes, SCOPES, None, &e),
        });

    for (item, label, path, scope) in [
        (
            TestItem::Notifications,
            NOTIFICATIONS,
            "/notifications?per_page=1",
            "notifications",
        ),
        (
            TestItem::TeamMembership,
            TEAMS,
            "/user/teams?per_page=1",
            "read:org",
        ),
    ] {
        report
            .results
            .push(match api.rest(rec, token, path, None).await {
                Ok(_) => result(item, label, None, TestOutcome::Ok, "OK", None),
                Err(
                    CallError::Forbidden { .. } | CallError::NotFound | CallError::Unauthorized,
                ) => result(
                    item,
                    label,
                    None,
                    TestOutcome::Failed,
                    &format!("Failed ({scope})"),
                    None,
                ),
                Err(e) => call_failed(item, label, None, &e),
            });
    }

    for owner in owners {
        report
            .results
            .push(test_owner(api, rec, token, owner).await);
    }
    report
}

/// One search of the owner. `X-GitHub-SSO` naming the owner's organization,
/// or a single-organization refusal with its URL, is `SSO authorization
/// required`.
async fn test_owner(api: &Api, rec: &mut Recorder, token: &str, owner: &OwnerProbe) -> TestResult {
    let qualifier = match owner.kind {
        OwnerKind::Public => "is:public".to_string(),
        OwnerKind::User => format!("user:{}", owner.name),
        OwnerKind::Org => format!("org:{}", owner.name),
    };
    rec.token.sso = false;
    rec.token.sso_orgs.clear();
    rec.token.sso_urls.clear();
    let answer = api
        .graphql(
            rec,
            token,
            "query OwnerTest($q: String!) { rateLimit { cost limit remaining resetAt } search(type: ISSUE, query: $q, first: 1) { issueCount } }",
            json!({"q": format!("is:pr involves:@me {qualifier}")}),
        )
        .await;
    let sso = rec.token.sso
        && (rec.token.sso_orgs.is_empty()
            || owner
                .github_id
                .is_some_and(|id| rec.token.sso_orgs.contains(&id)));
    if sso {
        return result(
            TestItem::Owner,
            &owner.name,
            Some(&owner.id),
            TestOutcome::SsoRequired,
            "SSO authorization required",
            rec.token.sso_urls.first().cloned(),
        );
    }
    match answer {
        Ok(answer) if answer.errors.is_empty() => result(
            TestItem::Owner,
            &owner.name,
            Some(&owner.id),
            TestOutcome::Ok,
            "OK",
            None,
        ),
        Ok(_) => result(
            TestItem::Owner,
            &owner.name,
            Some(&owner.id),
            TestOutcome::Failed,
            "Failed",
            None,
        ),
        Err(e) => call_failed(TestItem::Owner, &owner.name, Some(&owner.id), &e),
    }
}
