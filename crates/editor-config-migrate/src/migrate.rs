//! The conversion of a config directory from the old form to `init.lean`
//! and `Config/<Name>.lean` ([`convert`]).
//!
//! What it does, to the `.lean` files directly in the directory (regular
//! files, hidden ones left out as a shell's `*` leaves them), in the byte
//! order of their names:
//!
//! - The files are cut in two at the first file that must stay with the
//!   ones after it, the root's first file: the first file that defines
//!   `setup` or declares something `private` ([`crate::lines`]). With
//!   `setup` defined in the last file and nothing private before it, as
//!   most configs are, that is the last file.
//! - Each file before it is moved to `Config/<Name>.lean`, `<Name>` being
//!   its module name ([`crate::lines::module_name`]). It gets a header
//!   before its text: `import Editor`, an import of the file before it,
//!   and `open Editor`. An import brings what the imported file imports, so
//!   each file still sees every file before it.
//! - The root's first file and every file after it become `init.lean`, in
//!   order, under one header that imports the last file moved to
//!   `Config/`. When they are several, each is preceded by `-- From
//!   <file>:`, and each but the last is put in a `section` of its own, so
//!   what it opens ends where it ended in the old form, at the end of the
//!   file. The root is written as `init.lean.new` and renamed into place.
//!
//! Why the cut. The editor runs the `setup` that `init.lean` itself
//! defines, and the old form ran the `setup` of whichever file defined it;
//! a declaration named `setup` in an imported module could not be defined
//! again in the root. So the file that defines `setup` goes in the root,
//! with the files after it, which may name what it declares. And a
//! `private` declaration is visible in its own module alone, while the old
//! form's files were one module, so a file that declares one stays with
//! the files after it too. When no file is seen to define `setup`, it
//! cannot tell where `setup` is, and every file becomes part of
//! `init.lean`: that always loads.
//!
//! It refuses ([`Refusal`]), and changes nothing, since every check is made
//! before anything moves: a directory that is not there, and one that
//! already holds an entry named exactly `init.lean`; a file that already
//! starts with a header, which it names (a root spelt otherwise, such as
//! `Init.lean`, is one); a file that would move to `Config/` whose name
//! gives no module name, two such files that give one, and a
//! `Config/<Name>.lean` that is already there; and a file that would go in
//! `init.lean` before another and leaves a namespace, a section or a
//! `mutual` block open at its end, or closes one it did not open, which it
//! names. A directory with no `.lean` file directly in it has nothing to
//! convert ([`Outcome::NothingToConvert`]).
//!
//! What moved where, and why the root's files were kept together, is the
//! [`Conversion`], whose [`Outcome::lines`] are what the binary prints.

use std::collections::BTreeSet;
use std::ffi::OsString;
use std::fmt::Write as _;
use std::path::Path;

use crate::lines::{self, NoModule};
use crate::ports::{Files, FilesError, Kind};

/// Why the root's files were kept together in `init.lean`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Together {
    /// The first of them defines `setup` or declares something private.
    SetupOrPrivate,
    /// No line of any file was seen to define `setup`.
    NoSetupSeen,
}

/// What a conversion did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conversion {
    /// Each file moved to `Config/`, with its module's name, in order.
    pub moves: Vec<(String, String)>,
    /// The files that became `init.lean`, in order.
    pub merged: Vec<String>,
    /// Why they were kept together, when they are several.
    pub together: Option<Together>,
}

/// What [`convert`] found to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The directory holds no `.lean` file directly in it.
    NothingToConvert,
    /// It was converted.
    Converted(Conversion),
}

/// The lines the binary prints, `config-migrate: …`, naming the directory
/// as `dir`, the way the user gave it.
impl Outcome {
    /// The lines that say what was done.
    pub fn lines(&self, dir: &str) -> Vec<String> {
        let Self::Converted(conversion) = self else {
            return vec![format!(
                "config-migrate: {dir} holds no .lean file directly in it: there is nothing to convert"
            )];
        };
        let mut lines: Vec<String> = conversion
            .moves
            .iter()
            .map(|(file, module)| format!("config-migrate: moved {file} to Config/{module}.lean"))
            .collect();
        let merged = conversion.merged.join(" ");
        lines.push(match conversion.together {
            Some(together) => {
                let reason = match together {
                    Together::SetupOrPrivate => "the first of them defines setup or declares something private, and the editor runs the setup that init.lean itself defines",
                    Together::NoSetupSeen => "no line of any file was seen to define setup, so they are kept together",
                };
                format!("config-migrate: put {merged} in init.lean, in that order: {reason}")
            }
            None => format!("config-migrate: moved {merged} to init.lean"),
        });
        lines.push(format!("config-migrate: converted {dir}"));
        lines
    }
}

/// Why a directory was left as it was.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// No directory is there.
    NoDirectory,
    /// It already holds an entry named exactly `init.lean`.
    InitLeanThere,
    /// The file already starts with a header.
    Headed(String),
    /// The file, bound for `Config/`, gives no module name.
    NoModuleName {
        /// The file.
        file: String,
        /// Why.
        why: NoModule,
    },
    /// Two files bound for `Config/` give this module name.
    SameModule(String),
    /// `Config/<Name>.lean` is already there, for this name.
    ConfigModuleThere(String),
    /// The file, bound for `init.lean` before another, leaves a block open
    /// or closes one it did not open.
    Unbalanced(String),
    /// The file system refused a read or a write.
    Files(FilesError),
}

impl Refusal {
    /// What the binary prints after `config-migrate: `, naming the
    /// directory as `dir`, the way the user gave it.
    pub fn message(&self, dir: &str) -> String {
        match self {
            Self::NoDirectory => format!("there is no directory {dir}"),
            Self::InitLeanThere => {
                format!("{dir} already holds an init.lean: it is not a config in the old form")
            }
            Self::Headed(file) => format!(
                "{file} already starts with an import header, so it is not a config in the old form: a config the editor loads has its root in a file named exactly init.lean, which imports the modules under Config/; rename it to init.lean if it is the root"
            ),
            Self::NoModuleName {
                file,
                why: NoModule::NoLetterFirst,
            } => format!(
                "{file} gives no module name: after its leading digits its name must start with a letter"
            ),
            Self::NoModuleName {
                file,
                why: NoModule::OtherCharacter,
            } => format!("{file} gives no module name: its name must be letters, digits, - and _"),
            Self::SameModule(name) => {
                format!("two files give the module name Config.{name}: rename one of them")
            }
            Self::ConfigModuleThere(name) => format!("{dir}/Config/{name}.lean is already there"),
            Self::Unbalanced(file) => format!(
                "{file} leaves a namespace, a section or a mutual block open at its end (or closes one it did not open), and it would go in init.lean before the files after it, which that would change: close it in the file, or move the definition of setup to the last file, and run this again"
            ),
            Self::Files(error) => error.to_string(),
        }
    }
}

impl From<FilesError> for Refusal {
    fn from(error: FilesError) -> Self {
        Self::Files(error)
    }
}

/// One `.lean` file of the old form: its name, shown and on disk, and its
/// bytes.
struct Source {
    name: String,
    file: OsString,
    bytes: Vec<u8>,
}

/// The header of a converted file, importing the module before it when
/// there is one.
fn header(previous: Option<&str>) -> String {
    let mut header = "import Editor\n".to_owned();
    if let Some(previous) = previous {
        let _ = writeln!(header, "import Config.{previous}");
    }
    header.push_str("open Editor\n\n");
    header
}

/// Converts the config directory `dir`, every check made before anything
/// moves.
///
/// # Errors
///
/// Each [`Refusal`], as the module says, with the directory left as it
/// was; and the first write the file system refuses.
pub fn convert(files: &mut impl Files, dir: &Path) -> Result<Outcome, Refusal> {
    if files.kind(dir)? != Kind::Directory {
        return Err(Refusal::NoDirectory);
    }
    // By exactly its name: on a file system that ignores case, `init.lean`
    // is there when `Init.lean` is, and that file is refused below, by
    // name.
    let names = files.names(dir)?;
    if names.iter().any(|name| name == "init.lean") {
        return Err(Refusal::InitLeanThere);
    }
    let mut sources = Vec::new();
    for file in names {
        let bytes = file.as_encoded_bytes();
        if bytes.starts_with(b".") || !bytes.ends_with(b".lean") {
            continue;
        }
        if files.kind(&dir.join(&file))? != Kind::File {
            continue;
        }
        sources.push(Source {
            name: file.to_string_lossy().into_owned(),
            bytes: files.read(&dir.join(&file))?,
            file,
        });
    }
    if sources.is_empty() {
        return Ok(Outcome::NothingToConvert);
    }
    let texts: Vec<String> = sources
        .iter()
        .map(|s| String::from_utf8_lossy(&s.bytes).into_owned())
        .collect();

    // The root's first file: the first that defines `setup` or declares
    // something private. When no file is seen to define `setup`, the
    // first file: every file then goes in `init.lean`.
    let seen_setup = texts.iter().any(|t| lines::defines_setup(t));
    let first = if seen_setup {
        texts
            .iter()
            .position(|t| lines::defines_setup(t) || lines::declares_private(t))
            .unwrap_or(0)
    } else {
        0
    };
    let last = sources.len() - 1;

    // Everything is checked before anything is moved.
    let mut modules = Vec::new();
    let mut given = BTreeSet::new();
    for (at, (source, text)) in sources.iter().zip(&texts).enumerate() {
        if lines::starts_with_header(text) {
            return Err(Refusal::Headed(source.name.clone()));
        }
        if at < first {
            let module = lines::module_name(&source.name).map_err(|why| Refusal::NoModuleName {
                file: source.name.clone(),
                why,
            })?;
            if !given.insert(module.clone()) {
                return Err(Refusal::SameModule(module));
            }
            if files.kind(&dir.join("Config").join(format!("{module}.lean")))? != Kind::Nothing {
                return Err(Refusal::ConfigModuleThere(module));
            }
            modules.push(module);
        } else if at < last && lines::left_open(text) != 0 {
            return Err(Refusal::Unbalanced(source.name.clone()));
        }
    }

    let mut conversion = Conversion {
        moves: Vec::new(),
        merged: Vec::new(),
        together: None,
    };
    let mut previous: Option<&str> = None;
    for (source, module) in sources.iter().zip(&modules) {
        let config = dir.join("Config");
        files.make_dir(&config)?;
        let mut bytes = header(previous).into_bytes();
        bytes.extend_from_slice(&source.bytes);
        files.write(&config.join(format!("{module}.lean")), &bytes)?;
        files.remove(&dir.join(&source.file))?;
        conversion.moves.push((source.name.clone(), module.clone()));
        previous = Some(module);
    }

    let several = first < last;
    let mut root = header(previous).into_bytes();
    for (at, source) in sources.iter().enumerate().skip(first) {
        if several {
            root.extend_from_slice(format!("-- From {}:\n", source.name).as_bytes());
        }
        if several && at < last {
            // Several files in the root: each but the last is a section,
            // so what it opens ends with it.
            root.extend_from_slice(b"section\n\n");
            root.extend_from_slice(&source.bytes);
            root.extend_from_slice(b"\nend\n\n");
        } else {
            root.extend_from_slice(&source.bytes);
        }
        conversion.merged.push(source.name.clone());
    }
    let staged = dir.join("init.lean.new");
    files.write(&staged, &root)?;
    for source in &sources[first..] {
        files.remove(&dir.join(&source.file))?;
    }
    files.rename(&staged, &dir.join("init.lean"))?;
    if several {
        conversion.together = Some(if seen_setup {
            Together::SetupOrPrivate
        } else {
            Together::NoSetupSeen
        });
    }
    Ok(Outcome::Converted(conversion))
}

#[cfg(test)]
mod tests;
