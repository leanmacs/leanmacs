//! The URL opener handle and its C functions, called the way the C glue
//! calls them.
//!
//! What an opener does is the URL opener port's contract
//! (`editor_platform::url_opener::contract`). Here a handle over the port's
//! recording opener and one over its failing opener pin that a URL, a
//! refusal's reason and what was opened cross intact, and that each handle
//! is live until freed. No test reaches the desktop's opener.
//!
//! This is an integration test of its own, so a process of its own: it
//! counts the live handles of its process. Its tests count them in turn,
//! under [`COUNTED`].

use std::mem::MaybeUninit;
use std::slice;
use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_ffi::document::RawText;
use editor_ffi::text::editor_ffi_text_free;
use editor_ffi::url_opener::{
    UrlOpenerHandle, editor_ffi_url_opener_failing, editor_ffi_url_opener_free,
    editor_ffi_url_opener_live, editor_ffi_url_opener_open, editor_ffi_url_opener_opened,
    editor_ffi_url_opener_recording,
};
use editor_platform::url_opener::{UrlOpenError, UrlOpener, contract};

/// Held by each test while it counts the live handles, so that no other
/// test's handle is counted with its own.
static COUNTED: Mutex<()> = Mutex::new(());

/// The count's lock. A test that failed while holding it left no handle
/// half made, so a poisoned lock is still a whole one.
fn counting() -> MutexGuard<'static, ()> {
    COUNTED.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The text of a filled record, its buffer handed back.
///
/// # Safety
///
/// `raw` was filled by the library, and its buffer has not been handed
/// back.
unsafe fn take_text(raw: RawText) -> String {
    // SAFETY: the record's buffer is `text_len` bytes, owned until handed
    // back.
    let bytes = unsafe { slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, handed back
    // once.
    unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
    String::from_utf8(bytes).expect("the library lends UTF-8")
}

/// An opener that is a handle's C functions.
struct OverC(*mut UrlOpenerHandle);

// SAFETY: the handle's opener is `Send + Sync`, and the tests use it from
// one thread.
unsafe impl Send for OverC {}
// SAFETY: as above.
unsafe impl Sync for OverC {}

impl UrlOpener for OverC {
    fn open(&self, url: &str) -> Result<(), UrlOpenError> {
        let mut out = MaybeUninit::<RawText>::uninit();
        // SAFETY: the handle is live, `url` is alive for the call, and `out`
        // is writable.
        unsafe {
            if editor_ffi_url_opener_open(self.0, url.as_ptr(), url.len(), out.as_mut_ptr()) {
                Ok(())
            } else {
                Err(UrlOpenError {
                    reason: take_text(out.assume_init()),
                })
            }
        }
    }
}

/// What the handle's recording opener was handed, read through its C
/// function; `None` for a handle over another opener.
fn opened(handle: *mut UrlOpenerHandle) -> Option<String> {
    let mut out = MaybeUninit::<RawText>::uninit();
    // SAFETY: the handle is live and `out` is writable; the record is filled
    // only when the call answers true.
    unsafe {
        editor_ffi_url_opener_opened(handle, out.as_mut_ptr()).then(|| take_text(out.assume_init()))
    }
}

#[test]
fn a_handle_over_the_recording_opener_keeps_each_url_intact_in_order_and_is_live_until_freed() {
    let _counting = counting();
    let before = editor_ffi_url_opener_live();
    let handle = editor_ffi_url_opener_recording();
    assert_eq!(editor_ffi_url_opener_live(), before + 1);
    assert_eq!(opened(handle), Some(String::new()));

    let opener = OverC(handle);
    let urls = [
        "https://example.com/a b?x=1&y=2#frag",
        "",
        "https://例え.jp/é",
    ];
    for url in urls {
        assert_eq!(opener.open(url), Ok(()));
    }
    // Each URL is followed by a NUL byte, the empty one too.
    assert_eq!(
        opened(handle),
        Some("https://example.com/a b?x=1&y=2#frag\0\0https://例え.jp/é\0".to_owned())
    );
    // And the port's contract holds across the boundary.
    let failed = contract::check(&opener);
    assert!(failed.is_empty(), "{failed:?}");

    // SAFETY: the handle is live and freed once.
    unsafe { editor_ffi_url_opener_free(handle) };
    assert_eq!(editor_ffi_url_opener_live(), before);
}

#[test]
fn a_handle_over_a_failing_opener_answers_false_with_the_reason_and_reads_back_nothing() {
    let _counting = counting();
    let reason = "aucun gestionnaire: é";
    let before = editor_ffi_url_opener_live();
    // SAFETY: `reason` is alive for the call.
    let handle = unsafe { editor_ffi_url_opener_failing(reason.as_ptr(), reason.len()) };
    assert_eq!(editor_ffi_url_opener_live(), before + 1);

    assert_eq!(
        OverC(handle).open("https://example.com"),
        Err(UrlOpenError {
            reason: reason.to_owned()
        })
    );
    // Only a recording opener says what it was handed.
    assert_eq!(opened(handle), None);

    // SAFETY: the handle is live and freed once.
    unsafe { editor_ffi_url_opener_free(handle) };
    assert_eq!(editor_ffi_url_opener_live(), before);
}
