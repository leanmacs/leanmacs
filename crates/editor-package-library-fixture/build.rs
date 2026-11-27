//! Builds the fixture package libraries: each C file of `fixture/`
//! compiled and linked as a shared library of its own into `OUT_DIR`,
//! whose paths the crate publishes. Each finds the package runtime's
//! generated header, `crates/editor-package-runtime/include/`, on its
//! include path.
//!
//! They are linked here, with the C compiler `cc` finds, and not as Cargo
//! `cdylib`s: a `cdylib`'s path cannot reach another crate's tests on
//! stable Cargo (`editor-syntax-fixture-ini`'s crate docs).

use std::path::PathBuf;

#[expect(
    clippy::disallowed_methods,
    reason = "a build script's inputs are Cargo's environment"
)]
fn main() {
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo sets OUT_DIR"));
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").expect("Cargo sets CARGO_CFG_TARGET_OS");
    let (link, extension) = if target_os == "macos" {
        ("-dynamiclib", "dylib")
    } else {
        ("-shared", "so")
    };
    let compiler = cc::Build::new().std("c11").get_compiler();
    let header = "../editor-package-runtime/include";
    println!("cargo:rerun-if-changed={header}/editor_package_runtime.h");

    for (source, name, variable) in [
        (
            "fixture/runtime_too_small.c",
            "package-runtime-too-small",
            "EDITOR_PACKAGE_LIBRARY_FIXTURE_RUNTIME_TOO_SMALL",
        ),
        (
            "fixture/init_failed.c",
            "package-init-failed",
            "EDITOR_PACKAGE_LIBRARY_FIXTURE_INIT_FAILED",
        ),
        (
            "fixture/older_runtime.c",
            "package-older-runtime",
            "EDITOR_PACKAGE_LIBRARY_FIXTURE_OLDER_RUNTIME",
        ),
        (
            "fixture/current_runtime.c",
            "package-current-runtime",
            "EDITOR_PACKAGE_LIBRARY_FIXTURE_CURRENT_RUNTIME",
        ),
        (
            "fixture/no_declaration.c",
            "package-no-declaration",
            "EDITOR_PACKAGE_LIBRARY_FIXTURE_NO_DECLARATION",
        ),
        (
            "fixture/newer_runtime.c",
            "package-newer-runtime",
            "EDITOR_PACKAGE_LIBRARY_FIXTURE_NEWER_RUNTIME",
        ),
    ] {
        println!("cargo:rerun-if-changed={source}");
        let library = out.join(format!("lib{name}.{extension}"));
        let mut command = compiler.to_command();
        command
            .arg(link)
            .arg("-I")
            .arg(header)
            .arg(source)
            .arg("-o")
            .arg(&library);
        let status = command
            .status()
            .unwrap_or_else(|error| panic!("running {command:?}: {error}"));
        assert!(status.success(), "{command:?} failed: {status}");
        println!("cargo:rustc-env={variable}={}", library.display());
    }
}
