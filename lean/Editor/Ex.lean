import Editor.Api
import Editor.Command.Call
import Editor.Ex.Line
import Editor.Files
import Editor.Shell

/-!
# The ex command line

The ex line is a prompt whose answer is run as a named ex command
(`docs/design/keymaps-and-modes.md`, "The ex command line"). It is one
command, `ex`, written over the editor API (`Editor/Api.lean`): it asks for
a line and then runs it. The commands the shipped ex names run that are the
ex line's own are here too: `quit`, `save-and-quit` and `reload-config`.
`Editor.lean` imports this module, so
config calls them. The commands as compiled code registers them, and the ex
names that ship, are in `Editor/Ex/Compiled.lean`.

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
- **The prompt's candidates are the `:!` lines of the buffer's scope, then
  the ex names that are bound**: the history of the asking buffer's project,
  or the editor-wide one for a buffer outside any workspace, newest first
  (`Shell.history`, `Editor/Shell.lean`), then the bound names (`exNames`,
  `Editor/Api.lean`), which the loop answers from the registry as it is
  when the line is asked for. So while a line is being typed the scene
  lists the lines and names it matches, a key of the minibuffer chooses
  one, and accepting runs the chosen one (`Editor/Minibuffer.lean`).
  Typing `!` lists the history.
  - **The typed line is the pattern, whole.** A line with an argument
    matches no name, so nothing is listed, and accepting runs the line as
    typed. A name is completed, an argument is not.
  - **Nothing is chosen unless a key chooses it.** A typed name and the
    accept key run what was typed, as before there were candidates: `r`
    and the accept key is the name `r`, which nobody bound, and not
    `reload`.
- **Running a line** (`run`):
  1. the line is parsed into its range, its name and its argument
     (`Ex.parse`, `Editor/Ex/Line.lean`). A line that is empty or all
     white space runs nothing and says nothing, as Vim's does. A range
     before a name, which no name takes, is said (`noRange`), and nothing
     runs; so is a range alone, which in Vim goes to a line
     (`rangeAlone`);
  2. **a line of the bang form** (`:!cmd`, `Line.bang`) with no range is
     handed to the shell: the command `shell-command` is asked to run
     after this one with the text after the `!` and the line, trimmed
     (`invoke`; `Editor/Shell.lean`). `:!` with nothing after it is said
     (`Shell.noCommand`), and so is one with a range (`noRange`), which
     no command takes yet. No binding is asked of a bang line;
  3. the command asks which command the name is bound to (`exBinding`),
     which the loop answers from the registry as it is at this step. A
     name nobody bound is said in the echo area (`unknown`), and the
     editor goes on;
  4. the binding makes the invocation (`Binding.invocation?`). An argument
     for a name that takes nothing is said (`noArgument`), and nothing
     runs;
  5. the command asks for the invocation to be run after it (`invoke`).
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

## Quit

- **`quit`** (`quitName`, `quitCommand`) asks the editor to quit (`quit`,
  `Editor/Api.lean`; `docs/design/concurrency.md`, "Quit"). The ex name
  `q` is bound to it.
- **It is refused while a buffer that holds a file has unsaved changes**,
  and says so in the echo area (`notQuitting`): `quit: <name> has unsaved
  changes`, with the first such buffer's name. The editor goes on.
- **A buffer with no file never blocks it.** The scratch buffer cannot be
  saved, and `:w !cmd` is not built, so a rule that counted it would leave
  no way to quit once anything was typed there. This departs from Vim,
  which refuses.
- **It waits for a save in flight.** The command asks, and the loop says
  stop once the save's result has been delivered (`Editor/Loop.lean`,
  "Quit"): `w` then `q`, typed as fast as you like, writes the file and
  quits. If that save is refused the quit is withdrawn, and the save's
  refusal is what the echo area says, whether or not the buffer was
  modified: the editor never leaves on a save that did not write the
  file.
- **It quits the editor, not a window.** Vim's `q` closes the current
  window and quits when it is the last.
- **The system's quit runs it.** Command-Q, Quit from the Dock's menu, a
  logout, restart or shutdown reach the loop as `Event.quitRequested`,
  which runs the command named `quit` by these rules (`Editor/Loop.lean`,
  "Quit"). When it does not quit, the system is told to keep the editor
  running.

## A window's close request

- **A close request is a quit by `q`'s rule.** The rule is one program,
  `closeRequested`, which `quitCommand` is, and which the loop runs itself
  for a window's close request (`Editor/Loop.lean`, "Quit"): refused with
  `notQuitting` while a buffer that holds a file has unsaved changes,
  waiting for a save in flight, and withdrawn by a save that is refused.
- **The loop runs the rule, not the command registered as `quit`**, so a
  host that registers no ex command still closes its window, and config's
  `quit` does not replace what the close button does.

## Save and quit

- **`save-and-quit`** (`saveQuitName`, `saveQuitCommand`) is one command:
  it starts the save of the buffer of the window it was called with
  (`Files.save`, `Editor/Files.lean`), reads the state again, and asks
  the editor to quit only if that buffer then has a save in flight. The
  ex name `wq` is bound to it.
- **The quit waits for the save**, by the rule above: the file is
  written, the save's result is delivered, and that step says stop. The
  order is fixed by the wait, not by timing.
- **When the save did not start, it does not quit.** A buffer with no
  file says so (`Files.noFile`), and the editor goes on, as Vim's `wq`
  does with no file name.
- **When the save is refused**, the file having changed on disk, the quit
  is withdrawn and the echo area says the save's refusal
  (`Files.notSaved`). That holds for a buffer that is not modified too:
  its save is refused all the same, and the editor goes on.
- **When another buffer has unsaved changes**, the save starts and the
  quit is refused with that buffer's name (`notQuitting`): the file is
  written and the editor goes on. Vim does the same.
- **It saves a buffer that is not modified too**, as Vim's `wq` does.
- **While an earlier save of the buffer is in flight** the save command
  says so (`Files.beingSaved`) and starts none; the buffer has a save in
  flight, so the quit is asked.
  - It waits for that save, and the echo area keeps the save command's
    message until the save's result is delivered.
  - If the buffer was edited since that save began, the quit is refused
    with the buffer's name, and the refusal (`notQuitting`) is what the
    echo area says, in place of the save command's message. The earlier
    save still writes the text from before the edit, and the buffer
    stays modified.

## Reload

- **`reload-config`** (`reloadName`, `reloadCommand`) asks for the config
  to be reloaded (`reloadConfig`, `Editor/Api.lean`). The ex name `reload`
  is bound to it.
- **The reload is asynchronous.** The command runs to its end at once; the
  host starts the reload job, and the new config is installed between two
  later events (`docs/design/concurrency.md`, "Reload"). A key typed
  before the install runs the old config's binding.
- **It says nothing.** A reload's report is the host's to show: the
  headless host prints it, and nothing puts it in the echo area.

## Where an addition goes

| Addition | Where |
|---|---|
| An ex name | A binding in `Editor/Ex/Compiled.lean`, or config's `exCommand` (`Editor/Setup.lean`); nothing here |
| A command an ex name runs | Here if it is the ex line's own, with its name and its messages, and its registration in `Editor/Ex/Compiled.lean` |
| A part of a line | `Editor/Ex/Line.lean`, and its use in `run` |

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

/-- What the echo area says when a line gives a range to a name: no name
but the bang form's takes one. -/
def noRange (name : String) : String :=
  s!"{name}: takes no range"

/-- What the echo area says for a line that is a range alone: Vim goes to
that line, which is not built. -/
def rangeAlone : String :=
  "a range alone, to go to a line, is not built"

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
  if parsed.bang then
    match parsed.range, parsed.argument with
    | _, none =>
      message Shell.noCommand
    | none, some text =>
      invoke { command := Shell.commandName, arguments := [.str text, .str (trimmed line)] }
    | some _, some _ =>
      message (noRange parsed.name)
    return
  if parsed.range.isSome then
    message (if parsed.name.isEmpty then rangeAlone else noRange parsed.name)
    return
  let some binding ← exBinding parsed.name | message (unknown parsed.name)
  let some invocation := binding.invocation? parsed.argument | message (noArgument parsed.name)
  invoke invocation

/-- The ex command as it is called: runs the line that is its first
argument, a string (`run`). With anything else first, or nothing, it asks
for the line (`prompt`, labelled `label`), with itself as the continuation
and the ex names that are bound as the candidates:
the answer is then its first argument, and it runs in the view it was asked
from. Where the prompt is refused, because one is open, it says so in the
echo area (`notAsking`). -/
def exCommand (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str line :: _ =>
    run line
  | _ =>
    let candidates : EditorM (Array String) := do
      return Shell.history (← editorState) call.target.window.buffer ++ (← exNames)
    if let .error refusal← prompt label { command := name } (candidates := candidates) then
      message (notAsking refusal)

/-- The name the quit command is registered under. -/
def quitName : String :=
  "quit"

/-- What the echo area says when the quit command was refused: its name,
then why. -/
def notQuitting : QuitRefusal → String
  | .unsaved name => s!"{quitName}: {name} has unsaved changes"

/-- The quit rule, as the quit command and a window's close request run it
("A window's close request", in the module docs): asks the editor to quit
(`quit`, `Editor/Api.lean`), and says a refusal in the echo area
(`notQuitting`). The loop runs it for a close request (`Editor/Loop.lean`,
"Quit"). -/
def closeRequested : EditorM Unit := do
  if let .error refusal← quit then
    message (notQuitting refusal)

/-- The quit command as it is called: asks the editor to quit (`quit`,
`Editor/Api.lean`), and says a refusal in the echo area (`notQuitting`), by
the rule a close request runs (`closeRequested`). It reads nothing of its
call. -/
def quitCommand (_ : Call) : EditorM Unit :=
  closeRequested

/-- The name the save-and-quit command is registered under. -/
def saveQuitName : String :=
  "save-and-quit"

/-- The save-and-quit command as it is called: saves the buffer of the
window it was called with (`Files.save`), and, when that buffer then has a
save in flight, asks the editor to quit, which waits for the save ("Save
and quit", in the module docs). When the save did not start, the save
command's message stays and the editor is not asked. A quit that is
refused, for another buffer, is said in the echo area (`notQuitting`), and
the save goes on. -/
def saveQuitCommand (call : Call) : EditorM Unit := do
  let id := call.target.window.buffer
  Files.save id
  -- The state is read again: the save is in flight only if it started.
  if ((← editorState).buffer? id).any (·.file.any (·.saving.isSome)) then
    if let .error refusal← quit then
      message (notQuitting refusal)

/-- The name the command that reloads the config is registered under. -/
def reloadName : String :=
  "reload-config"

/-- The reload command as it is called: asks for the config to be reloaded
(`reloadConfig`, `Editor/Api.lean`). It says nothing, and reads nothing of
its call. -/
def reloadCommand (_ : Call) : EditorM Unit :=
  reloadConfig

end Editor.Ex
