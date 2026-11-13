import Editor.Text.Contract
import Editor.UndoTree

/-!
# The cases of the undo tree

What the undo tree (`Editor/UndoTree.lean`) does, as one list of cases. A
case is a `TextContract.Property`: a command that drives a tree through the
text port and returns whether it held. So the same list runs against the
text port's pure model (`model-test`, under `lake test`) and against its
real binding (`contract-test`, linked with the Rust library), as the port's
own contract does.

This module imports the tree and the port's contract, for `Property`, and
nothing else: not the model and not the real binding. The list is plain
data, programs that have not run.

Offsets are byte offsets. "é" and "ö" are two bytes each and "😀" is four:
`"héllo"` is 6 bytes and `"héllo wörld"` is 13.
-/

namespace Editor.UndoTreeCases

open TextContract (Property refusedWith selection)

/-- Applies `transaction` to the text of `tree` and tells the tree the
revision it produced. -/
def edit (tree : UndoTree) (transaction : Transaction) : TextM UndoTree :=
  return tree.record (← tree.text.apply transaction)

/-- Adds `added` at the end of the text of `tree`, by an insert, and tells
the tree. -/
def addAtEnd (tree : UndoTree) (added : String) : TextM UndoTree := do
  tree.text.insert (← tree.text.byteLength) added
  tree.sync

/-- Adds `added` at the end of the text of `tree` as a group of its own: the
edit, then a boundary. -/
def group (tree : UndoTree) (added : String) : TextM UndoTree :=
  return (← addAtEnd tree added).close

/-- What the text of `tree` reads, and its revision. -/
def reads (tree : UndoTree) : TextM (String × Nat) :=
  return (← tree.text.read, ← tree.text.revision)

/-- A new text holding "héllo wörld" with a tree over it, changed three
ways, each told to the tree, to "hello, rld😀" at revision 3: by a
transaction ("é" becomes "e" and "😀" is added at the end), by an insert
("," after "hello") and by a delete ("wö"). No boundary is set. -/
def changedThreeWays : TextM UndoTree := do
  let text ← createText "héllo wörld"
  let tree ← UndoTree.over text
  let tree ← edit tree { changes := #[.retain 1, .delete 2, .insert "e", .retain 10, .insert "😀"] }
  text.insert 5 ","
  let tree ← tree.sync
  text.delete 7 10
  tree.sync

/-- A tree over a new text holding "héllo" with three nodes under its root:
`a`, which added " A"; `a2`, under `a`, which added "2"; and `b`, a second
child of the root, which added "😀B", with the cursor after it as its
selection after. The text is at `b`, reading "héllo😀B", at revision 5. -/
structure Branches where
  /-- The tree, at `b`. -/
  tree : UndoTree
  /-- The first child of the root: "héllo A". -/
  a : UndoTree.NodeId
  /-- The child of `a`: "héllo A2". -/
  a2 : UndoTree.NodeId
  /-- The second child of the root: "héllo😀B". -/
  b : UndoTree.NodeId

/-- The selection `Branches.b` carried after it: the cursor at the end of
"héllo😀B". -/
def afterB : Selection :=
  selection .inclusive #[(11, 11)]

/-- Makes the tree of `Branches`. Revisions 1 and 2 made `a` and `a2`, one
move back to the root crossed two edges (3 and 4), and revision 5 made
`b`. A move back to the root that had nothing to do, which is not expected,
fails the command. -/
def branches : TextM Branches := do
  let text ← createText "héllo"
  let tree ← UndoTree.over text
  let tree ← group tree " A"
  let a := tree.current
  let tree ← group tree "2"
  let a2 := tree.current
  let some moved ← tree.goTo UndoTree.root | throw .noSuchText
  let tree ← edit moved.tree { changes := #[.retain 6, .insert "😀B"], after := some afterB }
  let tree := tree.close
  return ⟨tree, a, a2, tree.current⟩

/-- The cases of groups, undo, redo and branches. -/
def moveCases : List Property :=
  [{
      name :=
        "the undo tree: undo then a new edit keeps the old branch reachable: the parent has both children, in the order they were made, and a move to each reads what it read",
      holds := do
        let text ← createText "héllo"
        let tree ← UndoTree.over text
        let tree ← group tree " wörld"
        let first := tree.current
        let some undone ← tree.undo | return false
        let back := (← text.read) == "héllo"
        let tree ← group undone.tree "😀"
        let second := tree.current
        let children := (tree.node? UndoTree.root).map (·.children)
        let some toFirst ← tree.goTo first | return false
        let readsFirst := (← text.read) == "héllo wörld"
        let some toSecond ← toFirst.tree.goTo second | return false
        return back && first != second && children == some #[first, second] &&
            toFirst.tree.current == first &&
            readsFirst &&
            toSecond.tree.current == second &&
            (← text.read) == "héllo😀" },
    { name :=
        "the undo tree: a group undoes as one step: a transaction, an insert and a delete with a boundary after them are one node, one undo puts the text back at one more revision, and one redo makes all three again at one more"
      holds := do
        let tree := (← changedThreeWays).close
        let made := (← reads tree) == ("hello, rld😀", 3)
        let one := tree.nodes.size == 2 && (tree.node? tree.current).bind (·.cross) == some ⟨1, 3⟩
        let some undone ← tree.undo | return false
        let back ← reads tree
        -- The undo is one entry of the log, with the three made one.
        let entry := (← tree.text.changesSince 3).edits.size == 4
        let some redone ← undone.tree.redo | return false
        return made && one && back == ("héllo wörld", 4) && entry &&
            undone.tree.current == UndoTree.root &&
            (← reads tree) == ("hello, rld😀", 5) &&
            redone.tree.current == tree.current &&
            redone.tree.nodes.size == 2 },
    { name :=
        "the undo tree: undo closes the open group: with no boundary set, one undo takes back everything since the tree was made, and one redo makes it again"
      holds := do
        let tree ← changedThreeWays
        let noNode := tree.nodes.size == 1
        let some undone ← tree.undo | return false
        let back ← reads tree
        let some redone ← undone.tree.redo | return false
        return noNode && back == ("héllo wörld", 4) && undone.tree.nodes.size == 2 &&
            undone.tree.current == UndoTree.root &&
            (← reads tree) == ("hello, rld😀", 5) &&
            redone.tree.current != UndoTree.root },
    { name :=
        "the undo tree: nothing to do is none and changes nothing: undo at the root, redo at a leaf, redo with an edit pending, a move to an id that names no node, and a revert to a state of another node or to one that is not of the open group"
      holds := do
        let text ← createText "héllo"
        let tree ← UndoTree.over text
        let atRoot := (← tree.undo).isNone && (← tree.redo).isNone
        let tree ← group tree " A"
        let atLeaf := (← tree.redo).isNone
        let unchanged := (← reads tree) == ("héllo A", 1)
        -- There is a node to redo to, and an edit pending.
        let some undone ← tree.undo | return false
        let pending ← addAtEnd undone.tree "😀"
        let withPending := (← pending.redo).isNone
        let stranger : UndoTree.NodeId := ⟨9⟩
        let nowhere := (← pending.goTo stranger).isNone
        -- The state of another node, which the text is not at, and states
        -- that are not of the open group: it holds revision 3 alone.
        let elsewhere := (← pending.revertTo tree.state).isNone
        let before := (← pending.revertTo ⟨2⟩).isNone
        let after := (← pending.revertTo ⟨9⟩).isNone
        return atRoot && atLeaf && unchanged && withPending && nowhere && elsewhere && before &&
            after &&
            (← reads pending) == ("héllo😀", 3) },
    { name :=
        "the undo tree: redo goes to the child the text was last in: after an undo from the older of two branches to the older, and after a move to the parent from the newer to the newer"
      holds := do
        let made ← branches
        -- To the older branch, and up from it.
        let some toA ← made.tree.goTo made.a | return false
        let some up ← toA.tree.undo | return false
        let some down ← up.tree.redo | return false
        let older := down.tree.current == made.a && (← made.tree.text.read) == "héllo A"
        -- To the newer, and to its parent by a move.
        let some toB ← down.tree.goTo made.b | return false
        let some toRoot ← toB.tree.goTo UndoTree.root | return false
        let some again ← toRoot.tree.redo | return false
        return older && again.tree.current == made.b && (← made.tree.text.read) == "héllo😀B" },
    { name :=
        "the undo tree: a move crosses each edge between: from a leaf of one branch to a leaf of another the revision adds one for each edge, the text is the target's and the selection is the last edge's, and to the node the text is at nothing is applied"
      holds := do
        let made ← branches
        let start := (← reads made.tree) == ("héllo😀B", 5)
        -- One edge up and two down.
        let some toA2 ← made.tree.goTo made.a2 | return false
        let there := (← reads made.tree) == ("héllo A2", 8)
        -- Two edges up and one down, which hands back what `b` carried.
        let some toB ← toA2.tree.goTo made.b | return false
        let back := (← reads made.tree) == ("héllo😀B", 11)
        let some stay ← toB.tree.goTo made.b | return false
        return start && there && toA2.tree.current == made.a2 && toA2.selection == none && back &&
            toB.tree.current == made.b &&
            toB.selection == some afterB &&
            stay.tree.current == made.b &&
            stay.selection == none &&
            (← reads made.tree) == ("héllo😀B", 11) },
    -- "😀 héllo" is 11 bytes: "😀" is the bytes 0 to 3 and "é" the bytes 6
    -- and 7.
    { name :=
        "the undo tree: undo hands back the selection before its group's first transaction and redo the selection after its last, and each hands back none where none was carried"
      holds := do
        let text ← createText "😀 héllo"
        let tree ← UndoTree.over text
        let before := selection .line #[(0, 4), (8, 5)] 1
        let after := selection .block #[(7, 7)]
        let tree ←
          edit tree { changes := #[.retain 4, .insert "X", .retain 7], before := some before }
        let tree ← edit tree { changes := #[.retain 7, .delete 2, .retain 3], after := some after }
        let tree := tree.close
        let some undone ← tree.undo | return false
        let placed ← text.mark (.selection before)
        let held := (← text.marker placed) == .selection before
        let some redone ← undone.tree.redo | return false
        -- A group whose edits carried no selection.
        let tree ← group redone.tree "!"
        let some bare ← tree.undo | return false
        let some bareAgain ← bare.tree.redo | return false
        return undone.selection == some before && held && redone.selection == some after &&
            bare.selection == none &&
            bareAgain.selection == none &&
            (← text.read) == "😀X hllo!" },
    { name :=
        "the undo tree: the tree drops what it crosses and keeps what it needs: after an undo and a redo of a group the inverses of the group's own revisions and of the undo are gone, and every node is still reached"
      holds := do
        let tree := (← changedThreeWays).close
        let some undone ← tree.undo | return false
        let some redone ← undone.tree.redo | return false
        -- By hand, behind the tree's back: the group was 1 to 3, the undo 4.
        let ofGroup ← refusedWith .noInverse (discard <| tree.text.applyInverse 1 3)
        let ofPart ← refusedWith .noInverse (discard <| tree.text.applyInverse 3 3)
        let ofUndo ← refusedWith .noInverse (discard <| tree.text.applyInverse 4 4)
        let some again ← redone.tree.undo | return false
        let back := (← reads tree) == ("héllo wörld", 6)
        let some forth ← again.tree.redo | return false
        return ofGroup && ofPart && ofUndo && back && (← reads tree) == ("hello, rld😀", 7) &&
            forth.tree.current == tree.current },
    { name :=
        "the undo tree: an edit the tree was not told of makes its undo refused with nothing changed, and once the tree is told it is in the open group and one undo takes it back; and a tree told only the last of three revisions has all three in its group"
      holds := do
        let text ← createText "héllo"
        let tree ← UndoTree.over text
        let tree ← group tree " A"
        text.insert 8 "😀"
        let refused ← refusedWith .notInState (discard <| tree.undo)
        let unchanged := (← reads tree) == ("héllo A😀", 2)
        let told ← tree.sync
        let some undone ← told.undo | return false
        let one := (← reads tree) == ("héllo A", 3) && undone.tree.current == tree.current
        -- A gap is absorbed.
        let gap ← createText "héllo"
        let tree ← UndoTree.over gap
        gap.insert 6 "1"
        gap.insert 7 "2"
        gap.insert 8 "3"
        let tree := (tree.record 3).close
        let whole := (tree.node? tree.current).bind (·.cross) == some ⟨1, 3⟩
        let some undone ← tree.undo | return false
        return refused && unchanged && one && whole && (← reads tree) == ("héllo", 4) &&
            undone.tree.current == UndoTree.root },
    { name :=
        "the undo tree: an inverse applied behind the tree's back is an edit once the tree is told: one undo returns to before it"
      holds := do
        let text ← createText "héllo"
        let tree ← UndoTree.over text
        let tree ← group tree " wörld"
        discard <| text.applyInverse 1 1
        let behind := (← reads tree) == ("héllo", 2)
        let told ← tree.sync
        let some undone ← told.undo | return false
        return behind && (← reads tree) == ("héllo wörld", 3) &&
            undone.tree.current == tree.current &&
            undone.tree.nodes.size == 3 },
    { name :=
        "the undo tree: a move that is refused part-way leaves the caller's tree good: with one edge's inverse dropped behind the tree's back the move throws, and the tree the caller still holds, told the text's revision, undoes back to where the move started and can still cross the first edge"
      holds := do
        let made ← branches
        -- The move from `b` to `a2` crosses the edge of `b`, then that of
        -- `a`, whose inverse is dropped here, behind the tree's back.
        let some edge := (made.tree.node? made.a).bind (·.cross) | return false
        made.tree.text.dropInverses edge.first edge.last
        let thrown ← refusedWith .noInverse (discard <| made.tree.goTo made.a2)
        -- The first edge was crossed: the text is at the root's, one
        -- revision on.
        let partWay := (← reads made.tree) == ("héllo", 6)
        let told ← made.tree.sync
        let some undone ← told.undo | return false
        let back := (← reads made.tree) == ("héllo😀B", 7) && undone.tree.current == made.b
        let some first ← undone.tree.undo | return false
        return thrown && partWay && back && (← reads made.tree) == ("héllo", 8) &&
            first.tree.current == UndoTree.root },
    { name :=
        "the undo tree: a move closes the open group and drops what it crosses: with an edit pending and no boundary set, a move to a leaf of another branch makes a node of the group under the node the text was at, reads the target's text at one more revision for each edge, the new node's among them, and has dropped the run of every edge it crossed; and a move to the new node reads what the group made"
      holds := do
        let made ← branches
        let pending ← addAtEnd made.tree "!"
        let before :=
          (← reads pending) == ("héllo😀B!", 6) && pending.pending && pending.nodes.size == 4
        -- Up from the node of the group and from `b`, down to `a` and `a2`.
        let some toA2 ← pending.goTo made.a2 | return false
        let there :=
          (← reads pending) == ("héllo A2", 10) && toA2.tree.current == made.a2 &&
            !toA2.tree.pending
        -- The group is a node, the one child of `b`.
        let some closed := (toA2.tree.node? made.b).bind (·.next) | return false
        let node :=
          toA2.tree.nodes.size == 5 &&
            (toA2.tree.node? made.b).map (·.children) == some #[closed] &&
            (toA2.tree.node? closed).bind (·.parent) == some made.b
        -- By hand, behind the tree's back: the move crossed the edge of the
        -- group (revision 6), of `b` (5), of `a` (4) and of `a2` (3).
        let ofGroup ← refusedWith .noInverse (discard <| pending.text.applyInverse 6 6)
        let ofB ← refusedWith .noInverse (discard <| pending.text.applyInverse 5 5)
        let ofA ← refusedWith .noInverse (discard <| pending.text.applyInverse 4 4)
        let ofA2 ← refusedWith .noInverse (discard <| pending.text.applyInverse 3 3)
        -- Two edges up and two down.
        let some back ← toA2.tree.goTo closed | return false
        return before && there && node && ofGroup && ofB && ofA && ofA2 &&
            back.tree.current == closed &&
            (← reads pending) == ("héllo😀B!", 14) },
    { name :=
        "the undo tree: a move to the node the open group began at closes the group and undoes it: with an edit pending and no boundary set, the group is made a node under that node, the text reads what it read there at one more revision, the selection before the group's first transaction is handed back, the group's run is dropped, and one redo makes the group again"
      holds := do
        let text ← createText "héllo"
        let tree ← UndoTree.over text
        let tree ← group tree " A"
        let began := tree.current
        let before := selection .inclusive #[(8, 8)]
        let pending ← edit tree { changes := #[.retain 8, .insert "😀"], before := some before }
        let waiting :=
          (← reads pending) == ("héllo A😀", 2) && pending.pending && pending.nodes.size == 2 &&
            pending.current == began
        let some moved ← pending.goTo began | return false
        let back :=
          (← reads pending) == ("héllo A", 3) && moved.tree.current == began &&
            !moved.tree.pending &&
            moved.selection == some before
        let some closed := (moved.tree.node? began).bind (·.next) | return false
        let node :=
          moved.tree.nodes.size == 3 && (moved.tree.node? closed).bind (·.parent) == some began
        -- By hand, behind the tree's back: the group was revision 2.
        let dropped ← refusedWith .noInverse (discard <| text.applyInverse 2 2)
        let some redone ← moved.tree.redo | return false
        return waiting && back && node && dropped && redone.tree.current == closed &&
            (← reads pending) == ("héllo A😀", 4) }]

/-- The cases of reverting the open group, and of the saved state. -/
def stateCases : List Property :=
  [{
      name :=
        "the undo tree: reverting an open group restores the text and hands back the selections in force before it: the text is back at one more revision, the selection of two ranges its first transaction carried is handed back and can be placed, no node was made, there is nothing to redo, and a boundary then makes none",
      holds := do
        let text ← createText "héllo wörld"
        let tree ← UndoTree.over text
        -- "é" becomes "e", then "😀" is added at the end.
        let tree ←
          edit tree
              { changes := #[.retain 1, .delete 2, .insert "e", .retain 10]
                before := some (selection .exclusive #[(7, 13), (0, 3)])
                after := some (selection .exclusive #[(2, 2)]) }
        let tree ←
          edit tree
              { changes := #[.retain 12, .insert "😀"]
                before := some (selection .exclusive #[(12, 12)]) }
        let made := (← reads tree) == ("hello wörld😀", 2) && tree.pending
        let some reverted ← tree.revert | return false
        let back := (← reads tree) == ("héllo wörld", 3)
        -- In the store's form: sorted, the primary followed.
        let before := selection .exclusive #[(0, 3), (7, 13)] 1
        let placed ← text.mark (.selection before)
        let held := (← text.marker placed) == .selection before
        let noNode :=
          reverted.tree.nodes.size == 1 && reverted.tree.current == UndoTree.root &&
            !reverted.tree.pending &&
            reverted.tree.close == reverted.tree
        let noRedo := (← reverted.tree.redo).isNone && (← reverted.tree.undo).isNone
        -- What it took back is gone: the group's inverses and its own.
        let ofGroup ← refusedWith .noInverse (discard <| text.applyInverse 1 2)
        let ofRevert ← refusedWith .noInverse (discard <| text.applyInverse 3 3)
        -- With nothing pending, a revert applies nothing.
        let some again ← reverted.tree.revert | return false
        return made && back && reverted.selection == some before && held && noNode && noRedo &&
            ofGroup &&
            ofRevert &&
            again.tree == reverted.tree &&
            again.selection == none &&
            (← reads tree) == ("héllo wörld", 3) },
    { name :=
        "the undo tree: undoing back to the saved state marks the text unmodified, and redoing marks it modified again: a new tree is unmodified, an edit makes it modified, and after it is marked saved and a group is made, one undo makes it unmodified with the text reading what it read then, and one redo modified"
      holds := do
        let text ← createText "héllo"
        let tree ← UndoTree.over text
        let fresh := !tree.isModified
        let tree ← addAtEnd tree " wörld"
        let edited := tree.isModified && tree.close.isModified
        let tree := tree.close.markSaved
        let saved := !tree.isModified && (← reads tree) == ("héllo wörld", 1)
        let tree ← group tree "😀"
        let later := tree.isModified
        let some undone ← tree.undo | return false
        let back := !undone.tree.isModified && (← reads tree) == ("héllo wörld", 3)
        let some redone ← undone.tree.redo | return false
        return fresh && edited && saved && later && back && redone.tree.isModified &&
            (← reads tree) == ("héllo wörld😀", 4) },
    { name :=
        "the undo tree: reverting the part of a group a command made: a revert to the state kept after a first edit reads the text of that state and hands back the selection before the first transaction it took back, the rest of the group is still pending, and a boundary then makes one node of the group, which one undo takes back"
      holds := do
        let text ← createText "héllo"
        let tree ← UndoTree.over text
        let tree ← addAtEnd tree " A"
        let kept := tree.state
        let before := selection .inclusive #[(8, 8)]
        let tree ← edit tree { changes := #[.retain 8, .insert "😀"], before := some before }
        let tree ← addAtEnd tree "!"
        let made := (← reads tree) == ("héllo A😀!", 3) && tree.state != kept
        let some reverted ← tree.revertTo kept | return false
        let part :=
          (← reads tree) == ("héllo A", 4) && reverted.selection == some before &&
            reverted.tree.state == kept &&
            reverted.tree.pending &&
            reverted.tree.nodes.size == 1
        -- To the state the text is in, nothing is applied.
        let some stay ← reverted.tree.revertTo kept | return false
        let still := stay.tree == reverted.tree && stay.selection == none
        let closed := reverted.tree.close
        let one :=
          closed.nodes.size == 2 && (closed.node? closed.current).bind (·.cross) == some ⟨1, 4⟩
        let some undone ← closed.undo | return false
        return made && part && still && one && (← reads tree) == ("héllo", 5) &&
            undone.tree.current == UndoTree.root },
    { name :=
        "the undo tree: a text saved inside an open group is unmodified there, modified after a further edit and unmodified again after a revert to that state, and once the group is closed further on no undo or redo makes it unmodified; saved and then closed with nothing more it stays unmodified, and an undo and a redo make it modified and unmodified; and marked saved, once a boundary has been set, at the state taken at the end of the group it is unmodified, a revert to that state applies nothing, an undo and a redo make it modified and unmodified, and after a further edit a revert to that state takes the edit back"
      holds := do
        let text ← createText "héllo"
        let tree ← UndoTree.over text
        let tree := (← addAtEnd tree " A").markSaved
        let saved := tree.state
        let inside := !tree.isModified
        let tree ← addAtEnd tree "😀"
        let further := tree.isModified
        let some reverted ← tree.revertTo saved | return false
        let again := !reverted.tree.isModified && (← reads tree) == ("héllo A", 3)
        -- Closed further on: the saved state is no node.
        let closed := (← addAtEnd reverted.tree "!").close
        let some undone ← closed.undo | return false
        let some redone ← undone.tree.redo | return false
        let never := closed.isModified && undone.tree.isModified && redone.tree.isModified
        -- Saved, and then closed with nothing more: the saved state is the
        -- new node.
        let other ← createText "héllo"
        let tree ← UndoTree.over other
        let tree := (← addAtEnd tree " A").markSaved.close
        let still := !tree.isModified
        let some undone ← tree.undo | return false
        let some redone ← undone.tree.redo | return false
        let closedAfter :=
          still && undone.tree.isModified && !redone.tree.isModified &&
            (← reads tree) == ("héllo A", 3)
        -- Marked late: the state is taken at the end of an open group, as a
        -- save that takes time takes it, and marked once a boundary has made
        -- a node of the group. It is that node's state.
        let late ← createText "héllo"
        let tree ← UndoTree.over late
        let tree ← addAtEnd tree " A"
        let taken := tree.state
        let marked := tree.close.markSaved taken
        let reported := marked.state == taken && !marked.isModified
        -- The text is in that state, so a revert to it applies nothing.
        let stay := (← marked.revertTo taken) == some ⟨marked, none⟩
        let some away ← marked.undo | return false
        let some home ← away.tree.redo | return false
        let returned := away.tree.isModified && !home.tree.isModified
        -- After a further edit it is the node the open group began at, and a
        -- revert to it takes the edit back.
        let on ← addAtEnd home.tree "😀"
        let reverted ← on.revertTo taken
        let whole :=
          on.isModified && reverted.map (·.tree.isModified) == some false &&
            reverted.map (·.tree.pending) == some false &&
            (← reads on) == ("héllo A", 5)
        return inside && further && again && never && closedAfter && reported && stay && returned &&
            whole }]

/-- The case of who the tree's own edits are made by: every operation that
edits the text hands the origin it was given to the inverse it applies. A
trace names who wrote text an inverse put back, so each operation here puts
text back, under an origin no other is given. -/
def originCases : List Property :=
  [{
      name :=
        "the undo tree: the edit a move makes is made by the origin the move was given: text an undo, a redo, a move up, a move down, a revert to a state inside the open group and a revert of the whole group put back is traced to that operation's revision and to its own origin",
      holds := do
        -- "héllo" is 6 bytes and "h😀llo" 8: "é" is the bytes 1 and 2, and
        -- "😀" the bytes 1 to 4.
        let text ← createText "héllo"
        let tree ← UndoTree.over text
        let tree ← edit tree { changes := #[.retain 1, .delete 2, .insert "😀", .retain 3] }
        let tree := tree.close
        let made := tree.current
        -- Each crossing puts back what the one before it took out.
        let some undone ← tree.undo ⟨11⟩ | return false
        let byUndo := (← text.trace 1 3) == #[⟨1, 3, .entry 2 ⟨11⟩⟩]
        let some redone ← undone.tree.redo ⟨12⟩ | return false
        let byRedo := (← text.trace 1 5) == #[⟨1, 5, .entry 3 ⟨12⟩⟩]
        let some up ← redone.tree.goTo UndoTree.root ⟨13⟩ | return false
        let byUp := (← text.trace 1 3) == #[⟨1, 3, .entry 4 ⟨13⟩⟩]
        let some down ← up.tree.goTo made ⟨14⟩ | return false
        let byDown := (← text.trace 1 5) == #[⟨1, 5, .entry 5 ⟨14⟩⟩]
        -- An open group: "!" is added, and "😀" deleted after the state
        -- that is kept, so a revert to that state puts "😀" back.
        let tree ← addAtEnd down.tree "!"
        let kept := tree.state
        text.delete 1 5
        let tree ← tree.sync
        let some inside ← tree.revertTo kept ⟨15⟩ | return false
        let byRevertTo :=
          (← reads tree) == ("h😀llo!", 8) && (← text.trace 1 5) == #[⟨1, 5, .entry 8 ⟨15⟩⟩]
        -- "h" is deleted, which only a revert of the whole group puts back.
        text.delete 0 1
        let tree ← inside.tree.sync
        let some whole ← tree.revert ⟨16⟩ | return false
        let byRevert :=
          (← reads tree) == ("h😀llo", 10) && (← text.trace 0 1) == #[⟨0, 1, .entry 10 ⟨16⟩⟩]
        return byUndo && byRedo && byUp && byDown && byRevertTo && byRevert &&
            whole.tree.current == made }]

/-- The cases of the undo tree, which hold of it over every implementation
of the text port. -/
def cases : List Property :=
  moveCases ++ stateCases ++ originCases

end Editor.UndoTreeCases
