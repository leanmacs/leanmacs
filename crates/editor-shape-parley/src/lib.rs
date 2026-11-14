//! The real adapter of the `Shaper` port ([`editor_layout::shaper`]), over
//! Parley and fontique: [`ParleyShaper`].
//!
//! **No type of Parley or of fontique is public here.** A caller hands
//! this crate font files as bytes ([`FontSet`]) and gets the port's own
//! types back, and `deny.toml` lets no other crate depend on either
//! library. Both are pinned to an exact version (`Cargo.toml`).
//!
//! # How a text is shaped
//!
//! - **One Parley layout for each [`shape`] call**, of the text it is
//!   handed, which is one segment of one buffer row, and none for a break:
//!   the layout is kept ([`ParleyLine`]) and Parley breaks it again at
//!   another width without shaping. `PlainEditor` and a layout of a whole
//!   document are not used: both shape everything again on each edit.
//!   [`ParleyShaper::counters`] counts the layouts and their bytes.
//! - **A font is a spec stated to Parley**: its family, then the set's
//!   default family, then the set's fallback families as the families a
//!   character is looked for in, in that order; its size in pixels; its
//!   weight; its slant; its line height. A spec with no family starts at
//!   the default family.
//! - **A line is as tall as the fonts on it.** Parley makes a line at
//!   least as tall as a layout's default style; a text's default style
//!   here has no height, and every byte states its font, so a line in a
//!   small font is not held to font 0's height. An empty text is one line
//!   as tall as its run's font. A line height in pixels is the line's
//!   height, with one limit: Parley's line always holds its baseline, so a
//!   height so small that the line would end above its baseline (under
//!   about three quarters of the size) gives a line a little taller than
//!   was asked, and a height of 0 pixels at a size that is not 0 is not a
//!   line of no height. A font of size 0 is.
//! - **Runs are shaped whole, and only runs.** A ligature forms inside a
//!   font run and never across two, a letter and its combining mark are
//!   one cluster, and each family on a line has its own advances.
//! - **Heights and baselines are whole pixels and advances are the
//!   font's own**: layouts are built with Parley's quantising on.
//! - **Nothing in a text forces a break.** Parley breaks at a carriage
//!   return, at U+2028 and at U+2029, which the port says are content, so
//!   it is handed a stand-in of the same length in bytes for each: a space
//!   for a return and U+FFFD for a separator. Offsets stay true. What such
//!   a character should look like is not decided by this.
//! - **Breaking is Parley's**: at words, by the Unicode rules; a word
//!   wider than the width breaks inside itself, so a line fits or holds
//!   one cluster; and spaces at a wrap count toward the width and wrap.
//! - **A font's metrics** are those of one space shaped in it.
//!
//! # The rules this crate pins
//!
//! Its tests run on the fixture fonts under `tests/fonts` alone, compiled
//! in (`tests/common/mod.rs`), and state relations, never a number of
//! Parley's or of a font's:
//!
//! - the port's contract, [`editor_layout::shaper::contract`]
//!   (`tests/contract.rs`);
//! - what a font set holds and refuses (`tests/fixtures.rs`);
//! - the rules above (`tests/adapter.rs`, and the stand-ins in
//!   `src/shaper.rs`);
//! - what shaping whole runs gives on real fonts: the `fi` ligature as one
//!   glyph, a combining mark, two families on one line, and a spec's size,
//!   weight, slant and line height reaching the font a glyph is drawn in
//!   and the line's height (`tests/shaping.rs`).
//!
//! It pins no rule of layout's: which segments are shaped, and when, is
//! `editor-layout`'s, pinned there on the port's fake.
//!
//! [`shape`]: editor_layout::shaper::Shaper::shape

mod fonts;
mod shaper;

pub use fonts::{FontSet, FontSetError};
pub use shaper::{ParleyLine, ParleyShaper, ShapeCounters};
