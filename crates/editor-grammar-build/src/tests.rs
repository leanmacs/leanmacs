//! The core's tests, on hand-written fakes of the three ports.

use super::*;
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};

/// Locates the packages it is given, and refuses every other as no
/// dependency of `caller`.
struct FakeLocate {
    caller: &'static str,
    packages: BTreeMap<&'static str, PathBuf>,
}

impl FakeLocate {
    fn new(packages: &[(&'static str, &str)]) -> Self {
        Self {
            caller: "grammar-sources",
            packages: packages
                .iter()
                .map(|(name, dir)| (*name, PathBuf::from(dir)))
                .collect(),
        }
    }
}

impl Locate for FakeLocate {
    fn locate(&self, package: &str) -> Result<PathBuf, String> {
        self.packages
            .get(package)
            .cloned()
            .ok_or_else(|| not_a_dependency(package, self.caller))
    }
}

/// The files it is given, and no others.
struct FakeTree(BTreeSet<PathBuf>);

impl FakeTree {
    fn of(files: &[&str]) -> Self {
        Self(files.iter().map(PathBuf::from).collect())
    }
}

impl SourceTree for FakeTree {
    fn has_file(&self, path: &Path) -> bool {
        self.0.contains(path)
    }
}

/// One call of the compiler: its sources, include directory and output.
#[derive(Debug, PartialEq, Eq)]
struct Compiled {
    sources: Vec<PathBuf>,
    include: PathBuf,
    output: PathBuf,
}

/// Records each call, and fails the ones whose output is in `failing`,
/// with that output's text.
#[derive(Default)]
struct FakeCompile {
    calls: RefCell<Vec<Compiled>>,
    failing: BTreeMap<PathBuf, String>,
}

impl FakeCompile {
    fn failing(output: &str, text: &str) -> Self {
        Self {
            calls: RefCell::default(),
            failing: BTreeMap::from([(PathBuf::from(output), text.to_owned())]),
        }
    }
}

impl Compile for FakeCompile {
    fn compile(&self, sources: &[PathBuf], include: &Path, output: &Path) -> Result<(), String> {
        self.calls.borrow_mut().push(Compiled {
            sources: sources.to_vec(),
            include: include.to_owned(),
            output: output.to_owned(),
        });
        match self.failing.get(output) {
            Some(text) => Err(text.clone()),
            None => Ok(()),
        }
    }
}

fn paths(list: &[&str]) -> Vec<PathBuf> {
    list.iter().map(PathBuf::from).collect()
}

#[test]
fn a_grammar_with_a_parser_alone_compiles_its_parser_into_the_library_named_after_it() {
    let compile = FakeCompile::default();
    let report = build_with(
        &[Grammar::directory("tiny", "/g/tiny")],
        &FakeLocate::new(&[]),
        &FakeTree::of(&["/g/tiny/src/parser.c"]),
        &compile,
        Path::new("/out"),
        "linux",
    );
    assert_eq!(
        compile.calls.into_inner(),
        vec![Compiled {
            sources: paths(&["/g/tiny/src/parser.c"]),
            include: PathBuf::from("/g/tiny/src"),
            output: PathBuf::from("/out/libtree-sitter-tiny.so"),
        }]
    );
    assert_eq!(report.lines(), "built\ttiny\t/out/libtree-sitter-tiny.so\n");
    assert_eq!(report.watched, paths(&["/g/tiny/src"]));
}

#[test]
fn a_grammar_with_a_scanner_compiles_its_parser_and_its_scanner() {
    let compile = FakeCompile::default();
    let report = build_with(
        &[Grammar::package("yaml", "tree-sitter-yaml")],
        &FakeLocate::new(&[("tree-sitter-yaml", "/r/tree-sitter-yaml-0.7.2")]),
        &FakeTree::of(&[
            "/r/tree-sitter-yaml-0.7.2/src/parser.c",
            "/r/tree-sitter-yaml-0.7.2/src/scanner.c",
        ]),
        &compile,
        Path::new("/out"),
        "macos",
    );
    assert_eq!(
        compile.calls.into_inner(),
        vec![Compiled {
            sources: paths(&[
                "/r/tree-sitter-yaml-0.7.2/src/parser.c",
                "/r/tree-sitter-yaml-0.7.2/src/scanner.c",
            ]),
            include: PathBuf::from("/r/tree-sitter-yaml-0.7.2/src"),
            output: PathBuf::from("/out/libtree-sitter-yaml.dylib"),
        }]
    );
    assert_eq!(
        report.lines(),
        "built\tyaml\t/out/libtree-sitter-yaml.dylib\n"
    );
}

#[test]
fn a_cpp_scanner_is_refused_naming_the_grammar_and_nothing_is_compiled() {
    let compile = FakeCompile::default();
    let report = build_with(
        &[Grammar::directory("cpp", "/g/cpp")],
        &FakeLocate::new(&[]),
        &FakeTree::of(&["/g/cpp/src/parser.c", "/g/cpp/src/scanner.cc"]),
        &compile,
        Path::new("/out"),
        "linux",
    );
    assert!(compile.calls.into_inner().is_empty());
    assert_eq!(
        report.lines(),
        "failed\tcpp\tthe grammar `cpp` has a C++ scanner (/g/cpp/src/scanner.cc), which is not supported: a grammar's scanner is compiled as C\n"
    );
}

#[test]
fn a_source_with_no_parser_is_refused_naming_the_grammar() {
    let compile = FakeCompile::default();
    let report = build_with(
        &[Grammar::directory("empty", "/g/empty")],
        &FakeLocate::new(&[]),
        &FakeTree::of(&[]),
        &compile,
        Path::new("/out"),
        "linux",
    );
    assert!(compile.calls.into_inner().is_empty());
    assert_eq!(
        report.lines(),
        "failed\tempty\tthe grammar `empty`'s source has no src/parser.c (/g/empty/src/parser.c)\n"
    );
}

#[test]
fn a_package_that_is_no_dependency_fails_naming_the_grammar_and_the_package() {
    let compile = FakeCompile::default();
    let report = build_with(
        &[Grammar::package("yaml", "tree-sitter-yml")],
        &FakeLocate::new(&[("tree-sitter-yaml", "/r/tree-sitter-yaml-0.7.2")]),
        &FakeTree::of(&[]),
        &compile,
        Path::new("/out"),
        "linux",
    );
    assert!(compile.calls.into_inner().is_empty());
    assert_eq!(
        report.lines(),
        "failed\tyaml\t`tree-sitter-yml` is not a dependency of `grammar-sources`: a grammar's package is a build-dependency of the crate that builds it\n"
    );
}

#[test]
fn a_grammar_that_fails_to_compile_still_lets_the_next_one_build() {
    let compile = FakeCompile::failing(
        "/out/libtree-sitter-broken.so",
        "broken/src/parser.c:1:2: error: \"no\"\n1 error generated.\n",
    );
    let report = build_with(
        &[
            Grammar::directory("broken", "/g/broken"),
            Grammar::directory("tiny", "/g/tiny"),
        ],
        &FakeLocate::new(&[]),
        &FakeTree::of(&["/g/broken/src/parser.c", "/g/tiny/src/parser.c"]),
        &compile,
        Path::new("/out"),
        "linux",
    );
    assert_eq!(compile.calls.into_inner().len(), 2);
    assert_eq!(
        report.lines(),
        "failed\tbroken\tthe C compiler failed: broken/src/parser.c:1:2: error: \"no\"\nbuilt\ttiny\t/out/libtree-sitter-tiny.so\n"
    );
    assert_eq!(
        report.stderr(),
        "the grammar `broken`'s compile:\nbroken/src/parser.c:1:2: error: \"no\"\n1 error generated.\n"
    );
}

#[test]
fn the_compiler_failure_names_the_first_error_line_or_the_first_line() {
    assert_eq!(
        compiler_failure("In file included from x.c:1:\nx.h:2:3: error: bad\n"),
        "the C compiler failed: x.h:2:3: error: bad"
    );
    assert_eq!(
        compiler_failure("ld: symbol(s) not found\n"),
        "the C compiler failed: ld: symbol(s) not found"
    );
    assert_eq!(
        compiler_failure(""),
        "the C compiler failed, and said nothing"
    );
}

#[test]
fn a_line_keeps_to_one_line_and_three_fields() {
    let report = Report {
        outcomes: vec![Outcome::Failed {
            name: "x".to_owned(),
            reason: "a\tb\nc".to_owned(),
            output: None,
        }],
        watched: Vec::new(),
    };
    assert_eq!(report.lines(), "failed\tx\ta b c\n");
    assert_eq!(report.stderr(), "");
}

#[test]
fn the_library_is_a_dylib_on_macos_and_a_so_elsewhere() {
    assert_eq!(
        library_file_name("yaml", "macos"),
        "libtree-sitter-yaml.dylib"
    );
    assert_eq!(library_file_name("yaml", "linux"), "libtree-sitter-yaml.so");
    assert_eq!(
        library_file_name("c_sharp", "freebsd"),
        "libtree-sitter-c_sharp.so"
    );
}

#[test]
fn a_name_outside_lowercase_letters_digits_and_underscores_is_refused() {
    for name in ["", "Yaml", "c-sharp", "a b", "../x"] {
        let compile = FakeCompile::default();
        let report = build_with(
            &[Grammar::directory(name, "/g/x")],
            &FakeLocate::new(&[]),
            &FakeTree::of(&["/g/x/src/parser.c"]),
            &compile,
            Path::new("/out"),
            "linux",
        );
        assert!(compile.calls.into_inner().is_empty(), "{name:?}");
        assert_eq!(
            report.lines(),
            format!(
                "failed\t{}\tthe grammar name `{name}` is not one a symbol `tree_sitter_<name>` can carry: a grammar's name is lowercase letters, digits and underscores\n",
                one_line(name)
            ),
            "{name:?}"
        );
    }
    assert!(is_grammar_name("c_sharp2"));
}

#[test]
fn a_grammar_in_a_subdirectory_of_a_located_package_is_compiled_from_that_subdirectorys_src() {
    let compile = FakeCompile::default();
    let report = build_with(
        &[Grammar::package_in(
            "markdown_inline",
            "tree-sitter-md",
            "tree-sitter-markdown-inline",
        )],
        &FakeLocate::new(&[("tree-sitter-md", "/r/tree-sitter-md-0.5.4")]),
        &FakeTree::of(&[
            "/r/tree-sitter-md-0.5.4/tree-sitter-markdown-inline/src/parser.c",
            "/r/tree-sitter-md-0.5.4/tree-sitter-markdown-inline/src/scanner.c",
        ]),
        &compile,
        Path::new("/out"),
        "linux",
    );
    assert_eq!(
        compile.calls.into_inner(),
        vec![Compiled {
            sources: paths(&[
                "/r/tree-sitter-md-0.5.4/tree-sitter-markdown-inline/src/parser.c",
                "/r/tree-sitter-md-0.5.4/tree-sitter-markdown-inline/src/scanner.c",
            ]),
            include: PathBuf::from("/r/tree-sitter-md-0.5.4/tree-sitter-markdown-inline/src"),
            output: PathBuf::from("/out/libtree-sitter-markdown_inline.so"),
        }]
    );
    assert_eq!(
        report.watched,
        paths(&["/r/tree-sitter-md-0.5.4/tree-sitter-markdown-inline/src"])
    );
}

#[test]
fn a_built_outcome_names_the_grammars_source_directory() {
    let report = build_with(
        &[
            Grammar::package("yaml", "tree-sitter-yaml"),
            Grammar::package_in("markdown", "tree-sitter-md", "tree-sitter-markdown"),
        ],
        &FakeLocate::new(&[
            ("tree-sitter-yaml", "/r/tree-sitter-yaml-0.7.2"),
            ("tree-sitter-md", "/r/tree-sitter-md-0.5.4"),
        ]),
        &FakeTree::of(&[
            "/r/tree-sitter-yaml-0.7.2/src/parser.c",
            "/r/tree-sitter-md-0.5.4/tree-sitter-markdown/src/parser.c",
        ]),
        &FakeCompile::default(),
        Path::new("/out"),
        "linux",
    );
    assert_eq!(
        report.outcomes,
        vec![
            Outcome::Built {
                name: "yaml".to_owned(),
                library: PathBuf::from("/out/libtree-sitter-yaml.so"),
                source: PathBuf::from("/r/tree-sitter-yaml-0.7.2"),
            },
            Outcome::Built {
                name: "markdown".to_owned(),
                library: PathBuf::from("/out/libtree-sitter-markdown.so"),
                source: PathBuf::from("/r/tree-sitter-md-0.5.4/tree-sitter-markdown"),
            },
        ]
    );
    assert_eq!(
        report.lines(),
        "built\tyaml\t/out/libtree-sitter-yaml.so\nbuilt\tmarkdown\t/out/libtree-sitter-markdown.so\n"
    );
}
