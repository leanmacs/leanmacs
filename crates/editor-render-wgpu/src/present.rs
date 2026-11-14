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
//! surface: no window exists in this phase. The display pipeline's phase
//! 6 writes those calls against a window, from what [`choose`] gives, and
//! takes the measurements that say whether the choice bears out
//! (`docs/dev-practices/on-demand-checks.md`, "The present mode, measured
//! on a window"). Nothing has been measured.
//!
//! The types are this crate's own: no type of wgpu is public here. The
//! adapter that configures a surface maps them to wgpu's.

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

/// How to present, on a surface that offers the modes `offered` and a
/// frame latency within `latency`: the first of [`PREFERRED`] that is
/// offered, and `Fifo` when the offer names none of them, since every
/// back end has it; and [`FRAME_LATENCY`], held to the range offered.
pub fn choose(offered: &[Mode], latency: RangeInclusive<u32>) -> Presentation {
    let mode = PREFERRED
        .into_iter()
        .find(|mode| offered.contains(mode))
        .unwrap_or(Mode::Fifo);
    let (least, most) = (*latency.start(), *latency.end());
    Presentation {
        mode,
        frame_latency: FRAME_LATENCY.max(least).min(most.max(least)),
    }
}

#[cfg(test)]
mod tests {
    use super::{FRAME_LATENCY, Mode, Presentation, choose};

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
            assert_eq!(choose(offered, 1..=3).mode, Mode::Fifo, "{offered:?}");
        }
        // An offer that does not name it, or names nothing: every back
        // end has it all the same.
        assert_eq!(choose(&[Mode::Mailbox], 1..=3).mode, Mode::Fifo);
        assert_eq!(choose(&[], 1..=3).mode, Mode::Fifo);
    }

    #[test]
    fn the_frame_latency_is_one_clamped_into_the_range_offered() {
        let latency = |range| choose(&[Mode::Fifo], range).frame_latency;
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
    fn the_choice_is_fifo_at_a_latency_of_one() {
        assert_eq!(
            choose(&[Mode::Fifo, Mode::Immediate], 1..=3),
            Presentation {
                mode: Mode::Fifo,
                frame_latency: 1,
            }
        );
    }
}
