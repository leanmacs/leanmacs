//! The per-user editors a cold start chooses among.
//!
//! A user's package-set build installs editors of their own beside the
//! shipped default, one directory per build:
//!
//! ```text
//! <data>/editors/<core>/<n>/editor      (n: 1, 2, 3 ..., one per build)
//! <data>/editors/staging-<k>/           (a build in progress)
//! <data>/launch/cold-<pid>              (a cold start's record)
//! ```
//!
//! - **The data directory** ([`data_dir`]) is `--data` when given, else
//!   `$XDG_DATA_HOME/leanmacs` when `XDG_DATA_HOME` is set and not empty,
//!   else `$HOME/.local/share/leanmacs` when `HOME` is set and not empty.
//!   With none of them there is no data directory, and no per-user editor.
//! - **The core** is the identity of the shipped default's core: the one
//!   line of `<default>.core` beside the default executable, or in a
//!   bundle `Contents/Resources/editor.core`
//!   ([`core_record`], [`core_identity`]). An editor built on another core
//!   is not one this default's launcher may start, so only
//!   `<data>/editors/<core>/` is looked in.
//! - **The versions of the core** ([`versions`]) are its entries whose
//!   names are decimal numbers and which hold an `editor`, newest (the
//!   largest number) first. A numbered directory with no `editor` is a
//!   build not finished, and a `staging-*` one a build in progress: neither
//!   is a version.
//! - **The candidates** ([`candidates`]) are the newest version, the one
//!   before it when there is one, and the shipped default, in that order.
//!
//! Everything here is a function of its inputs; [`versions`] alone reads,
//! and only through the [`Files`] port.

use std::ffi::{OsStr, OsString};
use std::path::{Component, Path, PathBuf};

use crate::ports::{Files, Pid};

/// The directory of the app's data under `XDG_DATA_HOME`, or under
/// `$HOME/.local/share`.
pub const APP: &str = "leanmacs";

/// The variable naming the user's data directory, as XDG has it.
pub const XDG_DATA_HOME: &str = "XDG_DATA_HOME";

/// The variable naming the user's home.
pub const HOME: &str = "HOME";

/// The directory of the data directory that holds the per-user editors.
pub const EDITORS: &str = "editors";

/// The executable a version's directory holds.
pub const EXECUTABLE: &str = "editor";

/// The directory of the data directory that holds the cold starts'
/// records.
pub const LAUNCH: &str = "launch";

/// The data directory: `explicit` (`--data`) when given, else from the
/// environment `var` reads, as the module docs say; `None` when there is
/// none.
#[must_use]
pub fn data_dir(
    explicit: Option<&Path>,
    var: impl Fn(&str) -> Option<OsString>,
) -> Option<PathBuf> {
    if let Some(explicit) = explicit {
        return Some(explicit.to_owned());
    }
    let set = |name: &str| {
        var(name)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
    };
    if let Some(data) = set(XDG_DATA_HOME) {
        return Some(data.join(APP));
    }
    set(HOME).map(|home| home.join(".local").join("share").join(APP))
}

/// The record of the shipped default's core: in an app bundle, where the
/// default is `<bundle>/Contents/MacOS/<name>`,
/// `<bundle>/Contents/Resources/<name>.core`, since `codesign` refuses a
/// file in `Contents/MacOS` that is not code; elsewhere `<default>.core`,
/// beside it, where the package-set build writes it.
#[must_use]
pub fn core_record(default: &Path) -> PathBuf {
    let mut name = default.file_name().unwrap_or_default().to_owned();
    name.push(".core");
    let macos = default.parent();
    let contents = macos.and_then(Path::parent);
    match (macos, contents) {
        (Some(macos), Some(contents))
            if macos.file_name() == Some(std::ffi::OsStr::new("MacOS"))
                && contents.file_name() == Some(std::ffi::OsStr::new("Contents")) =>
        {
            contents.join("Resources").join(name)
        }
        _ => {
            let mut path = default.as_os_str().to_owned();
            path.push(".core");
            PathBuf::from(path)
        }
    }
}

/// The core's identity in its record's bytes: their one line, without the
/// space around it. `None` for bytes that are not UTF-8, for an empty
/// line, for more than one line, and for a line that is not a single plain
/// directory name (a `/`, `.` or `..`), which could lead out of
/// `<data>/editors/`.
#[must_use]
pub fn core_identity(bytes: &[u8]) -> Option<String> {
    let line = std::str::from_utf8(bytes).ok()?.trim();
    let mut components = Path::new(line).components();
    let plain = matches!(components.next(), Some(Component::Normal(_)))
        && components.next().is_none()
        && !line.contains(['/', '\n', '\r']);
    plain.then(|| line.to_owned())
}

/// The version a directory's name is: a decimal number, all ASCII digits,
/// with no sign; `None` for anything else, the empty name and a number too
/// large for a `u64` among them.
#[must_use]
pub fn version_number(name: &OsStr) -> Option<u64> {
    let name = name.to_str()?;
    if name.is_empty() || !name.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    name.parse().ok()
}

/// The directory of the core's versions: `<data>/editors/<core>`.
#[must_use]
pub fn core_dir(data: &Path, core: &str) -> PathBuf {
    data.join(EDITORS).join(core)
}

/// The executables of the core's complete versions, newest first: the
/// `editor` of each entry of [`core_dir`] whose name is a
/// [`version_number`] and which holds one. Nothing when the directory
/// cannot be listed.
#[must_use]
pub fn versions(files: &dyn Files, data: &Path, core: &str) -> Vec<PathBuf> {
    let dir = core_dir(data, core);
    let Ok(names) = files.list(&dir) else {
        return Vec::new();
    };
    let mut numbered: Vec<(u64, PathBuf)> = names
        .iter()
        .filter_map(|name| Some((version_number(name)?, dir.join(name).join(EXECUTABLE))))
        .filter(|(_, editor)| files.exists(editor))
        .collect();
    numbered.sort_by(|a, b| b.cmp(a));
    numbered.into_iter().map(|(_, editor)| editor).collect()
}

/// The candidates of a cold start, in the order they are tried: the
/// newest of `versions` (newest first), the one before it when there is
/// one, and `shipped`.
#[must_use]
pub fn candidates(versions: &[PathBuf], shipped: &Path) -> Vec<PathBuf> {
    versions
        .iter()
        .take(2)
        .cloned()
        .chain(std::iter::once(shipped.to_owned()))
        .collect()
}

/// The record a cold start of the launcher `pid` writes:
/// `<data>/launch/cold-<pid>`. The editor it execs keeps the pid, so no
/// two running cold starts share one.
#[must_use]
pub fn cold_record(data: &Path, pid: Pid) -> PathBuf {
    data.join(LAUNCH).join(format!("cold-{pid}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::{FakeClock, FakeFiles};

    fn env(vars: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
        let vars: Vec<(String, OsString)> = vars
            .iter()
            .map(|(n, v)| ((*n).to_owned(), OsString::from(v)))
            .collect();
        move |name| vars.iter().find(|(n, _)| n == name).map(|(_, v)| v.clone())
    }

    #[test]
    fn data_beats_the_environment_and_xdg_beats_home() {
        let both = [(XDG_DATA_HOME, "/x"), (HOME, "/h")];
        assert_eq!(
            data_dir(Some(Path::new("/given")), env(&both)),
            Some(PathBuf::from("/given"))
        );
        assert_eq!(
            data_dir(None, env(&both)),
            Some(PathBuf::from("/x/leanmacs"))
        );
        assert_eq!(
            data_dir(None, env(&[(HOME, "/h")])),
            Some(PathBuf::from("/h/.local/share/leanmacs"))
        );
        assert_eq!(
            data_dir(None, env(&[(XDG_DATA_HOME, ""), (HOME, "/h")])),
            Some(PathBuf::from("/h/.local/share/leanmacs"))
        );
    }

    #[test]
    fn with_neither_variable_set_and_not_empty_there_is_no_data_directory() {
        assert_eq!(data_dir(None, env(&[])), None);
        assert_eq!(
            data_dir(None, env(&[(XDG_DATA_HOME, ""), (HOME, "")])),
            None
        );
    }

    #[test]
    fn the_core_is_the_one_line_beside_the_default_or_in_its_bundles_resources() {
        assert_eq!(
            core_record(Path::new("/A.app/Contents/MacOS/editor")),
            PathBuf::from("/A.app/Contents/Resources/editor.core")
        );
        assert_eq!(
            core_record(Path::new("/w/packages/.lake/build/bin/editor")),
            PathBuf::from("/w/packages/.lake/build/bin/editor.core")
        );
        assert_eq!(core_identity(b"3f9a0c\n"), Some("3f9a0c".to_owned()));
        assert_eq!(core_identity(b"  3f9a0c \r\n"), Some("3f9a0c".to_owned()));
        for bytes in [
            &b""[..],
            b"\n",
            b"a\nb\n",
            b"a/b",
            b"/a",
            b"..",
            b".",
            b"\xff",
        ] {
            assert_eq!(core_identity(bytes), None, "{bytes:?}");
        }
    }

    #[test]
    fn a_version_is_a_decimal_number_with_no_sign() {
        assert_eq!(version_number(OsStr::new("10")), Some(10));
        assert_eq!(version_number(OsStr::new("007")), Some(7));
        for name in [
            "",
            "+3",
            "-3",
            "1a",
            "staging-1",
            " 1",
            "99999999999999999999999",
        ] {
            assert_eq!(version_number(OsStr::new(name)), None, "{name:?}");
        }
    }

    #[test]
    fn the_versions_of_the_core_are_its_complete_numbered_ones_newest_first() {
        let clock = FakeClock::new();
        let files = FakeFiles::new(&clock)
            .with("/d/editors/c/1/editor", "1")
            .with("/d/editors/c/2/editor", "2")
            .with("/d/editors/c/10/editor", "10")
            .with("/d/editors/c/11/editor.build", "half")
            .with_dir("/d/editors/c/12")
            .with("/d/editors/c/staging-3/editor", "s")
            .with("/d/editors/c/x4/editor", "x")
            .with("/d/editors/staging-5/editor", "s")
            .with("/d/editors/other/99/editor", "o");
        assert_eq!(
            versions(&files, Path::new("/d"), "c"),
            [
                PathBuf::from("/d/editors/c/10/editor"),
                PathBuf::from("/d/editors/c/2/editor"),
                PathBuf::from("/d/editors/c/1/editor"),
            ]
        );
        assert!(versions(&files, Path::new("/d"), "none").is_empty());
        assert!(versions(&files, Path::new("/nowhere"), "c").is_empty());
    }

    #[test]
    fn the_candidates_are_the_newest_the_previous_and_the_shipped_default() {
        let v = |n: &str| PathBuf::from(format!("/d/editors/c/{n}/editor"));
        let shipped = Path::new("/A/editor");
        assert_eq!(
            candidates(&[v("10"), v("2"), v("1")], shipped),
            [v("10"), v("2"), shipped.to_owned()]
        );
        assert_eq!(candidates(&[v("3")], shipped), [v("3"), shipped.to_owned()]);
        assert_eq!(candidates(&[], shipped), [shipped.to_owned()]);
    }

    #[test]
    fn a_cold_record_is_named_for_the_launchers_pid_under_launch() {
        assert_eq!(
            cold_record(Path::new("/d"), Pid(4242)),
            PathBuf::from("/d/launch/cold-4242")
        );
    }
}
