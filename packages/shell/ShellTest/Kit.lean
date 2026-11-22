import Editor.Api
import Editor.Command.Call
import Editor.Invocation
import Editor.Job
import Editor.Test.Ex
import Editor.Test.Keys
import Editor.Test.Minibuffer
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.Workspace
import Shell
import Shell.Compiled

/-!
# The shell package's test kit

The shell checks' jobs, bindings and commands, made of the shell's modules
(`Shell.lean`, `Shell/Compiled.lean`) over the half of the
workspace driver that names no workspace module, the core kit's
(`Editor/Test/Workspace.lean`): its jobs and the shell's run job
(`shellJobs`), its keys and the shell checks' (`shellBindings`), and its
commands, the kit's ex line's (`Editor.Test.exLinePackage`,
`Editor/Test/Ex.lean`: the kit's own ex command, which hands a `:!` line
to the names `shell-api` declares, written there as text), the kit's minibuffer's and the shell's
(`shellCommands`). A file's workspace is the core kit's stand-in for the
finder's answer (`openAttach`). The shell's child and its replies, and
what a check reads of a driver, are the core's kit's
(`Editor/Test/Shell.lean`).

It was the shell feature's kit in the core (`Editor.Shell.Kit`,
`lean/Editor/Shell/Kit.lean`) while the shell was modules of the core, and
moved here when it moved out; its declarations keep their names. A module of
the package's tests imports it; the package's library may not
(`docs/design/packages.md`, "What a package may import").
-/

namespace Editor.Test

open Editor

/-- The jobs of the shell checks over the open driver's jobs `workspace`:
those, and the shell's run job. -/
def shellJobsWith (workspace : String → Option (List Argument → Work)) (name : String) :
    Option (List Argument → Work) :=
  if name == Shell.runJob then some Shell.runWork else workspace name

/-- The jobs of the shell checks: the open driver checks', the kit's
opener's, whose load runs the stand-in for the workspace's attach
(`openJobs`, `openAttach`), and the shell's run job. -/
def shellJobs (name : String) : Option (List Argument → Work) :=
  shellJobsWith openJobs name

/-- The bindings of the shell checks (`shellKeys`). -/
def shellBindings : List (String × Invocation) :=
  openBindings ++
    [("C-e e", invoke ExLine.name), ("C-e y", invoke Minibuffer.acceptName),
      ("C-e k", invoke "kube"), ("C-e g", invoke Shell.interruptName), ("C-e u", invoke "undo"),
      ("C-e o", invoke "squat"), ("C-e s", invoke "split"), ("C-e c", invoke "close"),
      ("C-e x", invoke "drop"), ("C-o s", opens "/r/src/s.txt"), ("C-o t", opens "/r/src/t.txt")]

/-- The commands of the shell checks (`shellKeys`) over the open driver's
commands `workspace`. -/
def shellCommandsWith (workspace : List (String × Dispatched)) : List (String × Dispatched) :=
  workspace ++
    dispatchedOf
      (exLinePackage.registered.commands ++ Minibuffer.package.registered.commands ++
        Shell.package.registered.commands) ++
    [("kube", fun call => do
        let location := Location.reachable "kube" "pod" "/app"
        discard <| Workspace.register location openOrigin
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
(`openCommandsWith Opener.commands`). -/
def shellCommands : List (String × Dispatched) :=
  shellCommandsWith (openCommandsWith Opener.commands)

end Editor.Test
