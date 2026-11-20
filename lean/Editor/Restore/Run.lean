import Editor.Api
import Editor.Files
import Editor.Job
import Editor.Marks
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
  (`nextRun`), and reads each log. Per buffer of a run, the live journal is
  the highest generation whose log has a header; with none, the highest
  with a base, restored as a buffer with no file. Each live journal is
  restored at once: its base taken in (`JobSnapshotId.toText`), its log
  replayed (`Journal.replay`), as a new buffer with the header's name (or
  a free one, `EditorState.freeName`) whose history is a new tree marked
  saved nowhere, so it is modified; it holds the header's file at the
  header's stamp and line ending (`attachFile`), so a save expects the old
  stamp. A no-file text called `scratch` goes into the scratch buffer when
  that is untouched. Its modes are set by name, language before major, as
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
  top, clamped to the text. The other windows' places are kept
  (`Kept.places`) for phase 2's layouts, and written again in the index
  while their buffer's text does not move. It gives the run its number,
  which starts the journal (`Kept.run`), and the files it took in to
  remove (`Kept.stale`, `Kept.staleIndexes`).
- **What is said**: a line in the echo area, `restore: N buffers, M with
  unsaved text`, then `; K changed on disk` when there are, and `; see
  *restore*` when the report has more; the whole report in the read-only
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
  let mut pending : Kept.Pending :=
    { run, staleIndexes := choice.remove.map (indexPath loaded.directory) }
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
    -- Modified: a new tree, saved nowhere.
    let some buffer := (← editorState).buffer? id | continue
    let history ← (UndoTree.over buffer.text : TextM UndoTree)
    discard <| EditorState.ask (.setHistory id { history with saved := none })
    if let (some path, some first) := (path, header) then
      if let some stamp := first.stamp then
        discard <| id.attachFile path stamp first.lineEnding
        statArguments := statArguments ++ [.nat id.index, .str path]
    if let some entry := entry then
      pending :=
        { pending with
          deferred := pending.deferred ++ (← setModes id entry.major entry.minors entry.language) }
      let revision ← (buffer.text.revision : TextM Nat)
      let others := entry.views.filter fun place => some place.view != focused
      if !others.isEmpty then
        pending :=
          { pending with
            places := pending.places.push { buffer := id.index, revision, places := others } }
      if let some place := entry.views.find? (some ·.view == focused) then
        pending := { pending with focusBuffer := some (id.index, place) }
      restoredKeys := restoredKeys.push entry.key
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
    if let some place := entry.views.find? (some ·.view == focused) then
      pending := { pending with focusReopen := some (pending.reopen.size, place) }
    pending :=
      { pending with
        reopen :=
          pending.reopen.push
            { path := file.path, major := entry.major, minors := entry.minors
              language := entry.language
              places := entry.views.filter fun place => some place.view != focused } }
    loads := loads ++ [.str file.path]
  pending := { pending with report := report }
  setKept { (← editorState).restore with pending := some pending }
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
text: its selection's anchor and head, and its scroll's top row. -/
def placeIn (view : ViewId) (buffer : BufferId) (place : Place) : EditorM Unit := do
  let some shown := (← editorState).buffer? buffer | return
  let anchor ← (Marks.offsetAt shown.text place.anchor.row place.anchor.column : TextM Nat)
  let head ← (Marks.offsetAt shown.text place.head.row place.head.column : TextM Nat)
  if let .ok selection← view.selection then
    discard <|
        view.select
          { selection with
            ranges := #[⟨anchor, head⟩], primary := 0 }
  let top ← (Marks.offsetAt shown.text place.top 0 : TextM Nat)
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
  let mut reopened : Array (Option BufferId) := #[]
  for entry in pending.reopen do
    let reply := ((loads.find? (·.1 == entry.path)).map (·.2)).getD (.error .notFound)
    match reply with
    | .ok loaded =>
      let id ← Files.adopt entry.path loaded
      reopened := reopened.push id
      if let some id := id then
        deferred := deferred ++ (← setModes id entry.major entry.minors entry.language)
        if !entry.places.isEmpty then
          let some buffer := (← editorState).buffer? id | continue
          places :=
            places.push
              { buffer := id.index, revision := ← (buffer.text.revision : TextM Nat),
                places := entry.places }
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
  let buffers := pending.unsaved + (reopened.filter (·.isSome)).size
  let mut summary := s!"restore: {buffers} buffers, {pending.unsaved} with unsaved text"
  if changed > 0 then
    summary := summary ++ s!"; {changed} changed on disk"
  let problems := report.size > changed
  if problems then
    summary := summary ++ s!"; see {reportName}"
  if buffers > 0 || !report.isEmpty then
    writeReport (#[summary] ++ report)
    message summary
  setKept
      { (← editorState).restore with
        run := some pending.run, stale := pending.stale, staleIndexes := pending.staleIndexes
        places, deferred, pending := none, restored := true }

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
