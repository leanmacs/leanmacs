//! Taking over a streaming child a Lean job opened through the core's
//! process service, and reading it in Rust: what a package's crate that
//! speaks to a child (an agent's, a language server's) does, as a fixture.
//!
//! It reaches the core's one process service through the package runtime
//! alone ([`RuntimeChild::take_over`], over the runtime's `take_over`,
//! `child_pull`, `child_write` and `child_release`): this crate depends on
//! nothing of the editor's, and `rust/Cargo.toml` says so.
//!
//! [`consume`] is the logic: it pulls the child's lines, writes `pong` back
//! when it reads `ping-me`, and stops at the child's end or a cancel. It is
//! tested on a scripted child of echo's own port (`crate::fakes`).
//! [`Echo::attach`](crate::Echo::attach) runs it as a request of the
//! package's service, on a worker the service owns, and completes the
//! request once it has read to the end; [`attach`] takes the child over
//! and hands it to the process's service, and [`attach_take`] takes what
//! it read: the table's `attach` and `attach_take` ([`crate::ffi::EchoTable`]).

use crate::buffer;
use crate::ffi::{RawReply, loaded};
use crate::port::{ChildStreams, Ended, Frames, Pulled};
use crate::runtime::RuntimeChild;

/// What [`consume`] read of a child: each line, and a last line that says
/// how it ended or that it was cancelled; and how many pulls it took.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Read {
    /// The lines, then `<exited n>`, `<signalled n>`, `<line too long>`,
    /// `<message too long>`, `<failed: …>` or `<cancelled>`.
    pub lines: Vec<String>,
    /// How many pulls it took.
    pub pulls: u32,
}

impl Read {
    /// The lines, joined by line feeds.
    pub fn text(&self) -> String {
        self.lines.join("\n")
    }
}

/// How `ended` reads as the last line of a [`Read`].
fn said(ended: &Ended) -> String {
    match ended {
        Ended::Exited { code } => format!("<exited {code}>"),
        Ended::Signalled { signal } => format!("<signalled {signal}>"),
        Ended::LineTooLong => "<line too long>".to_owned(),
        Ended::MessageTooLong => "<message too long>".to_owned(),
        Ended::Failed(words) => format!("<failed: {words}>"),
    }
}

/// Pulls `streams` to its end or its cancel: every line of standard
/// output, `pong` written back for each `ping-me`, and then how it ended.
pub fn consume(streams: &dyn ChildStreams) -> Read {
    let mut lines = Vec::new();
    let mut pulls = 0;
    loop {
        let Pulled::Delivered(delivery) = streams.pull() else {
            lines.push("<cancelled>".to_owned());
            break;
        };
        pulls += 1;
        if let Frames::Lines(out) = delivery.out {
            for line in out {
                if line == b"ping-me"
                    && let Err(closed) = streams.write(b"pong\n".to_vec())
                {
                    lines.push(format!("<write refused: {}>", closed.0));
                }
                lines.push(String::from_utf8_lossy(&line).into_owned());
            }
        }
        if let Some(ended) = delivery.ended {
            lines.push(said(&ended));
            break;
        }
    }
    Read { lines, pulls }
}

/// Takes the streaming child `child` over through the runtime and reads it
/// as the request `request` of the process's service
/// ([`Echo::attach`](crate::Echo::attach)), which completes it once the
/// child has ended or was cancelled. False when the library is not loaded,
/// the take-over is refused, or the request is in use.
pub extern "C" fn attach(request: u64, child: u64) -> bool {
    let Some(loaded) = loaded() else {
        return false;
    };
    match RuntimeChild::take_over(loaded.runtime, child) {
        Some(streams) => loaded.echo.attach(request, Box::new(streams)),
        None => false,
    }
}

/// Takes what the request `request` read
/// ([`Echo::take_read`](crate::Echo::take_read)): returns whether there
/// was something, and if so fills `out` with its lines joined by line
/// feeds in `text` and its pulls in `checksum`. False when the library is
/// not loaded.
///
/// # Safety
///
/// `out` points to a writable [`RawReply`].
pub unsafe extern "C" fn attach_take(request: u64, out: *mut RawReply) -> bool {
    let Some(read) = loaded().and_then(|loaded| loaded.echo.take_read(request)) else {
        return false;
    };
    let (text, text_len) = buffer::lend(read.text().into_bytes());
    // SAFETY: the caller guarantees `out` is writable.
    unsafe {
        out.write(RawReply {
            text,
            text_len,
            checksum: read.pulls,
        });
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fakes::{CLOSED, ScriptedChild};

    #[test]
    fn a_child_is_read_to_its_end_and_answered_pong_for_ping_me() {
        let child = ScriptedChild::new(true)
            .delivers(&["one", "ping-me"], None)
            .delivers(&["got pong", "three"], Some(Ended::Exited { code: 2 }));

        let read = consume(&child);

        assert_eq!(read.text(), "one\nping-me\ngot pong\nthree\n<exited 2>",);
        assert_eq!(read.pulls, 2);
        assert_eq!(child.written(), [b"pong\n".to_vec()]);
    }

    #[test]
    fn a_cancelled_child_reads_as_cancelled() {
        let child = ScriptedChild::new(true);

        assert_eq!(
            consume(&child),
            Read {
                lines: vec!["<cancelled>".to_owned()],
                pulls: 0
            }
        );
    }

    #[test]
    fn a_child_that_ends_otherwise_says_how() {
        let long = ScriptedChild::new(false).delivers(&[], Some(Ended::LineTooLong));
        let signalled =
            ScriptedChild::new(false).delivers(&["ping-me"], Some(Ended::Signalled { signal: 15 }));
        let failed = ScriptedChild::new(false).delivers(&[], Some(Ended::Failed("bad".to_owned())));

        assert_eq!(consume(&long).text(), "<line too long>");
        assert_eq!(
            consume(&signalled).text(),
            format!("<write refused: {CLOSED}>\nping-me\n<signalled 15>")
        );
        assert_eq!(consume(&failed).text(), "<failed: bad>");
    }
}
