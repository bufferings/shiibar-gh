//! The daemon's time: the wall clock and the Mac's current time zone, or a
//! fixed time and zone in a `dev-ingest` build.

use jiff::Timestamp;
use jiff::tz::TimeZone;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone)]
pub struct Now {
    pub at: i64,
    pub tz: TimeZone,
}

impl Now {
    pub fn fixed(at: i64, tz: &str) -> Result<Self, String> {
        let tz = TimeZone::get(tz).map_err(|e| format!("unknown time zone: {e}"))?;
        Timestamp::from_second(at).map_err(|e| format!("time out of range: {e}"))?;
        Ok(Self { at, tz })
    }
}

#[derive(Debug, Default)]
pub struct Clock {
    fixed: Option<Now>,
}

impl Clock {
    pub fn system() -> Self {
        Self::default()
    }

    /// A `dev-ingest` build with a fixed time.
    pub fn is_fixed(&self) -> bool {
        self.fixed.is_some()
    }

    pub fn fix(&mut self, now: Now) {
        self.fixed = Some(now);
    }

    pub fn now(&self) -> Now {
        if let Some(now) = &self.fixed {
            return now.clone();
        }
        let at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs() as i64);
        Now {
            at,
            tz: TimeZone::system(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unknown_zone_is_refused() {
        assert!(Now::fixed(0, "Mars/Olympus").is_err());
    }
}
