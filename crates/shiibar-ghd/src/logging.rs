//! Leveled logging to stderr, one line per message that starts with the local
//! time and its offset (DESIGN.md, "Logs"). Level from `SHIIBAR_GH_LOG`
//! (`error`, `warn`, `info` or `debug`), default `info` (DESIGN.md,
//! "Constants").

use std::fmt::Arguments;
use std::sync::atomic::{AtomicU8, Ordering};

const ERROR: u8 = 0;
const WARN: u8 = 1;
const INFO: u8 = 2;
const DEBUG: u8 = 3;

static LEVEL: AtomicU8 = AtomicU8::new(INFO);

pub fn init_from_env() {
    let level = match std::env::var("SHIIBAR_GH_LOG").as_deref() {
        Ok("error") => ERROR,
        Ok("warn") => WARN,
        Ok("debug") => DEBUG,
        _ => INFO,
    };
    LEVEL.store(level, Ordering::Relaxed);
}

fn write(level: u8, label: &str, args: Arguments<'_>) {
    if level <= LEVEL.load(Ordering::Relaxed) {
        // `2027-01-15 08:00:00+09:00`, so a line can be matched with what
        // the owner saw on screen.
        let at = jiff::Zoned::now().strftime("%Y-%m-%d %H:%M:%S%:z");
        eprintln!("{at} shiibar-ghd {label}: {args}");
    }
}

pub fn error(args: Arguments<'_>) {
    write(ERROR, "error", args);
}

pub fn warn(args: Arguments<'_>) {
    write(WARN, "warn", args);
}

pub fn info(args: Arguments<'_>) {
    write(INFO, "info", args);
}

pub fn debug(args: Arguments<'_>) {
    write(DEBUG, "debug", args);
}
