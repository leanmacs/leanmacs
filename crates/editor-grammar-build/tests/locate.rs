//! The real locator ([`CargoMetadata`]) against what the core's fake of
//! [`Locate`] assumes: a dependency of the calling crate is found at the
//! directory holding its `Cargo.toml`, and a name that is none of its
//! dependencies is refused naming it. The calling crate is this one, whose
//! dependency `cc` is in the root lock; `cargo metadata` reads the
//! workspace and changes nothing.

use editor_grammar_build::{CargoMetadata, Locate, not_a_dependency};

fn locator() -> CargoMetadata {
    CargoMetadata::new(
        env!("CARGO"),
        env!("EDITOR_GRAMMAR_BUILD_TEST_TARGET"),
        concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml"),
        env!("CARGO_PKG_NAME"),
    )
}

#[test]
fn a_dependency_is_found_at_the_directory_holding_its_manifest() {
    let found = locator().locate("cc").expect("cc is a dependency");
    let manifest = found.join("Cargo.toml");
    #[expect(
        clippy::disallowed_methods,
        reason = "the test reads the manifest of the dependency the locator found, in Cargo's registry"
    )]
    let text = std::fs::read_to_string(&manifest)
        .unwrap_or_else(|error| panic!("reading {}: {error}", manifest.display()));
    assert!(text.contains("name = \"cc\""), "{}", manifest.display());
    assert!(
        text.contains("version = \"1.11.1\""),
        "{}",
        manifest.display()
    );
}

#[test]
fn a_name_that_is_no_dependency_is_refused_naming_it() {
    assert_eq!(
        locator().locate("tree-sitter-nothing"),
        Err(not_a_dependency(
            "tree-sitter-nothing",
            "editor-grammar-build"
        ))
    );
}
