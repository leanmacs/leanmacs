//! Taking over a streaming child a Lean job opened through the core's
//! process service, and reading it in Rust: what a package's crate that
//! speaks to a child (an agent's, a language server's) does, as a fixture.
//!
//! It reaches the core's one process service through `editor-service`
//! alone ([`editor_service::stream::take_over`]): this crate depends on
//! nothing else of the editor's, and `rust/Cargo.toml` says so.
//!
//! [`consume`] is the logic: it pulls the child's lines, writes `pong` back
//! when it reads `ping-me`, and stops at the child's end or a cancel. It is
//! tested on `editor-service`'s fake source,
//! [`editor_service::stream::fake::FakeSource`], stepped before each pull.
//! [`Echo::attach`](crate::Echo::attach) runs it as a request of the
//! package's service, on a worker the service owns, and completes the
//! request once it has read to the end; [`echo_ffi_attach`] takes the child
//! over and hands it to the process's service, and [`echo_ffi_attach_take`]
//! takes what it read.

use editor_service::buffer;
use editor_service::frame::Frames;
use editor_service::stream::{self, ChildStreams, Ended, Pulled};

use crate::ffi::{ECHO, RawReply};

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
        Ended::LineTooLong { .. } => "<line too long>".to_owned(),
        Ended::MessageTooLong { .. } => "<message too long>".to_owned(),
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

/// Takes the streaming child `child` over and reads it as the request
/// `request` of the process's service ([`Echo::attach`](crate::Echo::attach)),
/// which completes it once the child has ended or was cancelled. False
/// when the take-over is refused, or the request is in use.
#[unsafe(no_mangle)]
pub extern "C" fn echo_ffi_attach(request: u64, child: u64) -> bool {
    match stream::take_over(child) {
        Ok(streams) => ECHO.attach(request, streams),
        Err(_) => false,
    }
}

/// Takes what the request `request` read
/// ([`Echo::take_read`](crate::Echo::take_read)): returns whether there
/// was something, and if so fills `out` with its lines joined by line
/// feeds in `text` and its pulls in `checksum`.
///
/// # Safety
///
/// `out` points to a writable [`RawReply`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn echo_ffi_attach_take(request: u64, out: *mut RawReply) -> bool {
    let Some(read) = ECHO.take_read(request) else {
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
    use editor_service::frame::Framing;
    use editor_service::stream::StreamSource;
    use editor_service::stream::fake::FakeSource;

    #[test]
    fn a_child_is_read_to_its_end_and_answered_pong_for_ping_me() {
        let fake = FakeSource::new();
        let child = fake.child(Framing::Lines, Framing::Lines, 1 << 20, true);
        child
            .out(b"one\nping-me\n")
            .on_line(b"pong\n", b"got pong\nthree\n")
            .exit(2);
        let streams = fake.take_over(child.id()).expect("taken over");

        let read = consume(&*streams);

        assert_eq!(
            read.text(),
            "one\nping-me\ngot pong\nthree\n<exited 2>",
            "the reply came once `pong` was written"
        );
        assert_eq!(read.pulls, 2);
        assert_eq!(fake.record().written, [(child.id(), b"pong\n".to_vec())]);
    }

    #[test]
    fn a_cancelled_child_reads_as_cancelled() {
        let fake = FakeSource::new();
        let child = fake.child(Framing::Lines, Framing::Lines, 64, true);
        let streams = fake.take_over(child.id()).expect("taken over");
        child.cancel();

        assert_eq!(
            consume(&*streams),
            Read {
                lines: vec!["<cancelled>".to_owned()],
                pulls: 0
            }
        );
    }

    #[test]
    fn a_child_that_ends_otherwise_says_how() {
        let fake = FakeSource::new();
        let long = fake.child(Framing::Lines, Framing::Lines, 4, false);
        long.out(b"abcdef\n");
        let signalled = fake.child(Framing::Lines, Framing::Lines, 64, true);
        signalled.out(b"ping-me\n").signal(15);

        let long = consume(&*fake.take_over(long.id()).expect("taken over"));
        let signalled = consume(&*fake.take_over(signalled.id()).expect("taken over"));

        assert_eq!(long.text(), "<line too long>");
        assert!(
            signalled.text().starts_with("<write refused:"),
            "{}",
            signalled.text()
        );
        assert!(signalled.text().ends_with("ping-me\n<signalled 15>"));
    }
}
