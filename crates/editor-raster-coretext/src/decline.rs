//! Which fonts the Core Text adapter declines, for swash to draw.
//!
//! It draws the plain outlines of a static face, as the frame names it.
//! A face the shaper varies, or synthesises a bold or a slant for, or one
//! with colour glyphs, would need Core Text to be told more than the bytes
//! and the size (a variation, a matrix, a colour context), and that is a
//! follow-up. Until then such a font is declined, and the renderer's
//! fallback, swash, draws it.
//!
//! A new fact of a font the adapter declines goes here: a field of
//! [`FontFacts`], read in [`FontFacts::of`], and a test of its own.

use editor_raster::ResolvedFont;

/// The tables that hold colour glyphs: Apple's bitmaps, colour layers,
/// colour bitmaps and SVG documents.
pub const COLOUR_TABLES: [[u8; 4]; 4] = [*b"sbix", *b"COLR", *b"CBDT", *b"SVG "];

/// What decides whether a font is declined.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FontFacts {
    /// Its variation coordinates are not all at the default.
    pub coords_nonzero: bool,
    /// It is to be made bolder.
    pub embolden: bool,
    /// It is to be slanted.
    pub skew: bool,
    /// It has a table of colour glyphs.
    pub colour_tables: bool,
}

impl FontFacts {
    /// The facts of `font`, whose face has the tables `tables` (each tag
    /// as four bytes).
    pub fn of(font: &ResolvedFont, tables: &[[u8; 4]]) -> FontFacts {
        FontFacts {
            coords_nonzero: font.coords.iter().any(|coord| *coord != 0),
            embolden: font.embolden,
            skew: font.skew.is_some(),
            colour_tables: tables.iter().any(|tag| COLOUR_TABLES.contains(tag)),
        }
    }
}

/// Whether a font with `facts` is declined: any of them is reason enough.
pub fn declines(facts: &FontFacts) -> bool {
    let FontFacts {
        coords_nonzero,
        embolden,
        skew,
        colour_tables,
    } = *facts;
    coords_nonzero || embolden || skew || colour_tables
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use editor_raster::ResolvedFont;

    use super::{FontFacts, declines};

    /// A static face of no variation or synthesis.
    fn plain() -> ResolvedFont {
        ResolvedFont {
            data: Arc::new([0_u8; 0]),
            file: 0,
            index: 0,
            size: 16.0,
            coords: Vec::new(),
            embolden: false,
            skew: None,
        }
    }

    /// The tables of a plain outline face.
    const OUTLINES: [[u8; 4]; 4] = [*b"glyf", *b"loca", *b"cmap", *b"head"];

    #[test]
    fn a_plain_face_is_drawn() {
        assert!(!declines(&FontFacts::of(&plain(), &OUTLINES)));
        // A variable face at its default is plain.
        let default = ResolvedFont {
            coords: vec![0, 0],
            ..plain()
        };
        assert!(!declines(&FontFacts::of(&default, &OUTLINES)));
    }

    #[test]
    fn a_face_varied_from_its_default_is_declined() {
        let varied = ResolvedFont {
            coords: vec![0, 16384],
            ..plain()
        };
        assert!(declines(&FontFacts::of(&varied, &OUTLINES)));
    }

    #[test]
    fn a_synthetic_bold_is_declined() {
        let bold = ResolvedFont {
            embolden: true,
            ..plain()
        };
        assert!(declines(&FontFacts::of(&bold, &OUTLINES)));
    }

    #[test]
    fn a_synthetic_slant_is_declined() {
        let slanted = ResolvedFont {
            skew: Some(14.0),
            ..plain()
        };
        assert!(declines(&FontFacts::of(&slanted, &OUTLINES)));
    }

    #[test]
    fn a_face_with_colour_glyphs_is_declined() {
        for colour in [*b"sbix", *b"COLR", *b"CBDT", *b"SVG "] {
            let mut tables = OUTLINES.to_vec();
            tables.push(colour);
            assert!(declines(&FontFacts::of(&plain(), &tables)), "{colour:?}");
        }
    }

    #[test]
    fn each_fact_alone_declines() {
        for facts in [
            FontFacts {
                coords_nonzero: true,
                ..FontFacts::default()
            },
            FontFacts {
                embolden: true,
                ..FontFacts::default()
            },
            FontFacts {
                skew: true,
                ..FontFacts::default()
            },
            FontFacts {
                colour_tables: true,
                ..FontFacts::default()
            },
        ] {
            assert!(declines(&facts), "{facts:?}");
        }
        assert!(!declines(&FontFacts::default()));
    }
}
