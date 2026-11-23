import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Config.Packages
import Editor.Display
import Editor.DisplayRules
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
import Shell
import Shell.Compiled
import ShellTest.Check

/-!
# Linked tests: `Shell.lean`

The tests of `Shell.lean`: `shellChecks`, `:!` over the real process
service. They were the contract test's (`ContractTest.shellChecks`) while
the shell was modules of the core. The linked test's root,
`ShellTest/Linked.lean`, runs them; its module doc says what each shows.
-/

namespace ShellTest.Linked

open Editor
open Editor.Test.Linked

/-! ## `:!` over the real process service -/

/-- The keys of the shell checks: none bound, and the shell's commands by
name; the shell's job is the one registered. -/
def shellKeys : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      (Shell.package.registered.commands.find? (·.name == name)).bind fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered := { jobs := (· == Shell.runJob) } }

/-- `stepped`'s loop once what the step asked for is done, as a host does
it: each invocation it answered run as a step of its own, and each job it
started spawned on `services`, waited for, and its command delivered, each
taken in the same way, at most `depth` deep. `none` when a job did not end
in time or ended otherwise than finished, or a step was refused. -/
partial def settle (services : Job.Services) (display : DisplayHandler) (texts : RealTexts)
    (stepped : Loop.Stepped TestScheme.scheme) (depth : Nat := 8) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  if depth == 0 then
    return none
  let mut loop := stepped.loop
  let mut texts := texts
  for invocation in stepped.answered do
    let (next, after) ← (loop.invoke shellKeys invocation).runReal texts display
    let .ok next := next | return none
    let some (settled, after) ← settle services display after next (depth - 1) | return none
    loop := settled
    texts := after
  for start in stepped.starts do
    let some work :=
      (Shell.package.registered.jobs.find? (·.name == start.name)).map
        (·.work start.arguments) | return none
    let handle ← Job.spawn services work (pure ())
    -- hang guard: the job's end, on its outcome.
    if (← Job.awaitWithin patience handle.outcome.result?).isNone then
      handle.cancel
      return none
    let some (.finished command) ← handle.outcome? | return none
    handle.settle
    let (next, after) ← (loop.deliver shellKeys s!"job {start.name}" command).runReal texts display
    let .ok next := next | return none
    let some (settled, after) ← settle services display after next (depth - 1) | return none
    loop := settled
    texts := after
  return some (loop, texts)

/-- Runs `invocation` on a loop over the real process service `services`, its
working directory `fixtures` and its buffer holding `contents`, until it
has settled: what the echo area says and the buffer's text after, or none if
a step refused. -/
def ranOver (services : Job.Services) (fixtures : System.FilePath) (invocation : Invocation)
    (contents : String) : IO (Option (String × String)) := do
  let published ← Snapshots.new
  let recorder ← DisplayRecorder.new { advance := 8, lineHeight := 16 } published.reader
  let display := recorder.handle
  let begin : EditorM (Loop TestScheme.scheme) := do
    let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
    let some target := loop.state.focusedTarget? | throw TextError.noSuchText
    target.buffer.text.insert 0 contents
    return { loop with state := { loop.state with workingDirectory := fixtures } }
  let (started, texts) ← begin.runReal (RealTexts.over published) display
  let .ok loop := started | return none
  let (stepped, texts) ← (loop.invoke shellKeys invocation).runReal texts display
  let .ok stepped := stepped | return none
  let some (loop, texts) ← settle services display texts stepped | return none
  let read : EditorM String := do
    let some target := loop.state.focusedTarget? | throw TextError.noSuchText
    target.buffer.text.read
  let (text, _) ← read.runReal texts display
  let .ok text := text | return none
  return some (loop.state.echo, text)

-- inferred-waits W43: removed by host-tests-on-fakes phase 4
set_option linter.inferredWait false in
/-- A check of `shellChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def criterion16RealProcessCheck (services : Job.Services) (fixtures : System.FilePath) : Check :=
  { name :=
      "criterion 16: over the real process service, `:!` running the fixture `hello` leaves `hello` in the echo area, and its child is reaped"
    run := do
      let ran := ranOver services fixtures
      let before ← Ffi.processesPending
      let hello := s!"'{fixtures / "hello"}'"
      let said ←
        ran { command := Shell.commandName, arguments := [.str hello, .str s!"!{hello}"] } ""
      let reaped ← Editor.Test.Linked.childrenReapedTo services before
      return said == some ("hello", "") && reaped }

-- inferred-waits W43: removed by host-tests-on-fakes phase 4
set_option linter.inferredWait false in
/-- A check of `shellChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def criterion17RealProcessCheck (services : Job.Services) (fixtures : System.FilePath) : Check :=
  { name :=
      "criterion 17: over the real process service, `:%!/usr/bin/sort` over the lines b, c and a leaves a, b and c, and its child is reaped"
    run := do
      let ran := ranOver services fixtures
      let before ← Ffi.processesPending
      let said ←
        ran { command := Shell.filterName
              arguments := [.nat 1, .nat 3, .str "/usr/bin/sort", .str "%!/usr/bin/sort"] }
            "b\nc\na\n"
      let reaped ← Editor.Test.Linked.childrenReapedTo services before
      return said == some ("3 lines filtered", "a\nb\nc\n") && reaped }

/-- What only the real process service shows of `:!` and a filter, with the
loop's working directory the fixtures' (`fixtures`, `tests/shell`). Each
check runs `shell-command` or `shell-filter` by name, with the arguments
ex's line hands it (`Ex.run`): that ex hands a `:!` line to those names is
ex's, held by the model checks of the shell typed through the kit's ex line
(`ShellTest.shellChecks`). -/
def shellChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  [criterion16RealProcessCheck services fixtures, criterion17RealProcessCheck services fixtures]

end ShellTest.Linked
