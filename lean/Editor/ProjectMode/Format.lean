import Editor.Value

/-!
# Error formats, as data

An error format: what says where a tool's output names a file, a line,
maybe a column, and a severity. It is data a minor mode's contribution
carries (`Contribution.formats`, `Editor/ProjectMode.lean`) and config
names and builds, with no editor API. What reads a line with one, the
matcher and the locations it yields, is the compile mode's
(`Editor/Compile/Errors.lean`).

## Why this is a core module that declares names in `Editor.Compile`

The setup port registers contributions, the registry holds them by owner
and the workspace turns a contribution's minor mode on, so the types a
contribution is made of are the core's. They were declared in the compile
mode's modules, which are not core modules (`docs/design/packages.md`), and
moved here so that no core module imports one. Every declaration keeps its
full name (`Editor.Compile.Format`, `Editor.Compile.Severity`, …): config,
the docs and the tests name them, and a move changes only `import` lines.

## Formats are data

An error format (`Format`) is a record: its name; a pattern over one
output line (`Pattern`), whose pieces say which part of the line gives the
file, the line, the column, the severity and the message (`Part`);
optionally a pattern of a following line that continues it
(`continuation`); optionally a pattern of the line before it that gives its
severity and message (`lead`), for a tool that prints the location on the
line after its message, as rustc does; the words that name each severity
(`severities`, `Severity.words` by default) and the severity of a line that
names none (`severity`, an error by default); and what the tool calls the
first column (`columnBase`, 1 by default, as GNU and rustc count; Lean
counts from 0). A field a later format needs is added with a default, so
every existing format is unchanged.

A pattern is a list of steps (`step`, `optionalStep`), each a sequence of
pieces (`Piece`), each an atom (`Atom`) that may capture its text as a
part. How a pattern is matched is the matcher's
(`Editor/Compile/Errors.lean`, "The matcher").

## The general format

`Format.general`, the format every run falls back to; the tool-specific
formats (rustc's, Lean's) ship in `Editor/Compile/Shipped.lean`. It reads
GNU's `file:line:col: message` and `file:line: message`, with an optional
`error`, `warning` or `note` after the location. The file stops at a colon,
a space or a tab, so a compilation's header (`r@main in /r: make`), an
indented help line and its last line are no locations. A line that names
no severity is an error.

## Trees

`optional` and `field` are the two helpers the trees of this vocabulary
are written with: a site's (`Site.encode`, `Editor/Compile/Errors.lean`)
and a listing's entry's (`Listing.Entry`,
`Editor/ProjectMode/Listing.lean`). They are here because this is the one
module both import.

Pinned by `ModelTest.compileErrorChecks`.
-/

namespace Editor.Compile

/-- How bad a location is. -/
inductive Severity where
  /-- An error. -/
  | error
  /-- A warning. -/
  | warning
  /-- A note. -/
  | note
  deriving DecidableEq, Repr

/-- The severity's name, as it crosses in a tree. -/
def Severity.name : Severity → String
  | .error => "error"
  | .warning => "warning"
  | .note => "note"

/-- The severity a name is (`Severity.name`), if it is one. -/
def Severity.ofName? : String → Option Severity
  | "error" => some .error
  | "warning" => some .warning
  | "note" => some .note
  | _ => none

/-- The words that name each severity, as GNU's tools write them. -/
def Severity.words : List (String × Severity) :=
  [("error", .error), ("warning", .warning), ("note", .note)]

/-- What a captured piece's text gives. -/
inductive Part where
  /-- The file. -/
  | file
  /-- The line. -/
  | line
  /-- The column. -/
  | column
  /-- The severity's word. -/
  | severity
  /-- The location's message. -/
  | message
  deriving DecidableEq, Repr

/-- What one piece of a pattern matches. -/
inductive Atom where
  /-- Exactly `text`. -/
  | literal (text : String)
  /-- One or more of `0` to `9`. -/
  | digits
  /-- One or more spaces or tabs. -/
  | blanks
  /-- One or more characters, none of them in `excluded`. -/
  | noneOf (excluded : List Char)
  /-- One of `words`, tried in order. -/
  | oneOf (words : List String)
  /-- Every character to the line's end, maybe none. -/
  | rest
  deriving DecidableEq, Repr

/-- A piece of a pattern: an atom, and the part its text gives, if any. -/
structure Piece where
  /-- What it matches. -/
  atom : Atom
  /-- The part its text gives. -/
  into : Option Part := none
  deriving DecidableEq, Repr

/-- A step of a pattern: pieces in sequence, all of them or, for an
optional step, maybe none. -/
structure Step where
  /-- Its pieces. -/
  pieces : List Piece
  /-- Whether it may be skipped. -/
  optional : Bool := false
  deriving DecidableEq, Repr

/-- A pattern over one line, anchored at both ends ("The matcher", in the
module docs). -/
abbrev Pattern :=
  List Step

/-- An error format ("Formats are data", in the module docs). -/
structure Format where
  /-- Its name. -/
  name : String
  /-- The pattern of a location's line. -/
  pattern : Pattern
  /-- The pattern of a following line that continues a location. -/
  continuation : Option Pattern := none
  /-- The words that name each severity. -/
  severities : List (String × Severity) := Severity.words
  /-- The severity of a line with no severity part, or a word not in
  `severities`. -/
  severity : Severity := .error
  /-- What the tool calls the first column. -/
  columnBase : Nat := 1
  /-- The pattern of the line before a location's line that gives its
  severity and message, as rustc prints `error[E0308]: mismatched types`
  before ` --> src/main.rs:4:18`; none for a format whose location is on its
  message's line. -/
  lead : Option Pattern := none
  deriving DecidableEq, Repr

/-- A step of the pieces `pieces`. -/
def step (pieces : List Piece) : Step :=
  { pieces }

/-- An optional step of the pieces `pieces`. -/
def optionalStep (pieces : List Piece) : Step :=
  { pieces, optional := true }

/-- The general format ("The general format", in the module docs). -/
def Format.general : Format :=
  { name := "general"
    pattern :=
      [step
          [{ atom := .noneOf [':', ' ', '\t'], into := some .file }, { atom := .literal ":" },
            { atom := .digits, into := some .line }],
        optionalStep [{ atom := .literal ":" }, { atom := .digits, into := some .column }],
        step [{ atom := .literal ":" }],
        optionalStep
          [{ atom := .blanks },
            { atom := .oneOf ["error", "warning", "note"], into := some .severity },
            { atom := .literal ":" }],
        step [{ atom := .rest }]] }

/-- An optional value as a tree: `null` for none. -/
def optional {α : Type} (encode : α → Value) : Option α → Value
  | some value => encode value
  | none => .null

/-- The field `name` of `fields`. -/
def field (fields : List (String × Value)) (name : String) : Value :=
  ((fields.find? (·.1 == name)).map (·.2)).getD .null

end Editor.Compile
