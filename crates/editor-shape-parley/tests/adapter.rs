//! The adapter's own rules, on the fixture fonts: what a `shape` call and a
//! break cost, where a font's metrics come from, and the texts a paragraph
//! layout would treat as something other than a line of characters.
//!
//! No test states a number of Parley's or of a font's: each compares what
//! the adapter gives with what it gives elsewhere.

mod common;

use std::ops::Range;

use editor_layout::shaper::{
    FontId, FontSpec, Length, LineHeight, ResolvedFont, ShapedLine, Shaper, VisualLine, Weight,
};
use editor_shape_parley::{FontSet, ParleyLine, ParleyShaper, ShapeCounters};

use common::{
    HEBREW, HEBREW_FAMILY, JP, JP_FAMILY, MONO, MONO_FAMILY, SANS, SANS_FAMILY, clusters, family,
    files, fixture_set, in_font, in_fonts, one_line, plain, shaper, sized,
};

/// The bytes of each of `lines`.
fn ranges(lines: &[VisualLine]) -> Vec<Range<usize>> {
    lines.iter().map(|line| line.bytes.clone()).collect()
}

/// The id of the one glyph `text` is shaped to in the default font.
fn glyph_of(shaper: &ParleyShaper, text: &str) -> u32 {
    let line = one_line(shaper, &plain(text));
    assert_eq!(line.glyphs.len(), 1, "{text:?}");
    line.glyphs[0].id
}

#[test]
fn a_fonts_metrics_are_those_of_a_space_shaped_in_it() {
    let shaper = shaper();
    let metrics = shaper.metrics(FontId(0));
    let space = one_line(&shaper, &plain(" "));
    assert_eq!(space.glyphs.len(), 1);
    assert_eq!(metrics.advance, space.glyphs[0].advance);
    assert_eq!(metrics.line_height, space.height);
    assert!(metrics.advance > 0.0 && metrics.line_height > 0.0);
    // Each font has its own: a larger size is wider and taller.
    let big = shaper.font(&sized(32));
    let big_space = one_line(&shaper, &in_font(" ", big));
    assert_eq!(shaper.metrics(big).advance, big_space.glyphs[0].advance);
    assert_eq!(shaper.metrics(big).line_height, big_space.height);
    assert!(shaper.metrics(big).advance > metrics.advance);
    assert!(shaper.metrics(big).line_height > metrics.line_height);
    // Asked again, the same.
    assert_eq!(shaper.metrics(FontId(0)), metrics);
    // An id it never gave has the default font's.
    assert_eq!(shaper.metrics(FontId(1000)), metrics);
}

#[test]
fn a_shape_call_builds_one_layout_and_breaking_builds_none() {
    let shaper = shaper();
    let before = shaper.counters();
    let kept = shaper.shape(&plain("one two three"));
    let after = shaper.counters();
    assert_eq!(
        after,
        ShapeCounters {
            layouts: before.layouts + 1,
            bytes: before.bytes + 13,
        }
    );
    // Breaking a kept line, at any width and however often, builds none;
    // nor does asking for a font or for its metrics.
    for width in [None, Some(1.0), Some(20.0), Some(40.0), Some(1000.0), None] {
        kept.break_lines(width);
    }
    let bold = shaper.font(&FontSpec {
        weight: Weight::BOLD,
        ..FontSpec::default()
    });
    shaper.metrics(FontId(0));
    shaper.metrics(bold);
    shaper.metrics(bold);
    assert_eq!(shaper.counters(), after);
    // The next call builds the next.
    shaper.shape(&plain("é"));
    assert_eq!(
        shaper.counters(),
        ShapeCounters {
            layouts: after.layouts + 1,
            bytes: after.bytes + 2,
        }
    );
}

#[test]
fn every_visual_lines_baseline_is_from_its_own_top() {
    let shaper = shaper();
    let unbroken = one_line(&shaper, &plain("one two three four"));
    let lines = shaper
        .shape(&plain("one two three four"))
        .break_lines(Some(unbroken.width / 3.0));
    assert!(lines.len() >= 3, "{:?}", ranges(&lines));
    // One font throughout: every line is as tall as the unbroken one, with
    // its baseline as far down, and never the baseline of the lines above
    // it added on.
    for line in &lines {
        assert_eq!(
            (line.height, line.baseline),
            (unbroken.height, unbroken.baseline)
        );
        assert!(line.baseline > 0.0 && line.baseline < line.height);
    }
}

#[test]
fn an_empty_text_is_one_line_as_tall_as_its_runs_font() {
    let shaper = shaper();
    let empty = one_line(&shaper, &plain(""));
    assert_eq!(empty.bytes, 0..0);
    assert_eq!(empty.glyphs, vec![]);
    assert_eq!(empty.width, 0.0);
    assert_eq!(empty.height, shaper.metrics(FontId(0)).line_height);
    // With a run, the run's font, whatever its bytes.
    let big = shaper.font(&sized(32));
    let tall = one_line(&shaper, &in_fonts("", &[(0..0, big)]));
    assert_eq!(tall.height, shaper.metrics(big).line_height);
    assert!(tall.height > empty.height);
    // At a width too, one line.
    let lines = shaper.shape(&plain("")).break_lines(Some(1.0));
    assert_eq!(ranges(&lines), vec![0..0]);
}

#[test]
fn a_line_is_as_tall_as_the_fonts_on_it_and_no_taller_for_the_default_font() {
    let shaper = shaper();
    let (small, big) = (shaper.font(&sized(8)), shaper.font(&sized(32)));
    let (own, low, high) = (
        shaper.metrics(FontId(0)).line_height,
        shaper.metrics(small).line_height,
        shaper.metrics(big).line_height,
    );
    assert!(low < own && own < high);
    // A line wholly in a smaller font than the default is as tall as that
    // font's line: the default font, which is not on it, adds nothing.
    assert_eq!(one_line(&shaper, &in_font("ab cd", small)).height, low);
    // A line of two fonts is as tall as the taller.
    let mixed = in_fonts("ab cd", &[(0..2, small), (3..5, big)]);
    assert_eq!(one_line(&shaper, &mixed).height, high);
    // Broken, each visual line is as tall as the fonts on it alone: the
    // big word is on the first, and the second is the default font's.
    let wrapped = in_fonts("ab cd", &[(0..2, big)]);
    let lines = shaper.shape(&wrapped).break_lines(Some(1.0));
    let first = lines.first().expect("a line");
    let last = lines.last().expect("a line");
    assert_eq!((first.bytes.start, first.height), (0, high));
    assert_eq!((last.bytes.end, last.height), (5, own));
}

#[test]
fn a_return_and_the_separators_break_no_line_and_keep_every_offset() {
    let shaper = shaper();
    let text = "a\rb\u{2028}c\u{2029}d";
    let line = one_line(&shaper, &plain(text));
    assert_eq!(line.bytes, 0..text.len());
    // Each character is where it was: the separators are three bytes.
    assert_eq!(clusters(&line), vec![0, 1, 2, 3, 6, 7, 10]);
    // The stand-ins: a return is drawn as a space, and a separator as the
    // replacement character.
    let (space, replacement) = (glyph_of(&shaper, " "), glyph_of(&shaper, "\u{fffd}"));
    let ids: Vec<u32> = line.glyphs.iter().map(|glyph| glyph.id).collect();
    assert_eq!([ids[1], ids[3], ids[5]], [space, replacement, replacement]);
    // Each alone, and at the ends of a text.
    for text in ["\r", "\u{2028}", "\u{2029}", "\ra", "a\u{2029}"] {
        assert_eq!(one_line(&shaper, &plain(text)).bytes, 0..text.len());
    }
    // At a width they break as their stand-ins do, and still cover the
    // text.
    let lines = shaper.shape(&plain(text)).break_lines(Some(1.0));
    assert_eq!(lines.first().map(|line| line.bytes.start), Some(0));
    assert_eq!(lines.last().map(|line| line.bytes.end), Some(text.len()));
}

#[test]
fn a_font_of_size_0_gives_lines_of_no_height_and_no_panic() {
    let shaper = shaper();
    let flat = shaper.font(&sized(0));
    let lines = shaper
        .shape(&in_font("ab cd", flat))
        .break_lines(Some(10.0));
    assert!(!lines.is_empty());
    assert!(lines.iter().all(|line| line.height == 0.0));
    assert_eq!(lines.last().map(|line| line.bytes.end), Some(5));
    assert_eq!(shaper.metrics(flat).line_height, 0.0);
    // A line height of 0 pixels at an ordinary size shapes too. How tall
    // Parley makes such a line is its own; it is no taller than the font's
    // own line, and the font's metrics say the same as its lines.
    let squashed = shaper.font(&FontSpec {
        line_height: LineHeight::Pixels(Length::pixels(0)),
        ..FontSpec::default()
    });
    let line = one_line(&shaper, &in_font("ab", squashed));
    assert!(line.height < shaper.metrics(FontId(0)).line_height);
    assert_eq!(line.height, shaper.metrics(squashed).line_height);
}

#[test]
fn an_object_replacement_character_is_a_character_like_another() {
    let shaper = shaper();
    let line = one_line(&shaper, &plain("x\u{fffc}y"));
    assert_eq!(line.bytes, 0..5);
    assert_eq!(clusters(&line), vec![0, 1, 4]);
}

#[test]
fn spaces_wider_than_the_view_wrap() {
    let shaper = shaper();
    let text = "a          b";
    let unbroken = one_line(&shaper, &plain(text));
    let width = unbroken.width / 4.0;
    let lines = shaper.shape(&plain(text)).break_lines(Some(width));
    assert!(lines.len() >= 4, "{:?}", ranges(&lines));
    // No line hangs its spaces past the width.
    for line in &lines {
        assert!(line.width <= width, "{line:?}");
    }
}

#[test]
fn breaking_a_kept_line_adds_no_resolved_font() {
    let shaper = shaper();
    // Shaping describes every font the line is drawn in, fallbacks among
    // them, before it returns.
    let before = shaper.resolved().len();
    let kept = shaper.shape(&plain("ab 日 😀 cd"));
    let described = shaper.resolved();
    assert!(described.len() >= before + 3);
    // Broken at any width, every glyph names a font described then, and
    // the table is as it was.
    for width in [None, Some(1.0), Some(30.0), Some(1000.0)] {
        for line in kept.break_lines(width) {
            for glyph in &line.glyphs {
                assert!((glyph.font.0 as usize) < described.len(), "{glyph:?}");
            }
        }
        assert_eq!(shaper.resolved(), described);
    }
    // Shaping the same text again adds none either.
    shaper.shape(&plain("ab 日 😀 cd")).break_lines(Some(1.0));
    assert_eq!(shaper.resolved(), described);
    // Nor do a font's metrics, which are no line of a text.
    let fresh = self::shaper();
    fresh.metrics(FontId(0));
    assert_eq!(fresh.resolved().len(), 0);
}

/// Whether every font `shaper` describes is drawn from the bytes `file`.
fn all_drawn_from(shaper: &ParleyShaper, file: &[u8]) -> bool {
    let table = shaper.resolved();
    !table.is_empty() && table.iter().all(|font| (*font.data).as_ref() == file)
}

#[test]
fn setting_the_fonts_again_moves_the_generation_and_starts_the_table_again() {
    let shaper = shaper();
    let big = shaper.font(&sized(32));
    let before = shaper.generation();
    let kept = shaper.shape(&plain("a日"));
    assert!(shaper.resolved().len() >= 2);
    let metrics = shaper.metrics(FontId(0));
    let counted = shaper.counters();
    assert_eq!(shaper.generation(), before);

    // Other fonts: the monospace file alone.
    let mono = FontSet::only(MONO_FAMILY, &[], [MONO.to_vec()]).expect("one font");
    shaper.set_fonts(mono);
    let after = shaper.generation();
    assert_ne!(after, before);
    // The table starts again: nothing is described until something is
    // shaped under the new generation, and then only fonts of the new set.
    assert_eq!(shaper.resolved().len(), 0);
    let line = one_line(&shaper, &plain("a日"));
    assert!(all_drawn_from(&shaper, MONO));
    assert!(line.glyphs.iter().all(|glyph| glyph.font.0 == 0));
    // A font's metrics are asked of the new fonts.
    assert_ne!(shaper.metrics(FontId(0)), metrics);
    assert_eq!(
        shaper.metrics(FontId(0)).advance,
        one_line(&shaper, &plain(" ")).glyphs[0].advance
    );
    // Spec ids stay for the shaper's life, and the counters keep counting.
    assert_eq!(shaper.font(&sized(32)), big);
    assert_eq!(shaper.font(&FontSpec::default()), FontId(0));
    assert_eq!(shaper.counters().layouts, counted.layouts + 2);
    // A line kept from before still breaks, as it was shaped.
    assert_eq!(ranges(&kept.break_lines(None)), vec![0..4]);

    // The same fonts set again are another generation too: whoever keeps
    // anything by resolved font id starts again.
    shaper.set_fonts(fixture_set());
    assert_ne!(shaper.generation(), after);
    assert_ne!(shaper.generation(), before);
    assert_eq!(shaper.resolved().len(), 0);
    one_line(&shaper, &plain("a"));
    assert!(all_drawn_from(&shaper, SANS));
    assert_eq!(shaper.metrics(FontId(0)), metrics);
}

#[test]
fn setting_the_fonts_again_takes_the_new_sets_fallbacks_in_their_order() {
    // Three sets over the same five files, each with the CJK font as its
    // default family. That font has no space, and both the Hebrew font and
    // the primary have one, so the space of this text is drawn in
    // whichever of the two is the earlier fallback of the set in use.
    let set = |fallbacks: &[&str]| {
        FontSet::only(JP_FAMILY, fallbacks, files()).expect("the fixture fonts")
    };
    let space = |shaper: &ParleyShaper| {
        let line = one_line(shaper, &plain("日 "));
        assert_eq!(clusters(&line), vec![0, 3]);
        let font = shaper.resolved()[line.glyphs[1].font.0 as usize].clone();
        (line.glyphs[1].id, font)
    };
    let drawn_from = |(_, font): &(u32, ResolvedFont), file: &[u8]| (*font.data).as_ref() == file;
    let shaper = ParleyShaper::new(set(&[HEBREW_FAMILY, SANS_FAMILY]));
    assert!(drawn_from(&space(&shaper), HEBREW));
    // The other order: the first fallback of the new set, not of the one
    // the shaper was made with.
    shaper.set_fonts(set(&[SANS_FAMILY, HEBREW_FAMILY]));
    assert!(drawn_from(&space(&shaper), SANS));
    // A set with no fallback has none, though the files that were the
    // fallbacks are still in it: the space is the default family's
    // missing glyph.
    shaper.set_fonts(set(&[]));
    let alone = space(&shaper);
    assert!(drawn_from(&alone, JP));
    assert_eq!(alone.0, 0);
}

#[test]
fn every_glyph_of_the_monospace_family_is_as_wide_as_its_metrics_say() {
    let shaper = shaper();
    let mono = shaper.font(&family(MONO_FAMILY));
    let advance = shaper.metrics(mono).advance;
    let line = one_line(&shaper, &in_font("iiimmm WW", mono));
    assert_eq!(line.glyphs.len(), 9);
    assert!(line.glyphs.iter().all(|glyph| glyph.advance == advance));
}

#[test]
fn the_shaper_and_its_lines_are_shared_between_threads() {
    fn shared<T: Send + Sync>() {}
    shared::<ParleyShaper>();
    shared::<ParleyLine>();
}
