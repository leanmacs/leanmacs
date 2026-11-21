import Editor.Api
import Editor.Command.Call
import Editor.Ex
import Editor.Ex.Compiled
import Editor.Invocation
import Editor.Job
import Editor.Shell
import Editor.Shell.Compiled
import Editor.Test.Keys
import Editor.Test.Minibuffer
import Editor.Test.Shell
import Editor.Workspace
import Editor.Workspace.Kit

/-!
# The shell feature's test kit

The shell checks' jobs, bindings and commands, made of the shell's modules
(`Editor/Shell.lean`, `Editor/Shell/Compiled.lean`) over the workspace
driver of the workspace feature's kit (`Editor/Workspace/Kit.lean`): its
jobs and the shell's run job (`shellJobs`), its keys and the shell checks'
(`shellBindings`), and its commands, the ex line's, the kit's minibuffer's
and the shell's (`shellCommands`). The shell's child and its replies, and
what a check reads of a driver, are the core's kit's
(`Editor/Test/Shell.lean`).

It is the shell feature's kit: a test double, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"), and which moves into the shell package's test library
when the feature moves out.
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

end Editor.Test
