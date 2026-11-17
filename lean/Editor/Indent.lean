import Editor.Command
import Editor.Language.IndentUnit

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

/-- The capture names the rules read: the row rule and the opening rule
read the first four, and the primitives widen what they ask by the last. -/
def names : List String :=
  ["indent.begin", "indent.branch", "indent.ignore", "indent.open", "indent.incomplete"]

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
          -- An opening bracket the tree did not close reaches every later row.
          else if node.name == "indent.open" && node.firstRow < line.row then some node.firstRow
          else none
      let level := (begins.toList.eraseDups).length
      let branch :=
        captured.any fun node => node.name == "indent.branch" && node.start == line.firstNonBlank
      some (if branch then level - 1 else level)

/-- A node a capture of the indents query captured, as the opening rule
reads it: the capture's name and the offsets the node starts and stops
at. -/
structure Node where
  /-- The capture's name. -/
  name : String
  /-- The offset the node starts at. -/
  start : Nat
  /-- The offset it stops at, not included. -/
  stop : Nat
  deriving DecidableEq, Repr

/-- Where a new line opens: the offset of the text before the line break
it is opened at, and the offset of the first non-blank after it on its row
that moves to the new row, if one does. -/
structure Opening where
  /-- Where the line break goes. -/
  offset : Nat
  /-- The first non-blank after `offset` on its row, which moves to the new
  row: none when the new row is empty. -/
  firstNonBlank : Option Nat := none
  deriving DecidableEq, Repr

/-- What the opening rule ("The opening rule", in the module docs) counts
of `nodes` for a line opened at `opening`: `none`, add nothing, when the
position is inside a node captured `indent.ignore`; otherwise the starts of
the nodes that count, and whether a node captured `indent.branch` starts at
the first non-blank that moves to the new row. -/
def openingCounts (nodes : Array Node) (opening : Opening) : Option (Array Nat × Bool) :=
  let at_ := opening.offset
  if nodes.any fun node => node.name == "indent.ignore" && node.start < at_ && at_ < node.stop then
    none
  else
    let counted :=
      nodes.filterMap fun node =>
        if node.name == "indent.begin" && node.start < at_ && at_ < node.stop then some node.start
        else if node.name == "indent.open" && node.start < at_ then some node.start
        else none
    let branch :=
      match opening.firstNonBlank with
      | some first => nodes.any fun node => node.name == "indent.branch" && node.start == first
      | none => false
    some (counted, branch)

/-- The level of a new line whose counted nodes start on `rows`: the number
of distinct rows, less one for a `branch`, and never below 0. -/
def levelOf (rows : Array Nat) (branch : Bool) : Nat :=
  let level := rows.toList.eraseDups.length
  if branch then level - 1 else level

/-- Where a question of the indents query asked from `start` is asked
again from, so the bare brackets an incomplete node holds are seen: the
earliest start of the nodes of `nodes` captured `indent.incomplete`, or
`start` when that is earlier. -/
def widenedStart (nodes : Array Node) (start : Nat) : Nat :=
  nodes.foldl (fun least node => if node.name == "indent.incomplete" then min least node.start else least)
    start

/-- `level` levels of `unit`: that many times the unit's spaces, or that
many tabs. -/
def whitespace (unit : Language.IndentUnit) (level : Nat) : String :=
  match unit with
  | .spaces count => String.ofList (List.replicate (level * count) ' ')
  | .tab => String.ofList (List.replicate level '\t')

/-- A row as the re-indent reads it: where it starts, where its first
non-blank is (where its content ends on a blank row), where its content
ends, the whitespace before its first non-blank, and its level, `none` for
a row whose indent is kept. -/
structure Row where
  /-- The offset it starts at. -/
  start : Nat
  /-- The offset of its first non-blank, or of its content's end on a blank
  row. -/
  firstNonBlank : Nat
  /-- The offset its content ends at, before its line break. -/
  content : Nat
  /-- The text from its start to its first non-blank. -/
  leading : String
  /-- Its level; `none` when its indent is kept. -/
  level : Option Nat
  deriving DecidableEq, Repr

/-- The edits that re-indent `rows`, in order ("Re-indenting", in the
module docs): each row's leading whitespace, from its start to its first
non-blank, becomes its level in `unit`, and a blank row's becomes nothing.
A row with no level, and a row whose leading whitespace is already that,
is left. -/
def reindent (unit : Language.IndentUnit) (rows : Array Row) : Array (Extent × String) :=
  rows.filterMap fun row =>
    match row.level with
    | none => none
    | some level =>
      let wanted := if row.firstNonBlank == row.content then "" else whitespace unit level
      if row.leading == wanted then none else some (⟨row.start, row.firstNonBlank⟩, wanted)

/-- What a new line starts with ("New lines", in the module docs), from
the opening level `answer` and the leading whitespace `leading` of the row
the line opens on: its level in `unit`; nothing added inside a string or
comment; the row's own indent when the text is not parsed yet; and nothing
added when it has no tree or no indents query. -/
def newLine (unit : Language.IndentUnit) (answer : Except SyntaxTreeError (Option Nat))
    (leading : String) : Option String :=
  match answer with
  | .ok (some level) => some (whitespace unit level)
  | .ok none => none
  | .error .notParsed => some leading
  | .error _ => none

/-- The edit that breaks a line at `head` with `ending` ("New lines", in
the module docs): with no indent, the line ending at the bar; with the
indent `ws`, the `blanksBefore` blanks before the bar and the `blanksAfter`
after it are replaced with the line ending and the indent. -/
def breakAt (ending : String) (ws : Option String) (head blanksBefore blanksAfter : Nat) :
    Extent × String :=
  match ws with
  | none => (⟨head, head⟩, ending)
  | some ws => (⟨head - blanksBefore, head + blanksAfter⟩, ending ++ ws)

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
