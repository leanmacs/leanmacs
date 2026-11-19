import Editor.Json
import Editor.ProjectMode

/-!
# The shipped error formats and minor modes of the compile mode

What fits the compile mode to the kinds of project the editor is used on
(`docs/design/keymaps-and-modes.md`, "The compile mode, as built"), as data:
the error formats of rustc and of Lean, the reading of mise's task list, and
`cargo-mode`, `lake-mode` and `mise-mode`, which use them.
Pure, importing only the contributions' data and the JSON reader
(`Editor/Json.lean`), and imported by `Editor.lean`, so config can name each
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

## The modes

The contributions that ship (`shipped`), which the `compile` package
registers (`Compile/Compiled.lean`), so config's contribution of the
same name replaces one:

- **`cargo-mode`** (`cargoMode`): marker `Cargo.toml`, outermost, so in a
  member crate its root is the Cargo workspace's, where cargo's
  workspace-relative paths resolve; `build`, `test` and `clippy`, as `cargo
  build`, `cargo test` and `cargo clippy`; rustc's format.
- **`lake-mode`** (`lakeMode`): marker `lakefile.lean` or `lakefile.toml`;
  `build` and `test`, as `lake build` and `lake test`; Lean's format.
- **`mise-mode`** (`miseMode`): marker `mise.toml` or `.mise.toml`; its
  commands are computed (`Contribution.listing`): `mise tasks ls --json`,
  run by bare name on the child's `PATH` in the root, gives one command a
  task (`miseTasks`). It has no format of its own: a task's output is read
  by the other on-modes' formats and the general one, so `mise run test` in
  a Cargo crate inside a mise project reads rustc's errors through
  `cargo-mode`.

## mise's task list

`miseTasks` reads what `mise tasks ls --json` prints: a JSON array of
objects, one per task, each with a non-empty string `name` and, as a
non-empty string, the `dir` it runs in, among many other fields, which are
ignored. Each task is a named command of its name, whose line is `mise run`
and the name as one shell word (`shellWord`: bare when every character is
an ASCII letter or digit or one of `_ - . : / @ % + = ,`, else
single-quoted, a `'` written `'\''`), run in its `dir`. A name listed twice
keeps its first; `[]` gives none. Anything else is refused with why: `it is
not an array`, `task <n> is not an object`, `task <n> has no name`, or the
JSON reader's own reason.

Pinned by `CompileTest.projectFormatChecks`, `CompileTest.miseTaskChecks` and
`CompileTest.projectModeChecks`, on the models, and over the real process
service, with fixture programs standing in for cargo, lake, mise and git, by
`CompileTest.projectRunChecks`.
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

/-- `word` as one word of a shell's command line ("mise's task list", in
the module docs). -/
def shellWord (word : String) : String :=
  let bare (char : Char) : Bool := char.isAlphanum || "_-.:/@%+=,".contains char
  if !word.isEmpty && word.all bare then word else "'" ++ word.replace "'" "'\\''" ++ "'"

/-- The named commands of mise's task list `bytes` ("mise's task list", in
the module docs), or why it gives none. -/
def miseTasks (bytes : ByteArray) : Except String (Array NamedCommand) := do
  let .array tasks ← Json.parse bytes | throw "it is not an array"
  let mut commands : Array NamedCommand := #[]
  for (task, index) in tasks.zipIdx do
    let .object _ := task | throw s!"task {index + 1} is not an object"
    let some (.string name) := task.field? "name" | throw s!"task {index + 1} has no name"
    if name.isEmpty then
      throw s!"task {index + 1} has no name"
    let directory : Option System.FilePath :=
      match task.field? "dir" with
      | some (.string dir) => if dir.isEmpty then none else some dir
      | _ => none
    unless commands.any (·.name == name) do
      commands := commands.push { name, line := "mise run " ++ shellWord name, directory }
  return commands

/-- `cargo-mode` ("The modes", in the module docs). -/
def cargoMode : Contribution :=
  { mode := "cargo-mode", markers := #["Cargo.toml"], outermost := true
    commands :=
      #[{ name := "build", line := "cargo build" }, { name := "test", line := "cargo test" },
        { name := "clippy", line := "cargo clippy" }]
    formats := #[rustcFormat] }

/-- `lake-mode` ("The modes", in the module docs). -/
def lakeMode : Contribution :=
  { mode := "lake-mode", markers := #["lakefile.lean", "lakefile.toml"]
    commands :=
      #[{ name := "build", line := "lake build" }, { name := "test", line := "lake test" }]
    formats := #[leanFormat] }

/-- `mise-mode` ("The modes", in the module docs). -/
def miseMode : Contribution :=
  { mode := "mise-mode", markers := #["mise.toml", ".mise.toml"]
    listing :=
      some { program := "mise", arguments := #["tasks", "ls", "--json"], read := miseTasks } }

/-- The contributions that ship, in registration order. -/
def shipped : Array Contribution :=
  #[cargoMode, lakeMode, miseMode]

end Editor.Compile
