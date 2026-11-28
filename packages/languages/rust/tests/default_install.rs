//! The default set, installed with no config and run: `mise run
//! languages-install-check`, on demand, never part of the gate (the
//! operator's decision, 2026-11-26): it installs a package set, about
//! 420 MB, and no gate step installs one (`docs/design/packages.md`, "The
//! install"). The gate's wiring checks over the default set's build cover
//! the path of the grammars `languages` ships
//! (`packages/languages/LanguagesTest/Linked/Languages/Grammars/Real.lean`).
//!
//! The library compiles in no grammar, so a `.rs` file is highlighted only
//! once the `languages` package's `rust` grammar, compiled by the set's
//! build and copied by the install, has registered. This check shows that
//! an editor installed from the default set does that with no config of
//! the user's.
//!
//! `LEANMACS_SYSROOT` names the Lean toolchain's directory; the test panics
//! when it is unset, so a run that forgot it never passes. It needs the
//! default set's editor (`packages/.lake/build/bin/editor`), which `mise run
//! lean` builds. In a temporary directory it owns, it:
//!
//! 1. generates a config directory with the default set's editor's
//!    `headless --generate`, from `packages/languages/tests/install/config/init.lean`,
//!    a root whose `setup` registers nothing, which is "no config": the
//!    editor needs a root module in its config directory to write the
//!    directory's lakefile and to install. It resolves it with the
//!    toolchain's `lake update --keep-toolchain`;
//! 2. runs `lake -d <config> build :editorInstall` with
//!    `EDITOR_INSTALL_DIR=<tmp>/install` and the lines of the default set's
//!    `editor.build`, and reads back that the install copied the package's
//!    `rust` library to `grammars/languages/<platform>/` and recorded the
//!    package's grammars directory relative to it in `editor.grammars`;
//! 3. runs the installed editor headless, in a directory holding a copy of
//!    the Rust fixture `tests/syntax/rust/hello.rs`, twice: over that
//!    config, on `packages/languages/tests/install/script`, which reloads
//!    it; and with no config directory at all (a path never made) on
//!    `packages/languages/tests/install/without-config`, which asks for no
//!    reload, so the run starts with no config, as the window mode does
//!    with none, and the packages' grammars register alone. Each script
//!    opens the file with the Vim scheme's keys; each run's `highlights`
//!    line is compared with `packages/languages/tests/install/expected`'s,
//!    and each says no refusal of any grammar.
//!
//! Besides its temporary directory, it builds what the default set's and
//! the core's builds would, in place, which `mise run lean` has built
//! already.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use tempfile::TempDir;

/// The workspace: three directories above this crate's manifest, with its
/// links resolved, as the paths the build records are.
#[expect(
    clippy::disallowed_methods,
    reason = "the on-demand install check resolves the real checkout's directory, which it hands the real build"
)]
fn workspace() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("..")
        .canonicalize()
        .expect("the workspace")
}

/// The platform's name a per-platform grammar declaration lists a library
/// under (`Language.Grammar.platformOf`), and the file name of the `rust`
/// grammar's library there (`Languages.Grammars.libraries`).
fn platform_library() -> (String, &'static str) {
    let os = if cfg!(target_os = "macos") {
        "darwin"
    } else {
        std::env::consts::OS
    };
    let name = if cfg!(target_os = "macos") {
        "libtree-sitter-rust.dylib"
    } else {
        "libtree-sitter-rust.so"
    };
    (format!("{os}-{}", std::env::consts::ARCH), name)
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
#[ignore = "installs a package set: mise run languages-install-check"]
#[expect(
    clippy::disallowed_methods,
    reason = "the on-demand install check lays a config and an install out in its own temporary directory and reads back what the real build and editor wrote there"
)]
fn the_default_set_installed_with_no_config_highlights_a_rust_file() {
    let sysroot = PathBuf::from(
        std::env::var_os("LEANMACS_SYSROOT")
            .expect("LEANMACS_SYSROOT must name the Lean toolchain's directory"),
    );
    let lake = sysroot.join("bin").join("lake");
    let root = workspace();
    let core = root.join("lean");
    let languages = root.join("packages").join("languages");
    let default_editor = root
        .join("packages")
        .join(".lake")
        .join("build")
        .join("bin")
        .join("editor");
    let dir = TempDir::new().expect("a temporary directory");
    let tmp = dir.path().canonicalize().expect("the temporary directory");

    // 1. A config directory the default set's editor generates, whose root
    //    registers nothing.
    let config = tmp.join("config");
    fs::create_dir_all(&config).expect("the config directory");
    fs::copy(
        languages
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
    succeeded(
        "lake update --keep-toolchain",
        Command::new(&lake)
            .args(["update", "--keep-toolchain"])
            .current_dir(&config),
    );

    // 2. The install.
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
    let (platform, name) = platform_library();
    let library = install
        .join("grammars")
        .join("languages")
        .join(&platform)
        .join(name);
    assert!(
        library.is_file(),
        "the install copied the package's rust library to {}",
        library.display()
    );
    let grammars = fs::read_to_string(install.join("editor.grammars")).expect("editor.grammars");
    assert!(
        grammars
            .lines()
            .any(|line| line == "languages\tgrammars/languages"),
        "the install's editor.grammars names the package's grammars relative to it: {grammars:?}"
    );

    // 3. The installed editor, run headless on a copy of the Rust fixture.
    let work = tmp.join("work");
    fs::create_dir_all(&work).expect("the working directory");
    fs::copy(
        root.join("tests")
            .join("syntax")
            .join("rust")
            .join("hello.rs"),
        work.join("hello.rs"),
    )
    .expect("the Rust fixture");
    let expected = fs::read_to_string(languages.join("tests").join("install").join("expected"))
        .expect("the expected highlights");
    // With the config whose root registers nothing, reloaded; then with no
    // config directory at all, the path handed in never made, and no
    // reload: the run starts with no config, as the window mode does.
    let absent = tmp.join("no-config");
    for (what, directory, script) in [
        ("with an empty config, reloaded", &config, "script"),
        ("with no config directory", &absent, "without-config"),
    ] {
        let ran = succeeded(
            &format!("the installed editor's headless run {what}"),
            Command::new(install.join("editor"))
                .arg("headless")
                .arg(&sysroot)
                .arg(install.join("lib").join("lean"))
                .arg(directory)
                .arg(languages.join("tests").join("install").join(script))
                .current_dir(&work),
        );
        let printed = String::from_utf8(ran.stdout).expect("UTF-8");
        let highlights: Vec<&str> = printed
            .lines()
            .filter(|line| line.starts_with("highlights "))
            .collect();
        assert_eq!(
            highlights,
            expected.lines().collect::<Vec<_>>(),
            "the installed editor's highlights {what}; it printed:\n{printed}"
        );
        assert!(
            !printed.contains("grammar `"),
            "a grammar's registration was refused {what}; it printed:\n{printed}"
        );
    }
    assert!(
        !absent.exists(),
        "the run with no config directory made none"
    );
    println!(
        "languages-install-check: the default set, installed, highlights hello.rs with the languages package's grammar with an empty config and with no config directory"
    );
}
