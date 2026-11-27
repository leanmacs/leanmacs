//! The package runtime the core hands echo's library at its init, as echo
//! uses it: the runtime's definitions (`editor-package-runtime`, the same
//! the generated C header describes), the smallest runtime echo takes
//! ([`REQUIRED`]), and echo's ports over it ([`RuntimeCompleter`],
//! [`RuntimeChild`]).
//!
//! These hand-written ports and their `unsafe` stand until phase 3 of the
//! roadmap `package-native-libraries` gives package crates a safe wrapper
//! over the runtime. The rules they keep are the runtime's (its crate docs,
//! "Who owns what" and "How a pull crosses"):
//!
//! - The runtime is the core's, for the life of the process:
//!   [`RuntimeCompleter`] and [`RuntimeChild`] keep a `&'static` to it, and
//!   hand it to each member they call, first.
//! - A child handle is the core's. [`RuntimeChild`] pulls it from one
//!   thread and writes it from another, and releases it once, on drop.
//! - Every buffer the core lends is handed back once through
//!   `buffer_free`, after it is read: both of a pull's, and a refused
//!   write's words.
//!
//! [`decode`] reads a pull's words and bytes into echo's
//! [`Delivery`]; words it cannot read deliver a
//! failure, never a panic.

use std::mem::{offset_of, size_of};
use std::ptr;

use editor_package_runtime::{
    END_EXITED, END_FAILED, END_LINE_TOO_LONG, END_MESSAGE_TOO_LONG, END_NONE, END_SIGNALLED,
    FRAMING_BYTES, FRAMING_LINES, FRAMING_MESSAGES, PackageChild, PackageRuntime, RawBuffer,
    RawPull,
};

use crate::buffer;
use crate::port::{ChildStreams, Completer, Delivery, Ended, Frames, InputClosed, Pulled};

/// The smallest runtime echo takes: one that ends at `buffer_free`, the
/// last member echo calls, as `runtime_has!` computes it.
pub const REQUIRED: usize = offset_of!(PackageRuntime, buffer_free) + size_of::<usize>();

/// Echo's completer over the runtime: a completion of its service, posted
/// through the runtime's `complete`.
#[derive(Debug, Clone, Copy)]
pub struct RuntimeCompleter {
    /// The core's runtime.
    pub runtime: &'static PackageRuntime,
    /// Echo's service's id, from the runtime's `register_service`.
    pub service: u64,
}

impl Completer for RuntimeCompleter {
    fn complete(&self, request: u64) -> bool {
        // SAFETY: the runtime is the core's, handed to its own member.
        unsafe { (self.runtime.complete)(self.runtime, self.service, request) }
    }
}

/// A child the core took over for echo, as echo's port: each pull and
/// write through the runtime, and the handle released on drop.
#[derive(Debug)]
pub struct RuntimeChild {
    /// The core's runtime.
    runtime: &'static PackageRuntime,
    /// The core's handle of the child.
    handle: *mut PackageChild,
}

// SAFETY: the handle is the core's, which may be pulled from one thread
// and written from another (the core's `ChildStreams` rules); this type
// only hands it back to the core.
unsafe impl Send for RuntimeChild {}

// SAFETY: as for `Send`.
unsafe impl Sync for RuntimeChild {}

impl RuntimeChild {
    /// Takes the child `child` over through `runtime`, or none when the
    /// core refuses.
    pub fn take_over(runtime: &'static PackageRuntime, child: u64) -> Option<Self> {
        let mut handle = ptr::null_mut();
        // SAFETY: the handle's place is writable; the core writes it only
        // when it answers 0.
        let status = unsafe { (runtime.take_over)(runtime, child, &raw mut handle) };
        (status == 0 && !handle.is_null()).then(|| Self { runtime, handle })
    }

    /// The bytes of a buffer the core lent, copied, and the buffer handed
    /// back.
    fn copied(&self, bytes: *mut u8, len: usize) -> Vec<u8> {
        // SAFETY: the core lent `len` readable bytes, read here once and
        // then handed back this once.
        unsafe {
            let copy = buffer::borrow(bytes, len).to_vec();
            // Echo hands each buffer back exactly once, so the core never
            // refuses one: what it answers is not needed.
            let _ = (self.runtime.buffer_free)(self.runtime, bytes, len);
            copy
        }
    }
}

impl ChildStreams for RuntimeChild {
    fn pull(&self) -> Pulled {
        let mut raw = RawPull {
            delivered: false,
            words: ptr::null_mut(),
            words_len: 0,
            bytes: ptr::null_mut(),
            bytes_len: 0,
        };
        // SAFETY: the handle is live until drop, and the record writable.
        unsafe { (self.runtime.child_pull)(self.runtime, self.handle, &raw mut raw) };
        let words = self.copied(raw.words, raw.words_len);
        let bytes = self.copied(raw.bytes, raw.bytes_len);
        if raw.delivered {
            Pulled::Delivered(decode(&words, &bytes))
        } else {
            Pulled::Cancelled
        }
    }

    fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed> {
        let mut refused = RawBuffer {
            bytes: ptr::null_mut(),
            len: 0,
        };
        // SAFETY: the handle is live until drop, the bytes are the vector's
        // for the call, and the record writable.
        let written = unsafe {
            (self.runtime.child_write)(
                self.runtime,
                self.handle,
                bytes.as_ptr(),
                bytes.len(),
                &raw mut refused,
            )
        };
        if written {
            return Ok(());
        }
        let words = self.copied(refused.bytes, refused.len);
        Err(InputClosed(String::from_utf8_lossy(&words).into_owned()))
    }
}

impl Drop for RuntimeChild {
    fn drop(&mut self) {
        // SAFETY: the handle is live, released this once, after the last
        // call.
        unsafe { (self.runtime.child_release)(self.runtime, self.handle) };
    }
}

/// What a delivery says when its words cannot be read.
pub const UNREADABLE: &str = "the runtime's pull could not be read";

/// A pull's words and bytes, read as a delivery: one whose words cannot be
/// read delivers a failure ([`UNREADABLE`]) as its end.
pub fn decode(words: &[u8], bytes: &[u8]) -> Delivery {
    read(words, bytes).unwrap_or_else(|| Delivery {
        out: Frames::Lines(Vec::new()),
        err: Frames::Lines(Vec::new()),
        ended: Some(Ended::Failed(UNREADABLE.to_owned())),
    })
}

/// A reader of words and bytes, front to back.
struct Reader<'a> {
    /// The words left, as bytes.
    words: &'a [u8],
    /// The bytes left.
    bytes: &'a [u8],
}

impl Reader<'_> {
    /// The next word.
    fn word(&mut self) -> Option<u64> {
        let (word, rest) = self.words.split_first_chunk::<8>()?;
        self.words = rest;
        Some(u64::from_le_bytes(*word))
    }

    /// The next word, as a length.
    fn length(&mut self) -> Option<usize> {
        usize::try_from(self.word()?).ok()
    }

    /// The next `len` bytes.
    fn bytes(&mut self, len: usize) -> Option<Vec<u8>> {
        if len > self.bytes.len() {
            return None;
        }
        let (taken, rest) = self.bytes.split_at(len);
        self.bytes = rest;
        Some(taken.to_vec())
    }

    /// One stream's frames.
    fn frames(&mut self) -> Option<Frames> {
        let framing = self.word()?;
        let count = self.length()?;
        let mut frames = Vec::new();
        for _ in 0..count {
            let len = self.length()?;
            frames.push(len);
        }
        let frames = frames
            .into_iter()
            .map(|len| self.bytes(len))
            .collect::<Option<Vec<_>>>()?;
        match framing {
            FRAMING_LINES => Some(Frames::Lines(frames)),
            FRAMING_BYTES => Some(Frames::Bytes(frames.concat())),
            FRAMING_MESSAGES => Some(Frames::Messages(frames)),
            _ => None,
        }
    }
}

/// A pull's words and bytes, read; none when they cannot be.
fn read(words: &[u8], bytes: &[u8]) -> Option<Delivery> {
    let mut reader = Reader { words, bytes };
    let out = reader.frames()?;
    let err = reader.frames()?;
    let (tag, first, _second, failed) = (
        reader.word()?,
        reader.word()?,
        reader.word()?,
        reader.length()?,
    );
    let status = || i32::try_from(first.cast_signed()).ok();
    let ended = match tag {
        END_NONE => None,
        END_EXITED => Some(Ended::Exited { code: status()? }),
        END_SIGNALLED => Some(Ended::Signalled { signal: status()? }),
        END_LINE_TOO_LONG => Some(Ended::LineTooLong),
        END_MESSAGE_TOO_LONG => Some(Ended::MessageTooLong),
        END_FAILED => Some(Ended::Failed(
            String::from_utf8_lossy(&reader.bytes(failed)?).into_owned(),
        )),
        _ => return None,
    };
    let whole = reader.words.is_empty() && reader.bytes.is_empty();
    whole.then_some(Delivery { out, err, ended })
}

#[cfg(test)]
mod tests;
