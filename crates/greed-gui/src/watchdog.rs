//! Notices when the window stops showing what the session sends: redraws
//! that keep ending without presenting a frame, and keys or clicks that get
//! no frame back. The window feeds it what happens and acts on its alarms;
//! it keeps no timer of its own, only a deadline the event loop waits until
//! while something is outstanding.

use std::fmt;
use std::time::{Duration, Instant};

/// Redraws in a row that may end without presenting before the alarm.
const MISSES: u32 = 30;
/// How long redraws may be wanted without one presenting.
const UNPRESENTED: Duration = Duration::from_secs(2);
/// How long a key or click may go without a frame back.
const UNANSWERED: Duration = Duration::from_secs(3);
/// Each alarm doubles both limits until a frame is presented, up to this
/// many times, so a window that can't draw for a while doesn't keep
/// remaking its surface.
const MOST_STRIKES: u32 = 5;

/// What the watchdog noticed.
#[derive(Debug, PartialEq)]
pub(crate) enum Alarm {
    /// Redraws were wanted for `wanted` and none presented, `misses` of
    /// them ending without it: make the surface again and ask for a whole
    /// frame.
    Unpresented { misses: u32, wanted: Duration },
    /// A key or click got no frame back in this long: ask for a whole
    /// frame.
    Unanswered(Duration),
}

impl fmt::Display for Alarm {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unpresented { misses, wanted } => write!(
                f,
                "the window showed nothing new for {:.1} s while redraws were wanted \
                 ({misses} in a row ended without presenting)",
                wanted.as_secs_f64()
            ),
            Self::Unanswered(waited) => write!(
                f,
                "no frame came {:.1} s after a key or click",
                waited.as_secs_f64()
            ),
        }
    }
}

#[derive(Debug, Default)]
pub(crate) struct Watchdog {
    /// Redraws in a row that ended without presenting.
    misses: u32,
    /// Since when a redraw has been wanted with none presenting.
    wanted: Option<Instant>,
    /// Alarms since a frame was last presented.
    strikes: u32,
    /// The window says it's covered: not presenting is expected.
    covered: bool,
    /// When a key or click went that no frame has answered yet.
    sent: Option<Instant>,
    /// A whole frame was asked for since then.
    asked: bool,
}

impl Watchdog {
    /// A redraw was asked for.
    pub(crate) fn wanted(&mut self, now: Instant) {
        if !self.covered {
            self.wanted.get_or_insert(now);
        }
    }

    /// A redraw presented a frame, or had none to present.
    pub(crate) fn presented(&mut self) {
        self.misses = 0;
        self.wanted = None;
        self.strikes = 0;
    }

    /// A redraw ended without presenting. An alarm when that's gone on too
    /// long.
    pub(crate) fn missed(&mut self, now: Instant) -> Option<Alarm> {
        if self.covered {
            return None;
        }
        self.misses += 1;
        let wanted = now.saturating_duration_since(*self.wanted.get_or_insert(now));
        (self.misses >= MISSES << self.strikes || wanted >= self.patience())
            .then(|| self.unpresented(wanted))
    }

    /// The window was covered or shown again.
    pub(crate) fn covered(&mut self, covered: bool) {
        self.covered = covered;
        if covered {
            self.misses = 0;
            self.wanted = None;
        }
    }

    /// A key or click went to the session.
    pub(crate) fn sent(&mut self, now: Instant) {
        self.sent.get_or_insert(now);
    }

    /// A frame, or a change to one, came from the session.
    pub(crate) fn frame(&mut self) {
        self.sent = None;
        self.asked = false;
    }

    /// An alarm whose time has come by `now`, if one has. Each is given
    /// once, so call it until it's None.
    pub(crate) fn due(&mut self, now: Instant) -> Option<Alarm> {
        if let Some(wanted) = self
            .wanted
            .map(|since| now.saturating_duration_since(since))
            && wanted >= self.patience()
        {
            return Some(self.unpresented(wanted));
        }
        let waited = now.saturating_duration_since(self.sent.filter(|_| !self.asked)?);
        (waited >= UNANSWERED).then(|| {
            self.asked = true;
            Alarm::Unanswered(waited)
        })
    }

    /// When the next alarm could be due; None while nothing's outstanding,
    /// so an idle window doesn't wake.
    pub(crate) fn deadline(&self) -> Option<Instant> {
        let unpresented = self.wanted.map(|since| since + self.patience());
        let unanswered = self
            .sent
            .filter(|_| !self.asked)
            .map(|sent| sent + UNANSWERED);
        unpresented.into_iter().chain(unanswered).min()
    }

    fn patience(&self) -> Duration {
        UNPRESENTED * (1 << self.strikes)
    }

    fn unpresented(&mut self, wanted: Duration) -> Alarm {
        let misses = std::mem::take(&mut self.misses);
        self.wanted = None;
        self.strikes = (self.strikes + 1).min(MOST_STRIKES);
        Alarm::Unpresented { misses, wanted }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    /// Misses `n` redraws at `now`, giving the alarms.
    fn miss(dog: &mut Watchdog, now: Instant, n: u32) -> Vec<Alarm> {
        (0..n).filter_map(|_| dog.missed(now)).collect()
    }

    #[test]
    fn an_idle_window_has_no_deadline() {
        let now = Instant::now();
        let mut dog = Watchdog::default();
        assert_eq!(dog.deadline(), None);
        assert_eq!(dog.due(now + ms(60_000)), None);
        dog.wanted(now);
        dog.presented();
        dog.sent(now);
        dog.frame();
        assert_eq!(dog.deadline(), None);
        assert_eq!(dog.due(now + ms(60_000)), None);
    }

    #[test]
    fn thirty_redraws_in_a_row_without_presenting_raise_the_alarm() {
        let now = Instant::now();
        let mut dog = Watchdog::default();
        assert_eq!(miss(&mut dog, now, MISSES - 1), []);
        assert_eq!(
            dog.missed(now),
            Some(Alarm::Unpresented {
                misses: MISSES,
                wanted: Duration::ZERO
            })
        );
        assert_eq!(dog.deadline(), None, "counting starts again");
    }

    #[test]
    fn a_presented_frame_starts_the_count_again() {
        let now = Instant::now();
        let mut dog = Watchdog::default();
        assert_eq!(miss(&mut dog, now, MISSES - 1), []);
        dog.presented();
        assert_eq!(dog.deadline(), None);
        assert_eq!(miss(&mut dog, now, MISSES - 1), []);
    }

    #[test]
    fn a_wanted_redraw_that_never_presents_is_due_after_two_seconds() {
        let now = Instant::now();
        let mut dog = Watchdog::default();
        dog.wanted(now);
        dog.wanted(now + ms(500));
        assert_eq!(dog.deadline(), Some(now + UNPRESENTED), "from the first");
        assert_eq!(dog.due(now + ms(1999)), None);
        let alarm = Alarm::Unpresented {
            misses: 0,
            wanted: UNPRESENTED,
        };
        assert_eq!(dog.due(now + UNPRESENTED), Some(alarm));
        assert_eq!(dog.due(now + UNPRESENTED), None, "given once");
        assert_eq!(dog.deadline(), None);
    }

    #[test]
    fn a_redraw_missing_after_two_seconds_raises_the_alarm_however_few_missed() {
        let now = Instant::now();
        let mut dog = Watchdog::default();
        dog.wanted(now);
        assert_eq!(dog.missed(now + ms(100)), None);
        assert_eq!(
            dog.missed(now + UNPRESENTED),
            Some(Alarm::Unpresented {
                misses: 2,
                wanted: UNPRESENTED
            })
        );
    }

    #[test]
    fn each_alarm_doubles_the_limits_until_a_frame_presents() {
        let now = Instant::now();
        let mut dog = Watchdog::default();
        assert_eq!(miss(&mut dog, now, MISSES).len(), 1);
        assert_eq!(miss(&mut dog, now, 2 * MISSES - 1), []);
        assert_eq!(miss(&mut dog, now, 1).len(), 1);
        dog.wanted(now);
        assert_eq!(dog.deadline(), Some(now + 4 * UNPRESENTED));
        for _ in 0..10 {
            dog.due(now + ms(10_000_000));
            dog.wanted(now);
        }
        assert_eq!(
            dog.deadline(),
            Some(now + UNPRESENTED * (1 << MOST_STRIKES)),
            "up to a limit"
        );
        dog.presented();
        assert_eq!(miss(&mut dog, now, MISSES).len(), 1);
    }

    #[test]
    fn a_covered_window_not_presenting_is_no_alarm() {
        let now = Instant::now();
        let mut dog = Watchdog::default();
        dog.wanted(now);
        dog.covered(true);
        assert_eq!(dog.deadline(), None, "what was wanted is forgotten");
        dog.wanted(now);
        assert_eq!(miss(&mut dog, now + ms(10_000), MISSES * 2), []);
        assert_eq!(dog.deadline(), None);
        dog.covered(false);
        assert_eq!(miss(&mut dog, now, MISSES).len(), 1);
    }

    #[test]
    fn a_key_with_no_frame_back_asks_for_one_once() {
        let now = Instant::now();
        let mut dog = Watchdog::default();
        dog.sent(now);
        dog.sent(now + ms(1000));
        assert_eq!(dog.deadline(), Some(now + UNANSWERED), "from the first");
        assert_eq!(dog.due(now + ms(2999)), None);
        assert_eq!(
            dog.due(now + UNANSWERED),
            Some(Alarm::Unanswered(UNANSWERED))
        );
        assert_eq!(dog.due(now + ms(60_000)), None, "only once");
        assert_eq!(dog.deadline(), None);
        dog.sent(now + ms(5000));
        assert_eq!(dog.deadline(), None, "still waiting on the same answer");
    }

    #[test]
    fn a_frame_answers_the_keys_sent() {
        let now = Instant::now();
        let mut dog = Watchdog::default();
        dog.sent(now);
        dog.frame();
        assert_eq!(dog.due(now + ms(60_000)), None);
        dog.sent(now);
        assert_eq!(dog.due(now + ms(2999)), None);
        dog.frame();
        dog.sent(now + ms(10_000));
        assert_eq!(dog.deadline(), Some(now + ms(10_000) + UNANSWERED));
    }

    #[test]
    fn the_nearest_deadline_wins() {
        let now = Instant::now();
        let mut dog = Watchdog::default();
        dog.sent(now);
        dog.wanted(now + ms(500));
        assert_eq!(dog.deadline(), Some(now + ms(2500)));
        let later = now + ms(3000);
        assert!(matches!(dog.due(later), Some(Alarm::Unpresented { .. })));
        assert!(matches!(dog.due(later), Some(Alarm::Unanswered(_))));
        assert_eq!(dog.due(later), None);
    }
}
