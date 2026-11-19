import Editor.Api
import Editor.Command.Call
import Editor.Files
import Editor.Job
import Editor.Jumps.Go
import Editor.WorkingSet.Disk
import Editor.WorkingSet.Places
import Editor.Workspace.Attach

/-!
# `working-set-add` and `working-set-open`

A working set is a named list of ranges of a workspace's files
(`Editor/WorkingSet.lean` has the stored form, `Editor/WorkingSet/Places.lean`
where each is held). These are its commands.

## Adding

`working-set-add` works on the primary selection of the window it was
called with.

- **The span** is its extent under the selection's shape
  (`TextId.extents`); a range that is a cursor, its two ends equal, is its
  whole row, with the row's line break.
- **In an excerpt buffer** (project search's results, a set's own buffer, a
  review buffer), each end of the span is located in its source
  (`TextId.locate`), and the source is the buffer over it
  (`EditorState.bufferOver?`), as `project-search-visit` finds it: the range
  recorded is the file's, held by markers of the file's buffer. Ends in two
  sources are refused (`spansTwoFiles`); a source with no file, such as a
  review's old side or a drifted quote, is refused (`noFile`).
- **The set** is of the file's workspace, not of the buffer it was called
  from. A file in no workspace is refused (`noWorkspace`).
- **The name** is the first argument, or is asked for with the prompt
  `Add to working set (<label>): `, whose candidates are the workspace's
  sets, the last used first; the prompt's continuation carries the span, so
  the answer adds what was selected when it was asked. A new name makes a
  new set.
- A range whose file and span are in the set already is not added, and
  `already in <name>` is said; otherwise `<name>: added <path>:<line>`.
- The workspace's sets are read first (`ensureRead`,
  `Editor/WorkingSet/Disk.lean`); when that starts their load, the add runs
  again once it is done. A range added asks for the sets to be written
  (`requestWrite`). With no state directory the first add also says, once,
  that working sets are not kept across restarts.

## Opening

`working-set-open` opens a set of the workspace of the buffer of the window
it was called with, or, in an excerpt buffer with no workspace of its own
(project search's results), of the buffer under the cursor's excerpt; named
by its first argument or asked for with the prompt `Open working set (<label>): `, the last used first. A name the
workspace has no set of is said (`noSuchSet`).

- It records a jump and shows the buffer `*working-set: <name> in <label>*`
  in the calling window, made or emptied, with the mode `working-set`, the
  workspace's, and a record of the set it shows.
- **Each range is placed** (`fill`): a held one at its markers; a detached
  or a drifted one whose file is open is found again first
  (`WorkingSet.attach` with `retry`); a range whose file is open in no
  buffer is loaded by the job `working-set-files` (`File.load` under
  `Files.limit`, then `Files.adopt` shown nowhere, whose hook places it),
  whose command fills the buffer again; a file that cannot be loaded leaves
  its ranges drifted.
- **The excerpts** are each placed range's lines, grouped and merged as
  `WorkingSet.excerpts` decides, headed by `WorkingSet.header`; then each
  drifted range, in the set's order, as a read-only buffer `<path>@drifted`
  holding its stored quote, given the workspace and drawn whole in the face
  `working-set-drifted` (its spans, which the loop translates into the
  set's buffer), headed by `WorkingSet.driftedHeader`. An edit typed in a
  drifted quote is refused as any read-only buffer's. The drifted buffers
  are removed when the set's buffer is filled again or closed
  (`WorkingSet.freeDrifted`).
- Once nothing is loading it says `<name>: <n> ranges, <d> drifted`.

## Visiting

The set's buffer has the mode `working-set`, whose activate key (`RET` in
the Vim scheme's normal state) runs `working-set-visit`: a jump is recorded
and the file's buffer shown at the place under the cursor
(`Jumps.visitLocated`), so `C-o` returns.

## Removing, noting and refreshing

In a set's buffer, the ranges under the cursor are those of the excerpt it
is on whose spans hold its place in the source, or the excerpt's all when
none does (a drifted quote's) (`underCursor`); the buffer keeps which of
the set's ranges each of its excerpts shows (`Shown.excerpts`).

- **`working-set-remove`** (the mode's local `d`) removes the range under
  the cursor, its markers given up; where several are, it asks which by
  their notes, or their path and line (`rangeLabel`). The buffer is filled
  again, `<name>: removed <label>` is said, and the set is written. A set
  left empty is still listed.
- **`working-set-note`** (local `n`) asks `Note: ` with the range's note;
  the answer is its stored note, the buffer is filled again with the
  cursors where they were, so the excerpt's header says it, and the set is
  written. The header is rewritten by filling the excerpts again, not by
  `BufferId.setExcerptHeaders`: a fill is the one place the headers are
  made.
- **`working-set-refresh`** (the mode's refresh key) fills the buffer
  again, so its drifted ranges whose files are open are tried again, and
  says what it holds.

Pinned by `ModelTest.workingSetRunChecks`, on the loop's driver over the
models.
-/

namespace Editor.WorkingSet

/-- The name `working-set-add` is registered under. -/
def addName : String :=
  "working-set-add"

/-- The name `working-set-open` is registered under. -/
def openName : String :=
  "working-set-open"

/-- The name `working-set-visit` is registered under. -/
def visitName : String :=
  "working-set-visit"

/-- The name of a set's buffer's mode. -/
def modeName : String :=
  "working-set"

/-- The name of the job that loads the files of a set's ranges that no
buffer holds. -/
def filesJob : String :=
  "working-set-files"

/-- The category of the candidates the prompts list. -/
def category : String :=
  "working-set"

/-- The workspace of the buffer `id` on this machine: its location, root and
label. -/
def workspaceOfBuffer (state : EditorState) (id : BufferId) : Option (Location × String × String) :=
  do
  let (workspace, _) ← state.workspaceOf? id
  let root ← localRoot? workspace.location
  return (workspace.location, root, workspace.label)

/-- The workspace's set names, the last used first. -/
def namesOf (kept : Kept) : Array String :=
  let names := kept.sets.map (·.name)
  match kept.last with
  | some last => if names.contains last then #[last] ++ names.filter (· != last) else names
  | none => names

/-! ## Adding -/

/-- The bytes of the row the offset `offset` of `text` is on, with its line
break. -/
def rowSpan (text : TextId) (offset : Nat) : EditorM (Nat × Nat) := do
  let row := (← (text.pointOf offset : TextM Editor.Point)).row
  let start ← (text.offsetOf ⟨row, 0⟩ : TextM Nat)
  let rows ← (text.rowCount : TextM Nat)
  let stop ←
    if row + 1 < rows then
      (text.offsetOf ⟨row + 1, 0⟩ : TextM Nat)
    else
      (text.byteLength : TextM Nat)
  return (start, stop)

/-- The span of the primary selection of `call`'s window in its buffer's
text ("Adding", in the module docs). -/
def selectedSpan (call : Call) : EditorM (Option (Nat × Nat)) := do
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | return none
  let text := call.target.buffer.text
  if range.anchor == range.head then
    return some (← rowSpan text range.head)
  let extents ←
    (text.extents
          { selection with
            ranges := #[range], primary := 0 } :
        TextM (Array Extent))
  let some first := extents[0]? | return none
  let some last := extents.back? | return none
  return some (first.start, last.stop)

/-- The file buffer and the span in its text that `call`'s selection is
("Adding", in the module docs), or what is said when there is none. -/
def addedSpan (call : Call) : EditorM (Except String (BufferId × Nat × Nat)) := do
  let state ← editorState
  let some (start, stop) ← selectedSpan call | return .error (noFile call.target.buffer.name)
  let here := call.target.window.buffer
  if call.target.buffer.excerpts.isNone then
    if call.target.buffer.file.isNone then
      return .error (noFile call.target.buffer.name)
    return .ok (here, start, stop)
  let text := call.target.buffer.text
  let some first ←
    (text.locate start : TextM (Option Located)) | return .error (noFile call.target.buffer.name)
  let some last ←
    (text.locate stop : TextM (Option Located)) | return .error (noFile call.target.buffer.name)
  if first.source != last.source then
    return .error spansTwoFiles
  let some source := state.bufferOver? first.source | return .error (noFile call.target.buffer.name)
  let some buffer := state.buffer? source | return .error (noFile call.target.buffer.name)
  if buffer.file.isNone then
    return .error (noFile buffer.name)
  return .ok (source, first.offset, max first.offset last.offset)

/-- Adds the span from `start` to `stop` of the file buffer `id` to the set
`name` of its workspace ("Adding", in the module docs). -/
def addTo (id : BufferId) (start stop : Nat) (name : String) : EditorM Unit := do
  let state ← editorState
  let some buffer := state.buffer? id | return
  let some file := buffer.file | message (noFile buffer.name)
  let some (location, root, _) :=
    workspaceOfBuffer state id | message (noWorkspace addName buffer.name)
  let some relative := relativeIn root file.path | message (noWorkspace addName buffer.name)
  let continuation : Invocation :=
    { command := addName,
      arguments := [.str name, .bool true, .nat id.index, .nat start, .nat stop] }
  unless ← ensureRead location continuation do
    return
  let (kept, added) ← addRange (keptAt (← editorState) location) name id relative start stop
  match added with
  | .already =>
    setKept location kept
    message (alreadyIn name)
  | .added index =>
    let line :=
      ((kept.sets.find? (·.name == name)).bind (·.ranges[index]?)).map (·.stored.start.line)
    let said := addedSentence name relative (line.getD 1)
    if kept.disk == .memoryOnly && !kept.said then
      setKept location { kept with said := true }
      message s!"{said}; {memoryOnlySentence}"
    else
      setKept location kept
      message said
    requestWrite location

/-- `working-set-add` ("Adding", in the module docs): with an answer and the
span the prompt carried, adds it; otherwise the window's selection, to the
set its first argument names or the one the prompt is answered with. -/
def addCommand (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str answer :: .bool true :: .nat buffer :: .nat start :: .nat stop :: _ =>
    let name := answer.trimAscii.toString
    unless name.isEmpty do
      addTo ⟨buffer⟩ start stop name
  | arguments =>
    match ← addedSpan call with
    | .error said =>
      message said
    | .ok (id, start, stop) =>
      match arguments with
      | .str name :: _ =>
        addTo id start stop name
      | _ =>
        let state ← editorState
        let some (location, _, label) :=
          workspaceOfBuffer state id | message (noWorkspace addName call.target.buffer.name)
        let names := namesOf (keptAt state location)
        let opened ←
          prompt (addPrompt label)
              { command := addName
                arguments := [.bool true, .nat id.index, .nat start, .nat stop] } (sources :=
              [.given (.ofTexts "working-sets" category names)])
        if let .error refusal := opened then
          message s!"{addName}: {refusal.describe}"

/-! ## Opening -/

/-- The first and the last row (0-based) of the span from `start` to `stop`
of `text`: a span that ends at a row's start ends on the row before. -/
def rowsOf (text : TextId) (start stop : Nat) : EditorM (Nat × Nat) := do
  let first := (← (text.pointOf start : TextM Editor.Point)).row
  let last := (← (text.pointOf (if stop > start then stop - 1 else start) : TextM Editor.Point)).row
  return (first, max first last)

/-- The bytes of `text` from the start of the row `first` to the end of the
row `last`, with its line break. -/
def rowsSpan (text : TextId) (first last : Nat) : EditorM (Nat × Nat) := do
  let start ← (text.offsetOf ⟨first, 0⟩ : TextM Nat)
  let rows ← (text.rowCount : TextM Nat)
  let stop ←
    if last + 1 < rows then
      (text.offsetOf ⟨last + 1, 0⟩ : TextM Nat)
    else
      (text.byteLength : TextM Nat)
  return (start, stop)

/-- A held range as an excerpt is made of it: its path, its first and last
rows, its buffer, whether it was found with errors, and its note. -/
structure PlacedRange where
  /-- Its file, relative to the root. -/
  path : String
  /-- Its first row. -/
  first : Nat
  /-- Its last row. -/
  last : Nat
  /-- The buffer holding it. -/
  buffer : BufferId
  /-- Whether it was found with errors. -/
  changed : Bool
  /-- Its note. -/
  note : String
  /-- Its index among the set's ranges. -/
  index : Nat

/-- What filling a set's buffer came to: how many ranges it has, how many
are drifted, and the files of the ranges no buffer holds. -/
structure Filled where
  /-- How many ranges the set has. -/
  count : Nat := 0
  /-- How many of them are drifted. -/
  drifted : Nat := 0
  /-- The absolute paths of the files no buffer holds. -/
  pending : Array String := #[]

/-- Fills the set's buffer `results` with the excerpts of the set `name` of
the workspace at `location`, whose root is `root` ("Opening", in the module
docs): its ranges whose files are open placed first. -/
def fill (results : BufferId) (location : Location) (root name : String) : EditorM Filled := do
  let state ← editorState
  let some set := (keptAt state location).sets.find? (·.name == name) | return {}
  -- The ranges not held whose files are open are found again first.
  let mut paths : Array String := #[]
  for range in set.ranges do
    unless range.hold matches .held .. || paths.contains range.stored.path do
      paths := paths.push range.stored.path
  for path in paths do
    let absolute := System.FilePath.mk root / path
    if let some buffer := (← editorState).findFile absolute then
      attach buffer absolute (retry := true)
  let state ← editorState
  let old := ((shownOf state results).map (·.drifted)).getD #[]
  let some set := (keptAt state location).sets.find? (·.name == name) | return {}
  let mut placed : Array PlacedRange := #[]
  let mut drifted : Array (Nat × Stored) := #[]
  let mut pending : Array String := #[]
  for (range, index) in set.ranges.zipIdx do
    match range.hold with
    | .held buffer start stop changed =>
      let some held := state.buffer? buffer | continue
      let (first, last) ← offsets start stop
      let (firstRow, lastRow) ← rowsOf held.text first last
      placed :=
        placed.push
          { path := range.stored.path, first := firstRow, last := lastRow, buffer, changed
            note := range.stored.note, index }
    | .drifted =>
      drifted := drifted.push (index, range.stored)
    | .detached =>
      let absolute := (System.FilePath.mk root / range.stored.path).toString
      unless pending.contains absolute do
        pending := pending.push absolute
  let mut list : Array BufferExcerpt := #[]
  let mut shownRanges : Array (Array Nat) := #[]
  for excerpt in excerpts (placed.map fun range => (range.path, range.first, range.last)) do
    let members := excerpt.ranges.filterMap (placed[·]?)
    let some lead := members[0]? | continue
    let some held := state.buffer? lead.buffer | continue
    let (start, stop) ← rowsSpan held.text excerpt.first excerpt.last
    shownRanges := shownRanges.push (members.map (·.index))
    list :=
      list.push
        { buffer := lead.buffer, start, stop
          header :=
            header excerpt.path (excerpt.first + 1) (members.any (·.changed))
              (members.map (·.note)) }
  let mut made : Array Nat := #[]
  for (index, stored) in drifted do
    let some quote ← readOnlyBufferOf s!"{stored.path}@drifted" stored.quote location | continue
    let size := stored.quote.utf8ByteSize
    discard <| quote.setSpans #[{ start := 0, stop := size, face := ⟨"working-set-drifted"⟩ }]
    made := made.push quote.index
    shownRanges := shownRanges.push #[index]
    list := list.push { buffer := quote, start := 0, stop := size, header := driftedHeader stored }
  discard <| results.setExcerpts list
  -- The quotes the buffer showed before are let go once it no longer shows
  -- them.
  removeQuotes old
  discard <|
      results.setValue localName
        ({ root, name, drifted := made, excerpts := shownRanges } : Shown).encode
  return { count := set.ranges.size, drifted := drifted.size, pending }

/-- Puts the cursor of each window showing `results` at its start. -/
def toStart (results : BufferId) : EditorM Unit := do
  for window in (← editorState).windows do
    if window.buffer == results then
      Jumps.placeCursor window.id 0

/-- What the files job is started with: the set's buffer, by index, its
name, the workspace's root, the set's name, and the files to load. -/
structure FilesOrder where
  /-- The set's buffer's index. -/
  results : Nat
  /-- The set's buffer's name: the job's key. -/
  key : String
  /-- The workspace's root. -/
  root : String
  /-- The set's name. -/
  name : String
  /-- The files to load, absolute. -/
  paths : Array String
  deriving DecidableEq, Repr

/-- The order as a job's arguments. -/
def FilesOrder.arguments (order : FilesOrder) : List Argument :=
  [.nat order.results, .str order.key, .str order.root, .str order.name] ++
    order.paths.toList.map Argument.str

/-- The order `arguments` are, if they are one. -/
def FilesOrder.ofArguments? : List Argument → Option FilesOrder
  | .nat results :: .str key :: .str root :: .str name :: paths => do
    let paths ←
      paths.toArray.mapM fun
          | .str path => some path
          | _ => none
    return { results, key, root, name, paths }
  | _ => none

/-- The set's buffer of an order, if it is still there and still that
set's. -/
def resultsOf (state : EditorState) (index : Nat) (key : String) : Option BufferId := do
  let id : BufferId := ⟨index⟩
  let buffer ← state.buffer? id
  guard (buffer.name == key)
  return id

/-- Fills the set's buffer `results` and, once nothing of it is loading,
says what it holds; otherwise starts the job that loads its files. -/
def fillAndSay (results : BufferId) (location : Location) (root name key : String) : EditorM Unit :=
  do
  let filled ← fill results location root name
  toStart results
  if filled.pending.isEmpty then
    message (openedSentence name filled.count filled.drifted)
  else
    let order : FilesOrder := { results := results.index, key, root, name, paths := filled.pending }
    if let .error refusal← startJob filesJob order.arguments (key := some key) then
      message s!"{openName}: {refusal.describe}"

/-- The command a finished files job hands the loop: each file loaded taken
into a buffer shown nowhere (`Files.adopt`, whose hook places its ranges);
the detached ranges of each file that was not loaded drifted; and the set's
buffer filled again while it is there. -/
def arrived (order : FilesOrder) (loads : Array (String × Except FileError File.Loaded)) :
    EditorM Unit := do
  let location := Location.local (System.FilePath.mk order.root)
  for (path, reply) in loads do
    match reply with
    | .ok loaded =>
      discard <| Files.adopt path loaded
    | .error _ =>
      let kept := keptAt (← editorState) location
      let relative := relativeIn order.root path
      let sets :=
        kept.sets.map fun set =>
          { set with
            ranges :=
              set.ranges.map fun range =>
                if some range.stored.path == relative && range.hold == .detached then
                  { range with hold := .drifted }
                else range }
      setKept location { kept with sets }
  let some results := resultsOf (← editorState) order.results order.key | return
  let filled ← fill results location order.root order.name
  toStart results
  message (openedSentence order.name filled.count filled.drifted)

/-- The files job: loads each file of its order, in order, unless it is
longer than `Files.limit` bytes, and finishes with what the loads come to
(`arrived`). It fails only for arguments that are not an order. -/
def filesWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    FilesOrder.ofArguments? arguments | throw s!"{filesJob}: its arguments are not an order"
  let mut loads := #[]
  for path in order.paths do
    loads := loads.push (path, ← File.load path Files.limit)
  return arrived order loads

/-- Opens the set `name` of the workspace at `location`, whose root is
`root` and label `label`, in `call`'s window ("Opening", in the module
docs). -/
def openSet (call : Call) (location : Location) (root label name : String) : EditorM Unit := do
  unless ← ensureRead location { command := openName, arguments := [.str name] } do
    return
  let kept := keptAt (← editorState) location
  unless kept.sets.any (·.name == name) do
    message (noSuchSet name label)
    return
  setKept location { kept with last := some name }
  let view := call.target.window.id
  Jumps.record view
  let key := bufferName name label
  let results ←
    match ← findBuffer key with
    | some id =>
      pure (some id)
    | none =>
      match ← createExcerptBuffer key #[] with
      | .ok id =>
        pure (some id)
      | .error _ =>
        pure none
  let some results := results | message s!"{openName}: cannot make the buffer {key}"
  Workspace.setBufferWorkspace results location
  discard <| view.show results
  -- `working-set` is compiled, and the view shows the buffer: neither
  -- refusal of `setMajorMode` can happen here.
  discard <| view.setMajorMode modeName
  fillAndSay results location root name key

/-- The workspace a set is opened from `call`'s window in ("Opening", in the
module docs): its buffer's, else, in an excerpt buffer, the workspace of the
buffer under the cursor's excerpt. -/
def workspaceOfCall (call : Call) : EditorM (Option (Location × String × String)) := do
  let state ← editorState
  if let some found := workspaceOfBuffer state call.target.window.buffer then
    return some found
  if call.target.buffer.excerpts.isNone then
    return none
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | return none
  let some located ←
    (call.target.buffer.text.locate range.head : TextM (Option Located)) | return none
  let some source := state.bufferOver? located.source | return none
  return workspaceOfBuffer state source

/-- `working-set-open` ("Opening", in the module docs): the set its first
argument names, or the one the prompt is answered with. -/
def openCommand (call : Call) : EditorM Unit := do
  let state ← editorState
  let some (location, root, label) ←
    workspaceOfCall call | message (noWorkspace openName call.target.buffer.name)
  match call.arguments with
  | .str answer :: .bool true :: _ =>
    let name := answer.trimAscii.toString
    unless name.isEmpty do
      openSet call location root label name
  | .str name :: _ =>
    openSet call location root label name
  | _ =>
    let names := namesOf (keptAt state location)
    let opened ←
      prompt (openPrompt label) { command := openName, arguments := [.bool true] } (sources :=
          [.given (.ofTexts "working-sets" category names)])
    if let .error refusal := opened then
      message s!"{openName}: {refusal.describe}"

/-! ## Visiting -/

/-- What `working-set-visit` says when the cursor is on no file's text. -/
def noRangeHere : String :=
  s!"{visitName}: no file's text here"

/-- `working-set-visit` ("Visiting", in the module docs). -/
def visitCommand (call : Call) : EditorM Unit := do
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | message noRangeHere
  Jumps.visitLocated call.target.window.id call.target.buffer.text range.head noRangeHere

/-! ## Removing, noting and refreshing -/

/-- The name `working-set-remove` is registered under. -/
def removeName : String :=
  "working-set-remove"

/-- The name `working-set-note` is registered under. -/
def noteName : String :=
  "working-set-note"

/-- The name `working-set-refresh` is registered under. -/
def refreshName : String :=
  "working-set-refresh"

/-- What the set's buffer of `call`'s window shows, its set's location, and
the indices of the set's ranges under the cursor: those of the excerpt it
is in whose spans hold its place in the source, or all of the excerpt's
when none does. `none` in a buffer that is no set's, or on no excerpt. -/
def underCursor (call : Call) : EditorM (Option (Shown × Location × Array Nat)) := do
  let state ← editorState
  let some shown := shownOf state call.target.window.buffer | return none
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | return none
  let some located ←
    (call.target.buffer.text.locate range.head : TextM (Option Located)) | return none
  let some members := shown.excerpts[located.excerpt]? | return none
  let location := Location.local (System.FilePath.mk shown.root)
  let some set := (keptAt state location).sets.find? (·.name == shown.name) | return none
  let mut holding := #[]
  for index in members do
    if let some { hold := .held _ start stop _, .. } := set.ranges[index]? then
      let (first, last) ← offsets start stop
      if first ≤ located.offset && located.offset ≤ last then
        holding := holding.push index
  return some (shown, location, if holding.isEmpty then members else holding)

/-- How a range is named when a prompt asks which: its note, or its path
and line when it has none. -/
def rangeLabel (stored : Stored) : String :=
  if stored.note.isEmpty then s!"{stored.path}:{stored.start.line}" else stored.note

/-- What the remove and note commands say on no range. -/
def noRange (command : String) : String :=
  s!"{command}: no range of a working set here"

/-- Fills the set's buffer `results` again, its cursors where they were. -/
def refill (results : BufferId) (shown : Shown) (location : Location) : EditorM Unit := do
  let mut cursors := #[]
  for window in (← editorState).windows do
    if window.buffer == results then
      if let .ok selection← window.id.selection then
        cursors :=
          cursors.push (window.id, (selection.ranges[selection.primary]?.map (·.head)).getD 0)
  discard <| fill results location shown.root shown.name
  -- A note changes no text, so each cursor's offset is where it was.
  for (view, offset) in cursors do
    Jumps.placeCursor view offset

/-- Removes the ranges of `indices` from the set `shown` shows, refills its
buffer and asks for a write. -/
def removeRanges (results : BufferId) (shown : Shown) (location : Location) (indices : Array Nat) :
    EditorM Unit := do
  let kept := keptAt (← editorState) location
  let some set := kept.sets.find? (·.name == shown.name) | return
  for index in indices do
    if let some range := set.ranges[index]? then
      unhold range
  let ranges := (set.ranges.zipIdx.filter fun (_, index) => !indices.contains index).map (·.1)
  let removed := (indices.filterMap (set.ranges[·]?)).map (rangeLabel ·.stored)
  setKept location
      { kept with
        sets :=
          kept.sets.map fun other => if other.name == set.name then { set with ranges } else other }
  discard <| fill results location shown.root shown.name
  toStart results
  message s!"{shown.name}: removed {", ".intercalate removed.toList}"
  requestWrite location

/-- `working-set-remove` (the local `d` of a set's buffer): removes the
range under the cursor; where several are, it asks which by its label
(`rangeLabel`). -/
def removeCommand (call : Call) : EditorM Unit := do
  let results := call.target.window.buffer
  let some (shown, location, indices) ← underCursor call | message (noRange removeName)
  let set := (keptAt (← editorState) location).sets.find? (·.name == shown.name)
  let labelled :=
    indices.filterMap fun index =>
      (set.bind (·.ranges[index]?)).map fun range => (index, rangeLabel range.stored)
  match call.arguments with
  | .str answer :: .bool true :: _ =>
    match labelled.find? (·.2 == answer.trimAscii.toString) with
    | some (index, _) =>
      removeRanges results shown location #[index]
    | none =>
      message (noRange removeName)
  | _ =>
    if labelled.size ≤ 1 then
      removeRanges results shown location (labelled.map (·.1))
    else
      let opened ←
        prompt s!"Remove from {shown.name}: " { command := removeName, arguments := [.bool true] }
            (sources := [.given (.ofTexts "working-set-ranges" category (labelled.map (·.2)))])
      if let .error refusal := opened then
        message s!"{removeName}: {refusal.describe}"

/-- `working-set-note` (the local `n` of a set's buffer): asks for the note
of the range under the cursor, its current note in the prompt; the answer
is its note, which its excerpt's header says, and the set is written. -/
def noteCommand (call : Call) : EditorM Unit := do
  let results := call.target.window.buffer
  match call.arguments with
  | .str answer :: .bool true :: .nat index :: _ =>
    let some shown := shownOf (← editorState) results | message (noRange noteName)
    let location := Location.local (System.FilePath.mk shown.root)
    let kept := keptAt (← editorState) location
    let sets :=
      kept.sets.map fun set =>
        if set.name == shown.name then
          { set with
            ranges :=
              set.ranges.mapIdx fun at_ range =>
                if at_ == index then { range with stored.note := answer.trimAscii.toString }
                else range }
        else set
    setKept location { kept with sets }
    refill results shown location
    requestWrite location
  | _ =>
    let some (shown, location, indices) ← underCursor call | message (noRange noteName)
    let some index := indices[0]? | message (noRange noteName)
    let current :=
      (((keptAt (← editorState) location).sets.find? (·.name == shown.name)).bind
            (·.ranges[index]?)).map
        (·.stored.note)
    let opened ←
      prompt "Note: " { command := noteName, arguments := [.bool true, .nat index] } (initial :=
          current.getD "")
    if let .error refusal := opened then
      message s!"{noteName}: {refusal.describe}"

/-- `working-set-refresh` (the refresh key of a set's buffer): the set
filled again, its drifted ranges whose files are open tried again, and
said. -/
def refreshCommand (call : Call) : EditorM Unit := do
  let results := call.target.window.buffer
  let some shown :=
    shownOf (← editorState) results | message s!"{refreshName}: not a working set's buffer"
  let location := Location.local (System.FilePath.mk shown.root)
  let some buffer := (← editorState).buffer? results | return
  fillAndSay results location shown.root shown.name buffer.name

/-- A set's buffer's mode: the scheme's activate key (`RET` in the Vim
scheme's normal state) visits the range under the cursor, its refresh key
fills it again, and its local `d` removes the range under the cursor and
`n` sets its note. -/
def mode : Mode :=
  { name := modeName, roles := [(Role.refresh, refreshName), (Role.activate, visitName)]
    locals := [("d", removeName), ("n", noteName)]
    localDescs := [("d", "Remove the range"), ("n", "Note the range")] }

end Editor.WorkingSet
