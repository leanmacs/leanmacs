//! The package runtime the core hands echo's library at its init, as echo
//! sees it: a hand-written mirror of the core's struct ([`Runtime`]; the
//! core's is `editor_package_library::runtime::PackageRuntime`), and echo's
//! ports over it ([`RuntimeCompleter`], [`RuntimeChild`]).
//!
//! Phase 1 of the roadmap `package-native-libraries` allows this mirror
//! and its `unsafe`; phase 2 generates the header from the core's
//! definition. The rules it keeps are the core's (its runtime module's
//! docs, "Who owns what" and "How a pull crosses"):
//!
//! - The runtime is the core's static: [`RuntimeCompleter`] and
//!   [`RuntimeChild`] keep a `&'static` to it.
//! - A child handle is the core's. [`RuntimeChild`] pulls it from one
//!   thread and writes it from another, and releases it once, on drop.
//! - Every buffer the core lends is handed back once through
//!   `buffer_free`, after it is read: both of a pull's, and a refused
//!   write's words.
//!
//! [`decode`] reads a pull's words and bytes into echo's
//! [`Delivery`]; words it cannot read deliver a
//! failure, never a panic.

use std::ffi::c_void;
use std::mem::size_of;
use std::ptr;

use crate::buffer;
use crate::port::{ChildStreams, Completer, Delivery, Ended, Frames, InputClosed, Pulled};

/// The core's runtime, mirrored field for field: its size, then a function
/// pointer for each capability.
#[repr(C)]
#[derive(Debug)]
pub struct Runtime {
    /// The size of the runtime the core hands: checked against
    /// [`REQUIRED`] before any member is used.
    pub size: usize,
    /// Registers a service of the name lent for the call, and answers its
    /// id.
    pub register_service: unsafe extern "C" fn(name: *const u8, len: usize) -> u64,
    /// Posts a completion of `request` from `service`; false when refused.
    pub complete: extern "C" fn(service: u64, request: u64) -> bool,
    /// Takes the child over, writing its handle, and answers 0; or a
    /// refusal's tag.
    pub take_over: unsafe extern "C" fn(child: u64, handle: *mut *mut c_void) -> u32,
    /// Pulls the child, filling the record.
    pub child_pull: unsafe extern "C" fn(handle: *mut c_void, out: *mut RawPull),
    /// Writes to the child's input; false with the words lent when refused.
    pub child_write: unsafe extern "C" fn(
        handle: *mut c_void,
        bytes: *const u8,
        len: usize,
        refused: *mut RawBuffer,
    ) -> bool,
    /// Releases the child, once.
    pub child_release: unsafe extern "C" fn(handle: *mut c_void),
    /// Hands back a buffer the core lent.
    pub buffer_free: unsafe extern "C" fn(bytes: *mut u8, len: usize),
}

/// The smallest runtime echo takes: every member above.
pub const REQUIRED: usize = size_of::<Runtime>();

/// A pull as it crosses: whether it delivered, and two lent buffers.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RawPull {
    /// Whether frames, or the end, were delivered.
    pub delivered: bool,
    /// The words, little-endian `u64`s.
    pub words: *mut u8,
    /// The length of `words` in bytes.
    pub words_len: usize,
    /// The frames and the failed words, end to end.
    pub bytes: *mut u8,
    /// The length of `bytes`.
    pub bytes_len: usize,
}

/// A buffer the core lends.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct RawBuffer {
    /// The bytes.
    pub bytes: *mut u8,
    /// How many.
    pub len: usize,
}

/// Echo's completer over the runtime: a completion of its service, posted
/// through the runtime's `complete`.
#[derive(Debug, Clone, Copy)]
pub struct RuntimeCompleter {
    /// The core's runtime.
    pub runtime: &'static Runtime,
    /// Echo's service's id, from the runtime's `register_service`.
    pub service: u64,
}

impl Completer for RuntimeCompleter {
    fn complete(&self, request: u64) -> bool {
        (self.runtime.complete)(self.service, request)
    }
}

/// A child the core took over for echo, as echo's port: each pull and
/// write through the runtime, and the handle released on drop.
#[derive(Debug)]
pub struct RuntimeChild {
    /// The core's runtime.
    runtime: &'static Runtime,
    /// The core's handle of the child.
    handle: *mut c_void,
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
    pub fn take_over(runtime: &'static Runtime, child: u64) -> Option<Self> {
        let mut handle = ptr::null_mut();
        // SAFETY: the handle's place is writable; the core writes it only
        // when it answers 0.
        let status = unsafe { (runtime.take_over)(child, &raw mut handle) };
        (status == 0 && !handle.is_null()).then(|| Self { runtime, handle })
    }

    /// The bytes of a buffer the core lent, copied, and the buffer handed
    /// back.
    fn copied(&self, bytes: *mut u8, len: usize) -> Vec<u8> {
        // SAFETY: the core lent `len` readable bytes, read here once and
        // then handed back this once.
        unsafe {
            let copy = buffer::borrow(bytes, len).to_vec();
            (self.runtime.buffer_free)(bytes, len);
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
        unsafe { (self.runtime.child_pull)(self.handle, &raw mut raw) };
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
            (self.runtime.child_write)(self.handle, bytes.as_ptr(), bytes.len(), &raw mut refused)
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
        unsafe { (self.runtime.child_release)(self.handle) };
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
            0 => Some(Frames::Lines(frames)),
            1 => Some(Frames::Bytes(frames.concat())),
            2 => Some(Frames::Messages(frames)),
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
        0 => None,
        1 => Some(Ended::Exited { code: status()? }),
        2 => Some(Ended::Signalled { signal: status()? }),
        3 => Some(Ended::LineTooLong),
        4 => Some(Ended::MessageTooLong),
        5 => Some(Ended::Failed(
            String::from_utf8_lossy(&reader.bytes(failed)?).into_owned(),
        )),
        _ => return None,
    };
    let whole = reader.words.is_empty() && reader.bytes.is_empty();
    whole.then_some(Delivery { out, err, ended })
}

#[cfg(test)]
mod tests;
