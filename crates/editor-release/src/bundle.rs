//! The app bundle's layout: what `stage-bundle` copies into a directory
//! laid out as the app bundle will be, for the `editorApp` facet (`mise run
//! app`), the gate's `bundle-test` and `mise run module-bench`
//! (`docs/design/lean-runtime.md`, "Build"; `docs/dev-practices/
//! headless-mode.md`, "From an app bundle").
//!
//! ```text
//! stage-bundle [--launcher <file>] <bundle> <executable> <sysroot> <shipped list>
//! stage-bundle (--roots <root>,... | --closure <file>) [--launcher <file>] \
//!   <bundle> <executable> <sysroot> <package olean dirs> <kind>...
//! ```
//!
//! [`Command::parse`] reads those two command lines, options first; anything
//! else is the [`Usage`]. Either way [`stage`] makes `<bundle>/Contents/
//! MacOS/` and copies the executable there as `editor`, a regular file with
//! its executable bit even when the executable's path is a link, with the
//! record of the core's identity in `Contents/Resources/editor.core` when
//! the build wrote one (`<executable>.core`), and with `--launcher` the
//! app's launcher there as `leanmacs` (`crates/editor-launch-std`; the
//! bundle's `CFBundleExecutable`, which starts `editor`). What to copy is
//! what it is given.
//!
//! **The bundle as shipped** ([`Form::Shipped`]): everything a user's
//! package-set build needs, so one builds from the app alone
//! (`docs/design/packages.md`, "User package sets"), under
//! `Contents/Resources`:
//!
//! - `lean/toolchain/`: the Lean toolchain `<sysroot>`, whole, but its
//!   `exposed/` (mise's links) and any name starting with `.`: each
//!   top-level entry copied as a tree, directories made again, files
//!   cloned with their executable bits, and links copied as links;
//! - each file the shipped list names, at its place under `lean/`: the
//!   list is what `lake -d <set dir> query :editorShipped` prints
//!   (`lean/lakefile.lean`): one line `file<TAB><source><TAB><place>` a
//!   file, and one line `oleans<TAB><place>` for each `.olean` directory,
//!   in the order the editor searches them. A source that is a directory is
//!   copied whole;
//! - `editor.oleans`: those directories, one a line, relative to
//!   `Contents/Resources` (`lean/Editor/ModuleLookup.lean`, "The bundle's
//!   record");
//! - `editor.build`: the executable's `<executable>.build` without its
//!   `LEAN_CC=` line, every other line in order, so a build the app runs
//!   compiles and links with the bundled toolchain's own `clang`
//!   (`lean/Editor/PackageSet/Running.lean`); none when the build wrote
//!   none;
//! - on macOS, `lean/link-stubs/`: the link stubs [`crate::stubs`] writes
//!   from the executable, which a link with the toolchain's own linker
//!   needs for the system's frameworks (`linkAsEditor` in
//!   `lean/lakefile.lean`). On another host no stub is written and no
//!   program runs.
//!
//! The list is read and checked whole before anything is copied: a line of
//! a kind other than `file`, `oleans` or none, a `file` line whose place
//! would rename its source, and a list with no `oleans` line are refused
//! ([`Refusal`]), and so are the stubs' refusals.
//!
//! **Module files alone** ([`Form::Modules`], `mise run module-bench`'s
//! experiments on what config may import; `docs/design/lean-runtime.md`,
//! "What config may import, measured"): it copies module files, keeping
//! their paths relative to the directory they are in, from the toolchain's
//! `<sysroot>/lib/lean` into `Contents/Resources/lean/toolchain/lib/lean`,
//! so that directory is a sysroot, and from the packages' `.olean`
//! directories into `Contents/Resources/lean/editor`, one directory for
//! them, which it names in `Contents/Resources/editor.oleans`, so the
//! bundle's editor finds its modules there.
//!
//! `<package olean dirs>` is one directory, or several joined with `:`, as
//! the editor reads its own `.olean` directory argument; an empty part
//! names none. A module is copied from the first of them that holds it.
//! Only files of the given kinds are copied, a file being of a kind when
//! its name ends in `.<kind>` (`X.olean` is `olean`, `X.olean.server` is
//! not); a kind a module has no file of is skipped. With `--roots`, whole
//! top-level directories with their root files (`Init.olean` and
//! `Init/**` for `Init`), of the toolchain's roots it names, and `Editor`
//! from each package directory. With `--closure <file>`, only the modules
//! the file names, one module name a line (what `config-test
//! bench-modules` prints; blank lines skipped), each taken from the
//! toolchain's directory or the first package directory that holds its
//! `.olean`; a module in none of them is refused before anything is
//! copied.
//!
//! Files are reached through the [`Files`] port and the stubs' tools run
//! through the [`Process`] port, so the tests run on the published fakes.

use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::path::{Path, PathBuf};

use crate::ports::{EntryKind, Files, FilesError, Kind, Process};
pub use crate::stubs::Host;
use crate::stubs::{self, Stubs};

/// One `stage-bundle` command line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    /// The launcher to ship as `Contents/MacOS/leanmacs`, if any.
    pub launcher: Option<PathBuf>,
    /// The bundle's directory.
    pub bundle: PathBuf,
    /// The editor executable.
    pub executable: PathBuf,
    /// The Lean toolchain's directory.
    pub sysroot: PathBuf,
    /// Which bundle.
    pub form: Form,
}

/// The two bundles `stage-bundle` lays out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Form {
    /// The bundle as shipped, from the shipped list.
    Shipped {
        /// The list `editorShipped` printed.
        list: PathBuf,
    },
    /// Module files alone.
    Modules {
        /// Which modules.
        which: Which,
        /// The package directories, in the order they are searched.
        packages: Vec<PathBuf>,
        /// The kinds of file copied.
        kinds: Vec<String>,
    },
}

/// Which modules [`Form::Modules`] copies.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Which {
    /// Whole top-level directories of the toolchain, and `Editor`.
    Roots(Vec<String>),
    /// The modules a file names, one a line.
    Closure(PathBuf),
}

/// A command line `stage-bundle` does not take.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Usage;

/// The usage, as the binary prints it.
pub const USAGE: &str = "usage: stage-bundle [--launcher <file>] <bundle dir> <executable> <sysroot> <shipped list>\n       stage-bundle (--roots <root>,... | --closure <file>) [--launcher <file>] <bundle dir> <executable> <sysroot> <package olean dirs> <kind>...";

impl Command {
    /// Reads a command line, the program's name left out: the options
    /// `--launcher`, `--roots` and `--closure`, each with its value, then
    /// the paths.
    ///
    /// # Errors
    ///
    /// [`Usage`] for any other command line: an unknown option, an option
    /// with no value, `--roots` and `--closure` together, a wrong number of
    /// paths, no kind, or a package argument that names no directory.
    pub fn parse(args: &[OsString]) -> Result<Self, Usage> {
        let mut launcher = None;
        let mut roots = None;
        let mut closure = None;
        let mut rest = args;
        while let [option, tail @ ..] = rest {
            let slot = match option.to_str() {
                Some("--launcher") => &mut launcher,
                Some("--roots") => &mut roots,
                Some("--closure") => &mut closure,
                _ if option.as_encoded_bytes().starts_with(b"--") => return Err(Usage),
                _ => break,
            };
            let [value, tail @ ..] = tail else {
                return Err(Usage);
            };
            *slot = Some(value.clone());
            rest = tail;
        }
        let which = match (roots, closure) {
            (None, None) => None,
            (Some(roots), None) => {
                let roots = roots.to_str().ok_or(Usage)?;
                Some(Which::Roots(
                    roots
                        .split(',')
                        .filter(|r| !r.is_empty())
                        .map(str::to_owned)
                        .collect(),
                ))
            }
            (None, Some(closure)) => Some(Which::Closure(PathBuf::from(closure))),
            (Some(_), Some(_)) => return Err(Usage),
        };
        let (form, paths) = match which {
            None => {
                let [bundle, executable, sysroot, list] = rest else {
                    return Err(Usage);
                };
                (
                    Form::Shipped {
                        list: PathBuf::from(list),
                    },
                    [bundle, executable, sysroot],
                )
            }
            Some(which) => {
                let [bundle, executable, sysroot, packages, kinds @ ..] = rest else {
                    return Err(Usage);
                };
                let packages: Vec<PathBuf> = packages
                    .to_str()
                    .ok_or(Usage)?
                    .split(':')
                    .filter(|p| !p.is_empty())
                    .map(PathBuf::from)
                    .collect();
                let kinds = kinds
                    .iter()
                    .map(|k| k.to_str().map(str::to_owned).ok_or(Usage))
                    .collect::<Result<Vec<_>, _>>()?;
                if packages.is_empty() || kinds.is_empty() {
                    return Err(Usage);
                }
                (
                    Form::Modules {
                        which,
                        packages,
                        kinds,
                    },
                    [bundle, executable, sysroot],
                )
            }
        };
        let [bundle, executable, sysroot] = paths.map(PathBuf::from);
        Ok(Self {
            launcher: launcher.map(PathBuf::from),
            bundle,
            executable,
            sysroot,
            form,
        })
    }

    /// This command with every path it names passed through `resolve`, as
    /// the binary makes each absolute against its working directory.
    ///
    /// # Errors
    ///
    /// The first error `resolve` returns.
    pub fn resolved<E>(
        self,
        mut resolve: impl FnMut(&Path) -> Result<PathBuf, E>,
    ) -> Result<Self, E> {
        let form = match self.form {
            Form::Shipped { list } => Form::Shipped {
                list: resolve(&list)?,
            },
            Form::Modules {
                which,
                packages,
                kinds,
            } => Form::Modules {
                which: match which {
                    Which::Closure(file) => Which::Closure(resolve(&file)?),
                    roots @ Which::Roots(_) => roots,
                },
                packages: packages
                    .iter()
                    .map(|p| resolve(p))
                    .collect::<Result<_, _>>()?,
                kinds,
            },
        };
        Ok(Self {
            launcher: self.launcher.as_deref().map(&mut resolve).transpose()?,
            bundle: resolve(&self.bundle)?,
            executable: resolve(&self.executable)?,
            sysroot: resolve(&self.sysroot)?,
            form,
        })
    }
}

/// Why nothing was staged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// No file is at a path to copy as one: the executable or the
    /// launcher.
    NotAFile(PathBuf),
    /// No file or directory is at a shipped line's source.
    NoSource(PathBuf),
    /// A list or a closure is not UTF-8 text.
    NotText(PathBuf),
    /// The shipped list holds a line of a kind other than `file`,
    /// `oleans` or none.
    UnknownKind {
        /// The list.
        list: PathBuf,
        /// The line's kind.
        kind: String,
    },
    /// A `file` line's place would rename its source.
    Renamed {
        /// The source.
        source: String,
        /// The place.
        place: String,
    },
    /// The shipped list has no `oleans` line.
    NoOleans(PathBuf),
    /// A module of the closure is in no directory searched.
    NotInAnyDirectory {
        /// The module.
        module: String,
        /// The toolchain's directory of module files.
        toolchain: PathBuf,
        /// The package directories.
        packages: Vec<PathBuf>,
    },
    /// The link stubs were refused.
    Stubs(stubs::Refusal),
    /// The file system refused a read or a write.
    Files(FilesError),
}

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAFile(path) => write!(f, "no file at {}", path.display()),
            Self::NoSource(path) => write!(f, "nothing to copy at {}", path.display()),
            Self::NotText(path) => write!(f, "{} is not UTF-8 text", path.display()),
            Self::UnknownKind { list, kind } => write!(
                f,
                "{} holds a line of kind {kind}, which is neither file nor oleans",
                list.display()
            ),
            Self::Renamed { source, place } => {
                write!(f, "{source} would be renamed to {place}")
            }
            Self::NoOleans(list) => write!(f, "{} names no .olean directory", list.display()),
            Self::NotInAnyDirectory {
                module,
                toolchain,
                packages,
            } => {
                let packages: Vec<String> =
                    packages.iter().map(|p| p.display().to_string()).collect();
                write!(
                    f,
                    "no .olean file for {module} in {} or {}",
                    toolchain.display(),
                    packages.join(" ")
                )
            }
            Self::Stubs(refusal) => write!(f, "{refusal}"),
            Self::Files(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for Refusal {}

impl From<FilesError> for Refusal {
    fn from(error: FilesError) -> Self {
        Self::Files(error)
    }
}

/// One step of laying the bundle out, decided before any is taken.
#[derive(Debug)]
enum Step {
    /// Make a directory and those above it.
    MakeDir(PathBuf),
    /// Copy a file, a link followed, making the directory it goes in.
    Copy { from: PathBuf, to: PathBuf },
    /// Copy an entry as `cp -R` does: a directory as a tree, a link as a
    /// link.
    Tree {
        from: PathBuf,
        to: PathBuf,
        kind: EntryKind,
    },
    /// Write a file.
    Write { path: PathBuf, bytes: Vec<u8> },
    /// Write the link stubs into a directory.
    Stubs { out: PathBuf, stubs: Stubs },
}

/// `path` with `suffix` added to its file name: `editor` and `.core` give
/// `editor.core`.
fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

/// Whether something is at `path`, a link followed, as `test -e`.
fn exists(files: &impl Files, path: &Path) -> Result<bool, FilesError> {
    Ok(files.kind(path)? != Kind::Nothing)
}

/// Reads `path` as UTF-8 text.
fn read_text(files: &impl Files, path: &Path) -> Result<String, Refusal> {
    String::from_utf8(files.read(path)?).map_err(|_| Refusal::NotText(path.to_owned()))
}

/// The bundle's `Contents/MacOS` and `Contents/Resources`.
fn contents(bundle: &Path) -> (PathBuf, PathBuf) {
    let contents = bundle.join("Contents");
    (contents.join("MacOS"), contents.join("Resources"))
}

/// The steps both forms take: the editor, its core record, the launcher.
fn common_steps(command: &Command, files: &impl Files) -> Result<Vec<Step>, Refusal> {
    let (macos, resources) = contents(&command.bundle);
    let mut steps = vec![
        Step::MakeDir(macos.clone()),
        Step::MakeDir(resources.clone()),
    ];
    let is_file = |path: &Path| -> Result<bool, Refusal> {
        Ok(matches!(files.kind(path)?, Kind::File { .. }))
    };
    if !is_file(&command.executable)? {
        return Err(Refusal::NotAFile(command.executable.clone()));
    }
    steps.push(Step::Copy {
        from: command.executable.clone(),
        to: macos.join("editor"),
    });
    // The core's identity of the shipped default, in the bundle's
    // resources, where the launcher reads it to choose a per-user editor
    // (`docs/design/packages.md`, "User package sets"): `codesign` refuses
    // a file in `Contents/MacOS` that is not code. An executable the
    // package-set build did not link has none.
    let core = with_suffix(&command.executable, ".core");
    if exists(files, &core)? {
        steps.push(Step::Copy {
            from: core,
            to: resources.join("editor.core"),
        });
    }
    if let Some(launcher) = &command.launcher {
        if !is_file(launcher)? {
            return Err(Refusal::NotAFile(launcher.clone()));
        }
        steps.push(Step::Copy {
            from: launcher.clone(),
            to: macos.join("leanmacs"),
        });
    }
    Ok(steps)
}

/// A shipped list's lines, read and checked whole: the `file` lines'
/// sources and places, and the `oleans` lines' places, in order.
struct Shipped {
    files: Vec<(String, String)>,
    oleans: Vec<String>,
}

fn read_shipped(text: &str, list: &Path) -> Result<Shipped, Refusal> {
    let lines: Vec<Vec<&str>> = text.lines().map(|l| l.split('\t').collect()).collect();
    let field = |fields: &[&str], at: usize| fields.get(at).copied().unwrap_or("").to_owned();
    for fields in &lines {
        if !matches!(fields[0], "file" | "oleans" | "") {
            return Err(Refusal::UnknownKind {
                list: list.to_owned(),
                kind: fields[0].to_owned(),
            });
        }
    }
    let mut shipped = Shipped {
        files: Vec::new(),
        oleans: Vec::new(),
    };
    for fields in &lines {
        match fields[0] {
            "file" => {
                let (source, place) = (field(fields, 1), field(fields, 2));
                let name = |path: &str| path.rsplit('/').next().unwrap_or("").to_owned();
                if name(&source) != name(&place) {
                    return Err(Refusal::Renamed { source, place });
                }
                shipped.files.push((source, place));
            }
            "oleans" => shipped.oleans.push(field(fields, 1)),
            _ => {}
        }
    }
    if shipped.oleans.is_empty() {
        return Err(Refusal::NoOleans(list.to_owned()));
    }
    Ok(shipped)
}

/// `<executable>.build` without its `LEAN_CC=` line, every other line in
/// order, each ended by a newline.
fn shipped_build_record(record: &[u8]) -> Vec<u8> {
    let mut kept = Vec::new();
    let mut lines: Vec<&[u8]> = record.split(|b| *b == b'\n').collect();
    if record.ends_with(b"\n") || record.is_empty() {
        lines.pop();
    }
    for line in lines.into_iter().filter(|l| !l.starts_with(b"LEAN_CC=")) {
        kept.extend_from_slice(line);
        kept.push(b'\n');
    }
    kept
}

/// The steps of the bundle as shipped.
fn shipped_steps(
    command: &Command,
    list: &Path,
    host: Host,
    files: &impl Files,
    process: &mut impl Process,
) -> Result<Vec<Step>, Refusal> {
    let mut steps = common_steps(command, files)?;
    let (_, resources) = contents(&command.bundle);
    let lean = resources.join("lean");
    let shipped = read_shipped(&read_text(files, list)?, list)?;

    // The toolchain, whole, but mise's links to its executables, and the
    // names a shell's `*` leaves out.
    let toolchain = lean.join("toolchain");
    steps.push(Step::MakeDir(toolchain.clone()));
    for entry in files.entries(&command.sysroot)? {
        let hidden = entry.name.as_encoded_bytes().starts_with(b".");
        if hidden || entry.name == "exposed" {
            continue;
        }
        steps.push(Step::Tree {
            from: command.sysroot.join(&entry.name),
            to: toolchain.join(&entry.name),
            kind: entry.kind,
        });
    }

    let mut oleans = shipped.oleans.join("\n");
    oleans.push('\n');
    steps.push(Step::Write {
        path: resources.join("editor.oleans"),
        bytes: oleans.into_bytes(),
    });

    for (source, place) in &shipped.files {
        let from = PathBuf::from(source);
        let kind = match files.kind(&from)? {
            Kind::File { executable } => EntryKind::File { executable },
            Kind::Directory => EntryKind::Directory,
            Kind::Nothing | Kind::Other => return Err(Refusal::NoSource(from)),
        };
        let to = lean.join(place);
        if let Some(dir) = to.parent() {
            steps.push(Step::MakeDir(dir.to_owned()));
        }
        steps.push(Step::Tree { from, to, kind });
    }

    let record = with_suffix(&command.executable, ".build");
    if exists(files, &record)? {
        steps.push(Step::Write {
            path: resources.join("editor.build"),
            bytes: shipped_build_record(&files.read(&record)?),
        });
    }
    if host == Host::Macos {
        let stubs =
            stubs::decide(process, files, host, &command.executable).map_err(Refusal::Stubs)?;
        steps.push(Step::Stubs {
            out: lean.join("link-stubs"),
            stubs,
        });
    }
    Ok(steps)
}

/// The module name of a file named `name` when it is of one of `kinds`:
/// the name without its `.<kind>` ending.
fn of_kinds(name: &OsStr, kinds: &[String]) -> Option<String> {
    let name = name.to_str()?;
    kinds.iter().find_map(|kind| {
        let module = name.strip_suffix(kind.as_str())?.strip_suffix('.')?;
        (!module.is_empty()).then(|| module.to_owned())
    })
}

/// The files of `kinds` that make up the top-level module `root` in `dir`,
/// each relative to `dir` with its module's path: its root file and every
/// regular file under its directory, links not followed, as `find -type f`.
fn root_files(
    files: &impl Files,
    dir: &Path,
    root: &str,
    kinds: &[String],
) -> Result<Vec<(PathBuf, PathBuf)>, FilesError> {
    let mut found = Vec::new();
    for kind in kinds {
        let rel = PathBuf::from(format!("{root}.{kind}"));
        if exists(files, &dir.join(&rel))? {
            found.push((rel, PathBuf::from(root)));
        }
    }
    if files.kind(&dir.join(root))? == Kind::Directory {
        let mut pending = vec![PathBuf::from(root)];
        while let Some(rel_dir) = pending.pop() {
            for entry in files.entries(&dir.join(&rel_dir))? {
                let rel = rel_dir.join(&entry.name);
                match entry.kind {
                    EntryKind::Directory => pending.push(rel),
                    EntryKind::File { .. } => {
                        if let Some(module) = of_kinds(&entry.name, kinds) {
                            found.push((rel, rel_dir.join(module)));
                        }
                    }
                    EntryKind::Link | EntryKind::Other => {}
                }
            }
        }
    }
    Ok(found)
}

/// Where a module of the closure comes from: the directory that holds it,
/// and the staged directory it goes into.
fn closure_source<'a>(
    files: &impl Files,
    olean: &str,
    toolchain: &'a Path,
    staged_toolchain: &'a Path,
    packages: &'a [PathBuf],
    staged_editor: &'a Path,
) -> Result<Option<(&'a Path, &'a Path)>, FilesError> {
    if exists(files, &toolchain.join(olean))? {
        return Ok(Some((toolchain, staged_toolchain)));
    }
    for package in packages {
        if exists(files, &package.join(olean))? {
            return Ok(Some((package, staged_editor)));
        }
    }
    Ok(None)
}

/// The steps of module files alone.
fn module_steps(
    command: &Command,
    which: &Which,
    packages: &[PathBuf],
    kinds: &[String],
    files: &impl Files,
) -> Result<Vec<Step>, Refusal> {
    let mut steps = common_steps(command, files)?;
    let (_, resources) = contents(&command.bundle);
    let toolchain = command.sysroot.join("lib").join("lean");
    let staged_toolchain = resources
        .join("lean")
        .join("toolchain")
        .join("lib")
        .join("lean");
    let staged_editor = resources.join("lean").join("editor");
    steps.push(Step::MakeDir(staged_toolchain.clone()));
    steps.push(Step::MakeDir(staged_editor.clone()));
    // The bundle's record of its one `.olean` directory, which its editor
    // searches (`lean/Editor/ModuleLookup.lean`, "The bundle's record").
    steps.push(Step::Write {
        path: resources.join("editor.oleans"),
        bytes: b"lean/editor\n".to_vec(),
    });
    let copy = |steps: &mut Vec<Step>, from: &Path, to: &Path, rel: &Path| {
        steps.push(Step::Copy {
            from: from.join(rel),
            to: to.join(rel),
        });
    };
    match which {
        Which::Roots(roots) => {
            for root in roots {
                for (rel, _) in root_files(files, &toolchain, root, kinds)? {
                    copy(&mut steps, &toolchain, &staged_toolchain, &rel);
                }
            }
            // A module is copied from the first package directory that
            // holds it.
            let mut taken = BTreeSet::new();
            for package in packages {
                let found = root_files(files, package, "Editor", kinds)?;
                for (rel, _) in found.iter().filter(|(_, module)| !taken.contains(module)) {
                    copy(&mut steps, package, &staged_editor, rel);
                }
                taken.extend(found.into_iter().map(|(_, module)| module));
            }
        }
        Which::Closure(closure) => {
            for module in read_text(files, closure)?.lines().filter(|m| !m.is_empty()) {
                let path = module.replace('.', "/");
                let source = closure_source(
                    files,
                    &format!("{path}.olean"),
                    &toolchain,
                    &staged_toolchain,
                    packages,
                    &staged_editor,
                )?;
                let Some((from, to)) = source else {
                    return Err(Refusal::NotInAnyDirectory {
                        module: module.to_owned(),
                        toolchain,
                        packages: packages.to_vec(),
                    });
                };
                for kind in kinds {
                    let rel = PathBuf::from(format!("{path}.{kind}"));
                    if exists(files, &from.join(&rel))? {
                        copy(&mut steps, from, to, &rel);
                    }
                }
            }
        }
    }
    Ok(steps)
}

/// Copies the entry `from`, of kind `kind`, to `to` as `cp -R` does: a
/// directory as a tree, a file cloned with its executable bit, a link as a
/// link.
fn copy_entry(
    files: &mut impl Files,
    from: &Path,
    to: &Path,
    kind: EntryKind,
) -> Result<(), FilesError> {
    match kind {
        EntryKind::Directory => {
            files.make_dir(to)?;
            for entry in files.entries(from)? {
                copy_entry(
                    files,
                    &from.join(&entry.name),
                    &to.join(&entry.name),
                    entry.kind,
                )?;
            }
            Ok(())
        }
        EntryKind::File { .. } => files.copy(from, to),
        EntryKind::Link => {
            let target = files.read_link(from)?;
            files.symlink(&target, to)
        }
        EntryKind::Other => Err(FilesError::new(
            from,
            "neither a file, a directory nor a link, so not copied",
        )),
    }
}

fn take(files: &mut impl Files, step: Step) -> Result<(), FilesError> {
    match step {
        Step::MakeDir(dir) => files.make_dir(&dir),
        Step::Copy { from, to } => {
            if let Some(dir) = to.parent() {
                files.make_dir(dir)?;
            }
            files.copy(&from, &to)
        }
        Step::Tree { from, to, kind } => copy_entry(files, &from, &to, kind),
        Step::Write { path, bytes } => files.write(&path, &bytes, false),
        Step::Stubs { out, stubs } => stubs::write(files, &out, &stubs),
    }
}

/// Lays the bundle `command` names out, on `host`: every check is made and
/// every list read before anything is written.
///
/// # Errors
///
/// Each [`Refusal`], as the module says; and the first write the file
/// system refuses.
pub fn stage(
    command: &Command,
    host: Host,
    files: &mut impl Files,
    process: &mut impl Process,
) -> Result<(), Refusal> {
    let steps = match &command.form {
        Form::Shipped { list } => shipped_steps(command, list, host, files, process)?,
        Form::Modules {
            which,
            packages,
            kinds,
        } => module_steps(command, which, packages, kinds, files)?,
    };
    for step in steps {
        take(files, step)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
