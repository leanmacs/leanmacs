//! What shaping whole runs with real fonts gives, on the fixture fonts: a
//! ligature, a combining mark, two families on one line, and a spec's
//! attributes reaching the font a glyph is drawn in.
//!
//! The tests rest on the facts of the fixture files their README states,
//! and on no number of a font's: a glyph is "the one glyph of the line",
//! "not the glyph `f` has alone", "drawn in the bytes of this file",
//! "raised".

mod common;

use editor_layout::shaper::{
    FontId, FontSpec, Glyph, Length, LineHeight, ResolvedFont, Shaper, Slant, VisualLine, Weight,
};
use editor_shape_parley::{FontSet, ParleyShaper};

use common::{
    EMOJI, HEBREW, HEBREW_FAMILY, JP, JP_FAMILY, MONO, MONO_FAMILY, SANS, SANS_FAMILY, clusters,
    family, files, in_font, in_fonts, one_line, plain, shaper, sized,
};

/// The id of the one glyph `text` is shaped to in the default font.
fn glyph_of(shaper: &ParleyShaper, text: &str) -> u32 {
    let line = one_line(shaper, &plain(text));
    assert_eq!(line.glyphs.len(), 1, "{text:?}");
    line.glyphs[0].id
}

/// The id of each glyph of `line`.
fn ids(line: &VisualLine) -> Vec<u32> {
    line.glyphs.iter().map(|glyph| glyph.id).collect()
}

/// Whether each glyph of `line` starts where the one before it ends, the
/// first at the line's left edge and the last ending at its width. The
/// positions are sums of the same advances, so a few are a rounding apart.
fn end_to_end(line: &VisualLine) -> bool {
    let near = |a: f32, b: f32| (a - b).abs() < 0.01;
    let mut at = 0.0;
    for glyph in &line.glyphs {
        if !near(glyph.x, at) {
            return false;
        }
        at = glyph.x + glyph.advance;
    }
    near(at, line.width)
}

/// The font `glyph` is drawn in, as `shaper` describes it.
fn font_of(shaper: &ParleyShaper, glyph: &Glyph) -> ResolvedFont {
    shaper.resolved()[glyph.font.0 as usize].clone()
}

/// Whether `font` is drawn from the bytes `file`.
fn drawn_from(font: &ResolvedFont, file: &[u8]) -> bool {
    (*font.data).as_ref() == file
}

#[test]
fn fi_shapes_to_the_one_ligature_glyph() {
    let shaper = shaper();
    let line = one_line(&shaper, &plain("fi"));
    assert_eq!(line.bytes, 0..2);
    // One glyph for the two characters, at the first one's offset, and
    // neither letter's own glyph.
    assert_eq!(line.glyphs.len(), 1);
    assert_eq!(clusters(&line), vec![0]);
    let (f, i) = (glyph_of(&shaper, "f"), glyph_of(&shaper, "i"));
    assert_ne!(f, i);
    assert_ne!(line.glyphs[0].id, f);
    assert_ne!(line.glyphs[0].id, i);
    // It is as wide as its line.
    assert!(end_to_end(&line));
    // Inside a word too: `find` is three glyphs for four characters.
    let word = one_line(&shaper, &plain("find"));
    assert_eq!(clusters(&word), vec![0, 2, 3]);
    assert_eq!(word.glyphs[0].id, line.glyphs[0].id);
    assert!(end_to_end(&word));
}

#[test]
fn f_and_i_apart_are_two_glyphs() {
    let shaper = shaper();
    let (f, i) = (glyph_of(&shaper, "f"), glyph_of(&shaper, "i"));
    let space = glyph_of(&shaper, " ");
    assert_eq!(ids(&one_line(&shaper, &plain("f i"))), vec![f, space, i]);
    assert_eq!(ids(&one_line(&shaper, &plain("if"))), vec![i, f]);
}

#[test]
fn a_ligature_does_not_form_across_two_fonts() {
    let shaper = shaper();
    let (f, i) = (glyph_of(&shaper, "f"), glyph_of(&shaper, "i"));
    // The two letters in two fonts of one family: a run is shaped whole,
    // and only a run.
    let big = shaper.font(&sized(32));
    let line = one_line(&shaper, &in_fonts("fi", &[(1..2, big)]));
    assert_eq!(ids(&line), vec![f, i]);
    assert_eq!(clusters(&line), vec![0, 1]);
    assert_ne!(line.glyphs[0].font, line.glyphs[1].font);
}

#[test]
fn a_letter_and_its_combining_mark_are_one_cluster() {
    let shaper = shaper();
    // `e`, then U+0301, the combining acute accent, then `x`.
    let line = one_line(&shaper, &plain("e\u{301}x"));
    assert_eq!(line.bytes, 0..4);
    let (marked, rest) = line.glyphs.split_at(line.glyphs.len() - 1);
    assert!(!marked.is_empty());
    assert!(marked.iter().all(|glyph| glyph.cluster == 0));
    assert_eq!(rest[0].cluster, 3);
    assert_eq!(rest[0].id, glyph_of(&shaper, "x"));
}

#[test]
fn two_families_share_a_line_each_with_its_own_advances() {
    let shaper = shaper();
    let mono = shaper.font(&family(MONO_FAMILY));
    // The second word is in the monospace family.
    let line = one_line(&shaper, &in_fonts("iiimmm iiimmm", &[(7..13, mono)]));
    assert_eq!(line.glyphs.len(), 13);
    assert_eq!(clusters(&line), (0..13).collect::<Vec<_>>());
    let advances: Vec<f32> = line.glyphs.iter().map(|glyph| glyph.advance).collect();
    // Proportional: every `i` is as wide as the next and narrower than
    // every `m`.
    assert!(advances[..3].iter().all(|advance| *advance == advances[0]));
    assert!(advances[3..6].iter().all(|advance| *advance == advances[3]));
    assert!(advances[0] < advances[3]);
    // Monospace: all six are one width.
    assert!(advances[7..].iter().all(|advance| *advance == advances[7]));
    // Each family is drawn in its own font, and each glyph starts where
    // the one before it ends.
    assert_ne!(line.glyphs[0].font, line.glyphs[7].font);
    assert!(
        line.glyphs[7..]
            .iter()
            .all(|glyph| glyph.font == line.glyphs[7].font)
    );
    assert!(end_to_end(&line));
}

#[test]
fn a_resolved_font_says_what_a_rasteriser_needs() {
    let shaper = shaper();
    // The primary family has one face, regular and upright, so a bold, an
    // italic or an oblique spec is that face with the rest synthesised.
    let with = |spec: FontSpec| {
        let font = shaper.font(&spec);
        let line = one_line(&shaper, &in_font("a", font));
        (line.glyphs[0].font, font_of(&shaper, &line.glyphs[0]))
    };
    let (plain_id, regular) = with(FontSpec::default());
    let (bold_id, bold) = with(FontSpec {
        weight: Weight::BOLD,
        ..FontSpec::default()
    });
    let (italic_id, italic) = with(FontSpec {
        slant: Slant::Italic,
        ..FontSpec::default()
    });
    let (oblique_id, oblique) = with(FontSpec {
        slant: Slant::Oblique,
        ..FontSpec::default()
    });
    let (big_id, big) = with(sized(24));
    for font in [&regular, &bold, &italic, &oblique, &big] {
        assert!(drawn_from(font, SANS));
        assert_eq!(font.file, regular.file);
        assert_eq!(font.index, 0);
    }
    assert_eq!(
        (regular.size, regular.embolden, regular.skew),
        (16.0, false, None)
    );
    assert_eq!((bold.size, bold.embolden, bold.skew), (16.0, true, None));
    assert!(!italic.embolden && italic.skew.is_some_and(|degrees| degrees > 0.0));
    assert!(!oblique.embolden && oblique.skew.is_some_and(|degrees| degrees > 0.0));
    assert_eq!((big.size, big.embolden, big.skew), (24.0, false, None));
    // Each is an entry of its own, but the two slants, which come to the
    // same synthesis of the same face.
    let ids = [plain_id, bold_id, italic_id, big_id];
    for (index, id) in ids.iter().enumerate() {
        assert_eq!(ids.iter().position(|other| other == id), Some(index));
    }
    assert_eq!(oblique_id, italic_id);
    // A spec that differs only in its line height is drawn in the same
    // font: no glyph differs.
    let (spaced_id, _) = with(FontSpec {
        line_height: LineHeight::Multiple(128),
        ..FontSpec::default()
    });
    assert_eq!(spaced_id, plain_id);
}

#[test]
fn a_weight_on_a_fonts_weight_axis_is_an_instance_of_the_face_and_no_synthesis() {
    let shaper = shaper();
    // The emoji fixture is the one that varies: it has a weight axis. So
    // a bold emoji is the same face of the same file at another place on
    // the axis, which its variation coordinates say, and nothing is made
    // bolder after.
    let bold_spec = FontSpec {
        weight: Weight::BOLD,
        ..FontSpec::default()
    };
    let emoji_in = |spec: &FontSpec| {
        let font = shaper.font(spec);
        let line = one_line(&shaper, &in_font("😀", font));
        assert_eq!(line.glyphs.len(), 1);
        (line.glyphs[0].font, font_of(&shaper, &line.glyphs[0]))
    };
    let (regular_id, regular) = emoji_in(&FontSpec::default());
    let (bold_id, bold) = emoji_in(&bold_spec);
    for font in [&regular, &bold] {
        assert!(drawn_from(font, EMOJI));
        assert_eq!((font.embolden, font.skew), (false, None), "{font:?}");
    }
    assert_eq!(
        (bold.file, bold.index, bold.size),
        (regular.file, regular.index, regular.size)
    );
    // The coordinates are what tells the two apart: the bold one has
    // some, and they are not the regular one's.
    assert!(!bold.coords.is_empty(), "{bold:?}");
    assert_ne!(bold.coords, regular.coords);
    // So they are two entries of the table, and each is found again by
    // its coordinates: shaping either again adds none.
    assert_ne!(bold_id, regular_id);
    let described = shaper.resolved().len();
    assert_eq!(emoji_in(&bold_spec).0, bold_id);
    assert_eq!(emoji_in(&FontSpec::default()).0, regular_id);
    assert_eq!(shaper.resolved().len(), described);
}

#[test]
fn a_character_the_primary_lacks_is_drawn_in_the_fallback_that_covers_it() {
    let shaper = shaper();
    // Every byte is in the default font, whose family is the primary: it
    // has `a` and `b`, and neither the CJK character nor the emoji.
    let text = "a日😀b";
    let line = one_line(&shaper, &plain(text));
    assert_eq!(clusters(&line), vec![0, 1, 4, 8]);
    let fonts: Vec<ResolvedFont> = line
        .glyphs
        .iter()
        .map(|glyph| font_of(&shaper, glyph))
        .collect();
    assert!(drawn_from(&fonts[0], SANS));
    assert!(drawn_from(&fonts[1], JP));
    assert!(drawn_from(&fonts[2], EMOJI));
    assert!(drawn_from(&fonts[3], SANS));
    // All at the size the spec asked for, and the fallbacks' glyphs are
    // glyphs of theirs, not the missing glyph.
    assert!(fonts.iter().all(|font| font.size == 16.0));
    assert!(line.glyphs.iter().all(|glyph| glyph.id != 0));
    // The two letters are one resolved font, and each fallback another.
    assert_eq!(line.glyphs[0].font, line.glyphs[3].font);
    assert_ne!(line.glyphs[1].font, line.glyphs[0].font);
    assert_ne!(line.glyphs[2].font, line.glyphs[0].font);
    assert_ne!(line.glyphs[1].font, line.glyphs[2].font);
    // The line still starts each glyph where the one before it ends.
    assert!(end_to_end(&line));
    // At another size, the fallbacks are at that size.
    let big = shaper.font(&sized(32));
    let line = one_line(&shaper, &in_font(text, big));
    let sizes: Vec<f32> = line
        .glyphs
        .iter()
        .map(|glyph| font_of(&shaper, glyph).size)
        .collect();
    assert_eq!(sizes, vec![32.0; 4]);
}

#[test]
fn the_primary_alone_has_neither() {
    // The premise of the test above: with no fallback to turn to, both
    // characters are the primary's missing glyph, which is glyph 0 of any
    // font.
    let alone = FontSet::only(SANS_FAMILY, &[], [SANS.to_vec()]).expect("the primary");
    let shaper = ParleyShaper::new(alone);
    let line = one_line(&shaper, &plain("a日😀b"));
    assert_eq!(clusters(&line), vec![0, 1, 4, 8]);
    let ids = ids(&line);
    assert_eq!((ids[1], ids[2]), (0, 0));
    assert!(ids[0] != 0 && ids[3] != 0);
    for glyph in &line.glyphs {
        assert!(drawn_from(&font_of(&shaper, glyph), SANS));
    }
}

#[test]
fn a_character_is_looked_for_in_the_specs_family_then_the_default_then_the_fallbacks_in_order() {
    let shaper = shaper();
    // A run in the monospace family, which has ASCII alone: `a` is its
    // own, `é` is the default family's, and the CJK character a
    // fallback's.
    let mono = shaper.font(&family(MONO_FAMILY));
    let line = one_line(&shaper, &in_font("aé日", mono));
    let drawn_in: [&[u8]; 3] = [MONO, SANS, JP];
    assert_eq!(line.glyphs.len(), 3);
    for (glyph, file) in line.glyphs.iter().zip(drawn_in) {
        assert!(drawn_from(&font_of(&shaper, glyph), file), "{glyph:?}");
    }
    // A family the set does not hold is no family: the default's.
    let unknown = shaper.font(&family("No Such Family"));
    let line = one_line(&shaper, &in_font("a", unknown));
    assert!(drawn_from(&font_of(&shaper, &line.glyphs[0]), SANS));
    // Among the fallbacks, the first in the set's order that has the
    // character: the CJK font has no space, and both the Hebrew font and
    // the primary have one.
    let space_in = |fallbacks: &[&str]| {
        let fonts = FontSet::only(JP_FAMILY, fallbacks, files()).expect("the fixture fonts");
        let shaper = ParleyShaper::new(fonts);
        let line = one_line(&shaper, &plain("日 "));
        assert!(drawn_from(&font_of(&shaper, &line.glyphs[0]), JP));
        font_of(&shaper, &line.glyphs[1])
    };
    assert!(drawn_from(&space_in(&[HEBREW_FAMILY, SANS_FAMILY]), HEBREW));
    assert!(drawn_from(&space_in(&[SANS_FAMILY, HEBREW_FAMILY]), SANS));
}

#[test]
fn a_line_height_is_a_multiple_of_the_fonts_own_or_pixels() {
    let shaper = shaper();
    let height = |line_height: LineHeight| {
        let font = shaper.font(&FontSpec {
            line_height,
            ..FontSpec::default()
        });
        let line = one_line(&shaper, &in_font("ab", font));
        assert_eq!(shaper.metrics(font).line_height, line.height);
        line.height
    };
    let own = height(LineHeight::OWN);
    assert_eq!(own, shaper.metrics(FontId(0)).line_height);
    // Pixels are the line's height, whatever the font's own.
    assert_eq!(height(LineHeight::Pixels(Length::pixels(40))), 40.0);
    assert_eq!(height(LineHeight::Pixels(Length::pixels(17))), 17.0);
    // But for a height so small that the line would end above its
    // baseline: Parley's line always holds its baseline, so such a line is
    // shorter than the font's own and no shorter than was asked.
    let squashed = height(LineHeight::Pixels(Length::pixels(7)));
    assert!((7.0..own).contains(&squashed), "{squashed}");
    // A multiple of two is twice the font's own, to the pixel a height is
    // rounded to.
    let double = height(LineHeight::Multiple(128));
    assert!((double - 2.0 * own).abs() <= 1.0, "{double} for {own}");
    assert!(height(LineHeight::Multiple(96)) > own);
    assert!(height(LineHeight::Multiple(96)) < double);
}

/// Whether the glyph of `line` at `index` is drawn in the Hebrew fixture.
fn hebrew(shaper: &ParleyShaper, line: &VisualLine, index: usize) -> bool {
    drawn_from(&font_of(shaper, &line.glyphs[index]), HEBREW)
}

#[test]
fn latin_then_hebrew_is_in_the_visual_order_of_the_bidirectional_algorithm() {
    let shaper = shaper();
    // `abc`, a space, then shin, lamed, vav, final mem: four letters of
    // two bytes each, at bytes 4, 6, 8 and 10. In a left-to-right line the
    // Hebrew word is one right-to-left run: read from the left edge, its
    // letters are in reverse, so the last of the text is the leftmost.
    let text = "abc שלום";
    let line = one_line(&shaper, &plain(text));
    assert_eq!(line.bytes, 0..12);
    assert_eq!(clusters(&line), vec![0, 1, 2, 3, 10, 8, 6, 4]);
    assert!(end_to_end(&line));
    for index in 0..8 {
        assert_eq!(hebrew(&shaper, &line, index), index >= 4, "glyph {index}");
    }
    // Latin after it: the neutral space between the two takes the line's
    // direction, and the last word is back in order.
    let text = "abc שלום def";
    let line = one_line(&shaper, &plain(text));
    assert_eq!(line.bytes, 0..16);
    assert_eq!(
        clusters(&line),
        vec![0, 1, 2, 3, 10, 8, 6, 4, 12, 13, 14, 15]
    );
    assert!(end_to_end(&line));
    for index in 0..12 {
        let in_word = (4..8).contains(&index);
        assert_eq!(hebrew(&shaper, &line, index), in_word, "glyph {index}");
    }
}

#[test]
fn a_line_that_starts_in_hebrew_still_starts_at_the_left() {
    let shaper = shaper();
    // The base direction of every line is left to right, whatever its
    // first strong character: the Hebrew word is at the left edge, in its
    // own order, and the Latin word is to the right of it. Were the
    // direction taken from the text, the Latin word would be the
    // leftmost.
    let line = one_line(&shaper, &plain("שלום abc"));
    assert_eq!(clusters(&line), vec![6, 4, 2, 0, 8, 9, 10, 11]);
    assert!(end_to_end(&line));
    assert_eq!(line.glyphs[0].x, 0.0);
}

#[test]
fn a_left_to_right_lines_glyphs_are_in_cluster_order() {
    let shaper = shaper();
    for text in ["one two three", "aé€b", "a日😀b", "find the office"] {
        let line = one_line(&shaper, &plain(text));
        let clusters = clusters(&line);
        assert!(
            clusters.windows(2).all(|pair| pair[0] < pair[1]),
            "{text:?}: {clusters:?}"
        );
        assert!(end_to_end(&line), "{text:?}");
    }
}

#[test]
fn a_glyph_drawn_off_its_pen_position_carries_its_offset() {
    let shaper = shaper();
    // The Hebrew fixture draws the vav of this word to the left of its pen
    // position and no higher or lower, and the other three letters on
    // theirs. `dx` is how far to the right, so the vav's is less than
    // nothing, and it has no `dy`.
    let line = one_line(&shaper, &plain("שלום"));
    assert_eq!(clusters(&line), vec![6, 4, 2, 0]);
    let vav = &line.glyphs[1];
    assert!(vav.dx < 0.0, "{vav:?}");
    assert_eq!(vav.dy, 0.0, "{vav:?}");
    for letter in [0, 2, 3] {
        let glyph = &line.glyphs[letter];
        assert_eq!((glyph.dx, glyph.dy), (0.0, 0.0), "{glyph:?}");
    }
    // The offset moves the outline and not the pen: each glyph still
    // starts where the one before it ends.
    assert!(end_to_end(&line));
    // A Latin line has none.
    let line = one_line(&shaper, &plain("find"));
    assert!(
        line.glyphs
            .iter()
            .all(|glyph| glyph.dx == 0.0 && glyph.dy == 0.0)
    );
}

#[test]
fn a_glyph_drawn_above_where_it_would_be_has_a_dy_less_than_nothing() {
    let shaper = shaper();
    // The primary draws the combining acute accent, U+0301, at its own
    // height over `x`, and raises it over `X`, which is taller. Each is
    // the letter's glyph and then the accent's, in one cluster.
    let accent_over = |letter: &str| {
        let text = format!("{letter}\u{301}");
        let line = one_line(&shaper, &plain(&text));
        assert_eq!(clusters(&line), vec![0, 0], "{text:?}");
        let (base, accent) = (line.glyphs[0], line.glyphs[1]);
        assert_eq!(base.id, glyph_of(&shaper, letter));
        assert_eq!((base.dx, base.dy), (0.0, 0.0), "{base:?}");
        // The accent moves the outline and not the pen: the line is as
        // wide as the letter.
        assert_eq!(accent.advance, 0.0);
        assert!(end_to_end(&line));
        accent
    };
    let (over_small, over_capital) = (accent_over("x"), accent_over("X"));
    assert_eq!(over_small.id, over_capital.id);
    // `dy` is how far below the baseline: down is more, so a glyph that
    // is raised has less than nothing, and one that is neither raised nor
    // lowered has none.
    assert_eq!(over_small.dy, 0.0, "{over_small:?}");
    assert!(over_capital.dy < 0.0, "{over_capital:?}");
}
