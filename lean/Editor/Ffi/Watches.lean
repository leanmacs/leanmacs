import Editor.Ffi.Words

/-!
# Bindings: the watch service

The bindings of `crates/editor-ffi/src/watches.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Services and completions").
-/

namespace Editor.Ffi

open Words

/-- Why the watch service refused a start. -/
inductive WatchRefusal where
  /-- The path is not absolute, or has a `..` component. -/
  | notAbsolute
  /-- The directory is not there. -/
  | notFound
  /-- The path is not a directory. -/
  | notADirectory
  /-- The platform does not allow it. -/
  | denied
  /-- The system's limit on watches is reached. -/
  | limit
  /-- The service has shut down. -/
  | shutDown
  /-- Anything else. -/
  | failed
  deriving DecidableEq, Repr

/-- What a wait of the watch service came to. -/
inductive WatchReply where
  /-- A start's: the watch is live, and its id names it. -/
  | started
  /-- A start's: it was refused, with the platform's words. -/
  | refused (refusal : WatchRefusal) (detail : String)
  /-- A read's: each change's path, as its bytes, and its kinds' bits
  (created 1, written 2, renamed 4, removed 8, missed 16). -/
  | changes (changes : Array (ByteArray × UInt64))
  deriving DecidableEq

/-- The reply a status, words, a detail and the paths spell, by the table in
the module docs of `crates/editor-ffi/src/watches.rs`. An error, with what
was wrong, for a status the table does not have and for words that are not
the status's.

It is public for `FfiTest`, which decodes literal words with it; the bindings
call it from `watchesTake` and nowhere else. -/
def WatchReply.decode (status : UInt64) (words : ByteArray) (detail : String) (paths : ByteArray) :
    Except String WatchReply := do
  let some values := wordsOf? words | throw "its words are not whole words"
  match status, values.toList with
  | 0, [] =>
    return .started
  | 8, count :: rest =>
    unless rest.length == 2 * count.toNat do
      throw s!"its words do not spell {count} changes"
    let pairs := (List.range count.toNat).map fun index => (rest[2 * index]!, rest[2 * index + 1]!)
    let (found, used) :=
      pairs.foldl (init := ((#[] : Array (ByteArray × UInt64)), 0))
        fun (found, start) (length, bits) =>
        (found.push (paths.extract start (start + length.toNat), bits), start + length.toNat)
    unless used == paths.size do
      throw s!"its lengths do not add up to its {paths.size} bytes of paths"
    return .changes found
  | status, [] =>
    let refusal? : Option WatchRefusal :=
      match status with
      | 1 => some .notAbsolute
      | 2 => some .notFound
      | 3 => some .notADirectory
      | 4 => some .denied
      | 5 => some .limit
      | 6 => some .shutDown
      | 7 => some .failed
      | _ => none
    let some refusal := refusal? | throw s!"the status {status} is no watch reply"
    return .refused refusal detail
  | status, values =>
    throw s!"the status {status} with the words {values} is no watch reply"

/-- `watchesStart` as it crosses: three words and the path. -/
@[extern "editor_glue_watches_start"]
private opaque watchesStartRaw (id : UInt64) (words : @& ByteArray) (path : @& String) : IO Bool

/-- Asks the library's watch service to start the watch `id` of `path`: a
file (`target` 0), a directory's entries (1) or its tree (2), its changes
coalesced over `window` milliseconds and at most `bound` paths a delivery;
and returns whether it was accepted. It returns at once. The completion is a
`completion` event on the completion queue, from the library source 4, whose
code is `id`; its reply is then taken with `watchesTake`. `false`, with
nothing started, for a target that is none of these, an id in use, or when
the service could not start the start's thread. -/
def watchesStart (id target window bound : UInt64) (path : String) : IO Bool :=
  watchesStartRaw id (pushWord (pushWord (pushWord ByteArray.empty target) window) bound) path

/-- Asks for the next delivery of the watch `watch`, under the wait id `wait`,
and returns whether it was accepted: not for a watch that is not live, one
with a read pending, or a wait id in use. The completion is `wait`'s, and its
delivery is taken with `watchesTake wait`: every change up to the take. -/
@[extern "editor_glue_watches_next"]
opaque watchesNext (watch wait : UInt64) : IO Bool

/-- A watch reply as the glue builds it, in one call: the object fields
first and the `UInt64` field after them, so the order here is the layout the
glue writes. -/
private structure RawWatchReply where
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- The detail, copied from the library's buffer. -/
  detail : String
  /-- The paths, copied from the library's buffer. -/
  paths : ByteArray
  /-- What the reply is: the library's status. -/
  status : UInt64

/-- `watchesTake` before its reply is decoded. -/
@[extern "editor_glue_watches_take"]
private opaque watchesTakeRaw (wait : UInt64) : IO (Option RawWatchReply)

/-- Hands over the reply of the wait `wait`, once. `none` when the service
keeps nothing for it. It throws if the library sends a reply these bindings
cannot read. -/
def watchesTake (wait : UInt64) : IO (Option WatchReply) := do
  let some raw ← watchesTakeRaw wait | return none
  match WatchReply.decode raw.status raw.words raw.detail raw.paths with
  | .ok reply =>
    return some reply
  | .error reason =>
    throw (IO.userError s!"the library's watch reply could not be read: {reason}")

/-- Cancels the watch or the wait `id`, and returns whether there was
anything to cancel. Cancelling a watch drops its registration once no other
watch shares it; nothing cancelled is completed. Safe for an id that is
unknown. -/
@[extern "editor_glue_watches_cancel"]
opaque watchesCancel (id : UInt64) : IO Bool

/-- How many watches are starting or live, and how many waits are not
answered or not taken, together. A readout for tests. -/
@[extern "editor_glue_watches_pending"]
opaque watchesPending : IO UInt64

/-- Shuts the library's watch service down: ends every watch. A start asked
for later is refused as shut down. The editor's mains call it before they
quit the queues; it is safe to call again. -/
@[extern "editor_glue_watches_shutdown"]
opaque watchesShutdown : IO Unit

end Editor.Ffi
