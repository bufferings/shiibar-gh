//! Leveled logging to stderr. Level from `SHIIBAR_GH_LOG` (`error`, `info` or
//! `debug`), default `info` (DESIGN.md, section "Constants").

use std::fmt::Arguments;
use std::sync::atomic::{AtomicU8, Ordering};

const ERROR: u8 = 0;
const INFO: u8 = 1;
const DEBUG: u8 = 2;

static LEVEL: AtomicU8 = AtomicU8::new(INFO);

pub fn init_from_env() {
    let level = match std::env::var("SHIIBAR_GH_LOG").as_deref() {
        Ok("error") => ERROR,
        Ok("debug") => DEBUG,
        _ => INFO,
    };
    LEVEL.store(level, Ordering::Relaxed);
}

fn write(level: u8, label: &str, args: Arguments<'_>) {
    if level <= LEVEL.load(Ordering::Relaxed) {
        eprintln!("shiibar-ghd {label}: {args}");
    }
}

pub fn error(args: Arguments<'_>) {
    write(ERROR, "error", args);
}

pub fn info(args: Arguments<'_>) {
    write(INFO, "info", args);
}

pub fn debug(args: Arguments<'_>) {
    write(DEBUG, "debug", args);
}
