//! The real compiler ([`CcCompiler`]) against what the core's fake of
//! [`Compile`] assumes: sources that compile link into a shared library at
//! the path asked for, and sources that do not fail with the compiler's
//! output. The C sources are written into a temporary directory of the
//! test's own.

use editor_grammar_build::{CcCompiler, Compile};
use std::path::{Path, PathBuf};

const TARGET: &str = env!("EDITOR_GRAMMAR_BUILD_TEST_TARGET");
const HOST: &str = env!("EDITOR_GRAMMAR_BUILD_TEST_HOST");

/// Writes `text` to `name` in `dir`, which the test owns.
fn write(dir: &Path, name: &str, text: &str) -> PathBuf {
    let path = dir.join(name);
    #[expect(
        clippy::disallowed_methods,
        reason = "the test writes a C source into its own temporary directory"
    )]
    std::fs::write(&path, text)
        .unwrap_or_else(|error| panic!("writing {}: {error}", path.display()));
    path
}

/// Whether `path` is a file, read from the disk the compiler wrote to.
fn is_file(path: &Path) -> bool {
    #[expect(
        clippy::disallowed_methods,
        reason = "the test asks whether the compiler wrote the library into its own temporary directory"
    )]
    let file = path.is_file();
    file
}

#[test]
fn sources_that_compile_link_into_a_shared_library_at_the_path_asked_for() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let source = write(
        dir.path(),
        "tiny.c",
        "const void *tree_sitter_tiny(void) { return 0; }\n",
    );
    let library = dir.path().join("libtree-sitter-tiny.so");
    let compiled = CcCompiler::new(TARGET, HOST, "0").compile(&[source], dir.path(), &library);
    assert_eq!(compiled, Ok(()));
    assert!(is_file(&library), "no library at {}", library.display());
}

#[test]
fn a_source_that_does_not_compile_fails_with_the_compilers_output() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let source = write(
        dir.path(),
        "broken.c",
        "#error \"a source that does not compile\"\n",
    );
    let library = dir.path().join("libtree-sitter-broken.so");
    let compiled = CcCompiler::new(TARGET, HOST, "0").compile(&[source], dir.path(), &library);
    let output = compiled.expect_err("the compile fails");
    assert!(
        output.contains("a source that does not compile"),
        "the output holds the error: {output}"
    );
    assert!(!is_file(&library));
}
