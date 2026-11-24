import Compile
import Compile.Compiled
import CompileTest.Check
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Config.Packages
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Test.Ex
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Rig
import Editor.Test.Linked.Services
import Editor.Test.Opener
import Editor.Text
import Editor.Value
import Editor.Workspace

/-!
# Linked tests: `Compile.lean`

The tests of `Compile.lean` that need the Rust library: `compileHostChecks`,
a compile through the headless host on a stepped stage, its child and its
files the stage's fakes; `compileRunChecks`, a compile over the real
process service, is of the wiring set (`CompileTest/Linked/Compile/Real.lean`).
The linked test's root,
`CompileTest/Linked.lean`, runs them; its module doc says what each shows.
They were `ContractTest.compileChecks` while the compile mode was a module
of the core, and are written on the core's linked test kit
(`Editor.Test.Linked`), which brings the loop, the real bindings and the
services they run over.
-/

namespace CompileTest

open Editor
open Editor.Test.Linked

/-! ## A compile through the headless host, on the stage's fakes -/

/-- The working directory of `compileHostChecks`' host: a made-up path,
which only the stage's file fake holds, with no `src/a.rs` in it. -/
def hostDirectory : System.FilePath :=
  "/work"

/-- The line `compileHostChecks` compiles: a child that writes one error
line and then waits until it is killed. -/
def hostLine : String :=
  "printf 'src/a.rs:3:5: error: boom\\n'; exec sleep 600"

/-- What the process fake of `compileHostChecks` runs for `hostLine` in
`hostDirectory`: the child writes the error line and then pauses, so the
run's first read delivers that line alone, with no end. -/
def hostChild : Process.StreamScript :=
  { command := { program := "/bin/sh", arguments := #["-c", hostLine], directory := hostDirectory }
    steps := #[.write .out "src/a.rs:3:5: error: boom\n".toUTF8, .pause 600000] }

/-- Runs `name` on the core's test kit's ex line (`Editor.Test.exLinePackage`):
the command `ex`, run by name, asks; `name` is committed into the minibuffer
and the accept key pressed; then, when `answer` is given, it is committed
into the prompt the command asks and the accept key pressed. Drains the
host's queue and steps nothing (`Session.handled`). -/
def exRun (session : Session) (name : String) (answer : Option String := none) : IO Bool := do
  session.ask [.run Test.ExLine.name]
  session.commit name
  for key in acceptKeys do
    session.press key
  if let some answer := answer then
    unless ← session.handled do
      return false
    session.commit answer
    for key in acceptKeys do
      session.press key
  session.handled

/-- Starts the run of `hostLine` with `name` (`compile` or `recompile`) and
steps it to its first read's line, posted and shown; then holds the process
fake's completions and moves the clock past the run's pause after its post
(`Compile.batchPause`), and steps again: the run's next read is held, so the
child is running, as the real one sleeping in `exec sleep 600` is, until the
check kills it. -/
def runHeld (session : Session) (processes : Job.FakeProcesses) (name : String)
    (answer : Option String) : IO Bool := do
  unless ← exRun session name answer do
    return false
  session.step
  processes.holdCompletions
  session.clock.advance 50
  session.step
  return true

/-- Kills the run (`kill-compilation`), steps to rest, and lets the process
fake answer again (`Job.FakeProcesses.letGo`), whose held read the kill
withdrew. -/
def killHeld (session : Session) (processes : Job.FakeProcesses) : IO Bool := do
  unless ← exRun session Compile.killName do
    return false
  session.step
  processes.letGo
  session.step
  return true

/-- Runs `check` against a host stepped on the check's thread over a stepped
stage (`Stage.stepped`), with the elaborator of `context` and no config,
handed `packages` and its working directory `hostDirectory`: its file fake
holds that directory and nothing in it, and its process fake runs
`hostChild` for `hostLine`. `check` is handed the session and the process
fake. -/
def withCompileHost (context : HostContext) (packages : Array Package)
    (check : Session → Job.FakeProcesses → IO Bool) : IO Bool := do
  let stage ← Stage.new context context.elaborator (memorySource []) { packages }
  let stage ←
    stage.stepped ((({} : FileModel).withDirectory "/").withDirectory hostDirectory)
        { streams := #[hostChild] }
  let some fakes := stage.fakes | return false
  let stage :=
    { stage with collaborators := { stage.collaborators with workingDirectory := hostDirectory } }
  onStage stage fun drive stage => check (Session.ofStage drive "/" stage) fakes.services.processes

/-- `true` when `holds`, and otherwise throws, saying what was `observed`:
a check that fails names what it saw. -/
def saw (holds : Bool) (observed : String) : IO Bool := do
  unless holds do
    throw (IO.userError s!"saw {observed}")
  return true

/-- Whether some line of `lines` holds `part`. -/
def holding (lines : Array String) (part : String) : Bool :=
  lines.any fun line => (line.splitOn part).length > 1

/-- The checks of a compile through the headless host, handed the
packages a set hands its editor (`context.packages`), on a stepped stage:
the child is the stage's process fake (`hostChild`), the visit's file the
stage's file fake, and each scene is asked after the session is stepped to
rest or stepped until its job's own line, never after an idle. The visit of
`next-error` is held on purpose: its load job is in the fake scheduler, not
stepped, when the scene is asked, which is the interleaving a `settle` or a
`join` before the scene met under load (task
`compile-linked-next-error-settle-race`); once stepped until the load's own
end line, the echo says the file is not there. -/
def compileHostChecks (context : HostContext) : List Check :=
  [{  name :=
        "a compile through the host on a stepped stage: compile runs the child, whose error line is shown in the compilation buffer as a compilation.error once the clock passes the run's pause; kill-compilation withdraws the child's wait and says Compilation killed; recompile starts a second run"
      run :=
        withCompileHost context context.packages fun session processes => do
          session.ask [.reload]
          unless ← runHeld session processes Compile.compileName hostLine do
            return false
          let compiled ← session.sceneLines
          let output ← session.output.get
          unless ← killHeld session processes do
            return false
          let withdrawn ← processes.withdrawn
          let killed ← session.sceneLines
          unless ← runHeld session processes Compile.recompileName none do
            return false
          let again ← session.sceneLines
          let starts :=
            (← processes.started).filter fun (_, request) =>
              match request with
              | .start .. => true
              | _ => false
          unless ← killHeld session processes do
            return false
          saw
              (holding output s!"job 1 {Compile.runJob}: started" &&
                holding compiled "exec sleep 600\\nsrc/a.rs:3:5: error: boom\\n\", scroll 0" &&
                holding compiled ": compilation.error" &&
                holding compiled "mode-line.inactive \"*compilation:" &&
                !withdrawn.isEmpty &&
                holding killed ": Compilation killed after" &&
                holding killed "\\nsrc/a.rs:3:5: error: boom\\nCompilation killed after" &&
                starts.size == 2 &&
                holding (← session.output.get) s!"job 2 {Compile.runJob}: started" &&
                holding again "\\nsrc/a.rs:3:5: error: boom\\n")
              s!"compiled {compiled}; withdrawn {withdrawn}; killed {killed}; again {again}; starts {starts.size}; output {← session.output.get}" },
    { name :=
        "next-error visits the first location through the host: with the visit's load held, the scene shows no visit echo; once the load has ended, the echo says the path resolved against the run's directory is not there; previous-error then says there is no earlier location"
      run :=
        withCompileHost context context.packages fun session processes => do
          session.ask [.reload]
          unless ← runHeld session processes Compile.compileName hostLine do
            return false
          unless ← killHeld session processes do
            return false
          -- The forced interleaving: the visit's keys are drained, its load
          -- job is held in the fake scheduler, and the scene is asked
          -- before the load's end, every run.
          unless ← exRun session Compile.nextName do
            return false
          let before ← session.output.get
          let (held, _) ← session.scene
          let loadEnded (lines : Array String) : Bool :=
            (lines.extract before.size lines.size).any fun line =>
              line.startsWith "job " && (line.splitOn s!" {Test.Opener.loadJob}: ").length == 2 &&
                !line.endsWith ": started"
          let ended ← session.stepUntil loadEnded
          let (visited, _) ← session.scene
          unless ← exRun session Compile.previousName do
            return false
          session.step
          let (previous, _) ← session.scene
          let missing := s!"{hostDirectory / "src" / "a.rs"}: nothing is at the path"
          saw
              (!holding #[held] "nothing is at the path" && ended && holding #[visited] missing &&
                holding #[previous] "previous-error: no earlier locations in")
              s!"held {held}; ended {ended}; visited {visited}; previous {previous}; output {← session.output.get}" }]

/-! ## A compile over the real process service -/

/-- The keys of the compile checks: none bound, and the compile mode's
commands by name; its job is the one registered. -/
def compileKeys : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      (Compile.package.registered.commands.find? (·.name == name)).bind fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered := { jobs := (· == Compile.runJob) } }

/-- The text of the first compilation buffer, if there is one. -/
def compilationText (loop : Loop TestScheme.scheme) : EditorM (Option String) := do
  match (loop.state.buffers.toList.filterMap id).find? (·.name.startsWith "*compilation: ") with
  | some buffer =>
    return some (← buffer.text.read)
  | none =>
    return none

end CompileTest
