//! Generates the package runtime's C header with cbindgen, from the
//! definitions' one source file and `cbindgen.toml`, into `OUT_DIR` alone
//! (`src/lib.rs`). `with_src`, not `with_crate`: no `cargo metadata` runs
//! in the build, and the definitions are one file on purpose.

use std::path::PathBuf;

#[expect(
    clippy::disallowed_methods,
    reason = "a build script's inputs are Cargo's environment"
)]
fn main() {
    let manifest = PathBuf::from(
        std::env::var_os("CARGO_MANIFEST_DIR").expect("Cargo sets CARGO_MANIFEST_DIR"),
    );
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo sets OUT_DIR"));
    let config = manifest.join("cbindgen.toml");
    let source = manifest.join("../editor-package-runtime/src/lib.rs");
    println!("cargo:rerun-if-changed={}", config.display());
    println!("cargo:rerun-if-changed={}", source.display());
    let config = cbindgen::Config::from_file(&config)
        .unwrap_or_else(|error| panic!("reading {}: {error}", config.display()));
    cbindgen::Builder::new()
        .with_config(config)
        .with_src(&source)
        .generate()
        .unwrap_or_else(|error| panic!("generating the header from {}: {error}", source.display()))
        .write_to_file(out.join("editor_package_runtime.h"));
}
