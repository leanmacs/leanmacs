//! The port's fake: [`Lcs`], a longest common subsequence of lines, found
//! by the textbook table.
//!
//! It is quadratic in time and space, and plainly right: it is what the
//! core's tests and the contract run on, over texts of a few lines. A real
//! engine is faster and may pick other hunks of the same texts; the
//! contract holds only what every engine keeps.

use crate::{Hunk, LineDiff};

/// A line diff by the longest common subsequence of the lines: of two
/// lines that could each be matched, the old text's is given up first.
#[derive(Debug, Clone, Copy, Default)]
pub struct Lcs;

impl LineDiff for Lcs {
    fn hunks(&mut self, old: &[&[u8]], new: &[&[u8]]) -> Vec<Hunk> {
        // `longest[i][j]`: the longest common subsequence of `old[i..]` and
        // `new[j..]`.
        let mut longest = vec![vec![0usize; new.len() + 1]; old.len() + 1];
        for i in (0..old.len()).rev() {
            for j in (0..new.len()).rev() {
                longest[i][j] = if old[i] == new[j] {
                    longest[i + 1][j + 1] + 1
                } else {
                    longest[i + 1][j].max(longest[i][j + 1])
                };
            }
        }
        let mut hunks = Vec::new();
        let (mut i, mut j) = (0, 0);
        let mut open: Option<(usize, usize)> = None;
        while i < old.len() || j < new.len() {
            if i < old.len() && j < new.len() && old[i] == new[j] {
                if let Some((first_old, first_new)) = open.take() {
                    hunks.push(Hunk {
                        old: first_old..i,
                        new: first_new..j,
                    });
                }
                i += 1;
                j += 1;
                continue;
            }
            open.get_or_insert((i, j));
            if j == new.len() || (i < old.len() && longest[i + 1][j] >= longest[i][j + 1]) {
                i += 1;
            } else {
                j += 1;
            }
        }
        if let Some((first_old, first_new)) = open {
            hunks.push(Hunk {
                old: first_old..i,
                new: first_new..j,
            });
        }
        hunks
    }
}
