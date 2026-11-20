import Editor.Command.Dispatch
import Editor.Restore.Document
import Editor.Restore.Indexed

/-!
# Session restore: the journal and the index, kept in step

A run keeps its session under the state directory
(`EditorState.stateDirectory`), in `<state>/session/`: its index,
`session-<run>.json` (`Editor/Restore/Document.lean`), and a journal for
each buffer with unsaved text, `journals/<run>-<buffer>-<generation>.base`
and `.log` (`Editor/Restore/Journal.lean`). After a run that did not end
cleanly, the next start restores them (`Editor/Restore/Run.lean`). This
module is the core that keeps them in step with the editor, run by the loop
after each publish (`Loop.Stepped.published`, `Editor/Loop.lean`), and the
data it hands its host.

## The journal reconciler

`journalOrders` runs after each publish, beside the loop's other
reconcilers, and hands back its orders (`Restore.Order`), which the host
performs as unobserved file requests in order, through the file service, so
nothing waits on them (`Loop.Stepped.journal`). Its rules:

- **Only once restored.** It does nothing without a state directory, while
  the `restore` package's jobs are not registered (as the loop checks
  `follow-file`), and until the restore's command has run and given this run
  its number (`Kept.run`). The restore job makes `session/journals/` before
  it finishes, so every order is written into a directory that is there.
- **Which buffers are journalled** (`journalled`): a buffer with unsaved
  text, its history modified, that holds a file; or that holds none and is
  neither read-only nor an excerpt buffer (the scratch buffer typed in).
  Never the minibuffer's buffer, nor an owned or generated buffer.
- **A new generation**: a buffer journalled with no journal gets its base, a
  snapshot of its text saved whatever is there (the file service's atomic
  save), then its log's header appended.
- **One record per event**: a buffer whose text moved since its last record
  gets one record of every edit since (`TextId.changesSince`, the inserted
  text read by `slice`), appended with one write. A buffer that did not
  move costs no text request: its revision is read from its history, which
  the loop tells before each scene.
- **A new generation in place of a record**, and then the old one's two
  files removed, when the log has been forgotten past the record's
  revision, when the record would take the log past the bound (`bound`, 1
  MiB, or the base's size if larger), or when the buffer's file is no longer
  the one in the header (a save while still modified, or another path).
- **Removed**: the journal of a buffer no longer journalled (saved, undone
  to its saved state, or closed).
- **After a restore**, the journals it took in (`Kept.stale`) are removed
  after the new bases are asked for, in the same queue; the indexes it took
  in (`Kept.staleIndexes`) once this run's first index is written.
- **The end of the run.** When the loop stops because the editor leaves,
  the last orders remove this run's journals and save this run's index with
  `ended: true`, after the removes. No other run's file is touched.

## The index

`Document.of` is the index of the state now. When it differs from the last
one written and no write is pending, the reconciler starts `restore-write`
(`writeJob`), keyed, which waits `writeDelay` (500 ms on the job clock) and
then renders the index then and saves it over this run's file
(`Editor/Restore/Run.lean`). So a burst of changes is one write.

The index holds, for each buffer that holds a file and each buffer
journalled, its file, line ending, modes, live journal and the place of
each window on it (`Restore.Place`), with its jump list; and the places a
restore read that it did not put back, while the buffer's text has not
moved since (`Kept.places`), each with the run whose view ids it is under
(`Place.run`). Beside the buffers it holds the frame's tabs
and windows (`Frame.Record.of`, `Editor/Restore/Frame.lean`), and what the
reconciler mirrors: the workspace table's cells kept across a restart with
the parked ones (`Kept.table`, `Kept.parked`), the declared stores' cells
(`Kept.stores`) and the reported jobs running (`Kept.jobs`).

## Mirroring

The reconciler is handed a context (`Restore.Context`) built from what the
host told the loop (`Loop.Keys`): the registry, the config generation, the
log's bound, the host's declared cells (`StoresNow`) and the reported jobs
running. What the index keeps of stores costs nothing on a key that moves
none:

- **Only when a revision moved.** The host's cells' revision, the table's
  (`EditorState.workspacesRevision`) and the config generation are compared
  with the ones last mirrored (`Kept.mirrored`). Only when one moved are
  the host's cells forced (`StoresNow.cells`, a thunk) into `Kept.stores`
  and the table's cells recorded through their codecs into `Kept.table`
  (`Workspaces.record`). A store's value is rendered to JSON only by the
  debounced write.
- **Parked cells** (`Kept.parked`, table cells a restore read that no codec
  met) are met once config has installed past the generation they were
  parked at: each whose codec is registered now is met and put in its
  store by the rule a restore meets a cell with (`Workspaces.meetInto`,
  `Editor/Restore/Workspaces.lean`), and the rest are dropped. What that
  install lost is said once in the echo area: each value the codec
  refused and reset (`store <name>: <why>`), and the names dropped. Until
  then they are carried into every index written.
- **The jobs** are the reported jobs running, as the host last handed them,
  and how many other jobs run, a count only (`otherJobs`): those the
  registry does not report, the restore's own left out.
- **The held layout** (`Kept.heldLayout`), which a restore sets so that the
  host's default does not rearrange the layout it put back, is let go once
  the config generation is past it (`Loop.publish`, `Editor/Loop.lean`).

## Modes a restore deferred

A restore runs before config's `setup`, so a major mode only config
registers is not there to set. It is deferred (`Kept.deferred`): once a
config has installed, a mode now registered is set through the command
`restore-modes`, which the reconciler hands back to run, so its `onEnter`
runs; a mode still not registered is said, and not set.

Pinned by `ModelTest.journalReconcileChecks`, and the held layout by
`ModelTest.loopChecks`.
-/

namespace Editor.Restore

/-- The session directory under the state directory `state`. -/
def sessionDirectory (state : System.FilePath) : System.FilePath :=
  state / "session"

/-- The journals' directory under the state directory `state`. -/
def journalsDirectory (state : System.FilePath) : System.FilePath :=
  sessionDirectory state / "journals"

/-- The index file of the run `run` under the state directory `state`. -/
def indexPath (state : System.FilePath) (run : Nat) : System.FilePath :=
  sessionDirectory state / indexName run

/-- The base of a journal. -/
def basePath (state : System.FilePath) (run buffer generation : Nat) : System.FilePath :=
  journalsDirectory state / s!"{journalStem run buffer generation}.base"

/-- The log of a journal. -/
def logPath (state : System.FilePath) (run buffer generation : Nat) : System.FilePath :=
  journalsDirectory state / s!"{journalStem run buffer generation}.log"

/-- How long a log may grow before a new base is written, in bytes, unless
the base is larger: 1 MiB. -/
def bound : Nat :=
  1048576

/-- How long the index write waits for a burst of changes to end, in
milliseconds of the job clock. -/
def writeDelay : Nat :=
  500

/-- The name of the job that restores a session at start-up. -/
def restoreJob : String :=
  "restore"

/-- The name of the job of the restore's second half. -/
def filesJob : String :=
  "restore-files"

/-- The name of the job that writes the index once changes are quiet. -/
def writeJob : String :=
  "restore-write"

/-- The name of the job that saves a rendered index. -/
def saveJob : String :=
  "restore-save"

/-- The name of the command that sets the modes a restore deferred. -/
def modesName : String :=
  "restore-modes"

/-- How many of the jobs running, by their names `names`, the index counts
as other jobs (`Document.otherJobs`): those the registry does not report
(`reported`), the restore's own jobs left out, since they are the
session's own reading and writing, and the next start runs its own. What a
host hands the reconciler (`Loop.Keys.otherJobs`). -/
def otherJobs (reported : String → Bool) (names : Array String) : Nat :=
  (names.filter fun name =>
      !reported name && ![restoreJob, filesJob, writeJob, saveJob].contains name).size

/-- A journal order: a file request the host hands the file service with
nothing to wait for, and the snapshot to release once it is handed. -/
structure Order where
  /-- The request: an append, a remove, or a save of a snapshot whatever is
  there. -/
  request : FileRequest
  /-- The snapshot the request names, to release once it is handed. -/
  release : Option SnapshotId := none
  deriving DecidableEq, Repr

/-- The place of `window` of `state`, whose buffer's text is `text`: its
selection, its scroll's top row and its jump list (`jumpsOf`). -/
def placeOf (state : EditorState) (text : TextId) (window : Window) : TextM (Option Place) := do
  let .selection selection ← text.marker window.selection | return none
  let some range := selection.ranges[selection.primary]? | return none
  let .anchor scroll ← text.marker window.scroll | return none
  return some
      { view := window.id.index, anchor := ← spotOf text range.anchor,
        head := ← spotOf text range.head
        top := (← spotOf text scroll.offset).row, jumps := ← jumpsOf state window }

/-- The index of `state` now, for the run `run` ("The index", in the module
docs). The focused view is the selected one (`EditorState.selectedView`): a
prompt's asker while a prompt is open, so opening one changes nothing of
the index. -/
def Document.of (state : EditorState) (run : Nat) (ended : Bool := false) : TextM Document := do
  let kept := state.restore
  let mut buffers := #[]
  for index in [0:state.buffers.size] do
    let id : BufferId := ⟨index⟩
    let some buffer := state.buffer? id | continue
    unless indexed state id buffer do
      continue
    let mut views := #[]
    for window in state.windows do
      if window.buffer == id then
        if let .ok (some place)← observing (placeOf state buffer.text window) then
          views := views.push place
    -- The places a restore read and did not put back, as they were read:
    -- their views' ids are an earlier run's, which each names.
    for entry in kept.places do
      if entry.buffer == index && entry.revision == buffer.history.head then
        views :=
          views ++ entry.places.map fun place => { place with run := place.run <|> some entry.run }
    buffers :=
      buffers.push
        { key := index, name := buffer.name
          file := buffer.file.map fun file => { path := file.path.toString, stamp := file.stamp }
          lineEnding := buffer.lineEnding, major := buffer.major, minors := buffer.minors
          language := buffer.language
          journal :=
            (kept.journals.find? (·.buffer == index)).map fun journal =>
              { key := index, generation := journal.generation }
          views }
  return {
      run, ended, focused := some state.selectedView.index, buffers
      frame := some (← Frame.Record.of state)
      workspaces := kept.table.map (·.withParked kept.parked), stores := kept.stores
      jobs := kept.jobs, otherJobs := kept.otherJobs }

/-- What the host holds of the declared stores' cells for the index: a
revision it bumps whenever they change, and the cells kept across a
restart, codec applied, with the entries of config parked until it
installs, made only when forced (`Config.State.keptCells`). The reconciler
forces them only when the revision moved ("Mirroring", in the module
docs). -/
structure StoresNow where
  /-- The cells' revision. -/
  revision : Nat := 0
  /-- The cells kept across a restart, made when forced. -/
  cells : Thunk (Array KeptCell) := Thunk.pure #[]

/-- What the reconciler is handed beside the state, by the loop
(`Loop.Stepped.published`, `Editor/Loop.lean`), from what the host told it
(`Loop.Keys`). -/
structure Context where
  /-- What the loop was told of the registry: whether a mode of a name is
  registered, the codecs stores are kept across a restart with. -/
  registered : Loop.Registered := {}
  /-- How many configs have installed. -/
  configGeneration : Nat := 0
  /-- How long a log may grow before a new base is written. -/
  limit : Nat := bound
  /-- The host's declared stores' cells. -/
  stores : StoresNow := {}
  /-- The reported jobs running now. -/
  running : Array RunningJob := #[]
  /-- How many other jobs are running now (`otherJobs`). -/
  otherJobs : Nat := 0

/-- The table's kept cells and the parked ones mirrored into `kept` from
`state` and `context` ("Mirroring", in the module docs), when the revisions
moved since the last mirror: the host's cells forced, a parked cell met
into its store (`Workspaces.meetInto`) once an install registers its
codec, and dropped after an install that does not; a value the codec
refused, and the cells dropped, said once. The state, with each claimed
cell in its store, and the sentence to say, if any. -/
def mirrored (state : EditorState) (context : Context) : EditorState × Option String :=
  Id.run do
    let kept := state.restore
    let revisions := (context.stores.revision, state.workspacesRevision, context.configGeneration)
    if kept.mirrored == some revisions then
      return (state, none)
    let mut state := state
    let mut parked := kept.parked
    let mut said := none
    if !parked.isEmpty && context.configGeneration > kept.parkedAt then
      let mut table := state.workspaces
      let mut dropped := #[]
      let mut lines := #[]
      for (scope, cell) in parked do
        match context.registered.codec? cell.name with
        | some (_, codec) =>
          let (met, lost) := Workspaces.meetInto table scope cell codec
          table := met
          lines := lines ++ lost.toArray
        | none =>
          dropped := dropped.push cell.name
      parked := #[]
      if !dropped.isEmpty then
        lines :=
          lines.push
            s!"the session kept {", ".intercalate dropped.toList}, but no codec is registered for it now; dropped"
      if !lines.isEmpty then
        said := some s!"restore: {"; ".intercalate lines.toList}"
      state :=
        { state with
          workspaces := table, workspacesRevision := state.workspacesRevision + 1 }
    let record := Workspaces.record state.workspaces context.registered.codec?
    let restore :=
      { state.restore with
        stores := context.stores.cells.get, table := some record, parked
        mirrored :=
          some (context.stores.revision, state.workspacesRevision, context.configGeneration) }
    return ({ state with restore }, said)

/-- What the reconciler hands back: the state with what it keeps, the
journal's orders, the jobs to start and the invocations to run. -/
structure Reconciled where
  /-- The state, with `restore` in step. -/
  state : EditorState
  /-- The orders, in the order the file service is to work them. -/
  orders : Array Order := #[]
  /-- The jobs to start: the index write. -/
  starts : Array JobStart := #[]
  /-- The invocations to run: the modes a restore deferred, now registered. -/
  answered : Array Invocation := #[]
  /-- The keys of the jobs to cancel: at the end of the run, the index's
  write and save, so neither writes over the index the end saves. -/
  cancels : Array String := #[]

/-- The orders that remove the journal `journal` of the run `run`. -/
def removing (directory : System.FilePath) (run : Nat) (journal : Journal) : Array Order :=
  #[{ request := .remove (basePath directory run journal.buffer journal.generation) },
    { request := .remove (logPath directory run journal.buffer journal.generation) }]

/-- A new generation of the buffer `index`: the orders that save its base
and append its header, and its journal. -/
def generation (directory : System.FilePath) (run index number : Nat) (buffer : Buffer) :
    TextM (Array Order × Journal) := do
  let snapshot ← buffer.text.snapshot
  let size ← buffer.text.byteLength
  let revision ← buffer.text.revision
  let header : Journal.Header :=
    { name := buffer.name, path := buffer.file.map (·.path.toString)
      stamp := buffer.file.map (·.stamp), lineEnding := buffer.lineEnding, revision }
  let bytes := (Journal.Record.header header).bytes
  return (#[{
          request := .save (.snapshot snapshot) (basePath directory run index number) .whatever
          release := some snapshot },
        { request := .append (logPath directory run index number) bytes }],
      { buffer := index, generation := number, revision, logBytes := bytes.size, baseBytes := size
        path := buffer.file.map (·.path), stamp := buffer.file.map (·.stamp) })

/-- The reconciler ("The journal reconciler", in the module docs) of
`state`: `enabled` when the `restore` package's jobs are registered, and
`leaving` when the loop stops because the editor leaves; the rest it is
handed is `context`'s. -/
def journalOrders (state : EditorState) (enabled leaving : Bool) (context : Context := {}) :
    TextM Reconciled := do
  let registered (name : String) : Bool := (context.registered.entering name).isSome
  let configGeneration := context.configGeneration
  let limit := context.limit
  let some directory := state.stateDirectory | return { state }
  let some _ := state.restore.run | return { state }
  unless enabled && !state.restore.ended do
    return { state }
  -- What the index keeps beside the buffers, mirrored only when it moved.
  let (state, unclaimed) := mirrored state context
  let state :=
    { state with
      restore :=
        { state.restore with
          jobs := context.running, otherJobs := context.otherJobs
          heldLayout := state.restore.heldLayout.filter (configGeneration ≤ ·) } }
  let kept := state.restore
  let some run := kept.run | return { state }
  if leaving then
    let orders := kept.journals.flatMap (removing directory run)
    let document ← Document.of state run (ended := true)
    let text ← createText document.render
    let snapshot ← text.snapshot
    (TextSource.text text).release
    let save : Order :=
      { request := .save (.snapshot snapshot) (indexPath directory run) .whatever
        release := some snapshot }
    return {
        state :=
          { state with
            restore :=
              { kept with
                journals := #[], ended := true } }
        orders := orders.push save, cancels := #[writeJob, saveJob] }
  let mut orders := #[]
  let mut journals := #[]
  let mut next := kept.nextGeneration
  for index in [0:state.buffers.size] do
    let id : BufferId := ⟨index⟩
    let live := kept.journals.find? (·.buffer == index)
    let some buffer := state.buffer? id |
      if let some journal := live then
        orders := orders ++ removing directory run journal
      continue
    let wanted := journalled state id buffer
    match live, wanted with
    | none, false =>
      pure ()
    | some journal, false =>
      orders := orders ++ removing directory run journal
    | none, true =>
      let (made, journal) ← generation directory run index next buffer
      next := next + 1
      orders := orders ++ made
      journals := journals.push journal
    | some journal, true =>
      let sameFile :=
        journal.path == buffer.file.map (·.path) && journal.stamp == buffer.file.map (·.stamp)
      if sameFile && buffer.history.head == journal.revision then
        journals := journals.push journal
        continue
      let record : Option (Nat × ByteArray) ←
        if !sameFile then
          pure none
        else
          match ← observing (buffer.text.changesSince journal.revision) with
          | .error _ =>
            pure none
          | .ok patch =>
            let edits ← Journal.editsOf patch buffer.text.slice
            let bytes := (Journal.Record.edits edits).bytes
            if journal.logBytes + bytes.size > max limit journal.baseBytes then
              pure none
            else
              pure (some (patch.revision, bytes))
      match record with
      | some (revision, bytes) =>
        orders :=
          orders.push { request := .append (logPath directory run index journal.generation) bytes }
        journals :=
          journals.push
            { journal with
              revision, logBytes := journal.logBytes + bytes.size }
      | none =>
        let (made, fresh) ← generation directory run index next buffer
        next := next + 1
        orders := orders ++ made ++ removing directory run journal
        journals := journals.push fresh
  -- A journal of a buffer past the last slot is of a buffer closed.
  for journal in kept.journals do
    if journal.buffer ≥ state.buffers.size then
      orders := orders ++ removing directory run journal
  -- What a restore took in goes once the new bases are asked for.
  orders := orders ++ kept.stale.map fun path => { request := .remove path }
  let mut staleIndexes := kept.staleIndexes
  if kept.indexWritten then
    orders := orders ++ staleIndexes.map fun path => { request := .remove path }
    staleIndexes := #[]
  -- The modes a restore deferred, once a config has installed.
  let mut answered := #[]
  let mut deferred := #[]
  let mut said := none
  for entry in kept.deferred do
    let entry := { entry with generation := entry.generation.getD configGeneration }
    if entry.generation.any (configGeneration > ·) then
      if registered entry.mode then
        answered :=
          answered.push { command := modesName, arguments := [.nat entry.buffer, .str entry.mode] }
      else
        let name := ((state.buffer? ⟨entry.buffer⟩).map (·.name)).getD s!"buffer {entry.buffer}"
        said :=
          some s!"restore: no mode is registered as {entry.mode}: {name} is restored without it"
    else
      deferred := deferred.push entry
  let kept :=
    { kept with
      journals, nextGeneration := next, stale := #[], staleIndexes, deferred
      places :=
        kept.places.filter fun entry =>
          (state.buffer? ⟨entry.buffer⟩).any (·.history.head == entry.revision) }
  let state :=
    { state with
      restore := kept, echo := (said <|> unclaimed).getD state.echo }
  -- The index, once it differs from the last written and no write is
  -- pending: while one is, the index is not even made, since the write
  -- renders the index as it is when it fires.
  if kept.writing then
    return { state, orders, answered }
  let document ← Document.of state run
  if some document.render == kept.written then
    return { state, orders, answered }
  return {
      state := { state with restore := { kept with writing := true } }, orders, answered
      starts :=
        #[{ name := writeJob, arguments := [.str directory.toString], key := some writeJob }] }

end Editor.Restore
