//! The Core Text adapter's check, on demand on macOS
//! (`mise run coretext-check`, `docs/dev-practices/on-demand-checks.md`).
//!
//! What Core Text draws is the system's, so no test runs this: the gate
//! builds it and never runs it. It holds the adapter to the rasteriser
//! port's contract (`contract`), says what the user's font-smoothing
//! preference holds and what was decided from it, and compares the
//! adapter's masks with Core Text's own drawing of the weight sentence
//! (`compare`). Its exit status is the result: 0 when every property
//! holds and every comparison is within its thresholds.
//!
//! The fixture font and the captures are compiled in, so it reads no file.

#[cfg(target_os = "macos")]
mod compare;
#[cfg(target_os = "macos")]
mod contract;

/// The fixture font, Noto Sans Mono, the stand-in for Menlo.
#[cfg(target_os = "macos")]
const MONO: &[u8] = include_bytes!("../../../../tests/fonts/NotoSansMono-Regular.subset.ttf");

#[cfg(target_os = "macos")]
fn main() {
    use editor_raster_coretext::defaults::{FontDefaults, smoothing};

    #[expect(
        clippy::disallowed_methods,
        reason = "the check says what this machine's preference holds, on demand"
    )]
    let defaults = editor_raster_coretext::SystemDefaults::new();
    let preference = defaults.font_smoothing();
    println!(
        "check: AppleFontSmoothing is {preference:?}: text is smoothed: {}",
        smoothing(preference)
    );
    let contract = contract::run();
    let compared = compare::run();
    std::process::exit(if contract && compared { 0 } else { 1 });
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("check: Core Text is on macOS alone");
    std::process::exit(2);
}
