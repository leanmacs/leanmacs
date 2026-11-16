import Editor.Invocation

/-!
# An ex line

What a user answers the ex prompt with, as data: the line `e notes.txt` is
the *ex name* `e` and the argument `notes.txt`
(`docs/design/keymaps-and-modes.md`, "The ex command line"). Parsing a line
is here, and it is pure: it asks nothing of the editor. What a name runs is
the registry's (`Editor/Config/Registry.lean`), and running a line is the
ex command's (`Editor/Ex.lean`).

## The line

`Ex.parse` takes a line to its name and its argument (`Ex.Line`):

- **Leading and trailing white space is dropped.** White space is ASCII's:
  a space, a tab, a carriage return and a line feed (`Char.isWhitespace`).
- **The name is everything up to the first white space.** So a name may
  hold a hyphen or a digit, as a name config registers may, and a mark
  after letters is part of the name: `w!` is the name `w!`, not `w` with a
  `!`. A leading colon is not dropped either: `:w` is the name `:w`.
- **The argument is the rest**, with the white space before it dropped,
  kept whole: the spaces inside it are part of it, and nothing is escaped
  or expanded. `e /tmp/my notes.txt` has the argument `/tmp/my notes.txt`.
  It is `none` when nothing is left.
- **A line that is empty or all white space is no line** (`none`).

Vim's rule, a run of letters and then the rest (`w!`, `e#`, `w>>file`),
is not built: `!`, ranges and `#` are not, and a name config registers may
hold what is no letter. `w!` and `e!` ship as names of their own, each
bound with a fixed argument (`Editor/Ex/Compiled.lean`). The phase that
builds `!` replaces the rule here.

## The binding

An ex name is bound to a command's name (`Ex.Binding`), as a key sequence
is: it is no second kind of program. The binding says what the name takes
after it (`Ex.Takes`): nothing, or text; and it may carry arguments of its
own (`Binding.arguments`), which the command is always handed first: that
is how `e!` hands `edit-file` its force.

`Binding.invocation?` is the invocation a line of the binding's name runs:

- with no argument, the command with the binding's own arguments alone,
  whatever the binding takes;
- with an argument and a binding that takes text, the command with the
  binding's own arguments and then the line's argument, a string. That is
  where a prompt's answer goes (`prompt`, `Editor/Api.lean`), so a command
  that asks for a string when it is given none is an ex command as it
  stands;
- with an argument and a binding that takes nothing, `none`: the line is
  refused before anything runs, and the command is never handed a string
  it would ignore.

This module imports `Editor/Invocation.lean` alone, which is plain data, so
the registry and the state requests import it without anything of the loop
or the state.

## Where an addition goes

| Addition | Where |
|---|---|
| A part of a line beside its name and argument (a range, `!`) | A field of `Ex.Line`, read by `Ex.parse` |
| A kind of argument an ex name takes (a file) | A variant of `Ex.Takes`, with its case in `Binding.invocation?` |

Pinned by `ModelTest.exLineChecks`.
-/

namespace Editor.Ex

/-- An ex line: its name, and the rest of it. -/
structure Line where
  /-- The ex name: the line's first word. -/
  name : String
  /-- The rest of the line, with the white space round it dropped; `none`
  when nothing follows the name. -/
  argument : Option String := none
  deriving DecidableEq, Repr

/-- The ex line `line` is: its first word as the name, and the rest, with
the white space round it dropped, as the argument. `none` for a line that
is empty or all white space. -/
def parse (line : String) : Option Line :=
  let blank (char : Char) : Bool := char.isWhitespace
  let trimmed := ((line.toList.dropWhile blank).reverse.dropWhile blank).reverse
  let name := trimmed.takeWhile (!blank ·)
  let rest := (trimmed.dropWhile (!blank ·)).dropWhile blank
  if name.isEmpty then none
  else
    some
      { name := String.ofList name
        argument := if rest.isEmpty then none else some (String.ofList rest) }

/-- What an ex name takes after it on the line. -/
inductive Takes where
  /-- Nothing: a line with an argument is refused. -/
  | nothing
  /-- Text: the line's argument, whole, or none. -/
  | text
  deriving DecidableEq, Repr

/-- An ex binding: an ex name bound to a command's name, with what the name
takes. -/
structure Binding where
  /-- The ex name. -/
  name : String
  /-- The name of the command the ex name runs, looked up when the line is
  run. -/
  command : String
  /-- What the ex name takes after it. -/
  takes : Takes := .nothing
  /-- The arguments the command is always handed, before the line's own:
  how `e!` hands `edit-file` its force. -/
  arguments : List Argument := []
  deriving DecidableEq, Repr

/-- The invocation a line of this binding's name with `argument` runs; `none`
for an argument the binding does not take. The binding's own arguments come
first. -/
def Binding.invocation? (binding : Binding) : Option String → Option Invocation
  | none => some { command := binding.command, arguments := binding.arguments }
  | some argument =>
    match binding.takes with
    | .nothing => none
    | .text =>
      some { command := binding.command, arguments := binding.arguments ++ [.str argument] }

end Editor.Ex
