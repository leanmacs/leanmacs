import Editor.SyntaxTree
import Evil.TreeObjects
import EvilTest.Check

/-!
# Model tests: `Evil/TreeObjects.lean`

The model tests of `Evil/TreeObjects.lean`: `treeObjectRuleChecks`. The
root module `EvilTest.Model` runs them; its module doc says what each shows.
-/

namespace EvilTest

open Editor

/-- A row of the text objects query, for the tree objects' rule checks. -/
def objectRow (name : String) (start stop : Nat) : Evil.TreeObjects.Row :=
  { name, start, stop }

/-- The checks of the syntax tree's text-object rule
(`Evil.TreeObjects.choose`, `Evil/TreeObjects.lean`), pure, over
hand-built rows, answered for a range as the syntax tree port answers: the
rows that overlap it (`SyntaxTree.overlaps`), each range asked recorded. -/
def treeObjectRuleChecks : List Check :=
  let rows :=
    #[objectRow "function.outer" 0 100, objectRow "function.inner" 10 99,
      objectRow "function.outer" 20 60, objectRow "function.inner" 30 59,
      objectRow "function.inner" 31 40, objectRow "function.outer" 20 60,
      objectRow "class.outer" 70 80, objectRow "parameter.inner" 22 25, objectRow "comment" 21 26]
  let ask (first last : Nat) : StateM (List (Nat × Nat)) (Array Evil.TreeObjects.Row) := do
    modify (·.concat (first, last))
    return rows.filter fun row => SyntaxTree.overlaps row.start row.stop first last
  let asked (kind : Evil.TreeObjects.Kind) (inner : Bool) (low high : Nat) (wider : Bool := false)
    (count : Nat := 1) : Option (Nat × Nat) × List (Nat × Nat) :=
    (Evil.TreeObjects.choose ask kind inner low high (high + 1) wider count).run [] |>.run
  let choose (kind : Evil.TreeObjects.Kind) (inner : Bool) (low high : Nat) (wider : Bool := false)
    (count : Nat := 1) := (asked kind inner low high wider count).1
  [{  name := "the smallest node round the cursor comes first, a range captured twice once"
      run :=
        pure
          (choose .function false 35 35 == some (20, 60) &&
            choose .argument false 23 23 == some (22, 25)) },
    { name := "a count takes the node that many out, and too few is no object"
      run :=
        pure
          (choose .function false 35 35 (count := 2) == some (0, 100) &&
            choose .function false 35 35 (count := 3) == none) },
    { name := "a wider selection passes over a node no bigger than it for the next one out"
      run :=
        pure
          (choose .function false 20 59 (wider := true) == some (0, 100) &&
            choose .function false 21 59 (wider := true) == some (20, 60) &&
            choose .function false 20 59 == some (20, 60)) },
    { name := "the inside is the longest inner row within the chosen node"
      run :=
        pure
          (choose .function true 35 35 == some (30, 59) &&
            choose .function true 5 5 == some (10, 99)) },
    { name :=
        "the inside is asked over the chosen node's range, so a cursor in the node outside its inner row has the inside: the selection's cells are asked first, and the node's range only for an inside"
      run :=
        pure
          (asked .function true 5 5 == (some (10, 99), [(5, 6), (0, 100)]) &&
            asked .function true 21 21 == (some (30, 59), [(21, 22), (20, 60)]) &&
            asked .function false 5 5 == (some (0, 100), [(5, 6)]) &&
            asked .argument true 23 23 == (some (22, 25), [(23, 24)]) &&
            asked .class true 35 35 == (none, [(35, 36)])) },
    { name := "a node with no inner row has no inside"
      run :=
        pure (choose .class true 75 75 == none && choose .class false 75 75 == some (70, 80)) },
    { name :=
        "with no node round the cursor there is no object, and names the rule does not read count for nothing"
      run :=
        pure
          (choose .class false 35 35 == none && choose .argument false 21 21 == none &&
            choose .function false 100 100 == none) }]

end EvilTest
