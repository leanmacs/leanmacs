import Editor.Text

/-!
# The undo tree

A text's history as a tree of states, so that undoing and then editing never
loses a branch. It is plain Lean over the text port (`Editor/Text.lean`): it
imports the port and nothing else, neither the model nor the real binding,
and every move it makes is the port's `applyInverse` and `dropInverses`. The
store keeps what an undo needs and applies it; which edits are one step,
which branch a redo follows, how a failed command is rolled back and whether
a text is in the state last saved are decided here. Its cases
(`Editor/UndoTree/Cases.lean`) run against the text model and against the
real binding.

A tree is a value. An operation that changes it takes it and returns it, as
a store's command does, and one that edits the text is a program over the
text port, a value of `TextM`.

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
  as everywhere in `TextM`.
- **A move that throws has dropped nothing**: the drops of a move come after
  its last edge. So the tree the caller still holds stays good. Told the
  text's revision, it has whatever the move did as edits in its open group,
  and undoing that returns the text to where the move started.
- A **state** is where the text is in its history (`State`,
  `UndoTree.state`): a node, or, while a group is open, a point inside it.
  Undo, redo and `goTo` move between nodes only.
- **One state has one name**: the revision that first put the text in it,
  and nothing else. For a point of the open group that is the revision of
  the edit the tree was told of; for the root, the revision the text was at
  when the tree was made. A node keeps the name of its state. A boundary
  names nothing anew: the node it makes has the state the text is in, under
  the name it had while the group was open (`state_close`). A move to a
  node puts the text in that node's state, and the revision the move
  produced names no state. So a state a caller holds means the same point
  of the history whatever boundaries and moves came after it was taken, and
  two states are the same exactly when they are equal.
- `revertTo` goes back to a state of the open group, by one `applyInverse`
  of the run from just after that state to the last revision the tree
  knows, and hands back the selection before the first edit it took back.
  To a state inside the group, the edits before it stay pending, and the
  group is still one run: what was taken back and the revert itself cancel
  when the group is later undone as a step. `revert` goes back to the node
  itself, so the whole group goes: nothing is pending, **no node is made
  and there is nothing to redo**, and the group's inverses and the revert's
  own are dropped. That is the difference from an undo, which keeps what it
  takes back.
- **A failed command is rolled back** by keeping `tree.state` before the
  command and reverting to it if the command fails. Inside an insert
  session that is a state within the session's open group, which is why
  groups need not nest. A command that moved in the history cannot be
  rolled back this way: the move closed the group. The command loop does
  this (`Editor/Loop.lean`, "Rollback"), and does not take a move back: it
  reverts the group that is open after it (`revert`).
- **A boundary a failed command set goes with it.** The tree kept from
  before the command knows of no boundary set since: told the revision the
  text is at, its open group is everything the command did, across the
  nodes a later value of the tree made of it, and reverting it takes all of
  it back as one run, with no node left. That tree is good only while no
  edge of it was crossed since, because a crossing drops the run the edge
  held. `keepsEdgesOf` is whether a later tree still has an earlier one's
  edges as the earlier has them: each of its nodes, with the same parent,
  state and run. A crossing gives the edge another run for good, so a move
  over one of them shows, there and back or not. A move over an edge made
  since does not show: it drops inverses of the open group the earlier
  tree would revert, and the store then refuses that revert, with nothing
  changed.
- A state is one `UndoTree.state` gave. `revertTo` answers `none`, with
  nothing done, for a state of another node and for one that is not of the
  open group, and applies nothing for the state the text is in. The state
  of the node the open group began at is of the open group whenever it was
  taken: one taken at the end of a group that a boundary has since closed
  is that node's, so right after the boundary a revert to it applies
  nothing, and after a further edit it takes that edit back.
- **Saved.** The tree keeps the state last marked as saved (`markSaved`),
  and `isModified` is whether the text is in another. It saves nothing and
  asks the text nothing: whoever writes the file marks the state it wrote.
  A new tree is saved at its root: a text made from a file's bytes is what
  the file holds. So an edit makes a text modified; undoing, redoing or
  moving back to the saved node, or reverting to the saved state, makes it
  unmodified; and typing the saved text again by hand does not, since that
  is another state.
- **A boundary does not change whether a text is modified**, whichever of
  the mark and the boundary came first. If the text is in the saved state
  when its group is closed, the saved state is the new node's. A save that
  takes time may take the state at the end of an open group and mark it
  after the boundary: it marks that node, and an undo and a redo back to
  the node leave the text unmodified. A saved state the group moved on from
  before it was closed is a point inside a closed group, which no move
  returns to, so the text stays modified until it is saved again.
  `isModified_close` proves the rule for every tree.
- A tree that was not told of the newest revision answers for the one it
  knows. An inverse applied behind its back is an edit to it once it is
  told, so it may say "modified" of a text that is back in its saved state.
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

/-- Where a text is in its history, as the tree names it: at a node, or,
while a group is open, at a point inside it. A state is named by the
revision that first put the text in it and by nothing else, so one state has
one name, whether or not a boundary has been set since it was taken. -/
structure UndoTree.State where
  /-- The revision that first put the text in this state: the edit the tree
  was told of, or, for the root, the revision the text was at when the tree
  was made. A move back to the state produces a later revision, which names
  no state. -/
  revision : Nat
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
  /-- The state the text is in at this node: the one it was in when the
  boundary made the node, which is where every move to the node puts it. -/
  state : UndoTree.State
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
  /-- Where the text is in its history: the state a caller keeps before a
  command, to revert to if the command fails, or with a snapshot it saves,
  to mark as saved when the save reports. With nothing pending it is the
  state of `current`. -/
  state : UndoTree.State
  /-- The state last marked as saved. `none` when none was. -/
  saved : Option UndoTree.State
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

/-- A tree for `text`, which is at `revision`: a root, nothing pending, and
saved at its root. -/
def new (text : TextId) (revision : Nat) : UndoTree where
  text := text
  nodes := #[{ parent := none, state := ⟨revision⟩ }]
  current := root
  base := revision
  head := revision
  state := ⟨revision⟩
  saved := some ⟨revision⟩

/-- A tree for `text` as it is now: `new` with the revision the text is
at. -/
def over (text : TextId) : TextM UndoTree :=
  return new text (← text.revision)

/-- The node `id` names; `none` when it names none. -/
def node? (tree : UndoTree) (id : NodeId) : Option Node :=
  tree.nodes[id.index]?

/-- Whether the open group holds an edit. -/
def pending (tree : UndoTree) : Bool :=
  tree.head > tree.base

/-- Tells the tree that its text has reached `revision`: every revision
after the last it knew is in the open group, and the text is in the state
that revision put it in. A revision not after that one changes nothing. -/
def record (tree : UndoTree) (revision : Nat) : UndoTree :=
  if revision > tree.head then
    { tree with
      head := revision, state := ⟨revision⟩ }
  else tree

/-- Tells the tree the revision its text is at (`record`), for a caller that
does not thread one. -/
def sync (tree : UndoTree) : TextM UndoTree :=
  return tree.record (← tree.text.revision)

/-- The boundary. With nothing pending, the tree as it is. Otherwise the
open group becomes a node, a child of the node the text was at and the one
its redo goes to, the text is at it, and nothing is pending.

A boundary names nothing anew: the node it makes has the state the text is
in, under the name that state had while the group was open (`state_close`).
So a state taken before the boundary is the node's after it, and a boundary
does not change whether the text is modified (`isModified_close`). A saved
state the group has moved on from stays what it was, a point inside a group
that is now closed, which no move returns to. -/
def close (tree : UndoTree) : UndoTree :=
  if tree.pending then
    let id : NodeId := ⟨tree.nodes.size⟩
    let made : Node :=
      { parent := some tree.current, cross := some ⟨tree.base + 1, tree.head⟩, state := tree.state }
    let nodes :=
      tree.nodes.modify tree.current.index fun parent =>
        { parent with
          children := parent.children.push id, next := some id }
    { tree with
      nodes := nodes.push made
      current := id
      base := tree.head }
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
was crossed, which the caller drops once its move is over. The text is then
in the state of the node it crossed to: the revision the inverse produced
names no state. `none`, with nothing done, for the root and for an id that
names no node. -/
def crossEdge (tree : UndoTree) (child : NodeId) (down : Bool) (origin : Origin) :
    TextM (Option (UndoTree × Option Selection × Run)) := do
  let some node := tree.node? child | return none
  let some parent := node.parent | return none
  let some above := tree.node? parent | return none
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
      head := inverted.revision
      state := if down then node.state else above.state }
  return some (tree, inverted.selection, run)

/-- Undoes one step: closes the open group, then crosses to the parent of
the node the text is at, by an inverse applied with `origin`, and drops the
run it crossed. `none`, with nothing done, at the root with nothing
pending. -/
def undo (tree : UndoTree) (origin : Origin := .unattributed) : TextM (Option Moved) := do
  let tree := tree.close
  let some (tree, selection, run) ← tree.crossEdge tree.current false origin | return none
  tree.text.dropInverses run.first run.last
  return some ⟨tree, selection⟩

/-- Redoes one step: crosses to the child the text was last in, by an
inverse applied with `origin`, and drops the run it crossed. `none`, with
nothing done, at a node with no child, and whenever anything is pending. -/
def redo (tree : UndoTree) (origin : Origin := .unattributed) : TextM (Option Moved) := do
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
    TextM (Option Moved) := do
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

/-- Goes back to `state`, a state of the open group (`UndoTree.state`), by
one inverse applied with `origin`: the edits made since are taken back, and
the selection before the first of them is handed back.

To a state inside the group, the edits before it stay pending, and the open
group is still one run, which holds what was taken back and the revert
itself: they cancel when the group is later undone as a step. To the node
itself, the whole group goes: nothing is pending, no node is made, there is
nothing to redo, and the group's inverses and the revert's own are dropped.

The node the open group began at is known by its state, whenever that state
was taken: one taken at the end of a group that a boundary has since closed
is that node's.

`none`, with nothing done, for a state of another node and for one that is
not of the open group. To the state the text is in, it applies nothing. -/
def revertTo (tree : UndoTree) (state : State) (origin : Origin := .unattributed) :
    TextM (Option Moved) := do
  if state == tree.state then
    return some ⟨tree, none⟩
  if (tree.node? tree.current).map (·.state) == some state then
    -- The whole open group. The text is not in the node's state, so the
    -- group holds an edit.
    let inverted ← tree.text.applyInverse (tree.base + 1) tree.head origin
    tree.text.dropInverses (tree.base + 1) tree.head
    tree.text.dropInverses inverted.revision inverted.revision
    return some
        ⟨{ tree with
            base := inverted.revision, head := inverted.revision, state },
          inverted.selection⟩
  -- A state inside the open group is named by a revision after the group's
  -- start and before the last revision the tree knows: that one is where
  -- the text is, or is the revert that put it where it is.
  unless tree.base < state.revision ∧ state.revision < tree.head do
    return none
  let inverted ← tree.text.applyInverse (state.revision + 1) tree.head origin
  return some
      ⟨{ tree with
          head := inverted.revision, state },
        inverted.selection⟩

/-- Reverts the whole open group: `revertTo` the node the text was at when
the group began. -/
def revert (tree : UndoTree) (origin : Origin := .unattributed) : TextM (Option Moved) := do
  let some node := tree.node? tree.current | return none
  tree.revertTo node.state origin

/-- Whether `tree` still has the edges of `earlier`, a value the tree had
before, as `earlier` has them: it is over the same text and has each node of
`earlier` with the same parent, the same state and the same run. A crossing
gives an edge another run, so `tree` keeps them through edits, boundaries
and moves over edges made since, and no longer once a move has crossed one
of `earlier`'s, whether or not it crossed back. What else `tree` has is not
looked at: the nodes made since, and the child each redo goes to. -/
def keepsEdgesOf (tree earlier : UndoTree) : Bool :=
  tree.text == earlier.text &&
    (List.range earlier.nodes.size).all fun index =>
      match earlier.nodes[index]?, tree.nodes[index]? with
      | some was, some now =>
        now.parent == was.parent && now.state == was.state && now.cross == was.cross
      | _, _ => false

/-- Marks `state` as the state last saved: by default the state the text is
in. A save that takes time keeps `tree.state` with the snapshot it writes
and marks that state when it reports, however far the text has moved on and
whether or not a boundary has been set since: a state has one name. -/
def markSaved (tree : UndoTree) (state : State := tree.state) : UndoTree :=
  { tree with saved := some state }

/-- Whether the text is in another state than the one last saved. It is
about the state the tree knows of: a tree that was not told of the newest
revision answers for the revision it knows. -/
def isModified (tree : UndoTree) : Bool :=
  tree.saved != some tree.state

/-- A boundary does not change the state the text is in, or its name: a
state taken while a group was open is the state of the tree once the group
is closed. -/
theorem state_close (tree : UndoTree) : tree.close.state = tree.state := by
  unfold close
  split <;> rfl

/-- A boundary does not change whether the text is modified, whatever state
was marked as saved and whenever it was taken. -/
theorem isModified_close (tree : UndoTree) : tree.close.isModified = tree.isModified := by
  unfold close
  split <;> rfl

end UndoTree

end Editor
