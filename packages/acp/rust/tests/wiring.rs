//! The C functions over the process's acp service and the process's real
//! completion queue: a request started through them completes on that
//! queue, from the library's source with the service's id and the
//! request's id as its code, and its reply, taken through them, is the text
//! `event.rs` defines.
//!
//! An integration test of its own, because the service and the completion
//! queue are process-wide: it is the one test of its binary. No stream
//! source is provided in this process, so an `open` or a `load` is refused
//! at its start, as a take-over with no process service is.

use std::mem::MaybeUninit;

use acp_service::ffi::{
    RawReply, SERVICE, acp_ffi_answer, acp_ffi_free, acp_ffi_load, acp_ffi_open, acp_ffi_take,
    acp_ffi_withdraw,
};
use editor_service::queue::{COMPLETION, Event, Source, SourceKind};

/// Takes the reply to `id` through the C functions, its text handed back.
fn take(id: u64) -> Option<String> {
    let mut raw = MaybeUninit::<RawReply>::uninit();
    // SAFETY: `raw` is writable; it is read only when it was filled.
    unsafe {
        if !acp_ffi_take(id, raw.as_mut_ptr()) {
            return None;
        }
        let raw = raw.assume_init();
        let text =
            String::from_utf8(std::slice::from_raw_parts(raw.text, raw.text_len).to_vec()).ok();
        acp_ffi_free(raw.text, raw.text_len);
        text
    }
}

#[test]
fn a_request_started_through_the_c_functions_completes_on_the_completion_queue() {
    let source = Source {
        kind: SourceKind::Library,
        id: SERVICE.id(),
    };
    let option = "allow";
    // SAFETY: the pointer and length are the string's.
    assert!(unsafe { acp_ffi_answer(41, 99, 1, option.as_ptr(), option.len()) });
    // The answer to a session never opened completes at once, refused.
    assert_eq!(COMPLETION.next(), Event::completion(source, 41));
    assert_eq!(
        take(41).as_deref(),
        Some("refused\treason=the session 99 has ended")
    );
    assert_eq!(take(41), None, "taken once");
    assert!(!acp_ffi_withdraw(41));
    let cwd = "/work/example";
    // SAFETY: the pointers and lengths are the strings'.
    let opened = unsafe { acp_ffi_open(42, 7, cwd.as_ptr(), cwd.len(), cwd.as_ptr(), 0) };
    assert!(
        !opened,
        "no stream source in this process: the take-over is refused"
    );
    let session = "sess-0001";
    // SAFETY: the pointers and lengths are the strings'.
    let loaded = unsafe {
        acp_ffi_load(
            43,
            7,
            cwd.as_ptr(),
            cwd.len(),
            cwd.as_ptr(),
            0,
            session.as_ptr(),
            session.len(),
        )
    };
    assert!(!loaded, "a load's take-over is refused the same way");
}
