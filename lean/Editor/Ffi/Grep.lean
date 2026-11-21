import Editor.Ffi.Snapshot
import Editor.Ffi.Words

/-!
# Bindings: the grep service

The bindings of `crates/editor-ffi/src/grep.rs`. The conventions they follow,
and the tests that pin each, are in the module docs of `Editor/Ffi.lean`
("Services and completions").
-/

namespace Editor.Ffi

open Words

/-- Why the grep service refused a search, or how a walk ended refused. -/
inductive GrepRefusal where
  /-- The root is not absolute, or has a `..` component. -/
  | notAbsolute
  /-- The root is not there. -/
  | notFound
  /-- The root is not a directory. -/
  | notADirectory
  /-- The system does not allow it to be read. -/
  | denied
  /-- The pattern does not parse, or its engine refuses it. -/
  | invalid
  /-- The service has shut down. -/
  | shutDown
  /-- Anything else. -/
  | failed
  deriving DecidableEq, Repr

/-- The refusal the library's status says, if it says one. -/
def GrepRefusal.ofStatus? : UInt64 → Option GrepRefusal
  | 1 => some .notAbsolute
  | 2 => some .notFound
  | 3 => some .notADirectory
  | 4 => some .denied
  | 5 => some .invalid
  | 6 => some .shutDown
  | 7 => some .failed
  | _ => none

/-- A file with matches, as it crosses: its path's bytes, whether it was found
in an open buffer's text, and each match's row, start and stop. -/
structure GrepFile where
  /-- The path, as its bytes. -/
  path : ByteArray
  /-- Whether it was searched in an open buffer's text, not on disk. -/
  buffer : Bool
  /-- Each match: its row, its start and its stop, byte offsets. -/
  found : Array (UInt64 × UInt64 × UInt64)
  deriving DecidableEq

/-- How a delivery ends. -/
inductive GrepEnd where
  /-- More is to come. -/
  | more
  /-- The search is complete: the files and the matches it answered. -/
  | complete (files found : UInt64)
  /-- The search stopped at a limit with more to answer. -/
  | truncated (files found : UInt64)
  /-- The walk refused the root, with its words. -/
  | refused (refusal : GrepRefusal) (detail : String)
  deriving DecidableEq, Repr

/-- What a wait of the grep service came to. -/
inductive GrepReply where
  /-- A start's: the search runs, and its id names it. -/
  | started
  /-- A start's: it was refused, with its words: for an invalid pattern, the
  sentence the echo area says. -/
  | refused (refusal : GrepRefusal) (detail : String)
  /-- A read's: the files found, in the walk's order, and how it ends. -/
  | found (files : Array GrepFile) (ending : GrepEnd)
  deriving DecidableEq

/-- The files and the end a found reply's words spell, with the paths cut from
`paths`: an error unless they spell exactly that. -/
private def decodeFound (values : List UInt64) (detail : String) (paths : ByteArray) :
    Except String (Array GrepFile × GrepEnd) := do
  let count :: rest := values | throw "its words are empty"
  let mut words := rest
  let mut files : Array GrepFile := #[]
  let mut used := 0
  for _ in [0:count.toNat] do
    let length :: source :: matchCount :: tail := words
      | throw "its words end inside a file"
    unless tail.length ≥ 3 * matchCount.toNat do
      throw "its words end inside a file's matches"
    let found :=
      (List.range matchCount.toNat).toArray.map fun index =>
        (tail[3 * index]!, tail[3 * index + 1]!, tail[3 * index + 2]!)
    files :=
      files.push { path := paths.extract used (used + length.toNat), buffer := source == 1, found }
    used := used + length.toNat
    words := tail.drop (3 * matchCount.toNat)
  unless used == paths.size do
    throw s!"its lengths do not add up to its {paths.size} bytes of paths"
  let ending ←
    match words with
    | [0] =>
      pure GrepEnd.more
    | [1, fileCount, matchCount] =>
      pure (GrepEnd.complete fileCount matchCount)
    | [2, fileCount, matchCount] =>
      pure (GrepEnd.truncated fileCount matchCount)
    | [3, status] =>
      match GrepRefusal.ofStatus? status with
      | some refusal =>
        pure (GrepEnd.refused refusal detail)
      | none =>
        throw s!"the end's status {status} is no refusal"
    | other =>
      throw s!"the words {other} are no end"
  return (files, ending)

/-- The reply a status, words, a detail and the paths spell, by the table in
the module docs of `crates/editor-ffi/src/grep.rs`. An error, with what was
wrong, for a status the table does not have and for words that are not the
status's.

It is public for `FfiTest`, which decodes literal words with it; the bindings
call it from `grepTake` and nowhere else. -/
def GrepReply.decode (status : UInt64) (words : ByteArray) (detail : String) (paths : ByteArray) :
    Except String GrepReply := do
  let some values := wordsOf? words | throw "its words are not whole words"
  match status, values.toList with
  | 0, [] =>
    return .started
  | 8, values =>
    let (files, ending) ← decodeFound values detail paths
    return .found files ending
  | status, [] =>
    let some refusal :=
      GrepRefusal.ofStatus? status | throw s!"the status {status} is no grep reply"
    return .refused refusal detail
  | status, values =>
    throw s!"the status {status} with the words {values} is no grep reply"

/-- `grepStart` as it crosses: words, the strings end to end, and a snapshot
for each overlay. -/
@[extern "editor_glue_grep_start"]
private opaque grepStartRaw (id : UInt64) (words : @& ByteArray) (strings : @& ByteArray)
    (snapshots : @& Array Snapshot) : IO Bool

/-- Asks the library's grep service to start the search `id` of `pattern`
under `root`, answering at most `files` files and `found` matches and
delivering at most `bound` matches a read, with each `(path, snapshot)` of
`overlays` searched in place of the file at `path`; and returns whether it
was accepted. It returns at once. The completion is a `completion` event on
the completion queue, from the library source 7, whose code is `id`; its
reply is then taken with `grepTake`. `false`, with nothing started, for an id
in use, or when the service could not start the search's thread. -/
def grepStart (id : UInt64) (root pattern : String) (files found bound : UInt64)
    (overlays : Array (String × Snapshot)) : IO Bool :=
  let header :=
    [files, found, bound, root.utf8ByteSize.toUInt64, pattern.utf8ByteSize.toUInt64,
      overlays.size.toUInt64]
  let words :=
    overlays.foldl (fun words (path, _) => pushWord words path.utf8ByteSize.toUInt64)
      (header.foldl pushWord ByteArray.empty)
  let strings :=
    overlays.foldl (fun bytes (path, _) => bytes ++ path.toUTF8) (root.toUTF8 ++ pattern.toUTF8)
  grepStartRaw id words strings (overlays.map (·.2))

/-- Asks for the next delivery of the search `id`, under the wait id `wait`,
and returns whether it was accepted: not for a search that is not held, one
with a read pending, or a wait id in use. The completion is `wait`'s, and its
delivery is taken with `grepTake wait`. -/
@[extern "editor_glue_grep_next"]
opaque grepNext (id wait : UInt64) : IO Bool

/-- A grep reply as the glue builds it, in one call: the object fields first
and the `UInt64` field after them, so the order here is the layout the glue
writes. -/
private structure RawGrepReply where
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- The detail, copied from the library's buffer. -/
  detail : String
  /-- The paths, copied from the library's buffer. -/
  paths : ByteArray
  /-- What the reply is: the library's status. -/
  status : UInt64

/-- `grepTake` before its reply is decoded. -/
@[extern "editor_glue_grep_take"]
private opaque grepTakeRaw (wait : UInt64) : IO (Option RawGrepReply)

/-- Hands over the reply of the wait `wait`, once. `none` when the service
keeps nothing for it. It throws if the library sends a reply these bindings
cannot read. -/
def grepTake (wait : UInt64) : IO (Option GrepReply) := do
  let some raw ← grepTakeRaw wait | return none
  match GrepReply.decode raw.status raw.words raw.detail raw.paths with
  | .ok reply =>
    return some reply
  | .error reason =>
    throw (IO.userError s!"the library's grep reply could not be read: {reason}")

/-- Cancels the search or the wait `id`, and returns whether there was
anything to cancel. A cancelled search reads nothing more; nothing cancelled
is completed. Safe for an id that is unknown. -/
@[extern "editor_glue_grep_cancel"]
opaque grepCancel (id : UInt64) : IO Bool

/-- Asks the grep service for the request `id` to be completed once the
thread of every search started before this call has returned, a cancelled
search's among them, and returns whether it was accepted: refused for an id
in use. It returns at once and keeps no result. `grepCancel` withdraws it. -/
@[extern "editor_glue_grep_flush"]
opaque grepFlush (id : UInt64) : IO Bool

/-- How many searches are held, and how many waits are not answered or not
taken, together. A readout for tests. -/
@[extern "editor_glue_grep_pending"]
opaque grepPending : IO UInt64

/-- Shuts the library's grep service down: ends every search, once each
search's thread has returned. A start asked for later is refused as shut
down. The editor's mains call it before they quit the queues; it is safe to
call again. -/
@[extern "editor_glue_grep_shutdown"]
opaque grepShutdown : IO Unit

end Editor.Ffi
