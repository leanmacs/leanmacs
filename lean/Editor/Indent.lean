import Editor.Command
import Editor.Language.IndentUnit

/-!
# Indentation from a syntax tree

The indent level of each row of a text, and of a line opened at a
position, from the captures of the indents query its major mode's text
keeps (`Mode.SyntaxTree.indents`, `Editor/Highlight.lean`), and the edits
that turn levels into whitespace: what evil's `=` and its commands that
open a line do (`Editor/Evil/Operators.lean`, `Editor/Evil.lean`). The
rules are pure and live here alone; the library only answers the query's
captures as plain rows (`SyntaxTree.capturesOf`), and has no indent rule of
its own (`docs/design/rust-library.md`, "Injections, indentation and text
objects, as built").

## The names

The rules read captures named `indent.begin`, `indent.branch`,
`indent.ignore` (nvim-treesitter's names, so a config author can read
them), `indent.open` and `indent.incomplete` (ours), and ignore every other
name (`Indent.names`). Every rule is ours.

## The rule (`Indent.rule`)

A node's rows are the row it starts on through the row of its last byte, so
a node that ends at a row's start does not reach that row. For a row `r`:

1. **None**, "keep the row's indent", when `r` lies after the first row of
   a node captured `indent.ignore` and within its rows: a row inside a
   multi-line string or block comment.
2. **Otherwise the level**: the number of distinct start rows of the nodes
   captured `indent.begin` that start on a row before `r` and whose rows
   reach `r`, and of the nodes captured `indent.open` (an opening bracket
   the tree did not close) that start on a row before `r`, whatever their
   last row (nodes that begin on one row count once); less one when the
   row's first non-blank is where a node captured `indent.branch` starts (a
   closing bracket), and never below 0.

A blank row gets a level by the same rule: the level a line typed there
would have.

## The opening rule (`Indent.openingCounts`, `Indent.levelOf`)

The level of a new line, asked of the text before the line break, at the
offset `at` the line opens at (`Indent.Opening`), from the nodes captured
there with their offsets (`Indent.Node`), and the first non-blank after
`at` on its row when that moves to the new row (`RET` before text):

1. **None**, "add nothing", when a node captured `indent.ignore` has
   `start < at < stop`: the line opens inside a multi-line string or block
   comment.
2. **Otherwise the level**: the number of distinct rows of the starts of
   each node captured `indent.begin` with `start < at < stop` (it holds a
   byte at or after `at`, so it reaches the new row) and of each node
   captured `indent.open` with `start < at`; less one when the first
   non-blank that moves starts a node captured `indent.branch`; never below
   0. Only the counted starts are turned into rows.

So a position in the text before the break answers what the new row's
level will be, and nothing is asked of a revision that has no tree.

## Widening (`Indent.widenedStart`)

An opening bracket the tree did not close may be far above the rows asked:
`fn main() {` at the text's end is an `ERROR` that holds a bare `{`. A
question of the captures that answers a node captured `indent.incomplete`
(an `ERROR`, or a node with a `MISSING` child) is asked again from the
earliest such node's start, so the brackets it holds are seen. Valid code
has no such capture, so it costs nothing there.

## The primitives

- `TextId.indentLevels text first last` gives each row from `first` through
  `last` its level, from a snapshot of the text: the kept indents query's
  captures over the bytes from the first row's start to the last row's end,
  widened by a position at each end where the text has one, so every node
  that encloses a row shares a byte with the range, an empty one too, and
  then widened as above; each row's start and first non-blank, and each
  capture's first and last rows, from the text port; then the rule.
- `TextId.openingLevel text at rest` gives the level of a line opened at
  `at`: the captures over a position either side of `at`, through the cell
  of the first non-blank that moves when `rest`, widened as above; then the
  opening rule.
- `TextId.reindentEdits text first last unit` reads each row's start, first
  non-blank, content's end and leading whitespace and its level from
  `indentLevels`, then `Indent.reindent`.

A refusal is a value: `notAttached`, `noQuery` (the text keeps no indents
query), or `notParsed` (the tree of the text's last edit is not delivered
yet). The levels are counts, which `Indent.whitespace` turns into a unit's
spaces or tabs (`Editor/Language/IndentUnit.lean`).

## Re-indenting (`Indent.reindent`)

Each row's leading whitespace, from its start to its first non-blank,
becomes its level in the unit; a blank row's becomes nothing, as Vim's `=`
and rustfmt leave one. A row with no level, a blank one too, and a row
whose whitespace is already that, gets no edit. The edits are sorted and
apart, for one transaction.

## New lines (`Indent.newLine`, `Indent.breakAt`)

What a new line starts with, from the opening level:

| The opening level | The new line's whitespace |
|---|---|
| A level | That level in the unit |
| None (inside a string or comment) | Nothing added |
| Refused `notParsed` (keys faster than a reparse, or a replay) | The opening row's own leading whitespace: Vim's `autoindent`, never a wait |
| Refused otherwise (`notAttached`, `noQuery`, ...) | Nothing added, as before indenting |

`breakAt` is `RET`'s edit: with nothing added, the line ending at the bar;
with whitespace, the blanks either side of the bar on its row and the line
ending go, replaced by the line ending and the whitespace, as Vim's
`open_line` truncates the spaces left at the split under `autoindent`.

## Known limits

- An `ERROR` that holds a bare `{` and its bare `}` counts the `{` for the
  rows after the `}` too; a later `=` on code that parses corrects it.
- A continuation in an error state (`let x =` with nothing after) is one
  level in where rustfmt would give two.
- Indentation inside an injected layer is not asked.

Pinned by `ModelTest.indentRuleChecks` (the rule, pure),
`ModelTest.indentOpeningChecks` (the opening rule and the widening, pure),
`ModelTest.indentEditChecks` (whitespace, re-indent, new line and break,
pure), `ModelTest.indentLevelChecks` (the primitives, on the editor's
models) and, real-only, by `ContractTest`'s checks of the Rust fixture
`tests/syntax/rust/indent.rs`, whose levels are its own indentation, and of
the opening level of Rust texts at unclosed brackets.
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
          else
            if node.name == "indent.open" && node.firstRow < line.row then some node.firstRow
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
        else if node.name == "indent.open" && node.start < at_ then some node.start else none
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
  nodes.foldl
    (fun least node => if node.name == "indent.incomplete" then min least node.start else least)
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

/-- The nodes the indents query `snapshot` keeps captures over `start`
through `stop`, of the names the rules read (`Indent.names`), asked again
from the start of the earliest node captured `indent.incomplete` when that
is earlier (`Indent.widenedStart`), so the bare brackets an incomplete node
holds are seen. Refused, as a value, as `capturesOf` is. -/
private def indentNodes (snapshot : SnapshotId) (start stop : Nat) :
    EditorM (Except SyntaxTreeError (Array Indent.Node)) := do
  let ask (start : Nat) : EditorM (Except SyntaxTreeError (Array Indent.Node)) := do
    match ← SyntaxTree.lift (SyntaxTree.capturesOf snapshot .indents start stop) with
    | .error refusal =>
      return .error refusal
    | .ok kept =>
      return .ok <|
          kept.captures.filterMap fun capture =>
            (kept.names[capture.capture]?).bind fun name =>
              if Indent.names.contains name then
                some { name, start := capture.start, stop := capture.stop }
              else none
  match ← ask start with
  | .error refusal =>
    return .error refusal
  | .ok nodes =>
    let widened := Indent.widenedStart nodes start
    if widened < start then
      ask widened
    else
      return .ok nodes

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
    match ← indentNodes snapshot start stop with
    | .error refusal =>
      return .error refusal
    | .ok nodes =>
      let mut captured := #[]
      for node in nodes do
        let firstRow := (← text.pointOf node.start).row
        let lastByte ←
          if node.stop > node.start then
            text.motion .previousCell node.stop
          else
            pure node.start
        captured :=
          captured.push
            { name := node.name, start := node.start, firstRow
              lastRow := (← text.pointOf lastByte).row }
      let mut lines := #[]
      for row in [first:last + 1] do
        let rowStart ← text.offsetOf { row, column := 0 }
        lines := lines.push { row, firstNonBlank := ← text.motion .lineFirstNonBlank rowStart }
      return .ok (Indent.rule captured lines)

/-- The level of a line opened at `offset` of `text`, by the indents query
its text keeps ("The opening rule", in the module docs), asked of the text
as it is, before the line break: `none` when the line opens inside a node
whose indent is kept. With `rest`, what follows `offset` on its row moves
to the new row, so a closing bracket there leads the new row out. Refused,
as a value, with `notAttached`, `noQuery` or `notParsed`. -/
def TextId.openingLevel (text : TextId) (offset : Nat) (rest : Bool) :
    EditorM (Except SyntaxTreeError (Option Nat)) :=
  text.withSnapshot fun snapshot => do
    let length ← text.byteLength
    let firstNonBlank ←
      if rest then
        do
          let lineEnd ← text.motion .lineEnd offset
          let after ← text.slice offset lineEnd
          let blanks := (after.takeWhile fun char => char == ' ' || char == '\t').utf8ByteSize
          pure (if offset + blanks < lineEnd then some (offset + blanks) else none)
      else
        pure none
    let start ←
      if offset > 0 then
        text.motion .previousCell offset
      else
        pure 0
    -- Through the cell after the position, or after the first non-blank
    -- that moves, so a closing bracket there is asked.
    let last := firstNonBlank.getD offset
    let stop ←
      if last < length then
        text.motion .nextCell last
      else
        pure last
    match ← indentNodes snapshot start stop with
    | .error refusal =>
      return .error refusal
    | .ok nodes =>
      match Indent.openingCounts nodes { offset, firstNonBlank } with
      | none =>
        return .ok none
      | some (starts, branch) =>
        let rows ← starts.mapM fun start => return (← text.pointOf start).row
        return .ok (some (Indent.levelOf rows branch))

/-- The edits that re-indent the rows of `text` from `first` through `last`
in `unit` (`Indent.reindent`, "Re-indenting" in the module docs): each
row's levels from `indentLevels`, and its start, first non-blank, content's
end and leading whitespace from the text. Refused, as a value, as
`indentLevels` is. -/
def TextId.reindentEdits (text : TextId) (first last : Nat) (unit : Language.IndentUnit) :
    EditorM (Except SyntaxTreeError (Array (Extent × String))) := do
  match ← text.indentLevels first last with
  | .error refusal =>
    return .error refusal
  | .ok levels =>
    let mut rows := #[]
    for (level, index) in levels.zipIdx do
      let start ← text.offsetOf { row := first + index, column := 0 }
      let firstNonBlank ← text.motion .lineFirstNonBlank start
      rows :=
        rows.push
          { start, firstNonBlank, content := ← text.motion .lineEnd start
            leading := ← text.slice start firstNonBlank, level }
    return .ok (Indent.reindent unit rows)

end Editor
