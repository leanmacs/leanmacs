import Editor.Compile.Contribution

/-!
# The shipped error formats and minor modes of the compile mode

What fits the compile mode to the kinds of project the editor is used on
(`docs/design/keymaps-and-modes.md`, "The compile mode, as built"), as data:
the error formats of rustc and of Lean. Pure, importing only the
contributions' data, and imported by `Editor.lean`, so config can name each
one and build its own from it, as `{ Compile.rustcFormat with … }`.

## The formats

- **`rustcFormat`** (`rustc`): rustc, as cargo prints it. The location is on
  an arrow line, ` --> src/main.rs:4:18`, with any blanks before the arrow,
  the column 1-based; its lead is the line before, `error[E0308]: mismatched
  types`, `warning: unused variable: …`, `note: …` or `help: …`, whose word
  is its severity (`help` a note) and whose text after `: ` is its message.
  The snippet under it, the lines that start, after an optional line number
  and blanks, with `|`, `=` or `:::`, continue it; a blank line or the next
  message ends it.
- **`leanFormat`** (`lean`): Lake's form of Lean's messages, `error:
  ./Foo/Bar.lean:12:4: unknown identifier 'x'`, with `warning` and `info`
  (a note). The line is 1-based and the column 0-based (`columnBase` 0), the
  path may be relative to the package root and may start `./`, which
  `resolve` drops.

The general format reads none of rustc's or Lake's lines: its file stops at
a colon or a space, and a line that starts with a blank, or a word and `: `,
is no `file:line`.

Pinned by `ModelTest.projectFormatChecks`.
-/

namespace Editor.Compile

/-- rustc's error format ("The formats", in the module docs). -/
def rustcFormat : Format :=
  { name := "rustc"
    pattern :=
      [optionalStep [{ atom := .blanks }],
        step
          [{ atom := .literal "-->" }, { atom := .blanks },
            { atom := .noneOf [':'], into := some .file }, { atom := .literal ":" },
            { atom := .digits, into := some .line }],
        optionalStep [{ atom := .literal ":" }, { atom := .digits, into := some .column }]]
    continuation :=
      some
        [optionalStep [{ atom := .digits }], step [{ atom := .blanks }],
          step [{ atom := .oneOf ["|", "=", ":::"] }], step [{ atom := .rest }]]
    lead :=
      some
        [step [{ atom := .oneOf ["error", "warning", "note", "help"], into := some .severity }],
          optionalStep
            [{ atom := .literal "[" }, { atom := .noneOf [']'] }, { atom := .literal "]" }],
          step [{ atom := .literal ": " }, { atom := .rest, into := some .message }]]
    severities := [("error", .error), ("warning", .warning), ("note", .note), ("help", .note)] }

/-- Lean's error format, as Lake prints it ("The formats", in the module
docs). -/
def leanFormat : Format :=
  { name := "lean"
    pattern :=
      [step
          [{ atom := .oneOf ["error", "warning", "info"], into := some .severity },
            { atom := .literal ": " }, { atom := .noneOf [':', ' ', '\t'], into := some .file },
            { atom := .literal ":" }, { atom := .digits, into := some .line },
            { atom := .literal ":" }, { atom := .digits, into := some .column },
            { atom := .literal ": " }, { atom := .rest, into := some .message }]]
    severities := [("error", .error), ("warning", .warning), ("info", .note)]
    columnBase := 0 }

end Editor.Compile
