//! The builders the tests of the example's modules share: sizes a window
//! has, things entered in a ledger, and what a draw was for.

use editor_render::port::Target;
use editor_render_wgpu::Masks;

use crate::tally::{Happened, Served, Tally};

/// A size a window has.
pub const SMALL: Target = Target {
    width: 400,
    height: 300,
    scale: 1.0,
};

/// Another.
pub const LARGE: Target = Target {
    width: 800,
    height: 600,
    scale: 2.0,
};

/// A millisecond, in nanoseconds.
pub const MS: u64 = 1_000_000;

/// A draw of frame `frame` on `target` begins.
pub fn began(frame: usize, target: Target) -> Happened {
    Happened::Began {
        frame: Some(frame),
        target,
    }
}

/// The draw last begun presented, by a renderer that does not say
/// which masks it used.
pub const PRESENTED: Happened = Happened::Ended {
    presented: true,
    masks: None,
};

/// The draw last begun did not present.
pub const REFUSED: Happened = Happened::Ended {
    presented: false,
    masks: None,
};

/// The draw last begun presented, with its glyphs as `masks`.
pub fn presented_as(masks: Masks) -> Happened {
    Happened::Ended {
        presented: true,
        masks: Some(masks),
    }
}

/// `happened`, each a millisecond after the one before, the first at a
/// millisecond.
pub fn records(happened: &[Happened]) -> Vec<(u64, Happened)> {
    (1..)
        .map(|at| at * MS)
        .zip(happened.iter().cloned())
        .collect()
}

/// What `happened` comes to.
pub fn tallied(happened: &[Happened]) -> Tally {
    let mut tally = Tally::default();
    for (at_ns, happened) in records(happened) {
        tally.note(at_ns, &happened);
    }
    tally
}

/// What each draw of `tally` was for, in order.
pub fn served(tally: &Tally) -> Vec<Served> {
    tally.draws.iter().map(|draw| draw.served).collect()
}

/// A draw for a frame alone, for a size alone, for damage alone.
pub const FRAME: Served = Served {
    frame: true,
    size: false,
    damage: false,
};
pub const SIZE: Served = Served {
    frame: false,
    size: true,
    damage: false,
};
pub const DAMAGE: Served = Served {
    frame: false,
    size: false,
    damage: true,
};

/// A window that opened at `SMALL` and shows frame 1 there.
pub fn showing() -> Vec<Happened> {
    vec![
        Happened::Opened {
            size: SMALL,
            refresh: None,
        },
        Happened::Published(1),
        began(1, SMALL),
        PRESENTED,
    ]
}

/// `first`, then `then`.
pub fn and(first: Vec<Happened>, then: &[Happened]) -> Vec<Happened> {
    first.into_iter().chain(then.iter().cloned()).collect()
}
