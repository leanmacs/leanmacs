//! The library's table before its init has run: each of its functions
//! answers false, or none, and does nothing, as the glue's forwarders do
//! when no table was loaded. `start` starts nothing, `cancel` cancels
//! nothing, `take` and `attach_take` fill no reply, `attach` takes over no
//! child, and `flush` asks for no completion.
//!
//! An integration test of its own, a process in which nothing calls the
//! init: the library, once loaded, stays loaded for the process
//! (`tests/init.rs` loads it).

use std::mem::MaybeUninit;

use echo_service::ffi::{RawReply, TABLE};

#[test]
fn each_table_function_answers_false_or_none_before_the_library_is_loaded() {
    let text = "héllo";
    // SAFETY: the pointer and length are the string's, for the call.
    assert!(
        !unsafe { (TABLE.start)(41, text.as_ptr(), text.len()) },
        "start"
    );
    assert!(!(TABLE.cancel)(41), "cancel");
    (TABLE.flush)(41);
    let mut reply = MaybeUninit::<RawReply>::uninit();
    // SAFETY: `reply` is writable; it is never read, since nothing filled
    // it.
    assert!(!unsafe { (TABLE.take)(41, reply.as_mut_ptr()) }, "take");
    assert!(!(TABLE.attach)(42, 7), "attach");
    // SAFETY: as for `take`.
    assert!(
        !unsafe { (TABLE.attach_take)(42, reply.as_mut_ptr()) },
        "attach_take"
    );
}
