import Editor.Api
import Editor.Files
import Editor.Job
import Editor.Restore

/-!
# Restoring a session, and writing its index

The jobs and commands of the `restore` package (`Editor/Restore/Compiled.lean`)
over the core of `Editor/Restore.lean`.

## Restoring

At start, with a state directory, the host's first request is `restore`
(`Editor/Headless.lean`), which starts the job `restore` with the state
directory; the host holds its driver's requests that follow until the
restore has finished (`Kept.restored`). It is two halves, each a job and
its command, since only a command can read what a job loaded.

- **The job `restore`** (`restoreWork`) makes `session/journals/` with its
  parents, so the journal's orders always have a directory to write in;
  lists `session/` and `journals/`; and loads every index and every journal
  file there (`File.load`, under `Files.limit`).
- **Its command** (`read`) reads the indexes by the version rule and
  chooses the one restored (`Document.choose`), gives this run its number
  (`nextRun`), and reads each log. Before any buffer is made it restores
  the workspace table (`Workspaces.restore`, `Editor/Restore/Workspaces.lean`):
  each cell whose store has a codec registered now, a package's, is met
  with it, the codec asked of the registry (`RegistryRequest.storeCodec`),
  and the table, its cells met, handed to the state as plain data
  (`StateRequest.restoreWorkspaces`); every other cell, config's, is
  parked (`Kept.parked`, through `setRestore` with the rest of what the
  restore keeps) for the reconciler to meet once config installs. Per buffer of a run, the live journal is
  the highest generation whose log has a header; with none, the highest
  with a base, restored as a buffer with no file. Each live journal is
  restored at once: its base taken in (`JobSnapshotId.toText`), its log
  replayed (`Journal.replay`), as a new buffer with the header's name (or
  a free one, `EditorState.freeName`) whose history is a new tree marked
  saved nowhere, so it is modified; it holds the header's file at the
  header's stamp and line ending (`attachFile`), so a save expects the old
  stamp. A no-file text called `scratch` goes into the scratch buffer when
  that is untouched. Each buffer it makes is marked as having no history
  before the restore (`markRestored`), and one that holds a file is
  attached to its workspace (`Workspace.attach`), as an open does. Its modes are set by name, language before major, as
  `Files.adopt` orders them; a major mode no one has registered yet is
  deferred (`Kept.deferred`, `Editor/Restore.lean`, "Modes a restore
  deferred"). Then it starts `restore-files` for the second half, keeping
  what it is to finish (`Kept.pending`).
- **The job `restore-files`** (`filesWork`) stats each restored buffer's
  file and loads each file of the index that had no unsaved text.
- **Its command** (`restored`) marks a restored buffer whose file differs
  from its header's stamp, or is gone, as changed and untold
  (`BufferId.markChanged … false`), so the first edit is refused, as is a
  save, until `:w!` or `:e!`: a file is never silently overwritten. It
  reopens each unmodified file (`Files.adopt`) with its modes; one that is
  gone is said and not restored. It shows the buffer the focused view
  showed in the window focused now, with its recorded selection and scroll
  top, clamped to the text, in bytes as they were recorded
  (`Restore.offsetOf`). Each buffer it reopens is marked as having no
  history before the restore. With the index's frame
  (`Editor/Restore/Frame.lean`) it then puts every window of every tab
  back: the record renumbered (`Frame.Record.renumber`) so that the window
  focused now keeps its id as the focused window of the tab in view, every
  other view made on its buffer at its recorded place with markers of its
  own, a view whose buffer is not kept on `scratch` (said, unless it showed
  `scratch`), each window's jump list put back (a kept buffer's entry held
  by a new marker, a path's as a file place, attached once its buffer is
  restored, and an entry of no restored buffer dropped), a float at a
  position held by a new marker, and the frame asked for
  (`StateRequest.restoreFrame`). The layout it put back is held until config
  installs (`Kept.heldLayout`). A record `check` refuses, a prompt open,
  or a refusal of the state falls back to the placement above, said, every
  marker made for it given up. With no frame (a format-1 index) the other
  windows' places are kept (`Kept.places`), and written again in the index
  while their buffer's text does not move, each naming the run whose view
  ids it is under (`Place.run`): view ids are unique only within a run, so
  the focused view and the frame's views are looked up among the index's
  own places alone, and a kept place is never taken for a window of a later
  run. It hands the host the index's
  declared stores' cells (`restoreCells`): config's as they are, to be
  parked until config installs, a package's met with its codec, and any
  other's dropped, said. Each reported job the index says was running is
  said stopped by the restart. It gives the run its number, which starts
  the journal (`Kept.run`), and the files it took in to remove
  (`Kept.stale`, `Kept.staleIndexes`).
- **What is said**: a line in the echo area, `restore: N buffers, M with
  unsaved text`, then `; K changed on disk` when there are, `; J jobs
  stopped` when a reported job was running, and `; see *restore*` when the
  report has more; the whole report in the read-only
  buffer `*restore*`, shown nowhere.
- **A restore never fails to start the editor.** Every problem is a line
  of the report: a file of the session that cannot be loaded, an index or
  a log line not understood (the journal is then left on disk), a base
  that cannot be loaded.

## Writing the index

`restore-write` (`writeWork`), which the reconciler starts keyed, waits
`writeDelay` on the job clock, and its command (`writeNow`) renders this
run's index (`Document.of`), records it as written, takes a snapshot of a
text made of it and starts `restore-save` (`saveWork`), keyed: the
directory made with its parents and the snapshot saved over this run's
`session-<run>.json`, never another run's, by the file service's atomic
save. Its command (`savedIndex`) releases the snapshot, says a refusal, and
marks the index written once, after which the indexes a restore took in are
removed.

Pinned by `ModelTest.restoreChecks`, on the loop's driver over the models.
-/

namespace Editor.Restore

/-- The name of the report's buffer. -/
def reportName : String :=
  "*restore*"

/-- The name of the report's buffer's mode. -/
def reportMode : String :=
  "restore-report"

/-- What the job `restore` loaded. -/
structure Loaded where
  /-- The state directory. -/
  directory : System.FilePath
  /-- What making the journals' directory came to. -/
  made : Except FileError Unit
  /-- The names of the session directory's files. -/
  sessionNames : Array String := #[]
  /-- The names of the journals' directory's files. -/
  journalNames : Array String := #[]
  /-- Each index: its run, its name, and its load. -/
  indexes : Array (Nat × String × Except FileError File.Loaded) := #[]
  /-- Each journal file: its run, buffer and generation, whether it is the
  base, and its load. -/
  journals : Array (Nat × Nat × Nat × Bool × Except FileError File.Loaded) := #[]

/-- The text a load holds, read and let go of: what its job loaded, taken
into the store, read and released. -/
def textOf (loaded : File.Loaded) : EditorM String := do
  let text ← loaded.snapshot.toText
  let content ← (text.read : TextM String)
  ((TextSource.text text).release : TextM Unit)
  return content

/-- Sets what the session's reconciler keeps (`StateRequest.setRestore`). -/
def setKept (kept : Kept) : EditorM Unit :=
  EditorState.ask (.setRestore kept)

/-- The restore, finished, with `report` said in the echo area: nothing is
journalled, since the run has no number. -/
def failed (report : String) : EditorM Unit := do
  setKept
      { (← editorState).restore with
        restored := true, pending := none }
  message report

/-- Sets the modes of the buffer `id` by name, language before major: a
major mode no one has registered is deferred. -/
def setModes (id : BufferId) (major : Option String) (minors : Array String)
    (language : Option String) : EditorM (Array Kept.Deferred) := do
  if let some language := language then
    discard <| id.setLanguage (some language)
  let mut deferred := #[]
  if let some mode := major then
    match ← id.setMajorMode mode with
    | .error (.noSuchMode _) =>
      deferred := deferred.push { buffer := id.index, mode }
    | _ =>
      pure ()
  for minor in minors.reverse do
    discard <| id.addMinorMode minor
  return deferred

/-- The journal files of each buffer of a run, by generation. -/
structure Group where
  /-- The run. -/
  run : Nat
  /-- The buffer's key. -/
  buffer : Nat
  /-- Each generation's base load, if there is one. -/
  bases : Array (Nat × Except FileError File.Loaded) := #[]
  /-- Each generation's log load, if there is one. -/
  logs : Array (Nat × Except FileError File.Loaded) := #[]

/-- The journal files of `loaded`, grouped by run and buffer. -/
def groups (loaded : Loaded) : Array Group :=
  loaded.journals.foldl
    (fun groups (run, buffer, generation, base, reply) =>
      let found := groups.findIdx? fun group => group.run == run && group.buffer == buffer
      let group := (found.bind (groups[·]?)).getD { run, buffer }
      let group :=
        if base then { group with bases := group.bases.push (generation, reply) }
        else { group with logs := group.logs.push (generation, reply) }
      match found with
      | some index => groups.set! index group
      | none => groups.push group)
    #[]

/-- The name of a restored buffer with no header and no entry. -/
def orphanName (run buffer : Nat) : String :=
  s!"restored {run}-{buffer}"

/-- Puts `text`, which holds a restored text with no file, into the scratch
buffer when that is untouched, and answers it then; `none` otherwise. -/
def intoScratch (text : TextId) : EditorM (Option BufferId) := do
  let state ← editorState
  let some id := state.findBuffer EditorState.scratchName | return none
  let some scratch := state.buffer? id | return none
  if scratch.isModified || scratch.file.isSome then
    return none
  let length ← (scratch.text.byteLength : TextM Nat)
  if length != 0 then
    return none
  let content ← (text.read : TextM String)
  discard <| (scratch.text.insert 0 content : TextM Unit)
  ((TextSource.text text).release : TextM Unit)
  return some id

/-- The names of the stores whose cells `recorded` holds, each once. -/
def cellNames (recorded : Document.Workspaces) : Array String :=
  let cells :=
    recorded.workspaces.flatMap (·.cells) ++ recorded.projects.flatMap (·.cells) ++
      recorded.unscoped
  cells.foldl (fun names cell => if names.contains cell.name then names else names.push cell.name)
    #[]

/-- The codecs registered now for the stores called `names`
(`RegistryRequest.storeCodec`), as a lookup: plain data a pure restore of
the table can take. -/
def codecsOf (names : Array String) : EditorM (String → Option (String × StoreCodec)) := do
  let mut found : Array (String × String × StoreCodec) := #[]
  for name in names do
    if let some (owner, codec)← storeCodec? name then
      found := found.push (name, owner, codec)
  return fun name => (found.find? (·.1 == name)).map (·.2)

/-- The config generation now: how many configs have installed. -/
def generationNow : EditorM Nat := do
  return (← RegistryRequest.ask .workspaceSettings).2

/-- The first half's command ("Restoring", in the module docs): what the job
`restore` loaded, read, the indexes chosen among, each live journal restored,
and `restore-files` started for the rest. -/
def read (loaded : Loaded) : EditorM Unit := do
  if let .error error := loaded.made then
    failed
        s!"restore: {journalsDirectory loaded.directory} cannot be made: {error.describe}; nothing is restored or journalled"
    return
  let mut report : Array String := #[]
  -- The indexes, by the version rule.
  let mut reads : Array (Nat × Document.Read) := #[]
  for (run, name, reply) in loaded.indexes do
    match reply with
    | .ok file =>
      reads := reads.push (run, Document.read name (← textOf file))
    | .error error =>
      reads :=
        reads.push
          (run,
            { report := #[s!"{name} cannot be loaded ({error.describe}): it is left as it is"] })
  let choice := Document.choose reads
  report := report ++ choice.report
  let run :=
    nextRun (loaded.sessionNames ++ loaded.journalNames)
      (reads.filterMap (·.2.document.map (·.run)))
  let entryOf (journalRun key : Nat) : Option Document.Buffer :=
    choice.restored.bind fun document =>
      if document.run == journalRun then document.buffers.find? (·.key == key) else none
  let focused := choice.restored.bind (·.focused)
  -- The focused view's place: one of the index's own, never one an earlier
  -- run's ids are under (`Place.run`).
  let ownFocused (place : Place) : Bool := place.run.isNone && some place.view == focused
  let mut pending : Kept.Pending :=
    { run, staleIndexes := choice.remove.map (indexPath loaded.directory)
      frame := choice.restored.bind (·.frame), jobs := (choice.restored.map (·.jobs)).getD #[]
      stores := (choice.restored.map (·.stores)).getD #[] }
  -- The workspace table, before any buffer is attached, so that attaching
  -- finds its workspaces: each cell met with the codec registered now (a
  -- package's), and the others parked for config's.
  let mut parked := #[]
  if let some recorded := choice.restored.bind (·.workspaces) then
    let (table, waiting, lines) := Workspaces.restore recorded (← codecsOf (cellNames recorded))
    Workspace.restoreTable table
    parked := waiting
    report := report ++ lines
  let mut restoredKeys : Array Nat := #[]
  let mut statArguments : List Argument := []
  for group in groups loaded do
    -- Each log, read.
    let mut decoded : Array (Nat × Journal.Decoded) := #[]
    for (generation, reply) in group.logs do
      match reply with
      | .ok file =>
        decoded := decoded.push (generation, Journal.decode (← textOf file))
      | .error error =>
        report :=
          report.push
            s!"journal {journalStem group.run group.buffer generation}: its log cannot be loaded ({error.describe}): it is left as it is"
    let headed := decoded.filter (·.2.header.isSome)
    let live : Option Nat :=
      if headed.isEmpty then
        (group.bases.map (·.1)).foldl (fun found g => some ((found.getD g).max g)) none
      else some ((headed.map (·.1)).foldl max 0)
    let some generation := live | continue
    let stem := journalStem group.run group.buffer generation
    let some (_, .ok base) := group.bases.find? (·.1 == generation) |
      report := report.push s!"journal {stem}: its base cannot be loaded: it is left as it is"
      continue
    let log : Journal.Decoded := ((decoded.find? (·.1 == generation)).map (·.2)).getD {}
    let text ← base.snapshot.toText
    let played ← (Journal.replay text log.records : TextM Nat)
    let mut understood := true
    if played < log.records.size then
      report :=
        report.push
          s!"journal {stem}: {log.records.size - played} of its records do not apply: it is left as it is"
      understood := false
    if log.torn > 0 then
      report := report.push s!"journal {stem}: a torn last line of {log.torn} bytes is dropped"
    if let some why := log.stopped then
      report :=
        report.push s!"journal {stem}: {why}: what came before is restored, and it is left as it is"
      understood := false
    let entry := entryOf group.run group.buffer
    let header := log.header
    let name :=
      (header.map (·.name)) <|> (entry.map (·.name)) |>.getD (orphanName group.run group.buffer)
    -- The buffer: the scratch buffer when the text is a scratch text and it
    -- is untouched, a new one otherwise.
    let path := header.bind (·.path)
    let intoScratch? ←
      if path.isNone && name == EditorState.scratchName then
        intoScratch text
      else
        pure none
    let id ←
      match intoScratch? with
      | some id =>
        pure (some id)
      | none =>
        match ← addBuffer ((← editorState).freeName name) text with
        | .ok id =>
          pure (some id)
        | .error _ =>
          pure none
    let some id := id |
      report := report.push s!"journal {stem}: no buffer could be made for it: it is left as it is"
      continue
    -- Modified: a new tree, saved nowhere, which starts at the restore.
    let some buffer := (← editorState).buffer? id | continue
    let history ← (UndoTree.over buffer.text : TextM UndoTree)
    discard <| EditorState.ask (.setHistory id { history with saved := none })
    discard <| id.markRestored
    if let (some path, some first) := (path, header) then
      if let some stamp := first.stamp then
        discard <| id.attachFile path stamp first.lineEnding
        Workspace.attach id path
        statArguments := statArguments ++ [.nat id.index, .str path]
    if let some entry := entry then
      pending :=
        { pending with
          deferred := pending.deferred ++ (← setModes id entry.major entry.minors entry.language) }
      let revision ← (buffer.text.revision : TextM Nat)
      let others := entry.views.filter fun place => !ownFocused place
      if !others.isEmpty then
        pending :=
          { pending with
            places :=
              pending.places.push
                { buffer := id.index, revision, places := others, run := group.run } }
      if let some place := entry.views.find? ownFocused then
        pending := { pending with focusBuffer := some (id.index, place) }
      restoredKeys := restoredKeys.push entry.key
      pending := { pending with keys := pending.keys.push (entry.key, id.index) }
    pending := { pending with unsaved := pending.unsaved + 1 }
    if understood then
      let files :=
        group.bases.map (fun (g, _) => basePath loaded.directory group.run group.buffer g) ++
          group.logs.map fun (g, _) => logPath loaded.directory group.run group.buffer g
      pending := { pending with stale := pending.stale ++ files }
  -- The files of the index with no unsaved text, to reopen.
  let mut loads : List Argument := []
  for entry in (choice.restored.map (·.buffers)).getD #[] do
    if restoredKeys.contains entry.key then
      continue
    let some file := entry.file | continue
    if let some place := entry.views.find? ownFocused then
      pending := { pending with focusReopen := some (pending.reopen.size, place) }
    pending :=
      { pending with
        reopen :=
          pending.reopen.push
            { key := entry.key, path := file.path, major := entry.major, minors := entry.minors
              language := entry.language
              places := entry.views.filter fun place => !ownFocused place
              run := (choice.restored.map (·.run)).getD 0 } }
    loads := loads ++ [.str file.path]
  pending := { pending with report := report }
  setKept
      { (← editorState).restore with
        pending := some pending, parked, parkedAt := ← generationNow }
  let arguments :=
    [.str loaded.directory.toString, .nat (statArguments.length / 2)] ++ statArguments ++ loads
  if let .error refusal← startJob filesJob arguments then
    failed s!"restore: {refusal.describe}"

/-- The job `restore` ("Restoring", in the module docs): the journals'
directory made, the session's files listed and loaded, and the first half's
command (`read`). -/
def restoreWork (arguments : List Argument) : Work := fun _ => do
  let .str state :: _ := arguments | throw s!"{restoreJob}: its arguments are not a restore's"
  let directory := System.FilePath.mk state
  let made ← File.makeDirectory (journalsDirectory directory)
  let names (path : System.FilePath) : JobM (Array String) := do
    match ← File.list path with
    | .ok entries =>
      return (entries.filter (·.kind == .file)).map (·.name)
    | .error _ =>
      return #[]
  let sessionNames ← names (sessionDirectory directory)
  let journalNames ← names (journalsDirectory directory)
  let mut indexes := #[]
  for name in sessionNames do
    if let some run := runOfIndex? name then
      indexes :=
        indexes.push (run, name, ← File.load (sessionDirectory directory / name) Files.limit)
  let mut journals := #[]
  for name in journalNames do
    if let some (run, buffer, generation, base) := journalOf? name then
      journals :=
        journals.push
          (run, buffer, generation, base,
            ← File.load (journalsDirectory directory / name) Files.limit)
  return read { directory, made, sessionNames, journalNames, indexes, journals }

/-- Puts the window `view`, which shows `buffer`, at `place`, clamped to the
text: its selection's anchor and head, their columns in bytes as recorded
(`Restore.offsetOf`), and its scroll's top row. -/
def placeIn (view : ViewId) (buffer : BufferId) (place : Place) : EditorM Unit := do
  let some shown := (← editorState).buffer? buffer | return
  let anchor ← (offsetOf shown.text place.anchor : TextM Nat)
  let head ← (offsetOf shown.text place.head : TextM Nat)
  if let .ok selection← view.selection then
    discard <|
        view.select
          { selection with
            ranges := #[⟨anchor, head⟩], primary := 0 }
  let top ← (offsetOf shown.text ⟨place.top, 0⟩ : TextM Nat)
  if let some window := (← editorState).window? view then
    discard <|
        (observing (shown.text.place window.scroll (.anchor { offset := top, bias := .before })) :
          TextM _)

/-- The report's buffer, holding `lines`, read-only and shown nowhere: made,
or its text replaced. -/
def writeReport (lines : Array String) : EditorM Unit := do
  let text := "\n".intercalate lines.toList ++ "\n"
  let id ←
    match ← findBuffer reportName with
    | some id =>
      pure (some id)
    | none =>
      match ← createBuffer reportName with
      | .ok id =>
        pure (some id)
      | .error _ =>
        pure none
  let some id := id | return
  let some buffer := (← editorState).buffer? id | return
  discard <| id.setReadOnly false
  let length ← (buffer.text.byteLength : TextM Nat)
  discard <| (buffer.text.delete 0 length : TextM Unit)
  discard <| (buffer.text.insert 0 text : TextM Unit)
  discard <| id.setReadOnly true
  discard <| id.setMajorMode reportMode

/-- The name of config's owner (`Config.Owner.config`), whose cells a
restore hands on as they are, to be parked until config installs. -/
def configOwner : String :=
  "config"

/-- What the report says of the reported job `job` that was running. -/
def stoppedLine (job : RunningJob) : String :=
  let key := (job.key.map fun key => s!" ({key})").getD ""
  s!"the job {job.name}{key} of {job.owner} was running: the restart stopped it"

/-- The declared stores' cells of the index to hand the host
("Restoring", in the module docs), and what the report says: config's as
they are, to be parked until config installs; a package's met with the
codec registered now, which packages register before the restore; any
other not handed, and said. -/
def storesOf (cells : Array KeptCell) : EditorM (Array KeptCell × Array String) := do
  let mut handed := #[]
  let mut report := #[]
  for cell in cells do
    if cell.owner == configOwner then
      handed := handed.push cell
      continue
    match ← storeCodec? cell.name with
    | some (owner, codec) =>
      if owner == cell.owner then
        let met := codec.declaration.meet (some (cell.version, cell.value))
        handed :=
          handed.push
            { cell with
              version := met.version, value := met.value }
        if let some why := met.lost then
          report := report.push s!"store {cell.name} of {cell.owner}: {why}"
      else
        report :=
          report.push
            s!"store {cell.name} of {cell.owner}: {cell.owner} keeps no such store now: it is dropped"
    | none =>
      report :=
        report.push
          s!"store {cell.name} of {cell.owner}: {cell.owner} keeps no such store now: it is dropped"
  return (handed, report)

/-- The jump `jump` recorded, as a place of this run: held by a new marker
in the buffer restored for its key (`keys`), at its row and column in
characters, or in the file at its path; `none` for a key no buffer was
restored for. With it, the marker made, if one was. -/
def placeOfJump (keys : Array (Nat × Nat)) (jump : Jump) :
    EditorM (Option (Editor.Place × Option MarkerId)) := do
  match jump with
  | .file path row column =>
    return some (.file path row column, none)
  | .kept key row column =>
    let some (_, index) := keys.find? (·.1 == key) | return none
    let some buffer := (← editorState).buffer? ⟨index⟩ | return none
    let marker ←
      (do
          Marks.placeMarker buffer.text (← Marks.offsetAt buffer.text row column) : TextM MarkerId)
    return some (.held ⟨index⟩ marker, some marker)

/-- A window's jumps as recorded, as this run's (`placeOfJump`): an entry
of no restored buffer dropped, the index moved back past it. With them,
the markers made. -/
def jumpsOfRecord (keys : Array (Nat × Nat)) (record : Jumps.Record) :
    EditorM (Editor.Jumps × Array MarkerId) := do
  let mut entries := #[]
  let mut index := 0
  let mut made := #[]
  for position in [0:record.entries.size] do
    let some jump := record.entries[position]? | continue
    if let some (place, marker)← placeOfJump keys jump then
      entries := entries.push place
      made := made ++ marker.toArray
      if position < record.index then
        index := index + 1
  if record.index ≥ record.entries.size then
    index := entries.size
  let mut previous := none
  if let some jump := record.previous then
    if let some (place, marker)← placeOfJump keys jump then
      previous := some place
      made := made ++ marker.toArray
  return ({ list := { entries, index }, previous }, made)

/-- Puts back the frame `record` recorded ("Restoring", in the module docs):
renumbered from the window focused now, which keeps its id and is the
focused view of the tab in view; every other view made on its buffer at its
place (`placed`, by the record's view ids) with markers of its own, or on
`scratch` for a view whose buffer is not kept; its jumps put back by
`keys`; and the frame asked for (`restoreFrame`). The report's lines, or
why it is not restored, every marker it made then given up. -/
def restoreFrameOf (record : Frame.Record) (placed : Array (Nat × BufferId × Place))
    (keys : Array (Nat × Nat)) : EditorM (Except String (Array String)) := do
  if let some why := record.check then
    return .error why
  let state ← editorState
  if state.prompt.isSome then
    return .error LayoutRefusal.promptOpen.describe
  let start := state.frame.focused
  let some startWindow := state.window? start | return .error s!"there is no window {start.index}"
  let shape ←
    match ← (startWindow.selection.text.marker startWindow.selection : TextM Marker) with
    | .selection selection =>
      pure selection.shape
    | _ =>
      pure Shape.exclusive
  let scratch := state.findBuffer EditorState.scratchName
  let (renumbered, map, next) := record.renumber start.index state.nextView
  let mut windows : Array Window := #[]
  let mut made : Array MarkerId := #[]
  let mut lines := #[]
  for (old, new) in map do
    let target := (placed.find? (·.1 == old)).map (·.2)
    if target.isNone then
      if let some (_, name) := record.elsewhere.find? (·.1 == old) then
        if name != EditorState.scratchName then
          lines :=
            lines.push
              s!"window {old} showed {name}, which is not kept: it shows {EditorState.scratchName}"
    if new == start.index then
      let mut window := startWindow
      if let some (_, place) := target then
        if let some jumps := place.jumps then
          let (restored, markers) ← jumpsOfRecord keys jumps
          window := { window with jumps := restored }
          made := made ++ markers
      windows := windows.push window
      continue
    let shown : Option (BufferId × Option Place) :=
      match target with
      | some (buffer, place) => some (buffer, some place)
      | none => (scratch <|> some startWindow.buffer).map (·, none)
    let some (buffer, place) := shown | continue
    let some held := (← editorState).buffer? buffer | continue
    let (anchor, head, top) ←
      match place with
      | some place =>
        (do
            return (← offsetOf held.text place.anchor, ← offsetOf held.text place.head,
                ← offsetOf held.text ⟨place.top, 0⟩) :
            TextM (Nat × Nat × Nat))
      | none =>
        pure (0, 0, 0)
    let scroll ← (held.text.mark (.anchor { offset := top, bias := .before }) : TextM MarkerId)
    let selection ←
      (held.text.mark (.selection { ranges := #[⟨anchor, head⟩], shape }) : TextM MarkerId)
    made := made ++ #[scroll, selection]
    let mut jumps := {}
    if let some jumped := place.bind (·.jumps) then
      let (restored, markers) ← jumpsOfRecord keys jumped
      jumps := restored
      made := made ++ markers
    windows := windows.push { id := ⟨new⟩, buffer, scroll, selection, jumps }
  -- A float anchored at a position, held by a marker of its window's
  -- buffer at the recorded spot.
  let mut anchors := #[]
  for tab in renumbered.tabs do
    for float in tab.floats do
      let .position view spot := float.anchor | continue
      let some window := windows.find? (·.id == ⟨view⟩) | continue
      let some held := (← editorState).buffer? window.buffer | continue
      let marker ←
        (do
            Marks.placeMarker held.text (← offsetOf held.text spot) : TextM MarkerId)
      made := made.push marker
      anchors := anchors.push (float.view, marker)
  match ← restoreFrame renumbered windows anchors next with
  | .ok () =>
    -- A place in the file of a buffer restored is held in it again.
    for (_, index) in keys do
      if let some file := ((← editorState).buffer? ⟨index⟩).bind (·.file) then
        Jumps.attach ⟨index⟩ file.path
    return .ok lines
  | .error refusal =>
    for marker in made do
      discard <| (observing (marker.text.unmark marker) : TextM _)
    return .error refusal.describe

/-- The second half's command ("Restoring", in the module docs): each
restored buffer whose file changed or is gone marked, untold; each file with
no unsaved text reopened; the focused place put back; the report said; and
the run given its number. -/
def restored (stats : Array (Nat × Except FileError File.Stamp))
    (loads : Array (System.FilePath × Except FileError File.Loaded)) : EditorM Unit := do
  let some pending := (← editorState).restore.pending | return
  let mut report := pending.report
  let mut changed := 0
  for (index, stat) in stats do
    let id : BufferId := ⟨index⟩
    let some file := ((← editorState).buffer? id).bind (·.file) | continue
    let found : Option (Option File.Stamp) :=
      match stat with
      | .ok stamp => if stamp == file.stamp then none else some (some stamp)
      | .error .notFound => some none
      | .error _ => none
    if let some found := found then
      discard <| id.markChanged file.stamp found false
      changed := changed + 1
      report :=
        report.push
          s!"{file.path}: changed on disk since; restored with its unsaved text and marked"
  let mut deferred := pending.deferred
  let mut places := pending.places
  let mut keys := pending.keys
  let mut reopened : Array (Option BufferId) := #[]
  for entry in pending.reopen do
    let reply := ((loads.find? (·.1 == entry.path)).map (·.2)).getD (.error .notFound)
    match reply with
    | .ok loaded =>
      let id ← Files.adopt entry.path loaded
      reopened := reopened.push id
      if let some id := id then
        discard <| id.markRestored
        keys := keys.push (entry.key, id.index)
        deferred := deferred ++ (← setModes id entry.major entry.minors entry.language)
        if !entry.places.isEmpty then
          let some buffer := (← editorState).buffer? id | continue
          places :=
            places.push
              { buffer := id.index, revision := ← (buffer.text.revision : TextM Nat),
                places := entry.places, run := entry.run }
    | .error .notFound =>
      reopened := reopened.push none
      report := report.push s!"{entry.path}: gone from disk: it is not restored"
    | .error error =>
      reopened := reopened.push none
      report :=
        report.push s!"{entry.path}: cannot be loaded ({error.describe}): it is not restored"
  -- The focused view's buffer, in the window focused now.
  let focus : Option (BufferId × Place) :=
    match pending.focusBuffer, pending.focusReopen with
    | some (index, place), _ => some (⟨index⟩, place)
    | none, some (index, place) => (reopened[index]?.join).map (·, place)
    | none, none => none
  if let some (buffer, place) := focus then
    let view := (← editorState).frame.focused
    if let .ok ()← view.show buffer then
      placeIn view buffer place
  -- The frame, every window of every tab: each view's buffer and place are
  -- its buffer's in the index, among the index's own places only, since a
  -- place kept from an earlier run is under that run's view ids
  -- (`Place.run`).
  let own (places : Array Place) : Array Place := places.filter (·.run.isNone)
  let placed : Array (Nat × BufferId × Place) :=
    pending.places.flatMap
        (fun entry => (own entry.places).map fun place => (place.view, ⟨entry.buffer⟩, place)) ++
      ((pending.reopen.zip reopened).flatMap fun (entry, id) =>
        match id with
        | some id => (own entry.places).map fun place => (place.view, id, place)
        | none => #[]) ++
      (focus.map fun (buffer, place) => #[(place.view, buffer, place)]).getD #[]
  let mut frameRestored := false
  if let some record := pending.frame then
    match ← restoreFrameOf record placed keys with
    | .ok lines =>
      report := report ++ lines
      frameRestored := true
    | .error why =>
      report :=
        report.push s!"the windows are not restored ({why}): the focused buffer is shown as before"
  -- The places a restore read are put back with the frame; without it they
  -- are kept, as phase 1 kept them, for the next index.
  if frameRestored then
    places := #[]
  -- The declared stores' cells, for the host that holds them.
  let (cells, lines) ← storesOf pending.stores
  report := report ++ lines
  if !cells.isEmpty then
    restoreCells cells
  -- The reported jobs that were running: the restart stopped them.
  report := report ++ pending.jobs.map stoppedLine
  let buffers := pending.unsaved + (reopened.filter (·.isSome)).size
  let mut summary := s!"restore: {buffers} buffers, {pending.unsaved} with unsaved text"
  if changed > 0 then
    summary := summary ++ s!"; {changed} changed on disk"
  if !pending.jobs.isEmpty then
    summary := summary ++ s!"; {pending.jobs.size} jobs stopped"
  let problems := report.size > changed
  if problems then
    summary := summary ++ s!"; see {reportName}"
  if buffers > 0 || !report.isEmpty then
    writeReport (#[summary] ++ report)
    message summary
  let generation ← generationNow
  setKept
      { (← editorState).restore with
        run := some pending.run, stale := pending.stale, staleIndexes := pending.staleIndexes
        places, deferred, pending := none, restored := true
        heldLayout := if frameRestored then some generation else none }

/-- The job `restore-files` ("Restoring", in the module docs): each restored
buffer's file stated, and each file to reopen loaded. -/
def filesWork (arguments : List Argument) : Work := fun _ => do
  let .str _ :: .nat count :: rest :=
    arguments | throw s!"{filesJob}: its arguments are not a restore's"
  let mut stats := #[]
  let mut remaining := rest
  for _ in [0:count] do
    let .nat index :: .str path :: more :=
      remaining | throw s!"{filesJob}: its arguments are not a restore's"
    stats := stats.push (index, ← File.stat path)
    remaining := more
  let mut loads := #[]
  for argument in remaining do
    let .str path := argument | continue
    loads := loads.push (System.FilePath.mk path, ← File.load path Files.limit)
  return restored stats loads

/-- What a save of this run's index came to: the snapshot released, a
refusal said, and the index marked written. -/
def savedIndex (snapshot : Nat) (reply : Except FileError Unit) : EditorM Unit := do
  (SnapshotId.release ⟨snapshot⟩ : TextM Unit)
  match reply with
  | .error error =>
    message s!"restore: the session index is not saved: {error.describe}"
  | .ok () =>
    setKept { (← editorState).restore with indexWritten := true }

/-- The job `restore-save`: the session directory made and the snapshot
saved over this run's index, whatever is there. -/
def saveWork (arguments : List Argument) : Work := fun _ => do
  let .nat snapshot :: .str directory :: .str path :: _ :=
    arguments | throw s!"{saveJob}: its arguments are not a save's"
  match ← File.makeDirectory directory with
  | .error error =>
    return savedIndex snapshot (.error error)
  | .ok () =>
    let reply ← File.save (.snapshot ⟨snapshot⟩) path .whatever
    return savedIndex snapshot (reply.map fun _ => ())

/-- The command of the index's write ("Writing the index", in the module
docs): the index rendered, recorded as written, and its save started. -/
def writeNow (state : String) : EditorM Unit := do
  let editor ← editorState
  let kept := editor.restore
  let some run := kept.run | return
  if kept.ended then
    return
  let document ← (Document.of editor run : TextM Document)
  let rendered := document.render
  setKept
      { kept with
        written := some rendered, writing := false }
  let text ← createText rendered
  let snapshot ← (text.snapshot : TextM SnapshotId)
  ((TextSource.text text).release : TextM Unit)
  let directory := System.FilePath.mk state
  let arguments :=
    [.nat snapshot.index, .str (sessionDirectory directory).toString,
      .str (indexPath directory run).toString]
  if let .error refusal← startJob saveJob arguments (key := some saveJob) then
    (snapshot.release : TextM Unit)
    message s!"restore: the session index is not saved: {refusal.describe}"

/-- The job `restore-write`: waits `writeDelay`, then the write
(`writeNow`). -/
def writeWork (arguments : List Argument) : Work := fun _ => do
  let .str state :: _ := arguments | throw s!"{writeJob}: its arguments are not a write's"
  sleep writeDelay
  return writeNow state

/-- `restore-modes`: sets the major mode a restore deferred, its first
argument the buffer's index and its second the mode's name. -/
def modesCommand (call : Call) : EditorM Unit := do
  let .nat index :: .str mode :: _ := call.arguments | return
  discard <| (BufferId.mk index).setMajorMode mode

end Editor.Restore
