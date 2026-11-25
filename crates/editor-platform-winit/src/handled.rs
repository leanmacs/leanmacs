//! How many requests have been sent to a running window and how many of
//! them its loop has carried out: a readout for the contract example, which
//! waits on it before it reads back from the system what a request did.
//!
//! [`WinitPlatform::request`](editor_platform::Platform::request) counts a
//! request as sent before it sends it, and the loop counts each request it
//! took off the channel once a wake-up has carried them all out, on the
//! main thread ([`Handled::handled`]), dropped ones included: a request
//! asked before the window was made, and those a close finds. So once the
//! two counts meet, everything asked so far has been done, and a reading of
//! the window or the menu bar made after that sees it. The wait
//! ([`Handled::wait_all`]) is notified as the loop counts, never a poll.

use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};

use editor_wait::{self as wait, HangGuard};

/// The two counts of one run, and what is notified as they change.
#[derive(Default)]
pub(crate) struct Handled {
    /// The requests sent and the requests carried out.
    counts: Mutex<Counts>,
    /// Signalled when requests have been carried out.
    changed: Condvar,
    /// Called each time [`wait_all`](Self::wait_all) reads the counts,
    /// with them, under the lock. Set once, by a test.
    #[cfg(test)]
    awaited: std::sync::OnceLock<Box<dyn Fn(Counts) + Send + Sync>>,
}

/// What [`Handled::counts`] guards.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Counts {
    /// The requests sent to the run.
    sent: u64,
    /// The requests its loop has carried out.
    handled: u64,
}

impl Handled {
    /// Counts one request as sent. It is called before the request is sent,
    /// so the loop never counts more carried out than sent.
    pub(crate) fn sent(&self) {
        self.counts().sent += 1;
    }

    /// Counts `count` requests as carried out, and wakes the waits.
    pub(crate) fn handled(&self, count: usize) {
        if count == 0 {
            return;
        }
        let mut counts = self.counts();
        counts.handled = counts
            .handled
            .saturating_add(u64::try_from(count).unwrap_or(u64::MAX));
        drop(counts);
        self.changed.notify_all();
    }

    /// Waits until every request sent has been carried out, and says
    /// whether it was: false only once `guard` has run out first.
    ///
    /// `guard` names the loop's count of what it carried out: only a loop
    /// that never carries a request out reaches it. A bound past what the
    /// clock can count is no bound.
    pub(crate) fn wait_all(&self, guard: HangGuard) -> bool {
        let (_counts, all) = wait::wait_while(&self.changed, self.counts(), guard, |counts| {
            #[cfg(test)]
            if let Some(hook) = self.awaited.get() {
                hook(*counts);
            }
            counts.handled < counts.sent
        });
        all
    }

    /// Locks the counts. Nothing runs under the lock, so a poisoned one
    /// still guards consistent counts.
    fn counts(&self) -> MutexGuard<'_, Counts> {
        self.counts.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::mpsc::{self, Receiver};
    use std::thread;
    use std::time::Duration;

    /// hang guard: the wait's next reading, or its answer; only a hang
    /// reaches the bound, and the test then fails as a hang.
    const DEADLINE: HangGuard = HangGuard::on(
        "the wait's next reading, or its answer",
        Duration::from_secs(5),
    );

    /// A guard run out on purpose, at once: the requests not yet carried
    /// out.
    const NOT_YET: HangGuard = HangGuard::held("the requests not yet carried out", Duration::ZERO);

    /// [`Handled::wait_all`], the readout these tests are of: the one place
    /// they call it.
    fn wait_all(handled: &Handled, guard: HangGuard) -> bool {
        #[expect(
            clippy::disallowed_methods,
            reason = "waits for every request sent to be carried out, on `Handled::wait_all`, the readout these tests are of"
        )]
        handled.wait_all(guard)
    }

    /// Where each reading [`Handled::wait_all`] makes on `handled` arrives.
    fn readings(handled: &Handled) -> Receiver<Counts> {
        let (read, readings) = mpsc::channel();
        let read = Mutex::new(read);
        let hook = move |counts| {
            let _ = read
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .send(counts);
        };
        assert!(handled.awaited.set(Box::new(hook)).is_ok(), "set once");
        readings
    }

    #[test]
    fn with_nothing_sent_everything_has_been_carried_out() {
        assert!(wait_all(&Handled::default(), NOT_YET));
    }

    #[test]
    fn a_request_sent_and_not_carried_out_runs_the_wait_out() {
        let handled = Handled::default();
        handled.sent();
        assert!(!wait_all(&handled, NOT_YET));
        handled.handled(1);
        assert!(wait_all(&handled, NOT_YET));
    }

    #[test]
    fn a_wait_begun_before_the_loop_carries_the_request_out_returns_once_it_has() {
        let handled = Arc::new(Handled::default());
        let readings = readings(&handled);
        handled.sent();
        handled.sent();
        let (answer, answered) = mpsc::channel();
        {
            let handled = Arc::clone(&handled);
            thread::spawn(move || {
                let _ = answer.send(wait_all(&handled, DEADLINE));
            });
        }
        assert_eq!(
            wait::recv(&readings, DEADLINE),
            Ok(Counts {
                sent: 2,
                handled: 0
            }),
            "the wait reads none carried out"
        );

        handled.handled(1);
        // A wait that answered at its first reading never reads these.
        assert_eq!(
            wait::recv(&readings, DEADLINE),
            Ok(Counts {
                sent: 2,
                handled: 1
            })
        );
        handled.handled(1);
        assert_eq!(
            wait::recv(&readings, DEADLINE),
            Ok(Counts {
                sent: 2,
                handled: 2
            })
        );
        assert_eq!(wait::recv(&answered, DEADLINE), Ok(true));
    }
}
