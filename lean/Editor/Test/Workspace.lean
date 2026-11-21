import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Event
import Editor.Extension
import Editor.File.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Store
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Opener
import Editor.Text
import Editor.Value
import Editor.Workspace
import FilesApi

/-!
# The test kit: Workspace

The workspace a check sees settled (`settledOn`, `settledAfter`,
`shownWorkspace`), a store for the stores' checks (`countStore`), and the
stand-in for the workspace feature's attach (`attachAt`, `attachPackage`):
a package that gives every buffer that takes in a file one workspace, at
`files-api`'s hook `FilesApi.Opened`, which a check of another feature
registers in place of the workspace package. Also the half of the workspace
driver that names no workspace module, which the shell's and version
control's checks are built on (`openBindings`, `openCommandsWith`,
`openJobs`, `openDriver`): the files of `/r`, `/w` and `/x` and the keys
that open them, and each file's workspace given by a stand-in for the
finder's answer (`openFound`, `openAttach`, `openAttachPackage`, over the
general `attachBy` and `attachByPackage`): `/r` is a
main checkout on `main`, `/w` a linked worktree of it on `feature`, both
with the origin `openOrigin`, and `/x` is in none. It names no module of the
workspace feature: the workspace's world, finder jobs, commands, keys and
driver are that feature's kit (`Editor/Workspace/Kit.lean`). Shared by
several test modules; it holds no checks of its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

open Editor

/-- A store of a number, for the checks of the workspace and project
stores. -/
def countStore : Store Nat :=
  { name := "count", version := 1, initial := 0, encode := .nat
    decode := fun
      | .nat n => some n
      | _ => none }

/-- `driver` once `events` are fed and every job they start, and every job
those jobs' commands start, is finished, oldest first. -/
def settledOn (driver : TestDriver) (events : List Event) : TestDriver :=
  (List.range 8).foldl
    (fun driver _ =>
      match driver.pending[0]? with
      | some job => (driver.finish job.id).1
      | none => driver)
    (fedTo driver events).1

/-- `driver` once `keys` are pressed and every job they start, and every job
those jobs' commands start, is finished, oldest first. -/
def settledAfter (driver : TestDriver) (keys : String) : TestDriver :=
  settledOn driver (presses keys)

/-- The workspace of the buffer the view 0 of `driver` shows, and its
project. -/
def shownWorkspace (driver : TestDriver) : Option (Workspace × Project) := do
  driver.loop.state.workspaceOf? (← showing driver).id

/-- Gives the buffer `id` the workspace `found` at once, as the workspace
finder's answer recorded for the directory of `path` under the config
generation now: a stand-in for the workspace feature's attach, which a
test of another feature registers at the interface library `files-api`'s
hook `FilesApi.Opened` in its place. It starts no job and looks for no
mode on markers. -/
def attachAt (found : Workspace.Found) (id : BufferId) (path : System.FilePath) : EditorM Unit := do
  let directory := (path.parent.map Process.trimmed).getD found.root
  let (_, generation) ← RegistryRequest.ask .workspaceSettings
  discard <| EditorState.ask (.recordWorkspace directory generation (some found))
  Workspace.setBufferWorkspace id (.local found.root)

/-- A package, standing in for the workspace's, that registers `attachAt
found` at `FilesApi.Opened` under the workspace's name: every buffer that
takes in a file is given the workspace `found`. A test of another feature
registers it in place of the workspace package. -/
def attachPackage (found : Workspace.Found) : Package :=
  { name := "test-workspace"
    setup := Extension.add ({ name := "workspace", opened := attachAt found } : FilesApi.Opened) }

/-- The `origin` of the repository of the open driver checks
(`openFound`). -/
def openOrigin : String :=
  "git@github.com:o/r.git"

/-- The workspace a directory of the open driver checks is in, standing in
for the workspace finder's answer: in `/r`, the main checkout `/r` on
`main`; in `/w`, its linked worktree `/w` on `feature`; both of the project
whose common directory is `/r/.git` and whose origin is `openOrigin`
(`Workspace.Found.ofGit`, the core's, as the finder's git adapter answers);
anywhere else, none. -/
def openFound (directory : System.FilePath) : Option Workspace.Found :=
  if Workspace.holds "/r" directory then
    some
      (Workspace.Found.ofGit { toplevel := "/r", commonDir := "/r/.git", branch := .named "main" }
        (some openOrigin))
  else
    if Workspace.holds "/w" directory then
      some
        (Workspace.Found.ofGit
          { toplevel := "/w", commonDir := "/r/.git", branch := .named "feature" }
          (some openOrigin))
    else none

/-- Gives the buffer `id` of the file at `path` the workspace `answer` gives
for the file's directory (`attachAt`), a stand-in for the finder's answer
that knows its directories; nothing for a directory it gives none. -/
def attachBy (answer : System.FilePath → Option Workspace.Found) (id : BufferId)
    (path : System.FilePath) : EditorM Unit := do
  let some directory := path.parent | return
  if let some found := answer directory then
    attachAt found id path

/-- A package, standing in for the workspace's, that registers `attachBy
answer` at `FilesApi.Opened` under the workspace's name: for a driver or a
rig whose files are opened by `files-api`'s fake, which runs that hook. -/
def attachByPackage (answer : System.FilePath → Option Workspace.Found) : Package :=
  { name := "test-workspace"
    setup := Extension.add ({ name := "workspace", opened := attachBy answer } : FilesApi.Opened) }

/-- The workspace a directory is in when it is under `root`, a checkout of
`branch`, `main` by default, whose common directory is `commonDir`,
`root`'s `.git` by default, with no origin, standing in for the workspace
finder's answer over real git (`Workspace.Found.ofGit`, the core's, as the
finder's git adapter answers); none for a directory not under `root`. A
linked test that makes its repository in a temporary directory answers with
it. -/
def checkoutFound (root : System.FilePath) (branch : String := "main")
    (commonDir : System.FilePath := root / ".git") (directory : System.FilePath) :
    Option Workspace.Found :=
  if Workspace.holds root directory then
    some (Workspace.Found.ofGit { toplevel := root, commonDir, branch := .named branch } none)
  else none

/-- Gives the buffer `id` of the file at `path` the workspace `openFound`
answers for the file's directory (`attachBy`). -/
def openAttach (id : BufferId) (path : System.FilePath) : EditorM Unit :=
  attachBy openFound id path

/-- `attachByPackage openFound`: the stand-in for the workspace's attach of
the open driver checks, for a driver whose files `files-api`'s fake
opens. -/
def openAttachPackage : Package :=
  attachByPackage openFound

/-- The jobs of the open driver checks: the kit's opener's
(`Editor/Test/Opener.lean`), whose load runs `opened` once a buffer takes in
a file, `openAttach` by default, as a file's open runs the attach at
`FilesApi.Opened`. -/
def openJobs (opened : BufferId → System.FilePath → EditorM Unit := openAttach) (name : String) :
    Option (List Argument → Work) :=
  Opener.jobsWith opened (name := name)

/-- The bindings of the open driver checks: `C-o a`, `C-o b` and `C-o c`
open `a.lean`, `b.lean` and `c.lean` in `/r/src`, `C-o w` opens
`/w/src/b.lean` and `C-o x` opens `/x/a.txt`; `C-o n` makes a buffer `made`
that inherits the workspace of the window's buffer, and a buffer `bare`
that does not. -/
def openBindings : List (String × Invocation) :=
  [("C-o a", opens "/r/src/a.lean"), ("C-o b", opens "/r/src/b.lean"),
    ("C-o c", opens "/r/src/c.lean"), ("C-o w", opens "/w/src/b.lean"), ("C-o x", opens "/x/a.txt"),
    ("C-o n", invoke "inherit")]

/-- The commands of the open driver checks, by name, with the file commands
`files`: those and `inherit` (`openBindings`), which uses only the core's
`BufferId.inheritWorkspace`. -/
def openCommandsWith (files : List (String × Dispatched)) : List (String × Dispatched) :=
  files ++
    [("inherit", fun call => do
        if let .ok made← createBuffer "made" then
          discard <| made.inheritWorkspace call.target.window.buffer
        discard <| createBuffer "bare"
        return none)]

/-- The files of the open driver checks: those `openBindings` opens, and two
more in `/r/src` for the shell checks' filters. -/
def openFiles : List (System.FilePath × String) :=
  [("/r/src/a.lean", "a"), ("/r/src/b.lean", "b"), ("/r/src/c.lean", "c"), ("/w/src/b.lean", "w"),
    ("/x/a.txt", "x"), ("/r/src/s.txt", "b\nc\na\n"), ("/r/src/t.txt", "d\nb\nc\na")]

/-- A driver with the keys `keys`, those of `openBindings` over the kit's
opener's commands by default, and the jobs `registered`, `openJobs` by
default, whose file model holds `openFiles`, with no workspace world and no
git; `none` if making the state was refused. A buffer's workspace is the
one its jobs' load gives it, `openAttach` with `openJobs`, the stand-in for
the finder. -/
def openDriver (registered : String → Option (List Argument → Work) := openJobs)
    (keys : Loop.Keys TestScheme.scheme :=
      dispatchKeys openBindings (openCommandsWith Opener.commands)) :
    Option TestDriver :=
  let files :=
    openFiles.foldl (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8) {}
  (Loop.Driver.over keys registered (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { driver.jobs with files } }

end Editor.Test
