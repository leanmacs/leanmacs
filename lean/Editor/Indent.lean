import Editor.Command

/-!
# Indentation from a syntax tree

The indent level of each row of a text, from the captures of the indents
query its major mode's text keeps (`Mode.SyntaxTree.indents`,
`Editor/Highlight.lean`): a primitive Lean's indent commands use. The rule
(`Indent.rule`) is pure and lives here alone; the library only answers the
query's captures as plain rows (`SyntaxTree.capturesOf`), and has no indent
rule of its own (`docs/design/rust-library.md`, "Injections, indentation
and text objects, as built").

## The rule (`Indent.rule`)

It reads captures named `indent.begin`, `indent.branch` and `indent.ignore`
(nvim-treesitter's names, so a config author can read them; the rule is
ours), and ignores every other name. A node's rows are the row it starts on
through the row of its last byte, so a node that ends at a row's start does
not reach that row. For a row `r`:

1. **None**, "keep the row's indent", when `r` lies after the first row of
   a node captured `indent.ignore` and within its rows: a row inside a
   multi-line string or block comment.
2. **Otherwise the level**: the number of distinct start rows of the nodes
   captured `indent.begin` that start on a row before `r` and whose rows
   reach `r` (nodes that begin on one row count once), less one when the
   row's first non-blank is where a node captured `indent.branch` starts (a
   closing bracket), and never below 0.

A blank row gets a level by the same rule: the level a line typed there
would have.

## The primitive (`TextId.indentLevels`)

`indentLevels text first last` gives each row from `first` through `last`
its level, from a snapshot of the text: the kept indents query's captures
over the bytes from the first row's start to the last row's end, widened by
a position at each end where the text has one, so every node that encloses
a row shares a byte with the range, an empty one too; each row's start and
first non-blank, and each capture's first and last rows, from the text
port; then the rule. A refusal is a value: `notAttached`, `noQuery` (the
text keeps no indents query), or `notParsed` (the tree of the text's last
edit is not delivered yet; the caller keeps the row's indent). The levels
are counts: turning one into columns (the indent's width, tabs) is the
caller's.

Not built here: the evil `=` operator and indenting on a line break, which
are task `syntax-done-signal-mode-and-indent-operator`'s.

Pinned by `ModelTest.indentRuleChecks` (the rule, pure),
`ModelTest.indentLevelChecks` (the primitive, on the editor's models) and,
real-only, by `ContractTest`'s check of the Rust fixture
`tests/syntax/rust/indent.rs`, whose levels are its own indentation.
-/

namespace Editor.Indent

/-- The capture names the rule reads. -/
def names : List String :=
  ["indent.begin", "indent.branch", "indent.ignore"]

/-- A node a capture of the indents query captured, as the rule reads it:
the capture's name, where the node starts, and its first and last rows. -/
structure Captured where
  /-- The capture's name. -/
  name : String
  /-- The offset the node starts at. -/
  start : Nat
  /-- The row it starts on. -/
  firstRow : Nat
  /-- The row of its last byte; its first row for an empty node. -/
  lastRow : Nat
  deriving DecidableEq, Repr

/-- A row the rule gives a level: which row, and where its first non-blank
is (where its content ends on a blank row). -/
structure Line where
  /-- The row. -/
  row : Nat
  /-- The offset of its first non-blank. -/
  firstNonBlank : Nat
  deriving DecidableEq, Repr

/-- Whether `node` holds row `row` after its first row. -/
def Captured.holdsAfterFirst (node : Captured) (row : Nat) : Bool :=
  node.firstRow < row && row ≤ node.lastRow

/-- The level of each of `lines`, in order, by the rule of the module docs,
from `captured`; `none` for a row whose indent is kept. -/
def rule (captured : Array Captured) (lines : Array Line) : Array (Option Nat) :=
  lines.map fun line =>
    let ignored :=
      captured.any fun node => node.name == "indent.ignore" && node.holdsAfterFirst line.row
    if ignored then none
    else
      let begins :=
        captured.filterMap fun node =>
          if node.name == "indent.begin" && node.holdsAfterFirst line.row then some node.firstRow
          else none
      let level := (begins.toList.eraseDups).length
      let branch :=
        captured.any fun node => node.name == "indent.branch" && node.start == line.firstNonBlank
      some (if branch then level - 1 else level)

end Indent

/-- The indent level of each row of `text` from `first` through `last`, by
the indents query its text keeps (`Indent.rule`, "The primitive" in
`Editor/Indent.lean`): `none` for a row whose indent is kept. A row past the
text's last is left out. Refused, as a value, with `notAttached`, `noQuery`
or `notParsed`. -/
def TextId.indentLevels (text : TextId) (first last : Nat) :
    EditorM (Except SyntaxTreeError (Array (Option Nat))) :=
  text.withSnapshot fun snapshot => do
    let rows ← text.rowCount
    let last := min last (rows - 1)
    if first > last then
      return .ok #[]
    let length ← text.byteLength
    let firstStart ← text.offsetOf { row := first, column := 0 }
    let lastEnd ← text.motion .lineEnd (← text.offsetOf { row := last, column := 0 })
    let start ←
      if firstStart > 0 then
        text.motion .previousCell firstStart
      else
        pure 0
    let stop ←
      if lastEnd < length then
        text.motion .nextCell lastEnd
      else
        pure lastEnd
    match ← SyntaxTree.lift (SyntaxTree.capturesOf snapshot .indents start stop) with
    | .error refusal =>
      return .error refusal
    | .ok kept =>
      let mut captured := #[]
      for capture in kept.captures do
        let some name := kept.names[capture.capture]? | continue
        unless Indent.names.contains name do
          continue
        let firstRow := (← text.pointOf capture.start).row
        let lastByte ←
          if capture.stop > capture.start then
            text.motion .previousCell capture.stop
          else
            pure capture.start
        captured :=
          captured.push
            { name, start := capture.start, firstRow, lastRow := (← text.pointOf lastByte).row }
      let mut lines := #[]
      for row in [first:last + 1] do
        let rowStart ← text.offsetOf { row, column := 0 }
        lines := lines.push { row, firstNonBlank := ← text.motion .lineFirstNonBlank rowStart }
      return .ok (Indent.rule captured lines)

end Editor
