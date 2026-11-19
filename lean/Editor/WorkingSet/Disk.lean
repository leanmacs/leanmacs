import Editor.File
import Editor.Files
import Editor.Job
import Editor.VersionControl
import Editor.VersionControl.Git
import Editor.WorkingSet.Places

/-!
# Working sets on disk

Each workspace keeps its working sets in a file under the editor's state
directory (`EditorState.stateDirectory`):
`<state>/workspaces/<key>/working-sets.json` (`WorkingSet.storeFile`), as
JSON of the stored form (`Editor/WorkingSet.lean`). Only jobs touch it,
through the job port's file request.

## When it is read

Lazily, the first time a working-set command needs a workspace's sets in a
run (`ensureRead`, called by `working-set-add` and `working-set-open`):

- with no state directory, the sets live in memory only (`Disk.memoryOnly`),
  and the first add says so once;
- otherwise the job `working-set-load` is started, keyed by the root
  (`loadWork`): it loads the file (`File.load`), and its command
  (`readStore`) adopts the text, parses it and releases it. A missing file
  is an empty store, read. A file that cannot be loaded, does not parse, or
  whose version is above this editor's makes the workspace's sets
  unreadable for the run: they are not shown, the file is never written
  over, and `working sets of <label>: <path> cannot be read: <reason>; it is
  left as it is` is said. Read sets' ranges are detached, and those of
  files open in a buffer are found again at once (`WorkingSet.attach`).
  Then the command that asked runs again (`invoke`), so a start never
  waits on disk.

## When it is written

On every change to a set (an add, a remove, a note), when a buffer holding
one of the workspace's ranges is saved, and when such a buffer is closed,
through `WorkingSet.requestWrite` (`Editor/WorkingSet/Places.lean`), which
starts `working-set-write` keyed by the root, so a newer write cancels an
older one still asking:

- **the job** (`writeWork`) asks the version-control interface for the
  commit `HEAD` is at (`log "HEAD" 1`, through `connect`, git by default);
  no repository, or an unborn `HEAD`, is an empty commit;
- **its command** (`writeNow`) refreshes every held range's stored form from
  its text now and fills the commit in; detached ranges keep the form they
  were detached with, and drifted ones are written exactly as read. It
  renders the document, takes a snapshot of a text made of it, releases the
  text, and starts `working-set-save` (`saveWork`): the directory made with
  its parents (`File.makeDirectory`), then the snapshot saved over the file,
  whatever is there, by the file service's atomic temporary-and-rename save,
  so a reader never sees a torn file. Its command (`savedStore`) releases
  the snapshot and says a refusal, `working sets of <label> not saved:
  <reason>`. The save is not keyed: each releases its own snapshot, and the
  file service works saves in the order they were started, so the last one
  started is the one left on disk.

Nothing is written while the sets are not read, unreadable or in memory
only.

Pinned by `ModelTest.workingSetDiskChecks`, on the loop's driver over the
models: the second acceptance criterion of navigation-and-windows phase 5.
-/

namespace Editor.WorkingSet

/-- The name of the job that reads a workspace's working sets. -/
def loadJob : String :=
  "working-set-load"

/-- The name of the job that saves a workspace's working sets. -/
def saveJob : String :=
  "working-set-save"

/-- Makes sure the working sets of the workspace at `location` are read
("When it is read", in the module docs): `true` when they can be used now;
`false` when their load was started, and `continuation` runs once it is
done. -/
def ensureRead (location : Location) (continuation : Invocation) : EditorM Bool := do
  let state ← editorState
  let kept := keptAt state location
  unless kept.disk == .notRead do
    return true
  let some root := localRoot? location | return true
  match state.stateDirectory with
  | none =>
    setKept location { kept with disk := .memoryOnly }
    return true
  | some directory =>
    let arguments :=
      [.str root, .str (storeFile directory root).toString, .str continuation.command] ++
        continuation.arguments
    match ← startJob loadJob arguments (key := some s!"{loadJob} {root}") with
    | .ok () =>
      return false
    | .error _ =>
      -- A host with no load job keeps them in memory.
      setKept location { kept with disk := .memoryOnly }
      return true

/-- The label of the workspace at `location`, or its root when the table has
no workspace there. -/
def labelAt (state : EditorState) (location : Location) (root : String) : String :=
  ((state.workspaces.workspace? location).map (·.label)).getD root

/-- What a load of the store at `path` of the workspace whose root is
`root` comes to ("When it is read", in the module docs), and then the
command that asked, run again. -/
def readStore (root path : String) (reply : Except FileError File.Loaded)
    (continuation : Invocation) : EditorM Unit := do
  let location := Location.local (System.FilePath.mk root)
  let kept := keptAt (← editorState) location
  -- Another load may have been read first.
  if kept.disk == .notRead then
    let read : Except String (Array KeptSet) ←
      match reply with
      | .error .notFound =>
        pure (.ok #[])
      | .error error =>
        pure (.error error.describe)
      | .ok loaded =>
        let text ← loaded.snapshot.toText
        let content ← (text.read : TextM String)
        (text.release : TextM Unit)
        pure <|
            (Document.read content.toUTF8).map fun document =>
              document.sets.map fun set =>
                { name := set.name, ranges := set.ranges.map fun stored => { stored } }
    match read with
    | .ok sets =>
      setKept location
          { kept with
            disk := .read, sets := kept.sets ++ sets }
      for slot in (← editorState).buffers do
        let some buffer := slot | continue
        let some file := buffer.file | continue
        if (relativeIn root file.path).isSome then
          if let some id := (← editorState).findFile file.path then
            attach id file.path
    | .error reason =>
      setKept location { kept with disk := .unreadable reason }
      message (unreadableSentence (labelAt (← editorState) location root) path reason)
  invoke continuation

/-- The load job: loads the store its arguments name, and finishes with what
it comes to (`readStore`). It fails only for arguments that are not a load's. -/
def loadWork (arguments : List Argument) : Work := fun _ => do
  let .str root :: .str path :: .str command :: rest :=
    arguments | throw s!"{loadJob}: its arguments are not a load's"
  return readStore root path (← File.load path Files.limit) { command, arguments := rest }

/-- What a save of the store at `path` came to: the snapshot it saved
released, and a refusal said. -/
def savedStore (root : String) (snapshot : Nat) (reply : Except FileError Unit) : EditorM Unit := do
  (SnapshotId.release ⟨snapshot⟩ : TextM Unit)
  if let .error error := reply then
    let location := Location.local (System.FilePath.mk root)
    message (notSavedSentence (labelAt (← editorState) location root) error.describe)

/-- The save job: makes the store's directory and saves the snapshot over
its file, and finishes with what that came to (`savedStore`). -/
def saveWork (arguments : List Argument) : Work := fun _ => do
  let .str root :: .nat snapshot :: .str directory :: .str path :: _ :=
    arguments | throw s!"{saveJob}: its arguments are not a save's"
  match ← File.makeDirectory directory with
  | .error error =>
    return savedStore root snapshot (.error error)
  | .ok () =>
    let reply ← File.save (.snapshot ⟨snapshot⟩) path .whatever
    return savedStore root snapshot (reply.map fun _ => ())

/-- The command of a write ("When it is written", in the module docs): the
held ranges refreshed with the commit `commit`, the document rendered and
its save started. Nothing while the sets are not read. -/
def writeNow (root state commit : String) : EditorM Unit := do
  let location := Location.local (System.FilePath.mk root)
  let kept := keptAt (← editorState) location
  unless kept.disk == .read do
    return
  let mut sets := #[]
  for set in kept.sets do
    let mut ranges := #[]
    for range in set.ranges do
      if range.hold matches .held .. then
        let refreshedRange ← refreshed range
        ranges := ranges.push { refreshedRange with stored.commit := commit }
      else
        ranges := ranges.push range
    sets := sets.push { set with ranges }
  setKept location { kept with sets }
  let document : Document :=
    { root, sets := sets.map fun set => { name := set.name, ranges := set.ranges.map (·.stored) } }
  let text ← createText document.render
  let snapshot ← (text.snapshot : TextM SnapshotId)
  (text.release : TextM Unit)
  let directory := storeDirectory (System.FilePath.mk state) root
  let arguments :=
    [.str root, .nat snapshot.index, .str directory.toString,
      .str (storeFile (System.FilePath.mk state) root).toString]
  if let .error refusal← startJob saveJob arguments then
    (snapshot.release : TextM Unit)
    message (notSavedSentence (labelAt (← editorState) location root) refusal.describe)

/-- The write job: asks `connect`'s version-control interface, git by
default, for the commit `HEAD` is at, an empty one when there is none, and
finishes with the write (`writeNow`). -/
def writeWork
    (connect : String → System.FilePath → VersionControl.Handler := VersionControl.Git.handler)
    (arguments : List Argument) : Work := fun _ => do
  let .str root :: .str git :: .str state :: _ :=
    arguments | throw s!"{writeJob}: its arguments are not a write's"
  let commit :=
    match ← Program.runM (connect git (System.FilePath.mk root)) (VersionControl.log "HEAD" 1) with
    | .ok entries => (entries[0]?.map (·.id)).getD ""
    | .error _ => ""
  return writeNow root state commit

end Editor.WorkingSet
