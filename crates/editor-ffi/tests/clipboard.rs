//! The clipboard handle and its C functions, called the way the C glue
//! calls them.
//!
//! What a clipboard does is the clipboard port's contract
//! (`editor_platform::clipboard::contract`). Here a clipboard of the
//! test's own forwards each call to the C functions of a handle over the
//! port's memory clipboard, and must keep that contract: what is pinned is
//! that the calls and their answers cross. No test reads or writes the
//! desktop's clipboard.
//!
//! This is an integration test of its own, so a process of its own: it
//! counts the live handles of its process.

use std::mem::MaybeUninit;
use std::slice;

use editor_ffi::clipboard::{
    ClipboardHandle, ClipboardRead, editor_ffi_clipboard_free, editor_ffi_clipboard_live,
    editor_ffi_clipboard_memory, editor_ffi_clipboard_read, editor_ffi_clipboard_write,
};
use editor_ffi::document::RawText;
use editor_ffi::text::editor_ffi_text_free;
use editor_platform::clipboard::{Clipboard, ClipboardError, contract};

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

/// A clipboard that is a handle's C functions.
struct OverC(*mut ClipboardHandle);

impl Clipboard for OverC {
    fn read(&self) -> Result<Option<String>, ClipboardError> {
        let mut out = MaybeUninit::<RawText>::uninit();
        // SAFETY: the handle is live, and `out` is writable.
        let (status, text) = unsafe {
            let status = editor_ffi_clipboard_read(self.0, out.as_mut_ptr());
            (status, take_text(out.assume_init()))
        };
        match status {
            status if status == ClipboardRead::Text as u8 => Ok(Some(text)),
            status if status == ClipboardRead::Empty as u8 => Ok(None),
            _ => Err(ClipboardError { reason: text }),
        }
    }

    fn write(&self, text: &str) -> Result<(), ClipboardError> {
        let mut out = MaybeUninit::<RawText>::uninit();
        // SAFETY: the handle is live, `text` is alive for the call, and `out`
        // is writable.
        unsafe {
            if editor_ffi_clipboard_write(self.0, text.as_ptr(), text.len(), out.as_mut_ptr()) {
                Ok(())
            } else {
                Err(ClipboardError {
                    reason: take_text(out.assume_init()),
                })
            }
        }
    }
}

#[test]
fn a_handle_over_the_memory_clipboard_keeps_the_ports_contract_and_is_live_until_freed() {
    let before = editor_ffi_clipboard_live();
    let handle = editor_ffi_clipboard_memory();
    assert_eq!(editor_ffi_clipboard_live(), before + 1);
    let failed = contract::check(&OverC(handle));
    assert!(failed.is_empty(), "{failed:?}");
    // SAFETY: the handle is live and freed once.
    unsafe { editor_ffi_clipboard_free(handle) };
    assert_eq!(editor_ffi_clipboard_live(), before);
}
