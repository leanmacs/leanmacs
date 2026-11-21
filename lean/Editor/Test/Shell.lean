import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.InputScheme.Test
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Model
import Editor.Program
import Editor.State
import Editor.Test.Driver
import Editor.Test.Loop
import Editor.Test.Workspace
import Editor.Text
import Editor.Text.Model
import Editor.Value

/-!
# The test kit: Shell

A shell command's child and its replies on the process model
(`shellCommand`, `shellReply`, `withScript`), the compiled commands as a
driver dispatches them (`dispatchedOf`), and what a check reads of a
driver's buffers and views. It names no module of the shell: the shell
checks' jobs, bindings and commands are the shell feature's kit
(`Editor/Shell/Kit.lean`). Shared by several test modules; it holds no checks
of its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

open Editor

/-- `/bin/sh -c text` in `directory`: the child a `:!` line runs. -/
def shellCommand (directory : System.FilePath) (text : String) : Process.Command :=
  { program := "/bin/sh", arguments := #["-c", text], directory }

/-- A run of a shell checks' child that wrote `stdout` and `stderr` and
ended as `exit`. -/
def shellReply (stdout : String) (stderr : String := "") (exit : Process.Exit := .code 0) :
    Except ProcessError Process.Ran :=
  .ok { exit, stdout := stdout.toUTF8, stderr := stderr.toUTF8 }

/-- `driver` with `script` ahead of the scripts it has, so its command does
what it says. -/
def withScript (driver : TestDriver) (script : Process.Script) : TestDriver :=
  { driver with
    jobs :=
      { driver.jobs with
        processes :=
          { driver.jobs.processes with scripts := #[script] ++ driver.jobs.processes.scripts } } }

/-- The compiled commands `registrations` as the dispatch checks run them. -/
def dispatchedOf (registrations : Array Config.Registration) : List (String × Dispatched) :=
  registrations.toList.filterMap fun registration =>
    match registration.action with
    | .call run =>
      some
        (registration.name, fun call => do
          run call
          return none)
    | _ => none

/-- The text of the buffer `id` in `driver`'s text model. -/
def bufferText (driver : TestDriver) (id : BufferId) : Option String := do
  let buffer ← driver.loop.state.buffer? id
  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents)

/-- The text of the buffer called `name` in `driver`. -/
def namedText (driver : TestDriver) (name : String) : Option String := do
  bufferText driver (← driver.loop.state.findBuffer name)

/-- What the focused view of `driver` shows (`showing`). -/
def showingFocused (driver : TestDriver) : Option Showing :=
  showing driver driver.loop.state.frame.focused

/-- `driver` with `rules` as config's display rules, which the loop hands
the commands it runs (`Loop.Registered.displayRules`). -/
def withDisplayRules (driver : TestDriver) (rules : Array DisplayRule) : TestDriver :=
  { driver with
    keys :=
      { driver.keys with registered := { driver.keys.registered with displayRules := rules } } }

end Editor.Test
