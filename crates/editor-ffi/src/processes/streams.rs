//! The process's one process service as `editor-service`'s stream source,
//! so that a package's crate takes over a streaming child a job opened
//! ([`editor_service::stream::take_over`]), reaching it through
//! `editor-service` alone.
//!
//! [`PROVIDED`] is what [`editor_ffi_library_start`](super::editor_ffi_library_start)
//! provides. It is a zero-sized value that forwards each take-over to the
//! service ([`super::PROCESSES`]), which is itself a
//! [`StreamSource`]: providing it makes nothing and starts nothing, and a
//! take-over makes the service on its first use as a run or an open does,
//! so a take-over never depends on an open having come first.

use editor_service::stream::{ChildStreams, Refused, StreamSource};

use super::PROCESSES;

/// The process's process service, as a stream source.
pub(super) struct Provided;

/// The one [`Provided`].
pub(super) static PROVIDED: Provided = Provided;

impl StreamSource for Provided {
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused> {
        PROCESSES.take_over(child)
    }
}
