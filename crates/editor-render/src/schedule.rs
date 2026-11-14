//! The scheduler: when to draw, as a pure function of what is asked for and
//! the time.
//!
//! Frames are drawn on demand. A demand is a frame to show, a dirty mark, a
//! change of the target's size or scale, or an animation deadline that has
//! come. With no demand nothing is scheduled ([`Decision::Idle`]), and the
//! render loop waits with no deadline. With one, a draw happens once a
//! refresh interval has passed since the last draw began, so there is at
//! most one draw for each refresh of the display, however many demands
//! arrived meanwhile: the dirty mark is one stamp, not a count.
//!
//! [`decide`] reads no clock and keeps nothing: the loop hands it the time,
//! and a test hands it any time it likes.

/// The refresh interval of a display nobody has described: 60 a second.
pub const DEFAULT_REFRESH_NS: u64 = 16_666_667;

/// What is asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Demands {
    /// A frame is waiting that is not the one shown.
    pub frame: bool,
    /// When the frame shown was first marked dirty since the last draw.
    pub dirty_since: Option<u64>,
    /// The target's size or scale is not the one last drawn at.
    pub resized: bool,
    /// When an animation next needs a frame.
    pub animate_at: Option<u64>,
}

/// How draws are paced.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pace {
    /// When the last draw began; `None` before the first.
    pub last_draw: Option<u64>,
    /// The display's refresh interval, in nanoseconds.
    pub refresh_ns: u64,
}

/// What to do now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Nothing is asked for: wait until something is, with no deadline.
    Idle,
    /// Draw now.
    Draw,
    /// Wait until this time, or until something more is asked for, and
    /// decide again.
    WaitUntil(u64),
}

/// What to do at `now`, given `demands` and `pace`.
pub fn decide(demands: &Demands, pace: &Pace, now: u64) -> Decision {
    // The earliest a draw may begin: a refresh after the last one did.
    let earliest = pace
        .last_draw
        .map_or(0, |last| last.saturating_add(pace.refresh_ns));
    let due = demands.animate_at.is_some_and(|at| at <= now);
    if demands.frame || demands.dirty_since.is_some() || demands.resized || due {
        return if now >= earliest {
            Decision::Draw
        } else {
            Decision::WaitUntil(earliest)
        };
    }
    demands
        .animate_at
        .map_or(Decision::Idle, |at| Decision::WaitUntil(at.max(earliest)))
}

#[cfg(test)]
mod tests {
    use super::{DEFAULT_REFRESH_NS, Decision, Demands, Pace, decide};

    /// A refresh interval for the tests: a round number, so the times read
    /// easily.
    const REFRESH: u64 = 100;

    /// The pace after a draw at `last_draw`.
    fn after(last_draw: u64) -> Pace {
        Pace {
            last_draw: Some(last_draw),
            refresh_ns: REFRESH,
        }
    }

    /// The pace before any draw.
    const FIRST: Pace = Pace {
        last_draw: None,
        refresh_ns: REFRESH,
    };

    /// A dirty mark made at `since`, and nothing else.
    fn dirty(since: u64) -> Demands {
        Demands {
            dirty_since: Some(since),
            ..Demands::default()
        }
    }

    /// An animation deadline, and nothing else.
    fn animation(at: u64) -> Demands {
        Demands {
            animate_at: Some(at),
            ..Demands::default()
        }
    }

    #[test]
    fn idle_schedules_nothing() {
        let idle = Demands::default();
        assert_eq!(decide(&idle, &FIRST, 1), Decision::Idle);
        // However long it has been since the last draw.
        for now in [1000, 1001, 1100, 5000, u64::MAX] {
            assert_eq!(decide(&idle, &after(1000), now), Decision::Idle);
        }
    }

    #[test]
    fn several_dirty_marks_within_one_refresh_give_one_draw() {
        // A draw at 1000. Marks at 1010, 1020 and 1030 are one demand, the
        // stamp of the first: until a refresh has passed there is no draw.
        let marked = dirty(1010);
        for now in [1010, 1020, 1030, 1099] {
            assert_eq!(
                decide(&marked, &after(1000), now),
                Decision::WaitUntil(1100)
            );
        }
        // Then one draw, which serves them all.
        assert_eq!(decide(&marked, &after(1000), 1100), Decision::Draw);
        // And with the mark served, nothing more.
        assert_eq!(
            decide(&Demands::default(), &after(1100), 1101),
            Decision::Idle
        );
    }

    #[test]
    fn a_draw_waits_for_the_refresh_after_the_last() {
        let frame = Demands {
            frame: true,
            ..Demands::default()
        };
        // The first draw waits for nothing.
        assert_eq!(decide(&frame, &FIRST, 1), Decision::Draw);
        assert_eq!(
            decide(&frame, &after(1000), 1001),
            Decision::WaitUntil(1100)
        );
        assert_eq!(decide(&frame, &after(1000), 1100), Decision::Draw);
        assert_eq!(decide(&frame, &after(1000), 9000), Decision::Draw);
        // The interval is the pace's own.
        let slow = Pace {
            last_draw: Some(1000),
            refresh_ns: DEFAULT_REFRESH_NS,
        };
        assert_eq!(
            decide(&frame, &slow, 1001),
            Decision::WaitUntil(1000 + DEFAULT_REFRESH_NS)
        );
    }

    #[test]
    fn an_animation_deadline_is_waited_for_and_then_drawn() {
        // The last draw was long ago; the deadline is ahead.
        let animated = animation(5000);
        assert_eq!(
            decide(&animated, &after(1000), 4000),
            Decision::WaitUntil(5000)
        );
        assert_eq!(decide(&animated, &after(1000), 5000), Decision::Draw);
        assert_eq!(decide(&animated, &FIRST, 4000), Decision::WaitUntil(5000));
    }

    #[test]
    fn a_deadline_already_passed_is_drawn_at_once() {
        assert_eq!(decide(&animation(5000), &after(1000), 7000), Decision::Draw);
        // Unless a draw was less than a refresh ago.
        assert_eq!(
            decide(&animation(5000), &after(6950), 7000),
            Decision::WaitUntil(7050)
        );
    }

    #[test]
    fn a_deadline_sooner_than_the_next_refresh_waits_for_the_refresh() {
        assert_eq!(
            decide(&animation(1040), &after(1000), 1010),
            Decision::WaitUntil(1100)
        );
    }

    #[test]
    fn a_resize_is_a_demand_like_any_other() {
        let resized = Demands {
            resized: true,
            ..Demands::default()
        };
        assert_eq!(decide(&resized, &after(1000), 1100), Decision::Draw);
        assert_eq!(
            decide(&resized, &after(1000), 1050),
            Decision::WaitUntil(1100)
        );
    }

    #[test]
    fn a_demand_now_is_not_held_back_by_a_deadline_ahead() {
        let both = Demands {
            dirty_since: Some(1200),
            animate_at: Some(9000),
            ..Demands::default()
        };
        assert_eq!(decide(&both, &after(1000), 1200), Decision::Draw);
    }

    #[test]
    fn a_time_past_the_end_of_the_clock_does_not_wrap() {
        let pace = Pace {
            last_draw: Some(u64::MAX - 5),
            refresh_ns: REFRESH,
        };
        assert_eq!(
            decide(&dirty(u64::MAX - 4), &pace, u64::MAX - 3),
            Decision::WaitUntil(u64::MAX)
        );
    }

    /// One row of the walk: the time, whether a mark is made then, and what
    /// is decided.
    type Row = (u64, bool, Decision);

    #[test]
    fn no_two_draws_of_a_walk_are_less_than_a_refresh_apart() {
        // A loop walked by hand: at each time a mark may be made, then the
        // decision is taken; a draw serves the mark and sets the pace.
        let walk: [Row; 12] = [
            (10, false, Decision::Idle),
            (20, true, Decision::Draw),
            (30, true, Decision::WaitUntil(120)),
            (40, true, Decision::WaitUntil(120)),
            (119, false, Decision::WaitUntil(120)),
            (120, false, Decision::Draw),
            (121, false, Decision::Idle),
            (500, false, Decision::Idle),
            (501, true, Decision::Draw),
            (600, true, Decision::WaitUntil(601)),
            (601, true, Decision::Draw),
            (700, false, Decision::Idle),
        ];
        let mut pace = FIRST;
        let mut demands = Demands::default();
        let mut draws = Vec::new();
        for (now, mark, expected) in walk {
            if mark {
                demands.dirty_since.get_or_insert(now);
            }
            let decision = decide(&demands, &pace, now);
            assert_eq!(decision, expected, "at {now}");
            if decision == Decision::Draw {
                draws.push(now);
                pace.last_draw = Some(now);
                demands = Demands::default();
            }
        }
        // Eight marks, four draws, and a refresh between any two.
        assert_eq!(draws, vec![20, 120, 501, 601]);
        assert!(draws.windows(2).all(|pair| pair[1] - pair[0] >= REFRESH));
    }
}
