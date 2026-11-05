//! shiibar-ghd entry point: arguments and wiring only.

use shiibar_gh_proto::paths::StateDir;
use shiibar_ghd::clock::Clock;
use shiibar_ghd::github::Api;
use shiibar_ghd::keychain::Keychain;
use shiibar_ghd::{logging, server};
use std::process::ExitCode;
use std::sync::Arc;

/// The Keychain and GitHub of the default build: the real ones.
#[cfg(not(feature = "dev-ingest"))]
fn services(_: &StateDir) -> Result<(Arc<dyn Keychain>, Option<Api>), String> {
    let api = Api::new(shiibar_ghd::github::DEFAULT_BASE, false)
        .map_err(|e| format!("cannot set up the HTTP client: {e}"))?;
    Ok((Arc::new(shiibar_ghd::keychain::SystemKeychain), Some(api)))
}

/// A `dev-ingest` build never reaches the real Keychain or GitHub: a JSON
/// file under the state directory stands in for the Keychain, and only a
/// loopback URL for GitHub. Without them it has no Keychain and fetches
/// nothing. docs/tasks/M2.md, "How to test".
#[cfg(feature = "dev-ingest")]
fn services(dir: &StateDir) -> Result<(Arc<dyn Keychain>, Option<Api>), String> {
    use shiibar_ghd::keychain::{FileKeychain, NoKeychain};
    let keychain: Arc<dyn Keychain> = match std::env::var_os("SHIIBAR_GH_DEV_KEYCHAIN") {
        Some(path) => {
            let path = std::path::PathBuf::from(path);
            let inside = path.starts_with(dir.root())
                && !path
                    .components()
                    .any(|c| matches!(c, std::path::Component::ParentDir));
            if !inside {
                return Err(
                    "SHIIBAR_GH_DEV_KEYCHAIN must be a file under the state directory".into(),
                );
            }
            logging::info(format_args!(
                "dev-ingest: test Keychain at {}",
                path.display()
            ));
            Arc::new(FileKeychain::new(path))
        }
        None => {
            logging::info(format_args!("dev-ingest: no Keychain"));
            Arc::new(NoKeychain)
        }
    };
    let api = match std::env::var("SHIIBAR_GH_DEV_GITHUB_URL") {
        Ok(url) => {
            if !is_loopback(&url) {
                return Err("SHIIBAR_GH_DEV_GITHUB_URL must be a loopback http URL".into());
            }
            logging::info(format_args!("dev-ingest: test GitHub at {url}"));
            Some(Api::new(&url, true).map_err(|e| format!("cannot set up the HTTP client: {e}"))?)
        }
        Err(_) => {
            logging::info(format_args!("dev-ingest: no GitHub; nothing is fetched"));
            None
        }
    };
    Ok((keychain, api))
}

#[cfg(feature = "dev-ingest")]
fn is_loopback(url: &str) -> bool {
    let Ok(url) = reqwest::Url::parse(url) else {
        return false;
    };
    if url.scheme() != "http" {
        return false;
    }
    match url.host_str() {
        Some("localhost") => true,
        Some(host) => host
            .trim_start_matches('[')
            .trim_end_matches(']')
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback()),
        None => false,
    }
}

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
    let (keychain, api) = match services(&dir) {
        Ok(services) => services,
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
    match runtime.block_on(server::run(dir, clock, keychain, api)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("shiibar-ghd: {e:#}");
            ExitCode::from(1)
        }
    }
}
