import Editor.UndoTree

/-!
# Marks across line deletions and undo

The rules by which Vim 9.1's marks (`:help mark-motions`) follow edits
beyond what a marker does by itself, as plain data over the text port's
patches and the undo tree: a mark whose line is deleted is erased, and the
lowercase marks are put back by undo and redo. Where the marks are kept is
the editor state's (`Editor/State.lean`, "The jump list and marks"); each
buffer keeps what these rules need beside its marks (`Marks.History`), and
the loop runs them once an event has been handled
(`Editor/Marks/Follow.lean`).

- **A mark's line is erased when its line is deleted** (Vim's
  `mark_adjust` with `MAXLNUM`, "If you delete a line that contains a
  mark, that mark is erased"). The line of each mark's marker is read when
  an event has been handled (`Line`): where its row starts, and where it
  stops, after its line break. At the next, the patch of what changed since
  says whether one edit removed the line (`Line.removedBy`), which Vim 9.1
  decides by which lines its `del_lines` deletes whole:
  - A row an edit takes whole, with its line break, is removed when the
    edit started before the row: the rows after the first of a linewise
    delete, and the rows between the first and the last of a charwise
    delete or change across lines (whose `op_delete` truncates the first
    line, deletes the lines between and joins the last onto the first).
  - The row an edit starts at the start of is removed only when the edit
    stops at a row's start, as `dd`'s edit does. One that stops inside a
    later row leaves the row's remainder as the line it was: the first
    line of `3cc` (whose `op_change` deletes the lines after the first and
    truncates the first) and of a charwise delete from a line's start into
    a later line both keep their marks.
  - The last row has no line break of its own, so it is removed only with
    the line break before it, as `dd` on the last line removes it. The
    only row of a text is never removed by an edit, since the same edit
    is `dd`'s and `cc`'s on a text of one line.
  - Where the edit alone cannot say which lines were deleted, the command
    that knows erases their marks itself, as Vim's `del_lines` does: the
    linewise delete those of all its lines (`dd` on a text's only line
    among them) and the linewise change those of its lines after the
    first (`Jumps.eraseRows`, called by `Editor/Evil/Operators.lean`). A
    redo runs no command, so it erases by its edit alone.
  - A deletion of part of a row keeps the mark, which its marker carries
    to where the deletion left it.
- **Undo and redo put the lowercase marks back** (Vim's `u_undoredo`,
  "Lowercase marks are restored when using undo and redo"). Each node of
  the buffer's undo tree is given the lowercase marks as they were at the
  boundary before its edits, by row and column in characters (`At`). An
  undo or a redo crosses one edge, to the node's parent or from it: the
  marks the node kept are put back, and the node keeps the marks as they
  were before the move, which the move back puts back in turn
  (`History.follow`). A mark the node did not keep stays where its marker
  took it. A move across more than one edge (`UndoTree.goTo`, which no
  command makes) puts back nothing.
- **A tree with fewer nodes** than the history last saw is another tree,
  and what the history kept is dropped.

Pinned by `ModelTest.markRuleChecks`; the marks erased and put back in the
editor by `ModelTest.evilMarkChecks`.
-/

namespace Editor.Marks

/-- The offset the marker `marker` is at: an anchor's, or the head of a
selection's primary range. -/
def offsetOf (marker : MarkerId) : TextM Nat := do
  match ← marker.text.marker marker with
  | .anchor anchor =>
    return anchor.offset
  | .selection selection =>
    return (selection.ranges[selection.primary]?.map (·.head)).getD 0

/-- The byte offset of the row `row` and the column `column`, in characters,
of `text`: the start of the row, clamped to the last line, and the bytes of
the row's first `column` characters, clamped to its content. -/
def offsetAt (text : TextId) (row column : Nat) : TextM Nat := do
  let row := min row ((← text.lineCount) - 1)
  let content ← text.rowContent row
  let start ← text.offsetOf ⟨row, 0⟩
  return start + (String.ofList (content.toList.take column)).utf8ByteSize

/-- The row of the byte offset `offset` of `text`, and its column in
characters. -/
def pointAt (text : TextId) (offset : Nat) : TextM (Nat × Nat) := do
  let point ← text.pointOf offset
  let content ← text.rowContent point.row
  let (column, _) :=
    content.toList.foldl
      (fun (count, bytes) char =>
        if bytes < point.column then (count + 1, bytes + char.utf8Size) else (count, bytes))
      (0, 0)
  return (point.row, column)

/-- The line a mark's marker was on when it was last read ("A mark's line
is erased when its line is deleted", in the module docs). -/
structure Line where
  /-- The marker of the mark. -/
  marker : MarkerId
  /-- The offset its row starts at. -/
  start : Nat
  /-- The offset its row stops at: after its line break, or the text's end
  for the last row. -/
  stop : Nat
  /-- Whether it is the last row, which has no line break of its own. -/
  last : Bool
  deriving DecidableEq, Repr

/-- Whether `edit`, an edit of the text the line was read in, removes the
line ("A mark's line is erased when its line is deleted", in the module
docs): it takes the row with its line break, and starts before the row or
stops at a row's start; or, for the last row, it takes the row with the line
break before it. -/
def Line.removedBy (line : Line) (edit : Edit) : Bool :=
  if line.last then edit.old.start < line.start && line.stop ≤ edit.old.stop
  else
    edit.old.start ≤ line.start && line.stop ≤ edit.old.stop &&
      (edit.old.start < line.start || edit.old.stopPoint.column == 0)

/-- Whether one of the edits of `patch`, from the revision the line was read
at, removes the whole line. -/
def Line.removedIn (line : Line) (patch : Patch) : Bool :=
  patch.edits.any line.removedBy

/-- The line the marker `marker` is on now. -/
def lineOf (marker : MarkerId) : TextM Line := do
  let text := marker.text
  let row := (← text.pointOf (← offsetOf marker)).row
  let rows ← text.lineCount
  let start ← text.offsetOf ⟨row, 0⟩
  let last := row + 1 ≥ rows
  let stop ←
    if last then
      text.motion .textEnd start
    else
      text.offsetOf ⟨row + 1, 0⟩
  return { marker, start, stop, last }

/-- A lowercase mark at a row and a column, as a node of the undo tree keeps
it ("Undo and redo put the lowercase marks back", in the module docs). -/
structure At where
  /-- The mark's letter. -/
  char : Char
  /-- Its row, from 0. -/
  row : Nat
  /-- Its column, in characters from the row's start. -/
  column : Nat
  deriving DecidableEq, Repr

/-- The mark `char`, held by `marker`, at the row and column it is at now. -/
def atOf (char : Char) (marker : MarkerId) : TextM At := do
  let (row, column) ← pointAt marker.text (← offsetOf marker)
  return { char, row, column }

/-- What a buffer keeps beside its marks for these rules (the module docs):
the lines its marks were on when last read, the lowercase marks at the
last boundary, what it last saw of its undo tree, and the marks each node
keeps. -/
structure History where
  /-- The revision of the text `lines` were read at. -/
  revision : Nat := 0
  /-- The line of each mark's marker, the global marks held in the buffer
  among them, as read at `revision`. -/
  lines : Array Line := #[]
  /-- The lowercase marks at the last boundary of the buffer's undo tree. -/
  boundary : Array At := #[]
  /-- How many nodes the undo tree had when last seen. -/
  nodes : Nat := 1
  /-- The node the text was at when last seen. -/
  current : UndoTree.NodeId := UndoTree.root
  /-- The marks each node keeps, for the nodes that keep any. -/
  saved : Array (UndoTree.NodeId × Array At) := #[]
  deriving DecidableEq, Repr

/-- The marks the history puts back now that its buffer's undo tree is
`tree`, and the history after ("Undo and redo put the lowercase marks
back", in the module docs): each node made since keeps the marks at the
boundary; a move across one edge puts back the marks its node kept, and
the node keeps the marks at the boundary instead. -/
def History.follow (history : History) (tree : UndoTree) : Array At × History :=
  let size := tree.nodes.size
  let seen :=
    { history with
      nodes := size, current := tree.current }
  if size < history.nodes then (#[], { seen with saved := #[] })
  else
    if size > history.nodes then
      let made : Array (UndoTree.NodeId × Array At) :=
        if history.boundary.isEmpty then #[]
        else
          (List.range (size - history.nodes)).toArray.map fun k =>
            (⟨history.nodes + k⟩, history.boundary)
      (#[], { seen with saved := history.saved ++ made })
    else
      let parentOf (id : UndoTree.NodeId) := (tree.node? id).bind (·.parent)
      let crossed :=
        if tree.current == history.current then none
        else
          if parentOf history.current == some tree.current then some history.current
          else if parentOf tree.current == some history.current then some tree.current else none
      match crossed with
      | none => (#[], seen)
      | some node =>
        let restored := ((history.saved.find? (·.1 == node)).map (·.2)).getD #[]
        let kept := if history.boundary.isEmpty then #[] else #[(node, history.boundary)]
        (restored, { seen with saved := history.saved.filter (·.1 != node) ++ kept })

end Editor.Marks
