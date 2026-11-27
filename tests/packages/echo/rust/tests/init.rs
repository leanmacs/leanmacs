//! echo's init and its table on the wrapper's fake runtime
//! (`editor_package::fake::FakeRuntime`), as the core's load calls them:
//! the init answers the package's table, the same one twice, and registers
//! the service `echo` once; a request started through the table completes
//! through the runtime with that service's id, and its reply, taken through
//! the table, is its text and the text's CRC-32, handed back through the
//! table's `free`; an attached request reads a scripted child through the
//! runtime's members, answering `pong` to `ping-me`, and completes; an
//! unknown child is refused; and every buffer the runtime lent is handed
//! back. No `unsafe`: the wrapper's types make the table's functions safe
//! to call. The init's refusal of no runtime and of one too small is the
//! wrapper's (`editor-package`'s `tests/declare.rs`).
//!
//! An integration test of its own, and one test, because the library's
//! state is process-wide: once loaded, it stays loaded. What the table
//! answers before any init is `tests/not_loaded.rs`, a process of its own
//! that never loads it.

#![deny(unsafe_code)]

use std::ffi::c_void;
use std::ptr;
use std::time::Duration;

use echo_service::ffi::{PACKAGE, RawReply, editor_package_init};
use editor_package::buffer::{Bytes, Lent, Out};
use editor_package::fake::FakeRuntime;
use editor_package::raw::INIT_LOADED;
use editor_package::stream::Ended;
use editor_package::stream::fake::{ScriptedChild, ScriptedSource};
use editor_package::wait::HangGuard;

/// hang guard: the completion each wait ends on, posted from echo's
/// worker; only a hang reaches the bound.
const COMPLETION: HangGuard = HangGuard::on("the request's completion", Duration::from_secs(10));

/// A place for a reply that owns nothing yet.
fn place() -> RawReply {
    RawReply {
        text: Lent::empty(),
        checksum: 0,
    }
}

#[test]
fn echo_s_init_on_the_fake_registers_once_and_its_table_starts_attaches_and_hands_back_through_the_runtime()
 {
    let source = ScriptedSource::new();
    let scripted = ScriptedChild::new(true)
        .delivers(&["one", "ping-me"], None)
        .delivers(&[], Some(Ended::Exited { code: 0 }));
    let child = source.add(scripted.clone());
    let fake = FakeRuntime::over(Box::leak(Box::new(source))).leak();
    let table: *const c_void = ptr::from_ref(PACKAGE.table()).cast();

    assert_eq!(fake.init(editor_package_init), (INIT_LOADED, table));
    assert_eq!(fake.init(editor_package_init), (INIT_LOADED, table));
    let services = fake.services();
    assert_eq!(services.len(), 1, "registered once");
    let (name, echo) = services[0].clone();
    assert_eq!(name, "echo");
    let functions = PACKAGE.table().functions();

    assert!((functions.start)(41, Bytes::of("héllo".as_bytes())));
    assert!(fake.wait_completed(echo, 41, COMPLETION), "{COMPLETION}");
    let mut reply = place();
    assert!((functions.take)(41, Out::of(&mut reply)));
    assert_eq!(reply.text.as_bytes(), "héllo".as_bytes());
    assert_eq!(reply.checksum, 0x9E3B_8236);
    (functions.free)(reply.text);
    assert!(!(functions.take)(41, Out::of(&mut place())), "taken once");
    assert!(!(functions.cancel)(41));

    assert!((functions.attach)(42, child));
    assert!(fake.wait_completed(echo, 42, COMPLETION), "{COMPLETION}");
    let mut read = place();
    assert!((functions.attach_take)(42, Out::of(&mut read)));
    assert_eq!(read.text.as_bytes(), b"one\nping-me\n<exited 0>");
    assert_eq!(read.checksum, 2, "two pulls");
    (functions.free)(read.text);
    assert_eq!(scripted.written(), [b"pong\n".to_vec()]);

    assert!(!(functions.attach)(43, 999), "an unknown child");
    assert_eq!(fake.outstanding(), 0, "every lent buffer handed back");
}
