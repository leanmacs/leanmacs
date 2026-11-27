//! Loading a package's native library: the C function a package's glue
//! calls at its startup ([`editor_ffi_package_load`]), over the process's
//! one real loader and the process's package runtime
//! (`editor-package-library`; docs/design/packages.md, "A library loaded
//! when the editor runs, as built").
//!
//! It is called by a package's C glue, not by Lean: the glue's
//! `echo_glue_load`, say, from the package's `builtin_initialize`, before
//! Lean's `main` (`tests/packages/echo/ffi/glue.c`). The load opens the
//! library, finds its init, calls it with the runtime, and hands the glue
//! the table the init wrote, through which the glue forwards each of the
//! package's `@[extern]` calls; or it answers why not, as a status the
//! package's Lean side reads back.
//!
//! What a load decides, and in which order it refuses, is
//! `editor_package_library::load`'s, pinned there on the port's fake. The
//! real adapter is made here and nowhere else (the root `clippy.toml`).
//!
//! Tests: `tests/package_load.rs`, each refusal through C on real files;
//! `tests/package_runtime.rs`, libraries compiled from C against an older
//! runtime and against the generated header, loaded and run on the
//! process's runtime; and the fixture package echo's library, whose linked
//! test loads it through its glue (`EchoTest.Linked.echoLoadChecks`).

use std::ffi::c_void;
use std::path::Path;

use editor_package_library::load::load;
use editor_package_library::runtime::RUNTIME;
use editor_package_library_libloading::LibLoading;

use crate::text;

/// The process's loader: the platform's.
#[expect(
    clippy::disallowed_methods,
    reason = "the process's one real loader of package libraries, made here as the crate that wires the library together"
)]
static LIBRARIES: LibLoading = LibLoading::system();

/// Loads the package library at the `len` bytes of path at `path`, for a
/// glue of the package's interface version `interface`, calling its init
/// with the process's package runtime, and answers 0 with the table the
/// init wrote in `table`; or answers the refusal's tag, 1 to 8
/// (`editor_package_library::load::LoadRefusal`), with `table` untouched,
/// and for a newer runtime (7) or another interface (8) writes the two
/// numbers it compared into `versions[0]` and `versions[1]`: what the
/// library needs and the runtime's size, or the library's interface
/// version and `interface`. `versions` is written for those two alone.
///
/// The path is absolute; one that is not is refused as missing.
///
/// # Safety
///
/// `path` points to `len` readable bytes, unless `len` is zero, `table`
/// points to a writable pointer, and `versions` to two writable `u64`s.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_package_load(
    path: *const u8,
    len: usize,
    interface: u32,
    table: *mut *const c_void,
    versions: *mut u64,
) -> u32 {
    // SAFETY: the caller guarantees the pointer and the length.
    let path = unsafe { text::borrow(path, len) };
    match load(&LIBRARIES, Path::new(&*path), interface, &RUNTIME) {
        Ok(loaded) => {
            // SAFETY: the caller guarantees `table` is writable.
            unsafe { table.write(loaded.as_ptr()) };
            0
        }
        Err(refusal) => {
            if let Some((first, second)) = refusal.versions() {
                // SAFETY: the caller guarantees two writable `u64`s.
                unsafe {
                    versions.write(first);
                    versions.add(1).write(second);
                }
            }
            refusal.tag()
        }
    }
}
