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

use parley::fontique::{Blob, Collection, CollectionOptions, GenericFamily};

/// The family a spec with no family is shaped in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum DefaultFamily {
    /// A family, by its name.
    Named(String),
    /// Whichever families the system gives for the generic `monospace`.
    Monospace,
}

/// The fonts a shaper draws in, and the order it looks for a character in
/// them: the family a run's spec names, then the default family, then the
/// fallback families in the order given. A spec may name a CSS generic
/// family (`system-ui`, `monospace`, ...): the families the set gives for
/// it, by the platform for [`FontSet::system`] and by
/// [`FontSet::with_generic`] for a set of given files.
pub struct FontSet {
    /// The fonts.
    pub(crate) collection: Collection,
    /// The default family: what a spec with no family is shaped in.
    pub(crate) default: DefaultFamily,
    /// The fallback families, in the order they are tried.
    pub(crate) fallbacks: Vec<String>,
    /// The name of the default family, when it has one.
    default_name: Option<String>,
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
    /// A name given as a generic family is not one of CSS's generic family
    /// names: the name, as it was given.
    NotAGeneric(String),
}

impl fmt::Display for FontSetError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAFont => formatter.write_str("a file is not a font"),
            Self::NoSuchFamily(name) => write!(formatter, "no font file holds the family {name}"),
            Self::NotAGeneric(name) => write!(formatter, "{name} is not a generic family name"),
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
            default: DefaultFamily::Named(default.to_owned()),
            fallbacks: fallbacks.iter().map(|name| (*name).to_owned()).collect(),
            default_name: Some(default.to_owned()),
            families,
        })
    }

    /// The fonts of the machine: what the editor draws in. The default
    /// family is the system's monospace family, and a character the
    /// family asked for lacks is looked for in the families the system
    /// gives for its script, and for an emoji in the system's emoji
    /// family, as fontique finds them.
    ///
    /// What it holds depends on the machine, so no test calls it
    /// (the root `clippy.toml`); `mise run shaper-system` holds a shaper
    /// over it to the port's contract, on demand.
    pub fn system() -> Self {
        // The one place the system's fonts are turned on.
        let mut collection = Collection::new(CollectionOptions {
            shared: false,
            system_fonts: true,
        });
        let monospace: Vec<_> = collection
            .generic_families(GenericFamily::Monospace)
            .collect();
        let default_name = monospace
            .first()
            .and_then(|family| collection.family_name(*family))
            .map(str::to_owned);
        let mut families: Vec<String> = collection.family_names().map(str::to_owned).collect();
        families.sort_unstable();
        families.dedup();
        Self {
            collection,
            default: DefaultFamily::Monospace,
            fallbacks: Vec::new(),
            default_name,
            families,
        }
    }

    /// This set with the generic family `generic`, a CSS generic family
    /// name such as `system-ui` or `monospace`, given as `families` in
    /// that order: a spec naming `generic` is shaped in them (the crate's
    /// docs, "How a text is shaped"). A set of
    /// given files gives no generic family until it is given one here.
    ///
    /// Refused when `generic` is no generic family name, and when one of
    /// `families` is a family the set does not hold.
    pub fn with_generic(mut self, generic: &str, families: &[&str]) -> Result<Self, FontSetError> {
        let parsed = GenericFamily::parse(generic)
            .ok_or_else(|| FontSetError::NotAGeneric(generic.to_owned()))?;
        let mut ids = Vec::with_capacity(families.len());
        for name in families {
            let id = self
                .collection
                .family_id(name)
                .ok_or_else(|| FontSetError::NoSuchFamily((*name).to_owned()))?;
            ids.push(id);
        }
        self.collection
            .set_generic_families(parsed, ids.into_iter());
        Ok(self)
    }

    /// The names of the families it holds, sorted.
    pub fn families(&self) -> Vec<String> {
        self.families.clone()
    }

    /// The name of its default family: the family a spec with no family
    /// is shaped in. For the system's fonts it is the first family the
    /// system gives for `monospace`, and `None` when it gives none.
    pub fn default_family(&self) -> Option<&str> {
        self.default_name.as_deref()
    }
}
