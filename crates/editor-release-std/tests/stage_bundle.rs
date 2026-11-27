//! `stage-bundle` run as the binary it is, in a temporary directory the
//! test owns: the wiring from a command line to the files a bundle holds,
//! over the real file system (and, on macOS, the real tools for the link
//! stubs). What each form copies where is `editor_release::bundle`'s,
//! pinned by its own tests on the fake; here only the files written are
//! read back.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;

/// Writes `text` as the file `path`, making its directory.
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it writes its inputs in the test's own directory"
)]
fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().expect("a directory")).expect("the directory");
    std::fs::write(path, text).expect("the file");
}

/// Runs `stage-bundle` with `args`, which must succeed.
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it runs the real `stage-bundle`"
)]
fn stage_bundle(args: &[&Path]) {
    let status = Command::new(env!("CARGO_BIN_EXE_stage-bundle"))
        .args(args)
        .status()
        .expect("stage-bundle runs");
    assert!(status.success(), "stage-bundle exited {status}");
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it lays a toolchain and an editor out in the test's own directory and reads back the bundle the real `stage-bundle` wrote there"
)]
fn the_binary_stages_the_shipped_form() {
    let dir = TempDir::new().expect("a temporary directory");
    let root = dir.path();
    let sysroot = root.join("toolchain");
    write(&sysroot.join("bin/tool"), "#!/bin/sh\n");
    std::fs::set_permissions(
        sysroot.join("bin/tool"),
        std::fs::Permissions::from_mode(0o755),
    )
    .expect("an executable tool");
    write(&sysroot.join("lib/nested/file.txt"), "nested\n");
    std::os::unix::fs::symlink("tool", sysroot.join("bin/alias")).expect("a link");
    std::fs::create_dir_all(sysroot.join("exposed")).expect("exposed");
    std::os::unix::fs::symlink("../bin/tool", sysroot.join("exposed/tool")).expect("a link");

    // The editor is a real thin Mach-O on macOS, so its stubs can be read.
    let editor = root.join("build/editor");
    std::fs::create_dir_all(editor.parent().expect("build")).expect("build");
    std::fs::copy(env!("CARGO_BIN_EXE_link-stubs"), &editor).expect("an executable");
    write(
        &root.join("build/editor.build"),
        "LEAN_SYSROOT=/t\nLEAN_CC=/usr/bin/cc\nLEAN_TARGET=arm64\n",
    );
    write(&root.join("build/editor.core"), "core\n");
    write(&root.join("src/Mod.olean"), "module\n");
    let list = root.join("shipped");
    let source = root.join("src/Mod.olean");
    write(
        &list,
        &format!(
            "file\t{}\tcore/lib/Mod.olean\noleans\tcore/lib\n",
            source.display()
        ),
    );
    let app = root.join("Leanmacs.app");
    stage_bundle(&[&app, &editor, &sysroot, &list]);

    let resources = app.join("Contents/Resources");
    let lean = resources.join("lean");
    let shipped_editor = app.join("Contents/MacOS/editor");
    assert_eq!(
        std::fs::read(&shipped_editor).expect("the editor"),
        std::fs::read(&editor).expect("the executable")
    );
    let mode = std::fs::metadata(&shipped_editor)
        .expect("the editor")
        .permissions()
        .mode();
    assert_ne!(mode & 0o111, 0, "the editor is executable");
    assert_eq!(
        std::fs::read_to_string(resources.join("editor.core")).expect("editor.core"),
        "core\n"
    );
    assert_eq!(
        std::fs::read_to_string(lean.join("toolchain/lib/nested/file.txt")).expect("nested"),
        "nested\n"
    );
    assert!(!lean.join("toolchain/exposed").exists());
    assert_eq!(
        std::fs::read_link(lean.join("toolchain/bin/alias")).expect("still a link"),
        Path::new("tool")
    );
    assert_eq!(
        std::fs::read_to_string(lean.join("core/lib/Mod.olean")).expect("the shipped file"),
        "module\n"
    );
    assert_eq!(
        std::fs::read_to_string(resources.join("editor.oleans")).expect("editor.oleans"),
        "core/lib\n"
    );
    assert_eq!(
        std::fs::read_to_string(resources.join("editor.build")).expect("editor.build"),
        "LEAN_SYSROOT=/t\nLEAN_TARGET=arm64\n"
    );
    if cfg!(target_os = "macos") {
        assert!(lean.join("link-stubs/platform-version").is_file());
    }
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

/// Copies the directory `from` into `to`, each file's bytes.
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it copies the test package's checked-in grammars into the test's own directory"
)]
fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).expect("the directory");
    for entry in std::fs::read_dir(from).expect("the package's grammars") {
        let entry = entry.expect("an entry");
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), &target).expect("a file");
        }
    }
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it lays the test package's grammars and the fixture library out in the test's own directory and reads back the bundle the real `stage-bundle` wrote there"
)]
fn the_binary_stages_a_packages_grammar_library_and_queries() {
    let dir = TempDir::new().expect("a temporary directory");
    let root = dir.path();
    let sysroot = root.join("toolchain");
    write(&sysroot.join("lib/lean/Init.olean"), "init\n");
    let editor = root.join("build/editor");
    std::fs::create_dir_all(editor.parent().expect("build")).expect("build");
    std::fs::copy(env!("CARGO_BIN_EXE_link-stubs"), &editor).expect("an executable");
    // The test package's own `grammars/`, with the fixture library at the
    // path its declaration names for this platform.
    let package: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "../../tests/grammar-set/ini-grammar",
    ]
    .iter()
    .collect();
    let grammars = root.join("ini-grammar/grammars");
    copy_tree(&package.join("grammars"), &grammars);
    let (platform, name) = platform_library();
    let library = grammars.join(&platform).join(name);
    std::fs::create_dir_all(library.parent().expect("the platform's directory"))
        .expect("the platform's directory");
    std::fs::copy(editor_syntax_fixture_ini::LIBRARY, &library).expect("the fixture library");
    write(&root.join("src/Mod.olean"), "module\n");
    let list = root.join("shipped");
    write(
        &list,
        &format!(
            "file\t{}\tset/lib/Mod.olean\nfile\t{}\tset/ini-grammar/grammars\ngrammars\tini-grammar\tset/ini-grammar/grammars\noleans\tset/lib\n",
            root.join("src/Mod.olean").display(),
            grammars.display()
        ),
    );
    let app = root.join("Leanmacs.app");
    stage_bundle(&[&app, &editor, &sysroot, &list]);

    let resources = app.join("Contents/Resources");
    let staged = resources.join("lean/set/ini-grammar/grammars");
    assert_eq!(
        std::fs::read(staged.join(&platform).join(name)).expect("the staged library"),
        std::fs::read(editor_syntax_fixture_ini::LIBRARY).expect("the fixture library")
    );
    assert_eq!(
        std::fs::read(staged.join("queries/highlights.scm")).expect("the staged query"),
        std::fs::read(package.join("grammars/queries/highlights.scm"))
            .expect("the package's query")
    );
    assert_eq!(
        std::fs::read_to_string(resources.join("editor.grammars")).expect("editor.grammars"),
        "ini-grammar\tlean/set/ini-grammar/grammars\n"
    );
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it lays a package's grammars, a set's staged directory and the fixture library out in the test's own directory and reads back the bundle the real `stage-bundle` wrote there"
)]
fn the_binary_stages_a_grammar_library_compiled_into_a_sets_staged_directory_beside_the_packages_own()
 {
    // The lines a set's build lists for a package whose grammar it compiled
    // from source (`shippedGrammarsLines` in `lean/lakefile.lean`): the
    // package's own `grammars/`, holding no library; then the library, from
    // the set's staged directory, which is named after its Lake package and
    // so cannot be listed whole, to the same path under the package's
    // `grammars`; then the record's line.
    let dir = TempDir::new().expect("a temporary directory");
    let root = dir.path();
    let sysroot = root.join("toolchain");
    write(&sysroot.join("lib/lean/Init.olean"), "init\n");
    let editor = root.join("build/editor");
    std::fs::create_dir_all(editor.parent().expect("build")).expect("build");
    std::fs::copy(env!("CARGO_BIN_EXE_link-stubs"), &editor).expect("an executable");
    let package: PathBuf = [
        env!("CARGO_MANIFEST_DIR"),
        "../../tests/grammar-set/ini-grammar",
    ]
    .iter()
    .collect();
    let grammars = root.join("ini-grammar/grammars");
    copy_tree(&package.join("grammars"), &grammars);
    let (platform, name) = platform_library();
    let staged = root.join("set/.lake/build/grammars/ini-grammar");
    let compiled = format!("{platform}/{name}");
    let library = staged.join(&compiled);
    std::fs::create_dir_all(library.parent().expect("the platform's directory"))
        .expect("the platform's directory");
    std::fs::copy(editor_syntax_fixture_ini::LIBRARY, &library).expect("the fixture library");
    write(&root.join("src/Mod.olean"), "module\n");
    let list = root.join("shipped");
    write(
        &list,
        &format!(
            "file\t{}\tset/lib/Mod.olean\nfile\t{}\tset/ini-grammar/grammars\nfile\t{}\tset/ini-grammar/grammars/{compiled}\ngrammars\tini-grammar\tset/ini-grammar/grammars\noleans\tset/lib\n",
            root.join("src/Mod.olean").display(),
            grammars.display(),
            library.display()
        ),
    );
    let app = root.join("Leanmacs.app");
    stage_bundle(&[&app, &editor, &sysroot, &list]);

    let resources = app.join("Contents/Resources");
    let bundled = resources.join("lean/set/ini-grammar/grammars");
    assert_eq!(
        std::fs::read(bundled.join(&platform).join(name)).expect("the bundled library"),
        std::fs::read(editor_syntax_fixture_ini::LIBRARY).expect("the fixture library")
    );
    assert_eq!(
        std::fs::read(bundled.join("queries/highlights.scm")).expect("the bundled query"),
        std::fs::read(package.join("grammars/queries/highlights.scm"))
            .expect("the package's query")
    );
    assert_eq!(
        std::fs::read_to_string(resources.join("editor.grammars")).expect("editor.grammars"),
        "ini-grammar\tlean/set/ini-grammar/grammars\n"
    );
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the binary's test: it lays module files out in the test's own directory and reads back what the real `stage-bundle` staged there"
)]
fn the_binary_stages_a_closure() {
    let dir = TempDir::new().expect("a temporary directory");
    let root = dir.path();
    let sysroot = root.join("toolchain");
    write(&sysroot.join("lib/lean/Init/Core.olean"), "Init.Core\n");
    write(
        &sysroot.join("lib/lean/Init/Core.ilean"),
        "not a kind asked\n",
    );
    let package = root.join("package");
    write(&package.join("Editor/A.olean"), "Editor.A\n");
    write(&root.join("build/editor"), "editor\n");
    let closure = root.join("closure");
    write(&closure, "Init.Core\nEditor.A\n");
    let app = root.join("Leanmacs.app");
    stage_bundle(&[
        Path::new("--closure"),
        &closure,
        &app,
        &root.join("build/editor"),
        &sysroot,
        &package,
        Path::new("olean"),
    ]);

    let lean = app.join("Contents/Resources/lean");
    assert_eq!(
        std::fs::read_to_string(lean.join("toolchain/lib/lean/Init/Core.olean"))
            .expect("from the toolchain"),
        "Init.Core\n"
    );
    assert!(!lean.join("toolchain/lib/lean/Init/Core.ilean").exists());
    assert_eq!(
        std::fs::read_to_string(lean.join("editor/Editor/A.olean")).expect("from the package"),
        "Editor.A\n"
    );
    assert_eq!(
        std::fs::read_to_string(app.join("Contents/Resources/editor.oleans"))
            .expect("editor.oleans"),
        "lean/editor\n"
    );
}
