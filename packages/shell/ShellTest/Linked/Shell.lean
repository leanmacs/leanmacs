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
import Editor.Test.Shell
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

The tests of `Shell.lean`: `shellChecks`, `:!` and a filter on the loop
over the real text binding, the shell's jobs on a stepped rig. They were the contract test's (`ContractTest.shellChecks`) while
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
it, on `rig`: each invocation it answered run as a step of its own, and each
job it started spawned on the rig's services, run to its end
(`ProjectRig.ran`: on a stepped rig, on the check's thread), and its command
delivered, each taken in the same way, at most `depth` deep. `none` when a
job did not end or ended otherwise than finished, or a step was refused. -/
partial def settle (rig : ProjectRig) (texts : RealTexts) (stepped : Loop.Stepped TestScheme.scheme)
    (depth : Nat := 8) : IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  if depth == 0 then
    return none
  let mut loop := stepped.loop
  let mut texts := texts
  for invocation in stepped.answered do
    let (next, after) ← (loop.invoke shellKeys invocation).runReal texts rig.display
    let .ok next := next | return none
    let some (settled, after) ← settle rig after next (depth - 1) | return none
    loop := settled
    texts := after
  for start in stepped.starts do
    let some work :=
      (Shell.package.registered.jobs.find? (·.name == start.name)).map
        (·.work start.arguments) | return none
    let handle ← Job.spawn rig.services work (pure ())
    unless ← rig.ran handle do
      handle.cancel
      return none
    let some (.finished command) ← handle.outcome? | return none
    handle.settle
    let (next, after) ←
      (loop.deliver shellKeys s!"job {start.name}" command).runReal texts rig.display
    let .ok next := next | return none
    let some (settled, after) ← settle rig after next (depth - 1) | return none
    loop := settled
    texts := after
  return some (loop, texts)

/-- The made-up working directory of the shell checks' loop, which only the
rig's process fake's scripts name. -/
def shellDirectory : System.FilePath :=
  "/s"

/-- Runs `invocation` on a loop over a stepped rig (`ProjectRig.stepped`)
whose process fake runs `scripts`, its working directory `shellDirectory`
and its buffer holding `contents`, until it has settled: what the echo area
says, the buffer's text after, and the process fake's model then; none if a
step refused. -/
def ranOver (scripts : Array Process.Script) (invocation : Invocation) (contents : String) :
    IO (Option (String × String × ProcessModel)) := do
  let (rig, stepped) ← ProjectRig.stepped (processes := { scripts })
  let begin : EditorM (Loop TestScheme.scheme) := do
    let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
    let some target := loop.state.focusedTarget? | throw TextError.noSuchText
    target.buffer.text.insert 0 contents
    return { loop with state := { loop.state with workingDirectory := shellDirectory } }
  let (started, texts) ← begin.runReal (RealTexts.over rig.published) rig.display
  let .ok loop := started | return none
  let (stepped', texts) ← (loop.invoke shellKeys invocation).runReal texts rig.display
  let .ok stepped' := stepped' | return none
  let some (loop, texts) ← settle rig texts stepped' | return none
  let read : EditorM String := do
    let some target := loop.state.focusedTarget? | throw TextError.noSuchText
    target.buffer.text.read
  let (text, _) ← read.runReal texts rig.display
  let .ok text := text | return none
  return some (loop.state.echo, text, ← stepped.processes.model)

/-- A check of `shellChecks`, a declaration of its own. -/
def criterion16Check : Check :=
  { name :=
      "criterion 16: on the loop over the real text binding, `:!hello` running a child whose reply is `hello` leaves `hello` in the echo area, the child run once in the loop's working directory"
    run := do
      let command := Test.shellCommand shellDirectory "hello"
      let said ←
        ranOver #[{ command, reply := Test.shellReply "hello\n" }]
            { command := Shell.commandName, arguments := [.str "hello", .str "!hello"] } ""
      return said.map (fun (echo, text, model) => (echo, text, model.started)) ==
          some ("hello", "", #[command]) }

/-- A check of `shellChecks`, a declaration of its own. -/
def criterion17Check : Check :=
  { name :=
      "criterion 17: on the loop over the real text binding, `:%!sort` over the lines b, c and a feeds the child those lines and leaves the reply's a, b and c in the buffer"
    run := do
      let command := Test.shellCommand shellDirectory "sort"
      let said ←
        ranOver #[{ command, reply := Test.shellReply "a\nb\nc\n" }]
            { command := Shell.filterName
              arguments := [.nat 1, .nat 3, .str "sort", .str "%!sort"] } "b\nc\na\n"
      return said.map (fun (echo, text, model) => (echo, text, model.fed)) ==
          some ("3 lines filtered", "a\nb\nc\n", #[(command, "b\nc\na\n".toUTF8)]) }

/-- What `:!` and a filter do on the loop over the real text binding, the
shell's jobs on a stepped rig whose process fake answers each child
(`ranOver`). Each check runs `shell-command` or `shell-filter` by name,
with the arguments ex's line hands it (`Ex.run`): that ex hands a `:!` line
to those names is ex's, held by the model checks of the shell typed
through the kit's ex line (`ShellTest.shellChecks`). -/
def shellChecks : List Check :=
  [criterion16Check, criterion17Check]

end ShellTest.Linked
