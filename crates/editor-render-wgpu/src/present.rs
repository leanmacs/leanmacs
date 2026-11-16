//! How a frame is presented to a window: the present mode and the frame
//! latency, chosen from what a surface offers.
//!
//! The choice is a decision on record
//! (`docs/design/rendering-prior-art.md`, "Present mode and pacing"):
//! `Fifo`, with a frame latency of 1, on every platform. `Fifo` is the
//! one mode every back end has and it does not tear; an editor draws on
//! demand, so the frames a mode that drops or tears would save are frames
//! that are never drawn; and a latency of 1 is what wgpu recommends for a
//! user interface that does little GPU work a frame and wants low
//! latency.
//!
//! [`choose`] is that decision as a pure function, so the record cannot
//! drift from the code. Nothing here makes, configures or presents to a
//! surface: the device does (the module `gpu`), for a renderer made on a
//! window, and it configures the surface with what [`choose`] gives for
//! the modes the surface offers. A surface does not say what frame
//! latencies it takes, so the device asks for [`FRAME_LATENCY`] and wgpu
//! holds it to what the back end allows.
//!
//! To measure the choice against another, one run may ask for another
//! mode, another latency or both ([`Asked`], in
//! [`Settings::presentation`](crate::Settings::presentation)): it is given
//! the mode it asks for when the surface offers it, and its latency held
//! to the range offered, and [`choose`] fills in the half it does not ask
//! for, so that what applies when nothing is asked is said here alone. It
//! is not a setting of the editor: the decision stands until the
//! measurements say otherwise, and then it changes here and in the record
//! in one commit. A renderer on a window says what its surface offered,
//! only what was asked, and what it was configured with ([`Offered`]).
//! How a window's figures are taken is in
//! `docs/dev-practices/on-demand-checks.md`, "The present mode, measured
//! on a window".
//!
//! The types are this crate's own: no type of wgpu is public here. The
//! module `surface` maps them to wgpu's and back.

use std::ops::RangeInclusive;

/// A way a frame reaches the display, by wgpu's names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Mode {
    /// Frames wait in a queue for the display's refresh, each shown for a
    /// whole refresh: no tearing. Every back end has it.
    Fifo,
    /// As `Fifo`, but a frame that arrives late is shown at once, tearing.
    FifoRelaxed,
    /// A frame is shown the moment it is presented, tearing.
    Immediate,
    /// The newest frame presented replaces one that is waiting, at the
    /// refresh: no tearing, and frames are dropped.
    Mailbox,
}

/// The modes in the order they are preferred. One, today: what would be
/// added is added here.
pub const PREFERRED: [Mode; 1] = [Mode::Fifo];

/// How many frames may wait to be shown: 1.
pub const FRAME_LATENCY: u32 = 1;

/// How frames are presented.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Presentation {
    /// The present mode.
    pub mode: Mode,
    /// How many frames may wait to be shown.
    pub frame_latency: u32,
}

/// What a run asks for in place of the decision, to measure another
/// presentation: each half on its own, `None` for the decision's.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Asked {
    /// The present mode asked for.
    pub mode: Option<Mode>,
    /// The frame latency asked for.
    pub frame_latency: Option<u32>,
}

impl Asked {
    /// Nothing asked: the decision.
    pub const NOTHING: Self = Self {
        mode: None,
        frame_latency: None,
    };
}

/// What a surface offered, what a run asked for, and what the surface was
/// configured with ([`WgpuRenderer::presentation`](crate::WgpuRenderer::presentation)).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Offered {
    /// The modes the surface offered, in its order: those this crate has a
    /// name for.
    pub modes: Vec<Mode>,
    /// What the run asked for, and only that: a half it did not ask for is
    /// `None`.
    pub asked: Asked,
    /// What the surface was configured with. A mode asked for that is not
    /// this one was not offered.
    pub configured: Presentation,
}

/// How to present, on a surface that offers the modes `offered` and a
/// frame latency within `latency`.
///
/// With nothing `asked`, it is the decision: the first of [`PREFERRED`]
/// that is offered, and `Fifo` when the offer names none of them, since
/// every back end has it; and [`FRAME_LATENCY`], held to the range
/// offered. A run that asks for a presentation, to measure another
/// (`docs/dev-practices/on-demand-checks.md`), is given the mode it asks
/// for when the surface offers it, and the decision's otherwise or when it
/// asks for none; and the latency it asks for, or the decision's when it
/// asks for none, held to the range offered.
pub fn choose(offered: &[Mode], latency: RangeInclusive<u32>, asked: Asked) -> Presentation {
    let preferred = PREFERRED
        .into_iter()
        .find(|mode| offered.contains(mode))
        .unwrap_or(Mode::Fifo);
    let mode = asked
        .mode
        .filter(|mode| offered.contains(mode))
        .unwrap_or(preferred);
    let wanted = asked.frame_latency.unwrap_or(FRAME_LATENCY);
    let (least, most) = (*latency.start(), *latency.end());
    Presentation {
        mode,
        frame_latency: wanted.max(least).min(most.max(least)),
    }
}

#[cfg(test)]
mod tests {
    use super::{Asked, FRAME_LATENCY, Mode, Presentation, choose};

    #[test]
    fn fifo_is_chosen_from_any_offer() {
        // What wgpu's Metal back end reports, what its OpenGL back end
        // reports off Windows, and every mode, as a Vulkan surface may
        // report them, in two orders.
        let offers: [&[Mode]; 5] = [
            &[Mode::Fifo, Mode::Immediate],
            &[Mode::Fifo],
            &[
                Mode::Fifo,
                Mode::FifoRelaxed,
                Mode::Immediate,
                Mode::Mailbox,
            ],
            &[
                Mode::Mailbox,
                Mode::Immediate,
                Mode::FifoRelaxed,
                Mode::Fifo,
            ],
            &[Mode::Immediate, Mode::Fifo],
        ];
        for offered in offers {
            assert_eq!(
                choose(offered, 1..=3, Asked::NOTHING).mode,
                Mode::Fifo,
                "{offered:?}"
            );
        }
        // An offer that does not name it, or names nothing: every back
        // end has it all the same.
        assert_eq!(
            choose(&[Mode::Mailbox], 1..=3, Asked::NOTHING).mode,
            Mode::Fifo
        );
        assert_eq!(choose(&[], 1..=3, Asked::NOTHING).mode, Mode::Fifo);
    }

    #[test]
    fn the_frame_latency_is_one_clamped_into_the_range_offered() {
        let latency = |range| choose(&[Mode::Fifo], range, Asked::NOTHING).frame_latency;
        assert_eq!(FRAME_LATENCY, 1);
        assert_eq!(latency(1..=3), 1);
        assert_eq!(latency(1..=1), 1);
        assert_eq!(latency(0..=8), 1);
        // A back end whose least is more than one, and one that takes
        // none.
        assert_eq!(latency(2..=3), 2);
        assert_eq!(latency(0..=0), 0);
    }

    #[test]
    fn a_mode_asked_for_is_chosen_when_the_surface_offers_it() {
        let immediate = Asked {
            mode: Some(Mode::Immediate),
            frame_latency: Some(1),
        };
        assert_eq!(
            choose(&[Mode::Fifo, Mode::Immediate], 1..=3, immediate),
            Presentation {
                mode: Mode::Immediate,
                frame_latency: 1,
            }
        );
        // Not offered: the decision's, as if no mode were asked.
        assert_eq!(choose(&[Mode::Fifo], 1..=3, immediate).mode, Mode::Fifo);
        assert_eq!(choose(&[Mode::Mailbox], 1..=3, immediate).mode, Mode::Fifo);
    }

    #[test]
    fn a_frame_latency_asked_for_is_held_to_the_range_offered() {
        let latency = |frame_latency, range| {
            let asked = Asked {
                mode: Some(Mode::Fifo),
                frame_latency: Some(frame_latency),
            };
            choose(&[Mode::Fifo], range, asked).frame_latency
        };
        assert_eq!(latency(2, 1..=3), 2);
        assert_eq!(latency(5, 1..=3), 3);
        assert_eq!(latency(0, 1..=3), 1);
    }

    #[test]
    fn a_latency_asked_for_alone_keeps_the_decided_mode() {
        let latency_only = Asked {
            mode: None,
            frame_latency: Some(2),
        };
        // The decision's mode, from offers in either order, and the latency
        // asked, held to the range.
        for offered in [
            &[Mode::Immediate, Mode::Fifo][..],
            &[Mode::Fifo, Mode::Mailbox],
        ] {
            assert_eq!(
                choose(offered, 1..=3, latency_only),
                Presentation {
                    mode: Mode::Fifo,
                    frame_latency: 2,
                },
                "{offered:?}"
            );
        }
        assert_eq!(choose(&[Mode::Fifo], 3..=4, latency_only).frame_latency, 3);
    }

    #[test]
    fn a_mode_asked_for_alone_keeps_the_decided_latency() {
        let mode_only = Asked {
            mode: Some(Mode::Mailbox),
            frame_latency: None,
        };
        assert_eq!(
            choose(&[Mode::Fifo, Mode::Mailbox], 1..=3, mode_only),
            Presentation {
                mode: Mode::Mailbox,
                frame_latency: FRAME_LATENCY,
            }
        );
        // The decision's latency, held to the range as it is when nothing
        // is asked.
        assert_eq!(
            choose(&[Mode::Mailbox], 2..=3, mode_only).frame_latency,
            choose(&[Mode::Mailbox], 2..=3, Asked::NOTHING).frame_latency
        );
    }

    #[test]
    fn the_choice_is_fifo_at_a_latency_of_one() {
        assert_eq!(
            choose(&[Mode::Fifo, Mode::Immediate], 1..=3, Asked::NOTHING),
            Presentation {
                mode: Mode::Fifo,
                frame_latency: 1,
            }
        );
    }
}
