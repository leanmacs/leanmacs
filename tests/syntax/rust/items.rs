//! A module of a few items, for the syntax adapter's contract.

use std::collections::HashMap;

/// A point on a grid.
#[derive(Debug, Clone, Copy)]
pub struct Point {
    pub row: usize,
    pub column: usize,
}

impl Point {
    /// The point at `row` and `column`.
    pub const fn new(row: usize, column: usize) -> Self {
        Self { row, column }
    }
}

fn count<'a>(words: &[&'a str]) -> HashMap<&'a str, Vec<Option<usize>>> {
    let mut counts = HashMap::new();
    for (index, word) in words.iter().enumerate() {
        counts.entry(*word).or_insert_with(Vec::new).push(Some(index));
    }
    counts
}
