//! shiibar-gh: command line client of the daemon. Every command is one request
//! over the socket. DESIGN.md, sections "CLI" and "CLI exit codes".

use shiibar_gh_client::{ClientError, request, request_json, socket_path_from_env};
use shiibar_gh_proto::{
    AckResponse, ActivityResponse, Card, ConfigResponse, Filter, ListResponse, OpenResponse,
    Request, Row, Scope, ScopesResponse, StatusResponse,
};
use std::path::Path;
use std::process::ExitCode;

const OK: u8 = 0;
const ERROR: u8 = 1;
const NOT_FOUND: u8 = 2;

const FILTER_FLAGS: &str =
    "[--scope <scope>] [--needs-action] [--mine|--others] [--snoozed] [--json]";

/// `(command words, arguments, what it does)`.
const COMMANDS: [(&str, &str, &str); 18] = [
    ("list", FILTER_FLAGS, "Print the PR cards"),
    (
        "status",
        "<pr> [--json]",
        "Print the state label and Review, Checks and Base of a PR",
    ),
    (
        "activity",
        FILTER_FLAGS,
        "Print the rows of the shown cards, newest first",
    ),
    ("done", "<row>", "Mark a Needs action row as done"),
    ("undone", "<row>", "Mark a Needs action row as not done"),
    ("snooze", "<pr>", "Snooze a PR until the next Return time"),
    ("unsnooze", "<pr>", "End the Snooze of a PR"),
    ("refresh", "[--scope <scope>]", "Fetch now"),
    ("open", "<pr|row>", "Print the URL of a PR or row"),
    ("config get", "<key> [--json]", "Print a setting"),
    ("config set", "<key> <value>", "Change a setting"),
    (
        "reset",
        "",
        "Set aside an unreadable database and start empty",
    ),
    ("scope list", "[--json]", "Print the scopes"),
    ("scope add", "<owner>", "Register an owner"),
    (
        "scope remove",
        "<owner>",
        "Remove an owner, keeping its state",
    ),
    ("scope enable", "<scope>", "Enable a scope"),
    ("scope disable", "<scope>", "Disable a scope"),
    (
        "scope notify",
        "<scope> on|off",
        "Turn the notifications of a scope on or off",
    ),
];

fn usage(prefix: &str) -> String {
    let mut text = String::from("usage:\n");
    for (name, args, about) in COMMANDS {
        if name == prefix || name.starts_with(&format!("{prefix} ")) || prefix.is_empty() {
            text.push_str(&format!("  shiibar-gh {name} {args}\n      {about}\n"));
        }
    }
    text
}

struct UsageError(String);

/// The split of a command's arguments into flags and positionals.
struct Parsed {
    flags: Vec<String>,
    scope: Option<String>,
    positional: Vec<String>,
}

fn parse(args: &[String], allowed: &[&str], takes_scope: bool) -> Result<Parsed, UsageError> {
    let mut parsed = Parsed {
        flags: Vec::new(),
        scope: None,
        positional: Vec::new(),
    };
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        if takes_scope && arg == "--scope" {
            let value = args
                .next()
                .ok_or_else(|| UsageError("--scope needs a value".into()))?;
            parsed.scope = Some(value.clone());
        } else if arg.starts_with("--") {
            if !allowed.contains(&arg.as_str()) {
                return Err(UsageError(format!("unknown flag: {arg}")));
            }
            parsed.flags.push(arg.clone());
        } else {
            parsed.positional.push(arg.clone());
        }
    }
    Ok(parsed)
}

impl Parsed {
    fn has(&self, flag: &str) -> bool {
        self.flags.iter().any(|f| f == flag)
    }

    fn one(&self, name: &str) -> Result<String, UsageError> {
        match self.positional.as_slice() {
            [value] => Ok(value.clone()),
            _ => Err(UsageError(format!("expected one {name}"))),
        }
    }

    fn none(&self) -> Result<(), UsageError> {
        match self.positional.first() {
            None => Ok(()),
            Some(extra) => Err(UsageError(format!("unexpected argument: {extra}"))),
        }
    }
}

fn filter(parsed: &Parsed) -> Result<Filter, UsageError> {
    parsed.none()?;
    if parsed.has("--mine") && parsed.has("--others") {
        return Err(UsageError("--mine and --others exclude each other".into()));
    }
    Ok(Filter {
        scope: parsed.scope.clone(),
        needs_action: parsed.has("--needs-action"),
        mine: parsed.has("--mine"),
        others: parsed.has("--others"),
        snoozed: parsed.has("--snoozed"),
    })
}

const FILTER_ALLOWED: [&str; 5] = [
    "--needs-action",
    "--mine",
    "--others",
    "--snoozed",
    "--json",
];

/// A `<pr>` is `owner/repo#number`; anything else names a row.
fn open_request(target: String) -> Request {
    if target.contains('/') && target.contains('#') {
        Request::Open {
            pr: Some(target),
            row: None,
        }
    } else {
        Request::Open {
            pr: None,
            row: Some(target),
        }
    }
}

enum Output {
    Nothing,
    Cards,
    Rows,
    Card,
    Url,
    Value,
    Scopes,
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
}

fn one_arg(args: &[String], name: &str) -> Result<String, UsageError> {
    parse(args, &[], false)?.one(name)
}

fn scope_command(sub: &str, rest: &[String]) -> Result<Command, UsageError> {
    Ok(match sub {
        "list" => {
            let parsed = parse(rest, &["--json"], false)?;
            parsed.none()?;
            Command {
                request: Request::ScopeList,
                output: Output::Scopes,
                json: parsed.has("--json"),
            }
        }
        "add" => Command::quiet(Request::ScopeAdd {
            owner: one_arg(rest, "owner")?,
        }),
        "remove" => Command::quiet(Request::ScopeRemove {
            owner: one_arg(rest, "owner")?,
        }),
        "enable" => Command::quiet(Request::ScopeEnable {
            scope: one_arg(rest, "scope")?,
        }),
        "disable" => Command::quiet(Request::ScopeDisable {
            scope: one_arg(rest, "scope")?,
        }),
        "notify" => match rest {
            [scope, on] if on == "on" || on == "off" => Command::quiet(Request::ScopeNotify {
                scope: scope.clone(),
                on: on == "on",
            }),
            _ => return Err(UsageError("expected <scope> on|off".into())),
        },
        other => return Err(UsageError(format!("unknown command: scope {other}"))),
    })
}

fn config_command(sub: &str, rest: &[String]) -> Result<Command, UsageError> {
    Ok(match sub {
        "get" => {
            let parsed = parse(rest, &["--json"], false)?;
            Command {
                request: Request::ConfigGet {
                    key: parsed.one("key")?,
                },
                output: Output::Value,
                json: parsed.has("--json"),
            }
        }
        "set" => match rest {
            [key, value] => Command {
                request: Request::ConfigSet {
                    key: key.clone(),
                    value: serde_json::Value::String(value.clone()),
                },
                output: Output::Nothing,
                json: false,
            },
            _ => return Err(UsageError("expected <key> <value>".into())),
        },
        other => return Err(UsageError(format!("unknown command: config {other}"))),
    })
}

fn command(name: &str, rest: &[String]) -> Result<Command, UsageError> {
    Ok(match name {
        "list" | "activity" => {
            let parsed = parse(rest, &FILTER_ALLOWED, true)?;
            let filter = filter(&parsed)?;
            let json = parsed.has("--json");
            if name == "list" {
                Command {
                    request: Request::List { filter },
                    output: Output::Cards,
                    json,
                }
            } else {
                Command {
                    request: Request::Activity { filter },
                    output: Output::Rows,
                    json,
                }
            }
        }
        "status" => {
            let parsed = parse(rest, &["--json"], false)?;
            Command {
                request: Request::Status {
                    pr: parsed.one("pr")?,
                },
                output: Output::Card,
                json: parsed.has("--json"),
            }
        }
        "done" => Command::quiet(Request::Done {
            row: one_arg(rest, "row")?,
        }),
        "undone" => Command::quiet(Request::Undone {
            row: one_arg(rest, "row")?,
        }),
        "snooze" => Command::quiet(Request::Snooze {
            pr: one_arg(rest, "pr")?,
        }),
        "unsnooze" => Command::quiet(Request::Unsnooze {
            pr: one_arg(rest, "pr")?,
        }),
        "refresh" => {
            let parsed = parse(rest, &[], true)?;
            parsed.none()?;
            Command::quiet(Request::Refresh {
                scope: parsed.scope,
            })
        }
        "open" => Command {
            request: open_request(one_arg(rest, "pr or row")?),
            output: Output::Url,
            json: false,
        },
        "reset" => {
            parse(rest, &[], false)?.none()?;
            Command::quiet(Request::Reset)
        }
        other => return Err(UsageError(format!("unknown command: {other}"))),
    })
}

fn state_text(card: &Card) -> String {
    format!(
        "review={} checks={} base={}",
        card.review.as_text(),
        card.checks.as_text(),
        card.base_status.as_text()
    )
}

fn row_line(row: &Row) -> String {
    let unread = if row.unread { "*" } else { " " };
    let done = if row.done { " done" } else { "" };
    let text = row.text.as_deref().unwrap_or_default().replace('\n', " ");
    format!(
        "{unread} {} {} [{}{done}] {text}",
        row.id,
        row.kind.as_text(),
        row.class.as_text()
    )
}

fn print_card(card: &Card) {
    let snoozed = if card.snoozed { " snoozed" } else { "" };
    println!(
        "{} [{}] {}{snoozed} {} ({})",
        card.pr,
        card.state_label.as_text(),
        state_text(card),
        card.title,
        card.author
    );
    for row in &card.rows {
        println!("  {}", row_line(row));
    }
}

fn print_scope(scope: &Scope) {
    println!(
        "{} name={} enabled={} notify={} badge={} dot={}",
        scope.id, scope.name, scope.enabled, scope.notify, scope.badge, scope.dot
    );
}

fn print_value(value: &serde_json::Value) {
    match value {
        serde_json::Value::String(text) => println!("{text}"),
        other => println!("{other}"),
    }
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
        Output::Cards => {
            let response: ListResponse = request(socket, &command.request)?;
            response.cards.iter().for_each(print_card);
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
        Output::Scopes => {
            let response: ScopesResponse = request(socket, &command.request)?;
            response.scopes.iter().for_each(print_scope);
        }
    }
    Ok(())
}

fn run(args: &[String]) -> u8 {
    let (first, rest) = match args {
        [] => {
            eprint!("{}", usage(""));
            return ERROR;
        }
        [first, rest @ ..] => (first.as_str(), rest),
    };
    if first == "--help" {
        print!("{}", usage(""));
        return OK;
    }
    let grouped = matches!(first, "config" | "scope");
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
    let parsed = match (first, sub) {
        ("scope", Some(sub)) => scope_command(sub, &rest[1..]),
        ("config", Some(sub)) => config_command(sub, &rest[1..]),
        ("scope" | "config", None) => Err(UsageError(format!("{first} needs a subcommand"))),
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
    match execute(&socket, command) {
        Ok(()) => OK,
        Err(e) => {
            eprintln!("shiibar-gh: {e}");
            if e.is_not_found() { NOT_FOUND } else { ERROR }
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    ExitCode::from(run(&args))
}
