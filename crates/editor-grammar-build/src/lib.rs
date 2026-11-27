//! Compiles a package's pinned grammar sources into the shared libraries a
//! set's build stages (`docs/design/packages.md`, "A package's grammars").
//!
//! **Who uses it.** A package that ships a grammar as source, not as a
//! prebuilt library, holds a crate of its own whose build script calls
//! [`build`] with the grammars it declares (`packages/languages/rust`, the
//! crate `languages-grammar-sources`), and whose binary prints the report
//! this writes. The set's build runs that binary through Cargo (the
//! package's `editorGrammarSources` input file, read by the core's
//! `editorGrammars` facet, `lean/lakefile.lean`) and stages each library it
//! names. A fixture whose one grammar does not compile,
//! `editor-grammar-build-fixture`, holds the set's failure check to it.
//! Nothing here is linked into the editor.
//!
//! **What it compiles.** A grammar's source is a directory holding the
//! generated `src/parser.c`, and `src/scanner.c` when the grammar has one,
//! their headers under `src/`. Each is compiled with the C compiler `cc`
//! finds for the target and linked straight into
//! `libtree-sitter-<name>.dylib` (macOS) or `.so` (elsewhere), exporting
//! `tree_sitter_<name>`, as `editor-syntax-fixture-ini`'s build script links
//! its fixture. A Rust `cdylib` wrapping the grammar's crate cannot do it: a
//! forwarder named `tree_sitter_<name>` collides with the C symbol of the
//! same name in the grammar's archive, and one under another name breaks a
//! declaration's rule that the symbol registers the declared name.
//!
//! **Where a source is.** [`Source::Directory`] names it. [`Source::Package`]
//! names a Cargo package that the calling crate depends on, a crates.io
//! grammar crate or a vendored path crate, and its directory is found with
//! `cargo metadata` ([`CargoMetadata`]): grammar crates declare no `links`,
//! so no `DEP_*` metadata reaches a build script, and the metadata is the
//! supported way to find a dependency's directory. The version compiled is
//! the one the root lock pins, resolved through the calling crate's own
//! node of the resolve.
//!
//! **What it writes.** [`build`] writes `OUT_DIR/grammars.report`, one line a
//! grammar, `built<TAB><name><TAB><absolute library>` or
//! `failed<TAB><name><TAB><reason>` ([`Report::lines`]), and
//! `OUT_DIR/grammars.stderr`, each failed compile's compiler output
//! ([`Report::stderr`]). It never panics on a grammar that fails: it
//! records the failure, warns, and carries on, so the workspace still
//! builds and the set's build is what fails, naming the package and the
//! grammar. The decision is the set's build's, from the lines.
//!
//! **Its shape.** The core ([`build_with`]) reaches the outside world only
//! through the [`ports`]: [`Locate`] a package's directory, ask the
//! [`SourceTree`] whether a file is there, and [`Compile`] sources into a
//! library. The real adapters are [`CargoMetadata`], [`RealTree`] and
//! [`CcCompiler`], and [`build`] wires them, the one place that reads the
//! build script's environment.

mod cargo_metadata;
mod cc_compiler;
pub mod ports;
mod real_tree;

pub use cargo_metadata::CargoMetadata;
pub use cc_compiler::CcCompiler;
pub use ports::{Compile, Locate, SourceTree};
pub use real_tree::RealTree;

use std::path::{Path, PathBuf};

/// Where a grammar's source is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    /// A Cargo package the calling crate depends on, by its name: a
    /// crates.io grammar crate, or a vendored one by path.
    Package(String),
    /// A directory holding `src/parser.c`; a relative one is taken from the
    /// calling crate's directory by [`build`].
    Directory(PathBuf),
}

/// A grammar a package declares from source: its name, which its symbol
/// `tree_sitter_<name>` carries, and where its source is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Grammar {
    /// The grammar's name.
    pub name: String,
    /// Where its source is.
    pub source: Source,
}

impl Grammar {
    /// The grammar `name` from the Cargo package `package`.
    pub fn package(name: &str, package: &str) -> Self {
        Self {
            name: name.to_owned(),
            source: Source::Package(package.to_owned()),
        }
    }

    /// The grammar `name` from the directory `directory`.
    pub fn directory(name: &str, directory: impl Into<PathBuf>) -> Self {
        Self {
            name: name.to_owned(),
            source: Source::Directory(directory.into()),
        }
    }
}

/// What became of one grammar.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Compiled into `library`.
    Built {
        /// The grammar's name.
        name: String,
        /// The library, absolute.
        library: PathBuf,
    },
    /// Not compiled, and why.
    Failed {
        /// The grammar's name.
        name: String,
        /// Why, as a sentence.
        reason: String,
        /// The compiler's output, when the compiler ran and failed.
        output: Option<String>,
    },
}

/// What a build of a crate's grammars did: an outcome a grammar, in the
/// order declared, and the source directories a change to which builds them
/// again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    /// An outcome a grammar, in order.
    pub outcomes: Vec<Outcome>,
    /// The `src/` directory of each grammar whose source was found.
    pub watched: Vec<PathBuf>,
}

impl Report {
    /// The report's text: one line a grammar, `built<TAB><name><TAB><library>`
    /// or `failed<TAB><name><TAB><reason>`, each field kept to one line with
    /// no tab ([`one_line`]).
    pub fn lines(&self) -> String {
        self.outcomes
            .iter()
            .map(|outcome| match outcome {
                Outcome::Built { name, library } => format!(
                    "built\t{}\t{}\n",
                    one_line(name),
                    one_line(&library.to_string_lossy())
                ),
                Outcome::Failed { name, reason, .. } => {
                    format!("failed\t{}\t{}\n", one_line(name), one_line(reason))
                }
            })
            .collect()
    }

    /// The compiler's output of each grammar that failed to compile, each
    /// under a line naming the grammar; nothing when none did.
    pub fn stderr(&self) -> String {
        self.outcomes
            .iter()
            .filter_map(|outcome| match outcome {
                Outcome::Failed {
                    name,
                    output: Some(output),
                    ..
                } => Some(format!("the grammar `{name}`'s compile:\n{output}")),
                _ => None,
            })
            .collect()
    }
}

/// `text` with each tab and line break made a space, for a field of a
/// report's line.
pub fn one_line(text: &str) -> String {
    text.replace(['\t', '\n', '\r'], " ")
}

/// Whether `name` can be a grammar's name: lowercase ASCII letters, digits
/// and underscores, at least one, since its symbol is `tree_sitter_<name>`.
pub fn is_grammar_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

/// The file of the grammar `name`'s library for the target OS `os` (Cargo's
/// `CARGO_CFG_TARGET_OS`): `libtree-sitter-<name>.dylib` on macOS, `.so`
/// elsewhere.
pub fn library_file_name(name: &str, os: &str) -> String {
    let extension = if os == "macos" { "dylib" } else { "so" };
    format!("libtree-sitter-{name}.{extension}")
}

/// Why `package` cannot be located for the crate `caller`: it is none of
/// its dependencies.
pub fn not_a_dependency(package: &str, caller: &str) -> String {
    format!(
        "`{package}` is not a dependency of `{caller}`: a grammar's package is a build-dependency of the crate that builds it"
    )
}

/// The reason a failed compile gives, from the compiler's output: its first
/// line that holds `error`, or else its first line.
pub fn compiler_failure(output: &str) -> String {
    let mut lines = output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty());
    let first = lines.clone().next();
    match lines.find(|line| line.contains("error")).or(first) {
        Some(line) => format!("the C compiler failed: {line}"),
        None => "the C compiler failed, and said nothing".to_owned(),
    }
}

/// Builds each of `grammars` with the ports given: locates its source,
/// plans its sources, and compiles them into `out_dir`, the library named
/// for the target OS `os` ([`library_file_name`]). A grammar that fails
/// does not stop the rest.
pub fn build_with(
    grammars: &[Grammar],
    locate: &impl Locate,
    tree: &impl SourceTree,
    compile: &impl Compile,
    out_dir: &Path,
    os: &str,
) -> Report {
    let mut watched = Vec::new();
    let outcomes = grammars
        .iter()
        .map(|grammar| {
            let name = grammar.name.clone();
            let failed = |reason: String, output: Option<String>| Outcome::Failed {
                name: name.clone(),
                reason,
                output,
            };
            if !is_grammar_name(&name) {
                return failed(bad_name(&name), None);
            }
            let directory = match &grammar.source {
                Source::Package(package) => match locate.locate(package) {
                    Ok(directory) => directory,
                    Err(reason) => return failed(reason, None),
                },
                Source::Directory(directory) => directory.clone(),
            };
            let src = directory.join("src");
            let sources = match planned(&name, &src, tree) {
                Ok(sources) => sources,
                Err(reason) => return failed(reason, None),
            };
            watched.push(src.clone());
            let library = out_dir.join(library_file_name(&name, os));
            match compile.compile(&sources, &src, &library) {
                Ok(()) => Outcome::Built {
                    name: name.clone(),
                    library,
                },
                Err(output) => failed(compiler_failure(&output), Some(output)),
            }
        })
        .collect();
    Report { outcomes, watched }
}

/// The file [`build`] writes the report's lines into, in `OUT_DIR`; the
/// calling crate's binary prints it.
pub const REPORT_FILE: &str = "grammars.report";

/// The file [`build`] writes the failed compiles' output into, in
/// `OUT_DIR`; the calling crate's binary prints it on standard error.
pub const STDERR_FILE: &str = "grammars.stderr";

/// Builds `grammars` from a build script: the real adapters wired over the
/// build script's environment, the one place that reads it. It writes
/// [`REPORT_FILE`] and [`STDERR_FILE`] into `OUT_DIR`, asks Cargo to run it
/// again when a grammar's `src/` changes, and warns for each grammar that
/// failed. It never panics on a grammar that fails (the crate docs); only a
/// variable Cargo always sets, missing, or a report it cannot write, stops
/// it.
pub fn build(grammars: &[Grammar]) {
    let variable = |name: &str| {
        #[expect(
            clippy::disallowed_methods,
            reason = "a build script's inputs are Cargo's environment, read here and nowhere else in the crate"
        )]
        let value = std::env::var_os(name);
        value.unwrap_or_else(|| panic!("Cargo sets {name} for a build script"))
    };
    let text = |name: &str| {
        variable(name)
            .into_string()
            .unwrap_or_else(|value| panic!("{name} is not UTF-8: {value:?}"))
    };
    let manifest_dir = PathBuf::from(variable("CARGO_MANIFEST_DIR"));
    let out_dir = PathBuf::from(variable("OUT_DIR"));
    let target = text("TARGET");
    let package = text("CARGO_PKG_NAME");
    let grammars: Vec<Grammar> = grammars
        .iter()
        .map(|grammar| match &grammar.source {
            Source::Directory(directory) => Grammar {
                name: grammar.name.clone(),
                source: Source::Directory(manifest_dir.join(directory)),
            },
            Source::Package(_) => grammar.clone(),
        })
        .collect();
    let report = build_with(
        &grammars,
        &CargoMetadata::new(
            variable("CARGO"),
            &target,
            manifest_dir.join("Cargo.toml"),
            &package,
        ),
        &RealTree,
        &CcCompiler::new(&target, &text("HOST"), &text("OPT_LEVEL")),
        &out_dir,
        &text("CARGO_CFG_TARGET_OS"),
    );
    for (file, contents) in [
        (REPORT_FILE, report.lines()),
        (STDERR_FILE, report.stderr()),
    ] {
        let path = out_dir.join(file);
        #[expect(
            clippy::disallowed_methods,
            reason = "the build script writes its report into OUT_DIR, which the calling crate's binary prints"
        )]
        std::fs::write(&path, contents)
            .unwrap_or_else(|error| panic!("writing {}: {error}", path.display()));
    }
    for directory in &report.watched {
        println!("cargo:rerun-if-changed={}", directory.display());
    }
    println!("cargo:rerun-if-changed=build.rs");
    for outcome in &report.outcomes {
        if let Outcome::Failed { name, reason, .. } = outcome {
            println!(
                "cargo:warning=the grammar `{name}` did not compile from its source: {}",
                one_line(reason)
            );
        }
    }
}

/// The sources of the grammar `name` whose source directory is `src`:
/// `parser.c`, then `scanner.c` when there is one; or why there are none to
/// compile: no `parser.c`, or a C++ scanner.
fn planned(name: &str, src: &Path, tree: &impl SourceTree) -> Result<Vec<PathBuf>, String> {
    let parser = src.join("parser.c");
    if !tree.has_file(&parser) {
        return Err(format!(
            "the grammar `{name}`'s source has no src/parser.c ({})",
            parser.display()
        ));
    }
    let cpp = src.join("scanner.cc");
    if tree.has_file(&cpp) {
        return Err(format!(
            "the grammar `{name}` has a C++ scanner ({}), which is not supported: a grammar's scanner is compiled as C",
            cpp.display()
        ));
    }
    let scanner = src.join("scanner.c");
    let mut sources = vec![parser];
    if tree.has_file(&scanner) {
        sources.push(scanner);
    }
    Ok(sources)
}

/// Why the name `name` is refused ([`is_grammar_name`]).
fn bad_name(name: &str) -> String {
    format!(
        "the grammar name `{name}` is not one a symbol `tree_sitter_<name>` can carry: a grammar's name is lowercase letters, digits and underscores"
    )
}

#[cfg(test)]
mod tests;
