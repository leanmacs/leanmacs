//! The stubs decided from canned `lipo`, `otool`, `nm` and `vtool` output,
//! on [`RecordingProcess`] and [`FakeFiles`].

use super::*;
use crate::fake::{FakeFiles, Node, RecordingProcess};
use crate::ports::{Invocation, RunError};

const EXE: &str = "/build/editor";
const OUT: &str = "/stage/stubs";

const APPKIT: &str = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit";

/// What each tool prints for the executable.
#[derive(Clone)]
struct Tools {
    archs: String,
    otool: String,
    nm: String,
    vtool: String,
}

/// One `otool -L` line for a library.
fn library(install: &str, compatibility: &str, current: &str) -> String {
    format!("\t{install} (compatibility version {compatibility}, current version {current})\n")
}

/// One `nm -m -u` line for an import of `symbol` from `library`.
fn import(symbol: &str, library: &str) -> String {
    format!("                 (undefined) external {symbol} (from {library})\n")
}

const VTOOL: &str = "/build/editor:\nLoad command 11\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform MACOS\n    minos 26.0\n      sdk 27.2\n   ntools 1\n     tool LD\n  version 27106.1\n";

/// An executable that loads AppKit and `libSystem`, importing one symbol
/// of each.
fn tools() -> Tools {
    Tools {
        archs: "arm64\n".to_owned(),
        otool: format!(
            "{EXE}:\n{}{}",
            library(APPKIT, "45.0.0", "2575.20.19"),
            library("/usr/lib/libSystem.B.dylib", "1.0.0", "1359.40.3"),
        ),
        nm: import("_NSBeep", "AppKit") + &import("_abort", "libSystem"),
        vtool: VTOOL.to_owned(),
    }
}

/// The files before a run: the executable alone.
fn files() -> FakeFiles {
    FakeFiles::new().with_executable(EXE, "mach-o")
}

/// Answers each tool with `tools`' text for it.
fn answering(tools: Tools) -> impl FnMut(&Invocation) -> Result<Vec<u8>, RunError> {
    move |invocation: &Invocation| {
        let text = match invocation.program.to_str() {
            Some("lipo") => &tools.archs,
            Some("otool") => &tools.otool,
            Some("nm") => &tools.nm,
            Some("vtool") => &tools.vtool,
            _ => return Err(RunError::Start("no such program".to_owned())),
        };
        Ok(text.as_bytes().to_vec())
    }
}

/// `link_stubs` run on macOS over `tools` and `files`: its outcome, the
/// files after it, and the programs it ran.
fn run_on(tools: Tools, mut files: FakeFiles) -> (Result<(), Refusal>, FakeFiles, Vec<Invocation>) {
    let mut process = RecordingProcess::new(answering(tools));
    let outcome = link_stubs(
        &mut process,
        &mut files,
        Host::Macos,
        Path::new(EXE),
        Path::new(OUT),
    );
    (outcome, files, process.runs)
}

/// The text of the written file at `path`.
fn text(files: &FakeFiles, path: &str) -> String {
    match files.node(path) {
        Some(Node::File { bytes, .. }) => String::from_utf8(bytes.clone()).expect("UTF-8"),
        other => panic!("{path} is {other:?}, not a file"),
    }
}

/// `tools` refused: the refusal, with the files left as they were.
fn refused(tools: Tools) -> Refusal {
    let (outcome, after, _) = run_on(tools, files());
    assert_eq!(after, files(), "a refusal writes nothing");
    outcome.expect_err("refused")
}

#[test]
fn a_framework_gets_its_stub_in_its_framework_directory_with_only_its_imported_symbols() {
    let mut tools = tools();
    tools.nm =
        import("_NSBeep", "AppKit") + &import("_NSApp", "AppKit") + &import("_abort", "libSystem");
    let (outcome, files, _) = run_on(tools, files());
    assert_eq!(outcome, Ok(()));
    assert_eq!(
        text(&files, "/stage/stubs/AppKit.framework/AppKit.tbd"),
        "--- !tapi-tbd\n\
         tbd-version:     4\n\
         targets:         [ arm64-macos ]\n\
         install-name:    '/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit'\n\
         current-version: 2575.20.19\n\
         compatibility-version: 45.0.0\n\
         exports:\n\
         \x20 - targets:         [ arm64-macos ]\n\
         \x20   symbols:         [ '_NSApp', '_NSBeep' ]\n\
         ...\n"
    );
}

#[test]
fn a_library_stub_is_named_by_its_file_name_up_to_the_first_dot() {
    let mut tools = tools();
    tools.otool += &library("/usr/lib/libobjc.A.dylib", "1.0.0", "228.0.0");
    tools.nm += &import("_objc_msgSend", "libobjc");
    let (outcome, files, _) = run_on(tools, files());
    assert_eq!(outcome, Ok(()));
    let stub = text(&files, "/stage/stubs/libobjc.tbd");
    assert!(stub.contains("install-name:    '/usr/lib/libobjc.A.dylib'\n"));
    assert!(stub.contains("symbols:         [ '_objc_msgSend' ]\n"));
}

#[test]
fn libsystem_and_libcxx_get_no_stub_and_their_imports_are_not_refused() {
    let mut tools = tools();
    tools.otool += &library("/usr/lib/libc++.1.dylib", "1.0.0", "2000.0.0");
    tools.nm += &import("__ZdlPv", "libc++");
    let (outcome, files, _) = run_on(tools, files());
    assert_eq!(outcome, Ok(()));
    let written: Vec<_> = files
        .nodes()
        .keys()
        .filter(|path| path.starts_with(OUT))
        .cloned()
        .collect();
    assert_eq!(
        written,
        [
            PathBuf::from("/stage/stubs"),
            PathBuf::from("/stage/stubs/AppKit.framework"),
            PathBuf::from("/stage/stubs/AppKit.framework/AppKit.tbd"),
            PathBuf::from("/stage/stubs/platform-version"),
        ]
    );
}

#[test]
fn a_library_with_no_imports_gets_a_stub_with_no_exports() {
    let mut tools = tools();
    tools.otool += &library("/usr/lib/libiconv.2.dylib", "7.0.0", "7.0.0");
    let (outcome, files, _) = run_on(tools, files());
    assert_eq!(outcome, Ok(()));
    assert_eq!(
        text(&files, "/stage/stubs/libiconv.tbd"),
        "--- !tapi-tbd\n\
         tbd-version:     4\n\
         targets:         [ arm64-macos ]\n\
         install-name:    '/usr/lib/libiconv.2.dylib'\n\
         current-version: 7.0.0\n\
         compatibility-version: 7.0.0\n\
         ...\n"
    );
}

#[test]
fn symbols_are_listed_once_in_byte_order() {
    let mut tools = tools();
    tools.nm = ["_b", "_a", "_B", "_a", "__z"]
        .iter()
        .map(|s| import(s, "AppKit"))
        .collect();
    let (outcome, files, _) = run_on(tools, files());
    assert_eq!(outcome, Ok(()));
    assert!(
        text(&files, "/stage/stubs/AppKit.framework/AppKit.tbd")
            .contains("symbols:         [ '_B', '__z', '_a', '_b' ]\n")
    );
}

#[test]
fn platform_version_is_the_first_minos_and_sdk_vtool_reports() {
    let mut tools = tools();
    tools.vtool = VTOOL.to_owned()
        + "Load command 12\n      cmd LC_BUILD_VERSION\n platform MACCATALYST\n    minos 17.0\n      sdk 18.0\n";
    let (outcome, files, runs) = run_on(tools, files());
    assert_eq!(outcome, Ok(()));
    assert_eq!(text(&files, "/stage/stubs/platform-version"), "26.0 27.2\n");
    let commands: Vec<String> = runs.iter().map(ToString::to_string).collect();
    assert_eq!(
        commands,
        [
            "lipo -archs /build/editor",
            "otool -L /build/editor",
            "nm -m -u /build/editor",
            "vtool -show-build /build/editor",
        ]
    );
    assert!(runs.iter().all(|run| run.captured));
}

#[test]
fn a_host_that_is_not_macos_is_refused_and_runs_nothing() {
    let mut files = files();
    let mut process = RecordingProcess::new(answering(tools()));
    let outcome = link_stubs(
        &mut process,
        &mut files,
        Host::Other,
        Path::new(EXE),
        Path::new(OUT),
    );
    assert_eq!(outcome, Err(Refusal::NotMacos));
    assert_eq!(process.runs, []);
    assert_eq!(files, self::files());
}

#[test]
fn a_path_that_is_not_a_file_is_refused() {
    for before in [FakeFiles::new(), FakeFiles::new().with_dir(EXE)] {
        let (outcome, after, runs) = run_on(tools(), before.clone());
        assert_eq!(outcome, Err(Refusal::NotAFile(PathBuf::from(EXE))));
        assert_eq!(after, before);
        assert_eq!(runs, []);
    }
}

#[test]
fn more_than_one_architecture_is_refused() {
    let mut tools = tools();
    tools.archs = "x86_64 arm64\n".to_owned();
    assert_eq!(
        refused(tools),
        Refusal::SeveralArchitectures {
            executable: PathBuf::from(EXE),
            archs: "x86_64 arm64".to_owned(),
        }
    );
}

#[test]
fn otool_listing_no_library_is_refused() {
    let mut tools = tools();
    tools.otool = format!("{EXE}:\n");
    assert_eq!(refused(tools), Refusal::NoLibrary(PathBuf::from(EXE)));
}

#[test]
fn an_nm_line_not_an_import_bound_to_a_library_is_refused() {
    let mut tools = tools();
    tools.nm += "                 (undefined) external _dlsym (dynamically looked up)\n";
    assert_eq!(
        refused(tools),
        Refusal::NotAnImport {
            executable: PathBuf::from(EXE),
            line: "                 (undefined) external _dlsym (dynamically looked up)".to_owned(),
        }
    );
}

#[test]
fn an_import_bound_to_a_library_otool_does_not_list_is_refused_naming_the_symbol() {
    let mut tools = tools();
    tools.nm += &import("_MTLCreateSystemDefaultDevice", "Metal");
    assert_eq!(
        refused(tools),
        Refusal::Unbound {
            symbol: "_MTLCreateSystemDefaultDevice".to_owned(),
            library: "Metal".to_owned(),
        }
    );
}

#[test]
fn an_objective_c_symbol_is_refused_naming_it_and_its_library() {
    let mut tools = tools();
    tools.nm += &import("_OBJC_CLASS_$_NSView", "AppKit");
    assert_eq!(
        refused(tools),
        Refusal::ObjectiveC {
            symbol: "_OBJC_CLASS_$_NSView".to_owned(),
            library: "AppKit".to_owned(),
        }
    );
}

#[test]
fn vtool_reporting_no_minos_or_no_sdk_is_refused() {
    for vtool in [
        "Load command 11\n      cmd LC_BUILD_VERSION\n      sdk 27.2\n",
        "Load command 11\n      cmd LC_BUILD_VERSION\n    minos 26.0\n",
    ] {
        let mut tools = tools();
        tools.vtool = vtool.to_owned();
        assert_eq!(
            refused(tools),
            Refusal::NoPlatformVersion(PathBuf::from(EXE))
        );
    }
}

#[test]
fn a_tool_that_fails_is_refused_naming_its_command() {
    let mut files = files();
    let mut process = RecordingProcess::new(|i: &Invocation| {
        if i.program == "lipo" {
            Err(RunError::Failed(Some(1)))
        } else {
            Ok(Vec::new())
        }
    });
    let outcome = link_stubs(
        &mut process,
        &mut files,
        Host::Macos,
        Path::new(EXE),
        Path::new(OUT),
    );
    assert_eq!(
        outcome,
        Err(Refusal::Run {
            command: "lipo -archs /build/editor".to_owned(),
            error: RunError::Failed(Some(1)),
        })
    );
    assert_eq!(files, self::files());
}

#[test]
fn each_refusal_says_what_is_wrong() {
    assert_eq!(
        Refusal::Unbound {
            symbol: "_f".to_owned(),
            library: "Metal".to_owned()
        }
        .to_string(),
        "_f is imported from Metal, which otool -L does not list"
    );
    assert_eq!(
        Refusal::ObjectiveC {
            symbol: "_OBJC_CLASS_$_NSView".to_owned(),
            library: "AppKit".to_owned()
        }
        .to_string(),
        "_OBJC_CLASS_$_NSView, imported from AppKit, is an Objective-C symbol, which a text stub lists apart; link-stubs does not write that form"
    );
    assert_eq!(
        Refusal::NotAFile(PathBuf::from(EXE)).to_string(),
        "no executable at /build/editor"
    );
}
