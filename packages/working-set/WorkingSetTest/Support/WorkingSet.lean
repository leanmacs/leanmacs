import BuffersApiTest.Fake
import Editor.Api
import Editor.File.Model
import Editor.InputScheme.Test
import Editor.Job.Model
import Editor.Jumps.Go
import Editor.Loop.Driver
import Editor.State
import Editor.Test.Driver
import Editor.Test.Editing
import Editor.Test.Excerpt
import Editor.Test.Hosted
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Workspace
import FilesApiTest.Fake
import VcApiTest.Fake
import WorkingSet.Compiled
import WorkingSet.Places

/-!
# Model tests: support: WorkingSet

The working set checks' world, commands, keys and driver: the test scheme
with the kit's editing keys (`Editor/Test/Editing.lean`) and a key of the
checks' own that goes back in the jump list, over the editor's models, the
job model with
the files of the checks under `/r`, and the commands and jobs of
`files-api`'s fake, the buffer commands, the kit's stand-in for a project
search's results (`Editor.Test.excerptFiles`, `Editor/Test/Excerpt.lean`) and
whatever working set commands a check hands in; a file's open attaches its
workspace through the kit's stand-in at the hook `FilesApi.Opened`
(`openAttachPackage`: `/r` is the main checkout on `main`), and the working
sets' own hooks are registered. No project search: that a range is added from
its results is held by the default set's fixture
`tests/headless/working-set-from-search`. Shared by the
test modules of `WorkingSet/`; it holds no checks of its own.
-/

namespace WorkingSetTest

open Editor
open Editor.Test

namespace Support

/-- The workspace of the checks. -/
def root : System.FilePath :=
  "/r"

/-- The location of the workspace of the checks. -/
def location : Location :=
  .local root

/-- Six lines of `a.txt`. -/
def aText : String :=
  "alpha one\nbravo two\ncharlie three\ndelta four\necho five\nfoxtrot six\n"

/-- Four lines of `b.txt`, with a match of `needle` on its third. -/
def bText : String :=
  "one\ntwo\nthe needle here\nfour\n"

/-- Two lines of `c.txt`, with a match of `needle` on its first. -/
def cText : String :=
  "a needle\nsecond\n"

/-- The files of the checks on the job model's disk, under `/r`. -/
def disk (files : FileModel) : FileModel :=
  [("/r/a.txt", aText), ("/r/b.txt", bText), ("/r/c.txt", cText)].foldl
    (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8)
    (files.withDirectory root)

/-- `holds` a working set range of the window's buffer from `start` to
`stop`, in the set `name`, its workspace's store marked read first when
`read`: what the checks of the hooks add ranges with, before the add
command exists. -/
def holdCommand (call : Call) : EditorM Unit := do
  let .str name :: .nat start :: .nat stop :: .bool read :: _ := call.arguments | return
  let buffer := call.target.window.buffer
  let state ← editorState
  let some (workspace, _) := state.workspaceOf? buffer | return
  let some file := (state.buffer? buffer).bind (·.file) | return
  let some root := WorkingSet.localRoot? workspace.location | return
  let some relative := WorkingSet.relativeIn root file.path | return
  let kept := WorkingSet.keptAt state workspace.location
  let kept := if read then { kept with disk := .read } else kept
  let (kept, _) ← WorkingSet.addRange kept name buffer relative start stop
  WorkingSet.setKept workspace.location kept

/-- The commands every driver of the checks has: `files-api`'s fake's (the
kit's opener, `FilesApiTest.fake`), `buffers-api`'s fake's
(`BuffersApiTest.fake`), the kit's stand-in for a project search's results
(`excerptFilesRegistration`), and `ws-hold` (`holdCommand`). -/
def baseCommands : Array Config.Registration :=
  FilesApiTest.fake.registered.commands ++ BuffersApiTest.fake.registered.commands ++
    #[excerptFilesRegistration, { name := "ws-hold", action := .call holdCommand }]

/-- What the checks' extension points hold: the workspace's stand-in at
`FilesApi.Opened` (`openAttachPackage`, the core kit's answer for `/r`),
the fake's `FilesApi.Files` value, and the working sets' own hooks, in that
order, as a host registers the workspace before the working sets. -/
def hooks : Array Package :=
  #[openAttachPackage, FilesApiTest.fake, BuffersApiTest.fake, WorkingSet.package]

/-- The test scheme's keys of the checks: the kit's editing keys and
commands, and `C-o` on `jump-back`, a command written here that goes one
place back in its window's jump list (`Jumps.move`), as a scheme's key for
it does; the kit's minibuffer's commands
(`Test.Minibuffer.package.registered.commands`), so that a prompt is
answered, the base commands and then `commands`, a later one of a name in
place of an earlier; and `modes`, as a host's registry holds them, and the
extension points `hooks` register. -/
def keysWith (commands : Array Config.Registration) (modes : Array Mode) :
    Loop.Keys TestScheme.scheme :=
  let jumpBack : Dispatched := fun call => do
    discard <| Jumps.move call.target.window.id (-1)
    return none
  let handed :=
    dispatchKeys (editingBindings ++ [("C-o", invoke "jump-back")])
      (editingDispatched ++ [("jump-back", jumpBack)])
  let registered := Test.Minibuffer.package.registered.commands ++ baseCommands ++ commands
  let all := modes
  let registry := ({} : Config.Registry).replaceModes .compiled all
  { handed with
    maps := fun state view =>
      registry.activeMaps TestScheme.scheme state view ++ handed.maps state view
    command? := fun name =>
      match registered.findRev? (·.name == name) with
      | some { action := .call run, .. } =>
        some fun call => do
          run call
          return none
      | _ => handed.command? name
    registered :=
      { handed.registered with
        entering := fun name => (all.find? (·.name == name)).map ([·])
        extensions := (hostedRegistry hooks).extensionsAt } }

/-- `more`, then the jobs every driver of the checks has: a job of `more`
comes before one of theirs of its name. -/
def jobsWith (more : Array Config.JobRegistration) (name : String) :
    Option (List Argument → Work) :=
  ((more ++ FilesApiTest.fake.registered.jobs).find? (·.name == name)).map
    (·.workWith (VcApiTest.backendValues #[]))

/-- A driver of the checks: the keys of `keysWith` over an empty scratch buffer, with
`commands`, `modes` and `jobs` handed in, whose jobs meet the files of the
checks (`disk`); `none` if making the state was refused. -/
def driverWith (commands : Array Config.Registration := #[]) (modes : Array Mode := #[])
    (jobs : Array Config.JobRegistration := #[]) : Option TestDriver :=
  (Loop.Driver.over (keysWith commands modes) (fun _ => none) (barState "" 0)
        editorModel).toOption.map
    fun driver =>
    { driver with
      registered := jobsWith jobs, jobs := { files := disk {} } }

/-- `driver` once `command` is invoked with `arguments`. -/
def invoked (driver : TestDriver) (command : String) (arguments : List Argument := []) :
    TestDriver :=
  (driver.stepped (driver.loop.invoke driver.handed { command, arguments })).1

/-- `driver` once every post is delivered and every job finished, oldest
first, with those they start. -/
def drained (driver : TestDriver) : TestDriver :=
  (List.range 64).foldl
    (fun driver _ =>
      match driver.posting[0]? with
      | some job => (driver.posted job.id).1
      | none =>
        match driver.pending[0]? with
        | some job => (driver.finish job.id).1
        | none => driver)
    driver

/-- `driver` once the file `/r/<name>` is opened in the window and everything
that starts is settled. -/
def opened (driver : TestDriver) (name : String) : TestDriver :=
  drained (invoked driver FilesApi.openFileName [.str (root / name).toString])

/-- `driver` once the buffer called `name` is closed and everything that
starts is settled. -/
def closed (driver : TestDriver) (name : String) : TestDriver :=
  drained (invoked driver BuffersApi.closeName [.str name])

/-- `driver` with the file `/r/<name>` holding `text` on disk, as another
program would leave it. -/
def onDisk (driver : TestDriver) (name text : String) : TestDriver :=
  { driver with
    jobs := { driver.jobs with files := driver.jobs.files.withFile (root / name) text.toUTF8 } }

/-- What the workspace of the checks keeps of its working sets. -/
def kept (driver : TestDriver) : WorkingSet.Kept :=
  WorkingSet.keptAt driver.loop.state location

/-- The ranges of the set `name` of the workspace of the checks. -/
def rangesOf (driver : TestDriver) (name : String) : Array WorkingSet.Range :=
  (((kept driver).sets.find? (·.name == name)).map (·.ranges)).getD #[]

/-- What the text of the buffer `id` holds from `start` to `stop`. -/
def sliceOf (driver : TestDriver) (id : BufferId) (start stop : Nat) : Option String := do
  let buffer ← driver.loop.state.buffer? id
  ((buffer.text.slice start stop).runModel driver.model.texts).1.toOption

/-- The text a held range spans in `driver`, read through its markers. -/
def heldText (driver : TestDriver) (range : WorkingSet.Range) : Option String := do
  let .held buffer start stop _ := range.hold | none
  let first ← ((Marks.offsetOf start).runModel driver.model.texts).1.toOption
  let last ← ((Marks.offsetOf stop).runModel driver.model.texts).1.toOption
  sliceOf driver buffer first last

/-- The keys that put the cursor at the start of the line `line`, counted
from 1: the text's start, then a row down for each line before it. -/
def toLine (line : Nat) : String :=
  " ".intercalate ("C-<Home>" :: List.replicate (line - 1) "<ArrowDown>")

/-- The keys that move the cursor `rows` rows down. -/
def down (rows : Nat) : String :=
  " ".intercalate (List.replicate rows "<ArrowDown>")

/-- The keys that select `rows` whole rows from a cursor at a row's start:
the head moved a row down for each, the anchor kept, so the selection
covers the rows with their line breaks. -/
def selectRows (rows : Nat) : String :=
  " ".intercalate (List.replicate rows "S-<ArrowDown>")

/-- The key that lets go of a selection of whole rows (`selectRows`): the
head moved a character back, a bar at the end of the last row selected. -/
def letGo : String :=
  "<ArrowLeft>"

/-- The keys of each character of `text`, as a key string. -/
def typed (text : String) : String :=
  " ".intercalate
    (text.toList.map fun character => if character == ' ' then "SPC" else character.toString)

end Support

end WorkingSetTest
