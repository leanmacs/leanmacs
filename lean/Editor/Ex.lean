import Editor.Api
import Editor.Command.Call
import Editor.Ex.Line

/-!
# The ex command line

The ex line is a prompt whose answer is run as a named ex command
(`docs/design/keymaps-and-modes.md`, "The ex command line"). It is one
command, `ex`, written over the editor API (`Editor/Api.lean`): it asks for
a line and then runs it. `Editor.lean` imports this module, so config calls
it. The commands as compiled code registers them, and the ex names that
ship, are in `Editor/Ex/Compiled.lean`.

## The ex command

- **`ex` asks for its line when it is given none** (`exCommand`), as the
  open command asks for its path (`Editor/Files.lean`). With a string as
  its first argument it runs that line. With anything else first, or
  nothing, it asks with a prompt labelled `label`, whose continuation is
  `ex` itself with no argument of its own: when the prompt is accepted the
  command runs again with the line as its first argument, in the view it
  was asked from (`docs/design/concurrency.md`, "Prompts"). A key bound to
  it under the Vim scheme hands it a count and a register, so its first
  argument is no line, and it asks.
- **Where the prompt is refused**, because one is open, the echo area says
  so (`notAsking`): the command's name, then the refusal's sentence. The
  open prompt stays.
- **Running a line** (`run`):
  1. the line is parsed into its name and its argument (`Ex.parse`,
     `Editor/Ex/Line.lean`). A line that is empty or all white space runs
     nothing and says nothing, as Vim's does;
  2. the command asks which command the name is bound to (`exBinding`),
     which the loop answers from the registry as it is at this step. A
     name nobody bound is said in the echo area (`unknown`), and the
     editor goes on;
  3. the binding makes the invocation (`Binding.invocation?`). An argument
     for a name that takes nothing is said (`noArgument`), and nothing
     runs;
  4. the command asks for the invocation to be run after it (`invoke`).
- **The command a line runs is a step of its own.** `ex` does not run it:
  the loop hands the invocation to its host, which runs it before the next
  event, as it runs a prompt's continuation (`Editor/Loop.lean`,
  "Prompts"). So an accepted ex line is three steps: the accept command,
  `ex` with the line, and the bound command. The bound command is looked
  up by the loop when its step runs, after `ex`'s step, and is run like
  any command: one rollback, one scene, and what becomes of it in the echo
  area under its own name. A name no command is registered under is said
  by the loop, `<command>: no such command`.
- **So an ex command's error goes to the echo area as a command's does**,
  with no rule here: a refusal of the bound command is the loop's to say,
  and an unknown ex name is a message of `ex`, which ran to its end.

## Where an addition goes

| Addition | Where |
|---|---|
| An ex name | A binding in `Editor/Ex/Compiled.lean`, or config's `exCommand` (`Editor/Setup.lean`); nothing here |
| A command an ex name runs | Here if it is the ex line's own, with its name and its messages, and its registration in `Editor/Ex/Compiled.lean` |
| A part of a line (a range, `!`) | `Editor/Ex/Line.lean`, and its use in `run` |

Pinned by `ModelTest.exChecks`, on the loop's driver over the editor's
models and the test scheme.
-/

namespace Editor.Ex

/-- The name the ex command is registered under. -/
def name : String :=
  "ex"

/-- The label of the prompt the ex command asks for its line with. -/
def label : String :=
  ":"

/-- What the echo area says when a line's name is one nobody bound. -/
def unknown (name : String) : String :=
  s!"{name}: not an ex command"

/-- What the echo area says when a line gives an argument to a name that
takes nothing. -/
def noArgument (name : String) : String :=
  s!"{name}: takes no argument"

/-- What the echo area says when the ex command was called with no line and
could not ask for one: the refusal's own sentence, after the command's
name. -/
def notAsking (refusal : PromptRefusal) : String :=
  s!"{name}: {refusal.describe}"

/-- Runs the ex line `line` ("Running a line", in the module docs): parses
it, asks which command its name is bound to, and asks for that command to
be run after this one, with the line's argument. A line that is empty or
all white space runs nothing. A name nobody bound, and an argument for a
name that takes nothing, are each said in the echo area, and nothing
runs. -/
def run (line : String) : EditorM Unit := do
  let some parsed := parse line | return
  let some binding ← exBinding parsed.name | message (unknown parsed.name)
  let some invocation := binding.invocation? parsed.argument | message (noArgument parsed.name)
  invoke invocation

/-- The ex command as it is called: runs the line that is its first
argument, a string (`run`). With anything else first, or nothing, it asks
for the line (`prompt`, labelled `label`), with itself as the continuation:
the answer is then its first argument, and it runs in the view it was asked
from. Where the prompt is refused, because one is open, it says so in the
echo area (`notAsking`). -/
def exCommand (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str line :: _ =>
    run line
  | _ =>
    if let .error refusal← prompt label { command := name } then
      message (notAsking refusal)

end Editor.Ex
