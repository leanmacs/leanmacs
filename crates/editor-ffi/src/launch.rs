//! The editor's restart and its view of the app: an exec of another
//! program in this process ([`editor_ffi_exec`]), and CoreFoundation's main
//! bundle ([`editor_ffi_main_bundle`]). Both are thin forwards to the
//! launcher's adapters (`editor-launch-std`'s `StdExec` and
//! `identity::main_bundle`), so the editor and the launcher exec and read
//! the bundle the same way.

use std::path::PathBuf;

use editor_launch::ports::{Exec, Invocation, Refusal};
use editor_launch_std::StdExec;

use crate::document::RawText;
use crate::processes::command_of;
use crate::text;

/// Writes `text` into `out`, lent to the caller.
///
/// # Safety
///
/// `out` points to a writable [`RawText`].
unsafe fn lend_into(out: *mut RawText, text: String) {
    let (text, text_len) = text::lend(text);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawText { text, text_len }) };
}

/// The exec of the command the words and the string spell, in the layout
/// of a run's command ([`command_of`]), whose limit and directory an exec
/// does not use and whose `clear` it refuses. The program gets this
/// process's id and standard streams. It answers only when the exec failed:
/// `out` is then filled with the reason, which names the program.
///
/// # Safety
///
/// `words` points to `words_len` readable bytes and `strings` to
/// `strings_len`, both unchanged for the call (no bytes at all may be lent
/// with any pointer), and `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_exec(
    words: *const u8,
    words_len: usize,
    strings: *const u8,
    strings_len: usize,
    out: *mut RawText,
) {
    // SAFETY: the caller guarantees each pointer and its length.
    let (words, strings) = unsafe {
        (
            crate::words::borrow(words, words_len),
            crate::words::borrow(strings, strings_len),
        )
    };
    let reason = match command_of(words, strings) {
        None => "the exec's words spell no command".to_owned(),
        Some((command, _)) if command.environment.clear => {
            format!(
                "{}: an exec keeps the editor's environment and cannot clear it",
                command.program
            )
        }
        Some((command, _)) => {
            let invocation = Invocation {
                program: PathBuf::from(&command.program),
                args: command.arguments.into_iter().map(Into::into).collect(),
                set: command
                    .environment
                    .set
                    .into_iter()
                    .map(|(name, value)| (name.into(), value.into()))
                    .collect(),
                unset: command
                    .environment
                    .unset
                    .into_iter()
                    .map(Into::into)
                    .collect(),
            };
            match StdExec.exec(&invocation) {
                Refusal::NotFound(reason) | Refusal::Refused(reason) => reason,
                Refusal::Faked => format!("{}: not exec'd", command.program),
            }
        }
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { lend_into(out, reason) };
}

/// CoreFoundation's main bundle as this process sees it: 0 when there is
/// none (any system but macOS), 1 when there is one with no identifier, 2
/// when it has one. With 1 or 2, `path` is filled with the bundle's path;
/// with 2, `identifier` with its `CFBundleIdentifier`.
///
/// # Safety
///
/// `path` and `identifier` point to writable [`RawText`]s.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_main_bundle(
    path: *mut RawText,
    identifier: *mut RawText,
) -> u8 {
    match editor_launch_std::identity::main_bundle() {
        None => 0,
        Some((bundle, id)) => {
            // SAFETY: the caller guarantees `path` is writable.
            unsafe { lend_into(path, bundle.to_string_lossy().into_owned()) };
            match id {
                None => 1,
                Some(id) => {
                    // SAFETY: the caller guarantees `identifier` is writable.
                    unsafe { lend_into(identifier, id) };
                    2
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::mem::MaybeUninit;

    use editor_process::{Command, Environment};

    use super::*;
    use crate::processes::tests::laid_out;

    fn exec(command: &Command) -> String {
        let (words, strings) = laid_out(command, 0);
        let mut out = MaybeUninit::<RawText>::uninit();
        // SAFETY: the words and string live for the call, and `out` is
        // writable.
        let raw = unsafe {
            editor_ffi_exec(
                words.as_ptr(),
                words.len(),
                strings.as_ptr(),
                strings.len(),
                out.as_mut_ptr(),
            );
            out.assume_init()
        };
        // SAFETY: the library lent the buffer; it is handed back once.
        let text = unsafe { std::slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
        // SAFETY: as above.
        unsafe { text::editor_ffi_text_free(raw.text, raw.text_len) };
        String::from_utf8(text).unwrap()
    }

    #[test]
    fn an_exec_of_a_missing_program_answers_a_reason_naming_it_and_returns() {
        let reason = exec(&Command::new("/nonexistent/leanmacs-exec", ["a"], "/"));
        assert!(
            reason.starts_with("/nonexistent/leanmacs-exec: "),
            "{reason}"
        );
    }

    #[test]
    fn an_exec_that_would_clear_the_environment_is_refused_before_it_runs() {
        let command = Command::new("/bin/true", [""; 0], "/").with_environment(Environment {
            clear: true,
            ..Environment::default()
        });
        assert!(exec(&command).contains("cannot clear"));
    }

    #[test]
    fn words_that_spell_no_command_are_a_reason() {
        let mut out = MaybeUninit::<RawText>::uninit();
        // SAFETY: no bytes are lent, and `out` is writable.
        let raw = unsafe {
            editor_ffi_exec(std::ptr::null(), 0, std::ptr::null(), 0, out.as_mut_ptr());
            out.assume_init()
        };
        // SAFETY: the library lent the buffer; it is handed back once.
        let text = unsafe { std::slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
        // SAFETY: as above.
        unsafe { text::editor_ffi_text_free(raw.text, raw.text_len) };
        assert_eq!(text, b"the exec's words spell no command");
    }

    #[test]
    fn the_main_bundle_is_there_on_macos_only() {
        let mut path = MaybeUninit::<RawText>::uninit();
        let mut identifier = MaybeUninit::<RawText>::uninit();
        // SAFETY: both records are writable.
        let status = unsafe { editor_ffi_main_bundle(path.as_mut_ptr(), identifier.as_mut_ptr()) };
        if cfg!(target_os = "macos") {
            assert_eq!(
                status, 1,
                "a test binary is in no bundle, so it has no identifier"
            );
            // SAFETY: status 1 filled `path`, lent to us; handed back once.
            unsafe {
                let raw = path.assume_init();
                text::editor_ffi_text_free(raw.text, raw.text_len);
            }
        } else {
            assert_eq!(status, 0);
        }
    }
}
