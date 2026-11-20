import Editor.File

/-!
# What the session's reconciler keeps

The plain data of session restore that the editor state holds
(`EditorState.restore`, `Editor/State.lean`), here in a leaf module so that
the state can name it and the logic that keeps it (`Editor/Restore.lean`),
which imports the state, can too: the state imports nothing that imports it.
The rules are in `Editor/Restore.lean`; the formats on disk in
`Editor/Restore/Journal.lean` and `Editor/Restore/Document.lean`.

## Where an addition goes

| Addition | Where |
|---|---|
| Another fact the reconciler keeps between two publishes | A field of `Restore.Kept`, written by `Restore.journalOrders` or by a command of the `restore` package through `StateRequest.setRestore` |
| Another fact kept of one buffer's live journal | A field of `Restore.Journal` |
| Another fact of a window's place in a buffer | A field of `Restore.Place`, with its JSON in `Restore.Document` |

Pinned by `ModelTest.journalReconcileChecks` and `ModelTest.restoreChecks`.
-/

namespace Editor.Restore

/-- A position as the session index records it: a row, from 0, and a column
in bytes of that row's content. -/
structure Spot where
  /-- The row, from 0. -/
  row : Nat
  /-- The column, in bytes from the start of the row. -/
  column : Nat
  deriving DecidableEq, Repr, Inhabited

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
  deriving DecidableEq, Repr

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
  deriving DecidableEq, Repr

end Editor.Restore
