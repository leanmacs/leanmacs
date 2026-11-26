//! A streaming child the core's process service opened, taken over by a
//! package's crate: the port [`StreamSource`], the process's one source
//! ([`provide`], [`take_over`]), its published fake ([`fake::FakeSource`])
//! and its contract ([`contract::check`]).
//!
//! The core's process service owns every child: its spawn, environment,
//! group, kill, reap and shutdown. A Lean job opens a streaming child as it
//! always has; it then hands the child's number to a package's binding,
//! whose crate calls [`take_over`]. From then on the crate's own thread
//! pulls the child's framed streams with [`ChildStreams::pull`] and writes
//! its input with [`ChildStreams::write`], Rust to Rust, and the job reads
//! the child no more. Rust still never calls Lean: the crate reports
//! through its own service's completions.
//!
//! # The rules
//!
//! - **A package's crate depends on this crate alone.** It names no type
//!   of `editor-process`: the process service is reached through the port
//!   [`StreamSource`], in the editor's terms, which the crate that holds
//!   the process's one process service (`editor-ffi`) provides once, when
//!   the library starts ([`provide`]). The frames are [`frame`](crate::frame)'s,
//!   the same type the process service makes, and how a child ended is
//!   [`Ended`], this crate's own.
//! - **One static.** The editor is linked from one Rust archive, so the
//!   process holds one copy of this crate, and [`take_over`] reaches the
//!   source `editor-ffi` provided, whichever crate calls it.
//! - **A pull is the job's read and take in one call.** It blocks until
//!   something is deliverable, the child has ended, or it was cancelled,
//!   and drains what it delivers, which makes room under the bound and
//!   wakes a reader parked on it. So a consumer that does not pull holds
//!   the child at its bound exactly as a job that does not read does, and
//!   nothing is ever dropped. The last delivery says how the child ended
//!   ([`Delivery::ended`]), and the child is then forgotten.
//! - **One reader.** A child with a job's read pending is refused
//!   ([`Refused::ReadPending`]): the job takes or cancels its read first.
//!   Once taken over, the job's reads, writes and closes of it are refused,
//!   and a second take-over is refused ([`Refused::Taken`]).
//! - **The process service stays the owner.** A cancel of the child (the
//!   job's end) and the service's shutdown reach a consumer blocked in a
//!   pull, which answers [`Pulled::Cancelled`].
//! - **A write blocks** until every byte is in the child's pipe; a child
//!   that has no input, closed it, or ended answers [`InputClosed`] with
//!   the platform's words. Nothing is buffered beyond the pipe.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Another way a taken-over child can end | A variant of [`Ended`], which the process service's `End::ended` maps to | A property of [`contract`] that asks for it, and `End::ended`'s unit test in `editor-process` |
//! | A rule every source keeps | A property of [`contract::check`], a [`contract::Scenario`] for its child, and a flaw of [`fake::Flaws`] that breaks it | The contract's own tests, on the fake and on fakes written to break it; `editor-process`'s `tests/stream_contract.rs` and `editor-process-std`'s on the real service |
//! | Another way for a test to step the fake | A method of [`fake::FakeChild`] | The fake's unit tests |

pub mod contract;
pub mod fake;

use std::sync::OnceLock;

use crate::frame::{Frames, Stream};

/// How a taken-over child ended, as its last delivery says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ended {
    /// It exited with this status, once both streams ended, every frame
    /// was delivered and it was reaped.
    Exited {
        /// Its status.
        code: i32,
    },
    /// It was ended by this signal.
    Signalled {
        /// The signal.
        signal: i32,
    },
    /// A line of this stream was longer than the bound, so could never be
    /// delivered whole, and its group was killed.
    LineTooLong {
        /// The stream.
        stream: Stream,
        /// The bound, in bytes.
        bound: u64,
    },
    /// A `Content-Length` message of this stream was longer than the
    /// bound, its header counted, and its group was killed before its body
    /// was read.
    MessageTooLong {
        /// The stream.
        stream: Stream,
        /// The bound, in bytes.
        bound: u64,
    },
    /// A read failed, or a message's header broke a rule, and its group
    /// was killed: the platform's words, or what was wrong.
    Failed(String),
}

/// What a pull gives: every frame of both streams read and not yet taken,
/// and how the child ended, in the last one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Delivery {
    /// Standard output's frames.
    pub out: Frames,
    /// Standard error's frames.
    pub err: Frames,
    /// How it ended, in its last delivery only.
    pub ended: Option<Ended>,
}

/// What [`ChildStreams::pull`] answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pulled {
    /// Frames, and the end once there is one.
    Delivered(Delivery),
    /// The child was cancelled, the service shut down, or its last
    /// delivery was pulled already: nothing more comes.
    Cancelled,
}

/// Why a take-over was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Refused {
    /// No source has been provided in this process.
    NoService,
    /// The source holds no live streaming child of that number: none was
    /// opened, it was cancelled, or its last delivery was taken.
    NoSuchChild,
    /// The job has a read of the child pending: it takes or cancels it
    /// first.
    ReadPending,
    /// The child was taken over already.
    Taken,
}

/// A write refused because the child's standard input is closed: none was
/// asked for, the child closed it, or it ended or was cancelled. The
/// platform's words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputClosed(pub String);

/// A streaming child, taken over: pulled and written from the consumer's
/// own thread. Each call blocks.
pub trait ChildStreams: Send + Sync {
    /// The next delivery: blocks until something is deliverable, the child
    /// has ended, or it was cancelled, and drains it. A consumer that does
    /// not pull holds the child at its bound; nothing is dropped.
    fn pull(&self) -> Pulled;

    /// Writes every byte of `bytes` to the child's standard input, and
    /// blocks until they are in its pipe.
    ///
    /// # Errors
    ///
    /// [`InputClosed`] when the child has no input, closed it, or ended or
    /// was cancelled.
    fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed>;
}

/// What takes a streaming child over: the process service, as this crate
/// sees it.
pub trait StreamSource: Send + Sync {
    /// Takes the streaming child `child` over.
    ///
    /// # Errors
    ///
    /// Why it was refused: no such live child, a read of the job's pending,
    /// or taken already.
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused>;
}

/// The process's one source, once provided.
static SOURCE: OnceLock<&'static dyn StreamSource> = OnceLock::new();

/// Provides the process's one source, and says whether this was the first
/// call: a later one changes nothing. `editor-ffi` calls it when the
/// library starts, before Lean runs.
pub fn provide(source: &'static dyn StreamSource) -> bool {
    SOURCE.set(source).is_ok()
}

/// Takes the streaming child `child` over, through the source provided.
///
/// # Errors
///
/// [`Refused::NoService`] before a source is provided, and otherwise the
/// source's refusal.
pub fn take_over(child: u64) -> Result<Box<dyn ChildStreams>, Refused> {
    SOURCE.get().ok_or(Refused::NoService)?.take_over(child)
}
