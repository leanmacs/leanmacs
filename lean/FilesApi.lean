import Editor.Extension
import Editor.File
import Editor.FileJobs

/-!
# The interface library `files-api`

The interface library `files-api`, staged in the core's Lake package as its
own `lean_lib` with the layout and names it will have as the package
`packages/files-api/` (`lean/lakefile.lean`, `lean_lib FilesApi`): the
contract between the files feature (`packages/files/Files.lean`), which implements
it, and what others ask of a file being taken in and written. It imports
only the core's API, and its test library (`FilesApiTest`) only that, this
library and the core's test kit. Session restore, which is core, will reach
files through it, so it stays a core interface when the files feature moves
out.

## Its extension points

- **`Opened`, a hook**: every value, in order, is run (`runOpened`) once a
  buffer holds a file it took in, after the core's `Jumps.attach` and
  before the buffer is shown. The workspace attaches the buffer to its
  workspace here, and the working sets place their ranges, in that order,
  the order the packages register in.
- **`Saved`, a hook**: run (`runSaved`) once a save has written its file,
  before the save's follow-up starts. The working sets write their sets
  here.
- **`Files`, a choice** under `implementationName`, `files`, read with
  `files?`: what files does for others, `adopt` (the buffer of a path
  whose load answered, shown in a view or nowhere), `visit` (a path at a
  point, in a view, recording a jump there when asked: every caller asks
  but the jump commands, `Editor/Jumps/Go.lean`) and `save` (a buffer, forced or not, with a follow-up
  job). A save writes its file in a job, and starts the follow-up only once
  the file is written; a refused save, its file changed on disk or its
  write failed, starts nothing, and the implementation says the refusal as
  any save's is, so a caller says nothing of it. The latest value of the
  name wins, so config's replaces the feature's. With none a caller says
  `noImplementation`. The contract holds every implementation to these
  (`FilesApiTest.contractChecks`).

## Its names and constants

The names others reach (`names`, `jobs`): `open-file`, the core's
(`FileJobs.openFileCommand`), `save-buffer`, `edit-file`, `reload-buffer`
and `auto-reload-mode`; the jobs `check-files` and `follow-file`, the
core's. The limits a caller reads a file under (`loadLimit`) and diffs it
under (`diffLineLimit`), and what files says of a load it refused
(`notOpened`).

Its test library publishes a fake (`FilesApiTest.fake`, the core's test
kit's opener with this interface's hooks as its runners) and the contract
check every implementation runs (`FilesApiTest.contractChecks`).
-/

namespace FilesApi

open Editor

/-- A point of a text a visit puts the cursor at. -/
structure At where
  /-- The row, from 0. -/
  row : Nat
  /-- The column, in characters (Unicode scalar values) from the row's
  start. -/
  column : Nat
  /-- Whether the cursor goes to the row's first non-blank in place of the
  column, as a mark's line does (`'`). -/
  firstNonBlank : Bool := false
  deriving DecidableEq, Repr

/-- What is run once a buffer holds a file it took in: a hook ("Its
extension points", in the module docs). -/
structure Opened where
  /-- The value's name. -/
  name : String
  /-- Run with the buffer and the file's path. -/
  opened : BufferId → System.FilePath → EditorM Unit
  deriving TypeName

/-- What is run once a save has written a buffer's file: a hook. -/
structure Saved where
  /-- The value's name. -/
  name : String
  /-- Run with the buffer. -/
  saved : BufferId → EditorM Unit
  deriving TypeName

/-- What files does for others: a choice, under `implementationName`. -/
structure Files where
  /-- The value's name. -/
  name : String
  /-- The buffer of the file at the path, whose load answered: the buffer
  that holds the path, or a new one, shown in the view when one is given and
  nowhere otherwise; `none` when a step is refused. -/
  adopt : System.FilePath → File.Loaded → Option ViewId → EditorM (Option BufferId)
  /-- Visits the path in the view at the point, focusing the view when the
  first flag says so, and recording a jump in the view (`Jumps.record`)
  when the second says so. The buffer is shown with the cursor at the
  point: at once when a buffer holds the path, and otherwise once its load
  lands. -/
  visit : ViewId → System.FilePath → At → (focus : Bool) → (record : Bool) → EditorM Unit
  /-- Saves the buffer, whatever is on disk when the flag says so. The write
  runs in a job; the follow-up job, when one is given, is started only once
  the file is written, never in the step that asked. A refused save (the
  file changed on disk since it was loaded, without the flag, or the write
  failed) starts nothing, and the implementation reports the refusal as
  any save's is. -/
  save : BufferId → Bool → Option JobStart → EditorM Unit
  deriving TypeName

/-- The name the files feature registers its `Files` value under. -/
def implementationName : String :=
  "files"

/-- Runs every `Opened` value, in registration order, with `id` and `path`. -/
def runOpened (id : BufferId) (path : System.FilePath) : EditorM Unit := do
  for value in ← Extension.values Opened do
    value.opened id path

/-- Runs every `Saved` value, in registration order, with `id`. -/
def runSaved (id : BufferId) : EditorM Unit := do
  for value in ← Extension.values Saved do
    value.saved id

/-- The `Files` value of the implementation's name, the latest registered;
`none` when there is none. -/
def files? : EditorM (Option Files) :=
  Extension.named Files (·.name) implementationName

/-- What a caller named `name` says when there is no `Files` value. -/
def noImplementation (name : String) : String :=
  s!"{name}: no files implementation"

/-- What files says of a load of the file at `path` it refused with
`error`: `cannot open <path>: <the refusal's sentence>`. A caller that
loads a file itself under `loadLimit` says it of a refused load, as files
would. -/
def notOpened (path : System.FilePath) (error : FileError) : String :=
  s!"cannot open {path}: {error.describe}"

/-- The longest file a caller loads, in bytes: 1 GiB. -/
def loadLimit : Nat :=
  1 <<< 30

/-- The most lines a side of the middle of a diff the engine is asked about:
100 000. -/
def diffLineLimit : Nat :=
  100000

/-- The open command's name: the core's (`FileJobs.openFileCommand`). -/
def openFileName : String :=
  FileJobs.openFileCommand

/-- The save command's name. -/
def saveName : String :=
  "save-buffer"

/-- The name of the command the ex names `e` and `e!` run. -/
def editName : String :=
  "edit-file"

/-- The reload command's name. -/
def reloadName : String :=
  "reload-buffer"

/-- The name of the command that turns auto-reload on and off. -/
def autoReloadName : String :=
  "auto-reload-mode"

/-- The name of the job that checks files for a change on disk: the core's
(`FileJobs.checkJob`). -/
def checkJob : String :=
  FileJobs.checkJob

/-- The name of the job that follows a file for auto-reload: the core's
(`FileJobs.followJob`). -/
def followJob : String :=
  FileJobs.followJob

/-- Every command name this interface declares, in the order the files
feature registers them. -/
def names : Array String :=
  #[openFileName, saveName, editName, reloadName, autoReloadName]

/-- Every job name this interface declares. -/
def jobs : Array String :=
  #[checkJob, followJob]

end FilesApi
