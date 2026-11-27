//! acp's init and its table on the package wrapper's fake runtime
//! (`editor_package::fake::FakeRuntime`), as the core's load calls them:
//! the init answers the package's table, the same one twice, and registers
//! the service `acp` once; an answer to a session never opened, started
//! through the table, completes at once through the runtime with that
//! service's id and the request's id, and its reply, taken once through the
//! table, is the text `event.rs` defines, handed back through the table's
//! `free`; an `open` and a `load` of a child the fake's source does not hold
//! are refused at their start, as a take-over of an unknown child is; and
//! every buffer the runtime lent is handed back. No `unsafe`: the wrapper's
//! types make the table's functions safe to call. The init's refusal of no
//! runtime and of one too small is the wrapper's (`editor-package`'s
//! `tests/declare.rs`).
//!
//! An integration test of its own, and one test, because the library's
//! state is process-wide: once loaded, it stays loaded. What the table
//! answers before any init is `tests/not_loaded.rs`, a process of its own
//! that never loads it.

#![deny(unsafe_code)]

use std::ffi::c_void;
use std::ptr;

use acp_service::ffi::{PACKAGE, RawReply, editor_package_init};
use editor_package::buffer::{Bytes, Lent, Out};
use editor_package::fake::FakeRuntime;
use editor_package::raw::INIT_LOADED;

/// A place for a reply that owns nothing yet.
fn place() -> RawReply {
    RawReply {
        text: Lent::empty(),
    }
}

#[test]
fn acp_s_init_on_the_fake_registers_once_and_its_table_answers_refuses_and_hands_back_through_the_runtime()
 {
    let fake = FakeRuntime::new().leak();
    let table: *const c_void = ptr::from_ref(PACKAGE.table()).cast();

    assert_eq!(fake.init(editor_package_init), (INIT_LOADED, table));
    assert_eq!(fake.init(editor_package_init), (INIT_LOADED, table));
    let services = fake.services();
    assert_eq!(services.len(), 1, "registered once");
    let (name, acp) = services[0].clone();
    assert_eq!(name, "acp");
    let functions = PACKAGE.table().functions();

    // The answer to a session never opened completes at once, refused.
    assert!((functions.answer)(41, 99, 1, Bytes::of(b"allow")));
    assert_eq!(fake.next_completion(), Some((acp, 41)));
    let mut reply = place();
    assert!((functions.take)(41, Out::of(&mut reply)));
    assert_eq!(
        reply.text.as_bytes(),
        b"refused\treason=the session 99 has ended"
    );
    (functions.free)(reply.text);
    assert!(!(functions.take)(41, Out::of(&mut place())), "taken once");
    assert!(!(functions.withdraw)(41));

    let cwd = Bytes::of(b"/work/example");
    assert!(
        !(functions.open)(42, 7, cwd, Bytes::of(b"")),
        "no child 7 in the fake's source: the take-over is refused"
    );
    assert!(
        !(functions.load)(43, 7, cwd, Bytes::of(b""), Bytes::of(b"sess-0001")),
        "a load's take-over is refused the same way"
    );
    assert_eq!(
        fake.next_completion(),
        None,
        "a refused start completes nothing"
    );
    assert_eq!(fake.outstanding(), 0, "every lent buffer handed back");
}
