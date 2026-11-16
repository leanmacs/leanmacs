//! The line diff port's real adapter: [`ImaraDiff`], a [`LineDiff`] over
//! imara-diff's histogram algorithm.
//!
//! The port, its fake, its contract and the core round it (the common head
//! and tail, the line limit, the trim of each hunk to a character
//! boundary) are `editor-diff`'s. This crate is thin: it interns the lines
//! it is handed, asks the library for the hunks, has the library slide
//! them to where a person would put them (`postprocess_lines`, which moves
//! an ambiguous hunk by its lines' indentation), and hands them back as
//! the port's [`Hunk`]s. No imara-diff type is public, and no other crate
//! depends on the library (`deny.toml`).
//!
//! What it decides:
//!
//! - **The algorithm is the histogram diff**, the library's default and
//!   git's `--histogram`: it favours hunks a person reads as one change
//!   over a minimal script, and the core asks it about at most the line
//!   limit's lines.
//! - **More lines than the library takes** (it asserts fewer than
//!   `i32::MAX` tokens a side) are one hunk of everything, so the adapter
//!   never panics on its input. The editor's limit is far below that.

use editor_diff::{Hunk, LineDiff};
use imara_diff::{Algorithm, Diff, InternedInput};

/// The most lines a side the library takes.
const MOST: usize = i32::MAX as usize - 1;

/// A line diff over imara-diff's histogram algorithm.
#[derive(Debug, Clone, Copy, Default)]
pub struct ImaraDiff;

impl ImaraDiff {
    /// The adapter.
    pub fn new() -> Self {
        Self
    }
}

impl LineDiff for ImaraDiff {
    fn hunks(&mut self, old: &[&[u8]], new: &[&[u8]]) -> Vec<Hunk> {
        if old.len() > MOST || new.len() > MOST {
            return vec![Hunk {
                old: 0..old.len(),
                new: 0..new.len(),
            }];
        }
        let mut input = InternedInput::default();
        input.update_before(old.iter().copied());
        input.update_after(new.iter().copied());
        let mut diff = Diff::compute(Algorithm::Histogram, &input);
        diff.postprocess_lines(&input);
        diff.hunks()
            .map(|hunk| Hunk {
                old: hunk.before.start as usize..hunk.before.end as usize,
                new: hunk.after.start as usize..hunk.after.end as usize,
            })
            .collect()
    }
}
