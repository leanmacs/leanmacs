//! Hands the integration tests the target and host triples this crate is
//! built for (`tests/compile.rs`, `tests/locate.rs`): Cargo sets `TARGET`
//! and `HOST` for a build script alone, never for a test at run time, so
//! they reach the tests as `EDITOR_GRAMMAR_BUILD_TEST_TARGET` and
//! `EDITOR_GRAMMAR_BUILD_TEST_HOST`, read with `env!`.

#[expect(
    clippy::disallowed_methods,
    reason = "a build script's inputs are Cargo's environment"
)]
fn main() {
    let target = std::env::var("TARGET").expect("Cargo sets TARGET for a build script");
    let host = std::env::var("HOST").expect("Cargo sets HOST for a build script");
    println!("cargo:rustc-env=EDITOR_GRAMMAR_BUILD_TEST_TARGET={target}");
    println!("cargo:rustc-env=EDITOR_GRAMMAR_BUILD_TEST_HOST={host}");
    println!("cargo:rerun-if-changed=build.rs");
}
