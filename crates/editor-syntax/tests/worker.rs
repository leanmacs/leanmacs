//! The worker's loop on a real thread, while another thread edits the text
//! and touches the session: what is delivered only moves forward, and the
//! last edit's revision is delivered, its tree equal to a fresh parse.
//!
//! Nothing sleeps. The consumer sends each revision it is handed on a
//! channel, and the test waits on it with a bound.

use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::thread;
use std::time::Duration;

use editor_syntax::fake::{GRAMMAR, Parens, ParensParser};
use editor_syntax::{Consumer, GrammarName, Latest, Parsed, Session, Source, Syntax, Worker};
use editor_text::{Revision, Text};

/// How many edits the test makes.
const EDITS: u64 = 200;

/// The longest the test waits for one delivery.
const BOUND: Duration = Duration::from_secs(10);

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

/// A consumer that checks each revision is newer than the last it was
/// handed, and sends it on.
struct Forward {
    last: Mutex<Option<Revision>>,
    sent: Mutex<Sender<Revision>>,
}

impl<T> Consumer<T> for Forward {
    fn deliver(&self, parsed: &Parsed<T>) {
        let mut last = self.last.lock().unwrap();
        assert!(last.is_none_or(|last| parsed.revision > last));
        *last = Some(parsed.revision);
        self.sent.lock().unwrap().send(parsed.revision).unwrap();
    }
}

#[test]
fn a_worker_on_its_own_thread_delivers_only_newer_revisions_and_ends_at_the_last_edit() {
    let text = Arc::new(Mutex::new(Text::from("(a b)\n")));
    let source = Box::new(TextSource(Arc::downgrade(&text)));
    let session = Arc::new(Session::new(&Parens, GrammarName::new(GRAMMAR), source).unwrap());
    let (sent, received) = mpsc::channel();
    session.subscribe(Box::new(Forward {
        last: Mutex::new(None),
        sent: Mutex::new(sent),
    }));
    let worker = Worker::new(Arc::new(Parens));
    let handle = worker.handle();

    let last = thread::scope(|scope| {
        scope.spawn(|| worker.run());
        handle.touch(&session, Revision::new(0));
        let mut revision = Revision::new(0);
        for edit in 0..EDITS {
            let mut text = text.lock().unwrap();
            let len = text.current().len();
            let piece = ["(x", ")", " y", "\n"][usize::try_from(edit % 4).unwrap()];
            text.replace(len / 2..len / 2, piece).unwrap();
            revision = text.current().revision();
            drop(text);
            handle.touch(&session, revision);
        }
        let mut delivered = Revision::new(0);
        while delivered < revision {
            delivered = received
                .recv_timeout(BOUND)
                .expect("a delivery within the bound");
        }
        handle.stop();
        delivered
    });

    assert_eq!(last, Revision::new(EDITS));
    let snapshot = text.lock().unwrap().snapshot();
    let fresh = Parens.parse(&mut ParensParser, &snapshot, None);
    let parsed = session.parsed().unwrap();
    assert_eq!(parsed.revision, snapshot.revision());
    assert_eq!(Parens.nodes(&parsed.tree), Parens.nodes(&fresh));
}
