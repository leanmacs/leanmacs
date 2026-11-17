//! Release tooling's core: what names a build, and how the disk image is
//! packed.
//!
//! - [`build_id`]: the build ID, HEAD's committer time in UTC as
//!   `YYYYMMDDHHMMSS`, or `LEANMACS_BUILD_ID` when that is set.
//! - [`commit`]: the commit, HEAD's full SHA, or `LEANMACS_COMMIT` when that
//!   is set.
//! - [`dmg`]: the `.dmg`'s name, the plan of programs that packs it, and the
//!   check of a mounted volume's root.
//!
//! The crate touches nothing itself. It reads the environment through the
//! [`ports::Env`] port and runs programs through the [`ports::Process`] port,
//! and its `clippy.toml` refuses the calls that would reach either directly.
//! Its tests run on the published fakes ([`fake`]), and [`contract`] is the
//! check a real process adapter runs to show the fakes' answers are the
//! system's. The adapters and the `leanmacs-release` binary are
//! `editor-release-std`; the editor never links either crate (`deny.toml`).

pub mod build_id;
pub mod commit;
pub mod contract;
pub mod dmg;
pub mod fake;
pub mod ports;
