//! shiibar-ghd: owns local state and talks NDJSON over a Unix socket.
//!
//! `engine` holds the behavior of docs/DESIGN.md as plain state transitions
//! with no I/O, `store` saves that state in SQLite, `daemon` joins the two with
//! the subscribers, and `server` owns the socket and the startup sequence.

pub mod clock;
pub mod daemon;
pub mod engine;
pub mod logging;
pub mod model;
pub mod server;
pub mod store;
