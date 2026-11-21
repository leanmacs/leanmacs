//! The rasteriser port's macOS adapter: glyph masks drawn by Core Text,
//! as macOS draws text.
//!
//! Core Text's smoothing dilates an outline by an amount that grows with
//! the size and with the text colour's luminance
//! (`docs/design/text-and-display.md`), which no constant of swash's
//! matches. So on macOS the renderer is handed this rasteriser, which has
//! Core Text draw each glyph, and swash draws whatever it declines.
//!
//! The crate builds on every platform. Its pure modules hold every
//! decision and are tested everywhere, in the gate:
//!
//! - [`bounds`]: where a glyph's bitmap goes, and the pen in it;
//! - [`compare`]: how its masks are compared with Core Text's own drawing;
//! - [`defaults`]: the `FontDefaults` port, which says what
//!   `AppleFontSmoothing` holds, its fake, and whether text is smoothed;
//! - [`decline`]: which fonts are left to swash;
//! - [`fill`]: the grey a luminance bucket is drawn in.
//!
//! Its Core Text module and its real adapters are macOS only:
//! `CoreTextRasterizer`, the rasteriser, and `SystemDefaults`, the
//! `FontDefaults` that reads the user's preference.
//!
//! # What runs where
//!
//! No test under `#[cfg(test)]` calls Core Text or reads this machine's
//! preferences. What Core Text draws is the system's: it changes between
//! macOS releases, and the gate's macOS runner is not the machine its
//! captures were made on. The gate builds the macOS module and the
//! example `check` (clippy and rustdoc), and runs nothing of either. The
//! adapter's contract and its comparison with Core Text's own drawing run
//! on demand, on macOS (`mise run coretext-check`,
//! `docs/dev-practices/on-demand-checks.md`).
//!
//! # Where an addition goes
//!
//! A new fact of a font the adapter declines goes in [`decline`]; a new
//! rule every rasteriser keeps goes in `editor_raster::contract`; a
//! decision about what Core Text is asked goes in a pure module here, with
//! its test, and the macOS module only carries it out.

pub mod bounds;
pub mod compare;
pub mod decline;
pub mod defaults;
pub mod fill;

#[cfg(target_os = "macos")]
mod coretext;
#[cfg(target_os = "macos")]
pub use coretext::{CoreTextRasterizer, SystemDefaults, glyphs_of};
