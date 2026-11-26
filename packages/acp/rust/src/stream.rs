//! The child's streams as the SDK's transport: its standard output pulled
//! into lines, and lines written to its standard input.
//!
//! - **Pulled** ([`Pump::step`]): each pull of the taken-over child
//!   ([`ChildStreams::pull`]) hands its standard output's lines on, in
//!   order, and drops its standard error, which is pulled all the same so
//!   the child never blocks on it. The last delivery says how the child
//!   ended ([`ending_of`]), which the pump records before it ends the lines,
//!   so the session's last event can say it. A line longer than the bound
//!   ends the child, and the session, as
//!   [`Ending::LineTooLong`]: skipping a
//!   JSON-RPC line could drop a response and leave a request waiting for
//!   ever.
//! - **Written** ([`writer`]): each line the SDK sends is written whole,
//!   with its line feed, straight through [`ChildStreams::write`], on the
//!   session's own thread, the one writer.
//!
//! Each step is tested on `editor-service`'s fake source, stepped before the
//! pull.

use std::io;
use std::sync::{Arc, Mutex, PoisonError};

use editor_service::frame::Frames;
use editor_service::stream::{ChildStreams, Ended, Pulled};
use futures::Sink;
use futures::channel::mpsc;

use crate::event::Ending;
use crate::session::Transport;

/// How the child ended, once its last delivery was pulled: shared by the
/// pump, which records it, and the session, which says it last.
pub type EndingCell = Arc<Mutex<Option<Ending>>>;

/// How `ended` reads as the session's end.
pub fn ending_of(ended: &Ended) -> Ending {
    match ended {
        Ended::Exited { code } => Ending::Exited(*code),
        Ended::Signalled { signal } => Ending::Signalled(*signal),
        Ended::LineTooLong { .. } => Ending::LineTooLong,
        Ended::MessageTooLong { bound, .. } => {
            Ending::Failed(format!("a message was longer than {bound} bytes"))
        }
        Ended::Failed(words) => Ending::Failed(words.clone()),
    }
}

/// What pulls the child's standard output into the session's lines.
pub struct Pump {
    /// The child.
    streams: Arc<dyn ChildStreams>,
    /// Where its lines go: the transport's incoming stream.
    lines: mpsc::UnboundedSender<io::Result<String>>,
    /// Where its end is recorded.
    ending: EndingCell,
}

impl Pump {
    /// Pulls once: hands on every line of standard output delivered, drops
    /// standard error, and at the child's end, or its cancel, records how it
    /// ended and ends the lines. Whether to pull again.
    pub fn step(&self) -> bool {
        let Pulled::Delivered(delivery) = self.streams.pull() else {
            self.finish(Ending::Failed("the child was ended by its job".to_owned()));
            return false;
        };
        if let Frames::Lines(lines) = delivery.out {
            for line in lines {
                let text = String::from_utf8_lossy(&line).into_owned();
                if self.lines.unbounded_send(Ok(text)).is_err() {
                    // The session has ended: nothing reads the lines.
                    break;
                }
            }
        }
        match delivery.ended {
            Some(ended) => {
                self.finish(ending_of(&ended));
                false
            }
            None => true,
        }
    }

    /// Records `ending` and ends the lines, so the SDK reads the end of its
    /// input after every line before it.
    fn finish(&self, ending: Ending) {
        *self.ending.lock().unwrap_or_else(PoisonError::into_inner) = Some(ending);
        self.lines.close_channel();
    }
}

/// The SDK's outgoing sink over `streams`: each line written whole, with its
/// line feed, blocking until it is in the child's pipe; a refused write is
/// the transport's error.
pub fn writer(
    streams: Arc<dyn ChildStreams>,
) -> impl Sink<String, Error = io::Error> + Send + 'static {
    futures::sink::unfold(streams, async |streams, line: String| {
        let mut bytes = line.into_bytes();
        bytes.push(b'\n');
        streams
            .write(bytes)
            .map_err(|closed| io::Error::new(io::ErrorKind::BrokenPipe, closed.0))?;
        Ok::<_, io::Error>(streams)
    })
}

/// The transport over the taken-over child `streams`, and the pump that
/// feeds it.
pub fn transport(
    streams: Arc<dyn ChildStreams>,
) -> (
    Transport<
        impl Sink<String, Error = io::Error> + Send + 'static,
        mpsc::UnboundedReceiver<io::Result<String>>,
    >,
    Pump,
) {
    let (lines, incoming) = mpsc::unbounded();
    let ending: EndingCell = Arc::default();
    let pump = Pump {
        streams: Arc::clone(&streams),
        lines,
        ending: Arc::clone(&ending),
    };
    (
        Transport {
            outgoing: writer(streams),
            incoming,
            ending,
        },
        pump,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use editor_service::frame::Framing;
    use editor_service::stream::StreamSource;
    use editor_service::stream::fake::FakeSource;
    use futures::SinkExt;

    /// The lines the receiver holds now, and whether it has ended.
    fn received(incoming: &mut mpsc::UnboundedReceiver<io::Result<String>>) -> (Vec<String>, bool) {
        let mut lines = Vec::new();
        loop {
            match incoming.try_recv() {
                Ok(Ok(line)) => lines.push(line),
                Ok(Err(error)) => lines.push(format!("<error {error}>")),
                Err(mpsc::TryRecvError::Closed) => return (lines, true),
                Err(mpsc::TryRecvError::Empty) => return (lines, false),
            }
        }
    }

    #[test]
    fn standard_output_s_lines_are_handed_on_standard_error_is_dropped_and_the_exit_ends_the_lines()
    {
        let fake = FakeSource::new();
        let child = fake.child(Framing::Lines, Framing::Lines, 1 << 20, true);
        let (mut transport, pump) =
            transport(Arc::from(fake.take_over(child.id()).expect("taken over")));

        child.out(b"{\"one\":1}\n").err(b"a secret on stderr\n");
        assert!(pump.step());
        assert_eq!(
            received(&mut transport.incoming),
            (vec!["{\"one\":1}".to_owned()], false)
        );

        child.out(b"{\"two\":2}\n").exit(0);
        assert!(!pump.step(), "the child's end is the last pull");
        assert_eq!(
            received(&mut transport.incoming),
            (vec!["{\"two\":2}".to_owned()], true)
        );
        assert_eq!(
            *transport.ending.lock().expect("unpoisoned"),
            Some(Ending::Exited(0))
        );
    }

    #[test]
    fn a_line_longer_than_the_bound_ends_the_session_as_line_too_long() {
        let fake = FakeSource::new();
        let child = fake.child(Framing::Lines, Framing::Lines, 8, true);
        let (mut transport, pump) =
            transport(Arc::from(fake.take_over(child.id()).expect("taken over")));
        child.out(b"a line far past the bound\n");
        assert!(!pump.step());
        assert_eq!(received(&mut transport.incoming), (Vec::new(), true));
        assert_eq!(
            *transport.ending.lock().expect("unpoisoned"),
            Some(Ending::LineTooLong)
        );
    }

    #[test]
    fn a_cancelled_child_ends_the_lines_and_a_signal_says_so() {
        let fake = FakeSource::new();
        let cancelled = fake.child(Framing::Lines, Framing::Lines, 64, true);
        let signalled = fake.child(Framing::Lines, Framing::Lines, 64, true);
        let (cancelled_transport, cancelled_pump) = transport(Arc::from(
            fake.take_over(cancelled.id()).expect("taken over"),
        ));
        let (signalled_transport, signalled_pump) = transport(Arc::from(
            fake.take_over(signalled.id()).expect("taken over"),
        ));
        cancelled.cancel();
        signalled.signal(15);
        assert!(!cancelled_pump.step());
        assert!(!signalled_pump.step());
        assert!(matches!(
            *cancelled_transport.ending.lock().expect("unpoisoned"),
            Some(Ending::Failed(_))
        ));
        assert_eq!(
            *signalled_transport.ending.lock().expect("unpoisoned"),
            Some(Ending::Signalled(15))
        );
    }

    #[test]
    fn a_line_sent_is_written_whole_with_its_line_feed_and_a_closed_input_is_the_transport_s_error()
    {
        let fake = FakeSource::new();
        let child = fake.child(Framing::Lines, Framing::Lines, 64, true);
        let closed = fake.child(Framing::Lines, Framing::Lines, 64, false);
        let (open, _pump) = transport(Arc::from(fake.take_over(child.id()).expect("taken over")));
        let (shut, _shut_pump) =
            transport(Arc::from(fake.take_over(closed.id()).expect("taken over")));
        let mut open = Box::pin(open.outgoing);
        let mut shut = Box::pin(shut.outgoing);
        futures::executor::block_on(async {
            open.send("{\"jsonrpc\":\"2.0\"}".to_owned())
                .await
                .expect("written");
            let refused = shut.send("x".to_owned()).await;
            assert_eq!(
                refused.map_err(|error| error.kind()),
                Err(io::ErrorKind::BrokenPipe)
            );
        });
        assert_eq!(
            fake.record().written.first(),
            Some(&(child.id(), b"{\"jsonrpc\":\"2.0\"}\n".to_vec()))
        );
    }
}
