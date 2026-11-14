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
hold what is no letter. The phase that builds `!` replaces the rule here.

## Where an addition goes

| Addition | Where |
|---|---|
| A part of a line beside its name and argument (a range, `!`) | A field of `Ex.Line`, read by `Ex.parse` |

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

end Editor.Ex
