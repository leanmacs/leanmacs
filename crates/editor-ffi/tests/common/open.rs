//! What the streaming wiring test and the shutdown test share: a
//! streaming child opened through the C function, its command laid out as
//! Lean lays it out, and the wait for it to be held at its bound.

use std::path::Path;

use editor_ffi::processes::{editor_ffi_processes_await_held, editor_ffi_processes_open};

/// Opens `/bin/sh -c script` in `directory` as the streaming child `id`,
/// with lines framing on both streams, its input piped if `piped`, and
/// `bound`, through the C function.
pub fn open(id: u64, script: &str, directory: &Path, piped: bool, bound: u64) -> bool {
    let directory = directory
        .to_str()
        .expect("the temporary directory's path is UTF-8");
    let texts = ["-c", script];
    let program = "/bin/sh";
    // The input, the two framings (lines), then a run's words with the
    // bound for the limit.
    let mut words = vec![u64::from(piped), 0, 0, bound, 0, texts.len() as u64];
    words.extend(texts.iter().map(|text| text.len() as u64));
    words.extend([0, 0, program.len() as u64, directory.len() as u64]);
    let words: Vec<u8> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
    let strings = format!("{}{program}{directory}", texts.concat());
    // SAFETY: the pointers and lengths are those of `words` and `strings`,
    // alive for the call.
    unsafe {
        editor_ffi_processes_open(
            id,
            words.as_ptr(),
            words.len(),
            strings.as_ptr(),
            strings.len(),
        )
    }
}

/// hang guard: a reader's park on the child's bound; only a hang reaches
/// the bound, and the check then fails as a hang. In milliseconds, as the C
/// function takes it.
const HELD_GUARD_MS: u64 = 10_000;

/// Whether the child `id` comes to be held at its bound, on the park
/// itself (`editor_ffi_processes_await_held`).
pub fn comes_to_be_held(id: u64) -> bool {
    editor_ffi_processes_await_held(id, HELD_GUARD_MS)
}
