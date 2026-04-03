use chrono::{DateTime, Duration as ChronoDuration, Utc};
use std::time::{Duration, Instant};

const BOUNDED_WAKE_PROTECTION_SECS: u64 = 30;
const BOUNDED_WAKE_PROTECTION: Duration = Duration::from_secs(BOUNDED_WAKE_PROTECTION_SECS);
const MAX_SLEEP_ADJUSTMENT_HOURS: i64 = 24;
const STALE_SLEEP_SIGNAL_DEBOUNCE: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PowerState {
    Awake,
    Sleeping,
}

pub struct SleepTracker {
    state: PowerState,
    sleep_started_at: Option<DateTime<Utc>>,
    cumulative_sleep: ChronoDuration,
    last_wake_at: Option<Instant>,
    wake_protection_until: Option<Instant>,
    generation: u64,
}

impl SleepTracker {
    #[must_use]
    pub fn new() -> Self {
        Self {
            state: PowerState::Awake,
            sleep_started_at: None,
            cumulative_sleep: ChronoDuration::zero(),
            last_wake_at: None,
            wake_protection_until: None,
            generation: 0,
        }
    }

    pub fn report_sleep(&mut self) {
        self.clear_expired_wake_protection();
        self.enforce_sanity_cap();
        if self.state == PowerState::Sleeping {
            return;
        }

        let now = Instant::now();
        if self.last_wake_at.is_some_and(|last_wake_at| {
            now.duration_since(last_wake_at) < STALE_SLEEP_SIGNAL_DEBOUNCE
        }) {
            return;
        }

        self.state = PowerState::Sleeping;
        self.sleep_started_at = Some(Utc::now());
        self.wake_protection_until = None;
        self.generation = self.generation.saturating_add(1);
    }

    pub fn report_wake(&mut self) {
        self.clear_expired_wake_protection();
        let now = Instant::now();
        match (self.state, self.sleep_started_at.take()) {
            (PowerState::Sleeping, Some(sleep_started_at)) => {
                let elapsed = Utc::now().signed_duration_since(sleep_started_at);
                if elapsed > ChronoDuration::zero() {
                    self.cumulative_sleep += elapsed;
                }
                self.wake_protection_until = None;
            }
            _ => {
                self.wake_protection_until = now.checked_add(BOUNDED_WAKE_PROTECTION);
            }
        }

        self.state = PowerState::Awake;
        self.last_wake_at = Some(now);
        self.enforce_sanity_cap();
        self.generation = self.generation.saturating_add(1);
    }

    #[must_use]
    pub fn adjusted_now(&self) -> DateTime<Utc> {
        Utc::now() - self.sanitized_adjustment()
    }

    #[must_use]
    pub fn generation(&self) -> u64 {
        self.generation
    }

    fn active_sleep_elapsed(&self) -> ChronoDuration {
        if self.state != PowerState::Sleeping {
            return ChronoDuration::zero();
        }

        self.sleep_started_at
            .map(|sleep_started_at| Utc::now().signed_duration_since(sleep_started_at))
            .filter(|elapsed| *elapsed > ChronoDuration::zero())
            .unwrap_or_else(ChronoDuration::zero)
    }

    fn total_adjustment(&self) -> ChronoDuration {
        self.cumulative_sleep + self.active_sleep_elapsed()
    }

    fn wake_protection_adjustment(&self) -> ChronoDuration {
        match self.wake_protection_until {
            Some(wake_protection_until) if Instant::now() < wake_protection_until => {
                ChronoDuration::seconds(BOUNDED_WAKE_PROTECTION_SECS as i64)
            }
            _ => ChronoDuration::zero(),
        }
    }

    fn sanitized_adjustment(&self) -> ChronoDuration {
        let total_adjustment = self
            .total_adjustment()
            .max(self.wake_protection_adjustment());
        if total_adjustment > ChronoDuration::hours(MAX_SLEEP_ADJUSTMENT_HOURS) {
            ChronoDuration::zero()
        } else {
            total_adjustment
        }
    }

    fn enforce_sanity_cap(&mut self) {
        if self.total_adjustment() <= ChronoDuration::hours(MAX_SLEEP_ADJUSTMENT_HOURS) {
            return;
        }

        self.state = PowerState::Awake;
        self.sleep_started_at = None;
        self.cumulative_sleep = ChronoDuration::zero();
        self.wake_protection_until = None;
    }

    fn clear_expired_wake_protection(&mut self) {
        if self
            .wake_protection_until
            .is_some_and(|wake_protection_until| Instant::now() >= wake_protection_until)
        {
            self.wake_protection_until = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc_seconds_ago(seconds: i64) -> DateTime<Utc> {
        Utc::now() - ChronoDuration::seconds(seconds)
    }

    fn instant_seconds_ago(seconds: u64) -> Instant {
        Instant::now()
            .checked_sub(Duration::from_secs(seconds))
            .expect("instant subtraction should succeed")
    }

    fn instant_seconds_from_now(seconds: u64) -> Instant {
        Instant::now()
            .checked_add(Duration::from_secs(seconds))
            .expect("instant addition should succeed")
    }

    fn duration_since(adjusted: DateTime<Utc>) -> ChronoDuration {
        Utc::now().signed_duration_since(adjusted)
    }

    #[test]
    fn active_sleep_elapsed_uses_wall_clock_time() {
        // We intentionally use wall clock here because Instant on macOS is backed
        // by CLOCK_UPTIME_RAW, which does not advance while the machine sleeps.
        let tracker = SleepTracker {
            state: PowerState::Sleeping,
            sleep_started_at: Some(utc_seconds_ago(3)),
            cumulative_sleep: ChronoDuration::zero(),
            last_wake_at: None,
            wake_protection_until: None,
            generation: 0,
        };

        let offset = duration_since(tracker.adjusted_now());
        assert!(offset >= ChronoDuration::seconds(3));
        assert!(offset < ChronoDuration::seconds(4));
    }

    #[test]
    fn awake_sleep_wake_cycle_returns_to_awake() {
        let mut tracker = SleepTracker::new();

        tracker.report_sleep();
        tracker.sleep_started_at = Some(utc_seconds_ago(5));
        tracker.report_wake();

        assert_eq!(tracker.state, PowerState::Awake);
        assert!(tracker.sleep_started_at.is_none());
        assert!(tracker.cumulative_sleep >= ChronoDuration::seconds(5));
        assert!(tracker.cumulative_sleep < ChronoDuration::seconds(6));
    }

    #[test]
    fn adjusted_now_uses_cumulative_sleep_offset() {
        let tracker = SleepTracker {
            state: PowerState::Awake,
            sleep_started_at: None,
            cumulative_sleep: ChronoDuration::seconds(5),
            last_wake_at: None,
            wake_protection_until: None,
            generation: 0,
        };

        let offset = duration_since(tracker.adjusted_now());
        assert!(offset >= ChronoDuration::seconds(5));
        assert!(offset < ChronoDuration::seconds(6));
    }

    #[test]
    fn adjusted_now_during_active_sleep_includes_elapsed_sleep() {
        let tracker = SleepTracker {
            state: PowerState::Sleeping,
            sleep_started_at: Some(utc_seconds_ago(3)),
            cumulative_sleep: ChronoDuration::seconds(5),
            last_wake_at: None,
            wake_protection_until: None,
            generation: 0,
        };

        let offset = duration_since(tracker.adjusted_now());
        assert!(offset >= ChronoDuration::seconds(8));
        assert!(offset < ChronoDuration::seconds(9));
    }

    #[test]
    fn wake_without_sleep_installs_bounded_protection() {
        let mut tracker = SleepTracker::new();

        tracker.report_wake();

        assert_eq!(tracker.state, PowerState::Awake);
        assert!(tracker.sleep_started_at.is_none());
        assert_eq!(tracker.cumulative_sleep, ChronoDuration::zero());
        assert!(tracker.wake_protection_until.is_some());
        let offset = duration_since(tracker.adjusted_now());
        assert!(offset >= ChronoDuration::seconds(30));
        assert!(offset < ChronoDuration::seconds(31));
        assert_eq!(tracker.generation(), 1);
    }

    #[test]
    fn wake_without_sleep_protection_expires() {
        let tracker = SleepTracker {
            state: PowerState::Awake,
            sleep_started_at: None,
            cumulative_sleep: ChronoDuration::zero(),
            last_wake_at: None,
            wake_protection_until: Some(instant_seconds_ago(31)),
            generation: 0,
        };

        assert!(duration_since(tracker.adjusted_now()) < ChronoDuration::seconds(1));
    }

    #[test]
    fn sanity_cap_resets_tracker_after_excessive_sleep() {
        let mut tracker = SleepTracker::new();
        tracker.state = PowerState::Sleeping;
        tracker.sleep_started_at = Some(utc_seconds_ago(25 * 60 * 60));

        tracker.report_wake();

        assert_eq!(tracker.state, PowerState::Awake);
        assert!(tracker.sleep_started_at.is_none());
        assert_eq!(tracker.cumulative_sleep, ChronoDuration::zero());
        assert!(duration_since(tracker.adjusted_now()) < ChronoDuration::seconds(1));
    }

    #[test]
    fn double_sleep_is_no_op() {
        let mut tracker = SleepTracker::new();

        tracker.report_sleep();
        let first_generation = tracker.generation();
        let first_started_at = tracker.sleep_started_at;
        tracker.report_sleep();

        assert_eq!(tracker.state, PowerState::Sleeping);
        assert_eq!(tracker.generation(), first_generation);
        assert_eq!(tracker.sleep_started_at, first_started_at);
    }

    #[test]
    fn double_wake_installs_bounded_protection() {
        let mut tracker = SleepTracker::new();

        tracker.report_sleep();
        tracker.sleep_started_at = Some(utc_seconds_ago(5));
        tracker.report_wake();
        tracker.report_wake();

        assert_eq!(tracker.state, PowerState::Awake);
        assert!(tracker.sleep_started_at.is_none());
        assert!(tracker.cumulative_sleep >= ChronoDuration::seconds(5));
        assert!(tracker.cumulative_sleep < ChronoDuration::seconds(6));
        assert!(tracker.wake_protection_until.is_some());
        let offset = duration_since(tracker.adjusted_now());
        assert!(offset >= ChronoDuration::seconds(30));
        assert!(offset < ChronoDuration::seconds(31));
        assert_eq!(tracker.generation(), 3);
    }

    #[test]
    fn sleep_within_debounce_window_after_wake_is_rejected() {
        let mut tracker = SleepTracker {
            state: PowerState::Awake,
            sleep_started_at: None,
            cumulative_sleep: ChronoDuration::zero(),
            last_wake_at: Some(instant_seconds_ago(4)),
            wake_protection_until: None,
            generation: 7,
        };

        tracker.report_sleep();

        assert_eq!(tracker.state, PowerState::Awake);
        assert!(tracker.sleep_started_at.is_none());
        assert_eq!(tracker.generation(), 7);
    }

    #[test]
    fn sleep_after_debounce_window_is_accepted() {
        let mut tracker = SleepTracker {
            state: PowerState::Awake,
            sleep_started_at: None,
            cumulative_sleep: ChronoDuration::zero(),
            last_wake_at: Some(instant_seconds_ago(6)),
            wake_protection_until: Some(instant_seconds_from_now(24)),
            generation: 11,
        };

        tracker.report_sleep();

        assert_eq!(tracker.state, PowerState::Sleeping);
        assert!(tracker.sleep_started_at.is_some());
        assert!(tracker.wake_protection_until.is_none());
        assert_eq!(tracker.generation(), 12);
    }
}
