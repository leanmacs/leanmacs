//! The clipboard port's real adapter: [`SystemClipboard`], a
//! [`Clipboard`] over arboard.
//!
//! The port, its fake and its contract are `editor-platform`'s
//! (`editor_platform::clipboard`). This crate is thin: it keeps one
//! clipboard of arboard's for as long as it lives, forwards a read and a
//! write to it, and turns arboard's answers into the port's. No arboard
//! type is public, and no other crate depends on arboard (`deny.toml`).
//!
//! What it decides:
//!
//! - **A clipboard that holds no text reads as no text.** arboard answers a
//!   read of an empty clipboard, and of one that holds something that is
//!   not text, with an error of its own; that is the port's `None`. Every
//!   other error of arboard's is a failure, in arboard's words: its error
//!   type grows, and what it adds is a failure until it is given a meaning
//!   here.
//! - **One clipboard of arboard's is kept**, behind a lock. On Linux the
//!   text on the clipboard is served by the process that wrote it, from a
//!   thread arboard runs, for as long as arboard's clipboard lives: one made
//!   and dropped for each write would leave nothing to paste. So text
//!   written here is on the clipboard until this adapter is dropped or
//!   another program writes, and on X11 with no clipboard manager it is
//!   gone when the process ends.
//! - **An open that panics is a failure.** On Linux arboard's open starts
//!   that thread with `std::thread::spawn`, which panics when the system
//!   refuses a thread. The panic is caught and the open answered with a
//!   failure that says what the panic said, so the C function that opens
//!   the desktop's clipboard (`editor_ffi_clipboard_system`) keeps its
//!   rule that it never panics. A read or a write starts no thread.
//!
//! # Tests
//!
//! The gate (`mise run ci`) reads and writes no clipboard: a real one is
//! the desktop's, and a test leaves the machine as it found it. What it
//! covers here is how arboard's answers become the port's, on values built
//! in the tests. [`SystemClipboard::open`] is forbidden to tests by the
//! root `clippy.toml`.

use std::panic;
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::thread;

use editor_platform::clipboard::{Clipboard, ClipboardError};

/// The system clipboard, over arboard.
pub struct SystemClipboard {
    /// arboard's clipboard, kept for as long as this lives.
    clipboard: Mutex<arboard::Clipboard>,
}

impl SystemClipboard {
    /// The clipboard of the desktop this process runs on, or why it cannot
    /// be reached: no display, or on Linux a session with no X server.
    ///
    /// What it finds is the desktop's own, so no test calls it: the root
    /// `clippy.toml` forbids it to them.
    ///
    /// It does not panic. arboard's open does, on Linux, when the system
    /// refuses the thread that serves the clipboard; that is a failure
    /// here (`open_answer`).
    pub fn open() -> Result<Self, ClipboardError> {
        #[expect(
            clippy::disallowed_methods,
            reason = "this is the one place the system clipboard is opened"
        )]
        let opened = panic::catch_unwind(arboard::Clipboard::new);
        open_answer(opened).map(|clipboard| Self {
            clipboard: Mutex::new(clipboard),
        })
    }

    /// Locks arboard's clipboard. A poisoned lock is used as it is: the
    /// clipboard is arboard's to keep whole.
    fn clipboard(&self) -> MutexGuard<'_, arboard::Clipboard> {
        self.clipboard
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }
}

impl Clipboard for SystemClipboard {
    fn read(&self) -> Result<Option<String>, ClipboardError> {
        read_answer(self.clipboard().get_text())
    }

    fn write(&self, text: &str) -> Result<(), ClipboardError> {
        write_answer(self.clipboard().set_text(text))
    }
}

/// What the port answers a read with, from what arboard answered.
fn read_answer(answer: Result<String, arboard::Error>) -> Result<Option<String>, ClipboardError> {
    match answer {
        Ok(text) => Ok(Some(text)),
        Err(arboard::Error::ContentNotAvailable) => Ok(None),
        Err(error) => Err(failure(&error)),
    }
}

/// What the port answers an open with, from how arboard's open ended: its
/// clipboard; its error, in its words; or a panic, which is a failure that
/// says so and what the panic said, when it said it in text.
fn open_answer<C>(opened: thread::Result<Result<C, arboard::Error>>) -> Result<C, ClipboardError> {
    match opened {
        Ok(answer) => answer.map_err(|error| failure(&error)),
        Err(payload) => {
            let said = payload
                .downcast_ref::<String>()
                .map(String::as_str)
                .or_else(|| payload.downcast_ref::<&str>().copied());
            let reason = match said {
                Some(said) => {
                    format!("the clipboard could not be opened: arboard panicked: {said}")
                }
                None => "the clipboard could not be opened: arboard panicked".to_owned(),
            };
            Err(ClipboardError { reason })
        }
    }
}

/// What the port answers a write with, from what arboard answered.
fn write_answer(answer: Result<(), arboard::Error>) -> Result<(), ClipboardError> {
    answer.map_err(|error| failure(&error))
}

/// arboard's error as the port's failure, in arboard's words.
fn failure(error: &arboard::Error) -> ClipboardError {
    ClipboardError {
        reason: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::any::Any;

    use super::{failure, open_answer, read_answer, write_answer};
    use editor_platform::clipboard::ClipboardError;

    /// The port's failure with `reason`.
    fn failed(reason: &str) -> ClipboardError {
        ClipboardError {
            reason: reason.into(),
        }
    }

    /// arboard's words for a clipboard another program holds.
    const OCCUPIED: &str =
        "The native clipboard is not accessible due to being held by another party.";

    #[test]
    fn text_arboard_read_is_the_text() {
        assert_eq!(
            read_answer(Ok("café\n\ttab".into())),
            Ok(Some("café\n\ttab".into()))
        );
        // The empty text is text.
        assert_eq!(read_answer(Ok(String::new())), Ok(Some(String::new())));
    }

    #[test]
    fn a_clipboard_with_no_text_reads_as_none_and_not_as_a_failure() {
        assert_eq!(
            read_answer(Err(arboard::Error::ContentNotAvailable)),
            Ok(None)
        );
    }

    #[test]
    fn any_other_error_of_a_read_is_a_failure_in_arboards_words() {
        assert_eq!(
            read_answer(Err(arboard::Error::ClipboardOccupied)),
            Err(failed(OCCUPIED))
        );
        assert_eq!(
            read_answer(Err(arboard::Error::Unknown {
                description: "the X server went away".into()
            })),
            Err(failed(
                "Unknown error while interacting with the clipboard: the X server went away"
            ))
        );
        for error in [
            arboard::Error::ClipboardNotSupported,
            arboard::Error::ConversionFailure,
        ] {
            let reason = error.to_string();
            assert_eq!(read_answer(Err(error)), Err(failed(&reason)));
        }
    }

    #[test]
    fn a_write_arboard_made_is_made_and_one_it_refused_is_a_failure_in_its_words() {
        assert_eq!(write_answer(Ok(())), Ok(()));
        assert_eq!(
            write_answer(Err(arboard::Error::ClipboardOccupied)),
            Err(failed(OCCUPIED))
        );
        // No error of a write means "nothing there": each is a failure.
        let reason = arboard::Error::ContentNotAvailable.to_string();
        assert_eq!(
            write_answer(Err(arboard::Error::ContentNotAvailable)),
            Err(failed(&reason))
        );
    }

    #[test]
    fn an_open_that_panicked_is_a_failure_that_says_so_and_what_it_said() {
        // On Linux arboard's open starts the thread that serves the
        // clipboard, and panics when the system refuses it one. The payload
        // of such a panic, a `String` or a `&str`, is built here: nothing
        // panics in the test.
        let said: Box<dyn Any + Send> = Box::new(String::from("failed to spawn thread"));
        assert_eq!(
            open_answer::<()>(Err(said)),
            Err(failed(
                "the clipboard could not be opened: arboard panicked: failed to spawn thread"
            ))
        );
        let said: Box<dyn Any + Send> = Box::new("no more threads");
        assert_eq!(
            open_answer::<()>(Err(said)),
            Err(failed(
                "the clipboard could not be opened: arboard panicked: no more threads"
            ))
        );
        let said: Box<dyn Any + Send> = Box::new(7_u8);
        assert_eq!(
            open_answer::<()>(Err(said)),
            Err(failed(
                "the clipboard could not be opened: arboard panicked"
            ))
        );
        // An open that returned is answered as it returned.
        assert_eq!(open_answer(Ok(Ok(()))), Ok(()));
        assert_eq!(
            open_answer::<()>(Ok(Err(arboard::Error::ClipboardOccupied))),
            Err(failed(OCCUPIED))
        );
    }

    #[test]
    fn a_clipboard_that_cannot_be_opened_fails_in_arboards_words() {
        // What `open` answers when arboard makes no clipboard: on Linux,
        // arboard's words for a session with no X server.
        assert_eq!(
            failure(&arboard::Error::Unknown {
                description: "X11 server connection timed out".into()
            }),
            failed(
                "Unknown error while interacting with the clipboard: X11 server connection timed out"
            )
        );
        assert_eq!(
            failure(&arboard::Error::ClipboardNotSupported).reason,
            arboard::Error::ClipboardNotSupported.to_string()
        );
    }
}
