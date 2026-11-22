import Editor.Api
import Editor.Command.Call
import Editor.Ex.Line
import Editor.Package
import FilesApi

/-!
# The kit's ex line: a hand-written ex line over the core's ex line data

A stand-in for the `ex` package that a package's tests, and the core's own,
may register: a command `ex` written here over the core's ex line as data
(`Editor/Ex/Line.lean`: `Ex.parse`, `Ex.Range.resolve`,
`Ex.Binding.invocation?`) and the core's API (`exBinding`, `invoke`,
`prompt`), as the kit's minibuffer is written over the core's prompt. It
imports no module of the ex line's feature, so a test that types an ex line
names nothing of it.

It holds what its users type:

- **A line is parsed and run through its binding**: the command the
  registry binds the line's name to is asked to run after this one, with
  the line's argument.
- **What is wrong with a line is said in the echo area**, by this module's
  own texts: a name nobody bound (`ExLine.unknown`), an argument for a name
  that takes none (`ExLine.noArgument`), a range before a name
  (`ExLine.noRange`), and a range that resolves to no lines.
- **A bang line is handed to the shell's commands**, named here as text
  since a core module imports no interface package: `shell-command` with
  the text and the line, or, with a range, `shell-filter` with the range
  resolved against the target's buffer, the text and the line. A bang with
  no command is said (`ExLine.noCommand`).
- **With no line, it asks for one**, in a prompt labelled `:`
  (`ExLine.label`), with itself as the continuation. It offers no
  candidates: the ex line's history and names are the ex package's sources.

`exLinePackage` registers that command under `ex` (`ExLine.name`) and the ex
names files' and the buffers' tests type, each bound as the ex package
binds it: `w` and `w!` to `save-buffer`, `e` and `e!` to `edit-file`,
`autoread` and `noautoread` to `auto-reload-mode` (`files-api`'s names,
which the core holds), and `b`, `ls` and `bd` to `switch-buffer`,
`list-buffers` and `close-buffer` (the buffers' names, as text).

It holds no checks. It is pinned by the checks that type through it, in
the packages `buffers`, `files`, `shell`, `compile` and `evil`, and the ex
package's own check holds the real ex line to the same lines. Which ex
names the ex package binds, and to what, is ex's (`ModelTest.exChecks`, the
fixture `tests/headless/ex`); this module copies the ones its users type,
and nothing else (no `q`, `wq` or `reload`).
-/

namespace Editor.Test

open Editor

namespace ExLine

/-- The name the kit's ex command is registered under. -/
def name : String :=
  "ex"

/-- The label of the prompt the kit's ex command asks for its line with. -/
def label : String :=
  ":"

/-- What the echo area says when a line's name is one nobody bound. -/
def unknown (name : String) : String :=
  s!"{name}: not an ex command"

/-- What the echo area says when a line gives an argument to a name that
takes nothing. -/
def noArgument (name : String) : String :=
  s!"{name}: takes no argument"

/-- What the echo area says when a line gives a range to a name, or is a
range alone. -/
def noRange (name : String) : String :=
  s!"{name}: takes no range"

/-- What the echo area says for a bang line with no command after it. -/
def noCommand : String :=
  "!: no command"

/-- The name of the command a bang line with no range is handed to: the
shell's, as text. -/
def shellCommandName : String :=
  "shell-command"

/-- The name of the command a bang line with a range is handed to: the
shell's, as text. -/
def shellFilterName : String :=
  "shell-filter"

/-- How many lines the text of `target`'s buffer has, and the line of its
primary cursor, from 1, no further than the last. -/
def linesOf (target : Target) : TextM (Nat × Nat) := do
  let text := target.buffer.text
  let count ← text.lineCount
  let selection ← target.selection
  let head := (selection.ranges[selection.primary]?).map (·.head) |>.getD 0
  return (count, min count ((← text.pointOf head).row + 1))

/-- Runs the ex line `line`, typed in the view of `target` (the module
docs). A line that is empty or all white space runs nothing. -/
def run (target : Target) (line : String) : EditorM Unit := do
  let some parsed := Ex.parse line | return
  let typed := Ex.trimmed line
  if parsed.bang then
    match parsed.range, parsed.argument with
    | _, none =>
      message noCommand
    | none, some text =>
      invoke { command := shellCommandName, arguments := [.str text, .str typed] }
    | some range, some text =>
      let (count, current) ← linesOf target
      match range.resolve current count with
      | .error why =>
        message s!"{typed}: {why}"
      | .ok (first, last) =>
        invoke
            { command := shellFilterName
              arguments := [.nat first, .nat last, .str text, .str typed] }
    return
  if parsed.range.isSome then
    message (noRange parsed.name)
    return
  let some binding ← exBinding parsed.name | message (unknown parsed.name)
  let some invocation := binding.invocation? parsed.argument | message (noArgument parsed.name)
  invoke invocation

/-- The kit's ex command as it is called: runs the line that is its first
argument, a string, in the view it was called with (`run`). With anything
else first, or nothing, it asks for the line (`prompt`, labelled `label`),
with itself as the continuation; where the prompt is refused it says so in
the echo area, after its name. -/
def exCommand (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str line :: _ =>
    run call.target line
  | _ =>
    if let .error refusal← prompt label { command := name } then
      message s!"{name}: {refusal.describe}"

end ExLine

/-- The kit's ex line (the module docs): a package named `ex` that
registers the kit's ex command and the ex names of files and the
buffers. -/
def exLinePackage : Package :=
  { name := "ex"
    setup := do
      commandWith ExLine.name ExLine.exCommand
      Editor.exCommand "w" FilesApi.saveName
      Editor.exCommand "w!" FilesApi.saveName (arguments := [.bool true])
      Editor.exCommand "e" FilesApi.editName (takes := .text)
      Editor.exCommand "e!" FilesApi.editName (takes := .text) (arguments := [.bool true])
      Editor.exCommand "autoread" FilesApi.autoReloadName (arguments := [.bool true])
      Editor.exCommand "noautoread" FilesApi.autoReloadName (arguments := [.bool false])
      Editor.exCommand "b" "switch-buffer" (takes := .text)
      Editor.exCommand "ls" "list-buffers"
      Editor.exCommand "bd" "close-buffer" (takes := .text) }

end Editor.Test
