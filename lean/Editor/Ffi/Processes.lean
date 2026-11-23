import Editor.Bound
import Editor.Ffi.Words

/-!
# Bindings: the process service

The bindings of `crates/editor-ffi/src/processes.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Services and completions").
-/

namespace Editor.Ffi

open Words

/-- How a child the process service ran ended. -/
inductive ProcessExit where
  /-- It exited with this status. -/
  | code (n : UInt64)
  /-- It was ended by this signal. -/
  | signal (n : UInt64)
  deriving DecidableEq, Repr

/-- One of a child's output streams. -/
inductive ProcessStream where
  /-- Its standard output. -/
  | out
  /-- Its standard error. -/
  | err
  deriving DecidableEq, Repr

/-- What a run of the process service came to. Every refusal carries the
platform's words, naming the program and the directory. -/
inductive ProcessResult where
  /-- The child ran to its end, with both its streams. -/
  | ran (exit : ProcessExit) (stdout stderr : ByteArray)
  /-- The directory is not absolute. -/
  | relativeDirectory (detail : String)
  /-- The program names a directory and is not absolute. -/
  | relativeProgram (detail : String)
  /-- The program, or the directory, is not there. -/
  | notFound (detail : String)
  /-- The platform does not allow it. -/
  | denied (detail : String)
  /-- `stream` had more than `limit` bytes, and the child's group was
  killed. -/
  | outputTooLarge (stream : ProcessStream) (limit : UInt64)
  /-- The service has shut down. -/
  | shutDown (detail : String)
  /-- Anything else. -/
  | failed (detail : String)
  /-- A run that keeps its head (`processesRunHead`): its standard output
  went past the limit, and the child's group was killed. `stdout` is exactly
  its first `limit` bytes, `stderr` what was read of standard error by then.
  Output of exactly `limit` bytes is not cut: the run answers `ran`. -/
  | cut (stdout stderr : ByteArray)
  deriving DecidableEq

/-- The result a status, words, a detail and the two streams spell, by the
table in the module docs of `crates/editor-ffi/src/processes.rs`. An error,
with what was wrong, for a status the table does not have and for words that
are not the status's.

It is public for `FfiTest`, which decodes literal words with it; the bindings
call it from `processesTake` and nowhere else. -/
def ProcessResult.decode (status : UInt64) (words : ByteArray) (detail : String)
    (stdout stderr : ByteArray) : Except String ProcessResult := do
  let some words := wordsOf? words | throw "its words are not whole words"
  match status, words.toList with
  | 0, [0, code] =>
    return .ran (.code code) stdout stderr
  | 0, [1, signal] =>
    return .ran (.signal signal) stdout stderr
  | 1, [] =>
    return .relativeDirectory detail
  | 2, [] =>
    return .relativeProgram detail
  | 3, [] =>
    return .notFound detail
  | 4, [] =>
    return .denied detail
  | 5, [0, limit] =>
    return .outputTooLarge .out limit
  | 5, [1, limit] =>
    return .outputTooLarge .err limit
  | 6, [] =>
    return .shutDown detail
  | 7, [] =>
    return .failed detail
  | 9, [] =>
    return .cut stdout stderr
  | status, words =>
    throw s!"the status {status} with the words {words} is no process result"

/-- `processesRun` as it crosses: the command as words and one string. -/
@[extern "editor_glue_processes_run"]
private opaque processesRunRaw (id : UInt64) (words : @& ByteArray) (strings : @& String) : IO Bool

/-- A run's command and limit as they cross: the words, the limit, whether to
clear, and the count and byte lengths of each list of texts, and one string
of every text end to end. -/
def runLayout (program : String) (arguments : Array String) (clear : Bool)
    (set : Array (String × String)) (unset : Array String) (directory : String) (limit : UInt64) :
    ByteArray × String :=
  let size (text : String) := text.utf8ByteSize.toUInt64
  let words := pushWord (pushWord ByteArray.empty limit) (if clear then 1 else 0)
  let words :=
    arguments.foldl (fun words argument => pushWord words (size argument))
      (pushWord words arguments.size.toUInt64)
  let words :=
    set.foldl (fun words (name, value) => pushWord (pushWord words (size name)) (size value))
      (pushWord words set.size.toUInt64)
  let words :=
    unset.foldl (fun words name => pushWord words (size name)) (pushWord words unset.size.toUInt64)
  let words := pushWord (pushWord words (size program)) (size directory)
  let strings :=
    arguments.foldl (· ++ ·) "" ++ set.foldl (fun all (name, value) => all ++ name ++ value) "" ++
      unset.foldl (· ++ ·) "" ++
      program ++
      directory
  (words, strings)

/-- Asks the library's process service to run `program` with `arguments` in
`directory`, with the editor's environment emptied first if `clear` is set,
then with `unset` removed and `set` applied, collecting each output stream
unless it is longer than `limit` bytes, as the run `id`, and returns whether
it was accepted. It returns at once. The completion is a `completion` event
on the completion queue, from the library source 3, whose code is `id`;
there is none if the run is cancelled first. The result is then taken with
`processesTake`.

The command crosses as words, the limit, whether to clear, and the count and
byte lengths of each list of texts, and as one string of every text end to
end, in the layout of the module docs of `crates/editor-ffi/src/processes.rs`.
`false`, with nothing started, if `id` is in use or the service could not
start the run's thread; the words this builds are always readable. -/
def processesRun (id : UInt64) (program : String) (arguments : Array String) (clear : Bool)
    (set : Array (String × String)) (unset : Array String) (directory : String) (limit : UInt64) :
    IO Bool :=
  let (words, strings) := runLayout program arguments clear set unset directory limit
  processesRunRaw id words strings

/-- `processesRunInput` as it crosses: a run's words and string, and the
input's bytes. -/
@[extern "editor_glue_processes_run_input"]
private opaque processesRunInputRaw (id : UInt64) (words : @& ByteArray) (strings : @& String)
    (input : @& ByteArray) : IO Bool

/-- Asks the library's process service to run a command as `processesRun`
does, with `input` as the child's standard input, followed by end of file.
The bytes are copied. A child that does not read them is no refusal: the
run answers what it did. -/
def processesRunInput (id : UInt64) (program : String) (arguments : Array String) (clear : Bool)
    (set : Array (String × String)) (unset : Array String) (directory : String) (limit : UInt64)
    (input : ByteArray) : IO Bool :=
  let (words, strings) := runLayout program arguments clear set unset directory limit
  processesRunInputRaw id words strings input

/-- `processesRunHead` as it crosses: a run's words and string, and the
input's bytes. -/
@[extern "editor_glue_processes_run_head"]
private opaque processesRunHeadRaw (id : UInt64) (words : @& ByteArray) (strings : @& String)
    (input : @& ByteArray) : IO Bool

/-- Asks the library's process service to run a command fed `input` as
`processesRunInput` does, keeping the head of its standard output: once that
goes past `limit` bytes the child's group is killed and the run answers
`ProcessResult.cut` with exactly its first `limit` bytes. Standard error keeps
the usual rule, and a run whose output stays within the limit, exactly `limit`
bytes among it, answers `ran`. -/
def processesRunHead (id : UInt64) (program : String) (arguments : Array String) (clear : Bool)
    (set : Array (String × String)) (unset : Array String) (directory : String) (limit : UInt64)
    (input : ByteArray) : IO Bool :=
  let (words, strings) := runLayout program arguments clear set unset directory limit
  processesRunHeadRaw id words strings input

/-- `processesOpen` as it crosses: the open's three words and a run's words,
and one string. -/
@[extern "editor_glue_processes_open"]
private opaque processesOpenRaw (id : UInt64) (words : @& ByteArray) (strings : @& String) : IO Bool

/-- Asks the library's process service to start `program` as a streaming
child named `id`, its standard input piped if `input`, and each output
stream framed as bytes if `stdoutBytes` or `stderrBytes` says so and as
lines otherwise, holding up to `bound` bytes of each stream read and not
taken; the rest is as `processesRun`'s. It returns at once, and whether the
open was accepted. Its reply is taken with `processesTakeStream id` once `id`
is completed.

The words are the input and the two framings, then a run's words with the
bound for the limit, in the layout of the module docs of
`crates/editor-ffi/src/processes.rs`. -/
def processesOpen (id : UInt64) (input stdoutBytes stderrBytes : Bool) (program : String)
    (arguments : Array String) (clear : Bool) (set : Array (String × String)) (unset : Array String)
    (directory : String) (bound : UInt64) : IO Bool :=
  let flag (value : Bool) : UInt64 := if value then 1 else 0
  let lead :=
    pushWord (pushWord (pushWord .empty (flag input)) (flag stdoutBytes)) (flag stderrBytes)
  let (words, strings) := runLayout program arguments clear set unset directory bound
  processesOpenRaw id (lead ++ words) strings

/-- Asks for the next delivery of the streaming child `child`, as the wait
`wait`. It returns at once: false for a child the service does not hold, a
wait id in use, or a read already pending. The delivery is taken with
`processesTakeStream wait` once `wait` is completed, which is once however
much the child writes. -/
@[extern "editor_glue_processes_read"]
opaque processesRead (child wait : UInt64) : IO Bool

/-- Asks for `bytes` to be written to the standard input of the child
`child`, as the wait `wait`, and returns at once; false as for
`processesRead`. The bytes are copied. -/
@[extern "editor_glue_processes_write"]
opaque processesWrite (child wait : UInt64) (bytes : @& ByteArray) : IO Bool

/-- Closes the standard input of the child `child`, as the wait `wait`,
completed at once. -/
@[extern "editor_glue_processes_close_input"]
opaque processesCloseInput (child wait : UInt64) : IO Bool

/-- Whether the readers of the child `child` are held at its bound: 0 no, 1
yes, 2 no such child. A readout for tests. -/
@[extern "editor_glue_processes_held"]
opaque processesHeld (child : UInt64) : IO UInt64

/-- `processesAwaitHeld` as it crosses: its guard in milliseconds. -/
@[extern "editor_glue_processes_await_held"]
private opaque processesAwaitHeldRaw (child : UInt64) (boundMs : UInt64) : IO Bool

/-- Waits until the readers of the child `child` are held at its bound, and
says whether they were: false at once for a child the service does not hold
as streaming, and once `guard` has run out first. A readout for tests: it
returns on the reader's park, never by a poll of `processesHeld`. Only
readers that never park reach the guard. -/
def processesAwaitHeld (child : UInt64) (guard : HangGuard) : IO Bool :=
  processesAwaitHeldRaw child guard.ms.toUInt64

/-- A process result as the glue builds it, in one call: the object fields
first and the `UInt64` field after them, so the order here is the layout the
glue writes. -/
private structure RawProcessResult where
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- The detail, copied from the library's buffer. -/
  detail : String
  /-- The standard output, copied from the library's buffer. -/
  stdout : ByteArray
  /-- The standard error, copied from the library's buffer. -/
  stderr : ByteArray
  /-- How the run ended: the library's status. -/
  status : UInt64

/-- `processesTake` before its result is decoded. -/
@[extern "editor_glue_processes_take"]
private opaque processesTakeRaw (id : UInt64) : IO (Option RawProcessResult)

/-- Hands over the result of the run `id`, once. `none` when the service
keeps no result for `id`: it has not ended, it was cancelled, its result was
taken already, or it was another service's id. It throws if the library
sends a result these bindings cannot read. -/
def processesTake (id : UInt64) : IO (Option ProcessResult) := do
  let some raw ← processesTakeRaw id | return none
  match ProcessResult.decode raw.status raw.words raw.detail raw.stdout raw.stderr with
  | .ok result =>
    return some result
  | .error reason =>
    throw (IO.userError s!"the library's process result could not be read: {reason}")

/-- How a streaming child's stream crosses in a delivery. -/
inductive StreamFrames where
  /-- Whole lines. -/
  | lines (lines : Array ByteArray)
  /-- Bytes. -/
  | bytes (bytes : ByteArray)
  deriving DecidableEq

/-- How a streaming child ended, as its last delivery crosses. -/
inductive StreamEnd where
  /-- It exited so, every frame delivered. -/
  | exited (exit : ProcessExit)
  /-- A line of `stream` was longer than `bound`. -/
  | lineTooLong (stream : ProcessStream) (bound : UInt64)
  /-- A read failed; `detail` says how. -/
  | failed (detail : String)
  deriving DecidableEq

/-- What a request about a streaming child came to. -/
inductive StreamReply where
  /-- The child was started. -/
  | opened
  /-- A read's delivery: each stream's frames, and in the last one how the
  child ended. -/
  | delivered (stdout stderr : StreamFrames) (ended : Option StreamEnd)
  /-- The bytes are in the child's input, or it was closed. -/
  | written
  /-- The child's input is closed. -/
  | inputClosed (detail : String)
  /-- Refused as a run is refused: a run's result that is a refusal. -/
  | refused (refusal : ProcessResult)
  deriving DecidableEq

/-- A stream's frames read off the front of `values`, with `bytes` its
buffer: for lines, their count and each one's length, which must add up to
the buffer; and the words after them. -/
private def streamFramesOf? : List UInt64 → ByteArray → Option (StreamFrames × List UInt64)
  | 1 :: rest, bytes => some (.bytes bytes, rest)
  | 0 :: count :: rest, bytes =>
    let lengths := rest.take count.toNat
    if lengths.length != count.toNat || lengths.foldl (· + ·.toNat) 0 != bytes.size then none
    else
      let (lines, _) :=
        lengths.foldl (init := ((#[] : Array ByteArray), 0)) fun (lines, start) length =>
          (lines.push (bytes.extract start (start + length.toNat)), start + length.toNat)
      some (.lines lines, rest.drop count.toNat)
  | _, _ => none

/-- The reply a status, words, a detail and the two buffers spell, by the
table in the module docs of `crates/editor-ffi/src/processes.rs`. An error,
with what was wrong, for a status the table does not have and for words that
are not the status's.

It is public for `FfiTest`, which decodes literal words with it; the bindings
call it from `processesTakeStream` and nowhere else. -/
def StreamReply.decode (status : UInt64) (words : ByteArray) (detail : String)
    (stdout stderr : ByteArray) : Except String StreamReply := do
  let some values := wordsOf? words | throw "its words are not whole words"
  match status, values.toList with
  | 10, [] =>
    return .opened
  | 12, [] =>
    return .written
  | 8, [] =>
    return .inputClosed detail
  | 11, values =>
    let some (out, values) := streamFramesOf? values stdout
      | throw s!"its standard output's words do not spell frames of its {stdout.size} bytes"
    let some (err, values) := streamFramesOf? values stderr
      | throw s!"its standard error's words do not spell frames of its {stderr.size} bytes"
    match values with
    | [0] =>
      return .delivered out err none
    | [1, 0, code] =>
      return .delivered out err (some (.exited (.code code)))
    | [1, 1, signal] =>
      return .delivered out err (some (.exited (.signal signal)))
    | [2, 0, bound] =>
      return .delivered out err (some (.lineTooLong .out bound))
    | [2, 1, bound] =>
      return .delivered out err (some (.lineTooLong .err bound))
    | [3] =>
      return .delivered out err (some (.failed detail))
    | values =>
      throw s!"the words {values} spell no end of a delivery"
  | status, [] =>
    if [1, 2, 3, 4, 6, 7].contains status then
      return .refused (← ProcessResult.decode status .empty detail .empty .empty)
    else
      throw s!"the status {status} is no stream reply"
  | status, values =>
    throw s!"the status {status} with the words {values} is no stream reply"

/-- `processesTakeStream` before its reply is decoded: the record of a run's
result. -/
@[extern "editor_glue_processes_take_stream"]
private opaque processesTakeStreamRaw (wait : UInt64) : IO (Option RawProcessResult)

/-- Hands over the reply of the wait `wait` on a streaming child, once.
`none` when the service keeps no reply for it. It throws if the library sends
a reply these bindings cannot read: an unknown status, or line lengths that
do not add up. -/
def processesTakeStream (wait : UInt64) : IO (Option StreamReply) := do
  let some raw ← processesTakeStreamRaw wait | return none
  match StreamReply.decode raw.status raw.words raw.detail raw.stdout raw.stderr with
  | .ok reply =>
    return some reply
  | .error reason =>
    throw (IO.userError s!"the library's stream reply could not be read: {reason}")

/-- Cancels the run `id`, killing its child's process group if the child is
running, and returns whether there was anything to cancel: a run not over or
a result not taken. It is safe for an id that is unknown. A cancelled run is
never completed; a completion that was already queued still arrives, and
its result is gone. -/
@[extern "editor_glue_processes_cancel"]
opaque processesCancel (id : UInt64) : IO Bool

/-- Asks the process service for the wait `id` to be completed once every run
started before this call has ended, every open asked before it has been
answered, and every streaming child cancelled before it has been reaped,
and returns whether it was accepted. It returns at once and keeps no reply.
A live streaming child and its pending read are not waited for. -/
@[extern "editor_glue_processes_flush"]
opaque processesFlush (id : UInt64) : IO Bool

/-- How many runs have a child not yet reaped, and how many results have not
been taken, together. A readout for tests, which use it to see that a
cancelled run's child was reaped. -/
@[extern "editor_glue_processes_pending"]
opaque processesPending : IO UInt64

/-- Shuts the library's process service down: kills every child's process
group and returns once every child it started has been reaped. A run asked
for later is refused as shut down. The editor's mains call it before they
quit the queues; it is safe to call again. -/
@[extern "editor_glue_processes_shutdown"]
opaque processesShutdown : IO Unit

end Editor.Ffi
