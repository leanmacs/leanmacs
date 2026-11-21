import Editor.Ffi.Events
import Editor.Ffi.Watches
import FfiTest.Check
import FfiTest.Support.Files
import FfiTest.Support.Queues

/-!
# FFI tests: `Editor/Ffi/Watches.lean`

The tests of `Editor/Ffi/Watches.lean`: `watchChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The id of the watch service as an event's source. -/
def watchService : UInt64 :=
  4

/-- The library's watch service, as a directory's bracket flushes it: its
flush is completed once every start asked before is done. -/
def watchesFlushed : Flushed :=
  { name := "watch", flush := Editor.Ffi.watchesFlush, service := watchService }

/-- Whether the next completion is the watch service's for `id`. -/
def watchCompleted (id : UInt64) : IO Bool := do
  let some event ← pull .completion | return false
  return event.source == { kind := .library, id := watchService } && event.kind == .completion &&
      event.code == id

/-- The bit of a written change. -/
def writtenBit : UInt64 :=
  2

/-- The checks of the watch service's bindings: a start, a read and a take
in a temporary directory, words that spell no start refused, and the
decoding of a reply's words. -/
def watchChecks (_ : Unit) : List Check :=
  [{  name :=
        "a watch starts through the watch service, its completion comes back with its id, and a write to its file comes back as a change of the file's path, written, taken once"
      run :=
        inOwnDirectory (targets := [filesFlushed, watchesFlushed]) fun directory => do
          let file := directory / "f"
          IO.FS.writeFile file "a"
          unless ← Editor.Ffi.watchesStart 1201 0 0 64 file.toString do
            return false
          unless ← watchCompleted 1201 do
            return false
          let started ← Editor.Ffi.watchesTake 1201
          IO.FS.writeFile file "b"
          let mut written := false
          let mut onlyTheFile := true
          for wait in [1202:1206] do
            unless ← Editor.Ffi.watchesNext 1201 wait.toUInt64 do
              return false
            unless ← watchCompleted wait.toUInt64 do
              return false
            match ← Editor.Ffi.watchesTake wait.toUInt64 with
            | some (.changes changes) =>
              onlyTheFile := onlyTheFile && changes.all (·.1 == file.toString.toUTF8)
              if changes.any (·.2 &&& writtenBit != 0) then
                written := true
                break
            | _ =>
              return false
          let again ← Editor.Ffi.watchesTake 1202
          let cancelled ← Editor.Ffi.watchesCancel 1201
          return started == some .started && written && onlyTheFile && again.isNone && cancelled },
    { name :=
        "words that spell no start start no watch, and a missing directory is refused as not found, naming it"
      run :=
        inOwnDirectory (targets := [filesFlushed, watchesFlushed]) fun directory => do
          let malformed ← Editor.Ffi.watchesStart 1210 9 0 64 directory.toString
          let missing := directory / "missing"
          unless ← Editor.Ffi.watchesStart 1211 1 0 64 missing.toString do
            return false
          unless ← watchCompleted 1211 do
            return false
          let refused ←
            match ← Editor.Ffi.watchesTake 1211 with
            | some (.refused .notFound detail) =>
              pure (decide ((detail.splitOn "missing").length > 1))
            | _ =>
              pure false
          return !malformed && refused },
    { name := "a watch flush asked behind a start is completed after it, and keeps no reply"
      run :=
        inOwnDirectory (targets := [filesFlushed, watchesFlushed]) fun directory => do
          let started ← Editor.Ffi.watchesStart 1220 1 0 64 directory.toString
          let flushing ← Editor.Ffi.watchesFlush 1221
          let first ← watchCompleted 1220
          let second ← watchCompleted 1221
          let reply ← Editor.Ffi.watchesTake 1220
          let kept ← Editor.Ffi.watchesTake 1221
          let cancelled ← Editor.Ffi.watchesCancel 1220
          return started && flushing && first && second && reply == some .started && kept.isNone &&
              cancelled },
    { name :=
        "a watch reply decodes: started, each refusal, and changes as each path's bytes and its kinds' bits; words that do not add up are an error"
      run := do
        let decode (status : UInt64) (values : List UInt64) (paths : ByteArray := .empty) :=
          (Editor.Ffi.WatchReply.decode status (wordBytes values) "why" paths).toOption
        let changes := decode 8 [2, 4, 3, 2, 16] ("/w/a/x".toUTF8)
        return decode 0 [] == some .started && decode 2 [] == some (.refused .notFound "why") &&
            decode 5 [] == some (.refused .limit "why") &&
            changes == some (.changes #[("/w/a".toUTF8, 3), ("/x".toUTF8, 16)]) &&
            decode 8 [1, 9, 2] ("/w".toUTF8) == none &&
            decode 9 [] == none }]

end FfiTest
