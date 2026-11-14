//! The real adapter of the `Shaper` port ([`editor_layout::shaper`]), over
//! Parley and fontique: [`ParleyShaper`].
//!
//! **No type of Parley or of fontique is public here.** A caller hands
//! this crate font files as bytes ([`FontSet`]) and gets the port's own
//! types back, and `deny.toml` lets no other crate depend on either
//! library. Both are pinned to an exact version (`Cargo.toml`).
//!
//! # Where the fonts come from
//!
//! A [`FontSet`] is the one seam: the fonts a shaper draws in, the family
//! a spec with no family is shaped in, and where a character the family
//! asked for lacks is looked for.
//!
//! - [`FontSet::only`] holds exactly the font files it is handed, as
//!   bytes, with the system's fonts off, a default family and fallback
//!   families by name. What a shaper over it gives depends on the text and
//!   those bytes alone: it reads no file, no environment variable and no
//!   locale. Every test uses it, over the fixture fonts.
//! - [`FontSet::system`] is the fonts of the machine, for the editor: the
//!   default family is the system's monospace family, and fallback is by
//!   script and for emoji as fontique finds the system's. No test calls
//!   it (`clippy.toml`). Its check is on demand, `mise run shaper-system`:
//!   the example `examples/system.rs` holds a shaper over it to the port's
//!   contract and says which family the default is.
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
//! - **A glyph is drawn in the font Parley picked for its cluster**, which
//!   is the first of the families above that has the cluster's
//!   characters (after them, in the system's set, the families the system
//!   gives for the script), and the first of them when none has: the
//!   glyph is then that font's missing glyph, glyph 0. Each font a run is
//!   drawn in is an
//!   entry of [`resolved`]: the file's bytes, the face, the size, the
//!   variation coordinates and what is synthesised, with fontique's
//!   number for the file. `shape` adds a layout's fonts to the table
//!   before it returns, and a break adds none.
//! - **Runs are shaped whole, and only runs.** A ligature forms inside a
//!   font run and never across two, a letter and its combining mark are
//!   one cluster, and each family on a line has its own advances.
//! - **A line's glyphs are in visual order**, as the Unicode bidirectional
//!   algorithm orders them: runs from the left edge, and the clusters of a
//!   right-to-left run in the reverse of their order in the text. A
//!   glyph's `x` is its pen position, counted from the left edge through
//!   the advances before it, and its `dx` and `dy` are the offsets Parley
//!   gives its outline. A ligature's glyph starts at the left edge of the
//!   leftmost of its clusters.
//! - **The base direction of every line is left to right**, whatever its
//!   first character: a line that starts in Hebrew still starts at the
//!   left edge, with its Hebrew run reordered, as a code editor shows it.
//!   The fast path for a line that is left to right only is Parley's own:
//!   with that base direction it skips bidirectional resolution for a
//!   text with no right-to-left character. The adapter adds none, since it
//!   reads clusters back the same way either way. No test here can show
//!   the branch inside Parley ("When the pin moves").
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
//! - **Setting the fonts again is another generation**
//!   ([`ParleyShaper::set_fonts`]), whether or not they differ: the table
//!   of resolved fonts starts again from nothing, so a resolved id of
//!   before means nothing now, the metrics are asked of the new fonts,
//!   and the id of every spec stays. Nothing calls it yet: watching the
//!   system's fonts for changes is not built.
//!
//! # The rules this crate pins
//!
//! Its tests run on the fixture fonts under `tests/fonts` alone, compiled
//! in (`tests/common/mod.rs`), and state relations, never a number of
//! Parley's or of a font's:
//!
//! - the port's contract, [`editor_layout::shaper::contract`]
//!   (`tests/contract.rs`);
//! - what a font set holds and refuses, and that no font but the fixture
//!   files' is drawn in: a character no fixture covers is the primary's
//!   missing glyph (`tests/fixtures.rs`);
//! - fallback: a character the primary lacks is drawn in the fallback
//!   that covers it, at the spec's size, and a character is looked for in
//!   the spec's family, then the default, then the fallbacks in the set's
//!   order (`tests/shaping.rs`);
//! - that shaping describes every font a line is drawn in before it
//!   returns, so a break adds none, and what setting the fonts again does
//!   (`tests/adapter.rs`);
//! - the rules above (`tests/adapter.rs`, and the stand-ins in
//!   `src/shaper.rs`);
//! - what shaping whole runs gives on real fonts: the `fi` ligature as one
//!   glyph, a combining mark, two families on one line, and a spec's size,
//!   weight, slant and line height reaching the font a glyph is drawn in
//!   and the line's height (`tests/shaping.rs`).
//!
//! - visual order: Latin then Hebrew in the order of the bidirectional
//!   algorithm, written out by hand, the base direction, cluster order on
//!   a left-to-right line, and a glyph's offset carried
//!   (`tests/shaping.rs`); where a ligature's glyph starts in each
//!   direction, on clusters written out by hand (`src/shaper.rs`), since
//!   no fixture font has a ligature in a right-to-left script.
//!
//! It pins no rule of layout's: which segments are shaped, and when, is
//! `editor-layout`'s, pinned there on the port's fake. One file runs
//! layout over this adapter, for the wiring alone (`tests/layout.rs`):
//! the adapter builds as many Parley layouts as layout's own counters say
//! it shaped segments, none for a break, a reuse or a cursor, and of a
//! very long row no layout holds more than the longest segment layout
//! cuts. So a row costs one Parley layout for each segment of it that is
//! shaped, and never a layout of the whole row or of the document.
//!
//! # When the pin moves
//!
//! Parley changes its API and its behaviour between releases. On a bump
//! of `parley` or `fontique`, in a commit of its own:
//!
//! 1. Run the gate: the contract and the tests above are what a new
//!    version is held to.
//! 2. Read again the two places that make the left-to-right fast path, as
//!    they were at 0.13.0: `parley_engine/src/bidi.rs`, where a text with
//!    no character that needs it and a base level of 0 returns before
//!    resolving, and `parley_engine/src/analysis.rs`, where resolution is
//!    run only when a character needs it or the base direction is right
//!    to left.
//! 3. Check that Parley still breaks at a carriage return, U+2028 and
//!    U+2029 and at no other character short of a line feed (the
//!    stand-ins), and still makes a line at least as tall as the default
//!    style (the default style of no height).
//! 4. Run `mise run shaper-system` on each platform at hand: the gate
//!    never asks for the system's fonts, so only it shows that fontique
//!    still finds them.
//! 5. Run `mise run linux-ci`: the feature `fontconfig-dlopen` is what
//!    lets the pin build on Linux with cargo alone.
//!
//! [`shape`]: editor_layout::shaper::Shaper::shape
//! [`resolved`]: editor_layout::shaper::Shaper::resolved

mod fonts;
mod shaper;

pub use fonts::{FontSet, FontSetError};
pub use shaper::{ParleyLine, ParleyShaper, ShapeCounters};
