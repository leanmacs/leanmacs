//! The shaper's places against Core Text's, in a font of the machine
//! (`mise run coretext-menlo`, on demand on macOS).
//!
//! `core_text <font file> <places file> <family>`: the sentence "the window
//! draws this" laid out through [`ParleyShaper`] over the font file alone,
//! with `family` its default, at 28 pixels and at 14, against the places
//! Core Text gave its glyphs (a file `tools/coretext/capture.swift
//! --positions` writes, read by `tests/common/core_text.rs`, the gate's
//! parser). It prints each glyph's error and the line's end's, and exits
//! non-zero when a glyph is not Core Text's or a place is more than an
//! eighth of a pixel from Core Text's, the gate's bound in the fixture font
//! (`tests/core_text.rs`).
//!
//! The gate builds it and never runs it: the font is the machine's.

#[path = "../../tests/common/core_text.rs"]
#[allow(dead_code, reason = "the example uses the parser, not the fixture")]
mod core_text;

use std::process::ExitCode;

use editor_layout::shaper::{FontRun, FontSpec, Length, ShapeInput, ShapedLine, Shaper};
use editor_shape_parley::{FontSet, ParleyShaper};

use core_text::{SENTENCE, at_scale, errors, places, worst};

/// How far a pen place may be from Core Text's, in pixels.
const BOUND: f64 = 0.125;

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let [font, places_file, family] = &arguments[..] else {
        eprintln!("usage: core_text <font file> <places file> <family>");
        return ExitCode::from(2);
    };
    #[expect(
        clippy::disallowed_methods,
        reason = "on demand, this example is given a font of the machine and Core Text's places of it"
    )]
    let (bytes, text) = (std::fs::read(font), std::fs::read_to_string(places_file));
    let (Ok(bytes), Ok(text)) = (bytes, text) else {
        eprintln!("core_text: cannot read {font} or {places_file}");
        return ExitCode::from(2);
    };
    let all = match places(&text) {
        Ok(all) => all,
        Err(refused) => {
            eprintln!("core_text: {refused}");
            return ExitCode::from(2);
        }
    };
    let fonts = match FontSet::only(family, &[], [bytes]) {
        Ok(fonts) => fonts,
        Err(refused) => {
            eprintln!("core_text: {font}: {refused:?}");
            return ExitCode::from(2);
        }
    };
    let shaper = ParleyShaper::new(fonts);
    let mut held = true;
    for (scale, pixels) in [(2, 28), (1, 14)] {
        let spec = FontSpec {
            size: Length::pixels(pixels),
            ..FontSpec::default()
        };
        let id = shaper.font(&spec);
        let input = ShapeInput {
            text: SENTENCE.to_owned(),
            runs: vec![FontRun {
                bytes: 0..SENTENCE.len(),
                font: id,
            }],
        };
        let lines = shaper.shape(&input).break_lines(None);
        let ours: Vec<(u32, f64, f64)> = lines
            .iter()
            .flat_map(|line| &line.glyphs)
            .map(|glyph| {
                (
                    glyph.id,
                    f64::from(glyph.x + glyph.dx),
                    f64::from(glyph.advance),
                )
            })
            .collect();
        let theirs = at_scale(&all, scale);
        let Some((each, end)) = errors(&ours, &theirs) else {
            println!(
                "core_text: at {pixels} px, {} glyphs where Core Text has {}",
                ours.len(),
                theirs.len()
            );
            held = false;
            continue;
        };
        for error in &each {
            let ok = error.same_glyph && error.across.abs() <= BOUND;
            println!(
                "core_text: at {pixels} px glyph {:2} ({}): {:+.4} px{}",
                error.index,
                if error.same_glyph {
                    "Core Text's glyph"
                } else {
                    "ANOTHER GLYPH"
                },
                error.across,
                if ok { "" } else { "  MISSES" }
            );
            held &= ok;
        }
        println!(
            "core_text: at {pixels} px the line ends {end:+.4} px from Core Text's; the worst error is {:.4} px",
            worst(&each, end)
        );
        held &= end.abs() <= BOUND;
    }
    if held {
        println!("core_text: every place is within {BOUND} px of Core Text's");
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
