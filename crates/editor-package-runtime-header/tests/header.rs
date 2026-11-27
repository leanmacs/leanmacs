//! The checked-in C header is the one cbindgen generates from the
//! definitions: a change to `editor-package-runtime` that is not copied into
//! `crates/editor-package-runtime/include/editor_package_runtime.h` fails
//! here, and every change to the runtime's layout shows as a diff of the
//! header in review.

use editor_package_runtime_header::{GENERATED, GENERATED_AT};

/// The header as checked in.
const CHECKED_IN: &str =
    include_str!("../../editor-package-runtime/include/editor_package_runtime.h");

#[test]
fn the_checked_in_header_is_the_one_cbindgen_generates() {
    assert!(
        CHECKED_IN == GENERATED,
        "crates/editor-package-runtime/include/editor_package_runtime.h differs from the header \
         cbindgen generates from crates/editor-package-runtime/src/lib.rs: copy {GENERATED_AT} \
         over it"
    );
}
