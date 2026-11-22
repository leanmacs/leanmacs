import Editor.Event
import Editor.InputScheme
import Editor.Invocation
import Editor.State

/-!
# What a command is called with

When a key sequence completes, the scheme yields an invocation
(`Editor/Invocation.lean`): a command's name and plain arguments. The loop
looks the name up and runs the command with a `Call`: the invocation's
arguments, the keys that yielded it, and what the command acts on.

- **The target is handed in** (`Call.target`): the focused window and its
  buffer, as they were when the command was called. The editor state has
  no ambient current buffer (`Editor/State.lean`, "No ambient context"), so
  what a command acts on is an argument. A command can also ask for
  buffers and windows (`Editor/Api.lean`): the state it reads then is the
  one its own requests have left, and the target is not updated by them,
  so a command that shows another buffer in its window reads the window
  again (`ViewId.target`).
- **The arguments are the invocation's**, unchanged and in order. A count is
  one of them, where the scheme laid it out
  (`docs/design/keymaps-and-modes.md`, "Counts": `.nat n`, with `.nat 0` for
  none). There is no count field: a scheme's layouts put the count at
  different positions, and a second place for it would give a command two
  answers.
- **The keys are the chords that yielded the invocation**: what the scheme
  reported as pending before the last key, then that key's chord.
- **The report is what the input scheme says of the target's view**
  (`Call.report`, an `InputScheme.Report`, `Editor/InputScheme.lean`): the
  shape its selection has, whether a motion extends it, and the rest. A
  command cannot ask the scheme: its state is the loop's, at a type the
  loop does not know. For a key's command it is the report in the scheme's
  state after the key, so the command of the key that enters a state is
  told of that state; for a command no key ran, the report in the state
  the scheme is in. It is the default report where no scheme said
  anything: for a call made by hand, and under a scheme that reports
  nothing.

## Where an addition goes

| Addition | Where |
|---|---|
| Something every command is told about how it was called | A field of `Call`, filled where the loop makes the call (`Editor/Loop.lean`) |
| A new kind of argument | A variant of `Argument` (`Editor/Invocation.lean`); nothing here |
| Something a command asks of the editor | A request of the editor's port (`Editor/Command.lean`), and for the editor state an operation of the editor API (`Editor/Api.lean`); nothing here |

Pinned by `ModelTest.reloadChecks`, where a command is handed its call, and
the report by `ModelTest.dispatchReportChecks`, through the loop.
-/

namespace Editor

/-- What a command is called with: what it acts on, the arguments of the
invocation, the keys that yielded it, and what the input scheme says of the
view it acts on. -/
structure Call where
  /-- The window the command acts on and its buffer: the focused window's,
  when a key ran the command. -/
  target : Target
  /-- The invocation's arguments, in order. -/
  arguments : List Argument := []
  /-- The chords of the key sequence that yielded the invocation; none for a
  command no key ran. -/
  keys : List Key := []
  /-- What the input scheme says of the target's view: for a key's command,
  in the scheme's state after the key. The default report where no scheme
  said anything. -/
  report : InputScheme.Report := {}
  deriving BEq, Repr

/-- The count the call carries: its first argument when that is a natural
number, as an input scheme lays a count out before a command's own
arguments, and 0 for none. -/
def Call.count (call : Call) : Nat :=
  match call.arguments with
  | .nat count :: _ => count
  | _ => 0

/-- The call's count as a number of steps: 1 for none. -/
def Call.steps (call : Call) : Nat :=
  max 1 call.count

end Editor
