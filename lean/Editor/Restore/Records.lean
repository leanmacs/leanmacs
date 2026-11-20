import Editor.Floating
import Editor.Layout
import Editor.Store.Codec
import Editor.Workspace

/-!
# The session index's records, as plain data

The plain record types of the session index (`Editor/Restore/Document.lean`)
and of what the session's reconciler keeps (`Restore.Kept`,
`Editor/Restore/Kept.lean`): a spot, a window's jump list, the frame's tabs
and windows, the workspace table's records and a job running.

It is a leaf module: it imports only modules the editor state imports
too (`Editor/State.lean`), none of which imports a `Restore` module, so
`Kept`, which the state holds, can name these types, and the modules that
read the state and write the JSON (`Editor/Restore/Frame.lean`,
`Editor/Restore/Workspaces.lean`, `Editor/Restore/Document.lean`) import
them. It holds no logic: every function that reads the state or writes
JSON is in those modules.

## Where an addition goes

| Addition | Where |
|---|---|
| A new plain type that `Kept`, `Kept.Pending` or `Restore.Place` names | Here, never in a module that imports the state |
| Its JSON | The module that writes the part of the index it is in |

Its types are pinned through the checks of the modules that write them:
`ModelTest.restoreFrameChecks`, `ModelTest.restoreWorkspaceChecks` and
`ModelTest.restoreDocumentChecks`.
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

/-- An entry of a window's jump list, or its previous-context mark, as the
index records it: a place in characters, as `Jumps.detach` writes one
(`Editor/Jumps.lean`). -/
inductive Jump where
  /-- In the buffer kept under `key` in the index, at `row` and `column`,
  the column in characters. -/
  | kept (key row column : Nat)
  /-- In the file at `path`, at `row` and `column`, the column in
  characters. -/
  | file (path : String) (row column : Nat)
  deriving DecidableEq, Repr

/-- A window's jump list and previous-context mark as the index records
them. -/
structure Jumps.Record where
  /-- The list's entries, oldest first. -/
  entries : Array Jump := #[]
  /-- The list's index: an index of `entries`, or one past the end. -/
  index : Nat := 0
  /-- The previous-context mark, if there is one. -/
  previous : Option Jump := none
  deriving DecidableEq, Repr

/-- What a float is anchored to, as the index records it. -/
inductive Float.Anchor where
  /-- The frame. -/
  | frame
  /-- The window of the view `view`. -/
  | window (view : Nat)
  /-- A position of the window of the view `view`'s buffer. -/
  | position (view : Nat) (spot : Spot)
  deriving DecidableEq, Repr

/-- A floating window as the index records it. -/
structure Float.Record where
  /-- Its view's id. -/
  view : Nat
  /-- What it is anchored to. -/
  anchor : Float.Anchor
  /-- Its share of the area it is placed in. -/
  share : Floating.Share := {}
  /-- Whether it is pinned. -/
  pinned : Bool := false
  deriving DecidableEq, Repr

/-- One tab of the frame as the index records it: its windows by their
views' ids. -/
structure Tab.Record where
  /-- Its name, when it was given one. -/
  name : Option String := none
  /-- Its tiled windows, in order. -/
  windows : Array Nat
  /-- Its docked windows, each with its side. -/
  docked : Array (Nat × Side) := #[]
  /-- Its floats, in stacking order. -/
  floats : Array Float.Record := #[]
  /-- Its layout. -/
  layout : Layout := Layout.default
  /-- The layout a zoom returns to, while zoomed. -/
  zoomedFrom : Option Layout := none
  /-- Its focused window. -/
  focused : Nat
  /-- The window it focused before, if it is still one of its own. -/
  lastFocused : Option Nat := none
  deriving DecidableEq, Repr

/-- The frame as the index records it. -/
structure Frame.Record where
  /-- The index of the tab in view. -/
  selected : Nat := 0
  /-- The layout config had chosen (`Frame.chosen`), when it had. -/
  chosen : Option Layout := none
  /-- The tabs, in order. -/
  tabs : Array Tab.Record := #[]
  /-- The windows whose buffer the index does not keep, each with its
  buffer's name: a restore shows `scratch` in each. -/
  elsewhere : Array (Nat × String) := #[]
  deriving DecidableEq, Repr

/-- Where a store of the workspace table is (`Workspace.Table`). -/
inductive Document.Scope where
  /-- The store of the workspace at `location`. -/
  | workspace (location : Location)
  /-- The store of the project of `identity`. -/
  | project (identity : Project.Identity)
  /-- The store of the buffers outside any workspace. -/
  | unscoped
  deriving DecidableEq, Repr

/-- A workspace of the table as the index records it. -/
structure Workspace.Record where
  /-- Its location: its key. -/
  location : Location
  /-- What is checked out there. -/
  branch : Option Workspace.Branch := none
  /-- Its project's identity. -/
  project : Project.Identity
  /-- Its cells kept across a restart. -/
  cells : Array KeptCell := #[]
  deriving BEq, Repr

/-- A project of the table as the index records it. -/
structure Project.Record where
  /-- Its identity: its key. -/
  identity : Project.Identity
  /-- Its name. -/
  name : String
  /-- The URL of its `origin` remote, if it has one. -/
  remote : Option String := none
  /-- Its common git directory, if it is a repository. -/
  commonDir : Option System.FilePath := none
  /-- Its cells kept across a restart. -/
  cells : Array KeptCell := #[]
  deriving BEq, Repr

/-- The workspace table as the index records it: no directory cache, which
is asked again. -/
structure Document.Workspaces where
  /-- The workspaces, in the table's order. -/
  workspaces : Array Workspace.Record := #[]
  /-- The projects, in the table's order. -/
  projects : Array Project.Record := #[]
  /-- The unscoped store's cells kept across a restart. -/
  unscoped : Array KeptCell := #[]
  deriving BEq, Repr

/-- A job running, as the index records it: one a person waits on
(`workJob … (reported := true)`), which a restart stops. -/
structure RunningJob where
  /-- Its owner's name. -/
  owner : String
  /-- Its name. -/
  name : String
  /-- Its key, if it was started under one. -/
  key : Option String := none
  deriving DecidableEq, Repr

end Editor.Restore
