import Editor.Text

/-!
# The undo tree

A text's history as a tree of states, so that undoing and then editing never
loses a branch. It is plain Lean over the text port (`Editor/Text.lean`): it
imports the port and nothing else, neither the model nor the real binding,
and every move it makes is the port's `applyInverse` and `dropInverses`. The
store keeps what an undo needs and applies it; which edits are one step and
which branch a redo follows are decided here. Its cases
(`Editor/UndoTree/Cases.lean`) run against the text model and against the
real binding.

A tree is a value. An operation that changes it takes it and returns it, as
a store's command does, and one that edits the text is a command, a value of
`EditorM`.

## The rules of the tree

- A tree is the history of one text, which it is made over
  (`UndoTree.over`) and keeps: its operations cannot name another.
- A **node** is a state of the history: the text as it was after a group of
  edits. The **root** is the text as it was when the tree was made. A node
  holds no text and no selection. Both are the store's.
- A node has its parent, its children in the order they were made, the child
  a redo goes to (`next`), and one run of revisions (`cross`): the run whose
  inverse crosses the edge between the node and its parent *from the side
  the text is on*. For a node on the path from the root to where the text
  is, that is what an undo applies; for any other, what a redo applies.
- A node is named by a `NodeId`, an index in the order the nodes were made.
  Nothing is removed, so an id is never used again. An id names a node only
  with the tree it came from: nothing tells an index of another tree's from
  one of this tree's.
- The tree is **told** of edits; it does not make them and does not watch
  for them. `record` tells it the revision the text has reached, and `sync`
  asks the text and tells it. Everything after the last revision it knew is
  in the **open group**: revisions are consecutive and any run of them can
  be inverted where it ended, so the tree needs no list of them, and an edit
  made by something else (a job that finished, a config command) is in the
  group as soon as the tree is told a later revision.
- An edit the tree was **not told of** makes its next move refused by the
  store with `notInState`, with nothing changed. The caller tells it and
  asks again.
- `close` is the **boundary**: it makes the open group a node, a child of
  the node the text was at, and that node is where the text is. With nothing
  pending it makes no node. The caller sets the boundaries: after each
  command, but not inside an insert session or a repeat, which are one step.
- `undo` closes the open group and crosses to the parent. `redo` crosses to
  `next`, which is the child the text was last in: it is set when a child is
  made and whenever the text crosses between a node and a child, either way.
  With anything pending there is nothing to redo. `goTo` closes the open
  group, undoes up to the lowest node the two share and redoes down to its
  target, one edge at a time.
- **Crossing an edge** is one `applyInverse` of the node's `cross`, so a
  group undoes as one step: one request, one new revision, one entry of the
  log. The revision it produces is then the node's `cross`, alone: its
  inverse crosses the edge back. The run that was crossed is dropped
  (`dropInverses`), so after its first crossing an edge holds one kept
  inverse.
- A move hands back the selection to place (`Moved`): what the last
  `applyInverse` handed back, which is the selection before the group's
  first transaction for an undo and the selection after its last for a redo.
- `none` is the tree's own "there is nothing to do": an undo at the root, a
  redo with no child to go to, a move to an id that names no node. It is not
  a refusal, and nothing has changed. A refusal by the store is a `throw`,
  as everywhere in `EditorM`.
- **A move that throws has dropped nothing**: the drops of a move come after
  its last edge. So the tree the caller still holds stays good. Told the
  text's revision, it has whatever the move did as edits in its open group,
  and undoing that returns the text to where the move started.
- The revisions of an edge that has not been crossed, and of the open group,
  have their inverses kept by the store until the tree crosses them. The
  tree never prunes a node. Both are unbounded here.

## Another style over the same primitives

The tree is one history. Others are written over `applyInverse` and
`dropInverses` in the same way, and need nothing more of the store.

- A linear history is two lists of runs and the revision it last saw. Told a
  revision, it extends its newest run or starts one, drops the inverses its
  redo list held and empties it. Undo pops a run, applies its inverse and
  pushes the one revision that produced onto the redo list; redo is the
  same the other way.
- Vim's is this tree with a move to the node made before or after the one
  the text is at (node ids are in the order made), and a time on each node.
- Emacs's, where an undo is itself undoable, records the revision an inverse
  produced as an edit.
-/

namespace Editor

/-- The name of a node of one undo tree: its index in the order the tree's
nodes were made. It names a node only with the tree value it came from. -/
structure UndoTree.NodeId where
  /-- Which node: the tree's index for it. -/
  index : Nat
  deriving DecidableEq, Repr

/-- A run of consecutive revisions of a text, both ends included. -/
structure UndoTree.Run where
  /-- The run's first revision. -/
  first : Nat
  /-- The run's last revision. -/
  last : Nat
  deriving DecidableEq, Repr

/-- One state of a text's history, as the tree holds it. -/
structure UndoTree.Node where
  /-- The node this one was made from. `none` for the root. -/
  parent : Option UndoTree.NodeId
  /-- The nodes made from this one, in the order they were made. -/
  children : Array UndoTree.NodeId := #[]
  /-- The child a redo goes to: the one the text was last in. `none` for a
  node with no child. -/
  next : Option UndoTree.NodeId := none
  /-- The run whose inverse crosses the edge between this node and its
  parent from the side the text is on. `none` for the root. -/
  cross : Option UndoTree.Run := none
  deriving DecidableEq, Repr

/-- The history of one text, as a tree of states. The rules are in the
module docs. -/
structure UndoTree where
  /-- The text this is the history of. -/
  text : TextId
  /-- The nodes, in the order they were made. The root is the first. -/
  nodes : Array UndoTree.Node
  /-- The node the text is at, or was at when the open group began. -/
  current : UndoTree.NodeId
  /-- The text's revision when the open group was last empty. -/
  base : Nat
  /-- The last revision the tree was told. The open group is the revisions
  after `base` up to this one. -/
  head : Nat
  deriving DecidableEq, Repr

namespace UndoTree

/-- A tree after a move: where the text is now, and what to place. -/
structure Moved where
  /-- The tree after the move. -/
  tree : UndoTree
  /-- The selection to place: what the last inverse of the move handed back.
  `none` when it handed none back, and for a move that applied nothing. -/
  selection : Option Selection
  deriving DecidableEq, Repr

/-- The root of every tree: the text as it was when its tree was made. -/
def root : NodeId :=
  ⟨0⟩

/-- A tree for `text`, which is at `revision`: a root, and nothing
pending. -/
def new (text : TextId) (revision : Nat) : UndoTree where
  text := text
  nodes := #[{ parent := none }]
  current := root
  base := revision
  head := revision

/-- A tree for `text` as it is now: `new` with the revision the text is
at. -/
def over (text : TextId) : EditorM UndoTree :=
  return new text (← text.revision)

/-- The node `id` names; `none` when it names none. -/
def node? (tree : UndoTree) (id : NodeId) : Option Node :=
  tree.nodes[id.index]?

/-- Whether the open group holds an edit. -/
def pending (tree : UndoTree) : Bool :=
  tree.head > tree.base

/-- Tells the tree that its text has reached `revision`: every revision
after the last it knew is in the open group. A revision not after that one
changes nothing. -/
def record (tree : UndoTree) (revision : Nat) : UndoTree :=
  if revision > tree.head then { tree with head := revision } else tree

/-- Tells the tree the revision its text is at (`record`), for a caller that
does not thread one. -/
def sync (tree : UndoTree) : EditorM UndoTree :=
  return tree.record (← tree.text.revision)

/-- The boundary. With nothing pending, the tree as it is. Otherwise the
open group becomes a node, a child of the node the text was at and the one
its redo goes to, the text is at it, and nothing is pending. -/
def close (tree : UndoTree) : UndoTree :=
  if tree.pending then
    let id : NodeId := ⟨tree.nodes.size⟩
    let made : Node := { parent := some tree.current, cross := some ⟨tree.base + 1, tree.head⟩ }
    let nodes :=
      tree.nodes.modify tree.current.index fun parent =>
        { parent with
          children := parent.children.push id, next := some id }
    { tree with
      nodes := nodes.push made, current := id, base := tree.head }
  else tree

/-- The node `id` and those above it, up to the root, in that order. -/
def ancestors (tree : UndoTree) (id : NodeId) : List NodeId :=
  go tree.nodes.size id
where
  /-- Walks up from `id`. A parent was made before its child, so a path is
  no longer than the nodes there are, and `fuel` does not run out. -/
  go : Nat → NodeId → List NodeId
    | 0, _ => []
    | fuel + 1, id =>
      match (tree.node? id).bind (·.parent) with
      | some parent => id :: go fuel parent
      | none => [id]

/-- Crosses the edge between `child` and its parent, down to the child when
`down` and up to the parent otherwise, by one inverse applied with `origin`.
Returns the tree after it, what the inverse handed back, and the run that
was crossed, which the caller drops once its move is over. `none`, with
nothing done, for the root and for an id that names no node. -/
def crossEdge (tree : UndoTree) (child : NodeId) (down : Bool) (origin : Origin) :
    EditorM (Option (UndoTree × Option Selection × Run)) := do
  let some node := tree.node? child | return none
  let some parent := node.parent | return none
  let some run := node.cross | return none
  let inverted ← tree.text.applyInverse run.first run.last origin
  let crossed : Run := ⟨inverted.revision, inverted.revision⟩
  let nodes := tree.nodes.modify child.index ({ · with cross := some crossed })
  let nodes := nodes.modify parent.index ({ · with next := some child })
  let tree :=
    { tree with
      nodes
      current := if down then child else parent
      base := inverted.revision
      head := inverted.revision }
  return some (tree, inverted.selection, run)

/-- Undoes one step: closes the open group, then crosses to the parent of
the node the text is at, by an inverse applied with `origin`, and drops the
run it crossed. `none`, with nothing done, at the root with nothing
pending. -/
def undo (tree : UndoTree) (origin : Origin := .unattributed) : EditorM (Option Moved) := do
  let tree := tree.close
  let some (tree, selection, run) ← tree.crossEdge tree.current false origin | return none
  tree.text.dropInverses run.first run.last
  return some ⟨tree, selection⟩

/-- Redoes one step: crosses to the child the text was last in, by an
inverse applied with `origin`, and drops the run it crossed. `none`, with
nothing done, at a node with no child, and whenever anything is pending. -/
def redo (tree : UndoTree) (origin : Origin := .unattributed) : EditorM (Option Moved) := do
  if tree.pending then
    return none
  let some next := (tree.node? tree.current).bind (·.next) | return none
  let some (tree, selection, run) ← tree.crossEdge next true origin | return none
  tree.text.dropInverses run.first run.last
  return some ⟨tree, selection⟩

/-- Moves to the node `target`: closes the open group, then undoes up to the
lowest node the two share and redoes down to `target`, one inverse an edge,
each applied with `origin`, and then drops the runs it crossed. The
selection is the last edge's. `none`, with nothing done, for an id that
names no node. To the node the text is at, with nothing pending, it applies
nothing. -/
def goTo (tree : UndoTree) (target : NodeId) (origin : Origin := .unattributed) :
    EditorM (Option Moved) := do
  if (tree.node? target).isNone then
    return none
  let tree := tree.close
  let above := tree.ancestors target
  let some shared := (tree.ancestors tree.current).find? above.contains | return none
  let up := (tree.ancestors tree.current).takeWhile (· != shared)
  let down := (above.takeWhile (· != shared)).reverse
  let mut tree := tree
  let mut selection := none
  let mut crossed : Array Run := #[]
  for (child, descending) in up.map (·, false) ++ down.map (·, true) do
    let some (next, handed, run) ← tree.crossEdge child descending origin | return none
    tree := next
    selection := handed
    crossed := crossed.push run
  -- After the last edge, so that a move that was refused part-way has
  -- dropped nothing.
  for run in crossed do
    tree.text.dropInverses run.first run.last
  return some ⟨tree, selection⟩

end UndoTree

end Editor
