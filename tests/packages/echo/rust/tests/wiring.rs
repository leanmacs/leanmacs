//! The C functions over the process's echo service and the process's real
//! completion queue: a request started through them completes on that
//! queue, from the library's source with the service's id and the request's
//! id as its code, and its reply, taken through them, is its text and the
//! text's CRC-32 from the system's zlib.
//!
//! An integration test of its own, because the service and the completion
//! queue are process-wide: it is the one test of its binary.

use std::mem::MaybeUninit;

use echo_service::SERVICE;
use echo_service::ffi::{RawReply, echo_ffi_cancel, echo_ffi_free, echo_ffi_start, echo_ffi_take};
use editor_service::queue::{COMPLETION, Event, Source, SourceKind};

/// Starts the request `id` of `text` through the C function.
fn start(id: u64, text: &str) -> bool {
    // SAFETY: the pointer and length are the string's.
    unsafe { echo_ffi_start(id, text.as_ptr(), text.len()) }
}

/// Takes the reply to `id` through the C functions, its text handed back.
fn take(id: u64) -> Option<(String, u32)> {
    let mut raw = MaybeUninit::<RawReply>::uninit();
    // SAFETY: `raw` is writable; it is read only when it was filled.
    unsafe {
        if !echo_ffi_take(id, raw.as_mut_ptr()) {
            return None;
        }
        let raw = raw.assume_init();
        let text =
            String::from_utf8(std::slice::from_raw_parts(raw.text, raw.text_len).to_vec()).ok();
        echo_ffi_free(raw.text, raw.text_len);
        text.map(|text| (text, raw.checksum))
    }
}

#[test]
fn a_request_started_through_the_c_functions_completes_on_the_completion_queue() {
    let source = Source {
        kind: SourceKind::Library,
        id: SERVICE.id(),
    };
    assert!(start(41, "héllo"));
    // The pull parks until the worker reports.
    assert_eq!(COMPLETION.next(), Event::completion(source, 41));
    assert_eq!(take(41), Some(("héllo".to_owned(), 0x9E3B_8236)));
    assert_eq!(take(41), None);
    assert!(!echo_ffi_cancel(41));
}
