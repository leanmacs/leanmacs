//! Properties of kept inverses: each drives a
//! [`Text`](editor_text::Text) with generated transactions, which carry
//! generated selections, and inverses of generated runs, and compares it
//! with the strings the text held at every revision, kept beside it.

use editor_text::{
    Anchor, InverseError, Inverted, Marker, MarkerId, Origin, Revision, Selection, Text,
    Transaction,
};
use proptest::collection::vec;
use proptest::option;
use proptest::prelude::*;
use proptest::test_runner::TestCaseError;

use crate::anchors::bias;
use crate::selections::{Parts, parts};
use crate::{Walk, applied, check, floor, initial_text_to_walk, walk};

/// One generated step, before it is fitted to a text.
#[derive(Debug, Clone)]
enum Step {
    /// A transaction.
    Edit {
        /// What it does.
        walk: Walk,
        /// The selection before it, if it carries one.
        before: Option<Parts>,
        /// The selection after it, if it carries one.
        after: Option<Parts>,
    },
    /// The inverse of a run.
    Inverse(Run),
    /// A drop of the kept inverses of a run.
    Drop(Run),
}

/// A generated run of revisions, before it is fitted to a text.
#[derive(Debug, Clone)]
struct Run {
    /// Whether the run ends at the text's revision. Otherwise `last` says
    /// where.
    ends_now: bool,
    /// The run's last revision, as a number to cut down to the text's
    /// revision and one past it.
    last: usize,
    /// How many revisions before its last the run starts.
    back: usize,
    /// The run's first revision, as a number to cut down likewise, for a
    /// run that starts anywhere.
    first: Option<usize>,
}

impl Run {
    /// The first and the last revision of this run for a text at the
    /// revision `current`. One may be a revision the text has not reached,
    /// the first may be 0, and the first may be after the last.
    fn ends(&self, current: usize) -> (usize, usize) {
        let last = if self.ends_now {
            current
        } else {
            self.last % (current + 2)
        };
        let first = match self.first {
            Some(first) => first % (current + 2),
            None => last.saturating_sub(self.back),
        };
        (first, last)
    }
}

/// A run: three in four end at the text's revision, and seven in eight
/// start at most three revisions before they end.
fn run() -> impl Strategy<Value = Run> {
    (
        prop::bool::weighted(0.75),
        any::<usize>(),
        0..4_usize,
        option::weighted(0.125, any::<usize>()),
    )
        .prop_map(|(ends_now, last, back, first)| Run {
            ends_now,
            last,
            back,
            first,
        })
}

/// Up to `steps` steps: as many inverses as transactions, one drop for
/// every four of each, and two transactions in three carry each
/// selection.
fn steps(steps: usize) -> impl Strategy<Value = Vec<Step>> {
    let selection = || option::weighted(0.67, parts(3, usize::MAX));
    let step = prop_oneof![
        4 => (walk(), selection(), selection()).prop_map(|(walk, before, after)| Step::Edit {
            walk,
            before,
            after
        }),
        4 => run().prop_map(Step::Inverse),
        1 => run().prop_map(Step::Drop),
    ];
    vec(step, 0..=steps)
}

/// The selection of `parts` with every end moved onto a position of
/// `reference`.
fn fitted(parts: &Parts, reference: &str) -> Selection {
    let mut parts = parts.clone();
    for (anchor, head) in &mut parts.ranges {
        *anchor = floor(reference, *anchor % (reference.len() + 1));
        *head = floor(reference, *head % (reference.len() + 1));
    }
    parts.selection()
}

/// What is kept beside a text: everything about each of its revisions,
/// which are the indices.
#[derive(Debug, Clone)]
struct History {
    /// What the text held.
    strings: Vec<String>,
    /// The name of the state the text was in: the revision of the
    /// transaction that first put it there. A transaction names a new
    /// state, and the inverse of a run copies the name the text had
    /// before the run.
    names: Vec<usize>,
    /// The selection before and the selection after that the transaction
    /// that produced the revision carried. For an inverse, what the run's
    /// last transaction carried after and its first before.
    carried: Vec<(Option<Selection>, Option<Selection>)>,
    /// Whether the revision's kept inverse was dropped.
    dropped: Vec<bool>,
}

impl History {
    /// The history of a text made holding `initial`.
    fn of(initial: String) -> Self {
        Self {
            strings: vec![initial],
            names: vec![0],
            carried: vec![(None, None)],
            dropped: vec![false],
        }
    }

    /// Whether the run from `first` to `last`, which the text has reached,
    /// has a revision whose kept inverse was dropped.
    fn touches_a_drop(&self, first: usize, last: usize) -> bool {
        (first..=last).any(|revision| self.dropped[revision])
    }

    /// Whether a drop of the run from `first` to `last` is to be accepted,
    /// and records it if so.
    fn drop_run(&mut self, first: usize, last: usize) -> Result<(), InverseError> {
        if last > self.current() {
            return Err(InverseError::UnknownRevision);
        }
        for revision in first..=last {
            self.dropped[revision] = true;
        }
        Ok(())
    }

    /// The revision the text is at.
    fn current(&self) -> usize {
        self.strings.len() - 1
    }

    /// What the text holds.
    fn string(&self) -> &str {
        &self.strings[self.current()]
    }

    /// Whether the inverse of the run from `first` to `last` is to be
    /// accepted, by what was dropped and the names of the states.
    fn expected(&self, first: usize, last: usize) -> Result<(), InverseError> {
        let current = self.current();
        if first > current || last > current {
            Err(InverseError::UnknownRevision)
        } else if first == 0 || first > last || self.touches_a_drop(first, last) {
            Err(InverseError::NotKept)
        } else if self.names[current] != self.names[last] {
            Err(InverseError::NotInState)
        } else {
            Ok(())
        }
    }

    /// Records a transaction that made `string` and carried `carried`.
    fn edited(&mut self, string: String, carried: (Option<Selection>, Option<Selection>)) {
        self.names.push(self.strings.len());
        self.strings.push(string);
        self.carried.push(carried);
        self.dropped.push(false);
    }

    /// Records the inverse of the run from `first` to `last`, which the
    /// text has reached and which starts after revision 0.
    fn inverted(&mut self, first: usize, last: usize) {
        self.strings.push(self.strings[first - 1].clone());
        self.names.push(self.names[first - 1]);
        let carried = (self.carried[last].1.clone(), self.carried[first].0.clone());
        self.carried.push(carried);
        self.dropped.push(false);
    }
}

/// One request for an inverse, and what came of it.
struct Asked<'a> {
    /// The history as it was before the request.
    history: &'a History,
    /// The run's first revision.
    first: usize,
    /// The run's last revision.
    last: usize,
    /// What the text answered.
    result: &'a Result<Inverted, InverseError>,
    /// The text after the request.
    text: &'a Text,
}

/// Applies `steps` to `text`, which holds `initial`, keeping a history
/// beside it, and runs `law` on every request for an inverse and `each`
/// on the text after every step. Whatever the laws say, after every step
/// the text must hold what the history says it holds, at its revision.
fn along(
    text: &mut Text,
    initial: String,
    steps: &[Step],
    law: impl Fn(Asked<'_>) -> Result<(), TestCaseError>,
    each: impl Fn(&Text, &str) -> Result<(), TestCaseError>,
) -> Result<(), TestCaseError> {
    let mut history = History::of(initial);
    for step in steps {
        match step {
            Step::Edit {
                walk,
                before,
                after,
            } => {
                let reference = history.string();
                let changes = walk.changes(reference);
                let made = applied(&changes, reference);
                let before = before.as_ref().map(|parts| fitted(parts, reference));
                // Fitted to the text the changes make, where they make
                // one: a refused change set is refused whatever it carries.
                let after = after
                    .as_ref()
                    .map(|parts| fitted(parts, made.as_deref().unwrap_or(reference)));
                let mut transaction = Transaction::new(changes);
                if let Some(selection) = &before {
                    transaction = transaction.with_before(selection.clone());
                }
                if let Some(selection) = &after {
                    transaction = transaction.with_after(selection.clone());
                }

                let result = text.apply(&transaction, Origin::new(1));

                prop_assert_eq!(result.is_ok(), made.is_some());
                if let Some(made) = made {
                    history.edited(made, (before, after));
                }
            }
            Step::Inverse(run) => {
                let (first, last) = run.ends(history.current());

                let result = text.apply_inverse(
                    Revision::new(first as u64),
                    Revision::new(last as u64),
                    Origin::new(2),
                );

                law(Asked {
                    history: &history,
                    first,
                    last,
                    result: &result,
                    text,
                })?;
                if result.is_ok() {
                    prop_assert!(
                        1 <= first && first <= last && last <= history.current(),
                        "the inverse of {}..={} was accepted at revision {}",
                        first,
                        last,
                        history.current()
                    );
                    history.inverted(first, last);
                }
            }
            Step::Drop(run) => {
                let (first, last) = run.ends(history.current());

                let result =
                    text.drop_inverses(Revision::new(first as u64), Revision::new(last as u64));

                prop_assert_eq!(
                    result,
                    history.drop_run(first, last),
                    "a drop of {}..={}",
                    first,
                    last
                );
            }
        }
        prop_assert_eq!(&text.current().to_string(), history.string());
        prop_assert_eq!(text.current().revision().get(), history.current() as u64);
        each(text, history.string())?;
    }
    Ok(())
}

/// [`along`] for a text that is made here and holds no marker.
fn along_inverses(
    (initial, steps): (String, Vec<Step>),
    law: impl Fn(Asked<'_>) -> Result<(), TestCaseError>,
) -> Result<(), TestCaseError> {
    let mut text = Text::from(initial.as_str());
    along(&mut text, initial, &steps, law, |_, _| Ok(()))
}

/// A text, and the steps to take on it.
fn text_and_steps() -> impl Strategy<Value = (String, Vec<Step>)> {
    (initial_text_to_walk(), steps(24))
}

#[test]
fn an_inverse_is_accepted_only_where_its_run_ended_and_restores_the_text_before_it() {
    check(512, text_and_steps(), |case| {
        along_inverses(case, |asked| {
            let history = asked.history;
            let current = history.current();
            let now = asked.text.current();
            match asked.result {
                Ok(inverted) => {
                    // The text held what it held at the run's last
                    // revision, and now holds what it held before the
                    // run's first.
                    prop_assert!(1 <= asked.first && asked.last <= current);
                    prop_assert_eq!(history.string(), &history.strings[asked.last]);
                    prop_assert_eq!(&now.to_string(), &history.strings[asked.first - 1]);
                    prop_assert_eq!(inverted.revision.get(), current as u64 + 1);
                    prop_assert_eq!(now.revision(), inverted.revision);
                }
                Err(_) => {
                    prop_assert_eq!(&now.to_string(), history.string());
                    prop_assert_eq!(now.revision().get(), current as u64);
                    // A run that ends at the text's revision ended where
                    // the text is, so its inverse is never refused while
                    // all of it is kept.
                    let ends_now =
                        asked.last == current && 1 <= asked.first && asked.first <= asked.last;
                    prop_assert!(
                        !(ends_now && !history.touches_a_drop(asked.first, asked.last)),
                        "the inverse of {}..={} was refused at revision {}",
                        asked.first,
                        asked.last,
                        current
                    );
                }
            }
            Ok(())
        })
    });
}

#[test]
fn an_inverse_is_accepted_wherever_the_text_is_back_where_its_run_ended() {
    check(512, text_and_steps(), |case| {
        along_inverses(case, |asked| {
            let answered = asked.result.as_ref().map(|_| ()).map_err(|error| *error);
            prop_assert_eq!(
                answered,
                asked.history.expected(asked.first, asked.last),
                "the inverse of {}..={} at revision {}",
                asked.first,
                asked.last,
                asked.history.current()
            );
            Ok(())
        })
    });
}

#[test]
fn a_run_that_touches_a_dropped_revision_is_refused_as_not_kept() {
    check(512, text_and_steps(), |case| {
        along_inverses(case, |asked| {
            let (first, last) = (asked.first, asked.last);
            // Of the runs the text has reached, whatever state it is in.
            if last <= asked.history.current()
                && first <= last
                && asked.history.touches_a_drop(first, last)
            {
                prop_assert_eq!(
                    asked.result.as_ref().err(),
                    Some(&InverseError::NotKept),
                    "the inverse of {}..={}",
                    first,
                    last
                );
            }
            Ok(())
        })
    });
}

#[test]
fn the_selection_handed_back_is_the_one_the_runs_first_transaction_carried() {
    check(512, text_and_steps(), |case| {
        along_inverses(case, |asked| {
            let Ok(inverted) = asked.result else {
                return Ok(());
            };
            prop_assert_eq!(&inverted.selection, &asked.history.carried[asked.first].0);
            // It is at positions of the text the inverse left.
            let now = asked.text.current();
            for range in inverted.selection.iter().flat_map(Selection::ranges) {
                prop_assert!(now.is_char_boundary(range.anchor), "{:?}", range);
                prop_assert!(now.is_char_boundary(range.head), "{:?}", range);
            }
            Ok(())
        })
    });
}

#[test]
fn a_marker_held_through_inverses_is_always_at_a_position() {
    let marks = (
        vec((any::<usize>(), bias()), 0..=6),
        vec(parts(3, usize::MAX), 0..=3),
    );
    check(
        256,
        (text_and_steps(), marks),
        |((initial, steps), (anchors, selections))| {
            let mut text = Text::from(initial.as_str());
            let mut ids: Vec<MarkerId> = Vec::new();
            for (pick, bias) in anchors {
                let offset = floor(&initial, pick % (initial.len() + 1));
                let anchor: Anchor = Anchor::new(offset, bias);
                ids.extend(text.mark(Marker::Anchor(anchor)));
            }
            for parts in &selections {
                ids.extend(text.mark(Marker::Selection(fitted(parts, &initial))));
            }
            let marked = ids.len();
            along(
                &mut text,
                initial,
                &steps,
                |_| Ok(()),
                |text, string| {
                    let held: Vec<&Marker> = ids.iter().filter_map(|&id| text.marker(id)).collect();
                    prop_assert_eq!(held.len(), marked);
                    for marker in held {
                        let ends: Vec<usize> = match marker {
                            Marker::Anchor(anchor) => vec![anchor.offset],
                            Marker::Selection(selection) => selection
                                .ranges()
                                .iter()
                                .flat_map(|range| [range.anchor, range.head])
                                .collect(),
                        };
                        for end in ends {
                            prop_assert!(string.is_char_boundary(end), "{:?}", marker);
                        }
                    }
                    Ok(())
                },
            )
        },
    );
}
