//! `stage-bundle` run as the binary it is, in a temporary directory the
//! test owns: the wiring from a command line to the files a bundle holds,
//! over the real file system (and, on macOS, the real tools for the link
//! stubs). What each form copies where is `editor_release::bundle`'s,
//! pinned by its own tests on the fake; here only the files written are
//! read back.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
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
