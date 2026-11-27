//! The library's table before its init has run: each of its functions
//! answers false, or none, and does nothing, as the glue's forwarders do
//! when no table was loaded. `start` starts nothing, `cancel` cancels
//! nothing, `take` and `attach_take` fill no reply, `attach` takes over no
//! child, and `flush` asks for no completion.
//!
//! An integration test of its own, a process in which nothing calls the
//! init: the library, once loaded, stays loaded for the process
//! (`tests/init.rs` loads it).

#![deny(unsafe_code)]

use echo_service::ffi::{PACKAGE, RawReply};
use editor_package::buffer::{Bytes, Lent, Out};

#[test]
fn each_table_function_answers_false_or_none_before_the_library_is_loaded() {
    let functions = PACKAGE.table().functions();
    assert!(PACKAGE.state().is_none());

    assert!(
        !(functions.start)(41, Bytes::of("héllo".as_bytes())),
        "start"
    );
    assert!(!(functions.cancel)(41), "cancel");
    (functions.flush)(41);
    let mut reply = RawReply {
        text: Lent::empty(),
        checksum: 7,
    };
    assert!(!(functions.take)(41, Out::of(&mut reply)), "take");
    assert!(!(functions.attach)(42, 7), "attach");
    assert!(
        !(functions.attach_take)(42, Out::of(&mut reply)),
        "attach_take"
    );
    assert_eq!(
        (reply.text.as_bytes(), reply.checksum),
        (&b""[..], 7),
        "nothing filled"
    );
}
