//! A package that ships a grammar, installed and run: `mise run
//! grammar-install-check`, on demand, never part of the gate (the
//! operator's decision, 2026-11-26): it installs a package set, about
//! 420 MB, and no gate step installs one (`docs/design/packages.md`, "The
//! install"). The gate's wiring check over the grammar set's build covers
//! the grammar path (`tests/grammar-set/ini-grammar/IniGrammarTest/Linked`).
//!
//! `LEANMACS_SYSROOT` names the Lean toolchain's directory; the test panics
//! when it is unset, so a run that forgot it never passes. It needs the
//! default set's editor (`packages/.lake/build/bin/editor`), which `mise run
//! lean` builds. In a temporary directory it owns, it:
//!
//! 1. copies the test package `tests/grammar-set/ini-grammar` (no `.lake`),
//!    puts this crate's [`editor_syntax_fixture_ini::LIBRARY`] at the path
//!    its declaration names for this platform in the copy's `grammars/`,
//!    and points the copy's `editor-core` require at the core's absolute
//!    directory;
//! 2. generates a config directory from `tests/install/config/init.lean`
//!    with the default set's editor's `headless --generate`, adds the
//!    copy's `[[require]]` before the core's, the edit `:package-install`
//!    makes, and resolves it with the toolchain's `lake update
//!    --keep-toolchain`;
//! 3. runs `lake -d <config> build :editorInstall` with
//!    `EDITOR_INSTALL_DIR=<tmp>/install` and the lines of the default set's
//!    `editor.build`, and reads back the grammar files and the record the
//!    install copied and wrote;
//! 4. runs the installed editor headless, in a directory holding a copy of
//!    the INI fixture, on `tests/install/script`, and compares its
//!    `highlights` line with `tests/install/expected`'s.
//!
//! Besides its temporary directory, it builds what the default set's and
//! the core's builds would, in place, which `mise run lean` has built
//! already.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use tempfile::TempDir;

/// The workspace: two directories above this crate's manifest, with its
/// links resolved, as the paths the build records are.
#[expect(
    clippy::disallowed_methods,
    reason = "the on-demand install check resolves the real checkout's directory, which it hands the real build"
)]
fn workspace() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .canonicalize()
        .expect("the workspace")
}

/// The platform's name a per-platform grammar declaration lists a library
/// under (`Language.Grammar.platformOf`), and the file name of the fixture
/// library at that path in the test package's `grammars/`.
fn platform_library() -> (String, &'static str) {
    let os = if cfg!(target_os = "macos") {
        "darwin"
    } else {
        std::env::consts::OS
    };
    let name = if cfg!(target_os = "macos") {
        "libtree-sitter-ini.dylib"
    } else {
        "libtree-sitter-ini.so"
    };
    (format!("{os}-{}", std::env::consts::ARCH), name)
}

/// Copies the directory `from` into `to`, each file's bytes, links followed,
/// leaving out `.lake`.
#[expect(
    clippy::disallowed_methods,
    reason = "the on-demand install check copies the test package into its own temporary directory"
)]
fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).expect("the directory");
    for entry in fs::read_dir(from).expect("a directory to copy") {
        let entry = entry.expect("an entry");
        if entry.file_name() == ".lake" {
            continue;
        }
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), &target).expect("a file");
        }
    }
}

/// Runs `command` to success and returns what it wrote.
fn succeeded(what: &str, command: &mut Command) -> Output {
    let out = command
        .output()
        .unwrap_or_else(|e| panic!("{what} cannot start: {e}"));
    assert!(
        out.status.success(),
        "{what} failed ({}): {}{}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    out
}

#[test]
#[ignore = "installs a package set: mise run grammar-install-check"]
#[expect(
    clippy::disallowed_methods,
    reason = "the on-demand install check lays a package, a config and an install out in its own temporary directory and reads back what the real build and editor wrote there"
)]
fn an_installed_set_with_a_grammar_package_highlights_its_language() {
    let sysroot = PathBuf::from(
        std::env::var_os("LEANMACS_SYSROOT")
            .expect("LEANMACS_SYSROOT must name the Lean toolchain's directory"),
    );
    let lake = sysroot.join("bin").join("lake");
    let root = workspace();
    let core = root.join("lean");
    let package = root.join("tests").join("grammar-set").join("ini-grammar");
    let default_editor = root
        .join("packages")
        .join(".lake")
        .join("build")
        .join("bin")
        .join("editor");
    let dir = TempDir::new().expect("a temporary directory");
    let tmp = dir.path().canonicalize().expect("the temporary directory");

    // 1. The package, with the fixture library at this platform's path and
    //    its core at the core's absolute directory.
    let copy = tmp.join("ini-grammar");
    copy_tree(&package, &copy);
    let (platform, name) = platform_library();
    let library = copy.join("grammars").join(&platform).join(name);
    fs::create_dir_all(library.parent().expect("the platform's directory"))
        .expect("the platform's directory");
    fs::copy(editor_syntax_fixture_ini::LIBRARY, &library).expect("the fixture library");
    let core_path = core.to_str().expect("UTF-8");
    for file in ["lakefile.toml", "lake-manifest.json"] {
        let text = fs::read_to_string(copy.join(file)).expect("the package's file");
        fs::write(copy.join(file), text.replace("../../../lean", core_path))
            .expect("the package's file");
    }

    // 2. A config directory the default set's editor generates, the package
    //    added before the core, as `:package-install` adds one.
    let config = tmp.join("config");
    fs::create_dir_all(&config).expect("the config directory");
    fs::copy(
        package
            .join("tests")
            .join("install")
            .join("config")
            .join("init.lean"),
        config.join("init.lean"),
    )
    .expect("init.lean");
    let generate = tmp.join("generate");
    fs::write(&generate, "reload\nsettle\n").expect("the generating script");
    let oleans = core.join(".lake").join("build").join("lib").join("lean");
    succeeded(
        "the default set's editor's headless --generate",
        Command::new(&default_editor)
            .args(["headless", "--generate"])
            .arg(&sysroot)
            .arg(&oleans)
            .arg(&config)
            .arg(&generate),
    );
    let lakefile = fs::read_to_string(config.join("lakefile.toml")).expect("a generated lakefile");
    let marker = "[[require]]\nname = \"editor-core\"";
    assert!(
        lakefile.contains(marker),
        "the generated lakefile requires the core: {lakefile}"
    );
    let required = format!(
        "[[require]]\nname = \"ini-grammar\"\npath = \"{}\"\n\n{marker}",
        copy.display()
    );
    fs::write(
        config.join("lakefile.toml"),
        lakefile.replacen(marker, &required, 1),
    )
    .expect("the edited lakefile");
    succeeded(
        "lake update --keep-toolchain",
        Command::new(&lake)
            .args(["update", "--keep-toolchain"])
            .current_dir(&config),
    );

    // 3. The install.
    let install = tmp.join("install");
    let record = fs::read_to_string(default_editor.with_extension("build")).unwrap_or_default();
    succeeded(
        "lake build :editorInstall",
        Command::new(&lake)
            .env("EDITOR_INSTALL_DIR", &install)
            .envs(record.lines().filter_map(|line| line.split_once('=')))
            .arg("-d")
            .arg(&config)
            .args(["build", ":editorInstall"]),
    );
    let installed = install.join("grammars").join("ini-grammar");
    assert_eq!(
        fs::read(installed.join(&platform).join(name)).expect("the installed library"),
        fs::read(editor_syntax_fixture_ini::LIBRARY).expect("the fixture library"),
        "the install copied the package's library"
    );
    assert_eq!(
        fs::read(installed.join("queries").join("highlights.scm")).expect("the installed query"),
        fs::read(
            package
                .join("grammars")
                .join("queries")
                .join("highlights.scm")
        )
        .expect("the package's query"),
        "the install copied the package's highlights query"
    );
    assert_eq!(
        fs::read_to_string(install.join("editor.grammars")).expect("editor.grammars"),
        "ini-grammar\tgrammars/ini-grammar\n"
    );

    // 4. The installed editor, run headless on a copy of the INI fixture.
    let work = tmp.join("work");
    fs::create_dir_all(&work).expect("the working directory");
    fs::copy(
        root.join("tests")
            .join("syntax")
            .join("ini")
            .join("settings.ini"),
        work.join("settings.ini"),
    )
    .expect("the INI fixture");
    let ran = succeeded(
        "the installed editor's headless run",
        Command::new(install.join("editor"))
            .arg("headless")
            .arg(&sysroot)
            .arg(install.join("lib").join("lean"))
            .arg(&config)
            .arg(package.join("tests").join("install").join("script"))
            .current_dir(&work),
    );
    let printed = String::from_utf8(ran.stdout).expect("UTF-8");
    let expected = fs::read_to_string(package.join("tests").join("install").join("expected"))
        .expect("the expected highlights");
    let highlights: Vec<&str> = printed
        .lines()
        .filter(|line| line.starts_with("highlights "))
        .collect();
    assert_eq!(
        highlights,
        expected.lines().collect::<Vec<_>>(),
        "the installed editor's highlights; it printed:\n{printed}"
    );
    assert!(
        !printed.contains("grammar `ini`:"),
        "the grammar's registration was refused; it printed:\n{printed}"
    );
    println!(
        "grammar-install-check: an install of a set with ini-grammar highlights settings.ini with the package's grammar"
    );
}
