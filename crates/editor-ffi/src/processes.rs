//! The process service: commands run to their end, and streaming children
//! read and written a request at a time, completed through the completion
//! queue.
//!
//! This is the third service behind the completion queue, in the shape of
//! the timer and the file services (the crate docs, "Services and
//! completions"). A job in Lean asks for a run with an id
//! ([`editor_ffi_processes_run`]); it returns at once, the service's run
//! thread does the work, keeps the result under the id and queues an
//! [`EventKind::Completion`](crate::events::EventKind::Completion) whose code
//! is the id; the caller then takes the result once
//! ([`editor_ffi_processes_take`]). Rust never calls Lean.
//!
//! What a run does, and every rule of the service (which commands are
//! refused before a spawn, the output limit, what cancelling means, that
//! shutdown kills every group and reaps every child) is `editor-process`'s
//! ([`editor_process::service::Service`]), pinned there on the port's fake
//! and, by the contract, on real processes. This module only takes a
//! command apart, forwards, and lays a result out.
//!
//! The pieces:
//!
//! - [`command_of`] reads a command and its limit from words and one
//!   string, trusting nothing.
//! - [`encoded`] lays a [`RunResult`] out as a status, words, a detail and
//!   the two streams.
//! - [`open_of`] reads an open of a streaming child, and [`encoded_stream`]
//!   lays a reply about one out in the same record.
//! - The process has one service, over the machine's processes
//!   (`editor_process_std::StdProcesses`), in a static made on its first
//!   use. That static is the one place in this crate's sources that makes
//!   the adapter: the crate's `clippy.toml` refuses its constructor
//!   everywhere else, so the unit tests below run on the fake and start no
//!   process.
//!
//! # How a command crosses
//!
//! Words, then one string that holds every text of the command end to end,
//! in the words' order:
//!
//! | Words | Then |
//! |---|---|
//! | the limit, in bytes, of each stream | |
//! | clear: 0 or 1 | |
//! | the count of arguments | the byte length of each |
//! | the count of variables set | the byte lengths of each name and its value |
//! | the count of variables unset | the byte length of each |
//! | the byte length of the program | |
//! | the byte length of the directory | |
//!
//! Words that cannot be read, a clear that is neither 0 nor 1, lengths that
//! do not add up to the string, a length that ends inside a character, and
//! a string that is not UTF-8 are refused: the run is not started and the
//! call returns false.
//!
//! # How a result crosses
//!
//! [`editor_ffi_processes_take`] fills a [`RawProcessResult`]: a status,
//! words, a detail string and the two streams' bytes, each a buffer the
//! caller hands back with [`editor_ffi_text_free`](crate::text::editor_ffi_text_free).
//!
//! | Result | Status | Words |
//! |---|---|---|
//! | Ran | 0 | the exit's kind (0 a status, 1 a signal), then its number |
//! | The directory is not absolute | 1 | |
//! | The program is not absolute and names a directory | 2 | |
//! | Not found | 3 | |
//! | Denied | 4 | |
//! | A stream past the limit | 5 | the stream (0 out, 1 err), the limit |
//! | Shut down | 6 | |
//! | Failed | 7 | |
//!
//! Every refusal carries its detail, the platform's words naming the
//! program and the directory. The streams are empty but for a run that
//! ran.
//!
//! # How a streaming child crosses
//!
//! An open's words are three, then a run's words above, then its string:
//!
//! | Words | Then |
//! |---|---|
//! | the input: 0 closed, 1 a pipe | |
//! | the framing of standard output: 0 lines, 1 bytes | |
//! | the framing of standard error, the same | |
//! | a run's words, whose limit is the bound | a run's string |
//!
//! Words that spell no open are refused: the child is not started and the
//! call returns false. The child is named by the open's id from then on;
//! each read, write and close is a wait with an id of its own, completed
//! once on the completion queue. Every reply crosses as a
//! [`RawStreamReply`], the record of a run's result:
//!
//! | Reply | Status | Words |
//! |---|---|---|
//! | A refusal | 1, 2, 3, 4, 6, 7, as a run's | |
//! | Input closed | 8 | |
//! | Opened | 10 | |
//! | Delivered | 11 | for each stream, out then err: its framing (0 lines, 1 bytes), and for lines their count and each one's length; then the end: 0 not yet, 1 exited and the exit's kind and number, 2 a line too long and its stream (0 out, 1 err) and the bound, 3 a read that failed, whose words the detail is |
//! | Written | 12 | |
//!
//! A delivery's two buffers are its streams' bytes, the lines end to end
//! without their line feeds.
//!
//! # The C functions
//!
//! | Function | Does |
//! |---|---|
//! | [`editor_ffi_processes_run`] | Starts a run. False, starting nothing, for words that spell no command, an id in use, or when the system refuses the run its thread |
//! | [`editor_ffi_processes_take`] | Fills a [`RawProcessResult`] and returns true, or returns false when the service keeps no result for the id |
//! | [`editor_ffi_processes_open`] | Starts a streaming child. False, starting nothing, for words that spell no open, an id in use, or when the system refuses its thread |
//! | [`editor_ffi_processes_read`] | Asks for a child's next delivery |
//! | [`editor_ffi_processes_write`] | Copies the bytes and asks for them to be written to a child's input |
//! | [`editor_ffi_processes_close_input`] | Closes a child's input |
//! | [`editor_ffi_processes_take_stream`] | Fills a [`RawStreamReply`] and returns true, or returns false when the service keeps no reply for the wait |
//! | [`editor_ffi_processes_held`] | Whether a child is held at its bound: 0 no, 1 yes, 2 no such child. A readout for tests |
//! | [`editor_ffi_processes_cancel`] | Cancels a run, a streaming child or a wait on one, killing the child's group, and says whether there was anything to cancel |
//! | [`editor_ffi_processes_pending`] | Runs and streaming children whose child is not yet reaped, results not taken, and waits not answered or not taken |
//! | [`editor_ffi_processes_shutdown`] | Kills every group, runs and streaming children alike, and returns once every child is reaped; a later run or open is refused as shut down |

use std::path::PathBuf;
use std::sync::LazyLock;

use editor_process::frame::{Frames, Framing};
use editor_process::service::{End, RunResult, Service, StreamReply, Streaming};
use editor_process::{Command, Environment, Exit, Input, RefusalKind, Stream};
use editor_process_std::StdProcesses;

use crate::events;
use crate::text;
use crate::words::{self, Reader, Writer};

/// The id of the process service as an event's source: a completion of a
/// run comes from the library source with this id.
pub const SERVICE: u64 = 3;

/// The process's process service, over the machine's processes. It is made
/// on its first use, by a run or by shutdown.
#[expect(
    clippy::disallowed_methods,
    reason = "the process's process service is over the real processes; this static is the one place in the crate's sources that makes the adapter"
)]
static PROCESSES: LazyLock<Service<StdProcesses>> = LazyLock::new(|| {
    Service::new(StdProcesses::system(), |id| {
        events::complete(SERVICE, id);
    })
});

/// The command and the limit that `words` and `strings` spell, in the
/// layout the module docs give. `None` when they spell none.
pub fn command_of(words: &[u8], strings: &[u8]) -> Option<(Command, u64)> {
    let strings = std::str::from_utf8(strings).ok()?;
    let mut reader = Reader::new(words)?;
    let mut texts = Texts { strings, at: 0 };
    let limit = reader.word()?;
    let clear = match reader.word()? {
        0 => false,
        1 => true,
        _ => return None,
    };
    let mut arguments = Vec::with_capacity(reader.count(1)?);
    for _ in 0..arguments.capacity() {
        arguments.push(texts.next(reader.size()?)?);
    }
    let count = reader.count(2)?;
    let mut set = Vec::with_capacity(count);
    for _ in 0..count {
        let (name, value) = (reader.size()?, reader.size()?);
        set.push((texts.next(name)?, texts.next(value)?));
    }
    let count = reader.count(1)?;
    let mut unset = Vec::with_capacity(count);
    for _ in 0..count {
        unset.push(texts.next(reader.size()?)?);
    }
    let program = texts.next(reader.size()?)?;
    let directory = PathBuf::from(texts.next(reader.size()?)?);
    reader.finish()?;
    (texts.at == strings.len()).then_some((
        Command {
            program,
            arguments,
            environment: Environment { clear, set, unset },
            directory,
        },
        limit,
    ))
}

/// The command and the streaming that the words and the string of an open
/// spell: three words, the input (0 closed, 1 a pipe), which only the
/// streaming carries, and the framing of
/// standard output and of standard error (0 lines, 1 bytes), then a run's
/// words, whose limit is read as the bound. `None` when they spell none.
pub fn open_of(words: &[u8], strings: &[u8]) -> Option<(Command, Streaming)> {
    let mut reader = Reader::new(words.get(..24)?)?;
    let input = match reader.word()? {
        0 => Input::Closed,
        1 => Input::Pipe,
        _ => return None,
    };
    let framing = |word| match word {
        0 => Some(Framing::Lines),
        1 => Some(Framing::Bytes),
        _ => None,
    };
    let out = framing(reader.word()?)?;
    let err = framing(reader.word()?)?;
    reader.finish()?;
    let (command, bound) = command_of(&words[24..], strings)?;
    Some((
        command,
        Streaming {
            input,
            out,
            err,
            bound,
        },
    ))
}

/// The texts of a command, read off one string in order.
struct Texts<'a> {
    /// The string.
    strings: &'a str,
    /// Where the next text starts.
    at: usize,
}

impl Texts<'_> {
    /// The next text, `len` bytes long. `None` past the string's end, or
    /// for a length that ends inside a character.
    fn next(&mut self, len: usize) -> Option<String> {
        let end = self.at.checked_add(len)?;
        let text = self.strings.get(self.at..end)?;
        self.at = end;
        Some(text.to_owned())
    }
}

/// A run's result laid out as it crosses: the module docs' table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Encoded {
    /// The status.
    pub status: u64,
    /// The words.
    pub words: Vec<u64>,
    /// The detail: empty for a run that ran.
    pub detail: String,
    /// The standard output of a run that ran.
    pub stdout: Vec<u8>,
    /// The standard error of a run that ran.
    pub stderr: Vec<u8>,
}

/// The status of a refusal of `kind`.
///
/// The match on `editor-process`'s [`RefusalKind`] is exhaustive on
/// purpose. This crate must act on every kind: each crosses the C boundary
/// as a status this function chooses, so a new kind has to be given its
/// status here, and a row in the module docs' tables, before the crate
/// builds.
const fn refusal_status(kind: RefusalKind) -> u64 {
    match kind {
        RefusalKind::RelativeDirectory => 1,
        RefusalKind::RelativeProgram => 2,
        RefusalKind::NotFound => 3,
        RefusalKind::Denied => 4,
        RefusalKind::ShutDown => 6,
        RefusalKind::Failed => 7,
        RefusalKind::InputClosed => 8,
    }
}

/// `result` laid out as it crosses.
pub fn encoded(result: RunResult) -> Encoded {
    let bare = |status, words: Vec<u64>, detail: String| Encoded {
        status,
        words,
        detail,
        stdout: Vec::new(),
        stderr: Vec::new(),
    };
    match result {
        RunResult::Ran {
            exit,
            stdout,
            stderr,
        } => {
            let (kind, number) = match exit {
                Exit::Code(code) => (0, code),
                Exit::Signal(signal) => (1, signal),
            };
            Encoded {
                status: 0,
                // A number below 0 crosses as its 64-bit two's complement.
                words: vec![kind, i64::from(number).cast_unsigned()],
                detail: String::new(),
                stdout,
                stderr,
            }
        }
        RunResult::Refused(refusal) => {
            bare(refusal_status(refusal.kind), Vec::new(), refusal.detail)
        }
        RunResult::OutputTooLarge { stream, limit } => {
            let stream = match stream {
                Stream::Out => 0,
                Stream::Err => 1,
            };
            bare(5, vec![stream, limit], String::new())
        }
    }
}

/// The words of `frames`: its framing (0 lines, 1 bytes), and for lines
/// their count and each one's length; and its bytes end to end.
fn frames_words(frames: Frames, words: &mut Vec<u64>) -> Vec<u8> {
    match frames {
        Frames::Bytes(bytes) => {
            words.push(1);
            bytes
        }
        Frames::Lines(lines) => {
            words.push(0);
            words.push(lines.len() as u64);
            words.extend(lines.iter().map(|line| line.len() as u64));
            lines.concat()
        }
    }
}

/// A reply about a streaming child laid out as it crosses: the module
/// docs' table.
///
/// The match on `editor-process`'s [`StreamReply`] and [`End`] is
/// exhaustive on purpose. This crate must act on every variant: each reply
/// must be given a status and words to cross the C boundary, so a new
/// variant has to be given its encoding here, and a row in the module docs'
/// table, before the crate builds.
pub fn encoded_stream(reply: StreamReply) -> Encoded {
    let bare = |status, detail: String| Encoded {
        status,
        words: Vec::new(),
        detail,
        stdout: Vec::new(),
        stderr: Vec::new(),
    };
    match reply {
        StreamReply::Opened => bare(10, String::new()),
        StreamReply::Written => bare(12, String::new()),
        StreamReply::Refused(refusal) => bare(refusal_status(refusal.kind), refusal.detail),
        StreamReply::Delivered(delivery) => {
            let mut words = Vec::new();
            let stdout = frames_words(delivery.out, &mut words);
            let stderr = frames_words(delivery.err, &mut words);
            let mut detail = String::new();
            match delivery.ended {
                None => words.push(0),
                Some(End::Exited(exit)) => {
                    let (kind, number) = match exit {
                        Exit::Code(code) => (0, code),
                        Exit::Signal(signal) => (1, signal),
                    };
                    words.extend([1, kind, i64::from(number).cast_unsigned()]);
                }
                Some(End::LineTooLong { stream, bound }) => {
                    words.extend([2, u64::from(stream == Stream::Err), bound]);
                }
                Some(End::Failed(refusal)) => {
                    words.push(3);
                    detail = refusal.detail;
                }
            }
            Encoded {
                status: 11,
                words,
                detail,
                stdout,
                stderr,
            }
        }
    }
}

/// Asks the process's service to run the command that the `words_len`
/// bytes at `words` and the `strings_len` bytes at `strings` spell, as the
/// run `id`, and returns whether it was accepted. It returns at once and
/// never blocks.
///
/// The completion is one [`EventKind::Completion`] on the completion queue,
/// from the library source [`SERVICE`], whose code is `id`; there is none
/// if the run is cancelled first. The result is then taken with
/// [`editor_ffi_processes_take`].
///
/// Returns false, starting nothing, if the words spell no command, if `id`
/// is in use, or if the operating system refused the run its thread.
///
/// [`EventKind::Completion`]: crate::events::EventKind::Completion
///
/// # Safety
///
/// `words` points to `words_len` readable bytes and `strings` to
/// `strings_len`, both unchanged for the call (no bytes at all may be lent
/// with any pointer).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_processes_run(
    id: u64,
    words: *const u8,
    words_len: usize,
    strings: *const u8,
    strings_len: usize,
) -> bool {
    // SAFETY: the caller guarantees each pointer and its length.
    let (words, strings) = unsafe {
        (
            words::borrow(words, words_len),
            words::borrow(strings, strings_len),
        )
    };
    let Some((command, limit)) = command_of(words, strings) else {
        return false;
    };
    PROCESSES.start(id, command, limit)
}

/// The result of a run as it crosses the boundary: one record, filled in
/// one call. The module docs have the table of statuses and words.
#[repr(C)]
pub struct RawProcessResult {
    /// How the run ended.
    pub status: u64,
    /// The words: a buffer of `words_len` bytes, owned by the caller until
    /// it is handed back with
    /// [`editor_ffi_text_free`](crate::text::editor_ffi_text_free).
    pub words: *mut u8,
    /// The length of `words` in bytes.
    pub words_len: usize,
    /// The detail: a buffer of `detail_len` bytes of UTF-8, owned by the
    /// caller until it is handed back the same way.
    pub detail: *mut u8,
    /// The length of `detail` in bytes.
    pub detail_len: usize,
    /// The standard output: a buffer of `stdout_len` bytes, owned by the
    /// caller until it is handed back the same way.
    pub stdout: *mut u8,
    /// The length of `stdout` in bytes.
    pub stdout_len: usize,
    /// The standard error, the same way.
    pub stderr: *mut u8,
    /// The length of `stderr` in bytes.
    pub stderr_len: usize,
}

impl RawProcessResult {
    /// The record that lends what `encoded` holds.
    fn lending(encoded: Encoded) -> Self {
        let mut writer = Writer::with_capacity(encoded.words.len());
        for word in encoded.words {
            writer.word(word);
        }
        let (words, words_len) = words::lend(writer.finish());
        let (detail, detail_len) = text::lend(encoded.detail);
        let (stdout, stdout_len) = words::lend(encoded.stdout);
        let (stderr, stderr_len) = words::lend(encoded.stderr);
        Self {
            status: encoded.status,
            words,
            words_len,
            detail,
            detail_len,
            stdout,
            stdout_len,
            stderr,
            stderr_len,
        }
    }
}

/// Hands over the result of the run `id`, once: fills `out` and returns
/// true, or returns false, with `out` untouched, when the service keeps no
/// result for `id` (it has not ended, it was cancelled, its result was
/// taken already, or it was another service's id).
///
/// # Safety
///
/// `out` points to a writable [`RawProcessResult`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_processes_take(id: u64, out: *mut RawProcessResult) -> bool {
    let Some(result) = PROCESSES.take(id) else {
        return false;
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawProcessResult::lending(encoded(result))) };
    true
}

/// Cancels the run, the streaming child or the wait `id`, and returns
/// whether there was anything to cancel: a run or a streaming child not
/// over, a wait not answered, or a result or a reply not taken. Cancelling
/// a run or a streaming child kills its child's group if the child is
/// running; a streaming child's waits, a pending read or write among them,
/// are dropped with it. Cancelling a pending read or write drops that wait
/// alone: the child keeps running and keeps what it wrote. It is safe for
/// an id that is unknown. What is cancelled is never completed; a
/// completion already on the queue is still delivered, and the caller
/// ignores it.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_processes_cancel(id: u64) -> bool {
    PROCESSES.cancel(id)
}

/// How many runs and streaming children are not over, a cancelled one
/// being over once its child is reaped; how many results have not been
/// taken; and how many waits on streaming children have not been answered
/// or not taken: all together. A readout for tests, which use it to see
/// that a cancelled run's or streaming child's child was reaped.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_processes_pending() -> u64 {
    words::word(PROCESSES.pending())
}

/// Asks the process's service to start the streaming child that the
/// `words_len` bytes at `words` and the `strings_len` bytes at `strings`
/// spell ([`open_of`]), named `id`, and returns whether it was accepted. It
/// returns at once. Its reply, opened (status 10) or a refusal, is taken
/// with [`editor_ffi_processes_take_stream`] once `id` is completed.
///
/// # Safety
///
/// As for [`editor_ffi_processes_run`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_processes_open(
    id: u64,
    words: *const u8,
    words_len: usize,
    strings: *const u8,
    strings_len: usize,
) -> bool {
    // SAFETY: the caller guarantees each pointer and its length.
    let (words, strings) = unsafe {
        (
            words::borrow(words, words_len),
            words::borrow(strings, strings_len),
        )
    };
    let Some((command, streaming)) = open_of(words, strings) else {
        return false;
    };
    PROCESSES.open(id, command, streaming)
}

/// Asks for the next delivery of the child `child`, as the wait `wait`:
/// completed once, with every frame read up to the take. False for a child
/// the service does not hold, a wait id in use, or a read already pending.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_processes_read(child: u64, wait: u64) -> bool {
    PROCESSES.read(child, wait)
}

/// Copies the `len` bytes at `bytes` and asks for them to be written to the
/// standard input of the child `child`, as the wait `wait`: completed with
/// written (status 12) once every byte is in the pipe, or as input closed
/// (status 8). False as for [`editor_ffi_processes_read`].
///
/// # Safety
///
/// `bytes` points to `len` readable bytes, unchanged for the call (no
/// bytes at all may be lent with any pointer).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_processes_write(
    child: u64,
    wait: u64,
    bytes: *const u8,
    len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointer and its length.
    let bytes = unsafe { words::borrow(bytes, len) };
    PROCESSES.write(child, wait, bytes.to_vec())
}

/// Closes the standard input of the child `child`, as the wait `wait`,
/// completed at once with written (status 12).
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_processes_close_input(child: u64, wait: u64) -> bool {
    PROCESSES.close_input(child, wait)
}

/// Hands over the reply of the wait `wait` on a streaming child, once:
/// fills `out` and returns true, or returns false, with `out` untouched,
/// when the service keeps no reply for it. The module docs have the table
/// of statuses and words.
///
/// # Safety
///
/// `out` points to a writable [`RawStreamReply`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_processes_take_stream(
    wait: u64,
    out: *mut RawStreamReply,
) -> bool {
    let Some(reply) = PROCESSES.take_stream(wait) else {
        return false;
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawStreamReply::lending(encoded_stream(reply))) };
    true
}

/// Whether the readers of the child `child` are parked on its bound: 0 not
/// held, 1 held, 2 a child the service does not hold. A readout for tests.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_processes_held(child: u64) -> u64 {
    match PROCESSES.held(child) {
        Some(false) => 0,
        Some(true) => 1,
        None => 2,
    }
}

/// The reply about a streaming child as it crosses: the same record as a
/// run's result, a status, words, a detail and two buffers, here the
/// delivery's standard output and standard error end to end.
pub type RawStreamReply = RawProcessResult;

/// Shuts the process's service down: cancels every run and every
/// streaming child, killing each child's group, drops every result and
/// every wait or reply not taken, and returns once every child it started
/// has been reaped. It does not wait for a stream to close. A run or an
/// open asked for later is accepted, refused as shut down (status 6) and
/// completed at once. The editor calls it before it quits; it is safe to
/// call again.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_processes_shutdown() {
    PROCESSES.shutdown();
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::time::Duration;

    use editor_process::Refusal;
    use editor_process::fake::{FakeProcesses, Script};

    use super::*;
    use crate::words::tests::buffer;

    /// The words and the string of `command` with `limit`, as Lean lays
    /// them out.
    fn laid_out(command: &Command, limit: u64) -> (Vec<u8>, String) {
        let environment = &command.environment;
        let mut words = vec![
            limit,
            u64::from(environment.clear),
            command.arguments.len() as u64,
        ];
        let mut strings = String::new();
        for argument in &command.arguments {
            words.push(argument.len() as u64);
            strings += argument;
        }
        words.push(environment.set.len() as u64);
        for (name, value) in &environment.set {
            words.extend([name.len() as u64, value.len() as u64]);
            strings += name;
            strings += value;
        }
        words.push(environment.unset.len() as u64);
        for name in &environment.unset {
            words.push(name.len() as u64);
            strings += name;
        }
        let directory = command.directory.display().to_string();
        words.extend([command.program.len() as u64, directory.len() as u64]);
        strings += &command.program;
        strings += &directory;
        (buffer(&words), strings)
    }

    fn full() -> Command {
        Command::new("/bin/sh", ["-c", "printf é", ""], "/dïr").with_environment(Environment {
            clear: true,
            set: vec![("A".into(), "1".into()), ("".into(), "é".into())],
            unset: vec!["PATH".into()],
        })
    }

    #[test]
    fn a_command_crosses_as_words_and_one_string() {
        let command = full();
        let (words, strings) = laid_out(&command, 4096);

        assert_eq!(
            command_of(&words, strings.as_bytes()),
            Some((command, 4096))
        );
    }

    #[test]
    fn a_bare_command_crosses_with_no_lists() {
        let command = Command::new("sh", [""; 0], "/");
        let (words, strings) = laid_out(&command, 0);

        assert_eq!(
            words,
            buffer(&[0, 0, 0, 0, 0, 2, 1]),
            "the limit, clear, three empty counts, and the two lengths"
        );
        assert_eq!(command_of(&words, strings.as_bytes()), Some((command, 0)));
    }

    #[test]
    fn words_that_spell_no_command_are_refused() {
        let (words, strings) = laid_out(&full(), 9);
        let mut short = words.clone();
        short.pop();
        // A clear that is neither 0 nor 1.
        let mut bad_clear = words.clone();
        bad_clear[8] = 2;
        let mut extra = words.clone();
        extra.extend(0_u64.to_le_bytes());

        assert_eq!(
            command_of(&short, strings.as_bytes()),
            None,
            "not whole words"
        );
        assert_eq!(command_of(&bad_clear, strings.as_bytes()), None);
        assert_eq!(
            command_of(&extra, strings.as_bytes()),
            None,
            "words left over"
        );
        assert_eq!(command_of(&[], b""), None, "no words at all");
        assert_eq!(
            command_of(&buffer(&[0, 0, u64::MAX]), b""),
            None,
            "a count past the words"
        );
    }

    #[test]
    fn lengths_that_do_not_add_up_to_the_string_are_refused() {
        let (words, strings) = laid_out(&full(), 9);
        let longer = format!("{strings}x");
        let shorter = &strings[..strings.len() - 1];

        assert_eq!(
            command_of(&words, longer.as_bytes()),
            None,
            "a byte left over"
        );
        assert_eq!(command_of(&words, shorter.as_bytes()), None, "past the end");
        // The program's length cuts the two bytes of `é`.
        let cut = Command::new("é", [""; 0], "/");
        let (mut words, strings) = laid_out(&cut, 0);
        let at = words.len() - 16;
        words[at..at + 8].copy_from_slice(&1_u64.to_le_bytes());
        let at = words.len() - 8;
        words[at..].copy_from_slice(&2_u64.to_le_bytes());
        assert_eq!(
            command_of(&words, strings.as_bytes()),
            None,
            "inside a character"
        );
        // A string that is not UTF-8.
        let (words, _) = laid_out(&Command::new("a", [""; 0], "/"), 0);
        assert_eq!(command_of(&words, b"\xff/"), None);
    }

    #[test]
    fn each_result_is_its_status_and_its_words() {
        let refused = |kind| RunResult::Refused(Refusal::new(kind, "why"));
        let bare = |status, words: Vec<u64>, detail: &str| Encoded {
            status,
            words,
            detail: detail.into(),
            stdout: Vec::new(),
            stderr: Vec::new(),
        };

        assert_eq!(
            encoded(RunResult::Ran {
                exit: Exit::Code(3),
                stdout: b"out\n".to_vec(),
                stderr: b"\xff".to_vec(),
            }),
            Encoded {
                status: 0,
                words: vec![0, 3],
                detail: String::new(),
                stdout: b"out\n".to_vec(),
                stderr: b"\xff".to_vec(),
            }
        );
        assert_eq!(
            encoded(RunResult::Ran {
                exit: Exit::Signal(9),
                stdout: Vec::new(),
                stderr: Vec::new(),
            }),
            bare(0, vec![1, 9], "")
        );
        assert_eq!(
            encoded(RunResult::Ran {
                exit: Exit::Code(-1),
                stdout: Vec::new(),
                stderr: Vec::new(),
            })
            .words,
            [0, u64::MAX]
        );
        assert_eq!(
            encoded(refused(RefusalKind::RelativeDirectory)),
            bare(1, vec![], "why")
        );
        assert_eq!(
            encoded(refused(RefusalKind::RelativeProgram)),
            bare(2, vec![], "why")
        );
        assert_eq!(
            encoded(refused(RefusalKind::NotFound)),
            bare(3, vec![], "why")
        );
        assert_eq!(
            encoded(refused(RefusalKind::Denied)),
            bare(4, vec![], "why")
        );
        assert_eq!(
            encoded(RunResult::OutputTooLarge {
                stream: Stream::Err,
                limit: 4
            }),
            bare(5, vec![1, 4], "")
        );
        assert_eq!(
            encoded(RunResult::OutputTooLarge {
                stream: Stream::Out,
                limit: 7
            })
            .words,
            [0, 7]
        );
        assert_eq!(
            encoded(refused(RefusalKind::ShutDown)),
            bare(6, vec![], "why")
        );
        assert_eq!(
            encoded(refused(RefusalKind::Failed)),
            bare(7, vec![], "why")
        );
        assert_eq!(
            encoded(refused(RefusalKind::InputClosed)),
            bare(8, vec![], "why")
        );
    }

    #[test]
    fn a_result_a_service_kept_crosses_as_the_record_lays_it_out() {
        let fake = FakeProcesses::scripted([(
            full(),
            Ok(Script::ends(Exit::Code(2)).stdout("é").stderr("e")),
        )]);
        let (sender, completed) = mpsc::channel();
        let service = Service::new(fake, move |id| {
            sender.send(id).ok();
        });
        let (words, strings) = laid_out(&full(), 64);
        let (command, limit) = command_of(&words, strings.as_bytes()).expect("a command");

        assert!(service.start(5, command, limit));
        assert_eq!(completed.recv_timeout(Duration::from_secs(5)), Ok(5));
        let raw = RawProcessResult::lending(encoded(service.take(5).expect("a result")));

        assert_eq!(raw.status, 0);
        // SAFETY: each buffer was lent by `lending` with its length, and is
        // taken back once.
        let [words, detail, stdout, stderr] = unsafe {
            [
                (raw.words, raw.words_len),
                (raw.detail, raw.detail_len),
                (raw.stdout, raw.stdout_len),
                (raw.stderr, raw.stderr_len),
            ]
            .map(|(pointer, len)| Box::from_raw(std::ptr::slice_from_raw_parts_mut(pointer, len)))
        };
        assert_eq!(*words, *buffer(&[0, 2]));
        assert!(detail.is_empty());
        assert_eq!(*stdout, *"é".as_bytes());
        assert_eq!(*stderr, *b"e");
    }

    use editor_process::frame::{Frames, Framing};
    use editor_process::service::{Delivery, End, StreamReply, Streaming};

    /// The words and the string of an open of `command` with `streaming`,
    /// as Lean lays them out.
    fn open_laid_out(command: &Command, streaming: Streaming) -> (Vec<u8>, String) {
        let (run, strings) = laid_out(command, streaming.bound);
        let framing = |framing| u64::from(framing == Framing::Bytes);
        let mut words = buffer(&[
            u64::from(streaming.input == Input::Pipe),
            framing(streaming.out),
            framing(streaming.err),
        ]);
        words.extend(run);
        (words, strings)
    }

    #[test]
    fn an_open_crosses_as_its_input_its_framings_and_a_runs_words_with_the_bound_for_the_limit() {
        let streaming = Streaming {
            input: Input::Pipe,
            out: Framing::Lines,
            err: Framing::Bytes,
            bound: 4096,
        };
        let (words, strings) = open_laid_out(&full(), streaming);

        assert_eq!(
            open_of(&words, strings.as_bytes()),
            Some((full(), streaming)),
            "the input is the streaming's alone"
        );
        let closed = Streaming {
            input: Input::Closed,
            out: Framing::Bytes,
            err: Framing::Lines,
            bound: 1,
        };
        let (words, strings) = open_laid_out(&full(), closed);
        assert_eq!(open_of(&words, strings.as_bytes()), Some((full(), closed)));
    }

    #[test]
    fn open_words_that_spell_no_open_are_refused() {
        let streaming = Streaming {
            input: Input::Pipe,
            out: Framing::Lines,
            err: Framing::Lines,
            bound: 9,
        };
        let (words, strings) = open_laid_out(&full(), streaming);
        for word in 0..3 {
            let mut bad = words.clone();
            bad[word * 8] = 2;
            assert_eq!(open_of(&bad, strings.as_bytes()), None, "word {word}");
        }
        assert_eq!(open_of(&words[..16], b""), None, "no run after them");
        assert_eq!(open_of(&[], b""), None);
        let mut longer = strings.clone();
        longer.push('x');
        assert_eq!(open_of(&words, longer.as_bytes()), None);
    }

    fn delivered(out: Frames, err: Frames, ended: Option<End>) -> StreamReply {
        StreamReply::Delivered(Delivery { out, err, ended })
    }

    fn lines(lines: &[&str]) -> Frames {
        Frames::Lines(lines.iter().map(|line| line.as_bytes().to_vec()).collect())
    }

    #[test]
    fn each_stream_reply_is_its_status_and_its_words() {
        let bare = |status, words: Vec<u64>, detail: &str| Encoded {
            status,
            words,
            detail: detail.into(),
            stdout: Vec::new(),
            stderr: Vec::new(),
        };
        assert_eq!(encoded_stream(StreamReply::Opened), bare(10, vec![], ""));
        assert_eq!(encoded_stream(StreamReply::Written), bare(12, vec![], ""));
        for (kind, status) in [
            (RefusalKind::RelativeDirectory, 1),
            (RefusalKind::RelativeProgram, 2),
            (RefusalKind::NotFound, 3),
            (RefusalKind::Denied, 4),
            (RefusalKind::ShutDown, 6),
            (RefusalKind::Failed, 7),
            (RefusalKind::InputClosed, 8),
        ] {
            assert_eq!(
                encoded_stream(StreamReply::Refused(Refusal::new(kind, "why"))),
                bare(status, vec![], "why")
            );
        }
    }

    #[test]
    fn a_deliverys_line_lengths_add_up_to_its_buffer_and_its_end_is_its_last_words() {
        let reply = delivered(
            lines(&["one", "", "é"]),
            Frames::Bytes(b"\xffb".to_vec()),
            Some(End::Exited(Exit::Code(-1))),
        );

        let encoded = encoded_stream(reply);

        assert_eq!(encoded.status, 11);
        assert_eq!(
            encoded.words,
            [0, 3, 3, 0, 2, 1, 1, 0, u64::MAX],
            "lines, three of them and their lengths; bytes; exited with a status of -1"
        );
        assert_eq!(encoded.stdout, "oneé".as_bytes());
        assert_eq!(encoded.stderr, b"\xffb");
    }

    #[test]
    fn an_empty_delivery_and_each_end_cross() {
        let empty = encoded_stream(delivered(lines(&[]), lines(&[]), None));
        assert_eq!(empty.words, [0, 0, 0, 0, 0]);
        assert!(empty.stdout.is_empty() && empty.stderr.is_empty());

        let signal = encoded_stream(delivered(
            lines(&[]),
            lines(&[]),
            Some(End::Exited(Exit::Signal(9))),
        ));
        assert_eq!(signal.words, [0, 0, 0, 0, 1, 1, 9]);
        let too_long = encoded_stream(delivered(
            lines(&[]),
            lines(&[]),
            Some(End::LineTooLong {
                stream: Stream::Err,
                bound: 64,
            }),
        ));
        assert_eq!(too_long.words, [0, 0, 0, 0, 2, 1, 64]);
        let failed = encoded_stream(delivered(
            lines(&[]),
            lines(&[]),
            Some(End::Failed(Refusal::new(RefusalKind::Failed, "EIO"))),
        ));
        assert_eq!(failed.words, [0, 0, 0, 0, 3]);
        assert_eq!(failed.detail, "EIO");
    }

    #[test]
    fn a_streaming_childs_replies_cross_from_a_service_over_the_fake() {
        let command = full();
        let fake = FakeProcesses::scripted([(
            command.clone(),
            Ok(Script::ends(Exit::Code(2)).stdout("a\nb\n")),
        )]);
        let (sender, completed) = mpsc::channel();
        let service = Service::new(fake, move |id| {
            sender.send(id).ok();
        });
        let streaming = Streaming {
            input: Input::Pipe,
            out: Framing::Lines,
            err: Framing::Lines,
            bound: 64,
        };
        let (words, strings) = open_laid_out(&full(), streaming);
        let (command, streaming) = open_of(&words, strings.as_bytes()).expect("an open");

        assert!(service.open(5, command, streaming));
        assert_eq!(completed.recv_timeout(Duration::from_secs(5)), Ok(5));
        assert_eq!(
            service.take_stream(5).map(encoded_stream).map(|e| e.status),
            Some(10)
        );
        let mut words = Vec::new();
        let mut stdout = Vec::new();
        for wait in 6.. {
            assert!(service.read(5, wait));
            assert_eq!(completed.recv_timeout(Duration::from_secs(5)), Ok(wait));
            let reply = encoded_stream(service.take_stream(wait).expect("a delivery"));
            stdout.extend(reply.stdout);
            let ended = *reply.words.last().expect("words") != 0;
            words = reply.words;
            if ended {
                break;
            }
        }
        assert_eq!(stdout, b"ab");
        assert_eq!(words[words.len() - 3..], [1, 0, 2]);
    }
}
