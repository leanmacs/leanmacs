//! The adapter held to the rasteriser port's contract
//! (`editor_raster::contract`), smoothed and not, on the fixture font at
//! 14 and 28 pixels, with the glyph ids Core Text reads from the font's
//! own character map.

use std::sync::Arc;

use editor_raster::ResolvedFont;
use editor_raster::contract::{Fixture, check};
use editor_raster_coretext::{CoreTextRasterizer, glyphs_of};

use crate::MONO;

/// The fixture font at `size` pixels.
pub fn mono(size: f32) -> ResolvedFont {
    ResolvedFont {
        data: Arc::new(MONO),
        file: 1,
        index: 0,
        size,
        coords: Vec::new(),
        embolden: false,
        skew: None,
    }
}

/// Runs the contract; whether every property held.
pub fn run() -> bool {
    let mut held = true;
    for smoothing in [true, false] {
        for size in [14.0, 28.0] {
            let font = mono(size);
            let Some(ids) = glyphs_of(&font, "HI ") else {
                println!("contract: Core Text has no face or no glyphs of the fixture font");
                return false;
            };
            let fixture = Fixture {
                font,
                h: ids[0],
                i: ids[1],
                space: ids[2],
                hint: false,
            };
            let failures = check(
                &mut || Box::new(CoreTextRasterizer::new(smoothing)),
                &fixture,
            );
            let name = format!("contract: smoothing {smoothing}, {size} px");
            if failures.is_empty() {
                println!("{name}: every property holds");
            } else {
                held = false;
                for failure in failures {
                    println!("{name}: FAILS {failure}");
                }
            }
        }
    }
    held
}
