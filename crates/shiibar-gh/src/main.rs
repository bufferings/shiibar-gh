//! shiibar-gh: command line client of the daemon. Every command is one request
//! over the socket. DESIGN.md, sections "CLI (AI integration)" and "CLI exit
//! codes".

use shiibar_gh_client::{ClientError, request, request_json, socket_path_from_env};
use shiibar_gh_proto::{
    AccountResponse, AccountsResponse, AckResponse, ActivityResponse, At, Card, ConfigResponse,
    DismissedFilter, EventKind, EventsResponse, InfoResponse, ListResponse, MuteKind,
    MutesResponse, OpenResponse, OwnerLookupResponse, PlaceTab, PrFilter, RefreshResponse, Request,
    Row, Section, StatusResponse, Tab, TestResult, TokenTestResponse, Warning,
};
use std::collections::BTreeMap;
use std::io::{BufRead, IsTerminal};
use std::path::Path;
use std::process::ExitCode;

const OK: u8 = 0;
const ERROR: u8 = 1;
const NOT_FOUND: u8 = 2;

/// `(command words, arguments, what it does)`.
const COMMANDS: [(&str, &str, &str); 33] = [
    (
        "list",
        "[--account <a>] [--tab all|review|mine] [--owner <o>] [--authored|--assigned|--review-requested] [--search <text>] [--dismissed] [--json]",
        "Print the PR cards of a tab (default all). all: by owner, open PRs first,\n      \
         then the most recently updated; review: Doing, Todo, Waiting, Done in\n      \
         order; mine: in order, then Done. --dismissed prints the Dismissed list\n      \
         instead, newest first (--tab is ignored). Marks: [review:todo] or [mine]\n      \
         for the place, [review requested] for a PR awaiting your review, [muted],\n      \
         and the days left of a dismissed card. --search keeps the PRs where every\n      \
         word of <text> matches",
    ),
    (
        "status",
        "<pr> --account <a> [--json]",
        "Print the state label and Review, Checks and Base of a PR",
    ),
    (
        "activity",
        "[--account <a>] [--owner <o>]... [--authored|--assigned|--review-requested] [--search <text>] [--json]",
        "Print the rows of the cards that are not dismissed, newest first",
    ),
    (
        "read",
        "<row>... [--account <a>] | --all --account <a>",
        "Mark rows as read; --all marks every row of the account except those of\n      \
         dismissed PRs. With rows, --account must name their account",
    ),
    (
        "place",
        "<pr> review doing|todo|waiting [--top|--bottom|--before <pr>] --account <a> | <pr> review done --account <a> | <pr> mine [--top|--bottom|--before <pr>] --account <a> | <pr> mine done --account <a> | <pr> none --account <a>",
        "Put a PR in a section of Review, in Mine, in the Done of either, or in\n      \
         neither. Without a position it goes to the end, or to the top of todo\n      \
         from doing or waiting. Done takes no position: newest first by the time\n      \
         a card entered it. A merged or closed PR not in Review or Mine goes\n      \
         straight to Done",
    ),
    (
        "dismiss",
        "<pr> --account <a> [--json]",
        "Dismiss a PR: it leaves the lists for the Dismissed list",
    ),
    (
        "restore",
        "<pr> --account <a> [--json]",
        "Bring a dismissed PR back to its place",
    ),
    (
        "mute",
        "pr|repo|user <name> --account <a>",
        "Mute a pull request (owner/repo#number), a repository (owner/repo) or a\n      \
         user (login): its cards turn gray and only mentions notify",
    ),
    ("unmute", "pr|repo|user <name> --account <a>", "End a Mute"),
    (
        "mutes",
        "--account <a> [--json]",
        "Print the Mute lists of an account",
    ),
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
         status_interval_minutes, reactions_interval_minutes,\n      \
         auto_dismiss_after_days, dismissed_keep_days",
    ),
    (
        "config set",
        "<key> <value>",
        "Change a setting (text_size is a whole number from 9 to 18,\n      \
         auto_dismiss_after_days at least 0, dismissed_keep_days at least 1)",
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
        "Remove an account, its owners, PRs, mutes and its token",
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
        "Remove an owner and its PRs, places and settings",
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
    /// `--tab` and `--before`.
    values: BTreeMap<String, String>,
    positional: Vec<String>,
}

/// `allowed` lists the bare flags; `--account`, `--owner`, `--search`,
/// `--tab` and `--before` take a value when listed.
fn parse(args: &[String], allowed: &[&str]) -> Result<Parsed, UsageError> {
    let mut parsed = Parsed::default();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--account" | "--owner" | "--search" | "--tab" | "--before"
                if allowed.contains(&arg.as_str()) =>
            {
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
                    "--tab" | "--before" if parsed.values.contains_key(arg.as_str()) => {
                        return Err(UsageError(format!("{arg} is given twice")));
                    }
                    "--tab" | "--before" => {
                        parsed.values.insert(arg.clone(), value);
                    }
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
    /// A card answer (`place`, `dismiss`, `restore`): its PR and place.
    Placed,
    Mutes,
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
            allowed.extend(["--tab", "--dismissed"]);
            let p = parse(rest, &allowed)?;
            p.none()?;
            if p.owners.len() > 1 {
                return Err(UsageError("list takes one --owner".into()));
            }
            let tab: Tab = match p.values.get("--tab") {
                Some(tab) => wire(tab, "tab")?,
                None => Tab::All,
            };
            Command::new(
                Request::List {
                    account: p.account.clone(),
                    tab,
                    owner: p.owners.first().cloned(),
                    filter: p.filter()?,
                    search: p.search.clone(),
                    dismissed: if p.has("--dismissed") {
                        DismissedFilter::Only
                    } else {
                        DismissedFilter::Exclude
                    },
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
        "place" => place_command(rest)?,
        "dismiss" | "restore" => {
            let p = parse(rest, &["--account", "--json"])?;
            let [pr] = p.args("<pr>")?;
            let account = p.account()?;
            let request = if name == "dismiss" {
                Request::Dismiss { account, pr }
            } else {
                Request::Restore { account, pr }
            };
            Command::new(request, Output::Placed, p.json())
        }
        "mute" | "unmute" => {
            let p = parse(rest, &["--account", "--json"])?;
            let [kind, name_arg] = p.args("pr|repo|user <name>")?;
            let account = p.account()?;
            let kind: MuteKind = wire(&kind, "kind")?;
            let request = if name == "mute" {
                Request::Mute {
                    account,
                    kind,
                    name: name_arg,
                }
            } else {
                Request::Unmute {
                    account,
                    kind,
                    name: name_arg,
                }
            };
            Command::new(request, Output::Nothing, p.json())
        }
        "mutes" => {
            let p = parse(rest, &["--account", "--json"])?;
            p.none()?;
            Command::new(
                Request::MutesGet {
                    account: p.account()?,
                },
                Output::Mutes,
                p.json(),
            )
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

/// `place <pr> review <section> | mine [done] | none` with an optional
/// position.
fn place_command(rest: &[String]) -> Result<Command, UsageError> {
    let p = parse(
        rest,
        &["--account", "--top", "--bottom", "--before", "--json"],
    )?;
    let account = p.account()?;
    let (pr, tab, section) = match p.positional.as_slice() {
        [pr, tab, section] if tab == "review" => (pr.clone(), PlaceTab::Review, Some(section)),
        [pr, tab, section] if tab == "mine" && section == "done" => {
            (pr.clone(), PlaceTab::Mine, Some(section))
        }
        [pr, tab] if tab == "mine" => (pr.clone(), PlaceTab::Mine, None),
        [pr, tab] if tab == "none" => (pr.clone(), PlaceTab::None, None),
        _ => {
            return Err(UsageError(
                "expected <pr> review doing|todo|waiting|done, <pr> mine [done] or <pr> none"
                    .into(),
            ));
        }
    };
    let section = match section {
        Some(text) => {
            let section: Section = wire(text, "section")?;
            if !matches!(
                section,
                Section::Doing | Section::Todo | Section::Waiting | Section::Done
            ) {
                return Err(UsageError(format!(
                    "review takes doing, todo, waiting or done, not {text}"
                )));
            }
            Some(section)
        }
        None => None,
    };
    let before = p.values.get("--before").cloned();
    let at = match (p.has("--top"), p.has("--bottom")) {
        (true, true) => return Err(UsageError("--top and --bottom exclude each other".into())),
        (true, false) => Some(At::Top),
        (false, true) => Some(At::Bottom),
        (false, false) => None,
    };
    if before.is_some() && at.is_some() {
        return Err(UsageError("--before excludes --top and --bottom".into()));
    }
    if tab == PlaceTab::None && (before.is_some() || at.is_some()) {
        return Err(UsageError("place none takes no position".into()));
    }
    if section == Some(Section::Done) && (before.is_some() || at.is_some()) {
        return Err(UsageError(
            "done takes no position: it keeps the newest first".into(),
        ));
    }
    Ok(Command::new(
        Request::Place {
            account,
            pr,
            tab,
            section,
            before,
            at,
        },
        Output::Placed,
        p.json(),
    ))
}

fn row_line(row: &Row) -> String {
    let unread = if row.unread { "*" } else { " " };
    let muted = if row.muted { " [muted]" } else { "" };
    let text = row.text.as_deref().unwrap_or_default().replace('\n', " ");
    format!("{unread} {} {}{muted} {text}", row.id, row.kind.as_text())
}

/// `[review:todo]`, `[mine]` or `[mine:done]`.
fn place_mark(card: &Card) -> String {
    match &card.placement {
        None => String::new(),
        Some(p) => {
            let tab = p.tab.as_text();
            let section = p.section.as_text();
            if tab == "mine" && section == "main" {
                " [mine]".into()
            } else {
                format!(" [{tab}:{section}]")
            }
        }
    }
}

/// DESIGN.md, "Dismissed list": whole days left, rounded up; past the end
/// while the popover holds it, `0 days left`.
fn days_left(expires_at: i64, now: i64) -> String {
    let left = expires_at - now;
    let days = if left <= 0 {
        0
    } else {
        (left + 86_399) / 86_400
    };
    if days == 1 {
        "1 day left".into()
    } else {
        format!("{days} days left")
    }
}

fn now_epoch() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn card_line(card: &Card, logins: &BTreeMap<String, String>) -> String {
    let awaiting = if card.awaiting_review {
        " [review requested]"
    } else {
        ""
    };
    let muted = if card.muted.is_empty() {
        ""
    } else {
        " [muted]"
    };
    let left = card
        .dismiss_expires_at
        .map(|at| format!(" [{}]", days_left(at, now_epoch())))
        .unwrap_or_default();
    let account = logins.get(&card.account).unwrap_or(&card.account);
    format!(
        "{} [{}]{}{awaiting}{muted}{left} review={} checks={} base={} {} ({}) account={account}",
        card.pr,
        card.state_label.as_text(),
        place_mark(card),
        card.review.as_text(),
        card.checks.as_text(),
        card.base_status.as_text(),
        card.title,
        card.author
    )
}

fn print_card(card: &Card, logins: &BTreeMap<String, String>) {
    println!("{}", card_line(card, logins));
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
        Output::Placed => {
            let response: StatusResponse = request(socket, &command.request)?;
            let card = response.card;
            let place = place_mark(&card);
            let dismissed = if card.dismissed_at.is_some() {
                " [dismissed]"
            } else {
                ""
            };
            println!("{}{place}{dismissed}", card.pr);
        }
        Output::Mutes => {
            let response: MutesResponse = request(socket, &command.request)?;
            for name in &response.mutes.repos {
                println!("repo {name}");
            }
            for name in &response.mutes.users {
                println!("user {name}");
            }
            for name in &response.mutes.prs {
                println!("pr {name}");
            }
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
                    "{} id={} color={} token={} unread={}",
                    a.login,
                    a.id,
                    a.color.as_text(),
                    if a.token.registered { "yes" } else { "no" },
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
                        "{} {} id={} kind={} enabled={} notify={} skip_drafts={} prs={}",
                        a.login,
                        o.name,
                        o.id,
                        o.kind.as_text(),
                        o.enabled,
                        o.notify,
                        o.skip_drafts,
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
            "{} {} id={} kind={} enabled={} notify={} skip_drafts={} prs={}",
            account.login,
            o.name,
            o.id,
            o.kind.as_text(),
            o.enabled,
            o.notify,
            o.skip_drafts,
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
        assert!(command("dismiss", &args(&["o/r#1"])).is_err());
        assert!(command("dismiss", &args(&["o/r#1", "--account", "me"])).is_ok());
        assert!(command("place", &args(&["o/r#1", "mine"])).is_err());
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
    fn the_0_3_commands_are_gone() {
        let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(command("snooze", &args(&["o/r#1", "--account", "me"])).is_err());
        assert!(command("unsnooze", &args(&["o/r#1", "--account", "me"])).is_err());
        assert!(command("list", &args(&["--snoozed"])).is_err());
        assert!(owner_command("exclusions", &args(&["o", "--account", "me"])).is_err());
    }

    #[test]
    fn place_reads_its_section_and_position() {
        let args = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let place = command(
            "place",
            &args(&[
                "o/r#1",
                "review",
                "todo",
                "--before",
                "o/r#2",
                "--account",
                "me",
            ]),
        )
        .ok()
        .unwrap();
        assert!(matches!(
            place.request,
            Request::Place { tab: PlaceTab::Review, section: Some(Section::Todo), before: Some(ref b), at: None, .. } if b == "o/r#2"
        ));
        let top = command(
            "place",
            &args(&["o/r#1", "mine", "--top", "--account", "me"]),
        )
        .ok()
        .unwrap();
        assert!(matches!(
            top.request,
            Request::Place {
                tab: PlaceTab::Mine,
                section: None,
                at: Some(At::Top),
                ..
            }
        ));
        for (words, tab) in [
            (
                &["o/r#1", "review", "done", "--account", "me"][..],
                PlaceTab::Review,
            ),
            (
                &["o/r#1", "mine", "done", "--account", "me"],
                PlaceTab::Mine,
            ),
        ] {
            let done = command("place", &args(words)).ok().unwrap();
            assert!(
                matches!(done.request, Request::Place { tab: t, section: Some(Section::Done), before: None, at: None, .. } if t == tab),
                "{words:?}"
            );
        }
        for bad in [
            &["o/r#1", "review", "done", "--top", "--account", "me"][..],
            &[
                "o/r#1",
                "mine",
                "done",
                "--before",
                "o/r#2",
                "--account",
                "me",
            ],
            &["o/r#1", "mine", "main", "--account", "me"],
            &["o/r#1", "review", "main", "--account", "me"],
            &["o/r#1", "review", "--account", "me"],
            &["o/r#1", "mine", "--top", "--bottom", "--account", "me"],
            &["o/r#1", "none", "--top", "--account", "me"],
            &[
                "o/r#1",
                "mine",
                "--top",
                "--before",
                "o/r#2",
                "--account",
                "me",
            ],
        ] {
            assert!(command("place", &args(bad)).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn days_left_round_up() {
        assert_eq!(days_left(1_000 + 86_400 * 6, 1_000), "6 days left");
        assert_eq!(days_left(1_000 + 86_400 * 5 + 1, 1_000), "6 days left");
        assert_eq!(days_left(1_000 + 10, 1_000), "1 day left");
        assert_eq!(days_left(1_000, 1_000), "0 days left");
        assert_eq!(days_left(900, 1_000), "0 days left");
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
