//! Property tests of the display layers' conversions: a buffer position
//! converted up through the layers and back is the position.
//!
//! Every property runs through [`check`], which fixes the number of cases
//! and the generator's seed, and turns failure persistence off so no file
//! is written beside the sources. The `proptest!` macro is not used, since
//! its configuration reads `PROPTEST_*` variables from the environment.
//!
//! The texts favour what breaks a conversion: tabs at every column, a
//! carriage return before a line feed and alone, characters of one to four
//! bytes, empty rows, and one case in eight a row longer than a segment.

use std::fmt::Debug;

use editor_layout::layer::{Bias, Layer};
use editor_layout::tabs::{SEGMENT_BYTES, TabLayer};
use editor_text::{Snapshot, Text};
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::sample::select;
use proptest::test_runner::{Config, RngAlgorithm, TestCaseError, TestRng, TestRunner};

/// Runs `property` on `cases` values of `strategy`, from a fixed seed.
fn check<S>(cases: u32, strategy: S, property: impl Fn(S::Value) -> Result<(), TestCaseError>)
where
    S: Strategy,
    S::Value: Debug,
{
    let config = Config {
        cases,
        failure_persistence: None,
        ..Config::default()
    };
    let mut runner =
        TestRunner::new_with_rng(config, TestRng::deterministic_rng(RngAlgorithm::ChaCha));
    if let Err(failure) = runner.run(&strategy, property) {
        panic!("{failure}");
    }
}

/// A text of the pieces that break conversions, and now and then a row
/// longer than a segment.
fn texts() -> impl Strategy<Value = String> {
    let piece = select(vec![
        "a", "\t", "é", "😀", "€", "\r\n", "\n", "\r", " ", "ab\tc",
    ]);
    let short = vec(piece, 0..40).prop_map(|pieces| pieces.concat());
    prop_oneof![
        7 => short,
        1 => (vec(select(vec!["x", "é", "\t"]), 1..4), 1usize..3).prop_map(|(unit, rows)| {
            let row = unit.concat().repeat(SEGMENT_BYTES / 2 + 7);
            vec![row; rows].join("\n")
        }),
    ]
}

/// The positions of `snapshot` a property checks, in order: every one of a
/// short text; of a long one, every 37th and those within 8 bytes of a
/// multiple of a segment, where the cuts are. A conversion reads its whole
/// segment, so every position of a long row would cost its square.
fn positions(snapshot: &Snapshot) -> Vec<usize> {
    let long = snapshot.len() > 1000;
    (0..=snapshot.len())
        .filter(|&offset| snapshot.is_char_boundary(offset))
        .filter(|&offset| {
            let from_a_cut = offset % SEGMENT_BYTES;
            !long || offset % 37 == 0 || !(8..SEGMENT_BYTES - 8).contains(&from_a_cut)
        })
        .collect()
}

/// Whether `offset` is between a carriage return and its line feed: the
/// one position that converts to the row's end and comes back as it.
fn inside_a_line_break(text: &str, offset: usize) -> bool {
    offset > 0
        && text.as_bytes().get(offset - 1) == Some(&b'\r')
        && text.as_bytes().get(offset) == Some(&b'\n')
}

#[test]
fn a_position_converted_to_the_tab_layer_and_back_is_the_position() {
    check(64, (texts(), 1usize..9), |(text, tab_width)| {
        let snapshot = Text::from(text.as_str()).snapshot();
        let layer = TabLayer::new(snapshot.clone(), tab_width);
        for offset in positions(&snapshot) {
            let point = layer
                .to_layer(offset, Bias::Before)
                .ok_or_else(|| TestCaseError::fail(format!("no point at {offset}")))?;
            let back = layer.to_below(point, Bias::Before);
            let expected = if inside_a_line_break(&text, offset) {
                offset - 1
            } else {
                offset
            };
            prop_assert_eq!(back, Some(expected), "at {} ({:?})", offset, point);
        }
        Ok(())
    });
}

#[test]
fn a_column_inside_a_tabs_spaces_goes_back_to_the_tab() {
    check(64, (texts(), 2usize..9), |(text, tab_width)| {
        let snapshot = Text::from(text.as_str()).snapshot();
        let layer = TabLayer::new(snapshot.clone(), tab_width);
        for offset in positions(&snapshot) {
            if text[offset..].starts_with('\t') {
                let mut point = layer.to_layer(offset, Bias::Before).unwrap();
                let after = layer.to_layer(offset + 1, Bias::Before).unwrap();
                if after.segment != point.segment {
                    continue;
                }
                for column in point.column..after.column {
                    point.column = column;
                    prop_assert_eq!(layer.to_below(point, Bias::Before), Some(offset));
                }
            }
        }
        Ok(())
    });
}
