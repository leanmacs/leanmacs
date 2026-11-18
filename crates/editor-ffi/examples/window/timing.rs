//! What the tally finds of drawing on demand, and the ledger and the
//! renderer's journal as lines, each with its time since the window opened.

use std::time::Duration;

use editor_render::journal::Entry;
use editor_render::port::Target;

use crate::judge::{Findings, listed};
use crate::tally::{Happened, Idle, Record, Served, Tally};

/// How long the window is left alone, with nothing published, to see that
/// nothing is drawn.
pub const IDLE: Duration = Duration::from_secs(1);

/// How many times a window left alone for [`IDLE`] may ask to be drawn
/// again: a system that uncovers the window, or settles its size as it
/// opens, asks a few times. A window that asks at every refresh asks sixty
/// times and more.
const IDLE_ASKS: u64 = 5;

/// How long after `opened_ns` the time `at_ns` is, in milliseconds.
pub fn since(opened_ns: u64, at_ns: u64) -> f64 {
    (at_ns as f64 - opened_ns as f64) / 1e6
}

/// What is made of the draws `tally` holds, in a window that opened at
/// `opened_ns` and whose render loop counts `counted` draws, presented or
/// not: that none was for nothing.
pub fn on_demand(tally: &Tally, opened_ns: u64, counted: u64) -> Findings {
    let mut found = Findings::default();
    match tally.idle {
        Some(Idle {
            settled,
            drawn,
            asked,
        }) => {
            if !settled {
                found.lines.push(
                    "idle: the second began before the window had settled: a draw was in progress, or something asked for was not yet drawn"
                        .to_owned(),
                );
            }
            found.lines.push(format!(
                "idle: over {} s in which nothing was published, {drawn} frames were drawn and the window asked for {asked}",
                IDLE.as_secs()
            ));
            // A second that began before the window had settled may draw
            // for what was asked before it: each draw is judged by itself,
            // below.
            if settled && drawn > asked {
                found.failures.push(format!(
                    "{drawn} frames were drawn while idle and {asked} were asked for"
                ));
            }
            if asked > IDLE_ASKS {
                found.failures.push(format!(
                    "the window asked to be drawn {asked} times while idle: more than {IDLE_ASKS} is a timer"
                ));
            }
        }
        None => found
            .failures
            .push("the window was never seen idle: no frame was presented".to_owned()),
    }
    let unasked = tally.unasked();
    if let Some((number, first)) = unasked.first() {
        found.failures.push(format!(
            "{} of the {} draws were asked for by nothing: the first is draw {number}, which began {:.1} ms after the window opened",
            unasked.len(),
            tally.draws.len(),
            since(opened_ns, first.began_ns)
        ));
    }
    let asked = tally.asked;
    found.lines.push(format!(
        "over the whole run, {counted} draws for {asked} things that asked for one"
    ));
    if counted > asked {
        found.failures.push(format!(
            "{counted} draws were made and {asked} were asked for"
        ));
    }
    let entered = tally.draws.len() as u64;
    if counted != entered {
        found.failures.push(format!(
            "the render loop counts {counted} draws and its renderer was asked for {entered}"
        ));
    }
    found
}

/// A size and a scale, for a person: `800 by 600 at scale 2`.
pub fn sized(target: &Target) -> String {
    format!(
        "{} by {} at scale {}",
        target.width, target.height, target.scale
    )
}

/// The timeline of `records`: one line for each, its time since the first
/// and what happened.
pub fn timeline(records: &[Record]) -> Vec<String> {
    let Some((opened_ns, _)) = records.first() else {
        return Vec::new();
    };
    let on = sized;
    // What each draw was for is the tally's to say, as the records go by.
    let mut tally = Tally::default();
    let mut lines = Vec::new();
    for (at_ns, happened) in records {
        let again =
            matches!(happened, Happened::Published(frame) if tally.published == Some(*frame));
        let settled = tally.settled();
        tally.note(*at_ns, happened);
        let draw = tally.draws.len();
        let what = match happened {
            Happened::Opened { size, refresh } => format!(
                "the window told its drawer it opened, {}, on a display that {}",
                on(size),
                refresh.map_or_else(
                    || "does not say how often it refreshes".to_owned(),
                    |rate| format!("refreshes {rate} thousandths of a hertz")
                )
            ),
            Happened::Resized(size) => format!("the window told its drawer it is {}", on(size)),
            Happened::Damaged => "the window told its drawer it is damaged".to_owned(),
            Happened::Hidden(hidden) => format!("the window told its drawer Hidden({hidden})"),
            Happened::Told(said) => format!("the window told its drawer {said}"),
            Happened::Published(frame) => format!(
                "frame {frame} was published{}",
                if again { " again" } else { "" }
            ),
            Happened::Began { frame, target } => format!(
                "draw {draw} began, of {} on {}, for {}",
                frame.map_or_else(
                    || "a frame nobody published".to_owned(),
                    |frame| format!("frame {frame}")
                ),
                on(target),
                tally
                    .draws
                    .last()
                    .map_or_else(String::new, |draw| reasons(draw.served))
            ),
            Happened::Ended { presented, masks } => format!(
                "draw {draw} ended, {}",
                match (presented, masks) {
                    // The kind of mask in the renderer's own words for it.
                    (true, Some(masks)) => format!("presented, its glyphs as {masks}"),
                    (true, None) => "presented".to_owned(),
                    (false, _) => "not presented".to_owned(),
                }
            ),
            Happened::Idle(true) => format!(
                "the idle second began{}",
                if settled {
                    ""
                } else {
                    ", before the window had settled"
                }
            ),
            Happened::Idle(false) => "the idle second ended".to_owned(),
        };
        lines.push(format!("{:>9.1} ms: {what}", since(*opened_ns, *at_ns)));
    }
    lines
}

/// What a draw was for, for a person.
fn reasons(served: Served) -> String {
    let reasons: Vec<String> = [
        (served.frame, "a frame not yet shown"),
        (served.size, "a size not yet drawn at"),
        (served.damage, "damage"),
    ]
    .into_iter()
    .filter(|(served, _)| *served)
    .map(|(_, reason)| reason.to_owned())
    .collect();
    if reasons.is_empty() {
        "nothing that was asked".to_owned()
    } else {
        listed(&reasons)
    }
}

/// What the render loop's journal says of one frame presented, in a window
/// that opened at `opened_ns`.
pub fn journalled(entry: &Entry, opened_ns: u64) -> String {
    format!(
        "the journal's frame {} answers something asked {:.1} ms after the window opened: its draw began at {:.1} ms and it was presented at {:.1} ms",
        entry.serial,
        since(opened_ns, entry.input_ns),
        since(opened_ns, entry.draw_ns),
        since(opened_ns, entry.present_ns)
    )
}

/// What the example decides of what it saw, with no window: these run in
/// the gate.
#[cfg(test)]
mod tests {
    use editor_render::journal::Entry;
    use editor_render_wgpu::{Masks, SubpixelOrder};

    use super::{IDLE_ASKS, journalled, on_demand, timeline};
    use crate::judge::Findings;
    use crate::tally::{Draw, Happened, Idle, Served, Tally};
    use crate::testing::{
        DAMAGE, FRAME, LARGE, MS, PRESENTED, REFUSED, SMALL, and, began, presented_as, records,
        served, showing, tallied,
    };

    /// A tally of `draws` draws, the idle second as `idle`, and `asked`
    /// things that asked.
    fn tally_of(draws: &[Draw], idle: Option<Idle>, asked: u64) -> Tally {
        Tally {
            draws: draws.to_vec(),
            idle,
            asked,
            ..Tally::default()
        }
    }

    /// A draw that began at `began_ns` and presented, for `served`.
    fn draw(began_ns: u64, served: Served) -> Draw {
        Draw {
            began_ns,
            presented: true,
            served,
            idle: false,
        }
    }

    /// An idle second that began settled.
    fn idle(drawn: u64, asked: u64) -> Option<Idle> {
        Some(Idle {
            settled: true,
            drawn,
            asked,
        })
    }

    #[test]
    fn draws_that_were_each_asked_for_pass_and_say_what_the_idle_second_showed() {
        let tally = tally_of(
            &[draw(5 * MS, FRAME), draw(900 * MS, DAMAGE)],
            idle(0, 0),
            8,
        );
        assert_eq!(
            on_demand(&tally, MS, 2),
            Findings {
                lines: vec![
                    "idle: over 1 s in which nothing was published, 0 frames were drawn and the window asked for 0".to_owned(),
                    "over the whole run, 2 draws for 8 things that asked for one".to_owned(),
                ],
                failures: Vec::new(),
            }
        );
        // A window that asked in its idle second, and was drawn for it.
        let asked = on_demand(&tally_of(&[draw(5 * MS, FRAME)], idle(2, 2), 3), MS, 1);
        assert_eq!(
            asked.lines[0],
            "idle: over 1 s in which nothing was published, 2 frames were drawn and the window asked for 2"
        );
        assert_eq!(asked.failures, [] as [String; 0]);
    }

    #[test]
    fn a_draw_for_nothing_fails_wherever_it_is_and_says_which_and_when() {
        let storm = [
            draw(5 * MS, FRAME),
            draw(1_500 * MS + MS / 2, Served::default()),
            draw(1_600 * MS, Served::default()),
        ];
        // Whatever the idle second showed, and however many things asked.
        let found = on_demand(&tally_of(&storm, idle(0, 0), 9), MS, 3);
        assert_eq!(
            found.failures,
            [
                "2 of the 3 draws were asked for by nothing: the first is draw 2, which began 1499.5 ms after the window opened"
            ]
        );
    }

    #[test]
    fn more_frames_drawn_in_an_idle_second_than_were_asked_for_in_it_fails() {
        let found = on_demand(&tally_of(&[draw(5 * MS, FRAME)], idle(10, 0), 20), MS, 1);
        assert_eq!(
            found.failures,
            ["10 frames were drawn while idle and 0 were asked for"]
        );
        // Unless the second began before the window had settled: what was
        // drawn in it may be for that, and each draw is judged by itself.
        let unsettled = Some(Idle {
            settled: false,
            drawn: 1,
            asked: 0,
        });
        let found = on_demand(&tally_of(&[draw(5 * MS, FRAME)], unsettled, 2), MS, 1);
        assert_eq!(found.failures, [] as [String; 0]);
        assert_eq!(
            found.lines[0],
            "idle: the second began before the window had settled: a draw was in progress, or something asked for was not yet drawn"
        );
    }

    #[test]
    fn a_window_that_asks_again_and_again_while_idle_fails_as_a_timer() {
        let asks = IDLE_ASKS + 1;
        let most = on_demand(&tally_of(&[], idle(0, IDLE_ASKS), IDLE_ASKS), MS, 0);
        assert_eq!(most.failures, [] as [String; 0]);
        let found = on_demand(&tally_of(&[], idle(0, asks), asks), MS, 0);
        assert_eq!(
            found.failures,
            [format!(
                "the window asked to be drawn {asks} times while idle: more than {IDLE_ASKS} is a timer"
            )]
        );
    }

    #[test]
    fn a_window_never_seen_idle_and_more_draws_than_things_that_asked_fail() {
        let found = on_demand(&tally_of(&[draw(5 * MS, FRAME)], None, 1), MS, 1);
        assert_eq!(
            found.failures,
            ["the window was never seen idle: no frame was presented"]
        );
        // The loop counts its draws, presented or not: three for two asks.
        let found = on_demand(
            &tally_of(
                &[
                    draw(5 * MS, FRAME),
                    draw(6 * MS, FRAME),
                    draw(7 * MS, FRAME),
                ],
                idle(0, 0),
                2,
            ),
            MS,
            3,
        );
        assert_eq!(found.failures, ["3 draws were made and 2 were asked for"]);
        // And the renderer was asked for as many draws as the loop counts.
        let found = on_demand(&tally_of(&[draw(5 * MS, FRAME)], idle(0, 0), 4), MS, 2);
        assert_eq!(
            found.failures,
            ["the render loop counts 2 draws and its renderer was asked for 1"]
        );
    }

    #[test]
    fn the_timeline_says_each_thing_with_its_time_since_the_window_opened() {
        let lines = timeline(&records(&[
            Happened::Opened {
                size: LARGE,
                refresh: Some(120_000),
            },
            Happened::Published(1),
            began(1, LARGE),
            Happened::Resized(LARGE),
            Happened::Published(1),
            Happened::Damaged,
            Happened::Hidden(true),
            PRESENTED,
            began(1, LARGE),
            REFUSED,
            Happened::Idle(true),
            Happened::Published(2),
            Happened::Resized(SMALL),
            began(2, SMALL),
            PRESENTED,
            began(2, SMALL),
            Happened::Idle(false),
            Happened::Began {
                frame: None,
                target: SMALL,
            },
        ]));
        assert_eq!(
            lines,
            [
                "      0.0 ms: the window told its drawer it opened, 800 by 600 at scale 2, on a display that refreshes 120000 thousandths of a hertz",
                "      1.0 ms: frame 1 was published",
                "      2.0 ms: draw 1 began, of frame 1 on 800 by 600 at scale 2, for a frame not yet shown",
                "      3.0 ms: the window told its drawer it is 800 by 600 at scale 2",
                "      4.0 ms: frame 1 was published again",
                "      5.0 ms: the window told its drawer it is damaged",
                "      6.0 ms: the window told its drawer Hidden(true)",
                "      7.0 ms: draw 1 ended, presented",
                "      8.0 ms: draw 2 began, of frame 1 on 800 by 600 at scale 2, for damage",
                "      9.0 ms: draw 2 ended, not presented",
                "     10.0 ms: the idle second began, before the window had settled",
                "     11.0 ms: frame 2 was published",
                "     12.0 ms: the window told its drawer it is 400 by 300 at scale 1",
                "     13.0 ms: draw 3 began, of frame 2 on 400 by 300 at scale 1, for a frame not yet shown, a size not yet drawn at and damage",
                "     14.0 ms: draw 3 ended, presented",
                "     15.0 ms: draw 4 began, of frame 2 on 400 by 300 at scale 1, for nothing that was asked",
                "     16.0 ms: the idle second ended",
                "     17.0 ms: draw 5 began, of a frame nobody published on 400 by 300 at scale 1, for a frame not yet shown",
            ]
        );
        assert_eq!(timeline(&[]), [] as [String; 0]);

        // A display that does not say how often it refreshes, and an idle
        // second that began with nothing left to draw.
        let quiet = timeline(&records(&and(showing(), &[Happened::Idle(true)])));
        assert_eq!(
            quiet[0],
            "      0.0 ms: the window told its drawer it opened, 400 by 300 at scale 1, on a display that does not say how often it refreshes"
        );
        assert_eq!(quiet[4], "      4.0 ms: the idle second began");
    }

    #[test]
    fn the_timeline_says_which_masks_a_presented_draw_used() {
        // The kinds a renderer says, in the renderer's own words for each.
        let kinds = [
            Masks::Plain,
            Masks::Subpixel(SubpixelOrder::Rgb),
            Masks::Subpixel(SubpixelOrder::Bgr),
        ];
        for masks in kinds {
            let lines = timeline(&records(&[
                Happened::Opened {
                    size: SMALL,
                    refresh: None,
                },
                Happened::Published(1),
                began(1, SMALL),
                presented_as(masks),
                // A draw that did not present says nothing of its masks.
                Happened::Damaged,
                began(1, SMALL),
                Happened::Ended {
                    presented: false,
                    masks: Some(masks),
                },
            ]));
            assert_eq!(
                lines[3],
                format!("      3.0 ms: draw 1 ended, presented, its glyphs as {masks}")
            );
            assert_eq!(lines[6], "      6.0 ms: draw 2 ended, not presented");
        }
        // The masks of a draw change nothing of what it was for.
        let tally = tallied(&and(
            showing(),
            &[
                Happened::Damaged,
                began(1, SMALL),
                presented_as(Masks::Plain),
            ],
        ));
        assert_eq!(served(&tally), [FRAME, DAMAGE]);
        assert!(tally.settled());
    }

    #[test]
    fn a_journal_entry_says_when_what_it_answers_was_asked_and_when_it_was_drawn() {
        let entry = Entry {
            serial: 2,
            input_ns: 13 * MS + MS / 4,
            draw_ns: 588 * MS,
            present_ns: 801 * MS + MS / 2,
            rows_rebuilt: 0,
            rows_reused: 3,
        };
        assert_eq!(
            journalled(&entry, MS),
            "the journal's frame 2 answers something asked 12.2 ms after the window opened: its draw began at 587.0 ms and it was presented at 800.5 ms"
        );
    }
}
