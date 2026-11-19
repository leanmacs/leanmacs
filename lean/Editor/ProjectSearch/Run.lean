import Editor.Api
import Editor.Command.Call
import Editor.Evil.Motions
import Editor.Files
import Editor.Grep
import Editor.Job
import Editor.Jumps.Go
import Editor.ProjectSearch
import Editor.Workspace.FindFile

/-!
# `project-search`

Every match of a pattern under a workspace's root, honouring ignore files,
shown as an excerpt buffer of the files' own buffers: an edit typed in it is
an edit of the file's buffer, as wgrep's is. The decisions are
`Editor/ProjectSearch.lean`'s; the search is the library's, through the job
port (`Editor/Grep.lean`).

## The command

`project-search` takes an optional workspace location
(`Workspace.Location.arguments`) and then an optional pattern, in the syntax
of `/`.

- **What is searched** is decided as `find-file-in-workspace` decides it
  (`Workspace.FindFile.searched`): the location's workspace, else the
  workspace of the buffer of the window it was called with, else the
  directory a command run for that buffer would use; a location that cannot
  read files and run commands is refused, naming `project-search`.
- **With no pattern** it opens the prompt `Search <label>: `, with no
  candidates, and is its own continuation. A blank answer runs nothing.
- **With a pattern** it records a jump (`Jumps.record`), so `C-o` returns;
  sets the last search to the pattern, forward, so the loop draws its
  matches in `search-match` in the results and `n` and `N` step between
  them; makes the results buffer `*search: <pattern> in <label>*`, or empties
  the one there is (releasing the snapshots its last search took), and shows
  it in the calling window; takes a snapshot of each open buffer whose file
  is under the root; and starts the job `project-search`, keyed by the
  results buffer's name, so a new search into the buffer cancels the
  running one.

## The job and the deliveries

The job (`searchWork`) starts the search with each snapshot as the overlay
of its file, and reads it to its end. Each delivery is posted as
`project-search-found` with the files it holds, in walk order. It finishes
with a command that says how the search ended in the echo area, keeps that
sentence in the record, and releases the snapshots it was started with.

`project-search-found` adds each file to the record (a file cut across
deliveries is added once). A file whose buffer is open is placed at once:
its matches are asked of its buffer's whole text (`TextId.matches`), each
match's row and `ProjectSearch.contextRows` rows each side make its
excerpts, merged where they overlap, headed above the first, and they are
inserted at the file's slot in walk order (`BufferId.insertExcerpts`). A
file whose text holds no match now is dropped. A file no buffer holds is
recorded pending, and the delivery's pending files are loaded by one job,
`project-search-load`. When the results buffer is gone, the delivery cancels
the job by its key and does nothing else.

## Visiting

The results buffer has the mode `project-search`, whose activate key (`RET`
in the Vim scheme's normal state) runs `project-search-visit`: it records a
jump and shows the file's buffer, in the window it was called from, at the
place in the file of the cursor's place in the results (`TextId.locate`).
So `C-o` returns to the results, and after `C-w v` two visits leave the two
windows on two matches.

`project-search-symbol` searches the word under the cursor as a whole word,
`\<word\>`, the pattern `*` builds, where `project-search` would search.

## Loading

The load job loads its files in order (`File.load`, under `Files.limit`).
Its command takes each loaded file into a buffer shown nowhere
(`Files.adopt`, as the review takes in a file) and places it as an open
buffer is placed, at its slot in walk order, so a load that finishes after a
later delivery's open file was placed does not reorder the results. A
refused load is dropped and said (`cannot open <path>: ...`); a file whose
text holds no match once loaded is dropped. A file that is no longer
pending in the record (the results were rebuilt by another search) is left
alone.

Each matched file becomes a buffer and stays when the results buffer is
closed, as the review's do: the limits bound how many.

## Where an addition goes

| Addition | Where |
|---|---|
| A decision about what an excerpt shows, or a sentence | `Editor/ProjectSearch.lean`, pinned by `ModelTest.projectSearchChecks` |
| A step of the command or of a delivery | Here, pinned by `ModelTest.projectSearchRunChecks` on the loop's driver |
| A key that runs it | The default config (`config/default/05-leader.lean`) |
-/

namespace Editor.ProjectSearch

/-- The name the command is registered under. -/
def name : String :=
  "project-search"

/-- The name of the command a delivery is posted as. -/
def foundName : String :=
  "project-search-found"

/-- The name of the command that visits the match under the cursor. -/
def visitName : String :=
  "project-search-visit"

/-- The name of the command that searches the word under the cursor. -/
def symbolName : String :=
  "project-search-symbol"

/-- The name of the results buffer's mode. -/
def modeName : String :=
  "project-search"

/-- The name of the search's job. -/
def job : String :=
  "project-search"

/-- The name of the job that loads the files a delivery found that no buffer
holds. -/
def loadJob : String :=
  "project-search-load"

/-- The prompt's label for a search of the workspace labelled `label`. -/
def promptLabel (label : String) : String :=
  s!"Search {label}: "

/-- What a search's job is started with: the results buffer, by index, its
name, which keys the job, the root, the pattern, and each open buffer's
file with the snapshot of its text, by index. -/
structure Order where
  /-- The results buffer's index. -/
  results : Nat
  /-- The results buffer's name: the job's key. -/
  key : String
  /-- The root searched. -/
  root : String
  /-- The workspace's label. -/
  label : String
  /-- The pattern. -/
  pattern : String
  /-- Each overlay: a file's path and the snapshot of its buffer's text. -/
  overlays : Array (String × Nat)
  deriving DecidableEq, Repr

/-- The order as a job's arguments. -/
def Order.arguments (order : Order) : List Argument :=
  [.nat order.results, .str order.key, .str order.root, .str order.label, .str order.pattern] ++
    order.overlays.toList.flatMap fun (path, snapshot) => [.str path, .nat snapshot]

/-- The overlays the rest of an order's arguments are. -/
def overlaysOf? : List Argument → Option (Array (String × Nat))
  | [] => some #[]
  | .str path :: .nat snapshot :: rest => (overlaysOf? rest).map (#[(path, snapshot)] ++ ·)
  | _ => none

/-- The order `arguments` are, if they are one (`Order.arguments`). -/
def Order.ofArguments? : List Argument → Option Order
  | .nat results :: .str key :: .str root :: .str label :: .str pattern :: rest => do
    return { results, key, root, label, pattern, overlays := ← overlaysOf? rest }
  | _ => none

/-- The pattern the command's arguments carry: the text after a location, or
the first text when there is no location. -/
def patternOf (arguments : List Argument) : String :=
  match Location.of? arguments with
  | some (_, rest) => Workspace.FindFile.typedOf rest
  | none => Workspace.FindFile.typedOf arguments

/-- Whether `path` is under the directory `root`. -/
def under (root path : String) : Bool :=
  path.startsWith (if root.endsWith "/" then root else root ++ "/")

/-- The record the results buffer `id` keeps, if it is one. -/
def recordOf (state : EditorState) (id : BufferId) : Option Record :=
  (state.value? id Record.localName).bind Record.decode?

/-- Releases every snapshot of `indices`. -/
def releaseAll (indices : Array Nat) : EditorM Unit := do
  for index in indices do
    (SnapshotId.release ⟨index⟩ : TextM Unit)

/-- The results buffer called `key`, emptied, or made with nothing in it:
`none` when it cannot be made. The snapshots its last search took are
released. -/
def emptied (key : String) : EditorM (Option BufferId) := do
  match ← findBuffer key with
  | some id =>
    if let some record := recordOf (← editorState) id then
      releaseAll record.snapshots
    match ← id.setExcerpts #[] with
    | .ok () =>
      return some id
    | .error _ =>
      return none
  | none =>
    match ← createExcerptBuffer key #[] with
    | .ok id =>
      return some id
    | .error _ =>
      return none

/-- Each open buffer whose file is under `root`, with a snapshot of its text
taken now. -/
def overlaysUnder (root : String) : EditorM (Array (String × Nat)) := do
  let state ← editorState
  let mut overlays := #[]
  for slot in state.buffers do
    let some buffer := slot | continue
    let some file := buffer.file | continue
    let path := file.path.toString
    unless under root path do
      continue
    let snapshot ← (buffer.text.snapshot : TextM SnapshotId)
    overlays := overlays.push (path, snapshot.index)
  return overlays

/-- Searches `root`, labelled `label`, for `pattern`, from `call`'s window
("The command", in the module docs). -/
def run (call : Call) (root label pattern : String) : EditorM Unit := do
  let view := call.target.window.id
  Jumps.record view
  setLastSearch { pattern, forward := true }
  let key := bufferName pattern label
  let some results ← emptied key | message s!"{name}: cannot make the buffer {key}"
  discard <| view.show results
  -- `project-search` is compiled, and the view shows the buffer: neither
  -- refusal of `setMajorMode` can happen here.
  discard <| view.setMajorMode modeName
  let overlays ← overlaysUnder root
  let record : Record := { root, label, pattern, snapshots := overlays.map (·.2) }
  discard <| results.setValue Record.localName record.encode
  let order : Order := { results := results.index, key, root, label, pattern, overlays }
  if let .error refusal← startJob job order.arguments (key := some key) then
    releaseAll record.snapshots
    message s!"{name}: {refusal.describe}"

/-- `project-search` ("The command", in the module docs): with an answer,
`true`, a root and a label, it searches for the answer; otherwise it searches
for the pattern its arguments carry, or prompts for one. -/
def command (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str answer :: .bool true :: .str root :: .str label :: _ =>
    unless answer.trimAscii.isEmpty do
      run call root label answer
  | _ =>
    let (settings, _) ← RegistryRequest.ask .workspaceSettings
    match Workspace.FindFile.searched (← editorState) settings call name with
    | .error said =>
      message said
    | .ok searched =>
      let root := searched.root.toString
      let pattern := patternOf call.arguments
      if pattern.isEmpty then
        let opened ←
          prompt (promptLabel searched.label)
              { command := name, arguments := [.bool true, .str root, .str searched.label] }
        if let .error refusal := opened then
          message s!"{name}: {refusal.describe}"
      else
        run call root searched.label pattern

/-- The byte offset of each row's start in `text`, the first row's 0; a line
feed at the end starts no row. -/
def rowStarts (text : String) : Array Nat :=
  Id.run do
    let bytes := text.toUTF8
    let mut starts := #[0]
    for index in [0:bytes.size] do
      if bytes[index]! == 10 && index + 1 < bytes.size then
        starts := starts.push (index + 1)
    return starts

/-- The row the byte offset `offset` is on, given the rows' starts. -/
def rowOf (starts : Array Nat) (offset : Nat) : Nat :=
  (starts.findIdx? (· > offset)).map (· - 1) |>.getD (starts.size - 1)

/-- Places the file `sequence` of `record`, at `path`, whose buffer is
`buffer`, in the results buffer `results` ("The job and the deliveries", in
the module docs): its excerpts inserted at its slot, or the file dropped
when its text holds no match. The record after it. -/
def place (results : BufferId) (record : Record) (sequence : Nat) (path : String)
    (buffer : BufferId) : EditorM Record := do
  let some held := (← editorState).buffer? buffer | return record.set sequence .dropped
  let content ← (held.text.read : TextM String)
  let found ← (held.text.matches record.pattern 0 content.utf8ByteSize : TextM Matched)
  let extents :=
    match found with
    | .ranges all => all.filter fun (extent : Extent) => extent.start < extent.stop
    | .invalid _ => #[]
  if extents.isEmpty then
    return record.set sequence .dropped
  let starts := rowStarts content
  let rows :=
    excerptRows (extents.map fun (extent : Extent) => rowOf starts extent.start) contextRows
      starts.size
  let heading := header (relative record.root path) extents.size
  let list : Array BufferExcerpt :=
    rows.mapIdx fun index (first, last) =>
      { buffer, start := starts[first]!, stop := starts[last + 1]?.getD content.utf8ByteSize
        header := if index == 0 then heading else "" }
  match ← results.insertExcerpts (record.slot sequence) list with
  | .ok () =>
    return record.set sequence (.placed buffer.index list.size)
  | .error _ =>
    return record.set sequence .dropped

/-- The results buffer of an order's index and key, if it is still there and
still that search's. -/
def resultsOf (state : EditorState) (index : Nat) (key : String) : Option BufferId := do
  let id : BufferId := ⟨index⟩
  let buffer ← state.buffer? id
  guard (buffer.name == key)
  return id

/-- What the load job is started with: the results buffer, by index, its
name, and each file to load, by its sequence number in the record, in walk
order. -/
structure LoadOrder where
  /-- The results buffer's index. -/
  results : Nat
  /-- The results buffer's name. -/
  key : String
  /-- Each file: its sequence number and its path. -/
  files : Array (Nat × String)
  deriving DecidableEq, Repr

/-- The order as a job's arguments. -/
def LoadOrder.arguments (order : LoadOrder) : List Argument :=
  [.nat order.results, .str order.key] ++
    order.files.toList.flatMap fun (sequence, path) => [.nat sequence, .str path]

/-- The files the rest of a load order's arguments are. -/
def filesOf? : List Argument → Option (Array (Nat × String))
  | [] => some #[]
  | .nat sequence :: .str path :: rest => (filesOf? rest).map (#[(sequence, path)] ++ ·)
  | _ => none

/-- The order `arguments` are, if they are one (`LoadOrder.arguments`). -/
def LoadOrder.ofArguments? : List Argument → Option LoadOrder
  | .nat results :: .str key :: rest => do
    return { results, key, files := ← filesOf? rest }
  | _ => none

/-- The command a finished load hands the loop ("Loading", in the module
docs): each file loaded taken into a buffer shown nowhere (`Files.adopt`)
and placed, each refused load dropped and said, while the results buffer is
there and the file still pending in its record. -/
def loaded (order : LoadOrder) (loads : Array (Nat × String × Except FileError File.Loaded)) :
    EditorM Unit := do
  let some results := resultsOf (← editorState) order.results order.key | return
  let some record := recordOf (← editorState) results | return
  let mut record := record
  let wasEmpty := record.files.all fun file => !(file.state matches .placed ..)
  for (sequence, path, reply) in loads do
    let pendingHere :=
      record.files.any fun file =>
        file.sequence == sequence && file.path == path && file.state == .pending
    unless pendingHere do
      continue
    match reply with
    | .error error =>
      record := record.set sequence .dropped
      message s!"{name}: {Files.notOpened path error}"
    | .ok loaded =>
      match ← Files.adopt path loaded with
      | some buffer =>
        record ← place results record sequence path buffer
      | none =>
        record := record.set sequence .dropped
  discard <| results.setValue Record.localName record.encode
  if wasEmpty && record.files.any (fun file => file.state matches .placed ..) then
    for window in (← editorState).windows do
      if window.buffer == results then
        Jumps.placeCursor window.id 0

/-- The load job: loads each file of its order, in order, unless it is longer
than `Files.limit` bytes, and finishes with what the loads come to
(`loaded`). It fails only for arguments that are not a load order. -/
def loadWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    LoadOrder.ofArguments? arguments | throw s!"{loadJob}: its arguments are not a load order"
  let mut loads := #[]
  for (sequence, path) in order.files do
    loads := loads.push (sequence, path, ← File.load path Files.limit)
  return loaded order loads

/-- `project-search-found` ("The job and the deliveries", in the module
docs): the results buffer's index, its name, then each path the delivery
holds. -/
def foundCommand (call : Call) : EditorM Unit := do
  let .nat index :: .str key :: paths := call.arguments | return
  let state ← editorState
  let some results := resultsOf state index key | cancelJob key
  let some record := recordOf state results | cancelJob key
  let mut record := record
  let wasEmpty := record.files.all fun file => !(file.state matches .placed ..)
  let mut pending := #[]
  for argument in paths do
    let .str path := argument | continue
    let (added, sequence?) := record.add path
    record := added
    let some sequence := sequence? | continue
    match (← editorState).findFile path with
    | some buffer =>
      record ← place results record sequence path buffer
    | none =>
      pending := pending.push (sequence, path)
  discard <| results.setValue Record.localName record.encode
  unless pending.isEmpty do
    let order : LoadOrder := { results := index, key, files := pending }
    if let .error refusal← startJob loadJob order.arguments then
      message s!"{name}: {refusal.describe}"
  -- The first excerpts to arrive put each cursor on the results at their
  -- start, so the first match is at hand.
  if wasEmpty && record.files.any (fun file => file.state matches .placed ..) then
    for window in (← editorState).windows do
      if window.buffer == results then
        Jumps.placeCursor window.id 0

/-- The sentence a search ending `ending` says, of `pattern` in the
workspace labelled `label`. -/
def endedSentence (pattern label : String) : Grep.End → String
  | .complete _ 0 => noMatch pattern label
  | .complete files found => summary found files
  | .truncated files found => truncated found files

/-- The command a finished search hands the loop: it says `sentence`, keeps
it in the record if the results buffer is still there, and releases the
snapshots the search was started with. -/
def ended (order : Order) (sentence : String) : EditorM Unit := do
  releaseAll (order.overlays.map (·.2))
  if let some results := resultsOf (← editorState) order.results order.key then
    if let some record := recordOf (← editorState) results then
      discard <|
          results.setValue Record.localName
            { record with
                ended := some sentence, snapshots := #[] }.encode
  message sentence

/-- The search's job ("The job and the deliveries", in the module docs). It
fails only for arguments that are not an order. -/
def searchWork (arguments : List Argument) : Work := fun _ => do
  let some order := Order.ofArguments? arguments | throw s!"{job}: its arguments are not an order"
  let overlays : Array (System.FilePath × File.Source) :=
    order.overlays.map fun (path, snapshot) => (path, .snapshot ⟨snapshot⟩)
  match ← Grep.start order.root order.pattern overlays limits bound with
  | .error error =>
    return ended order (refused error)
  | .ok search =>
    -- A read per delivery; a search's deliveries end, and the bound on the
    -- loop is far past what the limits let through.
    for _ in [0:limits.found + limits.files + 2] do
      match ← Grep.next search with
      | .error error =>
        return ended order (refused error)
      | .ok delivery =>
        unless delivery.found.isEmpty do
          post {
                command := foundName
                arguments :=
                  [.nat order.results, .str order.key] ++
                    delivery.found.toList.map fun found => .str found.path.toString }
        if let some ending := delivery.ended then
          return ended order (endedSentence order.pattern order.label ending)
    return ended order (refused (.failed "the search never ended"))

/-- What `project-search-visit` says when the cursor is on no excerpt's
text. -/
def noMatchHere : String :=
  s!"{visitName}: no file's text here"

/-- `project-search-visit` ("Visiting", in the module docs): records a jump
and shows the file's buffer at the place under the cursor in the window it
was called from, so `C-o` returns to the results. -/
def visitCommand (call : Call) : EditorM Unit := do
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | message noMatchHere
  Jumps.visitLocated call.target.window.id call.target.buffer.text range.head noMatchHere

/-- `project-search-symbol` ("The command", in the module docs): searches
the word under the cursor as a whole word, the pattern `*` builds
(`Evil.starPattern`), where `project-search` would search. -/
def symbolCommand (call : Call) : EditorM Unit := do
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | message Evil.noStringUnderCursor
  let cells ← (Evil.lineCells call.target.buffer.text range.head : TextM (Array (Nat × String)))
  let some (_, word) := Evil.starWord cells range.head | message Evil.noStringUnderCursor
  command { call with arguments := [.str (Evil.starPattern word)] }

/-- The results buffer's mode: the scheme's activate key (`RET` in the Vim
scheme's normal state) visits the match under the cursor. -/
def mode : Mode :=
  { name := modeName, roles := [(Role.activate, visitName)] }

end Editor.ProjectSearch
