import Editor.Command
import Editor.Event
import Editor.InputScheme
import Editor.InputScheme.Vim
import Editor.Invocation
import Editor.Keymap
import Editor.Mode
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Keys
import ModelTest.Support.Vim

/-!
# Model tests: `Editor/InputScheme/Vim.lean`

The model tests of `Editor/InputScheme/Vim.lean`: `vimEditChecks`,
`vimRegistryChecks`, `vimGrammarChecks` and `vimStateChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the Vim scheme's edits (`Editor/InputScheme/Vim.lean`):
the invocation each compiles to, and what an edit says of itself. -/
def vimEditChecks : List Check :=
  let undo : Vim.Command := { name := "undo" }
  [{  name := "a move compiles to the move command, with the motion's name and then the count"
      run :=
        pure
          ((Vim.Edit.move "word" (some 2)).compile ==
              { command := "move", arguments := [.str "word", .nat 2] } &&
            Vim.moveCommand == "move") },
    { name :=
        "an edit with an operator compiles to the operate command, with the operator's name, the kind of its target and the target's name, the count and the register: over a motion, a text object, lines and the selection"
      run :=
        let compiled (over : Vim.Over) : Invocation :=
          (Vim.Edit.operate vimDelete over (some 3) (some "a")).compile
        let expected (kind name : String) : Invocation :=
          { command := "operate"
            arguments := [.str "delete", .str kind, .str name, .nat 3, .str "a"] }
        pure
          (compiled (.motion "word") == expected "motion" "word" &&
            compiled (.textObject "inner-word") == expected "text-object" "inner-word" &&
            compiled .lines == expected "lines" "" &&
            compiled .selection == expected "selection" "" &&
            Vim.operateCommand == "operate") },
    { name :=
        "an edit that runs a command compiles to that command, with the count and then the register"
      run :=
        pure
          ((Vim.Edit.run { name := "put-after" } (some 2) (some "+")).compile ==
            { command := "put-after", arguments := [.nat 2, .str "+"] }) },
    { name :=
        "a motion's argument compiles to a string right after the motion's name, in a move and over a motion, so the register stays the last argument; a count put in its place keeps the argument"
      run :=
        let over := Vim.Edit.operate vimDelete (.motion "find" (some "x")) (some 3) (some "a")
        pure
          ((Vim.Edit.move "find" (some 2) (some "x")).compile ==
              { command := "move", arguments := [.str "find", .str "x", .nat 2] } &&
            over.compile ==
              { command := "operate"
                arguments :=
                  [.str "delete", .str "motion", .str "find", .str "x", .nat 3, .str "a"] } &&
            over.compile.arguments.getLast? == some (.str "a") &&
            (Vim.Edit.move "find" none (some "x")).withCount 4 ==
              .move "find" (some 4) (some "x") &&
            over.withCount 5 ==
              .operate vimDelete (.motion "find" (some "x")) (some 5) (some "a")) },
    { name :=
        "an edit with no count compiles to a count of 0, and one with no register to the empty register name"
      run :=
        pure
          ((Vim.Edit.move "word" none).compile ==
              { command := "move", arguments := [.str "word", .nat 0] } &&
            (Vim.Edit.operate vimDelete .lines none none).compile ==
              { command := "operate"
                arguments := [.str "delete", .str "lines", .str "", .nat 0, .str ""] } &&
            (Vim.Edit.run undo none none).compile ==
              { command := "undo", arguments := [.nat 0, .str ""] }) },
    { name :=
        "edits that differ in one part compile to invocations that differ, each from every other"
      run :=
        let edits : List Vim.Edit :=
          [.move "word" none, .move "word" (some 1), .move "word" (some 2), .move "line" none,
            .operate vimDelete (.motion "word") none none,
            .operate vimYank (.motion "word") none none,
            .operate vimDelete (.motion "line") none none,
            .operate vimDelete (.textObject "word") none none, .operate vimDelete .lines none none,
            .operate vimDelete .selection none none,
            .operate vimDelete (.motion "word") (some 2) none,
            .operate vimDelete (.motion "word") none (some "a"),
            .operate vimDelete (.motion "word") none (some "b"), .run undo none none,
            .run { name := "redo" } none none, .run undo (some 2) none, .run undo none (some "a")]
        let compiled := edits.map (·.compile)
        pure (compiled.eraseDups.length == edits.length) },
    { name :=
        "a selection by a text object compiles to the select command with the object's name and the count, changes no text, names no state, and takes a count as a move does"
      run :=
        pure
          ((Vim.Edit.select "thing" (some 2)).compile ==
              { command := Vim.selectObjectCommand, arguments := [.str "thing", .nat 2] } &&
            (Vim.Edit.select "thing" none).compile ==
              { command := Vim.selectObjectCommand, arguments := [.str "thing", .nat 0] } &&
            !(Vim.Edit.select "thing" none).changes &&
            (Vim.Edit.select "thing" none).enters == none &&
            (Vim.Edit.select "thing" none).withCount 3 == .select "thing" (some 3)) },
    { name :=
        "whether an edit changes text is its operator's or its command's word for it, and a move changes none"
      run :=
        pure
          ((Vim.Edit.operate vimDelete .lines none none).changes &&
            !(Vim.Edit.operate vimYank .lines none none).changes &&
            (Vim.Edit.run vimInsert none none).changes &&
            !(Vim.Edit.run undo none none).changes &&
            !(Vim.Edit.move "word" (some 2)).changes) },
    { name :=
        "the state an edit enters is the one its operator or its command names, and a move names none"
      run :=
        pure
          ((Vim.Edit.operate vimChange .lines none none).enters == some "insert" &&
            (Vim.Edit.operate vimDelete .lines none none).enters == none &&
            (Vim.Edit.run vimInsert none none).enters == some "insert" &&
            (Vim.Edit.run undo none none).enters == none &&
            (Vim.Edit.move "word" none).enters == none) }]

/-- A state record as the checks compare it: its name, its cursor, its two
flags and how many keymaps it has. A record has no equality of its own,
since a keymap has none. -/
def vimSeen (record : Vim.StateRecord) : String × CursorShape × Bool × Bool × Nat :=
  (record.name, record.cursor, record.insertsText, record.operatesOnSelection,
    record.keymaps.length)

/-- The checks of the registry of Vim states (`Editor/InputScheme/Vim.lean`):
looking a state up by name, and registering one. -/
def vimRegistryChecks : List Check :=
  [{  name :=
        "the record of a registered Vim state is found by its name, with the cursor, the flags and the keymaps it was registered with"
      run :=
        pure
          (vimSeen (vimStates.get "insert") == ("insert", .bar, true, false, 1) &&
            vimSeen (vimStates.get "visual") == ("visual", .block, false, true, 2) &&
            vimSeen (vimStates.get "normal") == ("normal", .block, false, false, 1)) },
    { name := "a name the registry of Vim states does not have is read as the initial state"
      run :=
        pure
          (vimSeen (vimStates.get "replace") == vimSeen vimStates.initial &&
            (vimStates.get "").name == "normal") },
    { name := "registering a Vim state adds its record, found by its name, and leaves the others"
      run :=
        let added :=
          vimStates.register { name := "replace", cursor := .underline, insertsText := true }
        pure
          (vimSeen (added.get "replace") == ("replace", .underline, true, false, 0) &&
            vimSeen (added.get "insert") == vimSeen (vimStates.get "insert") &&
            added.others.map (·.name) == ["insert", "visual", "replace"] &&
            added.initial.name == "normal") },
    { name := "registering a Vim state of a name already registered replaces that record"
      run :=
        let replaced := vimStates.register { name := "insert", cursor := .hollow }
        pure
          (vimSeen (replaced.get "insert") == ("insert", .hollow, false, false, 0) &&
            (replaced.others.filter (·.name == "insert")).length == 1 &&
            replaced.others.length == 2 &&
            vimSeen replaced.initial == vimSeen vimStates.initial) },
    { name :=
        "registering a Vim state of the initial state's name replaces the initial record, and adds none"
      run :=
        let replaced := vimStates.register { name := "normal", cursor := .underline }
        pure
          (vimSeen replaced.initial == ("normal", .underline, false, false, 0) &&
            vimSeen (replaced.get "normal") == ("normal", .underline, false, false, 0) &&
            replaced.others.map (·.name) == ["insert", "visual"]) },
    { name :=
        "a Vim state's record says the shape of its selection: inclusive unless it says otherwise, and the shape it was registered with"
      run :=
        let added := vimStates.register { name := "lines", shape := .line }
        pure
          (({ name := "bare" } : Vim.StateRecord).shape == .inclusive &&
            (vimStates.get "normal").shape == .inclusive &&
            (vimStates.get "visual").shape == .inclusive &&
            (vimStates.get "insert").shape == .exclusive &&
            (added.get "lines").shape == .line) }]

/-- The initial state of the Vim scheme over `vimStates`, at its own type:
instance search does not see through the scheme's `State` field. -/
def vimInit : Vim.State :=
  (Vim.scheme vimStates).init

/-- The Vim scheme over `states` stepped from `state` through the keys the
key string `text` names, keys for `view`, with `maps` the active keymaps:
the state it is left in, at its own type, and what each key yielded. -/
def vimFedFrom (state : Vim.State) (text : String)
    (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps) (view : ViewId := ⟨0⟩)
    (states : Vim.States := vimStates) : Vim.State × List (Option Invocation) :=
  (Vim.scheme states).feed maps view state (keys text)

/-- `vimFedFrom` the scheme's initial state. -/
def vimFed (text : String) (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps)
    (view : ViewId := ⟨0⟩) (states : Vim.States := vimStates) :
    Vim.State × List (Option Invocation) :=
  vimFedFrom (Vim.scheme states).init text maps view states

/-- The keys the Vim scheme over `vimStates` reports as pending after the
keys `text` names, with `maps` the active keymaps. -/
def vimPending (text : String) (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps) : List Key :=
  (Vim.scheme vimStates).pending (vimFed text maps).1

/-- Active keymaps, for every view, that bind an operator and the register
prefix to two keys each, `g u` and `g r`: both under `g`, the prefix the
checks' normal state binds a motion under. -/
def vimTwoKeyMaps (_ : ViewId) : List (Keymap Vim.Bound) :=
  [vimKeymap [("g u", .operator { name := "lowercase" }), ("g r", .register)]]

/-- The invocation a move by `motion` compiles to, with `count`, 0 for
none. -/
def vimMove (motion : String) (count : Nat := 0) : Invocation :=
  { command := "move", arguments := [.str motion, .nat count] }

/-- The invocation an edit with the operator `operator` compiles to, over a
target of `kind` named `name`, with `count`, 0 for none, and `register`,
empty for none. -/
def vimOperate (operator kind name : String) (count : Nat := 0) (register : String := "") :
    Invocation :=
  { command := "operate"
    arguments := [.str operator, .str kind, .str name, .nat count, .str register] }

/-- What the run-table checks' visual states run `t-copy` as: the yank of
the selection into the register `+`. -/
def vimRunCopy : Vim.Edit :=
  .operate vimYank .selection none (some "+")

/-- What the run-table checks' visual states run `t-cut` as: the deletion of
the selection into the register `+`. -/
def vimRunCut : Vim.Edit :=
  .operate vimDelete .selection none (some "+")

/-- What the run-table checks' normal state runs `t-enter` as: a command of
that name that enters `visual-line`. -/
def vimRunEnter : Vim.Edit :=
  .run { name := "t-enter", enters := some "visual-line" } none none

/-- `vimStates` with run tables (`StateRecord.runs`): normal state runs
`t-enter` as `vimRunEnter`, and `visual` and a `visual-line` state the
checks register run `t-copy` and `t-cut` as `vimRunCopy` and
`vimRunCut`. -/
def vimRunStates : Vim.States :=
  let visual := vimStates.get "visual"
  let runs := [("t-copy", vimRunCopy), ("t-cut", vimRunCut)]
  ((vimStates.register { vimStates.initial with runs := [("t-enter", vimRunEnter)] }).register
        { visual with runs }).register
    { name := "visual-line", keymaps := visual.keymaps, operatesOnSelection := true, shape := .line
      runs }

/-- Active keymaps, for every view, that bind keys to command names alone,
as the scheme binds a command name (`InputScheme.command`): `C` to
`t-copy`, `X` to `t-cut`, `S` to `t-enter` and `N` to `t-none`, which no
run table has. -/
def vimRunMaps (_ : ViewId) : List (Keymap Vim.Bound) :=
  [vimKeymap
      [("C", .command { name := "t-copy" }), ("X", .command { name := "t-cut" }),
        ("S", .command { name := "t-enter" }), ("N", .command { name := "t-none" })]]

/-- The Vim scheme over `vimRunStates` fed `text` with `vimRunMaps`: the
state it is left in, the name of the Vim state view 0 is then in, and what
each key yielded. -/
def vimRunFed (text : String) : Vim.State × String × List (Option Invocation) :=
  let (state, yields) := vimFed text vimRunMaps ⟨0⟩ vimRunStates
  (state, state.stateOf vimRunStates ⟨0⟩, yields)

/-- What the Vim scheme over `vimRunStates` makes of `invocation`, named by
a menu item for view 0 from `state` (`InputScheme.invoked`), at the
state's own type. -/
def vimInvoked (state : Vim.State) (invocation : Invocation) : Vim.State × Invocation :=
  (Vim.scheme vimRunStates).invoked ⟨0⟩ state invocation

/-- The checks of the Vim scheme's grammar (`Editor/InputScheme/Vim.lean`),
on the registry written here: the keymaps a key is looked up in, and what a
key sequence parses to. -/
def vimGrammarChecks : List Check :=
  [{  name := "every row of the Vim checks' tables binds its keys"
      run :=
        pure
          ((vimKeymap vimNormalTable).bindings.length == vimNormalTable.length &&
            (vimKeymap vimEscapeTable).bindings.length == vimEscapeTable.length &&
            vimSequences.all fun text => !(keys text).isEmpty) },
    { name := "a key bound to a motion, typed alone, yields a move by that motion with no count"
      run :=
        pure
          ((vimFed "w").2 == [some (vimMove "word")] &&
            (vimParsed "w").2 == [.edit (.move "word" none)]) },
    { name :=
        "a motion bound to two keys yields its move on the second key, and nothing on the first"
      run := pure ((vimFed "g g").2 == [none, some (vimMove "first-line")]) },
    { name := "a key bound to a command yields the edit that runs it, with no count and no register"
      run :=
        pure
          ((vimFed "u").2 == [some { command := "undo", arguments := [.nat 0, .str ""] }] &&
            (vimParsed "u").2 == [.edit (.run { name := "undo" } none none)]) },
    { name :=
        "a key bound to a motion that takes a character is pending alone; the key after it names the character, a digit and TAB included, and completes the move, or the operator waiting over the motion with that argument, with the counts multiplied; any other key resets"
      run :=
        let active (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [("f", .charMotion "find")]]
        let move (char : String) (count : Nat) : Invocation :=
          { command := "move", arguments := [.str "find", .str char, .nat count] }
        let (escaped, escapedYields) := vimFed "f <Escape>" active
        pure
          (vimPending "f" active == keys "f" && vimPending "2 f" active == keys "2 f" &&
            vimPending "f x" active == [] &&
            (vimFed "f x" active).2 == [none, some (move "x" 0)] &&
            (vimParsed "f x" active).2 == [.nothing, .edit (.move "find" none (some "x"))] &&
            (vimFed "2 f 3" active).2.getLast? == some (some (move "3" 2)) &&
            (vimFed "f TAB" active).2.getLast? == some (some (move "\t" 0)) &&
            (vimFed "d 2 f x" active).2.getLast? ==
              some
                (some
                  { command := "operate"
                    arguments :=
                      [.str "delete", .str "motion", .str "find", .str "x", .nat 2, .str ""] }) &&
            (vimFed "2 d 3 f x" active).2.getLast? ==
              some
                (some
                  { command := "operate"
                    arguments :=
                      [.str "delete", .str "motion", .str "find", .str "x", .nat 6, .str ""] }) &&
            escapedYields == [none, none] &&
            decide (escaped = vimInit) &&
            (vimFed "f <Escape> w" active).2.getLast? == some (some (vimMove "word"))) },
    { name :=
        "a key bound to a motion that asks yields the command that opens its prompt, with the label, and resets the edit begun: nothing is pending, nothing is the last change, and the edit waits with the operator, the count and the register typed before it"
      run :=
        let active (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("/", .promptMotion "search" "/")]]
        let (asked, yields) := vimFed "/" active
        let (operated, _) := vimFed "\" a 2 d 3 /" active
        pure
          (yields == [some { command := Vim.askCommand, arguments := [.str "/"] }] &&
            asked.asking == some { view := ⟨0⟩, motion := "search" } &&
            asked.typed == [] &&
            asked.lastChange == none &&
            vimPending "/" active == [] &&
            operated.asking ==
              some
                { view := ⟨0⟩, motion := "search", operator := some vimDelete, count := some 6
                  register := some "a" }) },
    { name :=
        "the answer completes the edit that waits, with the answer as the motion's argument: a move with the count, and an operator over the motion with the count and the register, which is the last change; a second answer yields nothing"
      run :=
        let active (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("/", .promptMotion "search" "/")]]
        let (asked, _) := vimFed "2 /" active
        let (moved, move) := Vim.State.answered vimStates ⟨0⟩ "foo" asked
        let (operated, operate) :=
          Vim.State.answered vimStates ⟨0⟩ "x" (vimFed "\" a d 3 /" active).1
        let (again, nothing) := Vim.State.answered vimStates ⟨0⟩ "y" moved
        pure
          (move == some { command := "move", arguments := [.str "search", .str "foo", .nat 2] } &&
            moved.asking == none &&
            moved.lastChange == none &&
            operate ==
              some
                { command := "operate"
                  arguments :=
                    [.str "delete", .str "motion", .str "search", .str "x", .nat 3, .str "a"] } &&
            operated.lastChange ==
              some (.operate vimDelete (.motion "search" (some "x")) (some 3) (some "a")) &&
            nothing == none &&
            decide (again = moved)) },
    { name :=
        "the edit that waits for an answer is kept while keys are typed in the minibuffer's view and when that view closes, and dropped at the next key for another view, as after the prompt is cancelled"
      run :=
        let active (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("/", .promptMotion "search" "/")]]
        let (asked, _) := vimFed "/" active
        let opened := Vim.State.openMinibuffer vimStates ⟨5⟩ asked
        let (typed, _) := vimFedFrom opened "x y" active ⟨5⟩
        let closed := Vim.State.closeView ⟨5⟩ typed
        let (dropped, _) := vimFedFrom closed "w" active ⟨0⟩
        pure
          (opened.asking.map (·.minibuffer) == some (some ⟨5⟩) && typed.asking.isSome &&
            closed.asking.isSome &&
            dropped.asking == none) },
    { name :=
        "the Vim scheme reports the keys typed of an edit begun as pending, and none before a key and after the edit completes"
      run :=
        pure
          (vimPending "" == [] && vimPending "g" == keys "g" && vimPending "g g" == [] &&
            vimPending "w" == []) },
    { name :=
        "an unbound key after a prefix yields nothing and leaves the Vim scheme in its initial state, and the motion typed next yields its move"
      run :=
        let (state, yields) := vimFed "g z"
        let (alone, aloneYields) := vimFed "z"
        pure
          (yields == [none, none] && decide (state = vimInit) && aloneYields == [none] &&
            decide (alone = vimInit) &&
            (vimFed "g z g g").2 == [none, none, none, some (vimMove "first-line")]) },
    { name :=
        "a key bound in an active keymap and in the Vim state's keymap yields the active keymap's binding"
      run :=
        let active (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [("w", .motion "big-word")]]
        pure
          ((vimFed "w" active).2 == [some (vimMove "big-word")] &&
            (vimFed "w").2 == [some (vimMove "word")]) },
    { name :=
        "a prefix of a binding in an active keymap and of one in the Vim state's keymap goes on to either: the two lists are one walk"
      run :=
        let active (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [("g x", .motion "other")]]
        pure
          ((vimFed "g x" active).2 == [none, some (vimMove "other")] &&
            (vimFed "g g" active).2 == [none, some (vimMove "first-line")] &&
            (vimFed "g x").2 == [none, none]) },
    { name :=
        "the Vim scheme asks for the active keymaps of the view the key is for: another view's are not walked"
      run :=
        let active (view : ViewId) : List (Keymap Vim.Bound) :=
          if view.index == 1 then [vimKeymap [("m", .motion "late")]] else []
        pure
          ((vimFed "m" active ⟨1⟩).2 == [some (vimMove "late")] &&
            (vimFed "m" active ⟨0⟩).2 == [none]) },
    { name :=
        "the Vim scheme takes a key by its chord: a key from a window, with its physical code and repeated, continues and completes a sequence, and is reported pending as its chord"
      run :=
        let typed : Key :=
          { charKey "g" with
            physical := .code "KeyG", repeated := true }
        let fromWindow (typed : List Key) : Vim.State × List (Option Invocation) :=
          (Vim.scheme vimStates).feed vimNoMaps ⟨0⟩ vimInit typed
        let (state, yields) := fromWindow [typed, typed]
        let (begun, _) := fromWindow [typed]
        pure
          (yields == [none, some (vimMove "first-line")] && decide (state = vimInit) &&
            (Vim.scheme vimStates).pending begun == keys "g") },
    { name :=
        "an operator and then a motion yield one invocation on the motion's key: the operator over that motion, with no count"
      run :=
        pure
          ((vimFed "d w").2 == [none, some (vimOperate "delete" "motion" "word")] &&
            (vimFed "d g g").2 == [none, none, some (vimOperate "delete" "motion" "first-line")] &&
            (vimParsed "d w").2 ==
              [.nothing, .edit (.operate vimDelete (.motion "word") none none)]) },
    { name :=
        "an operator typed twice yields that operator over lines, with a count of 1: the doubled operator counts lines"
      run :=
        pure
          ((vimFed "d d").2 == [none, some (vimOperate "delete" "lines" "" 1)] &&
            (vimFed "y y").2 == [none, some (vimOperate "yank" "lines" "" 1)]) },
    { name :=
        "an unbound key after an operator yields no invocation and leaves no operator waiting, no prefix and no pending keys: the state is the initial state"
      run :=
        let (state, yields) := vimFed "d z"
        let (deeper, deeperYields) := vimFed "d g z"
        pure
          (yields == [none, none] && state.operator == none && state.walked == [] &&
            state.typed == [] &&
            decide (state = vimInit) &&
            deeperYields == [none, none, none] &&
            decide (deeper = vimInit) &&
            (vimFed "d z w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "a different operator after an operator, and a command after an operator, yield nothing and reset the edit"
      run :=
        let (other, otherYields) := vimFed "d c"
        let (command, commandYields) := vimFed "d u"
        pure
          (otherYields == [none, none] && decide (other = vimInit) &&
            commandYields == [none, none] &&
            decide (command = vimInit) &&
            (vimFed "d c w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "while an operator waits, a state with pending keymaps walks them in place of its own: a key its own keymaps bind to a command is a text object there after an operator, and the command alone; a key only its own bind resets after an operator; the state's keymaps hold for the rest; and a state with none walks its own"
      run :=
        let states :=
          vimStates.register
            { vimStates.initial with
              pending :=
                [vimKeymap
                    [("i", .textObject "inside"), ("d", .operator vimDelete),
                      ("w", .motion "word")]] }
        pure
          ((vimFed "d i" (states := states)).2 ==
              [none, some (vimOperate "delete" "text-object" "inside")] &&
            (vimFed "i" (states := states)).2 == (vimFed "i").2 &&
            (vimFed "d w" (states := states)).2 ==
              [none, some (vimOperate "delete" "motion" "word")] &&
            (vimFed "d x" (states := states)).2 == [none, none] &&
            (vimFed "d d" (states := states)).2 ==
              [none, some (vimOperate "delete" "lines" "" 1)] &&
            (vimFed "d i").2 == [none, none]) },
    { name :=
        "a text object after an operator is the operator's target, and a text object with no operator yields nothing and resets"
      run :=
        let (alone, aloneYields) := vimFed "t"
        pure
          ((vimFed "d t").2 == [none, some (vimOperate "delete" "text-object" "thing")] &&
            aloneYields == [none] &&
            decide (alone = vimInit)) },
    { name :=
        "a motion bound in an active keymap after the scheme was built is the target after each operator, and a move alone, with no further binding"
      run :=
        let scheme := Vim.scheme vimStates
        let late (_ : ViewId) : List (Keymap scheme.Binding) := [vimKeymap [("m", .motion "late")]]
        let typed (text : String) : List (Option Invocation) :=
          (scheme.feed late ⟨0⟩ scheme.init (keys text)).2
        pure
          (typed "d m" == [none, some (vimOperate "delete" "motion" "late")] &&
            typed "c m" == [none, some (vimOperate "change" "motion" "late")] &&
            typed "y m" == [none, some (vimOperate "yank" "motion" "late")] &&
            typed "m" == [some (vimMove "late")] &&
            (scheme.feed vimNoMaps ⟨0⟩ scheme.init (keys "d m")).2 == [none, none]) },
    { name :=
        "the Vim scheme reports an operator waiting, and the prefix walked after it, as pending keys, and none after the edit"
      run :=
        pure
          (vimPending "d" == keys "d" && vimPending "d g" == keys "d g" &&
            vimPending "d g g" == [] &&
            vimPending "d d" == []) },
    { name :=
        "d 2 w yields one invocation, on its last key: operate, delete, over the motion word, with a count of 2"
      run :=
        pure
          ((vimFed "d 2 w").2 ==
              [none, none,
                some
                  { command := "operate"
                    arguments := [.str "delete", .str "motion", .str "word", .nat 2, .str ""] }] &&
            (vimParsed "d 2 w").2.getLast? ==
              some (.edit (.operate vimDelete (.motion "word") (some 2) none))) },
    { name :=
        "2 d 3 w yields the invocation of d 2 w with a count of 6: a count before the operator and one before the motion multiply"
      run :=
        pure
          ((vimFed "2 d 3 w").2 ==
              [none, none, none,
                some
                  { command := "operate"
                    arguments := [.str "delete", .str "motion", .str "word", .nat 6, .str ""] }] &&
            (vimFed "3 d w").2.getLast? == some (some (vimOperate "delete" "motion" "word" 3))) },
    { name :=
        "a count before a doubled operator, and one inside it, count lines: 3 d d is three lines and 2 d 3 d is six"
      run :=
        pure
          ((vimFed "3 d d").2 == [none, none, some (vimOperate "delete" "lines" "" 3)] &&
            (vimFed "2 d 3 d").2 == [none, none, none, some (vimOperate "delete" "lines" "" 6)]) },
    { name :=
        "the digits of a count are read in base ten, and 0 after a digit is a digit: 1 0 w moves by 10"
      run :=
        pure
          ((vimFed "1 0 w").2 == [none, none, some (vimMove "word" 10)] &&
            (vimFed "1 2 3 w").2.getLast? == some (some (vimMove "word" 123))) },
    { name :=
        "0 with no count being typed is looked up like any key, so it yields the motion it is bound to, after an operator too"
      run :=
        pure
          ((vimFed "0").2 == [some (vimMove "line-start")] &&
            (vimFed "d 0").2 == [none, some (vimOperate "delete" "motion" "line-start")]) },
    { name :=
        "a count before a motion of two keys is carried by its move, and a command carries a count"
      run :=
        pure
          ((vimFed "2 g g").2 == [none, none, some (vimMove "first-line" 2)] &&
            (vimFed "3 u").2 ==
              [none, some { command := "undo", arguments := [.nat 3, .str ""] }] &&
            (vimParsed "2 g g").2.getLast? == some (.edit (.move "first-line" (some 2)))) },
    { name :=
        "a digit after a keymap prefix is looked up as a key of the sequence, not read as a count"
      run :=
        let active (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [("g 2", .motion "second")]]
        pure
          ((vimFed "g 2" active).2 == [none, some (vimMove "second")] &&
            (vimFed "3 g 2" active).2 == [none, none, some (vimMove "second" 3)]) },
    { name :=
        "a digit with control held is not a count: unbound, it resets the count typed before it"
      run := pure ((vimFed "2 C-3 w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "the count of the edit begun is the product of the counts typed so far, and none when no digit was typed"
      run :=
        pure
          ((vimFed "d").1.count == none && (vimFed "2").1.count == some 2 &&
            (vimFed "2 d").1.count == some 2 &&
            (vimFed "2 d 3").1.count == some 6 &&
            (vimFed "d 1 2").1.count == some 12) },
    { name :=
        "an unbound key after an operator and a count yields no invocation and leaves no count, no operator and no prefix: the state is the initial state"
      run :=
        let (state, yields) := vimFed "d 2 z"
        let (before, beforeYields) := vimFed "2 d z"
        pure
          (yields == [none, none, none] && state.count == none && state.operator == none &&
            state.walked == [] &&
            state.typed == [] &&
            decide (state = vimInit) &&
            beforeYields == [none, none, none] &&
            decide (before = vimInit) &&
            (vimFed "2 z w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "the Vim scheme reports the digits of a count among the pending keys, in the order typed"
      run :=
        pure
          (vimPending "d 2" == keys "d 2" && vimPending "2 d 3" == keys "2 d 3" &&
            vimPending "1 0" == keys "1 0" &&
            vimPending "2 d 3 w" == []) },
    { name :=
        "a register named before an operator is carried by its edit: the key after the register prefix names it by the text it prints"
      run :=
        pure
          ((vimFed "\" + y w").2 ==
              [none, none, none, some (vimOperate "yank" "motion" "word" 0 "+")] &&
            (vimParsed "\" + y w").2.getLast? ==
              some (.edit (.operate vimYank (.motion "word") none (some "+"))) &&
            (vimFed "\" A d d").2.getLast? == some (some (vimOperate "delete" "lines" "" 1 "A"))) },
    { name :=
        "a register named before a command is carried by its edit, and a digit after the register prefix names a register"
      run :=
        pure
          ((vimFed "\" a x").2 ==
              [none, none, some { command := "delete-char", arguments := [.nat 0, .str "a"] }] &&
            (vimFed "\" 2 x").2 ==
              [none, none, some { command := "delete-char", arguments := [.nat 0, .str "2"] }]) },
    { name :=
        "a move carries no register: one named before a motion is dropped when the motion completes"
      run :=
        let (state, yields) := vimFed "\" a w"
        pure
          (yields == [none, none, some (vimMove "word")] && decide (state = vimInit) &&
            (vimFed "\" a w x").2.getLast? ==
              some (some { command := "delete-char", arguments := [.nat 0, .str ""] })) },
    { name :=
        "counts before the register prefix and after the register multiply: 2 \" a 3 d d is six lines into a"
      run :=
        pure
          ((vimFed "2 \" a 3 d d").2 ==
            [none, none, none, none, none, some (vimOperate "delete" "lines" "" 6 "a")]) },
    { name :=
        "a key that prints nothing after the register prefix yields nothing and resets the edit"
      run :=
        let (state, yields) := vimFed "2 \" <Escape>"
        pure
          (yields == [none, none, none] && decide (state = vimInit) &&
            (vimFed "\" C-a w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "the register prefix after an operator, and after a register is already named, yields nothing and resets the edit"
      run :=
        let (afterOperator, operatorYields) := vimFed "d \""
        let (twice, twiceYields) := vimFed "\" a \""
        pure
          (operatorYields == [none, none] && decide (afterOperator = vimInit) &&
            twiceYields == [none, none, none] &&
            decide (twice = vimInit) &&
            (vimFed "d \" w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "the Vim scheme reports the register prefix and the key that names the register among the pending keys"
      run :=
        pure
          (vimPending "\"" == keys "\"" && vimPending "\" a" == keys "\" a" &&
            vimPending "\" a d" == keys "\" a d" &&
            vimPending "\" a d d" == []) },
    { name :=
        "an operator bound to two keys waits with no prefix left: the motion typed next, of one key or of two, is its target"
      run :=
        pure
          ((vimFed "g u w" vimTwoKeyMaps).2 ==
              [none, none, some (vimOperate "lowercase" "motion" "word")] &&
            (vimFed "g u g g" vimTwoKeyMaps).2 ==
              [none, none, none, some (vimOperate "lowercase" "motion" "first-line")] &&
            (vimParsed "g u w" vimTwoKeyMaps).2.getLast? ==
              some (.edit (.operate { name := "lowercase" } (.motion "word") none none))) },
    { name :=
        "a digit after an operator bound to two keys is read as a count, and multiplies with one typed before the operator"
      run :=
        pure
          ((vimFed "g u 2 w" vimTwoKeyMaps).2 ==
              [none, none, none, some (vimOperate "lowercase" "motion" "word" 2)] &&
            (vimFed "3 g u 2 w" vimTwoKeyMaps).2.getLast? ==
              some (some (vimOperate "lowercase" "motion" "word" 6))) },
    { name :=
        "an operator bound to two keys, typed twice, yields that operator over lines, and a different operator after it resets"
      run :=
        let (other, otherYields) := vimFed "g u d" vimTwoKeyMaps
        pure
          ((vimFed "g u g u" vimTwoKeyMaps).2 ==
              [none, none, none, some (vimOperate "lowercase" "lines" "" 1)] &&
            (vimFed "g u 3 g u" vimTwoKeyMaps).2.getLast? ==
              some (some (vimOperate "lowercase" "lines" "" 3)) &&
            otherYields == [none, none, none] &&
            decide (other = vimInit)) },
    { name :=
        "the Vim scheme reports both keys of an operator bound to two keys as pending, with the keys typed after it, and none after the edit"
      run :=
        pure
          (vimPending "g u" vimTwoKeyMaps == keys "g u" &&
            vimPending "g u g" vimTwoKeyMaps == keys "g u g" &&
            vimPending "g u 2" vimTwoKeyMaps == keys "g u 2" &&
            vimPending "g u w" vimTwoKeyMaps == [] &&
            vimPending "g u g u" vimTwoKeyMaps == []) },
    { name :=
        "a register prefix bound to two keys leaves no prefix: the key after it names the register, and the keys after that are looked up from the start"
      run :=
        let (twice, twiceYields) := vimFed "g r a g r" vimTwoKeyMaps
        pure
          ((vimFed "g r a y w" vimTwoKeyMaps).2 ==
              [none, none, none, none, some (vimOperate "yank" "motion" "word" 0 "a")] &&
            (vimFed "g r a g u g u" vimTwoKeyMaps).2.getLast? ==
              some (some (vimOperate "lowercase" "lines" "" 1 "a")) &&
            (vimFed "g r 2 x" vimTwoKeyMaps).2 ==
              [none, none, none,
                some { command := "delete-char", arguments := [.nat 0, .str "2"] }] &&
            (vimFed "2 g r a 3 d d" vimTwoKeyMaps).2.getLast? ==
              some (some (vimOperate "delete" "lines" "" 6 "a")) &&
            twiceYields == [none, none, none, none, none] &&
            decide (twice = vimInit)) },
    { name :=
        "the Vim scheme reports both keys of a register prefix bound to two keys as pending, with the key that names the register"
      run :=
        pure
          (vimPending "g r" vimTwoKeyMaps == keys "g r" &&
            vimPending "g r a" vimTwoKeyMaps == keys "g r a" &&
            vimPending "g r a d" vimTwoKeyMaps == keys "g r a d" &&
            vimPending "g r a d d" vimTwoKeyMaps == []) },
    { name :=
        "a key bound to a command name the view's state has a run-table entry for completes that entry's edit: over the selection in a visual state it ends the selection, leaving the view in the initial state, and a yank is not the last change where a deletion is"
      run :=
        let (copied, copiedIn, copiedYields) := vimRunFed "v C"
        let (cut, cutIn, cutYields) := vimRunFed "v X"
        pure
          (copiedYields.getLast? == some (some (vimOperate "yank" "selection" "" 0 "+")) &&
            copiedIn == "normal" &&
            copied.lastChange == none &&
            cutYields.getLast? == some (some (vimOperate "delete" "selection" "" 0 "+")) &&
            cutIn == "normal" &&
            cut.lastChange == some vimRunCut) },
    { name :=
        "a run-table entry that names a state enters it: S in normal state yields t-enter and leaves the view in visual-line"
      run :=
        pure
          (vimRunFed "S" ==
            ((vimFed "S" vimRunMaps ⟨0⟩ vimRunStates).1, "visual-line",
              [some { command := "t-enter", arguments := [.nat 0, .str ""] }])) },
    { name :=
        "a command name the view's state has no run-table entry for runs the command of that name and enters nothing: N anywhere, and C in normal state"
      run :=
        pure
          ((vimRunFed "N").2 ==
              ("normal", [some { command := "t-none", arguments := [.nat 0, .str ""] }]) &&
            (vimRunFed "C").2 ==
              ("normal", [some { command := "t-copy", arguments := [.nat 0, .str ""] }]) &&
            (vimRunFed "v N").2.1 == "visual" &&
            (vimRunFed "v N").2.2.getLast? ==
              some (some { command := "t-none", arguments := [.nat 0, .str ""] })) },
    { name :=
        "a run-table entry is used as written: a count and a register typed before its key are dropped"
      run :=
        pure
          ((vimRunFed "v 2 C").2.2.getLast? ==
              some (some (vimOperate "yank" "selection" "" 0 "+")) &&
            (vimRunFed "v \" a C").2.2.getLast? ==
              some (some (vimOperate "yank" "selection" "" 0 "+"))) },
    { name :=
        "a binding of the active keymaps to another command wins over the run table: with C bound to t-other in a keymap before, v C runs t-other and stays in visual"
      run :=
        let rebound (view : ViewId) : List (Keymap Vim.Bound) :=
          vimKeymap [("C", .command { name := "t-other" })] :: vimRunMaps view
        let (state, yields) := vimFed "v C" rebound ⟨0⟩ vimRunStates
        pure
          (yields.getLast? ==
              some (some { command := "t-other", arguments := [.nat 0, .str ""] }) &&
            state.stateOf vimRunStates ⟨0⟩ == "visual") },
    { name :=
        "a menu item's invocation of a name the view's state has a run-table entry for is that entry's edit, compiled, with the state the entry leaves; one of a name it has none for, or one with arguments, comes back as it was, with the state"
      run :=
        let visual := (vimRunFed "v").1
        let (copied, copy) := vimInvoked visual { command := "t-copy" }
        let (entered, enter) := vimInvoked vimInit { command := "t-enter" }
        let unchanged (state : Vim.State) (invocation : Invocation) : Bool :=
          let (after, yielded) := vimInvoked state invocation
          decide (after = state) && yielded == invocation
        pure
          (copy == vimOperate "yank" "selection" "" 0 "+" &&
            copied.stateOf vimRunStates ⟨0⟩ == "normal" &&
            enter == { command := "t-enter", arguments := [.nat 0, .str ""] } &&
            entered.stateOf vimRunStates ⟨0⟩ == "visual-line" &&
            (vimInvoked visual { command := "t-cut" }).1.lastChange == some vimRunCut &&
            unchanged visual { command := "t-none" } &&
            unchanged vimInit { command := "t-copy" } &&
            unchanged visual { command := "t-copy", arguments := [.nat 1] }) },
    { name :=
        "an active keymap's prefix shadows a Vim state's binding of the same keys: with insert state binding C-w and active maps binding C-w x, C-w is pending in insert state and C-w x runs the active binding; with no active maps C-w runs the state's"
      run :=
        let insert := vimStates.get "insert"
        let states :=
          vimStates.register
            { insert with
              keymaps :=
                insert.keymaps ++ [vimKeymap [("C-w", .command { name := "t-delete-word" })]] }
        let active (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("C-w x", .command { name := "t-exchange" })]]
        let ran (name : String) : Option Invocation :=
          some { command := name, arguments := [.nat 0, .str ""] }
        let (inInsert, yields) := vimFed "i C-w x" active ⟨0⟩ states
        pure
          (yields.drop 1 == [none, ran "t-exchange"] && inInsert.stateOf states ⟨0⟩ == "insert" &&
            (vimFed "i C-w" vimNoMaps ⟨0⟩ states).2.drop 1 == [ran "t-delete-word"]) }]

/-- `vimStates` with a state the checks register, `test`, whose keymap
binds `m` to a motion and whose cursor is an underline, and with `q` bound
in the normal state's keymaps to a command that enters it. -/
def vimWithTest : Vim.States :=
  let registered :=
    vimStates.register
      { name := "test", keymaps := [vimKeymap [("m", .motion "test-motion")]],
        cursor := .underline }
  registered.register
    { registered.initial with
      keymaps :=
        vimKeymap [("q", .command { name := "enter-test", enters := some "test" })] ::
          registered.initial.keymaps }

/-- The invocation the command `name` compiles to when a key bound to it is
typed with no count and no register. -/
def vimRun (name : String) : Invocation :=
  { command := name, arguments := [.nat 0, .str ""] }

/-- The checks of the Vim scheme's states (`Editor/InputScheme/Vim.lean`):
which Vim state a view is in, how one is entered, and what the grammar
reads of a state's record. -/
def vimStateChecks : List Check :=
  [{  name :=
        "the Vim scheme reports a view with no entry by the initial record: its cursor shape in the face cursor. and its name, one status field, its name in capitals in the badge face mode-line.state. and its name, its shape, no selecting, no insert session, and a view that takes no text"
      run :=
        let scheme := Vim.scheme vimStates
        pure
          (scheme.report vimInit ⟨0⟩ ==
              { cursor := { shape := .block, face := ⟨"cursor.normal"⟩ }
                status := #[{ text := "NORMAL", face := Vim.stateFace "normal" }]
                shape := .inclusive, selecting := false, session := false, takesText := false } &&
            scheme.report vimInit ⟨5⟩ == scheme.report vimInit ⟨0⟩ &&
            Vim.stateFace "normal" == ⟨"mode-line.state.normal"⟩ &&
            Vim.stateFace "visual-line" == ⟨"mode-line.state.visual-line"⟩) },
    { name :=
        "after a key that enters a state where typing is text, the Vim scheme reports that record's cursor, name and shape, an insert session, and a view that takes text"
      run :=
        let scheme := Vim.scheme vimStates
        pure
          (scheme.report (vimFed "i").1 ⟨0⟩ ==
            { cursor := { shape := .bar, face := ⟨"cursor.insert"⟩ }
              status := #[{ text := "INSERT", face := Vim.stateFace "insert" }], shape := .exclusive
              selecting := false, session := true, takesText := true }) },
    { name :=
        "the Vim scheme reports selecting for a view in a state whose operators act on the selection, and the record a check registers by its own cursor, name and shape"
      run :=
        let states := vimWithTest.register { vimWithTest.get "test" with shape := .line }
        let visual := (Vim.scheme vimStates).report (vimFed "v").1 ⟨0⟩
        pure
          (visual.selecting && !visual.session && !visual.takesText && visual.shape == .inclusive &&
            visual.status == #[{ text := "VISUAL", face := Vim.stateFace "visual" }] &&
            (Vim.scheme states).report (vimFed "q" (states := states)).1 ⟨0⟩ ==
              { cursor := { shape := .underline, face := ⟨"cursor.test"⟩ }
                status := #[{ text := "TEST", face := Vim.stateFace "test" }], shape := .line
                selecting := false, session := false, takesText := false }) },
    { name :=
        "the Vim scheme's report is one view's: a key for one view leaves another view's report as it was, a view told closed is reported by the initial record again, and a view told to be the minibuffer's by the record the registry names for it"
      run :=
        let scheme := Vim.scheme vimStates
        let (entered, _) := vimFed "i"
        let closed : Vim.State := scheme.closeView ⟨0⟩ entered
        let told : Vim.State := scheme.openMinibuffer ⟨3⟩ vimInit
        pure
          (scheme.report entered ⟨1⟩ == scheme.report vimInit ⟨1⟩ &&
            scheme.report entered ⟨0⟩ != scheme.report vimInit ⟨0⟩ &&
            scheme.report closed ⟨0⟩ == scheme.report vimInit ⟨0⟩ &&
            scheme.report told ⟨3⟩ == scheme.report entered ⟨0⟩ &&
            scheme.report told ⟨0⟩ == scheme.report vimInit ⟨0⟩) },
    { name :=
        "a state a check registers, entered by a key bound in the normal state's keymap, is the view's state, and the next key is looked up in its keymap"
      run :=
        let (state, yields) := vimFed "q m" (states := vimWithTest)
        pure
          ((vimFed "m" (states := vimWithTest)).2 == [none] &&
            vimInit.stateOf vimWithTest ⟨0⟩ == "normal" &&
            yields == [some (vimRun "enter-test"), some (vimMove "test-motion")] &&
            state.stateOf vimWithTest ⟨0⟩ == "test" &&
            (state.record vimWithTest ⟨0⟩).cursor == .underline &&
            (vimFed "q w" (states := vimWithTest)).2 == [some (vimRun "enter-test"), none]) },
    { name :=
        "an operator and a command that name a state leave the view in it, and ones that name none leave it where it was"
      run :=
        pure
          ((vimFed "c w").1.stateOf vimStates ⟨0⟩ == "insert" &&
            (vimFed "i").1.stateOf vimStates ⟨0⟩ == "insert" &&
            (vimFed "d w").1.stateOf vimStates ⟨0⟩ == "normal" &&
            (vimFed "u").1.stateOf vimStates ⟨0⟩ == "normal" &&
            (vimFed "v w").1.stateOf vimStates ⟨0⟩ == "visual") },
    { name :=
        "a Vim state is one view's: after a key for one view entered a state, another view is in the initial state and its keys are looked up there"
      run :=
        let (state, _) := vimFed "q" (states := vimWithTest)
        let typed (text : String) (view : ViewId) : List (Option Invocation) :=
          (vimFedFrom state text (view := view) (states := vimWithTest)).2
        pure
          (state.stateOf vimWithTest ⟨0⟩ == "test" && state.stateOf vimWithTest ⟨1⟩ == "normal" &&
            typed "m" ⟨0⟩ == [some (vimMove "test-motion")] &&
            typed "m" ⟨1⟩ == [none] &&
            typed "w" ⟨1⟩ == [some (vimMove "word")] &&
            typed "w" ⟨0⟩ == [none]) },
    { name :=
        "a view not in the initial state has one entry in the scheme's state, and entering the initial state removes it: the state is then the initial state"
      run :=
        let (both, _) := vimFedFrom (vimFed "i").1 "v" (view := ⟨1⟩)
        pure
          ((vimFed "i").1.current == [(⟨0⟩, "insert")] && (vimFed "i <Escape>").1.current == [] &&
            decide ((vimFed "v <Escape>").1 = vimInit) &&
            (vimFed "v i").1.current == [(⟨0⟩, "insert")] &&
            both.current == [(⟨0⟩, "insert"), (⟨1⟩, "visual")] &&
            (vimFedFrom both "<Escape>").1.current == [(⟨1⟩, "visual")]) },
    { name :=
        "a state's name that the registry does not have is read as the initial state, and a command that enters such a name enters the initial state"
      run :=
        let stale : Vim.State := { current := [(⟨0⟩, "gone")] }
        let nowhere (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("n", .command { name := "leave", enters := some "nowhere" })]]
        pure
          (stale.stateOf vimStates ⟨0⟩ == "normal" &&
            (vimFedFrom stale "w").2 == [some (vimMove "word")] &&
            (vimFed "i n" nowhere).1.current == [] &&
            decide ((vimFed "n" nowhere).1 = vimInit)) },
    { name :=
        "an edit begun by a key for one view is completed by a key for another, looked up in the keymaps of that view's state, and the state it enters is that view's"
      run :=
        let (entered, _) := vimFed "q" (view := ⟨1⟩) (states := vimWithTest)
        let (begun, _) := vimFedFrom entered "2 c" (view := ⟨0⟩) (states := vimWithTest)
        let (state, yields) := vimFedFrom begun "m" (view := ⟨1⟩) (states := vimWithTest)
        pure
          (yields == [some (vimOperate "change" "motion" "test-motion" 2)] &&
            state.current == [(⟨1⟩, "insert")] &&
            (vimFedFrom begun "m" (view := ⟨0⟩) (states := vimWithTest)).2 == [none]) },
    { name :=
        "an unbound key resets the edit begun and keeps which state each view is in: the state is the one the view was left in when it entered"
      run :=
        let (entered, _) := vimFed "v"
        let (state, yields) := vimFedFrom entered "2 g z"
        pure
          (yields == [none, none, none] && state.current == [(⟨0⟩, "visual")] &&
            decide (state = entered)) },
    { name :=
        "in a state that inserts text an unbound printable key yields a self-insert of the text it prints: a letter, the space, and a shifted letter from a window"
      run :=
        let (inserting, _) := vimFed "i"
        let shifted : Key :=
          { logical := .character "A", physical := .code "KeyA", modifiers := { shift := true } }
        let fromWindow : Vim.State × List (Option Invocation) :=
          (Vim.scheme vimStates).feed vimNoMaps ⟨0⟩ inserting [shifted]
        pure
          (Vim.selfInsert "a" == { command := "self-insert", arguments := [.str "a"] } &&
            (vimFedFrom inserting "a").2 == [some (Vim.selfInsert "a")] &&
            (vimFedFrom inserting "SPC w").2 ==
              [some (Vim.selfInsert " "), some (Vim.selfInsert "w")] &&
            fromWindow.2 == [some (Vim.selfInsert "A")]) },
    { name := "in a state that does not insert text an unbound printable key yields nothing"
      run :=
        pure
          ((vimFed "a").2 == [none] && (vimFed "v a").2.getLast? == some none &&
            (vimFed "i <Escape> a").2.getLast? == some none) },
    { name :=
        "in a state that inserts text a digit is text and not a count, 0 among them, and the key typed next carries no count"
      run :=
        let (inserting, _) := vimFed "i"
        let (state, yields) := vimFedFrom inserting "2 0"
        pure
          (yields == [some (Vim.selfInsert "2"), some (Vim.selfInsert "0")] &&
            state.count == none &&
            (vimFedFrom inserting "2 <Escape> w").2.getLast? == some (some (vimMove "word"))) },
    { name :=
        "in a state that inserts text an unbound key that prints nothing yields nothing and leaves the view in the state: a named key, and a character with control held"
      run :=
        let (inserting, _) := vimFed "i"
        let (state, yields) := vimFedFrom inserting "<Enter> C-z"
        pure (yields == [none, none] && decide (state = inserting)) },
    { name :=
        "in a state that inserts text an unbound key after a pending prefix is dropped with the prefix: neither is text"
      run :=
        let (inserting, _) := vimFed "i"
        let active (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("j k", .command { name := "normal", enters := some "normal" })]]
        let (state, yields) := vimFedFrom inserting "j z" active
        pure
          (yields == [none, none] && decide (state = inserting) &&
            (vimFedFrom inserting "j" active).1.typed == keys "j" &&
            (vimFedFrom inserting "j k" active).1.current == []) },
    { name :=
        "a self-insert leaves the scheme's state as it was but for the text kept for the last change, with nothing pending; where no text is being kept it leaves the whole state as it was"
      run :=
        let (inserting, _) := vimFed "i"
        let (state, _) := vimFedFrom inserting "a b"
        let minibuffer := Vim.State.openMinibuffer vimStates ⟨1⟩ vimInit
        let (typed, yields) := vimFedFrom minibuffer "a b" (view := ⟨1⟩)
        pure
          (decide ({ state with inserted := inserting.inserted } = inserting) &&
            state.typed == [] &&
            yields.length == 2 &&
            decide (typed = minibuffer)) },
    { name :=
        "in a state where operators act on the selection an operator yields its edit over the selection at once, waiting for no motion, and the view is then in the initial state"
      run :=
        let (state, yields) := vimFed "v d"
        pure
          (yields == [some (vimRun "visual"), some (vimOperate "delete" "selection" "")] &&
            (vimParsed "v d").2.getLast? ==
              some (.edit (.operate vimDelete .selection none none)) &&
            decide ({ state with lastChange := none } = vimInit) &&
            (vimFed "v d w").2.getLast? == some (some (vimMove "word"))) },
    { name :=
        "an operator over the selection that names a state leaves the view in that state, and one that names none in the initial state"
      run :=
        pure
          ((vimFed "v c").1.current == [(⟨0⟩, "insert")] &&
            (vimFed "v c").2.getLast? == some (some (vimOperate "change" "selection" "")) &&
            (vimFed "v y").1.current == [] &&
            (vimFed "v y").2.getLast? == some (some (vimOperate "yank" "selection" ""))) },
    { name :=
        "a count and a register typed before an operator over the selection are carried by its edit"
      run :=
        pure
          ((vimFed "v 2 \" a d").2 ==
            [some (vimRun "visual"), none, none, none,
              some (vimOperate "delete" "selection" "" 2 "a")]) },
    { name :=
        "in a state where operators act on the selection a motion is still a move, and the view stays in the state"
      run :=
        let (state, yields) := vimFed "v 2 w"
        pure
          (yields == [some (vimRun "visual"), none, some (vimMove "word" 2)] &&
            state.current == [(⟨0⟩, "visual")]) },
    { name :=
        "after d 2 w the scheme's last change is the edit d 2 w parsed to, and a move typed after it leaves the last change as it was"
      run :=
        let (state, parsed) := vimParsed "d 2 w"
        let (moved, _) := vimParsedFrom state "w 3 g g"
        pure
          (parsed.getLast? == some (.edit (.operate vimDelete (.motion "word") (some 2) none)) &&
            state.lastChange.map Vim.Parsed.edit == parsed.getLast? &&
            moved.lastChange == state.lastChange &&
            vimInit.lastChange == none &&
            (vimParsed "w").1.lastChange == none) },
    { name :=
        "an edit with an operator that changes no text does not replace the last change, and one with an operator that changes text does"
      run :=
        let (state, _) := vimParsed "d 2 w"
        pure
          ((vimParsedFrom state "y w").1.lastChange == state.lastChange &&
            (vimParsed "y w").1.lastChange == none &&
            (vimParsedFrom state "\" a c c").1.lastChange ==
              some (.operate vimChange .lines (some 1) (some "a"))) },
    { name :=
        "a command that changes text replaces the last change, with its count and register, and one that does not leaves it"
      run :=
        let (state, _) := vimParsed "d 2 w"
        pure
          ((vimParsedFrom state "3 \" a x").1.lastChange ==
              some (.run { name := "delete-char", changes := true } (some 3) (some "a")) &&
            (vimParsedFrom state "u").1.lastChange == state.lastChange &&
            (vimParsed "i").1.lastChange == some (.run vimInsert none none)) },
    { name := "an unbound key, a reset edit and entering a state keep the last change"
      run :=
        let (state, _) := vimParsed "d 2 w"
        pure
          (state.lastChange.isSome && (vimParsedFrom state "z").1.lastChange == state.lastChange &&
            (vimParsedFrom state "2 d z").1.lastChange == state.lastChange &&
            (vimParsedFrom state "d u").1.lastChange == state.lastChange &&
            (vimParsedFrom state "v").1.lastChange == state.lastChange &&
            (vimParsedFrom state "v <Escape>").1.lastChange == state.lastChange) },
    { name :=
        "an operator over the selection is the last change when it changes text, and is not when it changes none"
      run :=
        let (state, _) := vimParsed "d 2 w"
        pure
          ((vimParsedFrom state "v d").1.lastChange ==
              some (.operate vimDelete .selection none none) &&
            (vimParsedFrom state "v y").1.lastChange == state.lastChange) },
    { name := "typed text does not replace the last change"
      run :=
        let (inserting, _) := vimParsed "i"
        pure ((vimParsedFrom inserting "a b").1.lastChange == inserting.lastChange) },
    { name :=
        "the text typed in the insert session the last change began is kept: a change that enters a state where typing is text keeps the empty text for its view, the keys typed there are added in order, and the last change is as it was"
      run :=
        let (changing, _) := vimParsed "c w"
        let (typed, _) := vimParsedFrom changing "a b 1"
        pure
          (vimInit.inserted == none && vimInit.recording == none && changing.inserted == some "" &&
            changing.recording == some ⟨0⟩ &&
            typed.inserted == some "ab1" &&
            typed.recording == some ⟨0⟩ &&
            typed.lastChange == changing.lastChange &&
            (vimParsed "i x y").1.inserted == some "xy") },
    { name :=
        "the key that leaves the state ends the keeping and keeps the text: text typed in a later session that no change began is not added, and a reset keeps what was kept"
      run :=
        let peeking (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("z", .command { name := "peek", enters := some "insert" })]]
        let (left, _) := vimParsed "c w a b <Escape>"
        pure
          (left.inserted == some "ab" && left.recording == none &&
            (vimParsedFrom left "z q" peeking).1.inserted == some "ab" &&
            (vimParsedFrom left "d z").1.inserted == some "ab" &&
            (vimParsedFrom left "u").1.inserted == some "ab" &&
            (vimParsedFrom left "v <Escape>").1.inserted == some "ab") },
    { name :=
        "a change that enters no state where typing is text keeps no typed text, and a second change that begins a session empties what the first kept"
      run :=
        let (left, _) := vimParsed "c w a b <Escape>"
        pure
          ((vimParsed "d w").1.inserted == none && (vimParsedFrom left "x").1.inserted == none &&
            (vimParsedFrom left "x").1.recording == none &&
            (vimParsedFrom left "v d").1.inserted == none &&
            (vimParsedFrom left "c w").1.inserted == some "" &&
            (vimParsedFrom left "c w q").1.inserted == some "q") },
    { name :=
        "text typed in another view is not added, the minibuffer's included, and the view being closed ends the keeping and keeps the text"
      run :=
        let (typed, _) := vimParsed "c w a"
        let other := Vim.State.openMinibuffer vimStates ⟨1⟩ typed
        let (elsewhere, parsed) := vimParsedFrom other "q" (view := ⟨1⟩)
        let closed := Vim.State.closeView ⟨0⟩ typed
        pure
          (parsed == [.text "q"] && elsewhere.inserted == some "a" &&
            elsewhere.recording == some ⟨0⟩ &&
            (vimParsedFrom elsewhere "b").1.inserted == some "ab" &&
            closed.inserted == some "a" &&
            closed.recording == none &&
            (Vim.State.closeView ⟨1⟩ elsewhere).recording == some ⟨0⟩) },
    { name :=
        "a committed text the scheme is told of is typed text: it is added to what is kept for the last change when it was committed in the view being kept for, and not when in another"
      run :=
        let scheme := Vim.scheme vimStates
        let (typed, _) := vimParsed "c w a"
        let here : Vim.State := scheme.committed ⟨0⟩ "かな" typed
        let there : Vim.State := scheme.committed ⟨1⟩ "かな" typed
        let idle : Vim.State := scheme.committed ⟨0⟩ "かな" vimInit
        pure
          (here.inserted == some "aかな" &&
            decide ({ here with inserted := typed.inserted } = typed) &&
            decide (there = typed) &&
            decide (idle = vimInit)) },
    { name :=
        "a replay compiles to the repeat command, with whether the change began an insert session, the text typed in it, the command the change compiles to and then the change's own arguments; it changes no text and enters no state"
      run :=
        let change : Vim.Edit := .operate vimChange (.motion "word") (some 2) (some "a")
        pure
          ((Vim.Edit.replay change (some "xy")).compile ==
              { command := Vim.repeatCommand
                arguments :=
                  [.bool true, .str "xy", .str Vim.operateCommand, .str "change", .str "motion",
                    .str "word", .nat 2, .str "a"] } &&
            (Vim.Edit.replay (.run vimInsert none none) none).compile ==
              { command := Vim.repeatCommand
                arguments := [.bool false, .str "", .str "insert", .nat 0, .str ""] } &&
            !(Vim.Edit.replay change (some "xy")).changes &&
            (Vim.Edit.replay change (some "xy")).enters == none &&
            !Vim.repeatCommand.isEmpty) },
    { name :=
        "the repeat key yields the last change to replay, with the text typed in its session: nothing when there is no last change, and after a change the repeat command with the change's invocation; the replay is not the last change, and the view stays in the state it is in"
      run :=
        let dot (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [(".", .repeat)]]
        let (deleted, _) := vimFed "d 2 w"
        let (changed, _) := vimFed "c w a b <Escape>"
        let replayed (arguments : List Argument) : List (Option Invocation) :=
          [some { command := Vim.repeatCommand, arguments }]
        let (idle, nothing) := vimFed "." dot
        let (again, yielded) := vimFedFrom changed "." dot
        pure
          (nothing == [none] && decide (idle = vimInit) &&
            (vimFedFrom deleted "." dot).2 ==
              replayed
                [.bool false, .str "", .str Vim.operateCommand, .str "delete", .str "motion",
                  .str "word", .nat 2, .str ""] &&
            decide ((vimFedFrom deleted "." dot).1 = deleted) &&
            yielded ==
              replayed
                [.bool true, .str "ab", .str Vim.operateCommand, .str "change", .str "motion",
                  .str "word", .nat 0, .str ""] &&
            decide (again = changed)) },
    { name :=
        "a count typed before the repeat key replaces the last change's count, in what is yielded and in the last change, so a later bare repeat carries it; and while an operator waits the repeat key resets and yields nothing"
      run :=
        let dot (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [(".", .repeat)]]
        let (deleted, _) := vimFed "d 2 w"
        let thrice : Option Invocation :=
          some
            { command := Vim.repeatCommand
              arguments :=
                [.bool false, .str "", .str Vim.operateCommand, .str "delete", .str "motion",
                  .str "word", .nat 3, .str ""] }
        let (counted, yielded) := vimFedFrom deleted "3 ." dot
        let (waiting, reset) := vimFedFrom deleted "d ." dot
        pure
          (yielded == [none, thrice] &&
            counted.lastChange == some (.operate vimDelete (.motion "word") (some 3) none) &&
            counted.typed == [] &&
            (vimFedFrom counted "." dot).2 == [thrice] &&
            reset == [none, none] &&
            decide (waiting = deleted)) },
    { name :=
        "a key a mode binds runs its command in normal state, and in insert state it is typed text, while a key an active keymap binds for no mode still runs there"
      run :=
        let scheme := Vim.scheme vimStates
        let maps (_ : ViewId) : List (Keymap Vim.Bound) :=
          [Keymap.ofList
              [(keys "z", scheme.modeCommand "mode-thing"),
                (keys "Z", scheme.command "global-thing")]]
        let (inserting, _) := vimFed "i"
        pure
          ((vimFed "z" maps).2 == [some (vimRun "mode-thing")] &&
            (vimFedFrom inserting "z Z" maps).2 ==
              [some (Vim.selfInsert "z"), some (vimRun "global-thing")]) },
    { name := "a mode's binding that wraps a motion moves, and is an operator's target"
      run :=
        let maps (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("z", .mode (.motion "zed"))]]
        pure
          ((vimFed "z" maps).2 == [some (vimMove "zed")] &&
            (vimFed "d z" maps).2 == [none, some (vimOperate "delete" "motion" "zed")]) },
    { name :=
        "a hand-tuned key the Vim scheme has for a mode runs its command in normal state, and in insert state it is typed text"
      run :=
        let scheme :=
          Vim.scheme vimStates
            { vimModeKeys with tuned := [("tuning", keys "z", .command { name := "tuned-z" })] }
        let tuning : Mode := { name := "tuning" }
        let maps (_ : ViewId) : List (Keymap Vim.Bound) := tuning.keymaps scheme
        let (inserting, _) := vimFed "i"
        pure
          ((vimFed "z" maps).2 == [some (vimRun "tuned-z")] &&
            (vimFedFrom inserting "z" maps).2 == [some (Vim.selfInsert "z")]) },
    { name :=
        "Mode.check under the Vim scheme reports a hand-tuned key a state other than the initial one binds, and not one no state binds"
      run :=
        let scheme :=
          Vim.scheme vimStates
            { vimModeKeys with
              tuned :=
                [("tuning", keys "<Escape>", .command { name := "tuned-escape" }),
                  ("tuning", keys "z", .command { name := "tuned-z" })] }
        let tuning : Mode := { name := "tuning" }
        pure (tuning.check scheme == [.shadowsScheme (keys "<Escape>")]) },
    { name :=
        "told that a view is closed, the Vim scheme drops the Vim state it kept for it and keeps everything else: the other views' states, the edit begun and the last change; a view it kept nothing for changes nothing"
      run :=
        let scheme := Vim.scheme vimWithTest
        let (one, _) := vimFed "d w q" (states := vimWithTest)
        let (both, _) := vimFedFrom one "q 2" (view := ⟨1⟩) (states := vimWithTest)
        let closed : Vim.State := scheme.closeView ⟨0⟩ both
        let other : Vim.State := scheme.closeView ⟨7⟩ both
        pure
          (both.current == [(⟨0⟩, "test"), (⟨1⟩, "test")] && both.lastChange.isSome &&
            !both.typed.isEmpty &&
            closed == { both with current := [(⟨1⟩, "test")] } &&
            closed.stateOf vimWithTest ⟨0⟩ == "normal" &&
            closed.stateOf vimWithTest ⟨1⟩ == "test" &&
            other == both) },
    { name :=
        "told that a view is the minibuffer's, the Vim scheme puts it in the state its registry names and leaves the other views in theirs: a key that prints and a digit typed for it are text, and the same keys for another view are not; told that the view is closed, its state is the scheme's initial state again"
      run :=
        let states := vimStates
        let scheme := Vim.scheme states
        let told : Vim.State := scheme.openMinibuffer ⟨5⟩ vimInit
        let closed : Vim.State := scheme.closeView ⟨5⟩ told
        let typed (view : ViewId) (text : String) : List (Option Invocation) :=
          (vimFedFrom told text (view := view) (states := states)).2
        pure
          (told.current == [(⟨5⟩, "insert")] && told.stateOf states ⟨5⟩ == "insert" &&
            told.stateOf states ⟨0⟩ == "normal" &&
            typed ⟨5⟩ "w 2" == [some (Vim.selfInsert "w"), some (Vim.selfInsert "2")] &&
            (typed ⟨0⟩ "w").all
              (fun yielded => yielded.isSome && yielded != some (Vim.selfInsert "w")) &&
            typed ⟨0⟩ "2" == [none] &&
            closed == vimInit) },
    { name :=
        "with no state named for the minibuffer, and with a name the registry does not have, a view the Vim scheme is told is the minibuffer's is in the initial state, and the scheme's state is as it was"
      run :=
        let nowhere : Vim.States := { vimStates with minibuffer := some "nowhere" }
        let nameless : Vim.States := { vimStates with minibuffer := none }
        let unnamed : Vim.State := (Vim.scheme nameless).openMinibuffer ⟨5⟩ vimInit
        let unknown : Vim.State := (Vim.scheme nowhere).openMinibuffer ⟨5⟩ vimInit
        pure
          (vimStates.minibuffer == some "insert" && unnamed == vimInit && unknown == vimInit &&
            unknown.stateOf nowhere ⟨5⟩ == "normal") },
    { name :=
        "the notice of the minibuffer's view keeps the edit begun and the last change, and the other views' states"
      run :=
        let states := vimStates
        let (begun, _) := vimFedFrom (vimFed "x i" (states := states)).1 "d" (view := ⟨1⟩)
        let told : Vim.State := (Vim.scheme states).openMinibuffer ⟨5⟩ begun
        pure
          (begun.current == [(⟨0⟩, "insert")] && begun.lastChange.isSome && !begun.typed.isEmpty &&
            told == { begun with current := [(⟨0⟩, "insert"), (⟨5⟩, "insert")] }) }]

end ModelTest
