import Editor.Api
import Editor.Marks
import WorkingSet.Refind

/-!
# Working sets: where each range is held while the editor runs

A workspace's working sets as the editor holds them (`WorkingSet.Kept`):
its store (`WorkingSet.store`, kept per workspace with `Workspace.set` and
`Table.get`, as the review's rounds are), with each range's stored form
(`WorkingSet.lean`) and where it is held now (`Hold`):

- **held** by two anchor markers of its file's buffer's text, the start
  with the bias `before` and the stop with `after`, as an excerpt's ends
  are, so text typed at either end is in the range; and whether it was found
  with errors, which its excerpt's header says;
- **detached**: its file is open in no buffer, and its stored form is what
  it was when it was last held;
- **drifted**: its file was opened and the range was not found in it
  (`WorkingSet.refind`). Its stored form is never changed: a later open of
  the set tries again.

And what is known of the workspace's file on disk (`Disk`): not read yet,
read, unreadable for a reason (then nothing is ever written over it), or
kept in memory only (no state directory). The name of the set last used,
and whether the memory-only sentence was said, are kept beside the sets.

This module imports the editor API and the re-find ladder alone, so the
file commands (`Editor/Files.lean`) and the buffer commands
(`Editor/Buffers.lean`) can call its hooks, as they call `Jumps.detach` and
`Jumps.attach`.

- **Detach** (`detach`, called by `Buffers.closeInto` before a buffer is
  closed): each range held in the buffer gets its stored form refreshed
  from the text now (`refreshed`: the quote, its context and its points;
  the path, the commit and the note kept) and becomes detached, its markers
  given up, and a write of the workspace's sets is asked for
  (`requestWrite`). It answers the workspaces where anything was detached.
- **A save** of a buffer holding a range of a workspace's read sets asks
  for a write of them (`fileSaved`, run at the hook `FilesApi.Saved`, which
  `Files.saved` runs, once the file
  is written). The write is a job started by name, so this module does not
  import the one that does it (`WorkingSet/Disk.lean`).
- **Attach** (`attach`, run at the hook `FilesApi.Opened`, which `Files.adopt` runs once a buffer holds a
  file): in every workspace whose sets are read, or kept in memory, each
  detached range of the file (by its path relative to the workspace's root)
  is found again in the buffer's text (`WorkingSet.refind`) and is held, or
  drifted. With `retry` the drifted ranges of the file are tried again too,
  as an open of the set does. A workspace whose sets are not read is left
  alone.
- **A set's buffer** keeps which set it shows and the buffers of the
  drifted quotes it shows (`Shown`, its local value `working-set`); they are
  removed when it is filled again, and when it is closed
  (`freeDrifted`, called by `Buffers.closeInto`).
- **Adding** (`addRange`): a new range held in a buffer, captured from its
  text, at the end of the set of its name, which is made when there is
  none; or nothing, when the set has that file's range at that span
  already.

Pinned by `WorkingSetTest.workingSetPlaceChecks`, on the loop's driver over the
models.
-/

namespace Editor.WorkingSet

/-- What is known of a workspace's working sets on disk. -/
inductive Disk where
  /-- Not read yet in this run. -/
  | notRead
  /-- Read: what is held is what is kept on disk, and is written back. -/
  | read
  /-- The file could not be read, for `reason`: nothing of it is shown and it
  is never written over. -/
  | unreadable (reason : String)
  /-- There is no state directory: the sets live in memory only. -/
  | memoryOnly
  deriving DecidableEq, Repr, Inhabited

/-- Where a range is held now. -/
inductive Hold where
  /-- By the anchor markers `start` and `stop` of the text of the buffer
  `buffer`; `changed` when it was found with errors. -/
  | held (buffer : BufferId) (start stop : MarkerId) (changed : Bool)
  /-- Nowhere: its file is open in no buffer. -/
  | detached
  /-- Nowhere: its file was opened and it was not found. -/
  | drifted
  deriving DecidableEq, Repr, Inhabited

/-- A range of a set: its stored form and where it is held. -/
structure Range where
  /-- Its stored form. -/
  stored : Stored
  /-- Where it is held. -/
  hold : Hold := .detached
  deriving DecidableEq, Repr, Inhabited

/-- A set as the editor holds it. -/
structure KeptSet where
  /-- Its name. -/
  name : String
  /-- Its ranges, in the order they were added. -/
  ranges : Array Range := #[]
  deriving DecidableEq, Repr, Inhabited

/-- What a workspace keeps of its working sets while the editor runs. -/
structure Kept where
  /-- What is known of its file on disk. -/
  disk : Disk := .notRead
  /-- The name of the set last added to or opened. -/
  last : Option String := none
  /-- Whether the memory-only sentence was said. -/
  said : Bool := false
  /-- Its sets, in order. -/
  sets : Array KeptSet := #[]
  deriving DecidableEq, Repr, Inhabited

/-! ## The store's encoding -/

/-- The value of the field `name` of `fields`. -/
def fieldOf (fields : List (String × Value)) (name : String) : Option Value :=
  (fields.find? (·.1 == name)).map (·.2)

/-- A point as a tree. -/
def Point.encode (point : Point) : Value :=
  .list [.nat point.line, .nat point.column]

/-- The point a tree is. -/
def Point.decode? : Value → Option Point
  | .list [.nat line, .nat column] => some { line, column }
  | _ => none

/-- A stored form as a tree. -/
def Stored.encode (stored : Stored) : Value :=
  .record
    [("path", .str stored.path), ("commit", .str stored.commit), ("quote", .str stored.quote),
      ("prefix", .str stored.before), ("suffix", .str stored.after), ("start", stored.start.encode),
      ("stop", stored.stop.encode), ("note", .str stored.note)]

/-- The stored form a tree is. -/
def Stored.decode? : Value → Option Stored
  | .record fields => do
    let .str path ← fieldOf fields "path" | none
    let .str commit ← fieldOf fields "commit" | none
    let .str quote ← fieldOf fields "quote" | none
    let .str before ← fieldOf fields "prefix" | none
    let .str after ← fieldOf fields "suffix" | none
    let .str note ← fieldOf fields "note" | none
    return {
        path, commit, quote, before, after, note
        start := ← (fieldOf fields "start").bind Point.decode?
        stop := ← (fieldOf fields "stop").bind Point.decode? }
  | _ => none

/-- A marker as a tree: its text's index and its own. -/
def markerTree (marker : MarkerId) : List Value :=
  [.nat marker.text.index, .nat marker.index]

/-- Where a range is held, as a tree. -/
def Hold.encode : Hold → Value
  | .held buffer start stop changed =>
    .list
      ([.str "held", .nat buffer.index] ++ markerTree start ++ markerTree stop ++ [.bool changed])
  | .detached => .str "detached"
  | .drifted => .str "drifted"

/-- Where a range is held, from a tree. -/
def Hold.decode? : Value → Option Hold
  |
  .list
      [.str "held", .nat buffer, .nat startText, .nat start, .nat stopText, .nat stop,
        .bool changed] =>
    some (.held ⟨buffer⟩ ⟨⟨startText⟩, start⟩ ⟨⟨stopText⟩, stop⟩ changed)
  | .str "detached" => some .detached
  | .str "drifted" => some .drifted
  | _ => none

/-- What is known of the file on disk, as a tree. -/
def Disk.encode : Disk → Value
  | .notRead => .str "notRead"
  | .read => .str "read"
  | .unreadable reason => .list [.str "unreadable", .str reason]
  | .memoryOnly => .str "memoryOnly"

/-- What is known of the file on disk, from a tree. -/
def Disk.decode? : Value → Option Disk
  | .str "notRead" => some .notRead
  | .str "read" => some .read
  | .list [.str "unreadable", .str reason] => some (.unreadable reason)
  | .str "memoryOnly" => some .memoryOnly
  | _ => none

/-- A range as a tree. -/
def Range.encode (range : Range) : Value :=
  .record [("stored", range.stored.encode), ("hold", range.hold.encode)]

/-- The range a tree is. -/
def Range.decode? : Value → Option Range
  | .record [("stored", stored), ("hold", hold)] => do
    return { stored := ← Stored.decode? stored, hold := ← Hold.decode? hold }
  | _ => none

/-- A set as a tree. -/
def KeptSet.encode (set : KeptSet) : Value :=
  .record [("name", .str set.name), ("ranges", .list (set.ranges.toList.map (·.encode)))]

/-- The set a tree is. -/
def KeptSet.decode? : Value → Option KeptSet
  | .record [("name", .str name), ("ranges", .list ranges)] => do
    return { name, ranges := ← ranges.toArray.mapM Range.decode? }
  | _ => none

/-- What a workspace keeps of its working sets, as a tree. -/
def Kept.encode (kept : Kept) : Value :=
  .record
    [("disk", kept.disk.encode), ("last", (kept.last.map Value.str).getD .null),
      ("said", .bool kept.said), ("sets", .list (kept.sets.toList.map (·.encode)))]

/-- What a workspace keeps of its working sets, from a tree. -/
def Kept.decode? : Value → Option Kept
  | .record [("disk", disk), ("last", last), ("said", .bool said), ("sets", .list sets)] => do
    let last ←
      match last with
      | .null =>
        some none
      | .str name =>
        some (some name)
      | _ =>
        none
    return { disk := ← Disk.decode? disk, last, said, sets := ← sets.toArray.mapM KeptSet.decode? }
  | _ => none

/-- A workspace's working sets, as its store keeps them while the editor
runs. -/
def store : Store Kept :=
  { name := "working-sets", version := 1, initial := {}, encode := Kept.encode
    decode := Kept.decode? }

/-! ## Reading and writing what a workspace keeps -/

/-- The root of a workspace on this machine. -/
def localRoot? : Location → Option String
  | .local root => some root.toString
  | _ => none

/-- `path` relative to `root`, when it is under it. -/
def relativeIn (root : String) (path : System.FilePath) : Option String :=
  let lead := if root.endsWith "/" then root else root ++ "/"
  let path := path.toString
  if path.startsWith lead then some (String.ofList (path.toList.drop lead.length)) else none

/-- Every workspace on this machine, with its root and what it keeps of its
working sets. -/
def stores (state : EditorState) : Array (Location × String × Kept) :=
  state.workspaces.workspaces.filterMap fun (workspace, _) => do
    let root ← localRoot? workspace.location
    return (workspace.location, root, state.workspaces.get store workspace.location)

/-- What the workspace at `location` keeps of its working sets. -/
def keptAt (state : EditorState) (location : Location) : Kept :=
  state.workspaces.get store location

/-- Has the workspace at `location` keep `kept`. -/
def setKept (location : Location) (kept : Kept) : EditorM Unit :=
  discard <| Workspace.set store location kept

/-- Whether `range` is held in the buffer `id`. -/
def heldIn (id : BufferId) (range : Range) : Bool :=
  match range.hold with
  | .held buffer .. => buffer == id
  | _ => false

/-- The byte offsets two markers are at now. -/
def offsets (start stop : MarkerId) : EditorM (Nat × Nat) := do
  let first ← (Marks.offsetOf start : TextM Nat)
  let last ← (Marks.offsetOf stop : TextM Nat)
  return (first, max first last)

/-- `range` with its stored form refreshed from the text that holds it now,
when it is held: the quote, its context and its points; its path, its
commit and its note kept. A range held nowhere is as it was. -/
def refreshed (range : Range) : EditorM Range := do
  let .held buffer start stop _ := range.hold | return range
  let some held := (← editorState).buffer? buffer | return range
  let content ← (held.text.read : TextM String)
  let (first, last) ← offsets start stop
  return { range with
      stored := capture content first last range.stored.path range.stored.commit range.stored.note }

/-- The name of the job that writes a workspace's working sets: it reads the
commit `HEAD` is at, and its command refreshes and renders the sets and
starts the save (`WorkingSet/Disk.lean`). -/
def writeJob : String :=
  "working-set-write"

/-- Asks for the working sets of the workspace at `location` to be written
("When it is written", `WorkingSet/Disk.lean`): the job `writeJob`
is started by name, keyed by the root, so a newer write cancels an older
one still asking for the commit. Nothing is asked when the sets are not
read (not read yet, unreadable or in memory only), when there is no state
directory, or when no write job is registered. -/
def requestWrite (location : Location) : EditorM Unit := do
  let state ← editorState
  unless (keptAt state location).disk == .read do
    return
  let some directory := state.stateDirectory | return
  let some root := localRoot? location | return
  let (settings, _) ← RegistryRequest.ask .workspaceSettings
  discard <|
      startJob writeJob [.str root, .str settings.git, .str directory.toString] (key :=
        some s!"{writeJob} {root}")

/-- Asks for a write of each workspace whose read sets hold a range in the
buffer `id`, which was saved (run at `FilesApi.Saved`). -/
def fileSaved (id : BufferId) : EditorM Unit := do
  for (location, _, kept) in stores (← editorState) do
    if kept.disk == .read && kept.sets.any (·.ranges.any (heldIn id)) then
      requestWrite location

/-- Gives up the markers `range` is held by, if it is held. -/
def unhold (range : Range) : EditorM Unit := do
  if let .held _ start stop _ := range.hold then
    (start.text.unmark start : TextM Unit)
    (stop.text.unmark stop : TextM Unit)

/-- Holds the span from `start` to `stop` of the text of the buffer `id`
(`changed` when it was found with errors): two anchor markers, the start
biased `before` and the stop `after`. Detached when the buffer is gone. -/
def holdIn (id : BufferId) (start stop : Nat) (changed : Bool) : EditorM Hold := do
  let some buffer := (← editorState).buffer? id | return .detached
  let first ← (buffer.text.mark (.anchor { offset := start, bias := .before }) : TextM MarkerId)
  let last ← (buffer.text.mark (.anchor { offset := stop, bias := .after }) : TextM MarkerId)
  return .held id first last changed

/-- Detaches the ranges held in the buffer `id` ("Detach", in the module
docs), in every workspace, and answers the locations of the workspaces
where anything was detached. -/
def detach (id : BufferId) : EditorM (Array Location) := do
  let mut detached := #[]
  for (location, _, kept) in stores (← editorState) do
    unless kept.sets.any (·.ranges.any (heldIn id)) do
      continue
    let mut sets := #[]
    for set in kept.sets do
      let mut ranges := #[]
      for range in set.ranges do
        if heldIn id range then
          let refreshedRange ← refreshed range
          unhold range
          ranges := ranges.push { refreshedRange with hold := .detached }
        else
          ranges := ranges.push range
      sets := sets.push { set with ranges }
    setKept location { kept with sets }
    requestWrite location
    detached := detached.push location
  return detached

/-- Where `text` places `range` now, held in the buffer `id` or drifted. -/
def placed (id : BufferId) (content : String) (range : Range) : EditorM Range := do
  let placement ← (refind content range.stored : FuzzyM Placement)
  match placement.span? with
  | some (start, stop) =>
    return { range with hold := ← holdIn id start stop (placement matches .changed ..) }
  | none =>
    return { range with hold := .drifted }

/-- Attaches the ranges of the file at `path` to the buffer `id`, which
holds it ("Attach", in the module docs); with `retry`, its drifted ranges
too. -/
def attach (id : BufferId) (path : System.FilePath) (retry : Bool := false) : EditorM Unit := do
  let some opened := (← editorState).buffer? id | return
  for (location, root, kept) in stores (← editorState) do
    unless kept.disk matches .read | .memoryOnly do
      continue
    let some relative := relativeIn root path | continue
    let wanted (range : Range) : Bool :=
      range.stored.path == relative &&
        (range.hold == .detached || (retry && range.hold == .drifted))
    unless kept.sets.any (·.ranges.any wanted) do
      continue
    let content ← (opened.text.read : TextM String)
    let mut sets := #[]
    for set in kept.sets do
      let mut ranges := #[]
      for range in set.ranges do
        ranges :=
          ranges.push
            (←
              if wanted range then
                placed id content range
              else
                pure range)
      sets := sets.push { set with ranges }
    -- The store is read again: placing a range asks nothing of the state.
    setKept location { keptAt (← editorState) location with sets }

/-- What adding a range came to. -/
inductive Added where
  /-- It was added to the set, as its range at this index. -/
  | added (index : Nat)
  /-- The set holds that file's range at that span already. -/
  | already
  deriving DecidableEq, Repr

/-- Adds the span from `start` to `stop` of the text of the buffer `id`,
whose file is `relative` to the workspace's root, to the set `name` of what
`kept` holds ("Adding", in the module docs): held by markers, captured from
the text, its commit empty until it is written. The set is made when there
is none; `last` is the set's name. -/
def addRange (kept : Kept) (name : String) (id : BufferId) (relative : String) (start stop : Nat) :
    EditorM (Kept × Added) := do
  let some buffer := (← editorState).buffer? id | return (kept, .already)
  let set := (kept.sets.find? (·.name == name)).getD { name }
  for range in set.ranges do
    if let .held at_ first last _ := range.hold then
      if at_ == id && range.stored.path == relative && (← offsets first last) == (start, stop) then
        return ({ kept with last := some name }, .already)
  let content ← (buffer.text.read : TextM String)
  let hold ← holdIn id start stop false
  let range : Range := { stored := capture content start stop relative, hold }
  let set := { set with ranges := set.ranges.push range }
  let sets :=
    if kept.sets.any (·.name == name) then
      kept.sets.map fun other => if other.name == name then set else other
    else kept.sets.push set
  return ({ kept with
        sets, last := some name },
      .added (set.ranges.size - 1))

/-! ## A set's buffer -/

/-- What a set's buffer keeps as its local value `localName`: the root of
the workspace, the set's name and the drifted buffers it shows. -/
structure Shown where
  /-- The workspace's root. -/
  root : String
  /-- The set's name. -/
  name : String
  /-- The indices of the drifted quotes' buffers. -/
  drifted : Array Nat := #[]
  /-- For each excerpt it shows, in order, the indices among the set's
  ranges of the ranges in it. -/
  excerpts : Array (Array Nat) := #[]
  deriving DecidableEq, Repr

/-- The name of the local value a set's buffer keeps (`Shown`). -/
def localName : String :=
  "working-set"

/-- What a set's buffer keeps, as a tree. -/
def Shown.encode (shown : Shown) : Value :=
  .record
    [("root", .str shown.root), ("name", .str shown.name),
      ("drifted", .list (shown.drifted.toList.map Value.nat)),
      ("excerpts",
        .list (shown.excerpts.toList.map fun members => .list (members.toList.map Value.nat)))]

/-- What a set's buffer keeps, from a tree. -/
def Shown.decode? : Value → Option Shown
  |
  .record
      [("root", .str root), ("name", .str name), ("drifted", .list drifted),
        ("excerpts", .list excerpts)] =>
    do
    let nats (items : List Value) : Option (Array Nat) :=
      items.toArray.mapM fun
        | .nat index => some index
        | _ => none
    let excerpts ←
      excerpts.toArray.mapM fun
          | .list members => nats members
          | _ => none
    return { root, name, drifted := ← nats drifted, excerpts }
  | _ => none

/-- What the buffer `id` keeps as a set's buffer, if it is one. -/
def shownOf (state : EditorState) (id : BufferId) : Option Shown :=
  (state.value? id localName).bind Shown.decode?

/-- Removes the buffers of `indices`, drifted quotes a set's buffer showed. -/
def removeQuotes (indices : Array Nat) : EditorM Unit := do
  for index in indices do
    discard <| (⟨index⟩ : BufferId).remove

/-- Removes the drifted quotes' buffers the set's buffer `id` shows, and
forgets them. -/
def freeDrifted (id : BufferId) : EditorM Unit := do
  let some shown := shownOf (← editorState) id | return
  removeQuotes shown.drifted
  discard <| id.setValue localName { shown with drifted := #[] }.encode

end Editor.WorkingSet
