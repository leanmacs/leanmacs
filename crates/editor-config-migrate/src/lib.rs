//! Converting a config directory from the old form to the form the editor
//! loads (`docs/design/lean-runtime.md`, "Config and reload"): `mise run
//! config-migrate [-- <config dir>]`, the `config-migrate` binary of
//! `editor-config-migrate-std`.
//!
//! The old form is `.lean` files directly in the directory, with no
//! header, elaborated in the byte order of their names, each seeing what
//! the ones before it defined, with `Editor` imported and opened for them.
//! The form the editor loads is a root, `init.lean`, and the config files
//! it imports, each a Lean module under `Config/` that writes its own
//! header.
//!
//! - [`lines`]: the rules read from a file's text, a line at a time, with
//!   no Lean: whether it defines `setup`, declares something private,
//!   starts with a header or leaves a block open, and the module name a
//!   file's name gives.
//! - [`command`]: the command line, and the default directory,
//!   `$XDG_CONFIG_HOME/leanmacs` or `$HOME/.config/leanmacs`.
//! - [`migrate`]: the conversion, every check made before anything moves,
//!   and the record of what moved where and why.
//!
//! The crate touches nothing itself: files are reached through the
//! [`ports::Files`] port, which the root `clippy.toml` refuses any other way
//! to, and the binary reads the command line and the environment and hands
//! them in as data. Its tests run on the published fake ([`fake`]), and
//! [`contract`] is the check the real adapter runs to show the fake
//! behaves as the file system does.

pub mod command;
pub mod contract;
pub mod fake;
pub mod lines;
pub mod migrate;
pub mod ports;
