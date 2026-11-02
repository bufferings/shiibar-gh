//! shiibar-ghd entry point: arguments and wiring only.

use shiibar_gh_proto::paths::StateDir;
use shiibar_ghd::clock::Clock;
use shiibar_ghd::{logging, server};
use std::process::ExitCode;

fn clock_from_env() -> Result<Clock, String> {
    #[cfg_attr(not(feature = "dev-ingest"), allow(unused_mut))]
    let mut clock = Clock::system();
    #[cfg(feature = "dev-ingest")]
    {
        let now = std::env::var("SHIIBAR_GH_DEV_NOW").ok();
        let tz = std::env::var("SHIIBAR_GH_DEV_TZ").ok();
        if now.is_some() || tz.is_some() {
            let at = match now {
                Some(text) => text
                    .parse()
                    .map_err(|_| "SHIIBAR_GH_DEV_NOW must be epoch seconds".to_string())?,
                None => clock.now().at,
            };
            let fixed = match tz {
                Some(name) => shiibar_ghd::clock::Now::fixed(at, &name)?,
                None => shiibar_ghd::clock::Now {
                    at,
                    tz: clock.now().tz,
                },
            };
            clock.fix(fixed);
        }
    }
    Ok(clock)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args != ["--foreground"] {
        eprintln!("usage: shiibar-ghd --foreground");
        return ExitCode::from(1);
    }
    logging::init_from_env();
    let Some(dir) = StateDir::from_env() else {
        eprintln!("shiibar-ghd: cannot resolve the state directory");
        return ExitCode::from(1);
    };
    let clock = match clock_from_env() {
        Ok(clock) => clock,
        Err(e) => {
            eprintln!("shiibar-ghd: {e}");
            return ExitCode::from(1);
        }
    };
    let runtime = match tokio::runtime::Runtime::new() {
        Ok(runtime) => runtime,
        Err(e) => {
            eprintln!("shiibar-ghd: cannot start the runtime: {e}");
            return ExitCode::from(1);
        }
    };
    match runtime.block_on(server::run(dir, clock)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("shiibar-ghd: {e:#}");
            ExitCode::from(1)
        }
    }
}
