//! What shaping whole runs with real fonts gives, on the fixture fonts: a
//! ligature, a combining mark, two families on one line, and a spec's
//! attributes reaching the font a glyph is drawn in.
//!
//! The tests rest on the three facts of the fixture files their README
//! states, and on no number of a font's: a glyph is "the one glyph of the
//! line", "not the glyph `f` has alone", "drawn in the bytes of this
//! file".

mod common;

use editor_layout::shaper::{
    FontId, FontSpec, Glyph, Length, LineHeight, ResolvedFont, Shaper, Slant, VisualLine, Weight,
};
use editor_shape_parley::ParleyShaper;

use common::{
    MONO_FAMILY, SANS, clusters, family, in_font, in_fonts, one_line, plain, shaper, sized,
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
