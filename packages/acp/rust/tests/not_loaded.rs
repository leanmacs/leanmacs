//! The library's table before its init has run: each of its functions
//! answers false, or none, and does nothing, as the glue's forwarders do
//! when no table was loaded. `open` and `load` open no session, `next`,
//! `prompt`, `cancel_turn`, `set_mode` and `answer` start nothing, `take`
//! fills no reply, `withdraw` withdraws nothing, and `flush` asks for no
//! completion.
//!
//! An integration test of its own, a process in which nothing calls the
//! init: the library, once loaded, stays loaded for the process
//! (`tests/init.rs` loads it).

#![deny(unsafe_code)]

use acp_service::ffi::{PACKAGE, RawReply};
use editor_package::buffer::{Bytes, Lent, Out};

#[test]
fn each_table_function_answers_false_or_none_before_the_library_is_loaded() {
    let functions = PACKAGE.table().functions();
    assert!(PACKAGE.state().is_none());

    let cwd = Bytes::of(b"/work/example");
    let none = Bytes::of(b"");
    assert!(!(functions.open)(41, 7, cwd, none), "open");
    assert!(
        !(functions.load)(42, 7, cwd, none, Bytes::of(b"sess-0001")),
        "load"
    );
    assert!(!(functions.next)(43, 1), "next");
    assert!(!(functions.prompt)(44, 1, Bytes::of(b"hello")), "prompt");
    assert!(!(functions.cancel_turn)(45, 1), "cancel_turn");
    assert!(!(functions.set_mode)(46, 1, Bytes::of(b"plan")), "set_mode");
    assert!(!(functions.answer)(47, 1, 1, Bytes::of(b"allow")), "answer");
    (functions.flush)(48);
    let mut reply = RawReply {
        text: Lent::empty(),
    };
    assert!(!(functions.take)(47, Out::of(&mut reply)), "take");
    assert!(!(functions.withdraw)(47), "withdraw");
    assert_eq!(reply.text.as_bytes(), b"", "nothing filled");
}
