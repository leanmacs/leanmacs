import Editor.Api
import Editor.Compile.Listing
import Editor.Workspace.Finder

/-!
# Modes on markers: a buffer's minor modes from its markers

How a buffer whose file opens comes to have the minor modes the registered
compile contributions' markers turn on (`Editor/Workspace.lean`, "Modes on
markers"; `Editor/Compile/Contribution.lean`). Written over the editor API
and the marker search (`Workspace.presentMarkers`,
`Editor/Workspace/Finder.lean`). A command may not wait and a job may, so it
is, as finding a workspace is (`Editor/Workspace/Attach.lean`), a call that
starts a job, the job, which stamps the markers, and the job's command,
which gives the buffer its modes.

`Editor/Workspace/Attach.lean` imports this module: its attach and its find
job's command call `markModes`. So this module imports neither
`Editor.Files` nor `Editor.Compile`.

- **When.** Once, when a buffer's file opens and its workspace is known:
  from attach's cached answer at once, or from the find job's command once
  the finder has answered. The bound is the workspace's root, or the file's
  directory when it has no workspace.
- **Only with a contribution.** The marker modes are what the loop says of
  the registered contributions (`Workspace.Settings.markerModes`); with
  none, no job starts, so a host that registers none sees nothing new.
- **The job** (`find-mode-markers`, `markerJob`) is started with a marker
  order (`MarkerOrder`): the buffer, the file's directory, the bound and
  every contribution's marker, once each (`Workspace.markersOf`). A start
  that is refused is silent, as the find job's is: a host that registers no
  such job turns no mode on.
- **Its command** (`modesFound`) asks the loop for the marker modes now
  registered, and, while the buffer still holds a file in the order's
  directory, keeps the on-modes (`Workspace.onModes`) as the buffer-local
  value `marker-modes` (`Workspace.modesLocal`), nearest first, and adds
  each as a minor mode, the farthest first, so the buffer's minor modes
  list the nearest first and its keymap wins. Then it checks the on-modes'
  listings in the buffer's place (`Compile.refreshListings`,
  `Editor/Compile/Listing.lean`, which this module imports for it), so a
  mode that computes its commands lists them as it turns on. A buffer
  whose markers turn no mode on is left as it was. A reload's
  contributions apply to files opened after it.
- **Reading them back** (`onModesOf`): the on-modes a buffer keeps, none
  when it keeps none.

Pinned by `ModelTest.compileHookChecks`, on the loop's driver over the
editor's models and the job model.
-/

namespace Editor.Workspace

/-- The name the job that finds a buffer's mode markers is registered
under. -/
def markerJob : String :=
  "find-mode-markers"

/-- What the marker job is started with: the buffer, the directory of its
file, the bound the search stops at, and the markers looked for. -/
structure MarkerOrder where
  /-- The buffer whose file opened. -/
  buffer : BufferId
  /-- The directory of its file. -/
  directory : System.FilePath
  /-- Where the search stops: the workspace's root, or the directory. -/
  bound : System.FilePath
  /-- The markers looked for, each once. -/
  markers : Array String
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with: the buffer's number,
the directory and the bound, then each marker. -/
def MarkerOrder.arguments (order : MarkerOrder) : List Argument :=
  [.nat order.buffer.index, .str order.directory.toString, .str order.bound.toString] ++
    order.markers.toList.map .str

/-- The order `arguments` are, if they are one (`MarkerOrder.arguments`). -/
def MarkerOrder.ofArguments? : List Argument → Option MarkerOrder
  | .nat buffer :: .str directory :: .str bound :: markers => do
    let markers ←
      markers.mapM fun
          | .str marker => some marker
          | _ => none
    return { buffer := ⟨buffer⟩, directory, bound, markers := markers.toArray }
  | _ => none

/-- Starts the marker job for the buffer `id`, whose file is in
`directory`, searching up to `bound`, when `modes` holds any mode; a start
that is refused is silent. -/
def markModes (id : BufferId) (directory bound : System.FilePath) (modes : Array MarkerMode) :
    EditorM Unit := do
  if modes.isEmpty then
    return
  -- Refused only when no marker job is registered: then no buffer has an
  -- on-mode, and nothing is said.
  discard <|
      startJob markerJob
        (MarkerOrder.arguments { buffer := id, directory, bound, markers := markersOf modes })

/-- The command a finished marker job hands the loop (in the module docs):
while the buffer still holds a file in the order's directory, it keeps the
modes the markers `present` turn on and has each as a minor mode. -/
def modesFound (order : MarkerOrder) (present : Array (System.FilePath × String)) : EditorM Unit :=
  do
  let (settings, _) ← EditorState.ask .workspaceSettings
  let some buffer := (← editorState).buffer? order.buffer | return
  let some file := buffer.file | return
  if (file.path.parent.map Process.trimmed) != some order.directory then
    return
  let on := onModes settings.markerModes order.directory order.bound present
  if on.isEmpty then
    return
  discard <| order.buffer.setValue modesLocal (.list (on.toList.map OnMode.encode))
  for mode in on.reverse do
    discard <| order.buffer.addMinorMode mode.mode
  if let some place := Compile.placeOfBuffer (← editorState) order.buffer then
    Compile.refreshListings place on

/-- The marker job: stamps its order's markers (`presentMarkers`), and
finishes with what they become (`modesFound`). It fails only for arguments
that are not an order. -/
def markerWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    MarkerOrder.ofArguments? arguments | throw s!"{markerJob}: its arguments are not a marker order"
  return modesFound order (← presentMarkers order.markers order.directory order.bound)

/-- The on-modes the buffer `id` keeps in `state`, nearest first; none when
it keeps none. -/
def onModesOf (state : EditorState) (id : BufferId) : Array OnMode :=
  match state.value? id modesLocal with
  | some (.list items) => items.toArray.filterMap OnMode.decode?
  | _ => #[]

end Editor.Workspace
