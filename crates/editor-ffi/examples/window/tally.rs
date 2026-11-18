//! What the ledger comes to: each thing entered in it, and what each draw
//! was for, tallied in the order they happened.

use editor_render::port::Target;
use editor_render_wgpu::Masks;

/// One thing that bears on whether a draw was asked for, as the example
/// saw it happen.
#[derive(Debug, Clone, PartialEq)]
pub enum Happened {
    /// The window told its drawer that it opened.
    Opened {
        /// The size it opened at.
        size: Target,
        /// How often its display refreshes, in thousandths of a hertz,
        /// when the platform says.
        refresh: Option<u32>,
    },
    /// The window told its drawer its new size or scale.
    Resized(Target),
    /// The window told its drawer that the system asks for its content to
    /// be drawn again.
    Damaged,
    /// The window told its drawer that nobody can see it (`true`), or that
    /// somebody can again (`false`): it is covered, off the screen, or on
    /// another Space. It asks for no draw.
    Hidden(bool),
    /// The window told its drawer something else, which asks for no draw:
    /// as it prints.
    Told(String),
    /// A frame was published: which, counted from 1. Frames that are equal
    /// are one frame, as they are to the render loop.
    Published(usize),
    /// The renderer was asked to draw.
    Began {
        /// The frame to draw, by its number; `None` for a frame nobody
        /// published.
        frame: Option<usize>,
        /// What to draw it on.
        target: Target,
    },
    /// The renderer answered the draw last begun.
    Ended {
        /// Whether it presented the frame.
        presented: bool,
        /// The kind of mask it drew its glyphs with, as the renderer says;
        /// `None` for a renderer that does not say.
        masks: Option<Masks>,
    },
    /// The idle second began (`true`) or ended (`false`).
    Idle(bool),
}

/// One thing that happened, and when on the example's clock, in
/// nanoseconds.
pub type Record = (u64, Happened);

/// What a draw was for: each thing asked that it was the first draw to
/// answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Served {
    /// A frame that is not the one shown.
    pub frame: bool,
    /// A size or a scale that is not the one last drawn at.
    pub size: bool,
    /// Damage the window told of.
    pub damage: bool,
}

impl Served {
    /// Whether it is nothing at all.
    fn nothing(self) -> bool {
        !(self.frame || self.size || self.damage)
    }
}

/// One draw the renderer was asked for.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Draw {
    /// When it began.
    pub began_ns: u64,
    /// Whether it presented its frame; `false` while it is in progress.
    pub presented: bool,
    /// What it was for.
    pub served: Served,
    /// Whether it began in the idle second.
    pub idle: bool,
}

/// What the idle second showed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Idle {
    /// Whether everything asked before it began had been drawn by then.
    pub settled: bool,
    /// The draws that began in it and presented.
    pub drawn: u64,
    /// The things that asked for a draw in it.
    pub asked: u64,
}

/// The draw in progress.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Drawing {
    /// The frame it draws.
    frame: Option<usize>,
    /// What it draws on.
    target: Target,
    /// How many times the window had told of damage that it answers.
    damage: u64,
}

/// What the ledger comes to: which draw was for what, and what is still
/// asked for.
///
/// It keeps the render loop's own rule of what a demand is
/// (`editor_render::render_loop`): a frame that is not the one shown, a
/// size that is not the one last drawn at, and a mark that the frame shown
/// must be drawn again, which here only damage the window tells of leaves.
/// The first two it reads off the draw itself, by what was shown before
/// it; the third off what the window told since the last draw began. A
/// draw that presents answers all three; one that does not leaves them to
/// the next.
#[derive(Debug, Clone, Default)]
pub struct Tally {
    /// The frame last published.
    pub published: Option<usize>,
    /// The size the window last told.
    pub told: Option<Target>,
    /// The frame last presented, and what it was presented on.
    pub shown: Option<(Option<usize>, Target)>,
    /// How many times the window told of damage that no draw has begun
    /// since.
    pub damage: u64,
    /// The draw in progress.
    pub drawing: Option<Drawing>,
    /// Every draw, in order.
    pub draws: Vec<Draw>,
    /// How many things asked for a draw: a frame published, a new size
    /// told and damage told.
    pub asked: u64,
    /// Whether the idle second is under way.
    pub idling: bool,
    /// What the idle second showed, once it has begun.
    pub idle: Option<Idle>,
}

impl Tally {
    /// Takes in one thing that happened at `at_ns`.
    pub fn note(&mut self, at_ns: u64, happened: &Happened) {
        match happened {
            Happened::Opened { size, .. } => self.told = Some(*size),
            Happened::Resized(size) => {
                self.told = Some(*size);
                self.ask();
            }
            Happened::Damaged => {
                self.damage += 1;
                self.ask();
            }
            Happened::Hidden(_) | Happened::Told(_) => {}
            Happened::Published(frame) => {
                self.published = Some(*frame);
                self.ask();
            }
            Happened::Began { frame, target } => {
                let served = Served {
                    frame: self.shown.is_none_or(|(shown, _)| shown != *frame),
                    size: self.shown.is_some_and(|(_, on)| on != *target),
                    damage: self.damage > 0,
                };
                // The damage told so far is this draw's to answer: what is
                // told from here on is the next one's.
                self.drawing = Some(Drawing {
                    frame: *frame,
                    target: *target,
                    damage: std::mem::take(&mut self.damage),
                });
                self.draws.push(Draw {
                    began_ns: at_ns,
                    presented: false,
                    served,
                    idle: self.idling,
                });
            }
            Happened::Ended { presented, .. } => {
                let Some(drawing) = self.drawing.take() else {
                    return;
                };
                if !*presented {
                    // Nothing was answered: the damage is still told.
                    self.damage += drawing.damage;
                    return;
                }
                self.shown = Some((drawing.frame, drawing.target));
                if let Some(draw) = self.draws.last_mut() {
                    draw.presented = true;
                    if let (true, Some(idle)) = (draw.idle, &mut self.idle) {
                        idle.drawn += 1;
                    }
                }
            }
            Happened::Idle(true) => {
                self.idle = Some(Idle {
                    settled: self.settled(),
                    drawn: 0,
                    asked: 0,
                });
                self.idling = true;
            }
            Happened::Idle(false) => self.idling = false,
        }
    }

    /// Counts one thing that asked for a draw.
    fn ask(&mut self) {
        self.asked += 1;
        if let (true, Some(idle)) = (self.idling, &mut self.idle) {
            idle.asked += 1;
        }
    }

    /// What is asked for and not yet shown.
    pub fn wanted(&self) -> Served {
        let shown = self.shown;
        Served {
            frame: self
                .published
                .is_some_and(|published| shown.is_none_or(|(frame, _)| frame != Some(published))),
            size: shown.is_some_and(|(_, on)| self.told.is_some_and(|told| told != on)),
            damage: self.damage > 0,
        }
    }

    /// Whether a frame is shown and nothing more is asked for or being
    /// drawn.
    pub fn settled(&self) -> bool {
        self.shown.is_some() && self.drawing.is_none() && self.wanted().nothing()
    }

    /// The draws that were for nothing, each with its number from 1.
    pub fn unasked(&self) -> Vec<(usize, Draw)> {
        (1..)
            .zip(self.draws.iter().copied())
            .filter(|(_, draw)| draw.served.nothing())
            .collect()
    }
}

/// What the example decides of what it saw, with no window: these run in
/// the gate.
#[cfg(test)]
mod tests {
    use super::{Happened, Idle, Served};
    use crate::testing::{
        DAMAGE, FRAME, LARGE, MS, PRESENTED, REFUSED, SIZE, SMALL, and, began, served, showing,
        tallied,
    };

    #[test]
    fn a_draw_is_for_the_frame_the_size_and_the_damage_it_is_the_first_to_answer() {
        let tally = tallied(&and(
            showing(),
            &[
                // The window is resized: the frame shown is drawn again
                // there.
                Happened::Resized(LARGE),
                began(1, LARGE),
                PRESENTED,
                // The window says it is damaged: the same again.
                Happened::Damaged,
                began(1, LARGE),
                PRESENTED,
                // A new frame, with damage told as well, and twice: one
                // draw is for both.
                Happened::Published(2),
                Happened::Damaged,
                Happened::Damaged,
                began(2, LARGE),
                PRESENTED,
            ],
        ));
        assert_eq!(
            served(&tally),
            [
                FRAME,
                SIZE,
                DAMAGE,
                Served {
                    frame: true,
                    size: false,
                    damage: true,
                },
            ]
        );
        assert_eq!(tally.unasked(), []);
        assert!(tally.settled());
    }

    #[test]
    fn a_draw_of_what_is_shown_where_it_is_shown_with_no_damage_told_is_for_nothing() {
        // The frame shown is drawn again and again, and nobody asked.
        let storm = [
            began(1, SMALL),
            PRESENTED,
            began(1, SMALL),
            PRESENTED,
            began(1, SMALL),
        ];
        let tally = tallied(&and(showing(), &storm));
        assert_eq!(
            served(&tally),
            [
                FRAME,
                Served::default(),
                Served::default(),
                Served::default()
            ]
        );
        let unasked: Vec<usize> = tally.unasked().iter().map(|(number, _)| *number).collect();
        assert_eq!(unasked, [2, 3, 4]);
        // Each with when it began: the fifth thing that happened, at 5 ms.
        assert_eq!(tally.unasked()[0].1.began_ns, 5 * MS);
    }

    #[test]
    fn what_is_asked_while_a_draw_is_in_progress_is_for_the_next_draw() {
        // What a desktop did as its window opened: while the first frame
        // was being drawn the window said its size three times more, the
        // same frame was published for each, and the system asked for the
        // content again.
        let opening = [
            Happened::Opened {
                size: LARGE,
                refresh: Some(120_000),
            },
            Happened::Published(1),
            began(1, LARGE),
            Happened::Resized(LARGE),
            Happened::Published(1),
            Happened::Resized(LARGE),
            Happened::Published(1),
            Happened::Resized(LARGE),
            Happened::Published(1),
            Happened::Damaged,
            PRESENTED,
        ];
        let first = tallied(&opening);
        // The first frame is shown, and the window is not settled: the
        // damage is still to be answered. The size and the frame said
        // again ask for nothing.
        assert_eq!(first.wanted(), DAMAGE);
        assert!(!first.settled());

        // The draw that answers it is for the damage, and then nothing is
        // left.
        let second = tallied(&and(opening.to_vec(), &[began(1, LARGE), PRESENTED]));
        assert_eq!(served(&second), [FRAME, DAMAGE]);
        assert_eq!(second.unasked(), []);
        assert_eq!(second.wanted(), Served::default());
        assert!(second.settled());

        // What was said again gave nothing to draw for: a third draw is
        // for nothing.
        let third = tallied(&and(
            opening.to_vec(),
            &[began(1, LARGE), PRESENTED, began(1, LARGE), PRESENTED],
        ));
        assert_eq!(served(&third), [FRAME, DAMAGE, Served::default()]);
    }

    #[test]
    fn a_draw_that_did_not_present_leaves_what_it_was_for_to_the_next() {
        let tally = tallied(&and(
            showing(),
            &[
                Happened::Damaged,
                began(1, SMALL),
                REFUSED,
                // Tried again: still for the damage.
                began(1, SMALL),
                PRESENTED,
                // A new frame and a new size, refused, then drawn.
                Happened::Published(2),
                Happened::Resized(LARGE),
                began(2, LARGE),
                REFUSED,
                began(2, LARGE),
                PRESENTED,
                // And then nothing is left to draw for.
                began(2, LARGE),
                PRESENTED,
            ],
        ));
        let both = Served {
            frame: true,
            size: true,
            damage: false,
        };
        assert_eq!(
            served(&tally),
            [FRAME, DAMAGE, DAMAGE, both, both, Served::default()]
        );
        assert_eq!(
            tally
                .draws
                .iter()
                .map(|draw| draw.presented)
                .collect::<Vec<_>>(),
            [true, false, true, false, true, true]
        );
    }

    #[test]
    fn a_window_is_settled_once_what_was_asked_is_shown_and_no_draw_is_in_progress() {
        let opened = Happened::Opened {
            size: SMALL,
            refresh: None,
        };
        // Nothing is shown yet.
        assert!(!tallied(std::slice::from_ref(&opened)).settled());
        let published = [opened, Happened::Published(1)];
        assert_eq!(tallied(&published).wanted(), FRAME);
        // Nor while the first draw is in progress.
        let drawing = and(published.to_vec(), &[began(1, SMALL)]);
        assert!(!tallied(&drawing).settled());
        // Shown: settled.
        assert!(tallied(&showing()).settled());

        // A frame published and not yet shown, a size told and not yet
        // drawn at, and damage not yet answered each unsettle it.
        for (asked, wanted) in [
            (Happened::Published(2), FRAME),
            (Happened::Resized(LARGE), SIZE),
            (Happened::Damaged, DAMAGE),
        ] {
            let tally = tallied(&and(showing(), &[asked]));
            assert_eq!(tally.wanted(), wanted);
            assert!(!tally.settled());
        }
        // The frame shown, published again, the size drawn at, told again,
        // and what else a window tells do not.
        for said in [
            Happened::Published(1),
            Happened::Resized(SMALL),
            Happened::Hidden(false),
            Happened::Told("Refresh(Some(60000))".to_owned()),
        ] {
            let tally = tallied(&and(showing(), std::slice::from_ref(&said)));
            assert!(tally.settled(), "{said:?}");
        }
        // A size told and then the old one again leaves nothing to draw.
        let back = [Happened::Resized(LARGE), Happened::Resized(SMALL)];
        assert!(tallied(&and(showing(), &back)).settled());
    }

    #[test]
    fn the_idle_second_counts_what_asked_in_it_and_the_draws_that_began_in_it() {
        // Before it has begun, nothing is known of it.
        assert_eq!(tallied(&showing()).idle, None);

        let tally = tallied(&and(
            showing(),
            &[
                Happened::Idle(true),
                Happened::Damaged,
                began(1, SMALL),
                PRESENTED,
                Happened::Resized(LARGE),
                began(1, LARGE),
                // It ends while a draw is in progress: the draw began in
                // it.
                Happened::Idle(false),
                PRESENTED,
                // What comes after is not of it.
                Happened::Damaged,
                began(1, LARGE),
                PRESENTED,
            ],
        ));
        assert_eq!(
            tally.idle,
            Some(Idle {
                settled: true,
                drawn: 2,
                asked: 2,
            })
        );
        assert_eq!(
            tally.draws.iter().map(|draw| draw.idle).collect::<Vec<_>>(),
            [false, true, true, false]
        );

        // One that began before the window had settled says so, and a
        // draw that did not present is not counted.
        let unsettled = tallied(&and(
            showing(),
            &[
                Happened::Damaged,
                Happened::Idle(true),
                began(1, SMALL),
                REFUSED,
                Happened::Idle(false),
            ],
        ));
        assert_eq!(
            unsettled.idle,
            Some(Idle {
                settled: false,
                drawn: 0,
                asked: 0,
            })
        );
    }

    #[test]
    fn a_frame_published_a_new_size_and_damage_each_ask_and_nothing_else_does() {
        let tally = tallied(&and(
            showing(),
            &[
                Happened::Published(1),
                Happened::Resized(SMALL),
                Happened::Damaged,
                Happened::Told("Refresh(Some(60000))".to_owned()),
                Happened::Idle(true),
                Happened::Idle(false),
            ],
        ));
        // The frame published as the window opened, and these three: the
        // count is of what asked, whether or not it gave anything to draw.
        assert_eq!(tally.asked, 4);
    }
}
