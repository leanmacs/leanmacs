import Compile
import Compile.Compiled
import CompileTest.Check
import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Config.Packages
import Editor.Display
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.SyntaxTree
import Editor.TabBar
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Rig
import Editor.Test.Linked.Services
import Editor.Text
import Editor.Value
import Editor.Watch
import Editor.Workspace

/-!
# Linked tests: `Compile.lean`

The tests of `Compile.lean` that need the Rust library: `compileRunChecks`,
a compile over the real process service. The linked test's root,
`CompileTest/Linked.lean`, runs them; its module doc says what each shows.
They were `ContractTest.compileChecks` while the compile mode was a module
of the core, and are written on the core's linked test kit
(`Editor.Test.Linked`), which brings the loop, the real bindings and the
services they run over.
-/

namespace CompileTest

open Editor
open Editor.Test.Linked

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

/-- What only the real process service shows of a compile: its output in
the compilation buffer before the child ends, with the fixture
`three-lines` (`fixtures`, `tests/compile`), which waits for files the
check makes. -/
def compileRunChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  [{  name :=
        "criterion 11: over the real process service, the fixture three-lines shows each line in the compilation buffer before it ends, and its exit status in the last line; its child is reaped"
      run := do
        let before ← pendingChildren
        let directory ← IO.FS.createTempDir
        try
          let published ← Snapshots.new
          let recorder ← DisplayRecorder.new { advance := 8, lineHeight := 16 } published.reader
          let display := recorder.handle
          -- A scratch buffer has no workspace: the directory scope is the
          -- loop's working directory, where the fixture looks for its files.
          let begin : EditorM (Loop TestScheme.scheme) := do
            let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            return { loop with state := { loop.state with workingDirectory := directory } }
          let (started, texts) ← begin.runReal (RealTexts.over published) display
          let .ok loop := started | return false
          let line := s!"'{fixtures / "three-lines"}'"
          let (stepped, texts) ←
            (loop.invoke compileKeys
                    { command := Compile.compileName, arguments := [.str line] }).runReal
                texts display
          let .ok stepped := stepped | return false
          let some start := stepped.starts[0]? | return false
          let some work :=
            (Compile.package.registered.jobs.find? (·.name == start.name)).map
              (·.work start.arguments) | return false
          let posts ← IO.mkRef (#[] : Array Invocation)
          let handle ←
            Job.spawn services work (pure ()) fun invocation => posts.modify (·.push invocation)
          let loopRef ← IO.mkRef stepped.loop
          let textsRef ← IO.mkRef texts
          -- Delivers `command` as the loop delivers a job's, and reads the
          -- compilation buffer after it.
          let deliver (command : EditorM Unit) : IO (Option String) := do
            let (next, after) ←
              ((← loopRef.get).deliver compileKeys s!"job 1 {Compile.runJob}" command).runReal
                  (← textsRef.get) display
            textsRef.set after
            let .ok next := next | return none
            loopRef.set next.loop
            let (text, after) ← (compilationText next.loop).runReal (← textsRef.get) display
            textsRef.set after
            return (text.toOption).join
          let postsAt (count : Nat) : IO Bool := eventually (return (← posts.get).size ≥ count)
          let deliverPost (index : Nat) : IO (Option String) := do
            let some invocation := (← posts.get)[index]? | return none
            deliver (runPosted invocation)
          unless ← postsAt 1 do
            handle.cancel
            return false
          let first ← deliverPost 0
          IO.FS.writeFile (directory / "go-1") ""
          unless ← postsAt 2 do
            handle.cancel
            return false
          let second ← deliverPost 1
          IO.FS.writeFile (directory / "go-2") ""
          unless ← eventually handle.ended do
            handle.cancel
            return false
          -- What the child wrote after `two` came in posts of its own or with
          -- its end: each is delivered, in order, then the job's command.
          let mut last := second
          for index in [2:(← posts.get).size] do
            last ← deliverPost index
          let some (.finished command) ← handle.outcome? | return false
          last ← deliver command
          handle.settle
          let reaped ← eventually (return (← pendingChildren) == before)
          let lastLine (text : String) : String :=
            ((text.splitOn "\n").filter (!·.isEmpty)).getLast?.getD ""
          let has (text : Option String) (part : String) : Bool :=
            text.any fun text => (text.splitOn "\n").contains part
          return has first "one" && !has first "two" &&
              !(first.any fun text => (text.splitOn "Compilation").length > 1) &&
              has second "two" &&
              !has second "three" &&
              has last "three" &&
              (last.map lastLine).any
                (·.startsWith "Compilation exited abnormally with code 2 after ") &&
              reaped
        finally
          IO.FS.removeDirAll directory }]

end CompileTest
