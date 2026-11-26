//! Builds the fixture grammar library: the checked-in generated INI parser
//! (`grammar/src/parser.c`) and the fixture's own exports
//! (`grammar/exports.c`), compiled and linked as a shared library into
//! `OUT_DIR`, whose path the crate publishes as `LIBRARY`.
//!
//! It is linked here, with the C compiler `cc` finds, and not as a Cargo
//! `cdylib`: a `cdylib`'s path cannot reach another crate's tests on stable
//! Cargo, and a Rust `cdylib` does not export the C symbols of a static
//! archive linked into it (the crate docs).

use std::path::PathBuf;

#[expect(
    clippy::disallowed_methods,
    reason = "a build script's inputs are Cargo's environment"
)]
fn main() {
    for input in [
        "grammar/src/parser.c",
        "grammar/src/tree_sitter/parser.h",
        "grammar/src/tree_sitter/alloc.h",
        "grammar/src/tree_sitter/array.h",
        "grammar/exports.c",
    ] {
        println!("cargo:rerun-if-changed={input}");
    }
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo sets OUT_DIR"));
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").expect("Cargo sets CARGO_CFG_TARGET_OS");
    let (link, file) = if target_os == "macos" {
        ("-dynamiclib", "libtree-sitter-ini.dylib")
    } else {
        ("-shared", "libtree-sitter-ini.so")
    };
    let library = out.join(file);

    let compiler = cc::Build::new()
        .include("grammar/src")
        .std("c11")
        .warnings(false)
        .get_compiler();
    let mut command = compiler.to_command();
    command
        .arg(link)
        .arg("grammar/src/parser.c")
        .arg("grammar/exports.c")
        .arg("-o")
        .arg(&library);
    let status = command
        .status()
        .unwrap_or_else(|error| panic!("running {command:?}: {error}"));
    assert!(status.success(), "{command:?} failed: {status}");

    println!(
        "cargo:rustc-env=EDITOR_SYNTAX_FIXTURE_INI_LIBRARY={}",
        library.display()
    );
}
