//! A package with a native library, installed and run: `mise run
//! library-install-check`, on demand, never part of the gate (the
//! operator's decision, 2026-11-26, that no gate step installs a package
//! set, about 420 MB; `docs/dev-practices/on-demand-checks.md`). The gate
//! shows the same behaviour on the set build's staged copy
//! (`tests/packages/echo/EchoTest/Linked/Echo/Real/UserSet.lean`), and the
//! install's places and relative record by the core's guards
//! (`installLibrariesRecord`, `stagedLibraryPlace` in `lean/lakefile.lean`)
//! and model tests (`ModelTest.moduleLookupChecks`).
//!
//! `LEANMACS_SYSROOT` names the Lean toolchain's directory; the test panics
//! when it is unset, so a run that forgot it never passes. It needs the
//! library the fixture set's build staged for echo
//! (`tests/packages/.lake/build/libraries/echo/`) and the default set and
//! the core built, which `mise run lean` does. In a temporary directory it
//! owns, it:
//!
//! 1. copies the fixture package `tests/packages/echo` (no `.lake`), puts
//!    echo's staged library at the copy's `lib/libecho_service.<ext>`, so
//!    its `editorLibrary` target answers it and runs no process, and points
//!    the copy's core require at the core's absolute directory;
//! 2. writes a user's set requiring the default set, the copy and the core
//!    last, and resolves it with the toolchain's `lake update
//!    --keep-toolchain`;
//! 3. runs `lake build :editorInstall` with
//!    `EDITOR_INSTALL_DIR=<tmp>/install`, the fixture set's `editor.build`
//!    lines, `PATH=/usr/bin:/bin`, which holds no `cargo`, and a `HOME` in
//!    the temporary directory, the user's Lean, Lake and compiler variables
//!    removed, as the build job runs it;
//! 4. reads back the library the install copied and its relative record;
//! 5. removes the copy of echo and the set's `.lake`, the package's source
//!    and the set's build, and runs the installed editor's `--probe`,
//!    which prints `probe: ok` only once echo's initialiser loaded the
//!    library from the install.
//!
//! Besides its temporary directory, it builds what the default set's and
//! the core's builds would, in place, which `mise run lean` has built
//! already.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use tempfile::TempDir;

/// The `PATH` the builds run with: the system's directories alone.
const USER_PATH: &str = "/usr/bin:/bin";

/// The variables the build job removes before it sets the build record
/// over them (`Editor.PackageSet.clearedVariables`).
const CLEARED: [&str; 11] = [
    "LEAN_CC",
    "LEAN_AR",
    "LEAN_SYSROOT",
    "LEAN",
    "LEAN_PATH",
    "LEAN_SRC_PATH",
    "LAKE_HOME",
    "LAKE_OVERRIDE_LEAN",
    "ELAN_TOOLCHAIN",
    "CC",
    "AR",
];

/// The line echo's lakefile requires the core by.
const CORE_REQUIRE: &str = "require «editor-core» from \"..\" / \"..\" / \"..\" / \"lean\"";

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

/// The file name of echo's library on this platform.
fn library_file() -> &'static str {
    if cfg!(target_os = "macos") {
        "libecho_service.dylib"
    } else {
        "libecho_service.so"
    }
}

/// Copies the directory `from` into `to`, each file's bytes, links followed,
/// leaving out Lake's and the formatter's own directories.
#[expect(
    clippy::disallowed_methods,
    reason = "the on-demand install check copies the fixture package into its own temporary directory"
)]
fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).expect("the directory");
    for entry in fs::read_dir(from).expect("a directory to copy") {
        let entry = entry.expect("an entry");
        if entry.file_name() == ".lake" || entry.file_name() == ".lean-fmt-cache" {
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

/// `command`, run with the build job's environment: the user's Lean, Lake
/// and compiler variables removed, then `record`'s lines, the system's
/// `PATH` and the home `home` set over them.
fn as_the_build_runs<'a>(command: &'a mut Command, record: &str, home: &Path) -> &'a mut Command {
    for name in CLEARED {
        command.env_remove(name);
    }
    command
        .envs(record.lines().filter_map(|line| line.split_once('=')))
        .env("PATH", USER_PATH)
        .env("HOME", home)
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
#[ignore = "installs a package set: mise run library-install-check"]
#[expect(
    clippy::disallowed_methods,
    reason = "the on-demand install check lays a package, a set and an install out in its own temporary directory and reads back what the real build and editor wrote there"
)]
fn an_installed_set_loads_its_package_s_library_from_the_install_after_the_package_and_the_set_s_build_are_removed()
 {
    let sysroot = PathBuf::from(
        std::env::var_os("LEANMACS_SYSROOT")
            .expect("LEANMACS_SYSROOT must name the Lean toolchain's directory"),
    );
    let lake = sysroot.join("bin").join("lake");
    let root = workspace();
    let core = root.join("lean");
    let fixture_set = root.join("tests").join("packages");
    let staged = fixture_set
        .join(".lake")
        .join("build")
        .join("libraries")
        .join("echo")
        .join(library_file());
    let record = fs::read_to_string(
        fixture_set
            .join(".lake")
            .join("build")
            .join("bin")
            .join("editor.build"),
    )
    .unwrap_or_default();
    for directory in USER_PATH.split(':') {
        let cargo = Path::new(directory).join("cargo");
        assert!(
            !cargo.exists(),
            "{} is on the PATH the check builds with ({USER_PATH}), so this machine cannot show a build with no Cargo",
            cargo.display()
        );
    }
    let dir = TempDir::new().expect("a temporary directory");
    let tmp = dir.path().canonicalize().expect("the temporary directory");
    let home = tmp.join("home");
    fs::create_dir_all(&home).expect("the home");

    // 1. echo, with its library already built in `lib/` and its core at the
    //    core's absolute directory.
    let echo = tmp.join("echo");
    copy_tree(&fixture_set.join("echo"), &echo);
    fs::create_dir_all(echo.join("lib")).expect("lib/");
    fs::copy(&staged, echo.join("lib").join(library_file()))
        .expect("echo's library, which `mise run lean` staged for the fixture set");
    let core_path = core.to_str().expect("UTF-8");
    let lakefile = fs::read_to_string(echo.join("lakefile.lean")).expect("echo's lakefile");
    assert_eq!(
        lakefile.matches(CORE_REQUIRE).count(),
        1,
        "echo's lakefile requires the core by {CORE_REQUIRE}"
    );
    fs::write(
        echo.join("lakefile.lean"),
        lakefile.replace(
            CORE_REQUIRE,
            &format!("require «editor-core» from \"{core_path}\""),
        ),
    )
    .expect("echo's lakefile");
    let manifest = fs::read_to_string(echo.join("lake-manifest.json")).expect("echo's manifest");
    fs::write(
        echo.join("lake-manifest.json"),
        manifest.replace("\"../../../lean\"", &format!("\"{core_path}\"")),
    )
    .expect("echo's manifest");

    // 2. A user's set: the default set, echo, and the core last.
    let set = tmp.join("set");
    fs::create_dir_all(&set).expect("the set");
    let required = [
        ("default-set", root.join("packages")),
        ("echo", echo.clone()),
        ("editor-core", core.clone()),
    ];
    let mut text = String::from("name = \"user-set\"\n");
    for (name, path) in &required {
        text.push_str(&format!(
            "\n[[require]]\nname = \"{name}\"\npath = \"{}\"\n",
            path.display()
        ));
    }
    fs::write(set.join("lakefile.toml"), text).expect("the set's lakefile");
    succeeded(
        "lake update --keep-toolchain",
        as_the_build_runs(&mut Command::new(&lake), &record, &home)
            .args(["update", "--keep-toolchain"])
            .current_dir(&set),
    );

    // 3. The install, with no cargo on the PATH.
    let install = tmp.join("install");
    succeeded(
        "lake build :editorInstall",
        as_the_build_runs(&mut Command::new(&lake), &record, &home)
            .env("EDITOR_INSTALL_DIR", &install)
            .args(["build", ":editorInstall"])
            .current_dir(&set),
    );

    // 4. The library the install copied, and its record.
    assert_eq!(
        fs::read(install.join("libraries").join("echo").join(library_file()))
            .expect("the installed library"),
        fs::read(&staged).expect("echo's library"),
        "the install copied echo's library"
    );
    assert_eq!(
        fs::read_to_string(install.join("editor.libraries")).expect("editor.libraries"),
        format!("echo\tlibraries/echo/{}\n", library_file())
    );

    // 5. The package's source and the set's build gone, the installed editor
    //    loads echo's library from the install.
    fs::remove_dir_all(&echo).expect("echo's copy removed");
    fs::remove_dir_all(set.join(".lake")).expect("the set's build removed");
    let probe = succeeded(
        "the installed editor's --probe",
        Command::new(install.join("editor"))
            .arg("--probe")
            .current_dir("/"),
    );
    let printed = String::from_utf8(probe.stdout).expect("UTF-8");
    assert!(
        printed.lines().any(|line| line == "probe: ok"),
        "the installed editor's probe printed:\n{printed}"
    );
    println!(
        "library-install-check: an install of a set with echo loads echo's library from the install, with echo's source and the set's build removed: probe: ok"
    );
}
