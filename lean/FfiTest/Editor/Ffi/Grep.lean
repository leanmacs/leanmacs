import Editor.Ffi.Document
import Editor.Ffi.Events
import Editor.Ffi.Grep
import Editor.Ffi.Snapshot
import FfiTest.Check
import FfiTest.Support.Files
import FfiTest.Support.Queues

/-!
# FFI tests: `Editor/Ffi/Grep.lean`

The tests of `Editor/Ffi/Grep.lean`: `grepChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The id of the grep service as an event's source. -/
def grepService : UInt64 :=
  7

/-- The library's grep service, as a directory's bracket flushes it: its
flush is completed once the thread of every search started before has
returned, a cancelled search's among them. -/
def grepsFlushed : Flushed :=
  { name := "grep", flush := Editor.Ffi.grepFlush, service := grepService }

/-- Whether the next completion is the grep service's for `id`. -/
def grepCompleted (id : UInt64) : IO Bool := do
  let some event ← pull .completion | return false
  return event.source == { kind := .library, id := grepService } && event.kind == .completion &&
      event.code == id

/-- Reads the search `id` from the wait `wait` on until its end: every file
found, and the end; `none` when a read is refused, not completed, or not a
delivery. -/
def grepToEnd (id wait : UInt64) : IO (Option (Array Editor.Ffi.GrepFile × Editor.Ffi.GrepEnd)) :=
  do
  let mut files := #[]
  for step in [0:64] do
    let wait := wait + step.toUInt64
    unless ← Editor.Ffi.grepNext id wait do
      return none
    unless ← grepCompleted wait do
      return none
    match ← Editor.Ffi.grepTake wait with
    | some (.found found .more) =>
      files := files ++ found
    | some (.found found ending) =>
      return some (files ++ found, ending)
    | _ =>
      return none
  return none

/-- The checks of the grep service's bindings: a search in a temporary
directory with an open buffer's snapshot in place of a file, a refused
pattern's sentence, cancelling, and the decoding of a reply's words. -/
def grepChecks (_ : Unit) : List Check :=
  [{  name :=
        "a search starts through the grep service, and its deliveries answer the files under the root in walk order, an overlay's text in place of its file, an ignored file left out"
      run :=
        inOwnDirectory (targets := [filesFlushed, grepsFlushed]) fun directory => do
          IO.FS.writeFile (directory / "a.txt") "nothing\n"
          IO.FS.writeFile (directory / "b.txt") "x needle\n"
          IO.FS.writeFile (directory / "ignored.txt") "needle\n"
          IO.FS.writeFile (directory / ".ignore") "ignored.txt\n"
          let document ← Editor.Ffi.Document.new "needle\nneedle"
          let snapshot ← document.snapshot
          let a := (directory / "a.txt").toString
          unless
            ← Editor.Ffi.grepStart 1301 directory.toString "needle" 100 1000 64 #[(a, snapshot)] do
            return false
          unless ← grepCompleted 1301 do
            return false
          let started ← Editor.Ffi.grepTake 1301
          let some (files, ending) ← grepToEnd 1301 1302 | return false
          let summary :=
            files.toList.map fun file =>
              (String.fromUTF8! file.path, file.buffer, file.found.toList)
          let pending ← Editor.Ffi.grepPending
          return started == some .started &&
              summary ==
                [(a, true, [(0, 0, 6), (1, 7, 13)]),
                  ((directory / "b.txt").toString, false, [(0, 2, 8)])] &&
              ending == .complete 2 3 &&
              pending == 0 },
    { name :=
        "a pattern the syntax refuses is the start's refusal with Vim's sentence, and a root that is not there ends the first delivery refused"
      run :=
        inOwnDirectory (targets := [filesFlushed, grepsFlushed]) fun directory => do
          unless ← Editor.Ffi.grepStart 1310 directory.toString "\\(" 100 1000 64 #[] do
            return false
          unless ← grepCompleted 1310 do
            return false
          let refused ← Editor.Ffi.grepTake 1310
          let missing := (directory / "missing").toString
          unless ← Editor.Ffi.grepStart 1311 missing "x" 100 1000 64 #[] do
            return false
          unless ← grepCompleted 1311 do
            return false
          let started ← Editor.Ffi.grepTake 1311
          let ended ← grepToEnd 1311 1312
          let notFound :=
            match ended with
            | some (#[], .refused .notFound _) => true
            | _ => false
          return refused == some (.refused .invalid "E54: Unmatched \\(") &&
              started == some .started &&
              notFound },
    { name := "a search cancelled is held no more, and a cancel of an unknown id cancels nothing"
      run :=
        inOwnDirectory (targets := [filesFlushed, grepsFlushed]) fun directory => do
          IO.FS.writeFile (directory / "a") "x\n"
          unless ← Editor.Ffi.grepStart 1320 directory.toString "x" 100 1000 64 #[] do
            return false
          unless ← grepCompleted 1320 do
            return false
          let cancelled ← Editor.Ffi.grepCancel 1320
          let unknown ← Editor.Ffi.grepCancel 1329
          let pending ← Editor.Ffi.grepPending
          return cancelled && !unknown && pending == 0 },
    { name :=
        "a grep reply decodes: started, each refusal, files with their matches and each end; words that do not add up are an error"
      run := do
        let decode (status : UInt64) (values : List UInt64) (paths : ByteArray := .empty) :=
          (Editor.Ffi.GrepReply.decode status (wordBytes values) "why" paths).toOption
        let file (path : String) (buffer : Bool) (found : Array (UInt64 × UInt64 × UInt64)) :
          Editor.Ffi.GrepFile := { path := path.toUTF8, buffer, found }
        let two := decode 8 [2, 4, 0, 1, 0, 1, 2, 2, 1, 1, 3, 4, 5, 2, 2, 3] ("/w/a/x".toUTF8)
        return decode 0 [] == some .started && decode 5 [] == some (.refused .invalid "why") &&
            decode 2 [] == some (.refused .notFound "why") &&
            two ==
              some
                (.found #[file "/w/a" false #[(0, 1, 2)], file "/x" true #[(3, 4, 5)]]
                  (.truncated 2 3)) &&
            decode 8 [0, 0] == some (.found #[] .more) &&
            decode 8 [0, 3, 2] == some (.found #[] (.refused .notFound "why")) &&
            decode 8 [1, 9, 0, 0, 0] ("/w".toUTF8) == none &&
            decode 8 [0, 4] == none &&
            decode 9 [] == none }]

end FfiTest
