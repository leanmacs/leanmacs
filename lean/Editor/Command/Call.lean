import Editor.Event
import Editor.Invocation
import Editor.State

/-!
# What a command is called with

When a key sequence completes, the scheme yields an invocation
(`Editor/Invocation.lean`): a command's name and plain arguments. The loop
looks the name up and runs the command with a `Call`: the invocation's
arguments, the keys that yielded it, and what the command acts on.

- **The target is handed in** (`Call.target`): the focused window and its
  buffer. The editor state has no ambient current buffer
  (`Editor/State.lean`, "No ambient context"), and a command has no request
  for buffers or windows yet, so what it acts on is an argument.
- **The arguments are the invocation's**, unchanged and in order. A count is
  one of them, where the scheme laid it out
  (`docs/design/keymaps-and-modes.md`, "Counts": `.nat n`, with `.nat 0` for
  none). There is no count field: a scheme's layouts put the count at
  different positions, and a second place for it would give a command two
  answers.
- **The keys are the chords that yielded the invocation**: what the scheme
  reported as pending before the last key, then that key's chord.

## Where an addition goes

| Addition | Where |
|---|---|
| Something every command is told about how it was called | A field of `Call`, filled where the loop makes the call (`Editor/Loop.lean`) |
| A new kind of argument | A variant of `Argument` (`Editor/Invocation.lean`); nothing here |
| Something a command asks of the editor | A request of the editor's port (`Editor/Command.lean`); nothing here |

Pinned by `ModelTest.reloadChecks`, where a command is handed its call.
-/

namespace Editor

/-- What a command is called with: what it acts on, the arguments of the
invocation, and the keys that yielded it. -/
structure Call where
  /-- The window the command acts on and its buffer: the focused window's,
  when a key ran the command. -/
  target : Target
  /-- The invocation's arguments, in order. -/
  arguments : List Argument := []
  /-- The chords of the key sequence that yielded the invocation; none for a
  command no key ran. -/
  keys : List Key := []
  deriving BEq, Repr

end Editor
