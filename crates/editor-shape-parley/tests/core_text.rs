//! The shaper places glyphs where Core Text does.
//!
//! The sentence of the Core Text captures, "the window draws this", laid
//! out through [`ParleyShaper`] over the fixture font Noto Sans Mono alone,
//! at 28 pixels (14 points at scale 2) and at 14 (14 points at scale 1),
//! against the places Core Text gave its glyphs on macOS
//! (`tests/coretext/positions.txt`, compiled in): each glyph is Core
//! Text's glyph, and each pen place across, and the line's end, is within
//! [`BOUND`] of Core Text's. With the painter's rule (it floors a place to
//! Core Text's own grid, `editor-render-wgpu`'s `placement_tests`), this
//! bounds a glyph's place on screen against Core Text's.
//!
//! Measured on 2026-11-20: the worst error was 0.000 px at both sizes (to
//! the printed digits; Parley's pen places are the font's advances summed
//! in f32, and Core Text's are the same advances in f64). Seen to bite
//! once by hand: with one place of a copy of the positions moved by 0.3
//! px, the test failed at that glyph.

mod common;
#[path = "common/core_text.rs"]
mod core_text;

use editor_layout::shaper::{FontSpec, Length, Shaper};
use editor_shape_parley::{FontSet, ParleyShaper};

use common::{MONO, MONO_FAMILY, in_font, one_line};
use core_text::{FIXTURE, SENTENCE, at_scale, errors, places, worst};

/// How far a pen place may be from Core Text's, in pixels: an eighth of a
/// pixel, so that with the painter's grid a glyph is drawn where Core Text
/// draws it.
const BOUND: f64 = 0.125;

/// The sentence laid out in the fixture font at `pixels`: each glyph's id,
/// its pen place across and its advance.
fn laid_out(pixels: u32) -> Vec<(u32, f64, f64)> {
    let fonts = FontSet::only(MONO_FAMILY, &[], [MONO.to_vec()]).expect("the fixture font");
    let shaper = ParleyShaper::new(fonts);
    let font = shaper.font(&FontSpec {
        size: Length::pixels(pixels),
        ..FontSpec::default()
    });
    let line = one_line(&shaper, &in_font(SENTENCE, font));
    line.glyphs
        .iter()
        .map(|glyph| {
            (
                glyph.id,
                f64::from(glyph.x + glyph.dx),
                f64::from(glyph.advance),
            )
        })
        .collect()
}

#[test]
fn the_positions_file_is_read_and_has_the_sentence_at_both_scales() {
    let all = places(FIXTURE).expect("Core Text's places");
    for scale in [1, 2] {
        assert_eq!(at_scale(&all, scale).len(), SENTENCE.len(), "at {scale}");
    }
    assert!(places("1 85 0.0 0.0").is_err());
    assert!(places("# a comment\n\n1 85 0.0 0.0 8.4\n").is_ok());
}

#[test]
fn the_shaper_places_each_glyph_where_core_text_does_at_both_sizes() {
    let all = places(FIXTURE).expect("Core Text's places");
    for (scale, pixels) in [(2, 28), (1, 14)] {
        let theirs = at_scale(&all, scale);
        let ours = laid_out(pixels);
        let (each, end) = errors(&ours, &theirs).unwrap_or_else(|| {
            panic!("{} glyphs at {pixels} px, not {}", ours.len(), theirs.len())
        });
        for error in &each {
            assert!(error.same_glyph, "glyph {} at {pixels} px", error.index);
            assert!(
                error.across.abs() <= BOUND,
                "glyph {} at {pixels} px is {:.4} px from Core Text's",
                error.index,
                error.across
            );
        }
        assert!(
            end.abs() <= BOUND,
            "the line's end at {pixels} px is {end:.4} px off"
        );
        println!(
            "at {pixels} px the worst error is {:.4} px",
            worst(&each, end)
        );
    }
}
