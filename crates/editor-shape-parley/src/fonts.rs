//! Where a shaper's fonts come from: a [`FontSet`].
//!
//! A set is a collection of fonts, the family a spec with no family is
//! shaped in, and the families a character is looked for in when the
//! family asked for has no glyph for it. [`FontSet::only`] is the seam the
//! tests stand on: it holds exactly the font files it is handed, as bytes,
//! with the system's fonts off, so what a shaper over it gives depends on
//! those bytes and the text alone.

use std::fmt;
use std::sync::Arc;

use parley::fontique::{Blob, Collection, CollectionOptions};

/// The fonts a shaper draws in, and the order it looks for a character in
/// them: the family a run's spec names, then the default family, then the
/// fallback families in the order given.
pub struct FontSet {
    /// The fonts.
    #[expect(dead_code, reason = "read by the shaper, which the next commit adds")]
    pub(crate) collection: Collection,
    /// The default family: what a spec with no family is shaped in.
    pub(crate) default: String,
    /// The fallback families, in the order they are tried.
    pub(crate) fallbacks: Vec<String>,
    /// The families it holds, sorted.
    families: Vec<String>,
}

/// Why a [`FontSet`] could not be made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FontSetError {
    /// One of the files is not a font.
    NotAFont,
    /// A family named as the default or as a fallback is in none of the
    /// files: its name, as it was given.
    NoSuchFamily(String),
}

impl fmt::Display for FontSetError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAFont => formatter.write_str("a file is not a font"),
            Self::NoSuchFamily(name) => write!(formatter, "no font file holds the family {name}"),
        }
    }
}

impl std::error::Error for FontSetError {}

/// Its default family, its fallbacks and the families it holds; no font.
impl fmt::Debug for FontSet {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("FontSet")
            .field("default", &self.default)
            .field("fallbacks", &self.fallbacks)
            .field("families", &self.families)
            .finish_non_exhaustive()
    }
}

impl FontSet {
    /// A set of exactly the fonts in `files`, each the bytes of a font
    /// file, with no font of the system: `default` is its default family
    /// and `fallbacks` its fallback families, in the order they are tried.
    ///
    /// Refused when a file is not a font, and when `default` or one of
    /// `fallbacks` is a family none of the files holds.
    pub fn only(
        default: &str,
        fallbacks: &[&str],
        files: impl IntoIterator<Item = Vec<u8>>,
    ) -> Result<Self, FontSetError> {
        let mut collection = Collection::new(CollectionOptions {
            shared: false,
            system_fonts: false,
        });
        let mut families = Vec::new();
        for file in files {
            let registered = collection.register_fonts(Blob::new(Arc::new(file)), None);
            if registered.is_empty() {
                return Err(FontSetError::NotAFont);
            }
            for (family, _) in registered {
                if let Some(name) = collection.family_name(family) {
                    families.push(name.to_owned());
                }
            }
        }
        families.sort_unstable();
        families.dedup();
        for name in std::iter::once(&default).chain(fallbacks) {
            if collection.family_id(name).is_none() {
                return Err(FontSetError::NoSuchFamily((*name).to_owned()));
            }
        }
        Ok(Self {
            collection,
            default: default.to_owned(),
            fallbacks: fallbacks.iter().map(|name| (*name).to_owned()).collect(),
            families,
        })
    }

    /// The names of the families it holds, sorted.
    pub fn families(&self) -> Vec<String> {
        self.families.clone()
    }
}
