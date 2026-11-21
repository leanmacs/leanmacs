//! A thread and the owner that ends it: [`Worker`].
//!
//! A service that starts a thread for a scope, a test's loop among them,
//! holds it as a [`Worker`]. Dropping the worker asks the thread to stop,
//! with the `stop` it was given, and joins it, on every path: a test that
//! panics drops its worker while it unwinds, and the thread has ended
//! before the drop returns (AGENTS.md, "Deterministic concurrency in
//! tests": nothing a test creates outlives it).
//!
//! The process's own services are statics that are never dropped, so their
//! threads live for the process and end with it; they are no workers.

use std::io;
use std::thread::{self, JoinHandle, Thread};

#[cfg(test)]
use std::sync::OnceLock;

/// A thread and its owner: dropping the owner asks the thread to stop
/// (`stop`, run once) and joins it, on every path, a panicking test's
/// included.
///
/// A worker dropped on its own thread (its body held the last owner) runs
/// `stop` and does not join: a thread cannot wait for itself, and it ends
/// when its body returns.
pub struct Worker {
    stop: Option<Box<dyn FnOnce() + Send>>,
    thread: Option<JoinHandle<()>>,
    started: Thread,
    #[cfg(test)]
    join_waits: OnceLock<Box<dyn Fn() + Send + Sync>>,
}

impl Worker {
    /// Starts `body` on a thread named `name`; `stop` is what makes it
    /// return, and it runs once, on the first [`join`](Worker::join) or on
    /// the drop.
    ///
    /// # Errors
    ///
    /// The error the system gave when it could not start the thread.
    pub fn spawn(
        name: &str,
        stop: impl FnOnce() + Send + 'static,
        body: impl FnOnce() + Send + 'static,
    ) -> io::Result<Worker> {
        let thread = thread::Builder::new().name(name.to_owned()).spawn(body)?;
        Ok(Worker {
            stop: Some(Box::new(stop)),
            started: thread.thread().clone(),
            thread: Some(thread),
            #[cfg(test)]
            join_waits: OnceLock::new(),
        })
    }

    /// The thread the body runs on.
    #[must_use]
    pub fn thread(&self) -> &Thread {
        &self.started
    }

    /// Stops and joins now.
    ///
    /// # Errors
    ///
    /// The panic's payload, if the body panicked.
    pub fn join(mut self) -> thread::Result<()> {
        self.stop_and_join().unwrap_or(Ok(()))
    }

    /// Has `told` called when a drop or a join finds the thread still
    /// running after `stop`, just before it joins. Set once, by a test: a
    /// second call is ignored.
    #[cfg(test)]
    pub(crate) fn when_join_waits(&self, told: impl Fn() + Send + Sync + 'static) {
        let _ = self.join_waits.set(Box::new(told));
    }

    /// Runs `stop` if it has not run, then joins the thread unless it is
    /// the caller's own: `None` when there was nothing to join.
    fn stop_and_join(&mut self) -> Option<thread::Result<()>> {
        if let Some(stop) = self.stop.take() {
            stop();
        }
        let thread = self.thread.take()?;
        if thread.thread().id() == thread::current().id() {
            return None;
        }
        #[cfg(test)]
        if !thread.is_finished()
            && let Some(told) = self.join_waits.get()
        {
            told();
        }
        Some(thread.join())
    }
}

impl Drop for Worker {
    /// Stops the thread and joins it. A panic's payload is dropped: a drop
    /// while a test unwinds must not panic again, which would abort.
    fn drop(&mut self) {
        let _ = self.stop_and_join();
    }
}

#[cfg(test)]
mod tests {
    use super::Worker;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::mpsc;

    #[test]
    fn dropping_a_worker_returns_only_once_its_thread_has_ended() {
        let (stopped, told_stop) = mpsc::channel::<()>();
        let (gate, gated) = mpsc::channel::<()>();
        let ended = Arc::new(AtomicBool::new(false));
        let worker = Worker::spawn(
            "worker-test",
            move || {
                let _ = stopped.send(());
            },
            {
                let ended = Arc::clone(&ended);
                move || {
                    let _ = told_stop.recv();
                    let _ = gated.recv();
                    ended.store(true, Ordering::SeqCst);
                }
            },
        )
        .expect("the thread starts");
        let opener = gate.clone();
        worker.when_join_waits(move || {
            let _ = opener.send(());
        });

        drop(worker);
        let ended_at_drop = ended.load(Ordering::SeqCst);
        // On a drop that does not join, the body is still on the gate: let
        // it go, so the stray thread ends.
        drop(gate);
        assert!(
            ended_at_drop,
            "the drop returned with the body still on its gate"
        );
    }

    #[test]
    fn a_worker_whose_body_panicked_is_joined_on_drop_and_join_gives_the_panic() {
        // The body is held on a gate that only the drop's hook opens, then
        // notes that it ended and panics: a drop that did not join returns
        // with the body still on the gate.
        let (gate, gated) = mpsc::channel::<()>();
        let ended = Arc::new(AtomicBool::new(false));
        let dropped = Worker::spawn("worker-test", || {}, {
            let ended = Arc::clone(&ended);
            move || {
                let _ = gated.recv();
                ended.store(true, Ordering::SeqCst);
                panic!("the body panicked");
            }
        })
        .expect("the thread starts");
        let opener = gate.clone();
        dropped.when_join_waits(move || {
            let _ = opener.send(());
        });
        drop(dropped);
        let ended_at_drop = ended.load(Ordering::SeqCst);
        // On a drop that does not join, the body is still on the gate: let
        // it go, so the stray thread ends.
        drop(gate);
        assert!(
            ended_at_drop,
            "the drop returned with the panicking body still on its gate"
        );

        let joined = Worker::spawn("worker-test", || {}, || panic!("the body panicked"))
            .expect("the thread starts");
        let payload = joined.join().expect_err("the join gives the panic");
        assert_eq!(
            payload.downcast_ref::<&str>().copied(),
            Some("the body panicked")
        );
    }

    #[test]
    fn stop_runs_once_whether_the_worker_is_joined_or_dropped() {
        for join in [true, false] {
            let stops = Arc::new(AtomicUsize::new(0));
            let (stopped, told_stop) = mpsc::channel::<()>();
            let worker = Worker::spawn(
                "worker-test",
                {
                    let stops = Arc::clone(&stops);
                    move || {
                        stops.fetch_add(1, Ordering::SeqCst);
                        let _ = stopped.send(());
                    }
                },
                move || {
                    let _ = told_stop.recv();
                },
            )
            .expect("the thread starts");
            if join {
                worker.join().expect("the body returns");
            } else {
                drop(worker);
            }
            assert_eq!(stops.load(Ordering::SeqCst), 1, "joined: {join}");
        }
    }

    #[test]
    fn a_workers_thread_is_the_one_its_body_runs_on() {
        let (ran, told_ran) = mpsc::channel();
        let worker = Worker::spawn(
            "worker-test",
            || {},
            move || {
                let _ = ran.send(std::thread::current().id());
            },
        )
        .expect("the thread starts");
        let ran_on = told_ran.recv().expect("the body ran");
        assert_eq!(worker.thread().id(), ran_on);
        assert_eq!(worker.thread().name(), Some("worker-test"));
        assert_ne!(ran_on, std::thread::current().id());
    }

    #[test]
    fn a_worker_dropped_on_its_own_thread_does_not_join_itself() {
        let (hand, handed) = mpsc::channel::<Worker>();
        let (done, told_done) = mpsc::channel::<()>();
        let stops = Arc::new(AtomicUsize::new(0));
        let worker = Worker::spawn(
            "worker-test",
            {
                let stops = Arc::clone(&stops);
                move || {
                    stops.fetch_add(1, Ordering::SeqCst);
                }
            },
            move || {
                let me = handed.recv().expect("the worker is handed over");
                drop(me);
                let _ = done.send(());
            },
        )
        .expect("the thread starts");
        hand.send(worker).expect("the body waits for its worker");
        // A drop that joined its own thread would panic there, and the body
        // would never say it was done: the sender would drop instead.
        told_done
            .recv()
            .expect("the body went on after dropping its own worker");
        assert_eq!(stops.load(Ordering::SeqCst), 1);
    }
}
