import Editor.Api
import Editor.Command
import Editor.Event
import Editor.Extension
import Editor.InputScheme.Test
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Store
import Editor.Test.Driver
import Editor.Test.Keys
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
registers in place of the workspace package. It names no module of the
workspace feature: the workspace's world, jobs, commands, keys and driver
are that feature's kit (`Editor/Workspace/Kit.lean`). Shared by several test
modules; it holds no checks of its own.

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

end Editor.Test
