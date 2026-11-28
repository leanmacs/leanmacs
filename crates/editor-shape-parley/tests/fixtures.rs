//! A font set holds the fonts it was handed and no other: what makes the
//! shaping tests depend on the fixture files alone.

mod common;

use editor_layout::shaper::Shaper;
use editor_shape_parley::{FontSet, FontSetError};

use common::{
    EMOJI_FAMILY, FALLBACKS, HEBREW_FAMILY, JP_FAMILY, MONO_FAMILY, SANS, SANS_FAMILY, files,
    fixture_set, one_line, plain, shaper,
};

#[test]
fn a_font_set_holds_exactly_the_families_it_was_given() {
    // Sorted, whatever order the files came in.
    let mut expected = vec![
        SANS_FAMILY,
        MONO_FAMILY,
        HEBREW_FAMILY,
        JP_FAMILY,
        EMOJI_FAMILY,
    ];
    expected.sort_unstable();
    assert_eq!(fixture_set().families(), expected);
    // A set of one file holds that file's family and no other.
    let one = FontSet::only(SANS_FAMILY, &[], [SANS.to_vec()]).expect("one font");
    assert_eq!(one.families(), vec![SANS_FAMILY]);
}

#[test]
fn a_font_set_names_its_default_family() {
    assert_eq!(fixture_set().default_family(), Some(SANS_FAMILY));
    let mono = FontSet::only(MONO_FAMILY, &FALLBACKS, files()).expect("the fixture fonts");
    assert_eq!(mono.default_family(), Some(MONO_FAMILY));
}

#[test]
fn a_default_family_the_files_do_not_hold_is_refused_by_name() {
    let refused = FontSet::only("No Such Family", &FALLBACKS, files()).err();
    assert_eq!(
        refused,
        Some(FontSetError::NoSuchFamily("No Such Family".to_owned()))
    );
    // A family of a file that was not handed over is not held either.
    let refused = FontSet::only(MONO_FAMILY, &[], [SANS.to_vec()]).err();
    assert_eq!(
        refused,
        Some(FontSetError::NoSuchFamily(MONO_FAMILY.to_owned()))
    );
    // And no file at all holds no family.
    let refused = FontSet::only(SANS_FAMILY, &[], []).err();
    assert_eq!(
        refused,
        Some(FontSetError::NoSuchFamily(SANS_FAMILY.to_owned()))
    );
}

#[test]
fn a_fallback_family_the_files_do_not_hold_is_refused_by_name() {
    let refused = FontSet::only(SANS_FAMILY, &[HEBREW_FAMILY, "Missing"], files()).err();
    assert_eq!(
        refused,
        Some(FontSetError::NoSuchFamily("Missing".to_owned()))
    );
}

#[test]
fn a_generic_family_is_given_only_by_a_generic_name_and_as_families_the_files_hold() {
    let refused = fixture_set()
        .with_generic("proportional", &[SANS_FAMILY])
        .err();
    assert_eq!(
        refused,
        Some(FontSetError::NotAGeneric("proportional".to_owned()))
    );
    let refused = fixture_set()
        .with_generic("system-ui", &[SANS_FAMILY, "Missing"])
        .err();
    assert_eq!(
        refused,
        Some(FontSetError::NoSuchFamily("Missing".to_owned()))
    );
    // A refusal names what was refused.
    assert_eq!(
        FontSetError::NotAGeneric("proportional".to_owned()).to_string(),
        "proportional is not a generic family name"
    );
    // And a generic name given as families the set holds is taken.
    assert!(
        fixture_set()
            .with_generic("system-ui", &[SANS_FAMILY])
            .is_ok()
    );
}

#[test]
fn bytes_that_are_no_font_are_refused() {
    let refused = FontSet::only(SANS_FAMILY, &[], [b"not a font".to_vec()]).err();
    assert_eq!(refused, Some(FontSetError::NotAFont));
    // One bad file among good ones refuses the set.
    let mut mixed = files();
    mixed.push(Vec::new());
    let refused = FontSet::only(SANS_FAMILY, &FALLBACKS, mixed).err();
    assert_eq!(refused, Some(FontSetError::NotAFont));
}

#[test]
fn a_character_no_fixture_covers_is_the_primary_fonts_missing_glyph() {
    // U+0E01, a Thai letter: no fixture font has it, and the fonts of any
    // machine do. Were a system font consulted, it would be drawn in one;
    // it is glyph 0, which the font format makes the missing glyph, of
    // the primary fixture.
    let shaper = shaper();
    let line = one_line(&shaper, &plain("a\u{e01}"));
    assert_eq!(line.glyphs.len(), 2);
    assert_eq!(line.glyphs[1].cluster, 1);
    assert_eq!(line.glyphs[1].id, 0);
    assert_ne!(line.glyphs[0].id, 0);
    let table = shaper.resolved();
    for glyph in &line.glyphs {
        let font = &table[glyph.font.0 as usize];
        assert!((*font.data).as_ref() == SANS);
    }
    // Every font the shaper describes after it is one of the five files.
    shaper.shape(&plain("a日😀 שלום"));
    for font in shaper.resolved().iter() {
        let bytes = (*font.data).as_ref();
        assert!(files().iter().any(|file| file.as_slice() == bytes));
    }
}

#[test]
fn an_error_says_which_family_is_missing() {
    let error = FontSetError::NoSuchFamily("Missing".to_owned());
    assert_eq!(error.to_string(), "no font file holds the family Missing");
    assert_eq!(FontSetError::NotAFont.to_string(), "a file is not a font");
}
