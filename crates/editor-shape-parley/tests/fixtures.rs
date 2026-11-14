//! A font set holds the fonts it was handed and no other: what makes the
//! shaping tests depend on the fixture files alone.

mod common;

use editor_shape_parley::{FontSet, FontSetError};

use common::{
    EMOJI_FAMILY, FALLBACKS, HEBREW_FAMILY, JP_FAMILY, MONO_FAMILY, SANS, SANS_FAMILY, files,
    fixture_set,
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
fn an_error_says_which_family_is_missing() {
    let error = FontSetError::NoSuchFamily("Missing".to_owned());
    assert_eq!(error.to_string(), "no font file holds the family Missing");
    assert_eq!(FontSetError::NotAFont.to_string(), "a file is not a font");
}
