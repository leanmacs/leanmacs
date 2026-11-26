//! A streaming child handed to a consumer: [`Service::hand_off`], and the
//! service as `editor-service`'s stream source.
//!
//! A job opens a streaming child as it always has; [`Service::hand_off`]
//! then hands it to a consumer, which pulls its deliveries and writes its
//! input from its own thread ([`Handed`]), and the job reads it no more.
//! The service is [`editor_service::stream::StreamSource`] itself, and a
//! [`Handed`] the port's [`ChildStreams`], so the crate that holds the
//! process's one service provides it with no conversion of its own.
//!
//! - **The refusals** ([`HandOff`]), checked under the state lock and then
//!   the stream's, as a read is: a child the service does not hold live
//!   (unknown, cancelled, or forgotten after its last delivery), one with a
//!   read of the job's pending, and one handed already.
//! - **After the hand-off** the job's read, write and close of the child
//!   are refused, as for an unknown child; its cancel still ends it, and so
//!   does shutdown. A job's write already handed to the writer completes
//!   to the job: the writer answers each write to whoever asked.
//! - **A pull** ([`Handed::pull`]) is a read and its take in one call. It
//!   waits on the child's `changed` until something is deliverable, the
//!   child has ended, or the stream is abandoned (a cancel, shutdown, or
//!   its last delivery already pulled), and drains as a take does: room is
//!   made, a parked reader is told, and a consumer that does not pull holds
//!   the child at its bound. After the last delivery the child is
//!   forgotten.
//! - **A write** ([`Handed::write`]) waits for the write slot, which a
//!   job's write in flight may hold, puts the bytes in it for the writer,
//!   and waits on `changed` for the writer's reply to it. Every path that
//!   frees the slot tells `changed`: the writer's take, an abandon, and a
//!   job's cancel of its write still in the slot. A child with no
//!   input, a closed one, or an abandoned stream refuses it as
//!   [`RefusalKind::InputClosed`].
//! - **The waiter** tells `changed` once it has recorded the exit, so a
//!   consumer waiting for the end wakes. Every other change a pull waits
//!   for is told already: a reader's push, a failure, an abandon.
//!
//! Each ordering is forced in this module's tests on the port's fake: a
//! cancel and a shutdown reach a consumer held in its wait by a hook that
//! runs under the stream's lock (`before_pull_wait`), its streams held
//! open by a process outside its group and its reap held, so that nothing
//! but the abandon tells it; a child that has
//! exited and whose readers have let go before its hand-off delivers
//! everything (`exit_recorded`), and the waiter's notify is what ends a
//! wait for the end, its reap held; and a job's cancel of its queued write
//! wakes a consumer's write held waiting for the slot by a hook under the
//! stream's lock (`before_write_wait`); and a cancel and a shutdown reach a
//! consumer whose write the writer holds for good, every kill held, so
//! that nothing but the abandon answers it. Seen to bite once by hand, on
//! 2026-11-25: with the notify taken out of `StreamState::abandon`, the
//! cancel's and the shutdown's checks fail as hangs; with the waiter's
//! taken out, the check of the wait for the end does.

use std::sync::{Arc, PoisonError};

use editor_service::stream::{ChildStreams, Ended, InputClosed, Pulled, Refused, StreamSource};

use super::{Asker, Delivery, End, Inner, Run, Service, StreamReply, StreamState};
use crate::{Exit, Processes, Refusal, RefusalKind};

/// Why [`Service::hand_off`] refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HandOff {
    /// The service holds no live streaming child of that id: none was
    /// opened, it was cancelled, or its last delivery was taken.
    NoSuchChild,
    /// The job's read of it is pending: the job takes or cancels it first.
    ReadPending,
    /// It was handed off already.
    Taken,
}

/// A streaming child handed to a consumer ([`Service::hand_off`]). A cheap
/// handle: clones pull and write the one child.
pub struct Handed<P: Processes + 'static> {
    /// The service, to forget the child after its last delivery.
    inner: Arc<Inner<P>>,
    /// The child's id.
    child: u64,
    /// Its streams.
    stream: Arc<StreamState>,
}

impl<P: Processes + 'static> Clone for Handed<P> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
            child: self.child,
            stream: Arc::clone(&self.stream),
        }
    }
}

impl<P: Processes + 'static> Service<P> {
    /// Hands the live streaming child `child` to a consumer, which pulls
    /// its deliveries and writes its input from its own thread
    /// ([`Handed`]); the job reads, writes and closes it no more. The
    /// service still owns it: a cancel or shutdown ends it and answers a
    /// consumer's pull.
    ///
    /// # Errors
    ///
    /// [`HandOff::NoSuchChild`] for a child the service does not hold live,
    /// [`HandOff::ReadPending`] while the job's read of it is pending, and
    /// [`HandOff::Taken`] once it was handed off.
    pub fn hand_off(&self, child: u64) -> Result<Handed<P>, HandOff> {
        let state = self.inner.state();
        let Some(Run::Streaming {
            stream,
            cancelled: false,
            ..
        }) = state.runs.get(&child)
        else {
            return Err(HandOff::NoSuchChild);
        };
        let stream = Arc::clone(stream);
        let mut streamed = stream.state();
        if streamed.handed {
            return Err(HandOff::Taken);
        }
        if streamed.read.is_some() {
            return Err(HandOff::ReadPending);
        }
        streamed.handed = true;
        drop(streamed);
        drop(state);
        Ok(Handed {
            inner: Arc::clone(&self.inner),
            child,
            stream,
        })
    }
}

impl<P: Processes + 'static> Handed<P> {
    /// The next delivery, blocking until something is deliverable or the
    /// child has ended, and drained as it is taken; `None` once the child
    /// was cancelled, the service shut down, or the last delivery was
    /// taken.
    pub fn pull(&self) -> Option<Delivery> {
        let mut streamed = self.stream.state();
        loop {
            if streamed.abandoned {
                return None;
            }
            if streamed.outbox.deliverable() || streamed.end().is_some() {
                break;
            }
            #[cfg(test)]
            if let Some(waiting) = self.inner.before_pull_wait.get() {
                waiting();
            }
            streamed = self
                .stream
                .changed
                .wait(streamed)
                .unwrap_or_else(PoisonError::into_inner);
        }
        let (out, err) = streamed.outbox.drain();
        let ended = streamed.end();
        drop(streamed);
        // The readers parked on the bound go on.
        self.stream.changed.notify_all();
        if ended.is_some() {
            let mut state = self.inner.state();
            Service::<P>::forget(&mut state, self.child);
            drop(state);
            // Outside the state lock: the child is handed, so no read of
            // the job's can be pending.
            self.stream.abandon();
        }
        Some(Delivery { out, err, ended })
    }

    /// Writes every byte of `bytes` to the child's standard input, blocking
    /// until they are in its pipe: after a job's write the writer holds,
    /// if there is one. A consumer writes from one thread at a time: two
    /// writes from clones at once are each written whole, in the order they
    /// reach the slot, but the replies are not told apart, so each may be
    /// answered with the other's.
    ///
    /// # Errors
    ///
    /// A refusal as [`RefusalKind::InputClosed`] when the child has no
    /// input, it was closed or the child ended, or the stream was
    /// abandoned.
    pub fn write(&self, bytes: Vec<u8>) -> Result<(), Refusal> {
        let mut streamed = self.stream.state();
        let closed = |program: &str| {
            Refusal::new(
                RefusalKind::InputClosed,
                format!("cannot write to the standard input of `{program}`: it is closed"),
            )
        };
        loop {
            if streamed.abandoned || !streamed.input {
                return Err(closed(&streamed.program));
            }
            if streamed.write.is_none() {
                break;
            }
            // A job's write holds the slot until the writer takes it.
            #[cfg(test)]
            if let Some(waiting) = self.inner.before_write_wait.get() {
                waiting();
            }
            streamed = self
                .stream
                .changed
                .wait(streamed)
                .unwrap_or_else(PoisonError::into_inner);
        }
        streamed.consumer_written = None;
        streamed.write = Some((Asker::Consumer, bytes));
        self.stream.changed.notify_all();
        loop {
            match streamed.consumer_written.take() {
                Some(StreamReply::Refused(refusal)) => return Err(refusal),
                Some(_) => return Ok(()),
                None if streamed.abandoned => return Err(closed(&streamed.program)),
                None => {}
            }
            #[cfg(test)]
            if let Some(waiting) = self.inner.before_write_wait.get() {
                waiting();
            }
            streamed = self
                .stream
                .changed
                .wait(streamed)
                .unwrap_or_else(PoisonError::into_inner);
        }
    }
}

impl End {
    /// How the child ended, in the stream port's terms.
    pub fn ended(&self) -> Ended {
        match self {
            Self::Exited(Exit::Code(code)) => Ended::Exited { code: *code },
            Self::Exited(Exit::Signal(signal)) => Ended::Signalled { signal: *signal },
            Self::LineTooLong { stream, bound } => Ended::LineTooLong {
                stream: *stream,
                bound: *bound,
            },
            Self::MessageTooLong { stream, bound } => Ended::MessageTooLong {
                stream: *stream,
                bound: *bound,
            },
            Self::Failed(refusal) => Ended::Failed(refusal.detail.clone()),
        }
    }
}

impl<P: Processes + 'static> StreamSource for Service<P> {
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused> {
        match self.hand_off(child) {
            Ok(handed) => Ok(Box::new(handed)),
            Err(HandOff::NoSuchChild) => Err(Refused::NoSuchChild),
            Err(HandOff::ReadPending) => Err(Refused::ReadPending),
            Err(HandOff::Taken) => Err(Refused::Taken),
        }
    }
}

impl<P: Processes + 'static> ChildStreams for Handed<P> {
    fn pull(&self) -> Pulled {
        match Self::pull(self) {
            Some(delivery) => Pulled::Delivered(editor_service::stream::Delivery {
                out: delivery.out,
                err: delivery.err,
                ended: delivery.ended.as_ref().map(End::ended),
            }),
            None => Pulled::Cancelled,
        }
    }

    fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed> {
        Self::write(self, bytes).map_err(|refusal| InputClosed(refusal.detail))
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc::{self, Receiver, Sender};
    use std::sync::{Mutex, PoisonError};
    use std::thread;

    use super::super::support::{
        DEADLINE, ROOMY, comes_to_be_held, command, flushed, lines, lines_with, numbered, opened,
        readers_done, service,
    };
    use super::super::{Delivery, End, Service, StreamReply, Streaming};
    use super::{HandOff, Handed};
    use crate::fake::{FakeProcesses, Hold, Script, Step};
    use crate::frame::{Frames, Framing, Stream};
    use crate::{Exit, Input, Refusal, RefusalKind};
    use editor_service::stream::Ended;

    /// The pulls of `handed` to its last delivery, oldest first.
    fn to_the_end(handed: &Handed<FakeProcesses>) -> Vec<Delivery> {
        let mut deliveries = Vec::new();
        loop {
            let delivery = handed.pull().expect("a delivery");
            let ended = delivery.ended.is_some();
            deliveries.push(delivery);
            if ended {
                return deliveries;
            }
        }
    }

    /// Every line of standard output in `deliveries`.
    fn lines_of(deliveries: &[Delivery]) -> Vec<Vec<u8>> {
        deliveries
            .iter()
            .flat_map(|delivery| match &delivery.out {
                Frames::Lines(lines) => lines.clone(),
                other => panic!("lines, not {other:?}"),
            })
            .collect()
    }

    /// A channel the hook `set` sends on each time it is called.
    fn told(set: impl FnOnce(Box<dyn Fn() + Send + Sync>)) -> Receiver<()> {
        let (tell, told) = mpsc::channel::<()>();
        let tell: Mutex<Sender<()>> = Mutex::new(tell);
        set(Box::new(move || {
            let _ = tell.lock().unwrap_or_else(PoisonError::into_inner).send(());
        }));
        told
    }

    /// Has `service` tell the receiver each time a consumer's pull is about
    /// to wait.
    fn before_pull_wait(service: &Service<FakeProcesses>) -> Receiver<()> {
        told(|hook| {
            assert!(service.inner.before_pull_wait.set(hook).is_ok(), "set once");
        })
    }

    /// Has `service` tell the receiver each time a waiter has recorded its
    /// child's exit.
    fn exit_recorded(service: &Service<FakeProcesses>) -> Receiver<()> {
        told(|hook| {
            assert!(service.inner.exit_recorded.set(hook).is_ok(), "set once");
        })
    }

    #[test]
    fn lines_are_read_and_a_write_is_echoed_after_the_hand_off() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).steps([
                Step::Write(Stream::Out, b"one\n".to_vec()),
                Step::EchoLine(Stream::Out),
            ])),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        let handed = service.hand_off(1).expect("handed");

        let first = handed.pull().expect("a delivery");
        let written = handed.write(b"two\n".to_vec());
        let rest = to_the_end(&handed);

        assert_eq!(first.out, lines(&["one"]));
        assert_eq!(written, Ok(()));
        assert_eq!(lines_of(&rest), [b"two".to_vec()]);
        assert_eq!(
            rest.last().and_then(|last| last.ended.clone()),
            Some(End::Exited(Exit::Code(0)))
        );
        assert!(flushed(&service, &completed), "forgotten and reaped");
    }

    #[test]
    fn a_child_unknown_cancelled_or_forgotten_is_no_such_child() {
        let fake = FakeProcesses::scripted([
            (
                command("held"),
                Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled)),
            ),
            (
                command("ends"),
                Ok(Script::ends(Exit::Code(0)).stdout("a\n")),
            ),
        ]);
        let (service, completed) = service(&fake);
        let closed = lines_with(Input::Closed, ROOMY);
        opened(&service, &completed, 1, command("held"), closed);
        opened(&service, &completed, 2, command("ends"), closed);
        assert!(service.cancel(1));
        let ended = service.hand_off(2).expect("handed");
        to_the_end(&ended);

        assert_eq!(service.hand_off(99).err(), Some(HandOff::NoSuchChild));
        assert_eq!(service.hand_off(1).err(), Some(HandOff::NoSuchChild));
        assert_eq!(service.hand_off(2).err(), Some(HandOff::NoSuchChild));
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn a_child_with_a_read_pending_is_refused_until_it_is_withdrawn_and_a_second_hand_off_is_taken()
    {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled)),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, ROOMY),
        );
        assert!(service.read(1, 2), "a read with nothing to deliver");

        let pending = service.hand_off(1).err();
        assert!(service.cancel(2), "the read is withdrawn");
        let handed = service.hand_off(1);
        let again = service.hand_off(1).err();

        assert_eq!(pending, Some(HandOff::ReadPending));
        assert!(handed.is_ok());
        assert_eq!(again, Some(HandOff::Taken));
        assert!(service.cancel(1));
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn the_jobs_read_write_and_close_of_a_child_handed_off_are_refused() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .step(Step::AwaitInputClosed)),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        let _handed = service.hand_off(1).expect("handed");

        assert!(!service.read(1, 2));
        assert!(!service.write(1, 3, b"x".to_vec()));
        assert!(!service.close_input(1, 4));
        assert_eq!(service.pending(), 1, "the child alone: no wait was taken");
        assert!(service.cancel(1), "a cancel still ends it");
        assert!(flushed(&service, &completed));
    }

    // Seen to bite once by hand, on 2026-11-25: with the writer answering
    // every reply to the consumer once the child is handed, as the spike's
    // did, the job's write is never completed and the test fails waiting
    // for it.
    #[test]
    fn a_jobs_write_in_flight_at_the_hand_off_completes_to_the_job_and_the_consumers_follows_it() {
        // The child echoes its input, but its pipes and its bound hold two
        // bytes each, so it stops reading its input until something is
        // pulled, eight bytes in: the job's write of sixteen is held in the
        // writer at the hand-off.
        let fake = FakeProcesses::scripted([(
            command("cat"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .step(Step::EchoUntilClosed(Stream::Out))
                .pipe_capacity(2)),
        )]);
        let (service, completed) = service(&fake);
        let bytes = Streaming {
            input: Input::Pipe,
            out: Framing::Bytes,
            err: Framing::Bytes,
            bound: 2,
        };
        opened(&service, &completed, 1, command("cat"), bytes);
        assert!(service.write(1, 2, b"jjjjjjjjjjjjjjjj".to_vec()));
        assert!(fake.until(DEADLINE, |record| record.writes_blocked == 1));
        let handed = service.hand_off(1).expect("handed");

        let (consumer_wrote, written) = mpsc::channel();
        let echoed = thread::scope(|scope| {
            scope.spawn(|| {
                let _ = consumer_wrote.send(handed.write(b"cccccc".to_vec()));
            });
            let mut echoed = Vec::new();
            while echoed.len() < 22 {
                match handed.pull().map(|delivery| delivery.out) {
                    Some(Frames::Bytes(bytes)) => echoed.extend(bytes),
                    other => panic!("bytes, not {other:?}"),
                }
            }
            echoed
        });

        assert_eq!(editor_wait::recv(&written, DEADLINE), Ok(Ok(())));
        assert_eq!(editor_wait::recv(&completed, DEADLINE), Ok(2));
        assert_eq!(service.take_stream(2), Some(StreamReply::Written));
        assert_eq!(echoed, b"jjjjjjjjjjjjjjjjcccccc");
        let child = fake.record().spawned[0].0;
        assert_eq!(
            fake.record().children[&child].received,
            b"jjjjjjjjjjjjjjjjcccccc"
        );
        assert!(service.cancel(1));
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn a_consumers_write_to_a_child_with_no_input_is_refused_as_input_closed() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).hold(Hold::UntilKilled)),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, ROOMY),
        );
        let handed = service.hand_off(1).expect("handed");

        let refused = handed.write(b"x\n".to_vec());

        assert!(matches!(refused, Err(refusal) if refusal.kind == RefusalKind::InputClosed));
        assert!(service.cancel(1));
        assert!(flushed(&service, &completed));
    }

    // Seen to bite by hand, on 2026-11-25: with the writer's refusal
    // answered as `Ok`, the second write's check fails; with the writer no
    // longer marking the input closed, the third is answered in the fake's
    // words, not the service's own.
    #[test]
    fn a_consumers_write_after_the_child_closed_its_input_is_the_writers_refusal_and_then_refused_at_once()
     {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .steps([Step::EchoLine(Stream::Out), Step::CloseInput])),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        let handed = service.hand_off(1).expect("handed");

        let first = handed.write(b"a\n".to_vec());
        // Its echo is pulled: it has closed its input, in the same step.
        let echoed = handed.pull().map(|delivery| delivery.out);
        let second = handed.write(b"b\n".to_vec());
        let third = handed.write(b"c\n".to_vec());

        assert_eq!(first, Ok(()));
        assert_eq!(echoed, Some(lines(&["a"])));
        let words = |written: &Result<(), Refusal>| match written {
            Err(refusal) if refusal.kind == RefusalKind::InputClosed => refusal.detail.clone(),
            other => panic!("refused as input closed, not {other:?}"),
        };
        assert!(
            words(&second).contains("the fake's child has closed it"),
            "the writer's refusal, in the platform's words"
        );
        assert!(
            words(&third).ends_with("it is closed"),
            "refused at once, never reaching the writer"
        );
        let child = fake.record().spawned[0].0;
        assert_eq!(fake.record().children[&child].received, b"a\n");
        assert!(service.cancel(1));
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn a_child_handed_off_is_held_at_its_bound_while_nothing_pulls_and_pulls_deliver_every_line() {
        let script = numbered(2000);
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .stdout(script.clone())
                .pipe_capacity(100)),
        )]);
        let (service, completed) = service(&fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, 64),
        );
        let handed = service.hand_off(1).expect("handed");

        assert!(comes_to_be_held(&service, 1));
        let all = to_the_end(&handed);

        let mut got: Vec<u8> = Vec::new();
        for line in lines_of(&all) {
            got.extend(line);
            got.push(b'\n');
        }
        assert_eq!(got, script);
        assert_eq!(
            all.last().and_then(|last| last.ended.clone()),
            Some(End::Exited(Exit::Code(0)))
        );
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn each_end_is_the_ports_ended() {
        let failed = Refusal::new(RefusalKind::Failed, "EIO");
        let cases = [
            (End::Exited(Exit::Code(3)), Ended::Exited { code: 3 }),
            (End::Exited(Exit::Signal(9)), Ended::Signalled { signal: 9 }),
            (
                End::LineTooLong {
                    stream: Stream::Err,
                    bound: 4,
                },
                Ended::LineTooLong {
                    stream: Stream::Err,
                    bound: 4,
                },
            ),
            (
                End::MessageTooLong {
                    stream: Stream::Out,
                    bound: 64,
                },
                Ended::MessageTooLong {
                    stream: Stream::Out,
                    bound: 64,
                },
            ),
            (End::Failed(failed), Ended::Failed("EIO".into())),
        ];
        for (end, ended) in cases {
            assert_eq!(end.ended(), ended);
        }
    }

    // The forced interleavings. Seen to bite once by hand, on 2026-11-25:
    // with the notify taken out of `StreamState::abandon`, the first two
    // fail as hangs, the consumer never waking from its wait; with the one
    // taken out of the waiter after it records the exit, the last fails as
    // a hang.

    /// A consumer's pull of `handed` on a thread of its own, its answer on
    /// the receiver.
    fn pulling(handed: &Handed<FakeProcesses>) -> (Receiver<Option<Delivery>>, Consumer) {
        let (answer, answered) = mpsc::channel();
        let handed = handed.clone();
        let consumer = thread::spawn(move || {
            let _ = answer.send(handed.pull());
        });
        (answered, Consumer(Some(consumer)))
    }

    /// A consumer's thread, joined once its pull has answered: a test that
    /// saw it answer drops it, which joins it. One that hangs is left, so
    /// the test fails on its hang guard rather than hanging in a join.
    struct Consumer(Option<thread::JoinHandle<()>>);

    impl Consumer {
        /// Joins the thread, which has answered.
        fn answered(mut self) {
            if let Some(thread) = self.0.take() {
                thread.join().expect("the consumer's thread");
            }
        }
    }

    /// The consumer's answer, waited for on the receiver, its thread joined
    /// once it has answered.
    fn answer(
        answered: &Receiver<Option<Delivery>>,
        consumer: Consumer,
    ) -> Option<Option<Delivery>> {
        let answer = editor_wait::recv(answered, DEADLINE).ok();
        if answer.is_some() {
            consumer.answered();
        }
        answer
    }

    /// A child that writes nothing and runs until it is killed, with a
    /// process outside its group that holds both its streams: so no
    /// reader's end, and, with its reap held, no waiter's, tells `changed`
    /// on the kill. Only the abandon can wake a consumer.
    fn held_open() -> Script {
        Script::ends(Exit::Code(0))
            .hold(Hold::UntilKilled)
            .escaped(1)
    }

    #[test]
    fn a_cancel_while_the_consumer_is_blocked_in_a_pull_answers_cancelled() {
        let fake = FakeProcesses::scripted([(command("x"), Ok(held_open()))]);
        fake.hold_reaps();
        let (service, completed) = service(&fake);
        let waiting = before_pull_wait(&service);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, ROOMY),
        );
        let handed = service.hand_off(1).expect("handed");
        let child = fake.record().spawned[0].0;

        let (answered, consumer) = pulling(&handed);
        // The hook runs under the stream's lock, so the cancel's abandon
        // takes it only once the consumer is in its wait.
        assert_eq!(editor_wait::recv(&waiting, DEADLINE), Ok(()));
        assert!(service.cancel(1));
        let pulled = answer(&answered, consumer);
        fake.release_reaps();

        assert_eq!(pulled, Some(None), "cancelled");
        assert!(flushed(&service, &completed), "and reaped");
        assert!(!fake.alive(child));
        fake.end(child + 1);
        assert!(readers_done(&fake, child));
    }

    #[test]
    fn a_shutdown_while_the_consumer_is_blocked_in_a_pull_answers_cancelled() {
        let fake = FakeProcesses::scripted([(command("x"), Ok(held_open()))]);
        fake.hold_reaps();
        let (service, completed) = service(&fake);
        let waiting = before_pull_wait(&service);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, ROOMY),
        );
        let handed = service.hand_off(1).expect("handed");
        let child = fake.record().spawned[0].0;

        let (answered, consumer) = pulling(&handed);
        assert_eq!(editor_wait::recv(&waiting, DEADLINE), Ok(()));
        // Shutdown returns once the child is reaped, which is held: the
        // consumer is answered while it waits, by its abandon alone.
        let pulled = thread::scope(|scope| {
            let shutting = scope.spawn(|| service.shutdown());
            let pulled = answer(&answered, consumer);
            fake.release_reaps();
            shutting.join().expect("shutdown returns");
            pulled
        });

        assert_eq!(pulled, Some(None), "cancelled");
        assert_eq!(fake.record().reaped, [child], "every child reaped");
        assert_eq!(service.pending(), 0);
        fake.end(child + 1);
        assert!(readers_done(&fake, child));
    }

    /// Has `service` tell the receiver each time a consumer's write is about
    /// to wait: for the write slot, then for the writer's reply.
    fn before_write_wait(service: &Service<FakeProcesses>) -> Receiver<()> {
        told(|hook| {
            assert!(
                service.inner.before_write_wait.set(hook).is_ok(),
                "set once"
            );
        })
    }

    /// Where a consumer's write answers.
    type Wrote = Receiver<Result<(), Refusal>>;

    /// A consumer's write of `bytes` to `handed` on a thread of its own,
    /// its answer on the receiver.
    fn writing(handed: &Handed<FakeProcesses>, bytes: &[u8]) -> (Wrote, Consumer) {
        let (answer, answered) = mpsc::channel();
        let (handed, bytes) = (handed.clone(), bytes.to_vec());
        let consumer = thread::spawn(move || {
            let _ = answer.send(handed.write(bytes));
        });
        (answered, Consumer(Some(consumer)))
    }

    /// The consumer's write's answer, waited for on the receiver, its
    /// thread joined once it has answered.
    fn written(answered: &Wrote, consumer: Consumer) -> Option<Result<(), Refusal>> {
        let answer = editor_wait::recv(answered, DEADLINE).ok();
        if answer.is_some() {
            consumer.answered();
        }
        answer
    }

    // Seen to bite on 2026-11-25: with `cancel_wait` freeing the slot and
    // telling nothing, the consumer sleeps on a free slot, and the check
    // that it goes on to wait for its reply fails as a hang.
    #[test]
    fn a_job_cancelling_its_queued_write_wakes_a_consumers_write_waiting_for_the_slot() {
        // Its pipes and its bound hold two bytes each. It first writes six
        // bytes to standard output, held until something is pulled, and
        // only then reads its input, and writes nothing more: so once it is
        // held, nothing it does tells `changed`.
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0))
                .hold(Hold::UntilKilled)
                .steps([
                    Step::Write(Stream::Out, b"oooooo".to_vec()),
                    Step::AwaitInputClosed,
                ])
                .pipe_capacity(2)),
        )]);
        let (service, completed) = service(&fake);
        let waiting = before_write_wait(&service);
        let bytes = Streaming {
            input: Input::Pipe,
            out: Framing::Bytes,
            err: Framing::Bytes,
            bound: 2,
        };
        opened(&service, &completed, 1, command("x"), bytes);
        assert!(comes_to_be_held(&service, 1));
        // The job's write of four bytes is held in the writer, two in the
        // pipe, and its second waits in the slot.
        assert!(service.write(1, 2, b"aaaa".to_vec()));
        assert!(fake.until(DEADLINE, |record| record.writes_blocked == 1));
        assert!(service.write(1, 3, b"bb".to_vec()));
        let handed = service.hand_off(1).expect("handed");

        let (answered, consumer) = writing(&handed, b"cc");
        assert_eq!(
            editor_wait::recv(&waiting, DEADLINE),
            Ok(()),
            "waiting for the slot"
        );
        assert!(service.cancel(3), "the job's queued write is withdrawn");
        let put = editor_wait::recv(&waiting, DEADLINE);
        // Pulled, the child's output lets it read its input.
        let mut out = Vec::new();
        while out.len() < 6 {
            match handed.pull().map(|delivery| delivery.out) {
                Some(Frames::Bytes(bytes)) => out.extend(bytes),
                other => panic!("bytes, not {other:?}"),
            }
        }
        let consumers = written(&answered, consumer);

        assert_eq!(put, Ok(()), "woken, it puts its write in the slot");
        assert_eq!(consumers, Some(Ok(())));
        assert_eq!(editor_wait::recv(&completed, DEADLINE), Ok(2));
        assert_eq!(service.take_stream(2), Some(StreamReply::Written));
        let child = fake.record().spawned[0].0;
        assert_eq!(fake.record().children[&child].received, b"aaaacc");
        assert!(service.cancel(1));
        assert!(flushed(&service, &completed));
    }

    /// A child that never reads its input, whose input pipe holds one byte:
    /// a write of more is held in the writer for good.
    fn never_reads() -> Script {
        Script::ends(Exit::Code(0))
            .hold(Hold::UntilKilled)
            .pipe_capacity(1)
    }

    /// The service over a child that never reads, opened as `1` and handed
    /// off, with a consumer's write of three bytes held in the writer and
    /// every kill held: so the writer stays held after a cancel or a
    /// shutdown, and only the abandon can answer the consumer.
    fn a_write_held_for_good(
        fake: &FakeProcesses,
    ) -> (Service<FakeProcesses>, Receiver<u64>, Wrote, Consumer) {
        let (service, completed) = service(fake);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Pipe, ROOMY),
        );
        let handed = service.hand_off(1).expect("handed");
        let (answered, consumer) = writing(&handed, b"xyz");
        // The writer took the write, so the consumer let go of the lock to
        // wait for its reply.
        assert!(fake.until(DEADLINE, |record| record.writes_blocked == 1));
        fake.hold_kills();
        (service, completed, answered, consumer)
    }

    /// Whether `written` is a refusal as input closed.
    fn input_closed(written: Option<Result<(), Refusal>>) -> bool {
        matches!(written, Some(Err(refusal)) if refusal.kind == RefusalKind::InputClosed)
    }

    // Seen to bite by hand, on 2026-11-25: with `Handed::write` no longer
    // answering an abandoned stream, both fail as hangs.
    #[test]
    fn a_cancel_while_the_consumer_is_blocked_in_a_write_refuses_it_as_input_closed() {
        let fake = FakeProcesses::scripted([(command("x"), Ok(never_reads()))]);
        let (service, completed, answered, consumer) = a_write_held_for_good(&fake);

        let refused = thread::scope(|scope| {
            // The cancel abandons the stream, then parks in its held kill.
            let cancelling = scope.spawn(|| service.cancel(1));
            let refused = written(&answered, consumer);
            fake.release_kills();
            assert!(cancelling.join().expect("the cancel returns"));
            refused
        });

        assert!(input_closed(refused));
        assert!(flushed(&service, &completed), "and reaped");
    }

    #[test]
    fn a_shutdown_while_the_consumer_is_blocked_in_a_write_refuses_it_as_input_closed() {
        let fake = FakeProcesses::scripted([(command("x"), Ok(never_reads()))]);
        let (service, _completed, answered, consumer) = a_write_held_for_good(&fake);
        let child = fake.record().spawned[0].0;

        let refused = thread::scope(|scope| {
            // Shutdown abandons the stream, then parks in its held kill.
            let shutting = scope.spawn(|| service.shutdown());
            let refused = written(&answered, consumer);
            fake.release_kills();
            shutting.join().expect("shutdown returns");
            refused
        });

        assert!(input_closed(refused));
        assert_eq!(fake.record().reaped, [child], "every child reaped");
        assert_eq!(service.pending(), 0);
    }

    #[test]
    fn a_child_that_exits_before_its_hand_off_still_delivers_its_lines_and_its_exit() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(2)).stdout("a\nb\n").stderr("e\n")),
        )]);
        let (service, completed) = service(&fake);
        let recorded = exit_recorded(&service);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, ROOMY),
        );
        let child = fake.record().spawned[0].0;
        assert_eq!(editor_wait::recv(&recorded, DEADLINE), Ok(()));
        assert!(readers_done(&fake, child));

        let handed = service.hand_off(1).expect("handed after its end");
        let delivered = handed.pull();
        let again = service.hand_off(1).err();

        assert_eq!(
            delivered,
            Some(Delivery {
                out: lines(&["a", "b"]),
                err: lines(&["e"]),
                ended: Some(End::Exited(Exit::Code(2))),
            }),
            "one pull: every line and the exit"
        );
        assert_eq!(again, Some(HandOff::NoSuchChild));
        assert!(flushed(&service, &completed));
    }

    #[test]
    fn the_waiter_wakes_a_consumer_waiting_for_the_end() {
        let fake = FakeProcesses::scripted([(
            command("x"),
            Ok(Script::ends(Exit::Code(0)).stdout("a\n")),
        )]);
        fake.hold_reaps();
        let (service, completed) = service(&fake);
        let waiting = before_pull_wait(&service);
        opened(
            &service,
            &completed,
            1,
            command("x"),
            lines_with(Input::Closed, ROOMY),
        );
        let child = fake.record().spawned[0].0;
        // Both streams have ended; the exit is not recorded, its reap held.
        assert!(readers_done(&fake, child));
        assert!(fake.until(DEADLINE, |record| record.reaps_parked == 1));
        let handed = service.hand_off(1).expect("handed");
        let first = handed.pull();

        let (answered, consumer) = pulling(&handed);
        assert_eq!(editor_wait::recv(&waiting, DEADLINE), Ok(()));
        fake.release_reaps();
        let last = answer(&answered, consumer);

        assert_eq!(first.map(|delivery| delivery.out), Some(lines(&["a"])));
        assert_eq!(
            last,
            Some(Some(Delivery {
                out: lines(&[]),
                err: lines(&[]),
                ended: Some(End::Exited(Exit::Code(0))),
            }))
        );
        assert!(flushed(&service, &completed));
    }
}
