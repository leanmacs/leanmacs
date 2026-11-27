//! The ports echo's service is written over, in echo's own terms: what it
//! reports through ([`Completer`]) and a streaming child it reads
//! ([`ChildStreams`]), with what a pull of one gives.
//!
//! They are echo's, not `editor-service`'s: the crate ships as a library
//! of its own, which reaches the core only through the package runtime it
//! is handed at its init ([`crate::runtime`]), so it depends on nothing of
//! the editor's. The types are the subset of the core's stream rules that
//! [`crate::attach::consume`] reads (`editor-service`'s `stream` module
//! docs say the rules), and [`crate::runtime`] makes them from the
//! runtime's plain data. The tests run on hand-written fakes of both
//! (`crate::fakes`).

/// What a service reports through: that a request has finished.
pub trait Completer: Send + Sync {
    /// Reports that `request` has finished, and answers whether the report
    /// was accepted.
    fn complete(&self, request: u64) -> bool;
}

impl<C: Completer + ?Sized> Completer for &C {
    fn complete(&self, request: u64) -> bool {
        (**self).complete(request)
    }
}

/// One stream's frames, as a pull gives them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frames {
    /// Whole lines, each without its `\n`.
    Lines(Vec<Vec<u8>>),
    /// Bytes.
    Bytes(Vec<u8>),
    /// Whole messages' bodies.
    Messages(Vec<Vec<u8>>),
}

/// How a child ended, as its last delivery says.
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
    /// A line was longer than the bound.
    LineTooLong,
    /// A message was longer than the bound.
    MessageTooLong,
    /// A read failed: the platform's words, or what was wrong.
    Failed(String),
}

/// What a pull delivers: both streams' frames, and the end in the last.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Delivery {
    /// Standard output's frames.
    pub out: Frames,
    /// Standard error's frames.
    pub err: Frames,
    /// How it ended, in its last delivery only.
    pub ended: Option<Ended>,
}

/// What a pull answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pulled {
    /// Frames, and the end once there is one.
    Delivered(Delivery),
    /// Cancelled, shut down, or its last delivery pulled: nothing more.
    Cancelled,
}

/// A write refused: the child's input is closed. The platform's words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputClosed(pub String);

/// A streaming child taken over: pulled and written, each call blocking.
/// One writer at a time; a pull may run beside a write.
pub trait ChildStreams: Send + Sync {
    /// The next delivery, blocking until there is one.
    fn pull(&self) -> Pulled;

    /// Writes every byte of `bytes` to the child's input, blocking.
    ///
    /// # Errors
    ///
    /// [`InputClosed`] when the child's input is closed.
    fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed>;
}
