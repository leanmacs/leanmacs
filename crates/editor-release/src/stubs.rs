//! The link stubs a relink of the editor needs where there is no macOS SDK
//! (`docs/design/lean-runtime.md`, "A link on the user's machine,
//! measured"): the app ships them in `Contents/Resources/lean/link-stubs`,
//! and `tools/user-link-check.sh` stages them with the `link-stubs`
//! binary.
//!
//! For each dynamic library the executable loads (`otool -L`), other than
//! `libSystem` and `libc++`, which the Lean toolchain ships a stub and a
//! stand-in for, [`decide`] makes one text stub (`.tbd`, version 4)
//! holding
//!
//! - the library's install name and its current and compatibility
//!   versions, as the executable records them, and
//! - only the symbols the executable imports from it (`nm -m -u`, which
//!   names the library each undefined symbol is bound to), once each, in
//!   byte order.
//!
//! A framework's stub is `<out>/<Name>.framework/<Name>.tbd`, found with
//! `-F <out> -framework <Name>`; a library's is `<out>/<name>.tbd`, its
//! name being its file name up to the first dot, found with `-L <out>
//! -l<name>`. A library the executable loads and imports nothing from
//! still gets its stub, with no `exports`, so a link that names it finds
//! it.
//!
//! It also makes `<out>/platform-version`, one line, `<minos> <sdk>`: the
//! minimum macOS and the SDK version the executable records (`vtool
//! -show-build`, the first of each). A linker with no SDK records the
//! minimum macOS as the SDK version too, and AppKit and other frameworks
//! choose behaviour by the SDK version an executable was linked against,
//! so a relink passes these two on (`-platform_version macos <minos>
//! <sdk>`) and is the same build to them.
//!
//! So the stubs are made from the executable's own import table, by the
//! build that linked it against the SDK, and no file of the SDK is copied.
//! A relink that needs a symbol the executable never imported does not
//! find it: the stubs serve relinking the same compiled code, not new
//! calls into the system.
//!
//! It refuses ([`Refusal`]), before anything is written: a host other than
//! macOS, whose tools these are; a path that is not a file; an executable
//! of several architectures; one `otool -L` lists no library of; an `nm`
//! line that is not an import bound to a library; an import bound to a
//! library the executable does not load; an Objective-C class, metaclass,
//! instance variable or exception type symbol (`_OBJC_…_$_…`), which a
//! text stub lists apart from plain symbols, which the editor imports
//! none of, and so whose form is not written here, untried; and an
//! executable that records no minimum macOS or no SDK version.
//!
//! Programs run through the [`Process`] port and files are reached through
//! the [`Files`] port, so the tests run on the published fakes.

use std::collections::BTreeSet;
use std::fmt;
use std::path::{Path, PathBuf};

use crate::ports::{Files, FilesError, Invocation, Kind, Process, RunError, text};

/// The system the tool runs on, as its binary was built for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Host {
    /// macOS, whose command line tools read a Mach-O.
    Macos,
    /// Any other.
    Other,
}

/// The file that holds the minimum macOS and the SDK version.
pub const PLATFORM_VERSION: &str = "platform-version";

/// The libraries the Lean toolchain ships a stub or a stand-in for, which
/// get no stub here.
const SHIPPED_BY_TOOLCHAIN: [&str; 2] = ["libSystem", "libc++"];

/// Why no stubs were written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// The host is not macOS.
    NotMacos,
    /// No file is at the executable's path.
    NotAFile(PathBuf),
    /// The executable holds more than one architecture, as `lipo` lists
    /// them.
    SeveralArchitectures {
        /// The executable.
        executable: PathBuf,
        /// What `lipo -archs` printed.
        archs: String,
    },
    /// `otool -L` lists no library for the executable.
    NoLibrary(PathBuf),
    /// A line of `nm -m -u` is not an import bound to a library.
    NotAnImport {
        /// The executable.
        executable: PathBuf,
        /// The line.
        line: String,
    },
    /// An Objective-C symbol is imported, which this does not write.
    ObjectiveC {
        /// The symbol.
        symbol: String,
        /// The library it is imported from.
        library: String,
    },
    /// `vtool` reports no minimum macOS or no SDK version.
    NoPlatformVersion(PathBuf),
    /// A symbol is imported from a library `otool -L` does not list.
    Unbound {
        /// The first symbol imported from it.
        symbol: String,
        /// The library's name, as `nm -m` gives it.
        library: String,
    },
    /// A tool could not be run to success.
    Run {
        /// Its command line.
        command: String,
        /// Why.
        error: RunError,
    },
    /// The file system refused a read or a write.
    Files(FilesError),
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotMacos => f.write_str("macOS only: the stubs are read with macOS's own tools"),
            Self::NotAFile(path) => write!(f, "no executable at {}", path.display()),
            Self::SeveralArchitectures { executable, archs } => write!(
                f,
                "{} holds more than one architecture ({archs})",
                executable.display()
            ),
            Self::NoLibrary(path) => write!(f, "otool -L lists no library for {}", path.display()),
            Self::NotAnImport { executable, line } => write!(
                f,
                "an undefined symbol of {} is not of the form nm -m prints for an import bound to a library: {}",
                executable.display(),
                line.trim()
            ),
            Self::ObjectiveC { symbol, library } => write!(
                f,
                "{symbol}, imported from {library}, is an Objective-C symbol, which a text stub lists apart; link-stubs does not write that form"
            ),
            Self::NoPlatformVersion(path) => write!(
                f,
                "{} records no minimum macOS and SDK version",
                path.display()
            ),
            Self::Unbound { symbol, library } => write!(
                f,
                "{symbol} is imported from {library}, which otool -L does not list"
            ),
            Self::Run { command, error } => write!(f, "{command}: {error}"),
            Self::Files(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for Refusal {}

/// The stubs of one executable, decided and not yet written: each file's
/// path under the out directory, and its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stubs {
    /// Each file, its path relative to the out directory, in the order
    /// `otool -L` lists the libraries, then [`PLATFORM_VERSION`].
    pub files: Vec<(PathBuf, String)>,
}

/// A library the executable loads, as `otool -L` lists it.
struct Library {
    install: String,
    compatibility: String,
    current: String,
}

/// An `otool -L` line's library: `<install> (compatibility version <c>,
/// current version <v>)`, after any indent, both versions digits and dots.
fn parse_library(line: &str) -> Option<Library> {
    let body = line.trim_start().strip_suffix(')')?;
    let (install, versions) = body.rsplit_once(" (compatibility version ")?;
    let (compatibility, current) = versions.split_once(", current version ")?;
    let version = |v: &str| v.chars().all(|c| c.is_ascii_digit() || c == '.');
    (version(compatibility) && version(current)).then(|| Library {
        install: install.to_owned(),
        compatibility: compatibility.to_owned(),
        current: current.to_owned(),
    })
}

/// An `nm -m -u` line's import, `(library, symbol)`: `… external <symbol>
/// (from <library>)`, the symbol holding no space.
fn parse_import(line: &str) -> Option<(&str, &str)> {
    let body = line.strip_suffix(')')?;
    body.rmatch_indices(" external ").find_map(|(at, marker)| {
        let (symbol, library) = body[at + marker.len()..].split_once(" (from ")?;
        (!symbol.contains(' ')).then_some((library, symbol))
    })
}

/// The name `nm -m` gives a library, and whether it is a framework: a
/// framework's name, or a library's file name up to its first dot
/// (`libobjc` for `/usr/lib/libobjc.A.dylib`).
fn short_name(install: &str) -> (&str, bool) {
    if let Some(at) = install.rfind(".framework/")
        && let Some(slash) = install[..at].rfind('/')
    {
        return (&install[slash + 1..at], true);
    }
    let file = install.rsplit('/').next().unwrap_or(install);
    (file.split('.').next().unwrap_or(file), false)
}

/// Whether `symbol` is an Objective-C class, metaclass, instance variable
/// or exception type symbol: `_OBJC_`, capitals, `_$_`.
fn is_objective_c(symbol: &str) -> bool {
    symbol
        .strip_prefix("_OBJC_")
        .map(|rest| rest.trim_start_matches(|c: char| c.is_ascii_uppercase()))
        .is_some_and(|rest| rest.starts_with("_$_"))
}

/// The first value `vtool -show-build` reports for `key`.
fn first_value<'a>(report: &'a str, key: &str) -> Option<&'a str> {
    report.lines().find_map(|line| {
        let mut words = line.split_whitespace();
        if words.next() == Some(key) {
            words.next()
        } else {
            None
        }
    })
}

/// The text of one stub.
fn stub_text(target: &str, library: &Library, symbols: &BTreeSet<&str>) -> String {
    let mut text = format!(
        "--- !tapi-tbd\n\
         tbd-version:     4\n\
         targets:         [ {target} ]\n\
         install-name:    '{}'\n\
         current-version: {}\n\
         compatibility-version: {}\n",
        library.install, library.current, library.compatibility
    );
    if !symbols.is_empty() {
        let quoted: Vec<String> = symbols.iter().map(|s| format!("'{s}'")).collect();
        text.push_str("exports:\n");
        text.push_str(&format!("  - targets:         [ {target} ]\n"));
        text.push_str(&format!("    symbols:         [ {} ]\n", quoted.join(", ")));
    }
    text.push_str("...\n");
    text
}

/// Runs one tool on the executable and reads what it prints.
fn tool(
    process: &mut impl Process,
    program: &str,
    flags: &[&str],
    executable: &Path,
) -> Result<String, Refusal> {
    let invocation = Invocation::new(program)
        .args(flags)
        .arg(executable)
        .captured();
    text(process, &invocation).map_err(|error| Refusal::Run {
        command: invocation.to_string(),
        error,
    })
}

/// Decides the stubs of the executable at `executable` from what the
/// command line tools report of it, writing nothing.
///
/// # Errors
///
/// Each [`Refusal`], as the module says.
pub fn decide(
    process: &mut impl Process,
    files: &impl Files,
    host: Host,
    executable: &Path,
) -> Result<Stubs, Refusal> {
    if host != Host::Macos {
        return Err(Refusal::NotMacos);
    }
    if !matches!(
        files.kind(executable).map_err(Refusal::Files)?,
        Kind::File { .. }
    ) {
        return Err(Refusal::NotAFile(executable.to_owned()));
    }
    let archs = tool(process, "lipo", &["-archs"], executable)?;
    let archs = archs.trim();
    if archs.contains(char::is_whitespace) {
        return Err(Refusal::SeveralArchitectures {
            executable: executable.to_owned(),
            archs: archs.to_owned(),
        });
    }
    let target = format!("{archs}-macos");

    let listing = tool(process, "otool", &["-L"], executable)?;
    let libraries: Vec<Library> = listing.lines().filter_map(parse_library).collect();
    if libraries.is_empty() {
        return Err(Refusal::NoLibrary(executable.to_owned()));
    }

    let undefined = tool(process, "nm", &["-m", "-u"], executable)?;
    let mut imports = Vec::new();
    for line in undefined.lines() {
        let import = parse_import(line).ok_or_else(|| Refusal::NotAnImport {
            executable: executable.to_owned(),
            line: line.to_owned(),
        })?;
        imports.push(import);
    }

    let mut stubs = Vec::new();
    for library in &libraries {
        let (name, framework) = short_name(&library.install);
        if SHIPPED_BY_TOOLCHAIN.contains(&name) {
            continue;
        }
        let symbols: BTreeSet<&str> = imports
            .iter()
            .filter(|(from, _)| *from == name)
            .map(|(_, symbol)| *symbol)
            .collect();
        if let Some(symbol) = symbols.iter().find(|s| is_objective_c(s)) {
            return Err(Refusal::ObjectiveC {
                symbol: (*symbol).to_owned(),
                library: name.to_owned(),
            });
        }
        let path = if framework {
            PathBuf::from(format!("{name}.framework")).join(format!("{name}.tbd"))
        } else {
            PathBuf::from(format!("{name}.tbd"))
        };
        stubs.push((path, stub_text(&target, library, &symbols)));
    }

    let report = tool(process, "vtool", &["-show-build"], executable)?;
    let (Some(minos), Some(sdk)) = (first_value(&report, "minos"), first_value(&report, "sdk"))
    else {
        return Err(Refusal::NoPlatformVersion(executable.to_owned()));
    };
    stubs.push((PathBuf::from(PLATFORM_VERSION), format!("{minos} {sdk}\n")));

    // Every import is bound to a library the executable loads: the first
    // library by name that is not, with the first symbol imported from it.
    let loaded: BTreeSet<&str> = libraries.iter().map(|l| short_name(&l.install).0).collect();
    let unbound: BTreeSet<&str> = imports
        .iter()
        .map(|(from, _)| *from)
        .filter(|from| !loaded.contains(from))
        .collect();
    if let Some(library) = unbound.first()
        && let Some((_, symbol)) = imports.iter().find(|(from, _)| from == library)
    {
        return Err(Refusal::Unbound {
            symbol: (*symbol).to_owned(),
            library: (*library).to_owned(),
        });
    }
    Ok(Stubs { files: stubs })
}

/// Writes `stubs` into the directory `out`, making it and each framework's
/// directory.
///
/// # Errors
///
/// The first write the file system refuses.
pub fn write(files: &mut impl Files, out: &Path, stubs: &Stubs) -> Result<(), FilesError> {
    files.make_dir(out)?;
    for (path, text) in &stubs.files {
        let path = out.join(path);
        if let Some(dir) = path.parent() {
            files.make_dir(dir)?;
        }
        files.write(&path, text.as_bytes(), false)?;
    }
    Ok(())
}

/// Decides the stubs of `executable` and writes them into `out`: nothing is
/// written unless every check passes.
///
/// # Errors
///
/// Each [`Refusal`], as the module says.
pub fn link_stubs(
    process: &mut impl Process,
    files: &mut impl Files,
    host: Host,
    executable: &Path,
    out: &Path,
) -> Result<(), Refusal> {
    let stubs = decide(process, files, host, executable)?;
    write(files, out, &stubs).map_err(Refusal::Files)
}

#[cfg(test)]
mod tests;
