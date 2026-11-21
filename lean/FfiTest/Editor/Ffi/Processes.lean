import Editor.Ffi.Events
import Editor.Ffi.Processes
import FfiTest.Check
import FfiTest.Support.Files
import FfiTest.Support.Queues

/-!
# FFI tests: `Editor/Ffi/Processes.lean`

The tests of `Editor/Ffi/Processes.lean`: `processChecks`. The root module
`FfiTest` runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The id of the process service as the source of its completions. -/
def processService : UInt64 :=
  3

/-- The library's process service, as a directory's bracket flushes it: its
flush is completed once every run started before has ended and every child
cancelled before has been reaped. -/
def processesFlushed : Flushed :=
  { name := "process", flush := Editor.Ffi.processesFlush, service := processService }

/-- Whether the next completion on the queue is the process service's, for
the run `id`. -/
def processCompleted (id : UInt64) : IO Bool := do
  let some event ← pull .completion | return false
  return event.source == { kind := .library, id := processService } && event.kind == .completion &&
      event.code == id

/-- Runs `/bin/sh -c script` in `directory` as the run `id`, waits for its
completion and takes its result. `none` when the run was refused, was not
completed in time, or left no result. -/
def processResult (id : UInt64) (script : String) (directory : System.FilePath)
    (limit : UInt64 := 1000000) (set : Array (String × String) := #[]) :
    IO (Option Editor.Ffi.ProcessResult) := do
  unless
    ← Editor.Ffi.processesRun id "/bin/sh" #["-c", script] false set #[] directory.toString limit do
    return none
  unless ← processCompleted id do
    return none
  Editor.Ffi.processesTake id

/-- What `Editor.Ffi.ProcessResult.decode` makes of a status, words and a
detail, with empty streams; `none` when it is an error. -/
def decodedProcess (status : UInt64) (values : List UInt64) (detail : String := "") :
    Option Editor.Ffi.ProcessResult :=
  (Editor.Ffi.ProcessResult.decode status (wordBytes values) detail .empty .empty).toOption

/-- What `Editor.Ffi.StreamReply.decode` makes of a status, words, a detail
and the two buffers; `none` when it is an error. -/
def decodedStream (status : UInt64) (values : List UInt64) (detail : String := "")
    (out err : ByteArray := .empty) : Option Editor.Ffi.StreamReply :=
  (Editor.Ffi.StreamReply.decode status (wordBytes values) detail out err).toOption

/-- The reply of the wait `wait` on a streaming child, once its completion
has come back; `none` when it did not come in time or left no reply. -/
def streamReply (wait : UInt64) : IO (Option Editor.Ffi.StreamReply) := do
  unless ← processCompleted wait do
    return none
  Editor.Ffi.processesTakeStream wait

/-- The checks of the process service's bindings. A run goes in with an id,
its completion comes back on the completion queue, and its result is taken by
the id. What a run does is the library's rule; these pin that a command, its
arguments, its environment and its limit cross, and that every kind of result
comes back. Each check runs its children in a directory of its own
(`inOwnDirectory`), and each run has an id no other check uses. -/
def processChecks (_ : Unit) : List Check :=
  [{  name :=
        "a command runs through the process service: its completion comes back on the completion queue with the run's id, and its result, taken once, is its status and both its streams, with the environment it was given"
      run :=
        inOwnDirectory (targets := [filesFlushed, processesFlushed]) fun directory => do
          let result ←
            processResult 1101 "printf %s \"$EDITOR_FFI_SET\"; printf 'e\\377' >&2; exit 3"
                directory (set := #[("EDITOR_FFI_SET", "given")])
          let again ← Editor.Ffi.processesTake 1101
          return result == some (.ran (.code 3) "given".toUTF8 ("e".toUTF8.push 0xFF)) &&
              again.isNone },
    { name :=
        "a refusal crosses with its words: a program that is not there is not found, naming it, and a directory that is not absolute is refused as itself"
      run :=
        inOwnDirectory (targets := [filesFlushed, processesFlushed]) fun directory => do
          let missing := "/nonexistent/editor-ffi-test"
          unless ← Editor.Ffi.processesRun 1110 missing #[] false #[] #[] directory.toString 10 do
            return false
          unless ← processCompleted 1110 do
            return false
          let notFound ←
            match ← Editor.Ffi.processesTake 1110 with
            | some (.notFound detail) =>
              pure (decide ((detail.splitOn missing).length > 1))
            | _ =>
              pure false
          let relative ← processResult 1111 "exit 0" "relative"
          return notFound && relative matches some (.relativeDirectory _) },
    { name := "a stream past the limit crosses as too large, with the stream and the limit"
      run :=
        inOwnDirectory (targets := [filesFlushed, processesFlushed]) fun directory => do
          let out ← processResult 1120 "printf abc" directory 2
          let err ← processResult 1121 "printf abc >&2" directory 2
          return out == some (.outputTooLarge .out 2) && err == some (.outputTooLarge .err 2) },
    { name :=
        "a run cancelled while its child sleeps is never completed, its child is reaped, and a cancel says whether there was anything to cancel"
      run :=
        inOwnDirectory (targets := [filesFlushed, processesFlushed]) fun directory => do
          let before ← Editor.Ffi.processesPending
          unless
            ←
              Editor.Ffi.processesRun 1130 "/bin/sleep" #["600"] false #[] #[] directory.toString
                  10 do
            return false
          let cancelled ← Editor.Ffi.processesCancel 1130
          -- A flush is completed once the cancelled run's child is reaped.
          let flushed ← Editor.Ffi.processesFlush 1133
          let reaped :=
            flushed && (← processCompleted 1133) && (← Editor.Ffi.processesPending) == before
          let never ← Editor.Ffi.processesCancel 1131
          -- The next completion is the marker's, started after the cancel.
          let marker ← processResult 1132 "exit 0" directory
          return cancelled && reaped && !never && marker == some (.ran (.code 0) .empty .empty) &&
              (← Editor.Ffi.processesTake 1130).isNone },
    { name :=
        "a process result's words decode by its status: an exit by a status or a signal, each refusal with its detail, and a stream too large with its limit"
      run :=
        pure
          (decodedProcess 0 [0, 3] == some (.ran (.code 3) .empty .empty) &&
            decodedProcess 0 [1, 9] == some (.ran (.signal 9) .empty .empty) &&
            decodedProcess 1 [] "d" == some (.relativeDirectory "d") &&
            decodedProcess 2 [] "p" == some (.relativeProgram "p") &&
            decodedProcess 3 [] "n" == some (.notFound "n") &&
            decodedProcess 4 [] "no" == some (.denied "no") &&
            decodedProcess 5 [0, 4] == some (.outputTooLarge .out 4) &&
            decodedProcess 5 [1, 7] == some (.outputTooLarge .err 7) &&
            decodedProcess 6 [] "shut" == some (.shutDown "shut") &&
            decodedProcess 7 [] "f" == some (.failed "f")) },
    { name :=
        "a run that kept its head decodes from status 9 with no words to its two streams, and status 9 with words is no result"
      run :=
        pure
          ((Editor.Ffi.ProcessResult.decode 9 .empty "" "0123".toUTF8 "e".toUTF8).toOption ==
              some (.cut "0123".toUTF8 "e".toUTF8) &&
            (decodedProcess 9 [0]).isNone) },
    { name :=
        "a process result the bindings cannot read is an error: a status the table does not have, and words that are not the status's"
      run :=
        pure
          (([(8, []), (0, []), (0, [2, 0]), (0, [0]), (1, [1]), (5, [2, 1]), (5, [0]), (7, [0])].all
              fun ((status, values) : UInt64 × List UInt64) =>
              (decodedProcess status values).isNone) &&
            (Editor.Ffi.ProcessResult.decode 0 ⟨#[1, 2, 3]⟩ "" .empty .empty).toOption.isNone) },
    { name :=
        "a streaming child crosses the bindings: it opens, its first line is read as it writes it, a line written reaches it, a close ends its input, and its last delivery is its exit"
      run :=
        inOwnDirectory (targets := [filesFlushed, processesFlushed]) fun directory => do
          let script := "echo one; read x; echo \"$x\"; read y; exit 4"
          unless
            ←
              Editor.Ffi.processesOpen 1140 true false false "/bin/sh" #["-c", script] false #[] #[]
                  directory.toString 1000000 do
            return false
          let opened ← streamReply 1140
          unless ← Editor.Ffi.processesRead 1140 1141 do
            return false
          let first ← streamReply 1141
          unless ← Editor.Ffi.processesWrite 1140 1142 "two\n".toUTF8 do
            return false
          let written ← streamReply 1142
          unless ← Editor.Ffi.processesRead 1140 1143 do
            return false
          let second ← streamReply 1143
          unless ← Editor.Ffi.processesCloseInput 1140 1144 do
            return false
          let closed ← streamReply 1144
          let mut last := none
          for wait in [1145:1165] do
            unless ← Editor.Ffi.processesRead 1140 wait.toUInt64 do
              break
            last ← streamReply wait.toUInt64
            if let some (.delivered _ _ (some _)) := last then
              break
          return opened == some .opened &&
              first == some (.delivered (.lines #["one".toUTF8]) (.lines #[]) none) &&
              written == some .written &&
              second == some (.delivered (.lines #["two".toUTF8]) (.lines #[]) none) &&
              closed == some .written &&
              (match last with
              | some (.delivered _ _ (some (.exited (.code 4)))) => true
              | _ => false) },
    { name :=
        "whether a streaming child is held crosses the bindings: a child that writes for ever, never read, comes to be held at its bound, an id the service does not hold is 2, and a cancel reaps the held child and forgets it"
      run :=
        inOwnDirectory (targets := [filesFlushed, processesFlushed]) fun directory => do
          let before ← Editor.Ffi.processesPending
          unless
            ←
              Editor.Ffi.processesOpen 1170 false false false "/bin/sh"
                  #["-c", "while :; do echo y; done"] false #[] #[] directory.toString 16 do
            return false
          -- Every step runs whatever the one before it found, so the cancel
          -- always comes and no child is left writing.
          let opened ← streamReply 1170
          let held ← eventually (return (← Editor.Ffi.processesHeld 1170) == 1)
          let unknown ← Editor.Ffi.processesHeld 1171
          let cancelled ← Editor.Ffi.processesCancel 1170
          -- A flush is completed once the cancelled child is reaped.
          let flushed ← Editor.Ffi.processesFlush 1172
          let reaped :=
            flushed && (← processCompleted 1172) && (← Editor.Ffi.processesPending) == before
          let forgotten ← Editor.Ffi.processesHeld 1170
          return opened == some .opened && held && unknown == 2 && cancelled && reaped &&
              forgotten == 2 },
    { name :=
        "a stream reply's words decode by its status: opened, written, input closed, each refusal, and a delivery's lines by their lengths, its bytes and each end"
      run :=
        pure
          (decodedStream 10 [] == some .opened && decodedStream 12 [] == some .written &&
            decodedStream 8 [] "c" == some (.inputClosed "c") &&
            decodedStream 3 [] "n" == some (.refused (.notFound "n")) &&
            decodedStream 6 [] "s" == some (.refused (.shutDown "s")) &&
            decodedStream 11 [0, 2, 3, 0, 1, 0] "" "one".toUTF8 ("x".toUTF8.push 0xFF) ==
              some
                (.delivered (.lines #["one".toUTF8, .empty]) (.bytes ("x".toUTF8.push 0xFF))
                  none) &&
            decodedStream 11 [0, 0, 0, 0, 1, 0, 4] ==
              some (.delivered (.lines #[]) (.lines #[]) (some (.exited (.code 4)))) &&
            decodedStream 11 [0, 0, 0, 0, 1, 1, 9] ==
              some (.delivered (.lines #[]) (.lines #[]) (some (.exited (.signal 9)))) &&
            decodedStream 11 [0, 0, 0, 0, 2, 1, 64] ==
              some (.delivered (.lines #[]) (.lines #[]) (some (.lineTooLong .err 64))) &&
            decodedStream 11 [1, 1, 3] "EIO" ==
              some (.delivered (.bytes .empty) (.bytes .empty) (some (.failed "EIO")))) },
    { name :=
        "a stream reply the bindings cannot read is an error: a status the table does not have, line lengths that do not add up, words left over, and words a status has none of"
      run :=
        pure
          ((decodedStream 9 []).isNone && (decodedStream 0 [0, 3]).isNone &&
            (decodedStream 11 [0, 1, 4, 0, 0] "" "one".toUTF8).isNone &&
            (decodedStream 11 [0, 0, 0, 0, 0, 7]).isNone &&
            (decodedStream 11 [0, 0, 0, 0, 4]).isNone &&
            (decodedStream 10 [1]).isNone) }]

end FfiTest
