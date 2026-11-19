import Editor.JumpList
import ModelTest.Check

/-!
# Model tests: `Editor/JumpList.lean`

The model tests of `Editor/JumpList.lean`: `jumpListChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A jump list of line numbers, as the checks write one. -/
def jumpLines (entries : List Nat) (index : Nat) : JumpList Nat :=
  { entries := entries.toArray, index }

/-- A jump list of line numbers cleaned up by line, as the editor's
clean-up keys entries of one buffer. -/
def jumpCleaned (list : JumpList Nat) : JumpList Nat :=
  list.cleanup id

/-- A step by `n` of `list`, cleaned up first, from the line `here`, as
`C-o` and `C-i` take one: the list after it and the line it lands on. -/
def jumpStepped (list : JumpList Nat) (n : Int) (here : Nat) : Option (JumpList Nat × Nat) :=
  (jumpCleaned list).step n here

/-- `:help jumplist`'s worked example, entries as lines and indexes from 0:
the list after each step and the line each `C-o` lands on, with the cursor
on line 1167 at the start and on the last line, 2000, after `G`. -/
def jumpHelpExample : Option (List (JumpList Nat × Nat)) := do
  let start := jumpLines [1, 70, 1154] 3
  -- C-o from 1167: 1167 is recorded, and the step lands on 1154.
  let (first, landed) ← jumpStepped start (-1) 1167
  -- G from 1154 records 1154.
  let raw := first.record landed
  -- C-o from the last line cleans the list up first.
  let (second, onSecond) ← jumpStepped raw (-1) 2000
  let (third, onThird) ← jumpStepped second (-1) 0
  let (fourth, onFourth) ← jumpStepped third (-1) 0
  let (fifth, onFifth) ← jumpStepped fourth (-1) 0
  return [(first, landed), (raw, 0), (jumpCleaned raw, 0), (second, onSecond), (third, onThird),
      (fourth, onFourth), (fifth, onFifth)]

/-- The checks of the jump list's rules, over line numbers. -/
def jumpListChecks : List Check :=
  [{  name := "a record appends the entry and sets the index one past the end"
      run := return (jumpLines [1, 2] 0).record 7 == jumpLines [1, 2, 7] 3 },
    { name := "a record of an entry already there removes nothing"
      run := return (jumpLines [1, 2] 2).record 1 == jumpLines [1, 2, 1] 3 },
    { name := "the record past the limit drops the oldest entry"
      run :=
        let full : JumpList Nat := (List.range JumpList.limit).foldl (·.record ·) {}
        let next := full.record 100
        return full.entries.size == 100 && next.entries.size == 100 &&
            next.entries[0]? == some 1 && next.entries.back? == some 100 && next.index == 100 },
    { name := "a clean-up drops an earlier entry of the same line and keeps the latest"
      run := return jumpCleaned (jumpLines [1, 5, 2, 5] 4) == jumpLines [1, 2, 5] 3 },
    { name := "a clean-up carries the index with its entry"
      run := return jumpCleaned (jumpLines [1, 5, 2, 5, 9] 2) == jumpLines [1, 2, 5, 9] 1 },
    { name := "a clean-up moves an index at a dropped entry to the next entry kept"
      run := return jumpCleaned (jumpLines [1, 5, 2, 5, 9] 1) == jumpLines [1, 2, 5, 9] 1 },
    { name := "a clean-up keeps an index one past the end one past the end"
      run := return jumpCleaned (jumpLines [3, 3, 3] 3) == jumpLines [3] 1 },
    { name := "a step back from one past the end records first and lands on the entry before"
      run :=
        return (jumpLines [1, 2, 3] 3).plan (-1) == some { recordFirst := true, index := 2 } &&
            (jumpLines [1, 2, 3] 3).step (-1) 9 == some (jumpLines [1, 2, 3, 9] 2, 3) },
    { name := "a step back at the first entry fails"
      run := return (jumpLines [1, 2, 3] 0).plan (-1) == none },
    { name := "a step forward at the last entry fails"
      run := return (jumpLines [1, 2, 3] 2).plan 1 == none },
    { name := "a step forward from one past the end fails and records nothing"
      run := return (jumpLines [1, 2, 3] 3).plan 1 == none },
    { name := "a step on an empty list fails"
      run := return (jumpLines [] 0).plan (-1) == none },
    { name := "steps of 2 and 3 land that many entries away"
      run :=
        return (jumpLines [1, 2, 3, 4] 3).plan (-2) == some { recordFirst := false, index := 1 } &&
            (jumpLines [1, 2, 3, 4] 0).plan 3 == some { recordFirst := false, index := 3 } &&
            (jumpLines [1, 2, 3, 4] 4).plan (-3) == some { recordFirst := true, index := 1 } },
    { name := "a step past either end fails"
      run :=
        return (jumpLines [1, 2, 3, 4] 1).plan (-2) == none && (jumpLines [1, 2, 3, 4] 1).plan 3 == none &&
            (jumpLines [1, 2, 3, 4] 4).plan (-5) == none },
    { name := "a step back from one past the end of a full list lands on the entry before the record"
      run :=
        let full : JumpList Nat := (List.range JumpList.limit).foldl (·.record ·) {}
        return full.plan (-1) == some { recordFirst := true, index := 98 } &&
            (full.step (-1) 500).map (·.2) == some 99 },
    { name := ":help jumplist's example: C-o from 1167 records it and lands on 1154"
      run := return (jumpHelpExample.bind (·[0]?)) == some (jumpLines [1, 70, 1154, 1167] 2, 1154) },
    { name := ":help jumplist's example: G from 1154 appends 1154 and removes nothing"
      run := return (jumpHelpExample.bind (·[1]?)).map (·.1) == some (jumpLines [1, 70, 1154, 1167, 1154] 5) },
    { name := ":help jumplist's example: the clean-up drops the earlier 1154"
      run := return (jumpHelpExample.bind (·[2]?)).map (·.1) == some (jumpLines [1, 70, 1167, 1154] 4) },
    { name := ":help jumplist's example: C-o from the last line records it and lands on 1154"
      run :=
        return (jumpHelpExample.bind (·[3]?)) == some (jumpLines [1, 70, 1167, 1154, 2000] 3, 1154) },
    { name := ":help jumplist's example: more C-o land on 1167, 70 and 1"
      run :=
        return (jumpHelpExample.map fun steps => (steps.drop 4).map (·.2)) == some [1167, 70, 1] &&
            (jumpHelpExample.bind (·[6]?)).map (·.1.index) == some 0 },
    { name := ":help jumplist's example: C-o at the first entry fails"
      run :=
        return (jumpHelpExample.bind (·[6]?)).bind (fun (list, _) => jumpStepped list (-1) 0) ==
            none }]

end ModelTest
