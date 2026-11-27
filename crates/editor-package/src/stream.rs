//! A streaming child the core's process service opened, taken over by a
//! package's library through the runtime: the port ([`StreamSource`],
//! [`ChildStreams`]), with the same names, variants and fields as
//! `editor-service`'s `stream` module, so a crate's logic ports by its
//! imports.
//!
//! The rules are the process service's (`editor-service`'s `stream` module
//! docs): a pull blocks until something is deliverable, the child has
//! ended or it was cancelled; the last delivery says how the child ended,
//! and every pull after it answers [`Pulled::Cancelled`]; one reader; a
//! cancel of the child reaches a consumer parked in a pull; a write blocks
//! until its bytes are in the child's pipe, and is refused with the
//! platform's words ([`InputClosed`]) when the child has no input or ended;
//! one writer at a time, beside a pull.
//!
//! The real adapter is `Child`, a child taken over through the runtime,
//! each pull and write through the runtime's members. Its published fake
//! is `fake::ScriptedChild`; `contract::check` holds both to the same
//! rules.

use crate::frame::{Frames, Stream};

/// How a taken-over child ended, as its last delivery says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ended {
    /// It exited with this status.
    Exited {
        /// Its status.
        code: i32,
    },
    /// It was ended by this signal.
    Signalled {
        /// The signal.
        signal: i32,
    },
    /// A line of this stream was longer than the bound, and its group was
    /// killed.
    LineTooLong {
        /// The stream.
        stream: Stream,
        /// The bound, in bytes.
        bound: u64,
    },
    /// A `Content-Length` message of this stream was longer than the
    /// bound, its header counted, and its group was killed.
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

/// What a pull gives: every frame of both streams not yet taken, and how
/// the child ended, in the last one.
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
    /// No live streaming child of that number: none was opened, it was
    /// cancelled, or its last delivery was taken.
    NoSuchChild,
    /// The job has a read of the child pending.
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
/// own threads. Each call blocks. One writer at a time; a pull may run
/// beside a write.
pub trait ChildStreams: Send + Sync {
    /// The next delivery: blocks until something is deliverable, the child
    /// has ended, or it was cancelled.
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

/// What takes a streaming child over.
pub trait StreamSource: Send + Sync {
    /// Takes the streaming child `child` over.
    ///
    /// # Errors
    ///
    /// Why it was refused.
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused>;
}
