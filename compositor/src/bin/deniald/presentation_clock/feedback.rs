//! Validate optional DRM metadata before using it as physical display feedback.

use std::time::Duration;

// A completion this old cannot usefully train the live output clock. Keep
// processing its buffer retirement, but label its timing as an estimate.
const MAX_EVENT_AGE: Duration = Duration::from_secs(1);

/// DRM's scanout-position helper timestamps the end of vertical blanking.
/// At a vblank IRQ that edge may still be ahead of the current monotonic time.
/// Bound that lead by the active progressive mode, never by a generic allowance.
pub(super) fn blanking_lead_limit(
    clock_khz: u32,
    horizontal_total: u16,
    vertical_total: u16,
    vertical_active: u16,
) -> Option<Duration> {
    let blank_lines = vertical_total.checked_sub(vertical_active)?;
    if clock_khz == 0 || horizontal_total == 0 || vertical_active == 0 || blank_lines == 0 {
        return None;
    }
    let nanos = u64::from(blank_lines)
        .checked_mul(u64::from(horizontal_total))?
        .checked_mul(1_000_000)?
        .div_ceil(u64::from(clock_khz));
    Some(Duration::from_nanos(nanos))
}

#[derive(Debug, Default)]
pub(crate) struct FeedbackClock {
    last_timestamp: Option<Duration>,
    last_sequence: Option<u32>,
}

#[derive(Debug)]
pub(crate) struct ValidatedFeedback {
    pub(crate) timestamp: Option<Duration>,
    pub(crate) sequence: Option<u64>,
    pub(crate) timestamp_status: &'static str,
}

impl FeedbackClock {
    pub(crate) fn observe(
        &mut self,
        now: Option<Duration>,
        timestamp: Option<Duration>,
        sequence: Option<u32>,
        blanking_limit: Duration,
    ) -> ValidatedFeedback {
        let status = match (now, timestamp) {
            (_, None) => "missing_or_non_monotonic_clock",
            (None, _) => "clock_unavailable",
            (_, Some(timestamp)) if timestamp.is_zero() => "zero",
            (Some(now), Some(timestamp)) if timestamp.saturating_sub(now) > blanking_limit => {
                "future"
            }
            (Some(now), Some(timestamp)) if now.saturating_sub(timestamp) > MAX_EVENT_AGE => {
                "stale"
            }
            (_, Some(timestamp)) if self.last_timestamp.is_some_and(|last| timestamp <= last) => {
                "nonadvancing"
            }
            (Some(now), Some(timestamp)) if timestamp > now => "physical_blanking",
            _ => "physical",
        };
        let timestamp = timestamp.filter(|_| matches!(status, "physical" | "physical_blanking"));
        if timestamp.is_some() {
            self.last_timestamp = timestamp;
        }
        // Zero can be a legitimate u32 wrap. A repeated value or a reset is
        // not a vblank delta. Rebase after an invalid sample so recovery does
        // not turn a counter reset into billions of missed refreshes.
        let valid_sequence = sequence.filter(|current| match self.last_sequence {
            Some(last) => {
                let delta = current.wrapping_sub(last);
                delta > 0 && delta <= i32::MAX as u32
            }
            None => *current != 0,
        });
        self.last_sequence = sequence;
        ValidatedFeedback {
            timestamp,
            sequence: valid_sequence.map(u64::from),
            timestamp_status: status,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn zero_driver_metadata_never_becomes_physical_feedback() {
        let mut clock = FeedbackClock::default();
        for now in [10_000, 20_000, 240_000] {
            let feedback =
                clock.observe(Some(ms(now)), Some(Duration::ZERO), Some(0), Duration::ZERO);
            assert_eq!(feedback.timestamp_status, "zero");
            assert_eq!(feedback.timestamp, None);
            assert_eq!(feedback.sequence, None);
        }
    }

    #[test]
    fn accepts_delayed_physical_edges_but_rejects_bad_clocks() {
        let mut clock = FeedbackClock::default();
        let good = clock.observe(Some(ms(10_000)), Some(ms(9_950)), Some(42), Duration::ZERO);
        assert_eq!(good.timestamp, Some(ms(9_950)));
        assert_eq!(good.sequence, Some(42));
        for (timestamp, status) in [
            (9_950, "nonadvancing"),
            (9_940, "nonadvancing"),
            (1, "stale"),
            (10_001, "future"),
        ] {
            let result = clock.observe(Some(ms(10_000)), Some(ms(timestamp)), None, Duration::ZERO);
            assert_eq!(result.timestamp_status, status);
            assert_eq!(result.timestamp, None);
        }
        assert_eq!(
            clock
                .observe(None, Some(ms(10_000)), None, Duration::ZERO)
                .timestamp,
            None
        );
        assert_eq!(
            clock
                .observe(Some(ms(10_010)), Some(ms(10_000)), Some(43), Duration::ZERO)
                .timestamp,
            Some(ms(10_000))
        );
    }

    #[test]
    fn blanking_budget_comes_from_mode_and_rejects_invalid_timings() {
        assert_eq!(
            blanking_lead_limit(1_185_840, 3660, 2700, 2400),
            Some(Duration::from_nanos(925_926))
        );
        for timing in [
            (0, 3660, 2700, 2400),
            (1, 0, 2700, 2400),
            (1, 1, 2400, 2700),
            (1, 1, 2400, 2400),
            (1, 1, 1, 0),
        ] {
            assert_eq!(
                blanking_lead_limit(timing.0, timing.1, timing.2, timing.3),
                None
            );
        }
    }

    #[test]
    fn accepts_only_mode_bounded_future_edges_without_changing_metadata() {
        let now = Duration::from_secs(10);
        let limit = blanking_lead_limit(1_185_840, 3660, 2700, 2400).unwrap();
        let mut clock = FeedbackClock::default();
        let timestamp = now + Duration::from_micros(700);
        let feedback = clock.observe(Some(now), Some(timestamp), Some(42), limit);
        assert_eq!(feedback.timestamp, Some(timestamp));
        assert_eq!(feedback.timestamp_status, "physical_blanking");
        assert_eq!(feedback.sequence, Some(42));
        let feedback = clock.observe(Some(now), Some(now + limit), Some(43), limit);
        assert_eq!(feedback.timestamp, Some(now + limit));
        let feedback = clock.observe(
            Some(now),
            Some(now + limit + Duration::from_nanos(1)),
            Some(44),
            limit,
        );
        assert_eq!(feedback.timestamp, None);
        assert_eq!(feedback.timestamp_status, "future");
        let feedback = clock.observe(Some(now), Some(timestamp), Some(45), limit);
        assert_eq!(feedback.timestamp, None);
        assert_eq!(feedback.timestamp_status, "nonadvancing");
    }

    #[test]
    fn counter_wrap_is_valid_but_stalls_and_resets_are_not() {
        let mut clock = FeedbackClock::default();
        for (raw, accepted) in [
            (u32::MAX, Some(u64::from(u32::MAX))),
            (0, Some(0)),
            (1, Some(1)),
            (1, None),
            (2, Some(2)),
            (0, None),
            (1, Some(1)),
        ] {
            assert_eq!(
                clock
                    .observe(None, None, Some(raw), Duration::ZERO)
                    .sequence,
                accepted
            );
        }
    }
}
