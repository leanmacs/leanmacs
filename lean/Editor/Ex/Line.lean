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

`Ex.parse` takes a line to its range, its name and its argument
(`Ex.Line`):

- **Leading and trailing white space is dropped.** White space is ASCII's:
  a space, a tab, a carriage return and a line feed (`Char.isWhitespace`).
- **A range may come first** (`Ex.Range`), Vim's line range as far as `:!`
  needs one: `%`, the whole buffer (`1,$`); or an address, `a,b` of two of
  them, where an address (`Ex.Address`) is `.`, the cursor's line, `$`,
  the last line, or a line number. One address is that line to itself, and
  an address left out beside the comma is the cursor's line, as in Vim:
  `,5` is `.,5` and `3,` is `3,.`. Line 0 and a
  range that runs backwards are read as they are: resolving the range
  refuses them (`Range.resolve`). White space may follow the range.
- **A line whose first character after its range is `!` is the bang form**
  (`Line.bang`): its name is `!`, and the rest of the line, with the white
  space round it dropped, is its argument, `none` when nothing is left.
  `:!cmd` is a shell command and `:{range}!cmd` a filter
  (`Editor/Shell.lean`). Only a leading `!` starts it: `w!` is the name
  `w!`, as before.
- **Otherwise the name is everything up to the first white space.** So a
  name may hold a hyphen or a digit after its first character, as a name
  config registers may, and a mark after letters is part of the name:
  `w!` is the name `w!`, not `w` with a `!`. A leading colon is not dropped
  either: `:w` is the name `:w`.
- **The argument is the rest**, with the white space before it dropped,
  kept whole: the spaces inside it are part of it, and nothing is escaped
  or expanded. `e /tmp/my notes.txt` has the argument `/tmp/my notes.txt`.
  It is `none` when nothing is left.
- **A line that is empty or all white space is no line** (`none`). A range
  with nothing after it is a line with an empty name.

**A name config registers must read back as itself** (`Ex.reachable`):
`Ex.parse name` is that name, with no range, no bang and no argument. So a
name that is empty, holds white space or starts with `!`, `%`, `.`, `$`,
`,` or a digit cannot be typed, and `exCommand` refuses it
(`Editor/Setup.lean`). `w!` and `e!` ship as names of their own, each
bound with a fixed argument (`Editor/Ex/Compiled.lean`).

Vim's `#` and `:!!` are not built, nor any address but the four above
(no marks, patterns or offsets).

## Resolving a range

`Range.resolve range current count` is the first and the last line a range
stands for, from 1, over a buffer of `count` lines whose cursor is on line
`current`. A buffer's lines are its rows, but for the empty row after a last
line feed (`lineCount`): `b`, `c`, `a`, each with its line feed, is three
lines, and the empty text is one. It refuses, as a sentence:

- line 0 (`lineZero`);
- a line past the last (`pastEnd`): `line 7 is past the end of the buffer
  (3 lines)`, the first such address's;
- a range whose first line is after its last (`backwards`).

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
| A part of a line beside its name and argument | A field of `Ex.Line`, read by `Ex.parse` |
| A kind of address (a mark, a pattern) | A constructor of `Ex.Address`, read by `Ex.parse` and resolved by `Range.resolve` |
| A kind of argument an ex name takes (a file) | A variant of `Ex.Takes`, with its case in `Binding.invocation?` |

Pinned by `ModelTest.exLineChecks`.
-/

namespace Editor.Ex

/-- One end of a line range. -/
inductive Address where
  /-- `.`: the cursor's line. -/
  | current
  /-- `$`: the last line. -/
  | last
  /-- A line number, from 1. -/
  | line (n : Nat)
  deriving DecidableEq, Repr

/-- A line range: its first and its last line. `%` is `1,$`. -/
structure Range where
  /-- The first line. -/
  start : Address
  /-- The last line. -/
  stop : Address
  deriving DecidableEq, Repr

/-- An ex line: its range, its name, and the rest of it. -/
structure Line where
  /-- The ex name: the line's first word after its range, or `!` for the
  bang form. -/
  name : String
  /-- The rest of the line, with the white space round it dropped; `none`
  when nothing follows the name. -/
  argument : Option String := none
  /-- The line range before the name, if one is given. -/
  range : Option Range := none
  /-- Whether this is the bang form: `!` first after the range. -/
  bang : Bool := false
  deriving DecidableEq, Repr

/-- The digits `chars` starts with, as a number, and what follows them;
`none` when it starts with no digit. -/
def digitsOf (chars : List Char) : Option (Nat × List Char) :=
  let digits := chars.takeWhile Char.isDigit
  if digits.isEmpty then none
  else
    some
      (digits.foldl (fun n digit => 10 * n + (digit.toNat - '0'.toNat)) 0,
        chars.dropWhile Char.isDigit)

/-- The address `chars` starts with, and what follows it. -/
def addressOf : List Char → Option (Address × List Char)
  | '.' :: rest => some (.current, rest)
  | '$' :: rest => some (.last, rest)
  | chars => (digitsOf chars).map fun (n, rest) => (.line n, rest)

/-- The range `chars` starts with, and what follows it ("The line", in the
module docs). -/
def rangeOf : List Char → Option (Range × List Char)
  | '%' :: rest => some ({ start := .line 1, stop := .last }, rest)
  | chars =>
    let (first, rest) :=
      match addressOf chars with
      | some (address, rest) => (some address, rest)
      | none => (none, chars)
    match first, rest with
    | _, ',' :: after =>
      let start := first.getD .current
      match addressOf after with
      | some (stop, rest) => some ({ start, stop }, rest)
      | none => some ({ start, stop := .current }, after)
    | some start, rest => some ({ start, stop := start }, rest)
    | none, _ => none

/-- `line` with the white space round it dropped. -/
def trimmed (line : String) : String :=
  let blank (char : Char) : Bool := char.isWhitespace
  String.ofList ((line.toList.dropWhile blank).reverse.dropWhile blank).reverse

/-- The ex line `line` is ("The line", in the module docs): its range, if it
starts with one; then, for `!` first after it, the bang form, named `!`,
with the rest as its argument; otherwise its first word as the name and the
rest as the argument, with the white space round each dropped. `none` for a
line that is empty or all white space. -/
def parse (line : String) : Option Line :=
  let blank (char : Char) : Bool := char.isWhitespace
  let trimmed := (Ex.trimmed line).toList
  if trimmed.isEmpty then none
  else
    let (range, rest) :=
      match rangeOf trimmed with
      | some (range, rest) => (some range, rest.dropWhile blank)
      | none => (none, trimmed)
    let argumentOf (chars : List Char) : Option String :=
      let chars := chars.dropWhile blank
      if chars.isEmpty then none else some (String.ofList chars)
    match rest with
    | '!' :: after => some { name := "!", argument := argumentOf after, range, bang := true }
    | _ =>
      let name := rest.takeWhile (!blank ·)
      some { name := String.ofList name, argument := argumentOf (rest.dropWhile (!blank ·)), range }

/-- Whether the ex name `name` can be typed: the ex line reads it back as
that name, with no range, no bang and no argument ("The line", in the
module docs). -/
def reachable (name : String) : Bool :=
  parse name == some { name }

/-- What resolving a range says of line 0. -/
def lineZero : String :=
  "line 0 is before the first line"

/-- What resolving a range says of the line `line`, past the last of a
buffer of `count` lines. -/
def pastEnd (line count : Nat) : String :=
  s!"line {line} is past the end of the buffer ({count} {if count == 1 then "line" else "lines"})"

/-- What resolving a range says of one whose first line, `start`, is after
its last, `stop`. -/
def backwards (start stop : Nat) : String :=
  s!"the range {start},{stop} runs backwards"

/-- How many lines `text` has: its rows, but for the empty row after a last
line feed ("Resolving a range", in the module docs). -/
def lineCount (text : String) : Nat :=
  let rows := (text.toList.filter (· == '\n')).length + 1
  if text.endsWith "\n" then rows - 1 else rows

/-- How many lines a text of `rows` rows whose last row is `lastRow` has:
`lineCount` of it, asked of a text's rows. -/
def lineCountOf (rows : Nat) (lastRow : String) : Nat :=
  if rows > 1 && lastRow.isEmpty then rows - 1 else rows

/-- The line `address` stands for, with the cursor on line `current` of a
buffer of `count` lines. -/
def Address.resolve (address : Address) (current count : Nat) : Nat :=
  match address with
  | .current => current
  | .last => count
  | .line n => n

/-- The first and the last line `range` stands for, from 1, with the cursor
on line `current` of a buffer of `count` lines; or why it stands for none
("Resolving a range", in the module docs). -/
def Range.resolve (range : Range) (current count : Nat) : Except String (Nat × Nat) :=
  let start := range.start.resolve current count
  let stop := range.stop.resolve current count
  if start == 0 || stop == 0 then .error lineZero
  else
    if start > count then .error (pastEnd start count)
    else
      if stop > count then .error (pastEnd stop count)
      else if start > stop then .error (backwards start stop) else .ok (start, stop)

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
