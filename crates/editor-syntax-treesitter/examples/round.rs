//! Times the syntax rounds on one file, over the real adapter (`mise run
//! syntax-bench`, on the largest Lean file).
//!
//! On demand, never in the gate: what it prints is a measurement of this
//! machine, and it asserts nothing. The gate builds it (`clippy
//! --all-targets`, `cargo test`), so it keeps compiling, and never runs it.
//! Its figures are recorded in `docs/design/rust-library.md`, "Syntax, as
//! built", dated, beside the Rust measurement.
//!
//! Its arguments are a path and a grammar name, one of the six
//! `editor-syntax-fixture-grammars` builds, which it registers from its
//! native library with its policy. It reads the file into an
//! `editor_text::Text` behind a lock, as a document holds one, and opens a
//! session of the grammar over it. It prints the file's bytes and lines,
//! the grammar's reparse policy and its tree's error nodes, then times:
//!
//! - the first parse, a whole one;
//! - 20 times, an edit at the first line break after the middle (an `x`
//!   put in, then taken out, in turn), then **a round after the edit**
//!   (`Session::parse_once`, what the worker runs after a touch) and **the
//!   idle refresh** (`Session::refresh_once`: a whole parse and its compare
//!   with the round's tree, what the worker runs once the text is quiet).
//!
//! It prints the median, the minimum and the maximum of each. No highlights
//! query and no injections are set: it is the cost of the tree itself.

use std::process::ExitCode;
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use editor_wait::Stopwatch;

use editor_syntax::{GrammarName, GrammarSource, Latest, ReparsePolicy, Session, Source, Syntax};
use editor_syntax_fixture_grammars as grammars;
use editor_syntax_treesitter::TreeSitter;
use editor_text::{Revision, Text};

/// How many rounds, and refreshes, are timed.
const ROUNDS: usize = 20;

/// A text behind a lock, as a document holds one.
struct TextSource(Weak<Mutex<Text>>);

impl Source for TextSource {
    fn latest(&self, since: Option<Revision>) -> Option<Latest> {
        let text = self.0.upgrade()?;
        let text = text.lock().unwrap_or_else(PoisonError::into_inner);
        Some(Latest {
            snapshot: text.snapshot(),
            patch: since.and_then(|since| text.changes_since(since).ok()),
        })
    }
}

/// Milliseconds, to two places.
fn ms(duration: Duration) -> String {
    format!("{:.2} ms", duration.as_secs_f64() * 1e3)
}

/// Prints the median, the minimum and the maximum of `times`, which is not
/// empty.
fn summary(name: &str, mut times: Vec<Duration>) {
    times.sort();
    println!(
        "{name}: median {}, min {}, max {}, over {}",
        ms(times[times.len() / 2]),
        ms(times[0]),
        ms(times[times.len() - 1]),
        times.len()
    );
}

#[expect(
    clippy::disallowed_methods,
    reason = "an example's entry reads its own command line and the file it names, on demand"
)]
fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let (Some(path), Some(grammar)) = (args.next(), args.next()) else {
        eprintln!("usage: round <path> <grammar>");
        return ExitCode::from(2);
    };
    let source = match std::fs::read_to_string(&path) {
        Ok(source) => source,
        Err(error) => {
            eprintln!("round: cannot read {path}: {error}");
            return ExitCode::FAILURE;
        }
    };
    let Some(fixture) = grammars::ALL
        .into_iter()
        .find(|known| known.name == grammar)
    else {
        eprintln!("round: no fixture grammar {grammar}");
        return ExitCode::FAILURE;
    };
    let grammar = GrammarName::new(grammar);
    let text = Arc::new(Mutex::new(Text::from(source.as_str())));
    let syntax = TreeSitter::default();
    let registered = syntax.register(&GrammarSource {
        library: fixture.library.into(),
        symbol: fixture.symbol.to_owned(),
        policy: Some(if fixture.incremental {
            ReparsePolicy::Incremental
        } else {
            ReparsePolicy::Whole
        }),
    });
    if let Err(refusal) = registered {
        eprintln!("round: {} was refused: {refusal:?}", fixture.library);
        return ExitCode::FAILURE;
    }
    let Some(session) = Session::new(
        &syntax,
        grammar.clone(),
        Box::new(TextSource(Arc::downgrade(&text))),
    ) else {
        eprintln!("round: no grammar {}", grammar.as_str());
        return ExitCode::FAILURE;
    };

    let errors = syntax.parser(&grammar).map_or(0, |mut parser| {
        let snapshot = text
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .snapshot();
        let tree = syntax.parse(&mut parser, &snapshot, None);
        syntax.nodes(&tree).iter().filter(|node| node.error).count()
    });
    println!(
        "{path}: {} bytes, {} lines, grammar {}, policy {:?}, {errors} error nodes",
        source.len(),
        source.lines().count(),
        grammar.as_str(),
        session.policy()
    );

    let start = Stopwatch::start("the first parse");
    session.touch(Revision::new(0));
    session.parse_once(&syntax);
    // real time under test: the first parse's time, printed and never
    // asserted.
    println!("first parse: {}", ms(start.elapsed()));

    let middle = source.len() / 2;
    let at = source.as_bytes()[middle..]
        .iter()
        .position(|&byte| byte == b'\n')
        .map_or(source.len(), |offset| middle + offset);
    let (mut rounds, mut refreshes) = (Vec::new(), Vec::new());
    for round in 0..ROUNDS {
        let revision = {
            let mut text = text.lock().unwrap_or_else(PoisonError::into_inner);
            let edited = if round % 2 == 0 {
                text.replace(at..at, "x")
            } else {
                text.replace(at..at + 1, "")
            };
            if edited.is_err() {
                eprintln!("round: the edit at {at} was refused");
                return ExitCode::FAILURE;
            }
            text.current().revision()
        };
        session.touch(revision);
        let start = Stopwatch::start("a round's parse");
        session.parse_once(&syntax);
        // real time under test: each round's and each refresh's time,
        // printed and never asserted.
        rounds.push(start.elapsed());
        let start = Stopwatch::start("a refresh");
        session.refresh_once(&syntax);
        // real time under test: as above, the refresh's.
        refreshes.push(start.elapsed());
    }
    summary("a round after an edit", rounds);
    summary(
        "the idle refresh (a whole parse and the compare)",
        refreshes,
    );
    ExitCode::SUCCESS
}
