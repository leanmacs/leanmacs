//! The fixture fonts of the shaping tests: the five files checked in under
//! `tests/fonts` at the repository's root (its README says what each is),
//! compiled into the test, so no test reads a file when it runs and none
//! uses a font of the machine it runs on.

// Each test binary uses its own part of this module.
#![allow(dead_code)]

use editor_shape_parley::FontSet;

/// The primary: Noto Sans. Proportional, with a ligature for `fi`, and no
/// glyph for a CJK character or an emoji.
pub const SANS: &[u8] = include_bytes!("../../../../tests/fonts/NotoSans-Regular.subset.ttf");
/// Noto Sans Mono.
pub const MONO: &[u8] = include_bytes!("../../../../tests/fonts/NotoSansMono-Regular.subset.ttf");
/// Noto Sans Hebrew.
pub const HEBREW: &[u8] = include_bytes!("../../../../tests/fonts/NotoSansHebrew-Regular.ttf");
/// Noto Sans JP: the fallback that covers the CJK character.
pub const JP: &[u8] = include_bytes!("../../../../tests/fonts/NotoSansJP-Regular.subset.otf");
/// Noto Emoji: the fallback that covers the emoji.
pub const EMOJI: &[u8] = include_bytes!("../../../../tests/fonts/NotoEmoji.subset.ttf");

/// The family of [`SANS`].
pub const SANS_FAMILY: &str = "Noto Sans";
/// The family of [`MONO`].
pub const MONO_FAMILY: &str = "Noto Sans Mono";
/// The family of [`HEBREW`].
pub const HEBREW_FAMILY: &str = "Noto Sans Hebrew";
/// The family of [`JP`].
pub const JP_FAMILY: &str = "Noto Sans JP";
/// The family of [`EMOJI`].
pub const EMOJI_FAMILY: &str = "Noto Emoji";

/// The five files.
pub fn files() -> Vec<Vec<u8>> {
    [SANS, MONO, HEBREW, JP, EMOJI]
        .iter()
        .map(|bytes| bytes.to_vec())
        .collect()
}

/// The fallback families of [`fixture_set`], in order.
pub const FALLBACKS: [&str; 3] = [HEBREW_FAMILY, JP_FAMILY, EMOJI_FAMILY];

/// The fixture set: the five files, with Noto Sans the default family and
/// the Hebrew, the CJK and the emoji font its fallbacks, in that order.
pub fn fixture_set() -> FontSet {
    FontSet::only(SANS_FAMILY, &FALLBACKS, files()).expect("the fixture fonts")
}
