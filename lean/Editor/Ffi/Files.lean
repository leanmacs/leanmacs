import Editor.Ffi.Snapshot
import Editor.Ffi.Words
import Editor.InferredWait

/-!
# Bindings: the file service

The bindings of `crates/editor-ffi/src/files.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Services and completions").
-/

namespace Editor.Ffi

open Words

/-- What the file service compares to tell whether a file changed: when it
was last modified and how long it is. Two stamps are compared for equality
and never ordered. -/
structure FileStamp where
  /-- Whole seconds since the Unix epoch; negative before 1970. -/
  seconds : Int
  /-- The nanoseconds beyond `seconds`. -/
  nanoseconds : UInt64
  /-- The file's length in bytes. -/
  size : UInt64
  deriving DecidableEq, Repr

/-- What a save expects to find at its path. -/
inductive FileExpect where
  /-- Anything, or nothing: the save checks nothing. -/
  | whatever
  /-- No file. -/
  | absent
  /-- The file with this stamp: the one a load or the last save returned. -/
  | unchanged (stamp : FileStamp)
  deriving DecidableEq, Repr

/-- Why the file service refused a load or a save. -/
inductive FileRefusal where
  /-- The path is not absolute. -/
  | relativePath
  /-- Nothing is at the path, or at a directory on the way to it. -/
  | notFound
  /-- What is at the path is not a file. -/
  | notAFile
  /-- What is at the path is not a directory: a listing's refusal, and a
  directory made's when a file is at the path or on the way to it. -/
  | notADirectory
  /-- The file system does not allow it; `detail` is the platform's words. -/
  | denied (detail : String)
  /-- The file is binary: its first NUL byte is at `offset`. -/
  | binary (offset : UInt64)
  /-- The file is `size` bytes long, over the `limit` the load was given. -/
  | tooLarge (size limit : UInt64)
  /-- The file on disk is not the one the save expected: `found` is its
  stamp now, or `none` when there is no file. -/
  | changed (found : Option FileStamp)
  /-- No name was free for the save's temporary file. -/
  | noTemporaryName
  /-- Anything else; `detail` says what. -/
  | failed (detail : String)
  deriving DecidableEq, Repr

/-- What a file request came to. -/
inductive FileResult where
  /-- A file was loaded: its text as a snapshot, the stamp a save is to
  expect if the file has not changed, and how many line feeds stand alone
  and how many follow a carriage return. -/
  | loaded (snapshot : Snapshot) (stamp : FileStamp) (lineFeeds crlfs : UInt64)
  /-- A file was saved, and has this stamp. -/
  | saved (stamp : FileStamp)
  /-- A stamp was read: the file's, or `none` when nothing is there. -/
  | stamped (stamp : Option FileStamp)
  /-- A directory was listed: each entry's name and kind code (0 a file, 1 a
  directory, 2 anything else), sorted by the bytes of the names. -/
  | listed (entries : Array (String × UInt64))
  /-- A directory was made, with every directory on the way to it, or was
  there already. -/
  | made
  /-- The request was refused. -/
  | refused (refusal : FileRefusal)

/-- The stamp three words spell, from the index `first`: its seconds, a two's
complement word, then its nanoseconds and its size. -/
private def stampAt (words : Array UInt64) (first : Nat) : FileStamp where
  seconds := words[first]!.toInt64.toInt
  nanoseconds := words[first + 1]!
  size := words[first + 2]!

/-- The entries a listing's words and detail spell: after the count, each
entry's kind code and the byte length of its name, the names end to end in
`detail`. An error for a kind code no one defined, a length past the
detail's end or inside a character, and a detail longer than the names. -/
private def listingOf (words : Array UInt64) (detail : String) :
    Except String (Array (String × UInt64)) := do
  let count := words[0]!.toNat
  unless words.size == 1 + 2 * count do
    throw s!"a listing of {count} entries has {words.size} words"
  let bytes := detail.toUTF8
  let mut entries := #[]
  let mut start := 0
  for index in [0:count] do
    let kind := words[1 + 2 * index]!
    unless kind < 3 do
      throw s!"the kind {kind} is no entry's kind"
    let stop := start + words[2 + 2 * index]!.toNat
    unless stop ≤ bytes.size do
      throw s!"a name ends at {stop}, past the names' {bytes.size} bytes"
    let some name := String.fromUTF8? (bytes.extract start stop)
      | throw s!"the name from {start} to {stop} is not whole characters"
    entries := entries.push (name, kind)
    start := stop
  unless start == bytes.size do
    throw s!"the names are {bytes.size} bytes, and the lengths add up to {start}"
  return entries

/-- The result a status, a snapshot, words and a detail spell, by the table
in the module docs of `crates/editor-ffi/src/files.rs`. An error, with what
was wrong, for a status the table does not have and for words that are not
the status's.

It is public for `FfiTest`, which decodes literal words with it; the
bindings call it from `filesTake` and nowhere else. -/
def FileResult.decode (status : UInt64) (snapshot : Option Snapshot) (words : ByteArray)
    (detail : String) : Except String FileResult := do
  let some words := wordsOf? words | throw "its words are not whole words"
  match status, words.size, snapshot with
  | 0, 0, none =>
    return .made
  | 0, 5, some snapshot =>
    return .loaded snapshot (stampAt words 0) words[3]! words[4]!
  | 0, 3, none =>
    return .saved (stampAt words 0)
  | 0, 4, none =>
    match words[0]! with
    | 0 =>
      return .stamped none
    | 1 =>
      return .stamped (some (stampAt words 1))
    | present =>
      throw s!"a stamped file is present or not, and the word says {present}"
  | 1, 0, none =>
    return .refused .relativePath
  | 2, 0, none =>
    return .refused .notFound
  | 3, 0, none =>
    return .refused .notAFile
  | 4, 0, none =>
    return .refused (.denied detail)
  | 5, 1, none =>
    return .refused (.binary words[0]!)
  | 6, 2, none =>
    return .refused (.tooLarge words[0]! words[1]!)
  | 7, 4, none =>
    match words[0]! with
    | 0 =>
      return .refused (.changed none)
    | 1 =>
      return .refused (.changed (some (stampAt words 1)))
    | present =>
      throw s!"a changed file is present or not, and the word says {present}"
  | 8, 0, none =>
    return .refused .noTemporaryName
  | 9, 0, none =>
    return .refused (.failed detail)
  | 10, 0, none =>
    return .refused .notADirectory
  | 11, size, none =>
    if size == 0 then
      throw "a listing has its count"
    return .listed (← listingOf words detail)
  | status, count, snapshot =>
    let handle := if snapshot.isSome then "a snapshot" else "no snapshot"
    throw s!"the status {status} with {count} words and {handle} is no file result"

/-- Asks the library's file service to load the file at `path`, unless it is
longer than `limit` bytes, as the request `id`, and returns whether it was
accepted. It returns at once. The completion is a `completion` event on the
completion queue, from the library source 2, whose code is `id`; there is
none if the request is cancelled first. The result is then taken with
`filesTake`.

The path crosses as its bytes, with no decoding. `false`, with nothing
started, if `id` is in use or the service could not start its thread. -/
@[extern "editor_glue_files_load"]
opaque filesLoad (id : UInt64) (path : @& String) (limit : UInt64) : IO Bool

/-- Asks the library's file service for the stamp of the file at `path`, as
the request `id`, and returns whether it was accepted. It returns at once,
and nothing of the file is read. The completion and the result are as
`filesLoad`'s: the result is `stamped`, or a refusal.

`false`, with nothing started, if `id` is in use or the service could not
start its thread. -/
@[extern "editor_glue_files_stamp"]
opaque filesStamp (id : UInt64) (path : @& String) : IO Bool

/-- Asks the library's file service to list the directory at `path`, as the
request `id`, and returns whether it was accepted. It returns at once. The
completion and the result are as `filesLoad`'s: the result is `listed`, or a
refusal.

`false`, with nothing started, if `id` is in use or the service could not
start its thread. -/
@[extern "editor_glue_files_list"]
opaque filesList (id : UInt64) (path : @& String) : IO Bool

/-- Asks the library's file service to make the directory at `path`, with
every directory on the way to it, as the request `id`, and returns whether it
was accepted. It returns at once. The completion and the result are as
`filesLoad`'s: the result is `made`, or a refusal (`notADirectory` when a
file is at the path or on the way to it).

`false`, with nothing started, if `id` is in use or the service could not
start its thread. -/
@[extern "editor_glue_files_make_directory"]
opaque filesMakeDirectory (id : UInt64) (path : @& String) : IO Bool

/-- Asks the library's file service to add `bytes` to the end of the file at
`path`, making the file when nothing is there, as the request `id`, and
returns whether it was accepted. It returns at once. The completion and the
result are as `filesLoad`'s: the result is `made` (status 0, no words), or a
refusal. The bytes are handed to the system and not synced.

`false`, with nothing started, if `id` is in use or the service could not
start its thread. -/
@[extern "editor_glue_files_append"]
opaque filesAppend (id : UInt64) (path : @& String) (bytes : @& ByteArray) : IO Bool

/-- Asks the library's file service to remove the file at `path`, as the
request `id`, and returns whether it was accepted. It returns at once. The
completion and the result are as `filesLoad`'s: the result is `made` (status
0, no words), nothing there included, or a refusal.

`false`, with nothing started, if `id` is in use or the service could not
start its thread. -/
@[extern "editor_glue_files_remove"]
opaque filesRemove (id : UInt64) (path : @& String) : IO Bool

/-- Asks the library's file service to add `bytes` to the end of the file at
`path`, unobserved: with no id, never completed and with no result kept,
worked in order with every other request. A failure is kept, with its path,
for `filesFailure`. `false`, with nothing started, if the service could not
start its thread. -/
@[extern "editor_glue_files_append_unobserved"]
opaque filesAppendUnobserved (path : @& String) (bytes : @& ByteArray) : IO Bool

/-- Asks the library's file service to remove the file at `path`,
unobserved, as `filesAppendUnobserved` asks for an append. Nothing there is
no failure. -/
@[extern "editor_glue_files_remove_unobserved"]
opaque filesRemoveUnobserved (path : @& String) : IO Bool

/-- Asks the library's file service to save what `snapshot` holds as the
file at `path`, whatever is there, unobserved, as `filesAppendUnobserved`
asks for an append: atomically, by a temporary file and a rename. The
library keeps its own hold on the snapshot's text. -/
@[extern "editor_glue_files_save_unobserved"]
opaque filesSaveUnobserved (snapshot : @& Snapshot) (path : @& String) : IO Bool

/-- Takes the oldest failure of an unobserved request the service keeps, once:
its path and what failed, for a person. `none` when it keeps none. -/
@[extern "editor_glue_files_failure"]
opaque filesFailure : IO (Option (String × String))

/-- `filesSave` as it crosses: what the save expects as a tag (0 whatever, 1
absent, 2 unchanged) and a stamp's three numbers, its seconds as a two's
complement word. -/
@[extern "editor_glue_files_save"]
private opaque filesSaveRaw (id : UInt64) (snapshot : @& Snapshot) (path : @& String)
    (tag seconds nanoseconds size : UInt64) : IO Bool

/-- Asks the library's file service to save what `snapshot` holds as the file
at `path`, if what is on disk is what `expect` says, as the request `id`, and
returns whether it was accepted. It returns at once, and the library keeps
its own hold on the snapshot's text. The completion and the result are as
`filesLoad`'s.

`false`, with nothing started, if `id` is in use, if `expect` holds a stamp
with nanoseconds no stamp has, or if the service could not start its thread.
Seconds no 64-bit word holds are sent as the nearest it does. -/
def filesSave (id : UInt64) (snapshot : Snapshot) (path : String) (expect : FileExpect) : IO Bool :=
  match expect with
  | .whatever => filesSaveRaw id snapshot path 0 0 0 0
  | .absent => filesSaveRaw id snapshot path 1 0 0 0
  | .unchanged stamp =>
    let seconds := max (-(2 ^ 63 : Int)) (min stamp.seconds (2 ^ 63 - 1))
    filesSaveRaw id snapshot path 2 seconds.toInt64.toUInt64 stamp.nanoseconds stamp.size

/-- A file result as the glue builds it, in one call: the object fields
first and the `UInt64` field after them, so the order here is the layout the
glue writes. -/
private structure RawFileResult where
  /-- The loaded text, for a load that succeeded. -/
  snapshot : Option Snapshot
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- The detail, copied from the library's buffer. -/
  detail : String
  /-- How the request ended: the library's status. -/
  status : UInt64

/-- `filesTake` before its result is decoded. -/
@[extern "editor_glue_files_take"]
private opaque filesTakeRaw (id : UInt64) : IO (Option RawFileResult)

/-- Hands over the result of the file request `id`, once. `none` when the
service keeps no result for `id`: it is not finished, it was cancelled, its
result was taken already, or it was another service's id. It throws if the
library sends a result these bindings cannot read. -/
def filesTake (id : UInt64) : IO (Option FileResult) := do
  let some raw ← filesTakeRaw id | return none
  match FileResult.decode raw.status raw.snapshot raw.words raw.detail with
  | .ok result =>
    return some result
  | .error reason =>
    throw (IO.userError s!"the library's file result could not be read: {reason}")

/-- Cancels the file request `id`, and returns whether there was anything to
cancel: a request waiting or being worked, or a result not taken. It is safe
for an id that is unknown. A request that was waiting is never worked; a save
being worked does not replace its file; a completion that was already queued
still arrives, and its result is gone. -/
@[extern "editor_glue_files_cancel"]
opaque filesCancel (id : UInt64) : IO Bool

/-- Asks the file service for the request `id` to be completed once every
file request started before this call, unobserved ones included, has been
worked, and returns whether it was accepted. It returns at once. Its
completion is queued behind those of the requests it waited for, and it
keeps no result. `filesCancel` withdraws it while it waits. -/
@[extern "editor_glue_files_flush"]
opaque filesFlush (id : UInt64) : IO Bool

/-- Asks the file service to hold its worker as the request `id`, and
returns whether it was accepted: once the worker reaches it, behind every
request started before it, `id` is completed and the worker works nothing
more until `filesCancel id` lets it go. A control for tests, which the
editor never asks for. -/
@[extern "editor_glue_files_hold"]
opaque filesHold (id : UInt64) : IO Bool

/-- `filesPending` is an inferred wait (`Editor/InferredWait.lean`). -/
def filesPending.inferredWait : InferredWait :=
  .count
    [`Editor.Job.Real, `Editor.Job.Contract, `Editor.Job.FlushContract, `Editor.Job.HandleContract,
      `Editor.Test.Linked.Services]

/-- How many file requests are waiting or being worked, unobserved ones
included, and how many results have not been taken, together. A readout for
tests, which use it to see that a cancel left nothing behind, and for a
host's end, which waits for the journal's writes to be worked. -/
@[extern "editor_glue_files_pending"]
opaque filesPending : IO UInt64

end Editor.Ffi
