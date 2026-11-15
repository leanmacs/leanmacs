//! The clipboard port: text in and out of the system clipboard, with a fake
//! and a contract.
//!
//! A [`Clipboard`] is what a system clipboard can do, and no more: its text
//! is read, and text is written to it. Which text the editor writes and
//! when, and what a yank or a kill asks of it, are not decided here: that is
//! the clipboard interface in Lean and its model (the command loop's), and
//! this port is the Rust library's seam below it. `editor-platform-arboard`
//! is the real adapter.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Something more a clipboard holds (the primary selection, something that is not text) | An argument of [`Clipboard::read`] and [`Clipboard::write`], as data: which selection, which kind | The fake's tests here, and a property of [`contract`] |
//! | A rule every clipboard keeps | A property of [`contract`] | Its own tests, on the fake and on clipboards written to break it |
//!
//! # Where the real adapter is held to the contract
//!
//! [`MemoryClipboard`] passes [`contract::check`] in this crate's tests, and
//! everything above the port is tested on it; what the code above the port
//! does when a clipboard fails is tested on [`FailingClipboard`]. A real
//! clipboard belongs to
//! the desktop a test runs on, and the gate (`mise run ci`) reads and writes
//! none. The adapter's run of the contract is an example binary of
//! `editor-platform-arboard`, run on demand: `mise run linux-window`, in a
//! container under Xvfb, and `mise run clipboard-contract`, on the desktop
//! it is started from.

use std::error::Error;
use std::fmt;
use std::sync::{Mutex, MutexGuard, PoisonError};

/// Why a clipboard could not be read or written, or could not be reached at
/// all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClipboardError {
    /// The reason, in the clipboard's words.
    pub reason: String,
}

impl fmt::Display for ClipboardError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.reason)
    }
}

impl Error for ClipboardError {}

/// The port: a clipboard that holds text.
///
/// The rules every implementation keeps are [`contract::check`].
pub trait Clipboard {
    /// The text on the clipboard; `None` when it holds none, which is so of
    /// a clipboard that holds nothing and of one that holds something that
    /// is not text.
    fn read(&self) -> Result<Option<String>, ClipboardError>;

    /// Puts `text` on the clipboard, in place of whatever it held.
    fn write(&self, text: &str) -> Result<(), ClipboardError>;
}

/// The fake clipboard: text kept in memory, and never the system's.
///
/// It is public, not `cfg(test)`, so the tests of any crate above the port
/// run on it.
#[derive(Debug, Default)]
pub struct MemoryClipboard {
    /// The text held; `None` until something is written.
    text: Mutex<Option<String>>,
}

impl MemoryClipboard {
    /// A clipboard that holds nothing.
    pub fn new() -> Self {
        Self::default()
    }

    /// Locks the text. The lock is never held while other code runs, so a
    /// poisoned lock still guards a whole value.
    fn text(&self) -> MutexGuard<'_, Option<String>> {
        self.text.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Clipboard for MemoryClipboard {
    fn read(&self) -> Result<Option<String>, ClipboardError> {
        Ok(self.text().clone())
    }

    fn write(&self, text: &str) -> Result<(), ClipboardError> {
        *self.text() = Some(text.to_owned());
        Ok(())
    }
}

/// The failing fake: a clipboard that cannot be reached, whose every read
/// and write fails with the one reason it was made with, and changes
/// nothing.
///
/// It is public, not `cfg(test)`, so a crate above the port tests what it
/// does when the clipboard fails, as a desktop's can (no selection owner,
/// a clipboard held by another program), without a desktop. It keeps none
/// of [`contract::check`]'s properties: it is no clipboard that works.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailingClipboard {
    /// The reason every call fails with.
    reason: String,
}

impl FailingClipboard {
    /// A clipboard whose every call fails with `reason`.
    pub fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }

    /// The failure every call answers.
    fn failure(&self) -> ClipboardError {
        ClipboardError {
            reason: self.reason.clone(),
        }
    }
}

impl Clipboard for FailingClipboard {
    fn read(&self) -> Result<Option<String>, ClipboardError> {
        Err(self.failure())
    }

    fn write(&self, _text: &str) -> Result<(), ClipboardError> {
        Err(self.failure())
    }
}

pub mod contract {
    //! The contract of the clipboard port: the rules every [`Clipboard`]
    //! keeps, as a check that runs one.
    //!
    //! [`check`] reads and writes the clipboard it is given and returns the
    //! names of the properties that fail. It leaves its own text on the
    //! clipboard: a caller that checks a real one keeps what it finds
    //! there first and puts it back.

    use super::Clipboard;

    /// Text written is the text read back.
    pub const ROUND_TRIP: &str = "text written is the text read back";
    /// Non-ASCII text, a line feed and a tab come back unchanged.
    pub const UNCHANGED: &str = "non-ASCII text, a line feed and a tab come back unchanged";
    /// A later write replaces an earlier one.
    pub const REPLACED: &str = "a later write replaces an earlier one";
    /// A clipboard the check has not written to reads as no text or as
    /// text, and does not fail.
    pub const UNWRITTEN: &str =
        "a clipboard not yet written to reads as no text or as text, and does not fail";

    /// Every property, by name.
    pub const PROPERTIES: [&str; 4] = [UNWRITTEN, ROUND_TRIP, UNCHANGED, REPLACED];

    /// Holds `clipboard` to the contract, and returns the names of the
    /// properties that fail: none when it keeps them all.
    pub fn check(clipboard: &impl Clipboard) -> Vec<&'static str> {
        // Whether `text`, written, is what is then read.
        let comes_back = |text: &str| {
            clipboard.write(text).is_ok() && clipboard.read() == Ok(Some(text.to_owned()))
        };
        // The read comes first: after it the check has written.
        let unwritten = clipboard.read().is_ok();
        let round_trip = comes_back("the quick brown fox");
        let unchanged = comes_back(UNUSUAL);
        let replaced = clipboard.write("an earlier text").is_ok() && comes_back("a later text");
        [
            (UNWRITTEN, unwritten),
            (ROUND_TRIP, round_trip),
            (UNCHANGED, unchanged),
            (REPLACED, replaced),
        ]
        .into_iter()
        .filter_map(|(name, holds)| (!holds).then_some(name))
        .collect()
    }

    /// The text of [`UNCHANGED`]: accented Latin, Japanese, a character
    /// outside the basic plane, a line feed and a tab.
    const UNUSUAL: &str = "café 日本語 🦀\nline two\ttab";
}

#[cfg(test)]
mod tests {
    use super::contract::{self, PROPERTIES, REPLACED, ROUND_TRIP, UNCHANGED, UNWRITTEN};
    use super::{Clipboard, ClipboardError, FailingClipboard, MemoryClipboard};
    use std::sync::atomic::{AtomicBool, Ordering};

    #[test]
    fn a_memory_clipboard_never_written_to_holds_no_text() {
        assert_eq!(MemoryClipboard::new().read(), Ok(None));
    }

    #[test]
    fn text_written_to_a_memory_clipboard_is_the_text_read_back_until_it_is_replaced() {
        let clipboard = MemoryClipboard::new();

        assert_eq!(clipboard.write("one"), Ok(()));
        assert_eq!(clipboard.read(), Ok(Some("one".into())));
        // Reading takes nothing away.
        assert_eq!(clipboard.read(), Ok(Some("one".into())));

        assert_eq!(clipboard.write("deux: é\n\t"), Ok(()));
        assert_eq!(clipboard.read(), Ok(Some("deux: é\n\t".into())));

        // The empty text is text: the clipboard holds it.
        assert_eq!(clipboard.write(""), Ok(()));
        assert_eq!(clipboard.read(), Ok(Some(String::new())));
    }

    #[test]
    fn the_contract_holds_of_the_memory_clipboard() {
        assert_eq!(contract::check(&MemoryClipboard::new()), [""; 0]);
        // And of one that held something before the check.
        let written = MemoryClipboard::new();
        written.write("already here").expect("the fake takes text");
        assert_eq!(contract::check(&written), [""; 0]);
    }

    #[test]
    fn the_properties_are_four_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 4);
        for name in [UNWRITTEN, ROUND_TRIP, UNCHANGED, REPLACED] {
            assert!(PROPERTIES.contains(&name), "{name}");
        }
    }

    /// A clipboard that loses the first text written to it, and keeps every
    /// one after: a memory clipboard in everything else.
    #[derive(Default)]
    struct LosesItsFirstWrite {
        /// What it keeps.
        kept: MemoryClipboard,
        /// Whether a write has been lost yet.
        lost: AtomicBool,
    }

    impl Clipboard for LosesItsFirstWrite {
        fn read(&self) -> Result<Option<String>, ClipboardError> {
            self.kept.read()
        }

        fn write(&self, text: &str) -> Result<(), ClipboardError> {
            if self.lost.swap(true, Ordering::SeqCst) {
                self.kept.write(text)
            } else {
                Ok(())
            }
        }
    }

    /// A clipboard that keeps the first of two writes with no read between
    /// them: the second is dropped.
    #[derive(Default)]
    struct KeepsTheFirstOfTwo {
        /// What it keeps.
        kept: MemoryClipboard,
        /// Whether it has been written to since it was last read.
        written: AtomicBool,
    }

    impl Clipboard for KeepsTheFirstOfTwo {
        fn read(&self) -> Result<Option<String>, ClipboardError> {
            self.written.store(false, Ordering::SeqCst);
            self.kept.read()
        }

        fn write(&self, text: &str) -> Result<(), ClipboardError> {
            if self.written.swap(true, Ordering::SeqCst) {
                Ok(())
            } else {
                self.kept.write(text)
            }
        }
    }

    /// A clipboard that keeps ASCII and turns every other character into
    /// `?`.
    #[derive(Default)]
    struct AsciiOnly {
        /// What it keeps.
        kept: MemoryClipboard,
    }

    impl Clipboard for AsciiOnly {
        fn read(&self) -> Result<Option<String>, ClipboardError> {
            self.kept.read()
        }

        fn write(&self, text: &str) -> Result<(), ClipboardError> {
            let ascii: String = text
                .chars()
                .map(|character| if character.is_ascii() { character } else { '?' })
                .collect();
            self.kept.write(&ascii)
        }
    }

    /// A clipboard whose read fails until something has been written to it.
    #[derive(Default)]
    struct FailsWhileEmpty {
        /// What it keeps.
        kept: MemoryClipboard,
    }

    impl Clipboard for FailsWhileEmpty {
        fn read(&self) -> Result<Option<String>, ClipboardError> {
            match self.kept.read()? {
                Some(text) => Ok(Some(text)),
                None => Err(ClipboardError {
                    reason: "nothing is on the clipboard".into(),
                }),
            }
        }

        fn write(&self, text: &str) -> Result<(), ClipboardError> {
            self.kept.write(text)
        }
    }

    #[test]
    fn a_clipboard_that_loses_a_write_fails_the_round_trip_alone() {
        assert_eq!(
            contract::check(&LosesItsFirstWrite::default()),
            [ROUND_TRIP]
        );
    }

    #[test]
    fn a_clipboard_that_keeps_the_first_of_two_writes_fails_replacement_alone() {
        assert_eq!(contract::check(&KeepsTheFirstOfTwo::default()), [REPLACED]);
    }

    #[test]
    fn a_clipboard_that_turns_non_ascii_into_question_marks_fails_unchanged_alone() {
        assert_eq!(contract::check(&AsciiOnly::default()), [UNCHANGED]);
    }

    #[test]
    fn a_clipboard_whose_read_fails_before_a_write_fails_unwritten_alone() {
        assert_eq!(contract::check(&FailsWhileEmpty::default()), [UNWRITTEN]);
    }

    #[test]
    fn a_failing_clipboard_fails_every_read_and_write_with_its_reason_and_fails_unwritten() {
        let clipboard = FailingClipboard::new("pas de presse-papiers");
        let failed = ClipboardError {
            reason: "pas de presse-papiers".into(),
        };
        assert_eq!(clipboard.read(), Err(failed.clone()));
        assert_eq!(clipboard.write("text"), Err(failed.clone()));
        // A write changes nothing: the read after it fails the same way.
        assert_eq!(clipboard.read(), Err(failed));
        // It keeps none of the contract's properties: it stands in for a
        // clipboard that cannot be reached, never for one that works.
        assert_eq!(contract::check(&clipboard), PROPERTIES);
    }

    #[test]
    fn a_clipboard_error_says_its_reason() {
        let error = ClipboardError {
            reason: "the clipboard is held by another".into(),
        };
        assert_eq!(error.to_string(), "the clipboard is held by another");
    }
}
