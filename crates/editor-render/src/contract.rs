//! The contract of the [`Renderer`] port: the rules the fake and every real
//! adapter are held to.
//!
//! [`check`] draws a fixed set of frames through fresh renderers and
//! returns the names of the properties that fail. The published fake runs
//! it in `tests/renderer_contract.rs`; a real adapter runs it in its own
//! crate's tests.
//!
//! The rules are about what a renderer says it built, which is what the
//! port returns: a row whose content hash it has drawn under the same
//! generation and scale is not built again. They say nothing of pixels, of
//! glyph images or of time: a picture is each adapter's to check.
//!
//! The frames are laid out here, on layout's fake shaper, from scenes of
//! one view with a status row. What a renderer must have built for a frame
//! is read from the frames' own row hashes, the hashes the frame shows
//! that the frame before it did not, and never from a number of rows
//! written down here: which rows of two frames hash alike is layout's
//! rule, pinned by layout's tests.

use std::collections::HashSet;
use std::sync::Arc;

use editor_layout::Layout;
use editor_layout::frame::Frame;
use editor_layout::scene::{Rect, Scene, StatusField};
use editor_layout::shaper::fake::CellShaper;

use crate::port::{DrawRequest, Drawn, Renderer, Target};
use crate::rows::shown;

/// A first frame builds every row it shows.
pub const FIRST: &str = "a first frame builds every row it shows";
/// The same frame again builds none.
pub const SAME: &str = "the same frame again builds none";
/// A frame that differs only in its cursor builds none.
pub const CURSOR: &str = "a frame that differs only in its cursor builds none";
/// A frame that differs in one row builds that row alone.
pub const EDIT: &str = "a frame that differs in one row builds that row alone";
/// A frame scrolled by a row builds only the row that came into view.
pub const SCROLL: &str = "a frame scrolled by a row builds only the row that came into view";
/// A frame of another generation builds every row.
pub const GENERATION: &str = "a frame of another generation builds every row";
/// Another size at the same scale builds none.
pub const RESIZE: &str = "another size at the same scale builds none";
/// Rows built and rows reused are the rows shown, once for each distinct
/// hash.
pub const COUNTS: &str =
    "rows built and rows reused are the rows shown, once for each distinct hash";
/// A frame of no views is presented.
pub const EMPTY: &str = "a frame of no views is presented";

/// Every property, by name.
pub const PROPERTIES: [&str; 9] = [
    FIRST, SAME, CURSOR, EDIT, SCROLL, GENERATION, RESIZE, COUNTS, EMPTY,
];

/// The target the frames are drawn on.
const TARGET: Target = Target {
    width: 400,
    height: 64,
    scale: 1.0,
};

/// The frames the properties are run over.
struct Frames {
    /// Four rows of text, of which the view shows three, and a status row;
    /// no cursor.
    base: Arc<Frame>,
    /// `base` with a cursor on its first row.
    cursor: Arc<Frame>,
    /// `base` with its cursor elsewhere on that row.
    cursor_moved: Arc<Frame>,
    /// `base` with its second row's text changed.
    edited: Arc<Frame>,
    /// `base` scrolled down by one row.
    scrolled: Arc<Frame>,
    /// `base` laid out again after its fonts changed.
    later: Arc<Frame>,
    /// A frame in which two rows are alike.
    alike: Arc<Frame>,
}

/// The scene of `text` in one view the size of [`TARGET`], with a status
/// row.
fn scene(text: &str) -> Scene {
    let rect = Rect {
        x: 0,
        y: 0,
        width: TARGET.width,
        height: TARGET.height,
    };
    let mut scene = Scene::of_text(text, rect);
    scene.views[0].status = vec![StatusField {
        text: "status".to_owned(),
        face: "mode-line".to_owned(),
        ..StatusField::default()
    }];
    scene
}

/// Lays the frames out.
fn frames() -> Frames {
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    let text = "one\ntwo\nthree\nfour";
    let mut frame = |scene: &Scene| Arc::new(layout.frame(scene));
    let base = frame(&scene(text));
    let cursor = frame(&scene(text).selecting(0..0));
    let cursor_moved = frame(&scene(text).selecting(2..2));
    let edited = frame(&scene("one\ntwice\nthree\nfour"));
    let mut down = scene(text);
    down.views[0].scroll = "one\n".len();
    let scrolled = frame(&down);
    let alike = frame(&scene("same\nsame\nother"));
    layout.shaper().change_fonts();
    let later = Arc::new(layout.frame(&scene(text)));
    Frames {
        base,
        cursor,
        cursor_moved,
        edited,
        scrolled,
        later,
        alike,
    }
}

/// The distinct row hashes `frame` shows.
fn hashes(frame: &Frame) -> HashSet<u64> {
    shown(frame).map(|row| row.hash).collect()
}

/// How many distinct row hashes `frame` shows.
fn distinct(frame: &Frame) -> u64 {
    hashes(frame).len() as u64
}

/// How many of the distinct row hashes `after` shows `before` does not.
fn new_in(before: &Frame, after: &Frame) -> u64 {
    hashes(after).difference(&hashes(before)).count() as u64
}

/// A renderer under check, with whether every draw so far held
/// [`COUNTS`].
struct Checked<R> {
    /// The renderer.
    renderer: R,
    /// Whether the rows built and reused of every draw were the distinct
    /// rows its frame shows.
    counted: bool,
}

impl<R: Renderer> Checked<R> {
    /// Draws `frame` on `target`.
    fn draw_on(&mut self, frame: &Arc<Frame>, target: Target) -> Drawn {
        let drawn = self.renderer.draw(&DrawRequest { frame, target });
        self.counted &= drawn.rows_rebuilt + drawn.rows_reused == distinct(frame);
        drawn
    }

    /// Draws `frame` on [`TARGET`].
    fn draw(&mut self, frame: &Arc<Frame>) -> Drawn {
        self.draw_on(frame, TARGET)
    }
}

/// The names of the properties the renderers `make` gives do not hold, in
/// the order of [`PROPERTIES`]. `make` is called for a fresh renderer, one
/// that has drawn nothing, for each sequence of frames.
pub fn check<R: Renderer>(mut make: impl FnMut() -> R) -> Vec<&'static str> {
    let frames = frames();
    let mut counted = true;
    // Draws `first` and then `second` through a fresh renderer: what the
    // second draw said.
    let mut pair = |first: &Arc<Frame>, second: &Arc<Frame>, target: Target| {
        let mut checked = Checked {
            renderer: make(),
            counted: true,
        };
        let before = checked.draw(first);
        let after = checked.draw_on(second, target);
        counted &= checked.counted;
        (before, after)
    };
    let base = &frames.base;
    let (first, same) = pair(base, base, TARGET);
    let (_, cursor) = pair(&frames.cursor, &frames.cursor_moved, TARGET);
    let (_, edited) = pair(base, &frames.edited, TARGET);
    let (_, scrolled) = pair(base, &frames.scrolled, TARGET);
    let (_, later) = pair(base, &frames.later, TARGET);
    let larger = Target {
        width: TARGET.width * 2,
        height: TARGET.height * 2,
        ..TARGET
    };
    let (_, resized) = pair(base, base, larger);
    let (_, _) = pair(&frames.alike, base, TARGET);
    let nothing = Arc::new(Frame::default());
    let (empty, _) = pair(&nothing, &nothing, TARGET);
    let failed = [
        !(first.rows_rebuilt == distinct(base) && first.rows_reused == 0),
        same.rows_rebuilt != 0,
        cursor.rows_rebuilt != new_in(&frames.cursor, &frames.cursor_moved),
        edited.rows_rebuilt != new_in(base, &frames.edited),
        scrolled.rows_rebuilt != new_in(base, &frames.scrolled),
        !(later.rows_rebuilt == distinct(&frames.later) && later.rows_reused == 0),
        resized.rows_rebuilt != 0,
        !counted,
        !empty.presented,
    ];
    PROPERTIES
        .iter()
        .zip(failed)
        .filter_map(|(name, failed)| failed.then_some(*name))
        .collect()
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};
    use std::sync::Arc;

    use editor_layout::frame::{CursorBox, Frame};

    use super::{
        COUNTS, CURSOR, EDIT, EMPTY, FIRST, GENERATION, PROPERTIES, RESIZE, SAME, SCROLL, check,
    };
    use crate::port::{DrawRequest, Drawn, Renderer, Target};

    /// One way a renderer breaks the contract.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Fault {
        /// Says the rows of its first frame were held already.
        ReusesOnFirst,
        /// Builds every row when handed the frame it just drew.
        BuildsTheSameAgain,
        /// Builds every row when the cursors are not the last frame's.
        BuildsOnCursor,
        /// Builds every text row below one it builds.
        BuildsBelowAnEdit,
        /// Keeps a row by where it is as well as by its hash.
        BuildsMovedRows,
        /// Keeps its rows when the generation changes.
        KeepsAcrossGenerations,
        /// Builds every row when the target's size changes.
        BuildsOnResize,
        /// Counts a hash once for each row that has it.
        CountsTwice,
        /// Does not present a frame of no views.
        FailsOnEmpty,
    }

    /// Each fault, with the one property it breaks.
    const FAULTS: [(Fault, &str); 9] = [
        (Fault::ReusesOnFirst, FIRST),
        (Fault::BuildsTheSameAgain, SAME),
        (Fault::BuildsOnCursor, CURSOR),
        (Fault::BuildsBelowAnEdit, EDIT),
        (Fault::BuildsMovedRows, SCROLL),
        (Fault::KeepsAcrossGenerations, GENERATION),
        (Fault::BuildsOnResize, RESIZE),
        (Fault::CountsTwice, COUNTS),
        (Fault::FailsOnEmpty, EMPTY),
    ];

    /// A renderer written out by hand, apart from the row cache the fake
    /// uses: it keeps the rows of the frame it last drew by their hashes,
    /// and holds the contract unless it has a fault.
    struct ByHand {
        /// The way it breaks the contract, if it does.
        fault: Option<Fault>,
        /// The rows it holds: each hash, with where the row was.
        kept: HashMap<u64, f32>,
        /// The frame it last drew, and the target.
        last: Option<(Arc<Frame>, Target)>,
    }

    impl ByHand {
        /// A renderer that has drawn nothing, with `fault`.
        fn new(fault: Option<Fault>) -> Self {
            Self {
                fault,
                kept: HashMap::new(),
                last: None,
            }
        }

        /// Whether it has the fault `fault`.
        fn has(&self, fault: Fault) -> bool {
            self.fault == Some(fault)
        }

        /// Whether what it holds is of no use for `frame` on `target`.
        fn starts_again(&self, frame: &Arc<Frame>, target: Target) -> bool {
            let Some((last, on)) = &self.last else {
                return false;
            };
            let size = |target: &Target| (target.width, target.height);
            (last.generation != frame.generation && !self.has(Fault::KeepsAcrossGenerations))
                || on.scale != target.scale
                || (self.has(Fault::BuildsTheSameAgain)
                    && Arc::ptr_eq(last, frame)
                    && *on == target)
                || (self.has(Fault::BuildsOnCursor) && cursors(last) != cursors(frame))
                || (self.has(Fault::BuildsOnResize) && size(on) != size(&target))
        }
    }

    /// The cursors of every view of `frame`.
    fn cursors(frame: &Frame) -> Vec<CursorBox> {
        frame
            .views
            .iter()
            .flat_map(|view| view.cursors.iter().copied())
            .collect()
    }

    impl Renderer for ByHand {
        fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
            let (frame, target) = (request.frame, request.target);
            if frame.views.is_empty() && self.has(Fault::FailsOnEmpty) {
                return Drawn::default();
            }
            if self.starts_again(frame, target) {
                self.kept.clear();
            }
            let (mut rebuilt, mut reused) = (0, 0);
            let mut seen = HashSet::new();
            let mut now = HashMap::new();
            for view in &frame.views {
                // Each row's hash and top, and whether it is a text row.
                let text = view.rows.iter().map(|row| (row.hash, row.y, true));
                let status = view.status.iter().map(|row| (row.hash, row.y, false));
                let mut below = false;
                for (hash, y, is_text) in text.chain(status) {
                    let again = !seen.insert(hash);
                    if again && !self.has(Fault::CountsTwice) {
                        continue;
                    }
                    let held = again
                        || self
                            .kept
                            .get(&hash)
                            .is_some_and(|at| !self.has(Fault::BuildsMovedRows) || *at == y);
                    let forced = below && is_text && self.has(Fault::BuildsBelowAnEdit);
                    if held && !forced {
                        reused += 1;
                    } else {
                        rebuilt += 1;
                        below = true;
                    }
                    now.insert(hash, y);
                }
            }
            if self.last.is_none() && self.has(Fault::ReusesOnFirst) {
                reused += rebuilt;
                rebuilt = 0;
            }
            self.kept = now;
            self.last = Some((Arc::clone(frame), target));
            Drawn {
                presented: true,
                rows_rebuilt: rebuilt,
                rows_reused: reused,
                ..Drawn::default()
            }
        }
    }

    #[test]
    fn a_renderer_that_keeps_its_rows_by_their_hashes_holds_every_property() {
        assert_eq!(check(|| ByHand::new(None)), Vec::<&str>::new());
    }

    #[test]
    fn each_property_fails_alone_on_a_renderer_written_to_break_it() {
        for (fault, property) in FAULTS {
            assert_eq!(
                check(|| ByHand::new(Some(fault))),
                vec![property],
                "{fault:?}"
            );
        }
        // And every property has such a renderer.
        let broken: Vec<&str> = FAULTS.iter().map(|(_, property)| *property).collect();
        assert_eq!(broken, PROPERTIES);
    }

    /// A renderer that builds nothing and presents nothing.
    struct Inert;

    impl Renderer for Inert {
        fn draw(&mut self, _request: &DrawRequest<'_>) -> Drawn {
            Drawn::default()
        }
    }

    #[test]
    fn a_renderer_that_does_nothing_fails_by_name() {
        let failed = check(|| Inert);
        // It builds no row of a first frame or of another generation,
        // counts none and presents nothing.
        for property in [FIRST, GENERATION, COUNTS, EMPTY] {
            assert!(failed.contains(&property), "{property}");
        }
        // What asks only that nothing be built, it holds.
        for property in [SAME, RESIZE] {
            assert!(!failed.contains(&property), "{property}");
        }
    }
}
