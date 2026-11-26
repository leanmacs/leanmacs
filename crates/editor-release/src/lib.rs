//! Release tooling's core: what names a build, what the app bundle holds
//! and where, what its link stubs hold, how the disk image is packed, and
//! how the nightly is published.
//!
//! - [`bundle`]: the app bundle's layout, as `stage-bundle` stages it: the
//!   bundle as shipped, from the list `editorShipped` prints, or module
//!   files alone, for `mise run module-bench`.
//! - [`build_id`]: the build ID, HEAD's committer time in UTC as
//!   `YYYYMMDDHHMMSS`, or `LEANMACS_BUILD_ID` when that is set.
//! - [`commit`]: the commit, HEAD's full SHA, or `LEANMACS_COMMIT` when that
//!   is set.
//! - [`dmg`]: the `.dmg`'s name, the plan of programs that packs it, and the
//!   check of a mounted volume's root.
//! - [`install`]: the first-launch steps and the version command, as
//!   `packaging/macos/README.txt` says them, kept once for the page and the
//!   notes.
//! - [`nightly`]: the rolling `nightly` prerelease: the check of the
//!   mounted app's stamp against the build, `build.json`, the `.sha256`
//!   line, the release notes, which old build-ID copies to prune, and the
//!   ordered `gh` calls that publish; and `build.json` read back
//!   (`parse_build_json`).
//! - [`site`]: the download page, one self-contained `index.html` for the
//!   build a `build.json` describes, which loads nothing.
//! - [`stubs`]: the link stubs a relink with the toolchain's own linker
//!   needs, made from the executable's import table, and its
//!   `platform-version`.
//!
//! The crate touches nothing itself. It reads the environment through the
//! [`ports::Env`] port, runs programs through the [`ports::Process`] port
//! and reaches files through the [`ports::Files`] port, and the root
//! `clippy.toml` refuses the calls that would reach any of them directly.
//! Its tests run on the published fakes ([`fake`]), and [`contract`] holds
//! the checks a real process adapter and a real files adapter run to show
//! the fakes behave as the system does. The adapters and the binaries
//! (`leanmacs-release`, `stage-bundle`, `link-stubs`) are `editor-release-std`; the editor
//! never links either crate (`deny.toml`).

pub mod build_id;
pub mod bundle;
pub mod commit;
pub mod contract;
pub mod dmg;
pub mod fake;
pub mod install;
pub mod nightly;
pub mod ports;
pub mod site;
pub mod stubs;
