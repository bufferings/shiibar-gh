//! The daemon's time: the wall clock and the Mac's current time zone, or a
//! fixed time and zone in a `dev-ingest` build.

use jiff::civil::Date;
use jiff::tz::TimeZone;
use jiff::{Timestamp, Zoned};
use std::time::{SystemTime, UNIX_EPOCH};

/// A Return time as hour and minute.
pub type ClockTime = (u8, u8);

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

    /// The newest occurrence of `time` at or before now.
    pub fn latest_return_at(&self, time: ClockTime) -> i64 {
        let Some(today) = self.local_date() else {
            return i64::MIN;
        };
        let today_at = self.occurrence(today, time);
        if today_at.is_some_and(|at| at <= self.at) {
            return today_at.unwrap_or(i64::MIN);
        }
        today
            .yesterday()
            .ok()
            .and_then(|day| self.occurrence(day, time))
            .unwrap_or(i64::MIN)
    }

    /// The oldest occurrence of `time` after now.
    pub fn next_return_at(&self, time: ClockTime) -> i64 {
        let Some(today) = self.local_date() else {
            return i64::MAX;
        };
        let today_at = self.occurrence(today, time);
        if today_at.is_some_and(|at| at > self.at) {
            return today_at.unwrap_or(i64::MAX);
        }
        today
            .tomorrow()
            .ok()
            .and_then(|day| self.occurrence(day, time))
            .unwrap_or(i64::MAX)
    }

    fn local_date(&self) -> Option<Date> {
        let at = Timestamp::from_second(self.at).ok()?;
        Some(at.to_zoned(self.tz.clone()).date())
    }

    /// A local time that does not exist on a daylight saving change resolves
    /// the way `jiff` documents as "compatible": after the gap.
    fn occurrence(&self, day: Date, (hour, minute): ClockTime) -> Option<i64> {
        let zoned: Zoned = day
            .at(hour as i8, minute as i8, 0, 0)
            .to_zoned(self.tz.clone())
            .ok()?;
        Some(zoned.timestamp().as_second())
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
    fn nine_oclock_in_tokyo() {
        // 2027-01-15T17:00:00+09:00
        let now = Now::fixed(1_800_000_000, "Asia/Tokyo").unwrap();
        assert_eq!(now.latest_return_at((9, 0)), 1_800_000_000 - 8 * 3600);
        assert_eq!(now.next_return_at((9, 0)), 1_800_000_000 + 16 * 3600);
    }

    #[test]
    fn the_exact_return_time_counts_as_passed() {
        let at = 1_800_000_000 + 16 * 3600;
        let now = Now::fixed(at, "Asia/Tokyo").unwrap();
        assert_eq!(now.latest_return_at((9, 0)), at);
        assert_eq!(now.next_return_at((9, 0)), at + 86_400);
    }

    #[test]
    fn a_time_inside_a_spring_forward_gap_lands_after_the_gap() {
        // New York jumped from 02:00 to 03:00 on 2027-03-14.
        let after = Timestamp::strptime("%Y-%m-%d %H:%M %z", "2027-03-14 12:00 -0400").unwrap();
        let now = Now::fixed(after.as_second(), "America/New_York").unwrap();
        let expect = Timestamp::strptime("%Y-%m-%d %H:%M %z", "2027-03-14 03:30 -0400").unwrap();
        assert_eq!(now.latest_return_at((2, 30)), expect.as_second());
    }

    #[test]
    fn an_unknown_zone_is_refused() {
        assert!(Now::fixed(0, "Mars/Olympus").is_err());
    }
}
