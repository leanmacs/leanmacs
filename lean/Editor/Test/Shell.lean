import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Ex
import Editor.Ex.Compiled
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.Shell
import Editor.Shell.Compiled
import Editor.State
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Workspace
import Editor.Text
import Editor.Text.Model
import Editor.Value
import Editor.Workspace

/-!
# The test kit: Shell

The shell command's jobs, bindings, commands and replies. Shared by several test
modules under `ModelTest/Editor/`; it holds no checks of its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

open Editor

/-- The jobs of the shell checks over the workspace driver's jobs
`workspace`: those, and the shell's run job. -/
def shellJobsWith (workspace : String → Option (List Argument → Work)) (name : String) :
    Option (List Argument → Work) :=
  if name == Shell.runJob then some Shell.runWork else workspace name

/-- The jobs of the shell checks: the workspace driver checks', the kit's
opener's among them (`workspaceJobs`), and the shell's run job. -/
def shellJobs (name : String) : Option (List Argument → Work) :=
  shellJobsWith workspaceJobs name

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

/-- The bindings of the shell checks (`shellKeys`). -/
def shellBindings : List (String × Invocation) :=
  workspaceBindings ++
    [("C-e e", invoke Ex.name), ("C-e y", invoke Minibuffer.acceptName), ("C-e k", invoke "kube"),
      ("C-e g", invoke Shell.interruptName), ("C-e u", invoke "undo"), ("C-e o", invoke "squat"),
      ("C-e s", invoke "split"), ("C-e c", invoke "close"), ("C-e x", invoke "drop"),
      ("C-o s", opens "/r/src/s.txt"), ("C-o t", opens "/r/src/t.txt")]

/-- The commands of the shell checks (`shellKeys`) over the workspace
driver's commands `workspace`. -/
def shellCommandsWith (workspace : List (String × Dispatched)) : List (String × Dispatched) :=
  workspace ++
    dispatchedOf
      (Ex.package.registered.commands ++ Minibuffer.package.registered.commands ++
        Shell.package.registered.commands) ++
    [("kube", fun call => do
        let location := Location.reachable "kube" "pod" "/app"
        discard <| Workspace.register location workspaceOrigin
        Workspace.setBufferWorkspace call.target.window.buffer location
        return none),
      ("undo", fun call => do
        discard <| call.target.window.buffer.undo
        return none),
      ("squat", fun (_ : Call) => do
        discard <| createBuffer "*shell output: r@main*"
        return none),
      ("split", fun call => do
        if let .ok made← call.target.window.id.split then
          discard <| made.focus
        return none),
      ("close", fun call => do
        discard <| call.target.window.id.close
        return none),
      ("drop", fun call => do
        let window := call.target.window
        if let .ok elsewhere← createBuffer "elsewhere" then
          discard <| window.id.show elsewhere
          discard <| window.buffer.remove
        return none)]

/-- The commands of the shell checks (`shellKeys`), with the kit's opener's
(`workspaceCommands`). -/
def shellCommands : List (String × Dispatched) :=
  shellCommandsWith workspaceCommands

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
