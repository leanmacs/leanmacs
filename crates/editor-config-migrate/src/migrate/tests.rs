//! The conversion on [`FakeFiles`]: what each shape of the old form
//! becomes, and that what is refused is left as it was.

use super::*;
use crate::fake::{FakeFiles, Node};

const DIR: &str = "/home/u/.config/leanmacs";

/// A config directory holding `files`, each a name and its text.
fn config(files: &[(&str, &str)]) -> FakeFiles {
    files
        .iter()
        .fold(FakeFiles::new().with_dir(DIR), |fake, (name, text)| {
            fake.with_file(Path::new(DIR).join(name), text)
        })
}

/// `files` converted: the conversion, and the files after it.
fn converted(files: FakeFiles) -> (Conversion, FakeFiles) {
    let mut files = files;
    match convert(&mut files, Path::new(DIR)) {
        Ok(Outcome::Converted(conversion)) => (conversion, files),
        other => panic!("not converted: {other:?}"),
    }
}

/// `files` refused, which the conversion must leave as they were.
fn refused(files: FakeFiles) -> Refusal {
    let mut after = files.clone();
    let refusal = convert(&mut after, Path::new(DIR)).expect_err("refused");
    assert_eq!(after, files, "a refusal changes nothing");
    refusal
}

/// The files of the directory after, each a path under it and its text.
fn held(files: &FakeFiles) -> Vec<(String, String)> {
    files
        .nodes()
        .iter()
        .filter_map(|(path, node)| match node {
            Node::File(bytes) => Some((
                path.strip_prefix(DIR).ok()?.display().to_string(),
                String::from_utf8(bytes.clone()).expect("UTF-8"),
            )),
            Node::Dir => None,
        })
        .collect()
}

fn text_of(files: &FakeFiles, name: &str) -> String {
    held(files)
        .into_iter()
        .find(|(path, _)| path == name)
        .unwrap_or_else(|| panic!("no {name}"))
        .1
}

const LEADER: &str = "/-- What `greet` says. -/\ndef greet : EditorM Unit :=\n  message \"converted\"\n\ndef leaderMap : SetupM Unit :=\n  command \"greet\" greet\n";
const SETUP: &str = "def setup : SetupM Unit :=\n  leaderMap\n";

#[test]
fn the_old_forms_two_files_become_a_config_module_and_the_root() {
    let (conversion, files) = converted(config(&[
        ("05-leader.lean", LEADER),
        ("90-setup.lean", SETUP),
    ]));
    assert_eq!(
        held(&files),
        [
            (
                "Config/Leader.lean".to_owned(),
                format!("import Editor\nopen Editor\n\n{LEADER}")
            ),
            (
                "init.lean".to_owned(),
                format!("import Editor\nimport Config.Leader\nopen Editor\n\n{SETUP}")
            ),
        ]
    );
    assert_eq!(
        conversion,
        Conversion {
            moves: vec![("05-leader.lean".to_owned(), "Leader".to_owned())],
            merged: vec!["90-setup.lean".to_owned()],
            together: None,
        }
    );
    assert_eq!(
        Outcome::Converted(conversion).lines("~/conf"),
        [
            "config-migrate: moved 05-leader.lean to Config/Leader.lean",
            "config-migrate: moved 90-setup.lean to init.lean",
            "config-migrate: converted ~/conf",
        ]
    );
}

#[test]
fn each_config_module_imports_the_one_before_it() {
    let (conversion, files) = converted(config(&[
        ("10-greet.lean", "def greet := 1\n"),
        ("20-evil-keys.lean", "def evilKeys := greet\n"),
        ("90-setup.lean", "def setup := evilKeys\n"),
    ]));
    assert_eq!(
        text_of(&files, "Config/Greet.lean"),
        "import Editor\nopen Editor\n\ndef greet := 1\n"
    );
    assert_eq!(
        text_of(&files, "Config/EvilKeys.lean"),
        "import Editor\nimport Config.Greet\nopen Editor\n\ndef evilKeys := greet\n"
    );
    assert_eq!(
        text_of(&files, "init.lean"),
        "import Editor\nimport Config.EvilKeys\nopen Editor\n\ndef setup := evilKeys\n"
    );
    assert_eq!(conversion.moves.len(), 2);
}

#[test]
fn one_file_becomes_init_lean_alone() {
    let (conversion, files) = converted(config(&[("10-keys.lean", "def setup := 1\n")]));
    assert_eq!(
        held(&files),
        [(
            "init.lean".to_owned(),
            "import Editor\nopen Editor\n\ndef setup := 1\n".to_owned()
        )]
    );
    assert_eq!(conversion.merged, ["10-keys.lean"]);
    assert_eq!(conversion.together, None);
}

#[test]
fn a_setup_before_the_last_file_takes_it_and_the_files_after_it_into_init_lean_in_sections() {
    let (conversion, files) = converted(config(&[
        ("10-greet.lean", "def greet := 1\n"),
        (
            "20-setup.lean",
            "namespace Inner\nend Inner\ndef setup := greet\n",
        ),
        ("25-middle.lean", "def middle := 2\n"),
        ("30-checks.lean", "def checks := setup\n"),
    ]));
    assert_eq!(
        text_of(&files, "init.lean"),
        "import Editor\nimport Config.Greet\nopen Editor\n\n\
         -- From 20-setup.lean:\nsection\n\nnamespace Inner\nend Inner\ndef setup := greet\n\nend\n\n\
         -- From 25-middle.lean:\nsection\n\ndef middle := 2\n\nend\n\n\
         -- From 30-checks.lean:\ndef checks := setup\n"
    );
    assert_eq!(
        conversion.merged,
        ["20-setup.lean", "25-middle.lean", "30-checks.lean"]
    );
    assert_eq!(conversion.together, Some(Together::SetupOrPrivate));
    assert_eq!(
        Outcome::Converted(conversion).lines("/c"),
        [
            "config-migrate: moved 10-greet.lean to Config/Greet.lean",
            "config-migrate: put 20-setup.lean 25-middle.lean 30-checks.lean in init.lean, in that order: the first of them defines setup or declares something private, and the editor runs the setup that init.lean itself defines",
            "config-migrate: converted /c",
        ]
    );
}

#[test]
fn a_setup_in_the_first_of_two_files_takes_both() {
    let (conversion, files) = converted(config(&[
        ("10-setup.lean", "def setup := 1\n"),
        ("20-more.lean", "def more := setup\n"),
    ]));
    assert_eq!(conversion.moves, []);
    assert_eq!(conversion.merged, ["10-setup.lean", "20-more.lean"]);
    assert_eq!(
        held(&files).into_iter().map(|(p, _)| p).collect::<Vec<_>>(),
        ["init.lean"]
    );
    assert!(
        text_of(&files, "init.lean")
            .starts_with("import Editor\nopen Editor\n\n-- From 10-setup.lean:\nsection\n")
    );
}

#[test]
fn a_private_declaration_keeps_its_file_with_the_files_after_it() {
    let (conversion, _) = converted(config(&[
        ("05-first.lean", "def first := 1\n"),
        ("10-helpers.lean", "private def secret := 1\n"),
        ("90-setup.lean", "def setup := secret\n"),
    ]));
    assert_eq!(
        conversion.moves,
        [("05-first.lean".to_owned(), "First".to_owned())]
    );
    assert_eq!(conversion.merged, ["10-helpers.lean", "90-setup.lean"]);
    assert_eq!(conversion.together, Some(Together::SetupOrPrivate));
}

#[test]
fn with_no_setup_seen_every_file_goes_to_init_lean_and_the_conversion_says_why() {
    let (conversion, files) = converted(config(&[
        ("10-greet.lean", "def greet := 1\n"),
        ("90-setup.lean", "/-- The setup. -/ def setup := greet\n"),
    ]));
    assert_eq!(conversion.moves, []);
    assert_eq!(conversion.merged, ["10-greet.lean", "90-setup.lean"]);
    assert_eq!(conversion.together, Some(Together::NoSetupSeen));
    assert_eq!(
        held(&files).into_iter().map(|(p, _)| p).collect::<Vec<_>>(),
        ["init.lean"]
    );
    assert_eq!(
        Outcome::Converted(conversion).lines("/c")[0],
        "config-migrate: put 10-greet.lean 90-setup.lean in init.lean, in that order: no line of any file was seen to define setup, so they are kept together"
    );
}

#[test]
fn files_are_taken_in_byte_order_and_only_lean_files_directly_in_the_directory() {
    let (conversion, files) = converted(config(&[
        ("b-keys.lean", "def b := 1\n"),
        ("B-upper.lean", "def bigB := 1\n"),
        ("a-more.lean", "def a := 1\n"),
        ("z-setup.lean", "def setup := 1\n"),
        (".hidden.lean", "def hidden := 1\n"),
        ("notes.txt", "notes\n"),
        ("sub/x.lean", "def x := 1\n"),
    ]));
    assert_eq!(
        conversion.moves,
        [
            ("B-upper.lean".to_owned(), "BUpper".to_owned()),
            ("a-more.lean".to_owned(), "AMore".to_owned()),
            ("b-keys.lean".to_owned(), "BKeys".to_owned()),
        ]
    );
    let left: Vec<String> = held(&files).into_iter().map(|(p, _)| p).collect();
    assert_eq!(
        left,
        [
            ".hidden.lean",
            "Config/AMore.lean",
            "Config/BKeys.lean",
            "Config/BUpper.lean",
            "init.lean",
            "notes.txt",
            "sub/x.lean",
        ]
    );
}

#[test]
fn a_directory_with_no_lean_file_has_nothing_to_convert_and_is_unchanged() {
    let files = config(&[("notes.txt", "notes\n")]);
    let mut after = files.clone();
    let outcome = convert(&mut after, Path::new(DIR));
    assert_eq!(outcome, Ok(Outcome::NothingToConvert));
    assert_eq!(after, files);
    assert_eq!(
        Outcome::NothingToConvert.lines("/c"),
        ["config-migrate: /c holds no .lean file directly in it: there is nothing to convert"]
    );
}

#[test]
fn the_last_file_may_leave_a_namespace_open() {
    let (conversion, files) = converted(config(&[
        ("10-setup.lean", "def setup := 1\n"),
        ("20-more.lean", "namespace Open\ndef more := 1\n"),
    ]));
    assert_eq!(conversion.merged, ["10-setup.lean", "20-more.lean"]);
    assert!(
        text_of(&files, "init.lean")
            .ends_with("-- From 20-more.lean:\nnamespace Open\ndef more := 1\n")
    );
}

#[test]
fn no_directory() {
    let mut files = FakeFiles::new();
    assert_eq!(
        convert(&mut files, Path::new(DIR)),
        Err(Refusal::NoDirectory)
    );
    assert_eq!(files, FakeFiles::new());
    assert_eq!(
        Refusal::NoDirectory.message("~/c"),
        "there is no directory ~/c"
    );
}

#[test]
fn an_init_lean_already_there() {
    let refusal = refused(config(&[
        ("10-a.lean", "def a := 1\n"),
        ("init.lean", "def setup := 1\n"),
    ]));
    assert_eq!(refusal, Refusal::InitLeanThere);
    assert_eq!(
        refusal.message("/c"),
        "/c already holds an init.lean: it is not a config in the old form"
    );
}

#[test]
fn a_headed_file() {
    let refusal = refused(config(&[
        ("10-keys.lean", "def keys := 1\n"),
        (
            "90-setup.lean",
            "-- The setup.\nimport Editor\nopen Editor\n\ndef setup := 1\n",
        ),
    ]));
    assert_eq!(refusal, Refusal::Headed("90-setup.lean".to_owned()));
    assert!(
        refusal
            .message("/c")
            .starts_with("90-setup.lean already starts with an import header")
    );
}

#[test]
fn a_root_spelt_init_capital() {
    let refusal = refused(config(&[(
        "Init.lean",
        "import Editor\nopen Editor\n\ndef setup := 1\n",
    )]));
    assert_eq!(refusal, Refusal::Headed("Init.lean".to_owned()));
    let message = refusal.message("/c");
    assert!(
        message.contains("Init.lean") && message.contains("init.lean"),
        "{message}"
    );
}

#[test]
fn a_file_with_no_module_name() {
    let refusal = refused(config(&[
        ("10.lean", "def a := 1\n"),
        ("90-setup.lean", "def setup := 1\n"),
    ]));
    assert_eq!(
        refusal,
        Refusal::NoModuleName {
            file: "10.lean".to_owned(),
            why: NoModule::NoLetterFirst,
        }
    );
    assert_eq!(
        refusal.message("/c"),
        "10.lean gives no module name: after its leading digits its name must start with a letter"
    );
}

#[test]
fn two_files_giving_one_module_name() {
    let refusal = refused(config(&[
        ("10-keys.lean", "def a := 1\n"),
        ("20-keys.lean", "def b := 2\n"),
        ("90-setup.lean", "def setup := 1\n"),
    ]));
    assert_eq!(refusal, Refusal::SameModule("Keys".to_owned()));
    assert_eq!(
        refusal.message("/c"),
        "two files give the module name Config.Keys: rename one of them"
    );
}

#[test]
fn a_config_module_already_there() {
    let refusal = refused(config(&[
        ("10-keys.lean", "def a := 1\n"),
        ("90-setup.lean", "def setup := 1\n"),
        ("Config/Keys.lean", "mine\n"),
    ]));
    assert_eq!(refusal, Refusal::ConfigModuleThere("Keys".to_owned()));
    assert_eq!(
        refusal.message("/c"),
        "/c/Config/Keys.lean is already there"
    );
}

#[test]
fn a_namespace_left_open_before_another_file() {
    let refusal = refused(config(&[
        (
            "10-setup.lean",
            "def setup := 1\n\nnamespace LeftOpen\n\ndef inside := 1\n",
        ),
        ("20-more.lean", "def more := 2\n"),
    ]));
    assert_eq!(refusal, Refusal::Unbalanced("10-setup.lean".to_owned()));
    assert!(
        refusal
            .message("/c")
            .starts_with("10-setup.lean leaves a namespace, a section or a mutual block open")
    );
}

#[test]
fn an_end_closing_what_was_not_opened_before_another_file() {
    let refusal = refused(config(&[
        ("10-setup.lean", "def setup := 1\n\nend Stray\n"),
        ("20-more.lean", "def more := 2\n"),
    ]));
    assert_eq!(refusal, Refusal::Unbalanced("10-setup.lean".to_owned()));
}
