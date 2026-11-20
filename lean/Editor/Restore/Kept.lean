import Editor.File
import Editor.Restore.Records

/-!
# What the session's reconciler keeps

The plain data of session restore that the editor state holds
(`EditorState.restore`, `Editor/State.lean`), here in a leaf module so that
the state can name it and the logic that keeps it (`Editor/Restore.lean`),
which imports the state, can too: the state imports nothing that imports it.
It is still a leaf with the records it names (`Editor/Restore/Records.lean`):
that module and what it imports are all upstream of the state.
The rules are in `Editor/Restore.lean`; the formats on disk in
`Editor/Restore/Journal.lean` and `Editor/Restore/Document.lean`.

## Where an addition goes

| Addition | Where |
|---|---|
| Another fact the reconciler keeps between two publishes | A field of `Restore.Kept`, written by `Restore.journalOrders` or by a command of the `restore` package through `StateRequest.setRestore` |
| Another fact kept of one buffer's live journal | A field of `Restore.Journal` |
| Another fact of a window's place in a buffer | A field of `Restore.Place`, with its JSON in `Restore.Document` |
| Another fact of the frame, its tabs or windows | A field of `Frame.Record` or `Tab.Record` (`Editor/Restore/Records.lean`), its JSON and its reading of the state in `Editor/Restore/Frame.lean`, and its putting back in `Restore.restored` |
| Another fact of the workspace table | A field of `Workspace.Record`, `Project.Record` or `Document.Workspaces` (`Editor/Restore/Records.lean`), with its JSON, record and restore in `Editor/Restore/Workspaces.lean` |
| Another fact of a store kept across a restart | A field of `KeptCell` (`Editor/Store/Codec.lean`), its JSON in `Editor/Restore/Workspaces.lean`; mirrored into `Kept.stores` or `Kept.table` by `Restore.journalOrders` |
| A new plain type `Kept`, `Kept.Pending` or `Restore.Place` names | `Editor/Restore/Records.lean`, never a module that imports the state |

The cells parked for a codec (`Kept.parked`) are written by the same two
writers: the restore's first half parks the table cells no codec met, with
`setRestore` (`Restore.read`), and the reconciler claims or drops them
after an install. The state request that restores the table
(`StateRequest.restoreWorkspaces`) takes plain data, the cells already met,
and writes no field here.

Pinned by `ModelTest.journalReconcileChecks` and `ModelTest.restoreChecks`.
-/

namespace Editor.Restore

/-- Where one window is in its buffer: its view's id, the anchor and the head
of its primary selection, and the row its scroll starts at. -/
structure Place where
  /-- The id of the window's view. -/
  view : Nat
  /-- The anchor of the primary selection. -/
  anchor : Spot
  /-- The head of the primary selection: the cursor. -/
  head : Spot
  /-- The first row the window shows. -/
  top : Nat
  /-- Its jump list and previous-context mark, when it has either. -/
  jumps : Option Jumps.Record := none
  /-- The run whose view ids `view` is one of, when it is not the run of
  the index that holds the place: a place a restore read and did not put
  back, written again (`Kept.places`). View ids are unique only within one
  run, so a restore matches only its index's own places, those with none,
  to the focused view and to the frame's views. -/
  run : Option Nat := none
  deriving DecidableEq, Repr, Inhabited

/-- The live journal of one buffer: what generation it is, and how far it
has written. -/
structure Journal where
  /-- The buffer's index (`BufferId.index`), its key on disk. -/
  buffer : Nat
  /-- Its generation: each new base of the buffer is the next. -/
  generation : Nat
  /-- The revision of the buffer's text its last record reached. -/
  revision : Nat
  /-- How many bytes its log holds. -/
  logBytes : Nat
  /-- How many bytes its base holds. -/
  baseBytes : Nat
  /-- The file the buffer held when its header was written: its path. -/
  path : Option System.FilePath := none
  /-- The stamp in its header: the stamp of the buffer's file then. -/
  stamp : Option File.Stamp := none
  deriving DecidableEq, Repr

/-- The places a restore read for one buffer that it did not put back, kept
for the next index written while the buffer's text has not moved. -/
structure Kept.Places where
  /-- The buffer's index. -/
  buffer : Nat
  /-- The revision of its text when they were read. -/
  revision : Nat
  /-- The places. -/
  places : Array Place
  /-- The run of the index they were read from: the run whose view ids
  they are, unless a place names an earlier one (`Place.run`). -/
  run : Nat := 0
  deriving DecidableEq, Repr

/-- A major mode a restore could not set because no mode of its name was
registered, to set once a config has installed (`Restore.journalOrders`). -/
structure Kept.Deferred where
  /-- The buffer's index. -/
  buffer : Nat
  /-- The mode's name. -/
  mode : String
  /-- The config generation when it was deferred: a later one decides it.
  `none` until the reconciler first sees it, which reads the generation
  then. -/
  generation : Option Nat := none
  deriving DecidableEq, Repr

/-- A buffer of the index restored that held a file with no unsaved text:
reopened from its file (`Restore.restored`). -/
structure Kept.Reopen where
  /-- Its key in the index. -/
  key : Nat := 0
  /-- Its file's path. -/
  path : System.FilePath
  /-- Its major mode's name. -/
  major : Option String := none
  /-- Its minor modes' names. -/
  minors : Array String := #[]
  /-- Its language's name. -/
  language : Option String := none
  /-- The places of its windows. -/
  places : Array Place := #[]
  /-- The run of the index it is of, whose view ids its places are. -/
  run : Nat := 0
  deriving DecidableEq, Repr

/-- What the first half of a restore read and the second is to finish
(`Editor/Restore/Run.lean`, "Restoring"): the run's number, the buffers to
reopen, where the focus goes, and what to say and remove. -/
structure Kept.Pending where
  /-- This run's number. -/
  run : Nat
  /-- The buffers to reopen from their files, in the index's order. -/
  reopen : Array Kept.Reopen := #[]
  /-- The buffer restored with its unsaved text that the focused view
  showed, and its place there. -/
  focusBuffer : Option (Nat × Place) := none
  /-- The buffer to reopen that the focused view showed (an index into
  `reopen`), and its place there. -/
  focusReopen : Option (Nat × Place) := none
  /-- How many buffers were restored with their unsaved text. -/
  unsaved : Nat := 0
  /-- What the report says so far, a line each. -/
  report : Array String := #[]
  /-- The journal files taken in. -/
  stale : Array System.FilePath := #[]
  /-- The indexes taken in, of a format this editor understands. -/
  staleIndexes : Array System.FilePath := #[]
  /-- The places kept of the buffers restored with their unsaved text. -/
  places : Array Kept.Places := #[]
  /-- The modes deferred so far. -/
  deferred : Array Kept.Deferred := #[]
  /-- The frame of the index restored, to put back. -/
  frame : Option Frame.Record := none
  /-- Each buffer kept of the index restored that is restored, by its key
  in that index, and its index in this run. -/
  keys : Array (Nat × Nat) := #[]
  /-- The reported jobs the index restored says were running. -/
  jobs : Array RunningJob := #[]
  /-- The declared stores' cells of the index restored, to hand the host. -/
  stores : Array KeptCell := #[]
  deriving BEq, Repr

/-- What the session's reconciler keeps between two publishes. -/
structure Kept where
  /-- This run's number, once the restore's command has run: until then no
  journal is written and no index. -/
  run : Option Nat := none
  /-- The generation the next new journal gets. -/
  nextGeneration : Nat := 1
  /-- The live journal of each journalled buffer. -/
  journals : Array Journal := #[]
  /-- The files of the journals a restore took in, to remove once the new
  bases are asked for. -/
  stale : Array System.FilePath := #[]
  /-- The indexes of earlier runs a restore took in, of a format this editor
  understands, to remove once this run's first index is written. -/
  staleIndexes : Array System.FilePath := #[]
  /-- Whether this run's index has been written once. -/
  indexWritten : Bool := false
  /-- The last index document a write rendered, as its text. -/
  written : Option String := none
  /-- Whether a write of the index is pending: started and not yet
  rendered. -/
  writing : Bool := false
  /-- Whether the run ended: the last orders were handed. -/
  ended : Bool := false
  /-- The places a restore read that it did not put back. -/
  places : Array Kept.Places := #[]
  /-- The major modes a restore deferred. -/
  deferred : Array Kept.Deferred := #[]
  /-- What the first half of a restore left the second, while it runs. -/
  pending : Option Kept.Pending := none
  /-- Whether the restore has finished, whatever it came to: a host holds
  its driver's requests until it has. -/
  restored : Bool := false
  /-- The config generation at the restore, while the layout it put back
  is held: a publish passes over the layout it is handed until config has
  installed past it (`Loop.publish`). -/
  heldLayout : Option Nat := none
  /-- The declared stores' cells kept across a restart, codec applied, and
  the entries of config parked until it installs: what the index lists
  under `stores`, mirrored from the host (`Loop.Keys.stores`). -/
  stores : Array KeptCell := #[]
  /-- The workspace table's cells kept across a restart, codec applied, and
  those parked: what the index lists under `workspaces`. -/
  table : Option Document.Workspaces := none
  /-- The table cells a restore read that no codec met yet, each with its
  scope, and the config generation they were parked at: met by the
  reconciler after the first install that registers a codec, and dropped
  after one that does not. -/
  parked : Array (Document.Scope × KeptCell) := #[]
  /-- The config generation the parked cells wait past. -/
  parkedAt : Nat := 0
  /-- The revisions last mirrored: the host's cells', the workspace
  table's and the registry's generation. -/
  mirrored : Option (Nat × Nat × Nat) := none
  /-- The reported jobs running, as the host last handed them. -/
  jobs : Array RunningJob := #[]
  deriving BEq, Repr

end Editor.Restore
