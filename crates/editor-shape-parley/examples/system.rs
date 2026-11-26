//! The Parley shaper over the fonts of this machine, held to the `Shaper`
//! port's contract (`mise run shaper-system`).
//!
//! On demand, never in the gate: what it finds depends on the machine's
//! fonts. The gate builds this example and never runs it; every test of
//! the crate runs on the fixture fonts, and the root `clippy.toml` forbids
//! [`FontSet::system`] to them.
//!
//! It prints the family the default spec is shaped in and how many
//! families the machine has, then the contract's properties that fail, by
//! name, or that all hold. Its exit status is the result.

use std::process::ExitCode;

use editor_layout::shaper::contract;
use editor_shape_parley::{FontSet, ParleyShaper};

fn main() -> ExitCode {
    #[expect(
        clippy::disallowed_methods,
        reason = "this example is the one place the system's fonts are asked for: it is their check, run on demand"
    )]
    let fonts = FontSet::system();
    println!(
        "shaper-system: the default family is {}, of {} families",
        fonts.default_family().unwrap_or("none"),
        fonts.families().len()
    );
    let failed = contract::check(&ParleyShaper::new(fonts));
    if failed.is_empty() {
        println!(
            "shaper-system: all {} properties of the shaper contract hold",
            contract::PROPERTIES.len()
        );
        return ExitCode::SUCCESS;
    }
    for property in failed {
        println!("shaper-system: failed: {property}");
    }
    ExitCode::FAILURE
}
