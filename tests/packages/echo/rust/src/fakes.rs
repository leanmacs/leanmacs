//! Hand-written fakes of echo's ports ([`crate::port`]), for its tests: a
//! completer that records each report ([`RecordingCompleter`]), and a child
//! whose pulls a test scripts ([`ScriptedChild`]).

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex, PoisonError};

use editor_wait::HangGuard;

use crate::port::{ChildStreams, Completer, Delivery, Ended, Frames, InputClosed, Pulled};

/// A completer that accepts every report and records it, in order.
#[derive(Debug, Default)]
pub struct RecordingCompleter {
    /// The requests reported and not yet taken.
    requests: Mutex<Vec<u64>>,
    /// Signalled at each report.
    reported: Condvar,
}

impl RecordingCompleter {
    /// A completer that has recorded nothing.
    pub fn new() -> Self {
        Self::default()
    }

    /// The requests reported since the last take, in order, forgotten.
    pub fn take(&self) -> Vec<u64> {
        std::mem::take(&mut *self.requests.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// Waits until `request` has been reported since the last take, and
    /// says whether it was: false only once `guard` ran out first.
    pub fn wait_reported(&self, request: u64, guard: HangGuard) -> bool {
        let requests = self.requests.lock().unwrap_or_else(PoisonError::into_inner);
        let (_requests, reported) =
            editor_wait::wait_while(&self.reported, requests, guard, |requests| {
                !requests.contains(&request)
            });
        reported
    }
}

impl Completer for RecordingCompleter {
    fn complete(&self, request: u64) -> bool {
        self.requests
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(request);
        self.reported.notify_all();
        true
    }
}

/// A child whose pulls a test scripts: each pull answers the next
/// delivery scripted, and [`Pulled::Cancelled`] once there is none. It
/// records every write, and refuses each with [`CLOSED`] when it has no
/// input.
#[derive(Debug)]
pub struct ScriptedChild {
    /// The deliveries left, oldest first.
    pulls: Mutex<VecDeque<Delivery>>,
    /// Whether it has an input.
    input: bool,
    /// Every write, oldest first.
    written: Mutex<Vec<Vec<u8>>>,
}

/// The words a write to a child with no input is refused with.
pub const CLOSED: &str = "the child has no input";

impl ScriptedChild {
    /// A child with an input if `input`, delivering nothing yet.
    pub fn new(input: bool) -> Self {
        Self {
            pulls: Mutex::new(VecDeque::new()),
            input,
            written: Mutex::new(Vec::new()),
        }
    }

    /// This child, delivering `lines` of standard output next, and the end
    /// `ended` with them.
    #[must_use]
    pub fn delivers(self, lines: &[&str], ended: Option<Ended>) -> Self {
        let out = lines.iter().map(|line| line.as_bytes().to_vec()).collect();
        self.pulls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push_back(Delivery {
                out: Frames::Lines(out),
                err: Frames::Lines(Vec::new()),
                ended,
            });
        self
    }

    /// Every write, oldest first.
    pub fn written(&self) -> Vec<Vec<u8>> {
        self.written
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

impl ChildStreams for ScriptedChild {
    fn pull(&self) -> Pulled {
        self.pulls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
            .map_or(Pulled::Cancelled, Pulled::Delivered)
    }

    fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed> {
        self.written
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(bytes);
        if self.input {
            Ok(())
        } else {
            Err(InputClosed(CLOSED.to_owned()))
        }
    }
}
