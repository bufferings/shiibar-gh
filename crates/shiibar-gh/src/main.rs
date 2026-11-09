//! shiibar-gh: command line client of the daemon. Every command is one request
//! over the socket. DESIGN.md, sections "CLI (AI integration)" and "CLI exit
//! codes".

use shiibar_gh_client::{ClientError, request, request_json, socket_path_from_env};
use shiibar_gh_proto::{
    AccountResponse, AccountsResponse, AckResponse, ActivityResponse, Card, ConfigResponse,
    EventKind, EventsResponse, ExclusionsResponse, InfoResponse, ListResponse, OpenResponse,
    OwnerLookupResponse, PrFilter, RefreshResponse, Request, Row, StatusResponse, TestResult,
    TokenTestResponse, Warning,
};
use std::collections::BTreeMap;
use std::io::{BufRead, IsTerminal};
use std::path::Path;
use std::process::ExitCode;

const OK: u8 = 0;
const ERROR: u8 = 1;
const NOT_FOUND: u8 = 2;

/// `(command words, arguments, what it does)`.
const COMMANDS: [(&str, &str, &str); 30] = [
    (
        "list",
        "[--account <a>] [--owner <o>] [--authored|--assigned|--review-requested] [--search <text>] [--snoozed] [--json]",
        "Print the PR cards of the PRs tab, by owner, open PRs first, then the most\n      \
         recently updated. [review requested] marks a PR awaiting your review.\n      \
         --search keeps the PRs where every word of <text> matches; --snoozed\n      \
         prints the Snoozed section",
    ),
    (
        "status",
        "<pr> --account <a> [--json]",
        "Print the state label and Review, Checks and Base of a PR",
    ),
    (
        "activity",
        "[--account <a>] [--owner <o>]... [--authored|--assigned|--review-requested] [--search <text>] [--json]",
        "Print the rows of the shown cards, newest first",
    ),
    (
        "read",
        "<row>... [--account <a>] | --all --account <a>",
        "Mark rows as read; --all marks every row of the account except those of\n      \
         snoozed PRs. With rows, --account must name their account",
    ),
    (
        "snooze",
        "<pr> --account <a>",
        "Snooze a PR until the next Return time",
    ),
    ("unsnooze", "<pr> --account <a>", "End the Snooze of a PR"),
    (
        "refresh",
        "[--account <a>]",
        "Fetch now and return once applied; reads the Keychain again when it could not be read",
    ),
    (
        "open",
        "<pr|row> [--account <a>]",
        "Print the URL of a PR (needs --account) or of a row; a row stays unread",
    ),
    (
        "config get",
        "<key> [--json]",
        "Print a setting. Keys: launch_at_login, appearance, text_size,\n      \
         status_interval_minutes, reactions_interval_minutes, snooze_return_time,\n      \
         keep_watching_days, drop_after_days",
    ),
    (
        "config set",
        "<key> <value>",
        "Change a setting (text_size is a whole number from 9 to 18)",
    ),
    (
        "version",
        "[--json]",
        "Print the version of this command and of the running daemon",
    ),
    (
        "reset",
        "",
        "Set aside an unreadable database and start empty",
    ),
    (
        "account list",
        "[--json]",
        "Print the accounts and their owners",
    ),
    (
        "account add",
        "[--json]",
        "Add the account the token on standard input belongs to",
    ),
    (
        "account remove",
        "<account>",
        "Remove an account, its owners, PRs and its token",
    ),
    (
        "account color",
        "<account> none|red|orange|yellow|green|blue|purple",
        "Set the color of an account",
    ),
    (
        "token set",
        "--account <a>",
        "Replace the token with the one on standard input, if it belongs to the account",
    ),
    (
        "token test",
        "[--account <a>] [--json]",
        "Test the token piped to standard input, or the saved one. Without\n      \
         --account a piped token is required. Without a token to pipe, run it\n      \
         from a terminal or with </dev/null",
    ),
    (
        "token reset",
        "",
        "Delete the Keychain item: every account is left without a token",
    ),
    (
        "owner lookup",
        "<owner> --account <a> [--json]",
        "Print an owner's login, kind (org or user) and id, without adding it",
    ),
    (
        "owner list",
        "[--account <a>] [--json]",
        "Print the owners. With --account, --json prints {\"ok\":true,\"owners\":[...]}\n      \
         for that account; without it, the account_list response",
    ),
    (
        "owner add",
        "<owner>|public --account <a> [--json]",
        "Add an owner (looked up on GitHub), or Public",
    ),
    (
        "owner remove",
        "<owner> --account <a>",
        "Remove an owner and its PRs, snoozes and settings",
    ),
    ("owner enable", "<owner> --account <a>", "Enable an owner"),
    ("owner disable", "<owner> --account <a>", "Disable an owner"),
    (
        "owner notify",
        "<owner> on|off --account <a>",
        "Notify for the owner",
    ),
    (
        "owner skip-drafts",
        "<owner> on|off --account <a>",
        "Skip draft pull requests",
    ),
    (
        "owner events",
        "<owner> --account <a> [--json] | set <owner> <event> list|notify on|off --account <a> | copy <from-owner> <to-owner> --account <a>",
        "Print, change or copy the event table",
    ),
    (
        "owner exclusions",
        "<owner> --account <a> [--json] | set <owner> repo|user <name> hidden|list-only --account <a> | remove <owner> repo|user <name> --account <a>",
        "Print, set or remove Exclusions",
    ),
    (
        "help",
        "",
        "--json prints the daemon's response line unchanged (DESIGN.md, Wire format)",
    ),
];

fn usage(prefix: &str) -> String {
    let mut text = String::from("usage:\n");
    for (name, args, about) in COMMANDS {
        if prefix.is_empty() || name == prefix || name.starts_with(&format!("{prefix} ")) {
            text.push_str(&format!("  shiibar-gh {name} {args}\n      {about}\n"));
        }
    }
    text
}

struct UsageError(String);

/// The split of a command's arguments into flags, values and positionals.
#[derive(Default)]
struct Parsed {
    flags: Vec<String>,
    account: Option<String>,
    owners: Vec<String>,
    search: Option<String>,
    positional: Vec<String>,
}

/// `allowed` lists the bare flags; `--account`, `--owner` and `--search`
/// take a value when listed.
fn parse(args: &[String], allowed: &[&str]) -> Result<Parsed, UsageError> {
    let mut parsed = Parsed::default();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--account" | "--owner" | "--search" if allowed.contains(&arg.as_str()) => {
                let value = args
                    .next()
                    .ok_or_else(|| UsageError(format!("{arg} needs a value")))?
                    .clone();
                match arg.as_str() {
                    "--account" if parsed.account.is_some() => {
                        return Err(UsageError("--account is given twice".into()));
                    }
                    "--account" => parsed.account = Some(value),
                    "--search" if parsed.search.is_some() => {
                        return Err(UsageError("--search is given twice".into()));
                    }
                    "--search" => parsed.search = Some(value),
                    _ => parsed.owners.push(value),
                }
            }
            flag if flag.starts_with("--") => {
                if !allowed.contains(&flag) {
                    return Err(UsageError(format!("unknown flag: {flag}")));
                }
                parsed.flags.push(flag.to_string());
            }
            _ => parsed.positional.push(arg.clone()),
        }
    }
    Ok(parsed)
}

impl Parsed {
    fn has(&self, flag: &str) -> bool {
        self.flags.iter().any(|f| f == flag)
    }

    fn json(&self) -> bool {
        self.has("--json")
    }

    /// DESIGN.md, "CLI": commands about an owner or a PR need `--account`.
    fn account(&self) -> Result<String, UsageError> {
        self.account
            .clone()
            .ok_or_else(|| UsageError("--account <account> is required".into()))
    }

    fn args<const N: usize>(&self, names: &str) -> Result<[String; N], UsageError> {
        <[String; N]>::try_from(self.positional.clone())
            .map_err(|_| UsageError(format!("expected {names}")))
    }

    fn none(&self) -> Result<(), UsageError> {
        match self.positional.first() {
            None => Ok(()),
            Some(extra) => Err(UsageError(format!("unexpected argument: {extra}"))),
        }
    }

    fn filter(&self) -> Result<PrFilter, UsageError> {
        let chosen: Vec<PrFilter> = [
            ("--authored", PrFilter::Authored),
            ("--assigned", PrFilter::Assigned),
            ("--review-requested", PrFilter::ReviewRequested),
        ]
        .into_iter()
        .filter(|(flag, _)| self.has(flag))
        .map(|(_, f)| f)
        .collect();
        match chosen.as_slice() {
            [] => Ok(PrFilter::All),
            [one] => Ok(*one),
            _ => Err(UsageError(
                "--authored, --assigned and --review-requested exclude each other".into(),
            )),
        }
    }
}

fn on_off(text: &str) -> Result<bool, UsageError> {
    match text {
        "on" => Ok(true),
        "off" => Ok(false),
        other => Err(UsageError(format!("expected on or off, not {other}"))),
    }
}

/// A wire enum from its text, or a usage error.
fn wire<T: serde::de::DeserializeOwned>(text: &str, what: &str) -> Result<T, UsageError> {
    serde_json::from_value(serde_json::Value::String(text.to_string()))
        .map_err(|_| UsageError(format!("unknown {what}: {text}")))
}

enum Output {
    Nothing,
    /// `read <row>... --account <a>`: every row has to be the account's.
    ReadAs(String),
    Warnings,
    Tests,
    Cards,
    Rows,
    Card,
    Url,
    Value,
    Accounts,
    Account,
    Owners,
    Lookup,
    Events,
    Exclusions,
}

struct Command {
    request: Request,
    output: Output,
    json: bool,
}

impl Command {
    fn quiet(request: Request) -> Self {
        Self {
            request,
            output: Output::Nothing,
            json: false,
        }
    }

    fn new(request: Request, output: Output, json: bool) -> Self {
        Self {
            request,
            output,
            json,
        }
    }
}

/// The first line of standard input, without its line ending. `None` when
/// nothing came. DESIGN.md, "CLI": tokens come from standard input only.
fn stdin_token() -> Option<String> {
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line).ok()?;
    let token = line.trim_end_matches(['\n', '\r']).trim().to_string();
    (!token.is_empty()).then_some(token)
}

fn account_command(sub: &str, rest: &[String]) -> Result<Command, UsageError> {
    Ok(match sub {
        "list" => {
            let p = parse(rest, &["--json"])?;
            p.none()?;
            Command::new(Request::AccountList, Output::Accounts, p.json())
        }
        "add" => {
            let p = parse(rest, &["--json"])?;
            p.none()?;
            let token = stdin_token()
                .ok_or_else(|| UsageError("pipe the token to standard input".into()))?;
            Command::new(Request::AccountAdd { token }, Output::Account, p.json())
        }
        "remove" => {
            let p = parse(rest, &[])?;
            let [account] = p.args("<account>")?;
            Command::quiet(Request::AccountRemove { account })
        }
        "color" => {
            let p = parse(rest, &[])?;
            let [account, color] = p.args("<account> <color>")?;
            Command::quiet(Request::AccountColor {
                account,
                color: wire(&color, "color")?,
            })
        }
        other => return Err(UsageError(format!("unknown command: account {other}"))),
    })
}

fn token_command(sub: &str, rest: &[String]) -> Result<Command, UsageError> {
    Ok(match sub {
        "set" => {
            let p = parse(rest, &["--account"])?;
            p.none()?;
            let account = p.account()?;
            let token = stdin_token()
                .ok_or_else(|| UsageError("pipe the token to standard input".into()))?;
            Command::quiet(Request::TokenSet { account, token })
        }
        "test" => {
            let p = parse(rest, &["--account", "--json"])?;
            p.none()?;
            let token = if std::io::stdin().is_terminal() {
                None
            } else {
                stdin_token()
            };
            if p.account.is_none() && token.is_none() {
                return Err(UsageError(
                    "without --account, pipe the token to standard input".into(),
                ));
            }
            Command::new(
                Request::TokenTest {
                    account: p.account.clone(),
                    token,
                },
                Output::Tests,
                p.json(),
            )
        }
        "reset" => {
            parse(rest, &[])?.none()?;
            Command::quiet(Request::TokenReset)
        }
        other => return Err(UsageError(format!("unknown command: token {other}"))),
    })
}

fn owner_command(sub: &str, rest: &[String]) -> Result<Command, UsageError> {
    let p = parse(rest, &["--account", "--json"])?;
    if sub == "list" {
        p.none()?;
        return Ok(Command::new(Request::AccountList, Output::Owners, p.json()));
    }
    let account = p.account()?;
    let json = p.json();
    Ok(match sub {
        "lookup" => {
            let [owner] = p.args("<owner>")?;
            Command::new(
                Request::OwnerLookup { account, owner },
                Output::Lookup,
                json,
            )
        }
        "add" => {
            let [owner] = p.args("<owner>")?;
            Command::new(Request::OwnerAdd { account, owner }, Output::Account, json)
        }
        "remove" => {
            let [owner] = p.args("<owner>")?;
            Command::quiet(Request::OwnerRemove { account, owner })
        }
        "enable" => {
            let [owner] = p.args("<owner>")?;
            Command::quiet(Request::OwnerEnable { account, owner })
        }
        "disable" => {
            let [owner] = p.args("<owner>")?;
            Command::quiet(Request::OwnerDisable { account, owner })
        }
        "notify" => {
            let [owner, on] = p.args("<owner> on|off")?;
            Command::quiet(Request::OwnerNotify {
                account,
                owner,
                on: on_off(&on)?,
            })
        }
        "skip-drafts" => {
            let [owner, on] = p.args("<owner> on|off")?;
            Command::quiet(Request::OwnerSkipDrafts {
                account,
                owner,
                on: on_off(&on)?,
            })
        }
        "events" => match p.positional.first().map(String::as_str) {
            Some("set") => {
                let [_, owner, event, column, on] =
                    p.args("set <owner> <event> list|notify on|off")?;
                Command::new(
                    Request::OwnerEventsSet {
                        account,
                        owner,
                        event: wire(&event, "event")?,
                        column: wire(&column, "column")?,
                        on: on_off(&on)?,
                    },
                    Output::Events,
                    json,
                )
            }
            Some("copy") => {
                let [_, from_owner, to_owner] = p.args("copy <from-owner> <to-owner>")?;
                Command::new(
                    Request::OwnerEventsCopy {
                        account,
                        from_owner,
                        to_owner,
                    },
                    Output::Events,
                    json,
                )
            }
            _ => {
                let [owner] = p.args("<owner>")?;
                Command::new(
                    Request::OwnerEventsGet { account, owner },
                    Output::Events,
                    json,
                )
            }
        },
        "exclusions" => match p.positional.first().map(String::as_str) {
            Some("set") => {
                let [_, owner, kind, name, state] =
                    p.args("set <owner> repo|user <name> hidden|list-only")?;
                Command::new(
                    Request::OwnerExclusionsSet {
                        account,
                        owner,
                        kind: wire(&kind, "kind")?,
                        name,
                        state: wire(&state.replace('-', "_"), "state")?,
                    },
                    Output::Exclusions,
                    json,
                )
            }
            Some("remove") => {
                let [_, owner, kind, name] = p.args("remove <owner> repo|user <name>")?;
                Command::new(
                    Request::OwnerExclusionsRemove {
                        account,
                        owner,
                        kind: wire(&kind, "kind")?,
                        name,
                    },
                    Output::Exclusions,
                    json,
                )
            }
            _ => {
                let [owner] = p.args("<owner>")?;
                Command::new(
                    Request::OwnerExclusionsGet { account, owner },
                    Output::Exclusions,
                    json,
                )
            }
        },
        other => return Err(UsageError(format!("unknown command: owner {other}"))),
    })
}

fn config_command(sub: &str, rest: &[String]) -> Result<Command, UsageError> {
    Ok(match sub {
        "get" => {
            let p = parse(rest, &["--json"])?;
            let [key] = p.args("<key>")?;
            Command::new(Request::ConfigGet { key }, Output::Value, p.json())
        }
        "set" => {
            let p = parse(rest, &[])?;
            let [key, value] = p.args("<key> <value>")?;
            Command::quiet(Request::ConfigSet {
                key,
                value: serde_json::Value::String(value),
            })
        }
        other => return Err(UsageError(format!("unknown command: config {other}"))),
    })
}

const FILTER_FLAGS: [&str; 7] = [
    "--account",
    "--owner",
    "--search",
    "--authored",
    "--assigned",
    "--review-requested",
    "--json",
];

fn command(name: &str, rest: &[String]) -> Result<Command, UsageError> {
    Ok(match name {
        "list" => {
            let mut allowed = FILTER_FLAGS.to_vec();
            allowed.push("--snoozed");
            let p = parse(rest, &allowed)?;
            p.none()?;
            if p.owners.len() > 1 {
                return Err(UsageError("list takes one --owner".into()));
            }
            Command::new(
                Request::List {
                    account: p.account.clone(),
                    owner: p.owners.first().cloned(),
                    filter: p.filter()?,
                    search: p.search.clone(),
                    snoozed: p.has("--snoozed"),
                },
                Output::Cards,
                p.json(),
            )
        }
        "activity" => {
            let p = parse(rest, &FILTER_FLAGS)?;
            p.none()?;
            Command::new(
                Request::Activity {
                    account: p.account.clone(),
                    owners: p.owners.clone(),
                    filter: p.filter()?,
                    search: p.search.clone(),
                },
                Output::Rows,
                p.json(),
            )
        }
        "status" => {
            let p = parse(rest, &["--account", "--json"])?;
            let [pr] = p.args("<pr>")?;
            Command::new(
                Request::Status {
                    account: p.account()?,
                    pr,
                },
                Output::Card,
                p.json(),
            )
        }
        "read" => {
            let p = parse(rest, &["--all", "--account"])?;
            if p.has("--all") {
                p.none()?;
                Command::quiet(Request::ReadAll {
                    account: p.account()?,
                })
            } else {
                if p.positional.is_empty() {
                    return Err(UsageError("expected <row>... or --all".into()));
                }
                let request = Request::Read {
                    row_ids: p.positional.clone(),
                };
                // DESIGN.md, "CLI": `--account` may be left out; when given,
                // it has to name the rows' account, as with `open <row>`.
                match p.account.clone() {
                    Some(login) => Command::new(request, Output::ReadAs(login), false),
                    None => Command::quiet(request),
                }
            }
        }
        "snooze" | "unsnooze" => {
            let p = parse(rest, &["--account"])?;
            let [pr] = p.args("<pr>")?;
            let account = p.account()?;
            Command::quiet(if name == "snooze" {
                Request::Snooze { account, pr }
            } else {
                Request::Unsnooze { account, pr }
            })
        }
        "refresh" => {
            let p = parse(rest, &["--account"])?;
            p.none()?;
            Command::new(
                Request::Refresh {
                    account: p.account.clone(),
                },
                Output::Warnings,
                false,
            )
        }
        "open" => {
            let p = parse(rest, &["--account"])?;
            let [target] = p.args("<pr|row>")?;
            // A `<pr>` is `owner/repo#number`; anything else names a row.
            let request = if target.contains('/') && target.contains('#') {
                Request::Open {
                    account: Some(p.account()?),
                    pr: Some(target),
                    row: None,
                }
            } else {
                Request::Open {
                    account: p.account.clone(),
                    pr: None,
                    row: Some(target),
                }
            };
            Command::new(request, Output::Url, false)
        }
        "reset" => {
            parse(rest, &[])?.none()?;
            Command::quiet(Request::Reset)
        }
        other => return Err(UsageError(format!("unknown command: {other}"))),
    })
}

fn row_line(row: &Row) -> String {
    let unread = if row.unread { "*" } else { " " };
    let text = row.text.as_deref().unwrap_or_default().replace('\n', " ");
    format!("{unread} {} {} {text}", row.id, row.kind.as_text())
}

fn print_card(card: &Card, logins: &BTreeMap<String, String>) {
    let snoozed = if card.snoozed { " snoozed" } else { "" };
    let awaiting = if card.awaiting_review {
        " [review requested]"
    } else {
        ""
    };
    let account = logins.get(&card.account).unwrap_or(&card.account);
    println!(
        "{} [{}]{awaiting} review={} checks={} base={}{snoozed} {} ({}) account={account}",
        card.pr,
        card.state_label.as_text(),
        card.review.as_text(),
        card.checks.as_text(),
        card.base_status.as_text(),
        card.title,
        card.author
    );
    for row in &card.rows {
        println!("  {}", row_line(row));
    }
}

fn print_warning(warning: &Warning) {
    let until = warning
        .until
        .map(|at| format!(" (until {at})"))
        .unwrap_or_default();
    eprintln!(
        "warning: {} {}{until}",
        warning.kind.as_text(),
        warning.message
    );
}

/// One `token test` line: the board's mark and text.
fn test_line(result: &TestResult) -> String {
    let text = match (
        result.outcome.as_text().as_str(),
        result.item.as_text().as_str(),
    ) {
        ("ok", "account") => result.text.clone(),
        ("ok", _) => format!("✓ {}", result.text),
        ("failed", _) => format!("✗ {}", result.text),
        _ => result.text.clone(),
    };
    let url = result
        .url
        .as_ref()
        .map(|u| format!(" ({u})"))
        .unwrap_or_default();
    format!("{}: {text}{url}", result.label)
}

fn print_value(value: &serde_json::Value) {
    match value {
        serde_json::Value::String(text) => println!("{text}"),
        other => println!("{other}"),
    }
}

fn logins(socket: &Path) -> BTreeMap<String, String> {
    request::<AccountsResponse>(socket, &Request::AccountList)
        .map(|r| r.accounts.into_iter().map(|a| (a.id, a.login)).collect())
        .unwrap_or_default()
}

fn execute(socket: &Path, command: Command) -> Result<(), ClientError> {
    if command.json {
        println!("{}", request_json(socket, &command.request)?);
        return Ok(());
    }
    match command.output {
        Output::Nothing => {
            request::<AckResponse>(socket, &command.request)?;
        }
        Output::ReadAs(login) => {
            let accounts: AccountsResponse = request(socket, &Request::AccountList)?;
            let not_found = |message: String| ClientError::Remote {
                code: shiibar_gh_proto::Lenient::Known(shiibar_gh_proto::ErrorCode::NotFound),
                message,
            };
            let id = accounts
                .accounts
                .iter()
                .find(|a| a.login.eq_ignore_ascii_case(&login))
                .map(|a| a.id.clone())
                .ok_or_else(|| not_found(format!("not found: account {login}")))?;
            if let Request::Read { row_ids } = &command.request
                && let Some(other) = row_ids
                    .iter()
                    .find(|row| !row.starts_with(&format!("{id}:")))
            {
                return Err(not_found(format!("not found: row {other}")));
            }
            request::<AckResponse>(socket, &command.request)?;
        }
        Output::Warnings => {
            let response: RefreshResponse = request(socket, &command.request)?;
            response.warnings.iter().for_each(print_warning);
        }
        Output::Tests => {
            let response: TokenTestResponse = request(socket, &command.request)?;
            for result in &response.results {
                println!("{}", test_line(result));
            }
        }
        Output::Cards => {
            let response: ListResponse = request(socket, &command.request)?;
            let logins = logins(socket);
            for card in &response.cards {
                print_card(card, &logins);
            }
        }
        Output::Rows => {
            let response: ActivityResponse = request(socket, &command.request)?;
            for row in &response.rows {
                println!("{} {}", row.pr, row_line(row));
            }
        }
        Output::Card => {
            let response: StatusResponse = request(socket, &command.request)?;
            let card = response.card;
            println!("{} {}", card.pr, card.state_label.as_text());
            println!("Review: {}", card.review.as_text());
            println!("Checks: {}", card.checks.as_text());
            println!("Base: {}", card.base_status.as_text());
        }
        Output::Url => {
            let response: OpenResponse = request(socket, &command.request)?;
            println!("{}", response.url);
        }
        Output::Value => {
            let response: ConfigResponse = request(socket, &command.request)?;
            print_value(&response.value);
        }
        Output::Accounts => {
            let response: AccountsResponse = request(socket, &command.request)?;
            for a in &response.accounts {
                println!(
                    "{} id={} color={} token={} review={} unread={}",
                    a.login,
                    a.id,
                    a.color.as_text(),
                    if a.token.registered { "yes" } else { "no" },
                    a.review_count,
                    a.unread
                );
                for w in &a.warnings {
                    println!("  warning: {} {}", w.kind.as_text(), w.message);
                }
                for o in &a.owners {
                    println!("  {} kind={}", o.name, o.kind.as_text());
                }
            }
        }
        Output::Account => {
            let response: AccountResponse = request(socket, &command.request)?;
            println!("{}", response.account.login);
        }
        Output::Owners => {
            let response: AccountsResponse = request(socket, &command.request)?;
            for a in &response.accounts {
                for o in &a.owners {
                    println!(
                        "{} {} id={} kind={} enabled={} notify={} skip_drafts={} review={} prs={}",
                        a.login,
                        o.name,
                        o.id,
                        o.kind.as_text(),
                        o.enabled,
                        o.notify,
                        o.skip_drafts,
                        o.review_count,
                        o.pr_count
                    );
                }
            }
        }
        Output::Lookup => {
            let response: OwnerLookupResponse = request(socket, &command.request)?;
            println!(
                "{} {} {}",
                response.owner,
                response.kind.as_text(),
                response.id
            );
        }
        Output::Events => {
            let response: EventsResponse = request(socket, &command.request)?;
            let mark = |on: bool| if on { "on" } else { "off" };
            for kind in EventKind::ALL {
                let name = shiibar_gh_proto::Lenient::Known(kind).as_text();
                if let Some(cell) = response.events.get(&name) {
                    println!(
                        "{name} list={} notify={}",
                        mark(cell.list),
                        mark(cell.notify)
                    );
                }
            }
        }
        Output::Exclusions => {
            let response: ExclusionsResponse = request(socket, &command.request)?;
            let state = |s: &shiibar_gh_proto::Lenient<shiibar_gh_proto::ExclusionState>| {
                s.as_text().replace('_', "-")
            };
            for e in &response.exclusions.repos {
                println!("repo {} {}", e.name, state(&e.state));
            }
            for e in &response.exclusions.users {
                println!("user {} {}", e.name, state(&e.state));
            }
        }
    }
    Ok(())
}

/// `owner list --account <a>`: the account is a filter of the printout.
fn owner_list_filter(command: &Command, rest: &[String]) -> Option<String> {
    if !matches!(command.output, Output::Owners) {
        return None;
    }
    parse(rest, &["--account", "--json"]).ok()?.account
}

fn run(args: &[String]) -> u8 {
    let (first, rest) = match args {
        [] => {
            eprint!("{}", usage(""));
            return ERROR;
        }
        [first, rest @ ..] => (first.as_str(), rest),
    };
    if first == "--help" || first == "help" {
        print!("{}", usage(""));
        return OK;
    }
    let grouped = matches!(first, "config" | "account" | "token" | "owner");
    let sub = rest.first().map(String::as_str);
    let help_name = match (grouped, sub) {
        (true, Some(sub)) if sub != "--help" => format!("{first} {sub}"),
        _ => first.to_string(),
    };
    if !COMMANDS
        .iter()
        .any(|(name, _, _)| *name == help_name || name.starts_with(&format!("{help_name} ")))
    {
        eprintln!("shiibar-gh: unknown command: {help_name}");
        eprint!("{}", usage(""));
        return ERROR;
    }
    if args.iter().any(|arg| arg == "--help") {
        print!("{}", usage(&help_name));
        return OK;
    }
    if first == "version" {
        return match parse(rest, &["--json"]).and_then(|p| p.none().map(|()| p.json())) {
            Ok(json) => version(json),
            Err(UsageError(message)) => {
                eprintln!("shiibar-gh: {message}");
                eprint!("{}", usage("version"));
                ERROR
            }
        };
    }
    let parsed = match (first, sub) {
        ("account", Some(sub)) => account_command(sub, &rest[1..]),
        ("config", Some(sub)) => config_command(sub, &rest[1..]),
        ("token", Some(sub)) => token_command(sub, &rest[1..]),
        ("owner", Some(sub)) => owner_command(sub, &rest[1..]),
        ("config" | "account" | "token" | "owner", None) => {
            Err(UsageError(format!("{first} needs a subcommand")))
        }
        _ => command(first, rest),
    };
    let command = match parsed {
        Ok(command) => command,
        Err(UsageError(message)) => {
            eprintln!("shiibar-gh: {message}");
            eprint!("{}", usage(&help_name));
            return ERROR;
        }
    };
    let Some(socket) = socket_path_from_env() else {
        eprintln!("shiibar-gh: cannot resolve the state directory");
        return ERROR;
    };
    let result = match owner_list_filter(&command, rest.get(1..).unwrap_or_default()) {
        Some(login) => owner_list(&socket, &login, command.json),
        None => execute(&socket, command),
    };
    match result {
        Ok(()) => OK,
        Err(e) => {
            eprintln!("shiibar-gh: {e}");
            if e.is_not_found() { NOT_FOUND } else { ERROR }
        }
    }
}

/// DESIGN.md, "CLI": this command's version and the daemon's `info`
/// version. A daemon that does not answer is `not running` (`null`), and the
/// exit code stays 0.
fn version(json: bool) -> u8 {
    let cli = env!("CARGO_PKG_VERSION");
    let daemon = socket_path_from_env()
        .and_then(|socket| request::<InfoResponse>(&socket, &Request::Info).ok())
        .map(|info| info.version);
    if json {
        println!("{}", serde_json::json!({"cli": cli, "daemon": daemon}));
    } else {
        println!("cli: {cli}");
        println!("daemon: {}", daemon.as_deref().unwrap_or("not running"));
    }
    OK
}

/// The owners of one account. `--json` prints `{"ok":true,"owners":[...]}`.
fn owner_list(socket: &Path, login: &str, json: bool) -> Result<(), ClientError> {
    let response: AccountsResponse = request(socket, &Request::AccountList)?;
    let Some(account) = response
        .accounts
        .into_iter()
        .find(|a| a.login.eq_ignore_ascii_case(login))
    else {
        return Err(ClientError::Remote {
            code: shiibar_gh_proto::Lenient::Known(shiibar_gh_proto::ErrorCode::NotFound),
            message: format!("not found: account {login}"),
        });
    };
    if json {
        println!(
            "{}",
            serde_json::json!({"ok": true, "owners": account.owners})
        );
        return Ok(());
    }
    for o in &account.owners {
        println!(
            "{} {} id={} kind={} enabled={} notify={} skip_drafts={} review={} prs={}",
            account.login,
            o.name,
            o.id,
            o.kind.as_text(),
            o.enabled,
            o.notify,
            o.skip_drafts,
            o.review_count,
            o.pr_count
        );
    }
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    ExitCode::from(run(&args))
}

#[cfg(test)]
mod tests {
    use super::*;
    use shiibar_gh_proto::{Lenient, TestItem, TestOutcome};

    fn result(item: TestItem, outcome: TestOutcome, text: &str) -> TestResult {
        TestResult {
            item: Lenient::Known(item),
            label: "Scopes".into(),
            owner: None,
            outcome: Lenient::Known(outcome),
            text: text.into(),
            url: None,
        }
    }

    #[test]
    fn a_test_line_shows_the_mark_of_the_board() {
        let cases = [
            (
                result(TestItem::Scopes, TestOutcome::Failed, "Missing (read:org)"),
                "Scopes: ✗ Missing (read:org)",
            ),
            (
                result(TestItem::Scopes, TestOutcome::Ok, "OK"),
                "Scopes: ✓ OK",
            ),
            (
                result(TestItem::Account, TestOutcome::Ok, "bufferings"),
                "Scopes: bufferings",
            ),
            (
                result(TestItem::Owner, TestOutcome::CantCheck, "Can't check"),
                "Scopes: Can't check",
            ),
        ];
        for (result, line) in cases {
            assert_eq!(test_line(&result), line);
        }
    }

    #[test]
    fn a_command_about_an_owner_needs_the_account() {
        let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(owner_command("enable", &args(&["org"])).is_err());
        assert!(owner_command("enable", &args(&["org", "--account", "me"])).is_ok());
        assert!(command("snooze", &args(&["o/r#1"])).is_err());
        assert!(command("read", &args(&["row"])).is_ok());
        assert!(command("read", &args(&["--all"])).is_err());
        assert!(command("read", &args(&["--all", "--account", "me"])).is_ok());
        assert!(command("read", &args(&[])).is_err());
        assert!(command("list", &args(&["--authored", "--assigned"])).is_err());
    }

    #[test]
    fn the_0_2_todo_commands_are_gone() {
        let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(command("done", &args(&["row"])).is_err());
        assert!(command("todo", &args(&["row"])).is_err());
        assert!(command("list", &args(&["--todo"])).is_err());
        assert!(command("activity", &args(&["--todo"])).is_err());
        assert!(
            owner_command(
                "events",
                &args(&["set", "o", "mentioned", "todo", "on", "--account", "me"])
            )
            .is_err()
        );
    }

    #[test]
    fn search_takes_one_value() {
        let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let list = command("list", &args(&["--search", "api #407"]))
            .ok()
            .unwrap();
        assert!(matches!(
            list.request,
            Request::List { search: Some(ref s), .. } if s == "api #407"
        ));
        assert!(command("list", &args(&["--search"])).is_err());
        assert!(command("activity", &args(&["--search", "a", "--search", "b"])).is_err());
    }
}
