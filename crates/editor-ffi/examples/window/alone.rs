//! What a window left alone shows: whether, each time it was left alone,
//! it showed what was laid out for its size and scale.

use std::time::Duration;

use editor_render::port::Target;

use crate::judge::Findings;
use crate::tally::{Happened, Record, Tally};
use crate::timing::{since, sized};

/// How long a window must be told nothing, with nothing published and no
/// draw begun or ended, to count as left alone.
const ALONE: Duration = Duration::from_secs(1);

/// What is made of the times the window of `records` was left alone, when
/// frame `n` of them was laid out for the window `laid[n - 1]`: that each
/// time, what it showed was laid out for it.
///
/// A window is left alone when [`ALONE`] passes in which it tells its
/// drawer nothing, no frame is published and no draw begins or ends. The
/// example's own wait for the render loop's rest is not something that
/// happened to the window, and breaks no such stretch. A stretch is judged when somebody can see
/// the window (it has not said it is hidden), a frame has been presented,
/// and no draw is in progress. Then the draw last presented must be of a
/// frame laid out for the size and the scale the window last said, on that
/// size and scale: anything else is a stale frame, or a frame of one scale
/// on a window at another, left on the screen. This is what is asked of a
/// window after it is resized, moved to a display at another scale, put
/// into the system's fullscreen and taken out of it, and shown again after
/// another Space, each time a person waits a second before going on.
pub fn left_alone(records: &[Record], laid: &[Target]) -> Findings {
    let opened_ns = records.first().map_or(0, |(at_ns, _)| *at_ns);
    let mut tally = Tally::default();
    let mut hidden = false;
    // When the last thing happened that was not the example's own doing.
    let mut quiet_since: Option<u64> = None;
    let (mut times, mut stale) = (0_usize, Vec::new());
    for (at_ns, happened) in records {
        if !matches!(happened, Happened::Idle(_)) {
            // Judged by what was so through the stretch that now ends:
            // before this record is taken in.
            let alone = quiet_since
                .is_some_and(|since| at_ns.saturating_sub(since) >= ALONE.as_nanos() as u64);
            let seen = !hidden && tally.drawing.is_none();
            if let (true, true, Some((frame, on)), Some(told), Some(from_ns)) =
                (alone, seen, tally.shown, tally.told, quiet_since)
            {
                times += 1;
                let laid_for = frame.and_then(|frame| laid.get(frame.checked_sub(1)?));
                if laid_for != Some(&told) || on != told {
                    let showed = match (frame, laid_for) {
                        (Some(frame), Some(laid_for)) => {
                            format!("frame {frame}, laid out for {}", sized(laid_for))
                        }
                        (Some(frame), None) => {
                            format!("frame {frame}, laid out for nothing the ledger was told")
                        }
                        (None, _) => "a frame nobody published".to_owned(),
                    };
                    stale.push(format!(
                        "left alone from {:.1} ms after it opened, the window showed {showed}, on {}, when it had last said it is {}",
                        since(opened_ns, from_ns),
                        sized(&on),
                        sized(&told)
                    ));
                }
            }
            quiet_since = Some(*at_ns);
        }
        if let Happened::Hidden(now) = happened {
            hidden = *now;
        }
        tally.note(*at_ns, happened);
    }
    let line = match (times, stale.len()) {
        (0, _) => "the window was never left alone for a second while it showed a frame, so what it shows when it is left alone was not judged".to_owned(),
        (times, 0) => format!(
            "left alone {times} times, and each time the window showed what was laid out for it"
        ),
        (times, stale) => format!(
            "left alone {times} times, and {stale} of them the window did not show what was laid out for it"
        ),
    };
    Findings {
        lines: vec![line],
        failures: stale,
    }
}

/// What the example decides of what it saw, with no window: these run in
/// the gate.
#[cfg(test)]
mod tests {
    use editor_render::port::Target;

    use super::left_alone;
    use crate::judge::Findings;
    use crate::tally::Happened;
    use crate::testing::{LARGE, MS, PRESENTED, SMALL, began};

    /// `happened`, each at its time since the first in milliseconds.
    fn timed(happened: &[(u64, Happened)]) -> Vec<(u64, Happened)> {
        happened
            .iter()
            .map(|(at_ms, happened)| (MS + at_ms * MS, happened.clone()))
            .collect()
    }

    /// The size of `LARGE` at the scale of `SMALL`: a window dragged to a
    /// display at another scale keeps its size in pixels for a moment.
    const WIDE: Target = Target {
        width: 800,
        height: 600,
        scale: 1.0,
    };

    /// The line of a window that was left alone `times` times and showed
    /// what was laid out for it each time.
    fn alone(times: usize) -> String {
        format!(
            "left alone {times} times, and each time the window showed what was laid out for it"
        )
    }

    #[test]
    fn left_alone_a_window_that_shows_what_was_laid_out_for_it_passes() {
        let records = timed(&[
            (
                0,
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
            ),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            // The example's own second is nothing the window did: with it
            // or without, this is one stretch of a second and more.
            (30, Happened::Idle(true)),
            (1030, Happened::Idle(false)),
            // A resize: the frame shown is drawn on the new size, and then
            // the frame laid out for it.
            (1500, Happened::Resized(WIDE)),
            (1501, began(1, WIDE)),
            (1510, PRESENTED),
            (1511, Happened::Published(2)),
            (1512, began(2, WIDE)),
            (1520, PRESENTED),
            // A change of scale alone, a second to the millisecond later.
            (2520, Happened::Resized(LARGE)),
            (2521, Happened::Published(3)),
            (2522, began(3, LARGE)),
            (2530, PRESENTED),
            // The window says the same again, and the same frame is
            // published again: nothing is drawn, and nothing is stale.
            (4000, Happened::Resized(LARGE)),
            (4001, Happened::Published(3)),
            // Damage, a millisecond short of a second later: not alone.
            (5000, Happened::Damaged),
            (5001, began(3, LARGE)),
            (5010, PRESENTED),
            (7000, Happened::Told("Closing".to_owned())),
        ]);
        // Frame 1 was laid out for SMALL, 2 for WIDE and 3 for LARGE.
        let laid = [SMALL, WIDE, LARGE];
        assert_eq!(
            left_alone(&records, &laid),
            Findings {
                lines: vec![alone(4)],
                failures: Vec::new(),
            }
        );
        // Back at a size it had: the frame laid out for it then is the
        // frame laid out for it now.
        let back = timed(&[
            (
                0,
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
            ),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (30, Happened::Resized(WIDE)),
            (31, Happened::Published(2)),
            (32, began(2, WIDE)),
            (40, PRESENTED),
            (50, Happened::Resized(SMALL)),
            (51, Happened::Published(1)),
            (52, began(1, SMALL)),
            (60, PRESENTED),
            (3000, Happened::Told("Closing".to_owned())),
        ]);
        assert_eq!(left_alone(&back, &laid).lines, [alone(1)]);
        assert_eq!(left_alone(&back, &laid).failures, [] as [String; 0]);
    }

    #[test]
    fn the_examples_own_wait_for_rest_neither_breaks_a_stretch_nor_makes_two_of_one() {
        // More than a second before the wait for rest begins, the wait
        // itself, and less than one after it: one stretch, of the window's.
        let records = timed(&[
            (
                0,
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
            ),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (1100, Happened::Idle(true)),
            (2100, Happened::Idle(false)),
            (2500, Happened::Told("Closing".to_owned())),
        ]);
        assert_eq!(left_alone(&records, &[SMALL]).lines, [alone(1)]);
        // Less than a second on either side of it, and more than one in
        // all.
        let records = timed(&[
            (
                0,
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
            ),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (500, Happened::Idle(true)),
            (510, Happened::Idle(false)),
            (1200, Happened::Told("Closing".to_owned())),
        ]);
        assert_eq!(left_alone(&records, &[SMALL]).lines, [alone(1)]);
    }

    #[test]
    fn left_alone_a_window_that_shows_a_frame_laid_out_for_another_size_or_scale_fails_and_says_which()
     {
        let opened = [
            (
                0,
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
            ),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
        ];
        let closing = (9000, Happened::Told("Closing".to_owned()));
        let laid = [SMALL, WIDE, LARGE];
        let found = |then: &[(u64, Happened)]| {
            let all: Vec<_> = opened
                .iter()
                .chain(then)
                .chain([&closing])
                .cloned()
                .collect();
            left_alone(&timed(&all), &laid)
        };

        // Another size: the frame shown is drawn on the new size, and the
        // frame laid out for it never comes.
        let stale = found(&[
            (1500, Happened::Resized(WIDE)),
            (1501, began(1, WIDE)),
            (1510, PRESENTED),
        ]);
        assert_eq!(
            stale,
            Findings {
                lines: vec![
                    "left alone 2 times, and 1 of them the window did not show what was laid out for it"
                        .to_owned()
                ],
                failures: vec![
                    "left alone from 1510.0 ms after it opened, the window showed frame 1, laid out for 400 by 300 at scale 1, on 800 by 600 at scale 1, when it had last said it is 800 by 600 at scale 1"
                        .to_owned()
                ],
            }
        );

        // Another scale: the frame laid out for the size at the old scale
        // is shown on the window at the new one.
        let unscaled = found(&[
            (1500, Happened::Resized(WIDE)),
            (1501, Happened::Published(2)),
            (1502, began(2, WIDE)),
            (1510, PRESENTED),
            (3000, Happened::Resized(LARGE)),
            (3001, began(2, LARGE)),
            (3010, PRESENTED),
        ]);
        assert_eq!(
            unscaled.failures,
            [
                "left alone from 3010.0 ms after it opened, the window showed frame 2, laid out for 800 by 600 at scale 1, on 800 by 600 at scale 2, when it had last said it is 800 by 600 at scale 2"
            ]
        );
        assert_eq!(
            unscaled.lines,
            ["left alone 3 times, and 1 of them the window did not show what was laid out for it"]
        );

        // The right frame, published, and never drawn where the window
        // now is: what is shown is the old frame on the old size.
        let undrawn = found(&[
            (1500, Happened::Resized(WIDE)),
            (1501, Happened::Published(2)),
        ]);
        assert_eq!(
            undrawn.failures,
            [
                "left alone from 1501.0 ms after it opened, the window showed frame 1, laid out for 400 by 300 at scale 1, on 400 by 300 at scale 1, when it had last said it is 800 by 600 at scale 1"
            ]
        );

        // A frame nobody published, and one the ledger was never told the
        // window of.
        let unknown = found(&[
            (
                1500,
                Happened::Began {
                    frame: None,
                    target: SMALL,
                },
            ),
            (1510, PRESENTED),
        ]);
        assert_eq!(
            unknown.failures,
            [
                "left alone from 1510.0 ms after it opened, the window showed a frame nobody published, on 400 by 300 at scale 1, when it had last said it is 400 by 300 at scale 1"
            ]
        );
        let untold = left_alone(
            &timed(&opened.iter().chain([&closing]).cloned().collect::<Vec<_>>()),
            &[],
        );
        assert_eq!(
            untold.failures,
            [
                "left alone from 20.0 ms after it opened, the window showed frame 1, laid out for nothing the ledger was told, on 400 by 300 at scale 1, when it had last said it is 400 by 300 at scale 1"
            ]
        );
    }

    #[test]
    fn a_window_that_is_hidden_or_never_left_alone_is_not_judged() {
        let never = "the window was never left alone for a second while it showed a frame, so what it shows when it is left alone was not judged";
        let unjudged = |happened: &[(u64, Happened)]| {
            assert_eq!(
                left_alone(&timed(happened), &[SMALL, WIDE]),
                Findings {
                    lines: vec![never.to_owned()],
                    failures: Vec::new(),
                }
            );
        };
        let opened = Happened::Opened {
            size: SMALL,
            refresh: None,
        };
        let closing = Happened::Told("Closing".to_owned());
        // Nothing happened, and a window that closed within the second.
        unjudged(&[]);
        unjudged(&[
            (0, opened.clone()),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (1019, closing.clone()),
        ]);
        // Hidden: on another Space, a stale frame is nobody's to see. What
        // is stale here is put right as the window is shown again.
        unjudged(&[
            (0, opened.clone()),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (30, Happened::Hidden(true)),
            (40, Happened::Resized(WIDE)),
            (3000, Happened::Hidden(false)),
            (3001, began(1, WIDE)),
            (3010, PRESENTED),
            (3011, Happened::Published(2)),
            (3012, began(2, WIDE)),
            (3020, PRESENTED),
            (3500, closing.clone()),
        ]);
        // Nothing was ever presented: a window that opened where nobody
        // can see it, and is not told so. That no frame was presented
        // fails the run by another check.
        unjudged(&[
            (0, opened.clone()),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (
                20,
                Happened::Ended {
                    presented: false,
                    masks: None,
                },
            ),
            (5000, closing.clone()),
        ]);
        // A draw in progress for the whole of the stretch: the window is
        // not left alone while it is drawn on.
        unjudged(&[
            (0, opened.clone()),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (30, Happened::Resized(WIDE)),
            (31, began(1, WIDE)),
            (2000, PRESENTED),
            (2001, Happened::Published(2)),
            (2002, began(2, WIDE)),
            (2010, PRESENTED),
            (2500, closing.clone()),
        ]);
        // Shown again and then left alone, it is judged.
        let shown = timed(&[
            (0, opened),
            (10, Happened::Published(1)),
            (11, began(1, SMALL)),
            (20, PRESENTED),
            (30, Happened::Hidden(true)),
            (3000, Happened::Hidden(false)),
            (4500, closing),
        ]);
        assert_eq!(left_alone(&shown, &[SMALL]).lines, [alone(1)]);
    }
}
