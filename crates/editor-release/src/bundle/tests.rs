//! The bundle staged on [`FakeFiles`], with a [`RecordingProcess`]
//! answering canned tool output for the macOS stubs.

use std::ffi::OsString;

use super::*;
use crate::fake::{FakeFiles, Node, RecordingProcess};
use crate::ports::{Invocation, RunError};

const BUNDLE: &str = "/out/Leanmacs.app";
const RESOURCES: &str = "/out/Leanmacs.app/Contents/Resources";
const LEAN: &str = "/out/Leanmacs.app/Contents/Resources/lean";
const EXE: &str = "/build/bin/editor";
const SYSROOT: &str = "/toolchain";
const LIST: &str = "/work/shipped";

fn args(words: &[&str]) -> Vec<OsString> {
    words.iter().map(OsString::from).collect()
}

/// What the tools print for the macOS stubs: one framework, one import.
fn tool_output(invocation: &Invocation) -> Result<Vec<u8>, RunError> {
    let text = match invocation.program.to_str() {
        Some("lipo") => "arm64\n",
        Some("otool") => {
            "\t/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (compatibility version 45.0.0, current version 2575.20.19)\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1359.40.3)\n"
        }
        Some("nm") => "                 (undefined) external _NSBeep (from AppKit)\n",
        Some("vtool") => "    minos 26.0\n      sdk 27.2\n",
        _ => return Err(RunError::Start("no such program".to_owned())),
    };
    Ok(text.as_bytes().to_vec())
}

/// A toolchain, an editor beside its records, and a shipped list.
fn files() -> FakeFiles {
    files_without_core().with_file("/build/bin/editor.core", "core 1\n")
}

/// [`files`] but the core record beside the editor.
fn files_without_core() -> FakeFiles {
    FakeFiles::new()
        .with_executable(EXE, "editor")
        .with_file(
            "/build/bin/editor.build",
            "LEAN_SYSROOT=/toolchain\nLEAN_CC=/usr/bin/cc\nLEAN_TARGET=arm64\n",
        )
        .with_executable("/toolchain/bin/lean", "lean")
        .with_file("/toolchain/lib/lean/Init.olean", "init")
        .with_file("/toolchain/include/lean/lean.h", "h")
        .with_link("/toolchain/bin/lean-alias", "lean")
        .with_link("/toolchain/exposed/lean", "../bin/lean")
        .with_file("/toolchain/.hidden", "dot")
        .with_file("/src/Editor.olean", "editor olean")
        .with_file("/src/Editor/Basic.lean", "basic")
        .with_file("/src/lakefile.lean", "lakefile")
        .with_file(
            LIST,
            "file\t/src/Editor.olean\tcore/.lake/build/lib/lean/Editor.olean\n\
             file\t/src/lakefile.lean\tlakefile.lean\n\
             oleans\tcore/.lake/build/lib/lean\n\
             oleans\tpackages/a/.lake/build/lib/lean\n",
        )
}

/// The shipped form's command line, with `launcher` when given.
fn shipped(launcher: Option<&str>) -> Command {
    let mut words = Vec::new();
    if let Some(launcher) = launcher {
        words.extend(["--launcher", launcher]);
    }
    words.extend([BUNDLE, EXE, SYSROOT, LIST]);
    Command::parse(&args(&words)).expect("the shipped form")
}

/// `command` staged on `host` over `files`: its outcome, the files after,
/// and the programs run.
fn stage_on(
    command: &Command,
    host: Host,
    mut files: FakeFiles,
) -> (Result<(), Refusal>, FakeFiles, Vec<Invocation>) {
    let mut process = RecordingProcess::new(tool_output);
    let outcome = stage(command, host, &mut files, &mut process);
    (outcome, files, process.runs)
}

/// `command` staged elsewhere than macOS, which must succeed.
fn staged(command: &Command, files: FakeFiles) -> FakeFiles {
    let (outcome, after, _) = stage_on(command, Host::Other, files);
    assert_eq!(outcome, Ok(()));
    after
}

/// `command` refused over `files`, which it must leave as they were.
fn refused(command: &Command, files: FakeFiles) -> Refusal {
    let (outcome, after, runs) = stage_on(command, Host::Macos, files.clone());
    assert_eq!(after, files, "a refusal writes nothing");
    assert_eq!(runs, [], "a refusal runs nothing");
    outcome.expect_err("refused")
}

fn file(files: &FakeFiles, path: &str) -> (String, bool) {
    match files.node(path) {
        Some(Node::File { bytes, executable }) => (
            String::from_utf8(bytes.clone()).expect("UTF-8"),
            *executable,
        ),
        other => panic!("{path} is {other:?}, not a file"),
    }
}

/// The paths under `dir`, relative to it, sorted as strings.
fn under(files: &FakeFiles, dir: &str) -> Vec<String> {
    let mut found: Vec<String> = files
        .nodes()
        .keys()
        .filter_map(|path| path.strip_prefix(dir).ok())
        .filter(|rel| !rel.as_os_str().is_empty())
        .map(|rel| rel.display().to_string())
        .collect();
    found.sort();
    found
}

// The command line.

#[test]
fn the_shipped_form_takes_four_paths_after_its_options() {
    assert_eq!(
        Command::parse(&args(&["--launcher", "/l", "/b", "/e", "/s", "/list"])),
        Ok(Command {
            launcher: Some(PathBuf::from("/l")),
            bundle: PathBuf::from("/b"),
            executable: PathBuf::from("/e"),
            sysroot: PathBuf::from("/s"),
            form: Form::Shipped {
                list: PathBuf::from("/list"),
            },
        })
    );
    assert_eq!(
        Command::parse(&args(&["/b", "/e", "/s", "/list", "extra"])),
        Err(Usage)
    );
}

#[test]
fn the_module_form_takes_package_directories_joined_by_colons_and_at_least_one_kind() {
    assert_eq!(
        Command::parse(&args(&[
            "--roots", "Init,Std", "/b", "/e", "/s", "/p1:/p2", "olean", "ilean"
        ])),
        Ok(Command {
            launcher: None,
            bundle: PathBuf::from("/b"),
            executable: PathBuf::from("/e"),
            sysroot: PathBuf::from("/s"),
            form: Form::Modules {
                which: Which::Roots(vec!["Init".to_owned(), "Std".to_owned()]),
                packages: vec![PathBuf::from("/p1"), PathBuf::from("/p2")],
                kinds: vec!["olean".to_owned(), "ilean".to_owned()],
            },
        })
    );
    assert_eq!(
        Command::parse(&args(&["--closure", "/c", "/b", "/e", "/s", "/p"])),
        Err(Usage),
        "no kind"
    );
}

#[test]
fn empty_parts_of_the_package_argument_name_nothing_and_none_left_is_the_usage() {
    let Ok(Command {
        form: Form::Modules { packages, .. },
        ..
    }) = Command::parse(&args(&[
        "--closure",
        "/c",
        "/b",
        "/e",
        "/s",
        ":/p1::/p2:",
        "olean",
    ]))
    else {
        panic!("the module form");
    };
    assert_eq!(packages, [PathBuf::from("/p1"), PathBuf::from("/p2")]);
    assert_eq!(
        Command::parse(&args(&["--closure", "/c", "/b", "/e", "/s", "::", "olean"])),
        Err(Usage)
    );
}

#[test]
fn an_unknown_option_or_a_missing_path_is_the_usage() {
    for words in [
        &["--force", "/b", "/e", "/s", "/list"][..],
        &["/b", "/e", "/s"],
        &["--launcher"],
        &[],
    ] {
        assert_eq!(Command::parse(&args(words)), Err(Usage), "{words:?}");
    }
}

#[test]
fn roots_and_closure_together_are_the_usage() {
    assert_eq!(
        Command::parse(&args(&[
            "--roots",
            "Init",
            "--closure",
            "/c",
            "/b",
            "/e",
            "/s",
            "/p",
            "olean"
        ])),
        Err(Usage)
    );
}

// Both forms.

#[test]
fn the_editor_is_a_regular_copy_of_the_executable_with_its_executable_bit() {
    let files = files()
        .with_executable("/build/real-editor", "the real editor")
        .with_link("/build/editor-link", "real-editor");
    let mut command = shipped(None);
    command.executable = PathBuf::from("/build/editor-link");
    let after = staged(&command, files);
    assert_eq!(
        file(&after, "/out/Leanmacs.app/Contents/MacOS/editor"),
        ("the real editor".to_owned(), true)
    );
}

#[test]
fn the_core_record_ships_in_resources_only_when_the_build_wrote_one() {
    let after = staged(&shipped(None), files());
    assert_eq!(
        file(&after, "/out/Leanmacs.app/Contents/Resources/editor.core"),
        ("core 1\n".to_owned(), false)
    );
    let after = staged(&shipped(None), files_without_core());
    assert_eq!(
        after.node("/out/Leanmacs.app/Contents/Resources/editor.core"),
        None
    );
}

#[test]
fn the_launcher_lands_as_leanmacs_only_when_given() {
    let files = files().with_executable("/target/release/leanmacs", "launcher");
    let after = staged(&shipped(Some("/target/release/leanmacs")), files.clone());
    assert_eq!(
        file(&after, "/out/Leanmacs.app/Contents/MacOS/leanmacs"),
        ("launcher".to_owned(), true)
    );
    let after = staged(&shipped(None), files);
    assert_eq!(
        after.node("/out/Leanmacs.app/Contents/MacOS/leanmacs"),
        None
    );
}

// The shipped form.

#[test]
fn the_toolchain_ships_whole_but_exposed_with_links_kept_as_links() {
    let after = staged(&shipped(None), files());
    assert_eq!(
        under(&after, &format!("{LEAN}/toolchain")),
        [
            "bin",
            "bin/lean",
            "bin/lean-alias",
            "include",
            "include/lean",
            "include/lean/lean.h",
            "lib",
            "lib/lean",
            "lib/lean/Init.olean",
        ]
    );
    assert_eq!(
        after.node(format!("{LEAN}/toolchain/bin/lean-alias")),
        Some(&Node::Link(PathBuf::from("lean")))
    );
    assert_eq!(
        file(&after, &format!("{LEAN}/toolchain/bin/lean")),
        ("lean".to_owned(), true)
    );
}

#[test]
fn each_shipped_file_lands_at_its_place_under_lean() {
    let after = staged(&shipped(None), files());
    assert_eq!(
        file(
            &after,
            &format!("{LEAN}/core/.lake/build/lib/lean/Editor.olean")
        ),
        ("editor olean".to_owned(), false)
    );
    assert_eq!(
        file(&after, &format!("{LEAN}/lakefile.lean")),
        ("lakefile".to_owned(), false)
    );
}

#[test]
fn a_shipped_directory_is_copied_whole() {
    let files = files()
        .with_file("/src/Editor/Deep/More.lean", "more")
        .with_file(LIST, "file\t/src/Editor\tcore/Editor\noleans\tcore\n");
    let after = staged(&shipped(None), files);
    assert_eq!(
        under(&after, &format!("{LEAN}/core/Editor")),
        ["Basic.lean", "Deep", "Deep/More.lean"]
    );
}

#[test]
fn the_olean_record_lists_the_olean_places_in_order() {
    let after = staged(&shipped(None), files());
    assert_eq!(
        file(&after, &format!("{RESOURCES}/editor.oleans")).0,
        "core/.lake/build/lib/lean\npackages/a/.lake/build/lib/lean\n"
    );
}

#[test]
fn the_shipped_build_record_drops_lean_cc_and_keeps_every_other_line_in_order() {
    let after = staged(&shipped(None), files());
    assert_eq!(
        file(&after, &format!("{RESOURCES}/editor.build")).0,
        "LEAN_SYSROOT=/toolchain\nLEAN_TARGET=arm64\n"
    );
}

#[test]
fn no_build_record_beside_the_executable_ships_none() {
    let mut command = shipped(None);
    let files = files().with_executable("/elsewhere/editor", "editor");
    command.executable = PathBuf::from("/elsewhere/editor");
    let after = staged(&command, files);
    assert_eq!(after.node(format!("{RESOURCES}/editor.build")), None);
    assert_eq!(after.node(format!("{RESOURCES}/editor.core")), None);
}

#[test]
fn on_macos_the_link_stubs_land_in_lean_link_stubs() {
    let (outcome, after, runs) = stage_on(&shipped(None), Host::Macos, files());
    assert_eq!(outcome, Ok(()));
    assert_eq!(
        under(&after, &format!("{LEAN}/link-stubs")),
        [
            "AppKit.framework",
            "AppKit.framework/AppKit.tbd",
            "platform-version"
        ]
    );
    assert_eq!(
        file(&after, &format!("{LEAN}/link-stubs/platform-version")).0,
        "26.0 27.2\n"
    );
    assert!(
        runs.iter()
            .all(|run| run.args.last() == Some(&OsString::from(EXE)))
    );
}

#[test]
fn elsewhere_no_stubs_are_written_and_no_program_runs() {
    let (outcome, after, runs) = stage_on(&shipped(None), Host::Other, files());
    assert_eq!(outcome, Ok(()));
    assert_eq!(after.node(format!("{LEAN}/link-stubs")), None);
    assert_eq!(runs, []);
}

#[test]
fn a_line_of_another_kind_is_refused_naming_it() {
    let files = files().with_file(LIST, "oleans\tcore\nfile\t/a\tb/a\ndir\t/x\tx\n");
    assert_eq!(
        refused(&shipped(None), files),
        Refusal::UnknownKind {
            list: PathBuf::from(LIST),
            kind: "dir".to_owned(),
        }
    );
}

#[test]
fn a_line_that_would_rename_its_file_is_refused() {
    let files = files().with_file(
        LIST,
        "oleans\tcore\nfile\t/src/lakefile.lean\tcore/lakefile.toml\n",
    );
    assert_eq!(
        refused(&shipped(None), files),
        Refusal::Renamed {
            source: "/src/lakefile.lean".to_owned(),
            place: "core/lakefile.toml".to_owned(),
        }
    );
}

#[test]
fn a_list_with_no_olean_directory_is_refused() {
    let files = files().with_file(LIST, "file\t/src/lakefile.lean\tlakefile.lean\n");
    assert_eq!(
        refused(&shipped(None), files),
        Refusal::NoOleans(PathBuf::from(LIST))
    );
}

// Module files alone.

/// A toolchain's and two packages' module files, of several kinds.
fn module_files() -> FakeFiles {
    FakeFiles::new()
        .with_executable(EXE, "editor")
        .with_file("/toolchain/lib/lean/Init.olean", "Init")
        .with_file("/toolchain/lib/lean/Init.ilean", "Init i")
        .with_file("/toolchain/lib/lean/Init/Core.olean", "Init.Core")
        .with_file("/toolchain/lib/lean/Init/Core.olean.server", "Init.Core s")
        .with_file("/toolchain/lib/lean/Init/Data/List.olean", "Init.Data.List")
        .with_file("/toolchain/lib/lean/Std.olean", "Std")
        .with_file("/toolchain/lib/lean/Lean.olean", "Lean")
        .with_file("/p1/Editor.olean", "Editor from p1")
        .with_file("/p1/Editor/A.olean", "Editor.A")
        .with_file("/p2/Editor.olean", "Editor from p2")
        .with_file("/p2/Editor/B.olean", "Editor.B")
        .with_file("/p2/Shipped.olean", "Shipped")
        .with_file("/p2/Shipped.olean.server", "Shipped s")
}

fn modules(which: &[&str], packages: &str, kinds: &[&str]) -> Command {
    let mut words: Vec<&str> = which.to_vec();
    words.extend([BUNDLE, EXE, SYSROOT, packages]);
    words.extend(kinds);
    Command::parse(&args(&words)).expect("the module form")
}

const STAGED_TOOLCHAIN: &str = "/out/Leanmacs.app/Contents/Resources/lean/toolchain/lib/lean";
const STAGED_EDITOR: &str = "/out/Leanmacs.app/Contents/Resources/lean/editor";

#[test]
fn roots_copy_the_root_file_and_its_tree_of_the_given_kinds_only() {
    let after = staged(
        &modules(&["--roots", "Init"], "/p1", &["olean"]),
        module_files(),
    );
    assert_eq!(
        under(&after, STAGED_TOOLCHAIN),
        [
            "Init",
            "Init.olean",
            "Init/Core.olean",
            "Init/Data",
            "Init/Data/List.olean"
        ]
    );
}

#[test]
fn editor_comes_from_each_package_directory_into_lean_editor() {
    let after = staged(
        &modules(&["--roots", "Std"], "/p1:/p2", &["olean"]),
        module_files(),
    );
    assert_eq!(
        under(&after, STAGED_EDITOR),
        ["Editor", "Editor.olean", "Editor/A.olean", "Editor/B.olean"]
    );
    assert_eq!(
        file(&after, &format!("{STAGED_EDITOR}/Editor.olean")).0,
        "Editor from p1",
        "a module in two directories comes from the first"
    );
}

#[test]
fn the_closure_takes_each_module_from_the_toolchain_first_then_the_first_package_holding_it() {
    let files = module_files()
        .with_file("/p2/Lean.olean", "Lean from p2")
        .with_file("/work/closure", "Init.Core\n\nLean\nEditor\nShipped\n");
    let after = staged(
        &modules(
            &["--closure", "/work/closure"],
            "/p1:/p2",
            &["olean", "olean.server"],
        ),
        files,
    );
    assert_eq!(
        under(&after, STAGED_TOOLCHAIN),
        [
            "Init",
            "Init/Core.olean",
            "Init/Core.olean.server",
            "Lean.olean"
        ]
    );
    assert_eq!(
        under(&after, STAGED_EDITOR),
        ["Editor.olean", "Shipped.olean", "Shipped.olean.server"]
    );
    assert_eq!(
        file(&after, &format!("{STAGED_EDITOR}/Editor.olean")).0,
        "Editor from p1"
    );
}

#[test]
fn a_closure_module_in_no_directory_is_refused_naming_it() {
    let files = module_files().with_file("/work/closure", "Init\nNowhere.Module\n");
    assert_eq!(
        refused(
            &modules(&["--closure", "/work/closure"], "/p1:/p2", &["olean"]),
            files
        ),
        Refusal::NotInAnyDirectory {
            module: "Nowhere.Module".to_owned(),
            toolchain: PathBuf::from("/toolchain/lib/lean"),
            packages: vec![PathBuf::from("/p1"), PathBuf::from("/p2")],
        }
    );
}

#[test]
fn a_file_is_of_a_kind_by_its_whole_ending() {
    let files = module_files()
        .with_file("/toolchain/lib/lean/Init/Weird.oleanx", "not a kind")
        .with_file("/toolchain/lib/lean/Init/Weirdolean", "not a kind either");
    let after = staged(&modules(&["--roots", "Init"], "/p1", &["olean"]), files);
    let staged = under(&after, STAGED_TOOLCHAIN);
    assert!(staged.contains(&"Init/Core.olean".to_owned()));
    assert!(!staged.contains(&"Init/Core.olean.server".to_owned()));
    assert!(!staged.contains(&"Init/Weird.oleanx".to_owned()));
    assert!(!staged.contains(&"Init/Weirdolean".to_owned()));
    assert!(!staged.contains(&"Init.ilean".to_owned()));
}

#[test]
fn the_module_record_is_lean_editor() {
    let after = staged(
        &modules(&["--roots", "Init"], "/p1", &["olean"]),
        module_files(),
    );
    assert_eq!(
        file(&after, &format!("{RESOURCES}/editor.oleans")).0,
        "lean/editor\n"
    );
    assert_eq!(
        file(&after, "/out/Leanmacs.app/Contents/MacOS/editor"),
        ("editor".to_owned(), true)
    );
}

#[test]
fn each_refusal_says_what_is_wrong() {
    assert_eq!(
        Refusal::UnknownKind {
            list: PathBuf::from(LIST),
            kind: "dir".to_owned()
        }
        .to_string(),
        "/work/shipped holds a line of kind dir, which is neither file nor oleans"
    );
    assert_eq!(
        Refusal::NotInAnyDirectory {
            module: "M".to_owned(),
            toolchain: PathBuf::from("/t"),
            packages: vec![PathBuf::from("/p1"), PathBuf::from("/p2")],
        }
        .to_string(),
        "no .olean file for M in /t or /p1 /p2"
    );
}
