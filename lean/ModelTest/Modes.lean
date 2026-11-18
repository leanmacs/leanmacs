import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Evil.Compiled
import Editor.Ex.Line
import Editor.Face.Vocabulary
import Editor.Indent
import Editor.InputScheme.Contract
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Language
import Editor.Layout
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.SyntaxTree.Model
import Editor.TabBar
import Editor.TabCommands.Compiled
import Editor.Watch.Model
import Editor.WindowCommands.Compiled
import ModelTest.Dispatch

/-!
# Model tests: schemes and modes

The checks of the input scheme's contract, the Vim scheme, mode records,
language matching, the mode registry and dispatch, highlighting, indentation
and entering a mode.

Its lists of checks: `schemeContractChecks`, `vimEditChecks`,
`vimRegistryChecks`, `vimGrammarChecks`, `vimStateChecks`,
`vimDefaultChecks`, `vimContractChecks`, `modeRecordChecks`,
`languageMatchChecks`, `modeRegistryChecks`, `modeDispatchChecks`,
`highlightFaceChecks`, `highlightEnterChecks`, `indentRuleChecks`,
`indentOpeningChecks`, `indentEditChecks`, `indentLevelChecks`,
`modeEnterChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- A scheme written for the test that breaks the contract: it yields the
first binding that the keys so far begin, so it emits on a strict prefix. -/
def eager : InputScheme :=
  { State := List Key
    Binding := Invocation
    init := []
    step := fun maps view state key =>
      let typed := state ++ [key.chord]
      match
        (maps view).findSome? fun keymap =>
          keymap.bindings.find? fun binding => typed.isPrefixOf binding.1 with
      | some binding => ([], some binding.2)
      | none => ([], none)
    pending := id
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that an unbound key leaves the pending keys as they were. -/
def sticky : InputScheme :=
  { State := TestScheme.State
    Binding := Invocation
    init := {}
    step := fun maps view state key =>
      match TestScheme.step maps view state key with
      | (next, some invocation) => (next, some invocation)
      | (next, none) => (if next.pending.isEmpty then state else next, none)
    pending := (·.pending)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that it reports no pending keys. -/
def silent : InputScheme :=
  { State := TestScheme.State
    Binding := Invocation
    init := {}
    step := TestScheme.step
    pending := fun _ => []
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that an unbound key after a prefix hides the prefix and does not drop
it. It then reports no pending keys, and the key typed next is still walked
from the prefix, so the input typed next does not yield what it yields from
the initial state. Its state is the test scheme's, and whether its pending
keys are hidden. -/
def masking : InputScheme :=
  { State := TestScheme.State × Bool
    Binding := Invocation
    init := ({}, false)
    step := fun maps view state key =>
      match TestScheme.step maps view state.1 key with
      | (next, some invocation) => ((next, false), some invocation)
      | (next, none) =>
        if !state.1.pending.isEmpty && next.pending.isEmpty && !state.2 then ((state.1, true), none)
        else ((next, false), none)
    pending := fun state => if state.2 then [] else state.1.pending
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that an unbound key after a prefix yields an invocation. -/
def noisy : InputScheme :=
  { State := TestScheme.State
    Binding := Invocation
    init := {}
    step := fun maps view state key =>
      match TestScheme.step maps view state key with
      | (next, some invocation) => (next, some invocation)
      | (next, none) =>
        if !state.pending.isEmpty && next.pending.isEmpty then (next, some (invoke "noise"))
        else (next, none)
    pending := (·.pending)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that after a key that yields an invocation it reports the keys of the
input just completed as pending. Its state is the test scheme's, and the
keys it reports. -/
def lingering : InputScheme :=
  { State := TestScheme.State × List Key
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      match TestScheme.step maps view state.1 key with
      | (next, some invocation) => ((next, state.1.pending ++ [key.chord]), some invocation)
      | (next, none) => ((next, next.pending), none)
    pending := (·.2)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that what it says runs a named command runs a command of another
name. -/
def misnaming : InputScheme :=
  { TestScheme.scheme with command := fun name => { command := name ++ "-not" } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that what it says a mode's key is bound to runs a command of another
name. -/
def modeMisnaming : InputScheme :=
  { TestScheme.scheme with modeCommand := fun name => { command := name ++ "-not" } }

/-- A scheme written for the test that breaks the contract: the test scheme,
with a role table that lacks the role `mark`. -/
def roleless : InputScheme :=
  { TestScheme.scheme with roles := TestScheme.roles.filter (·.1 != Role.mark) }

/-- A scheme written for the test that breaks the contract: the test scheme,
with the role `previous-item` put on the keys of `next-item` as well. -/
def crowded : InputScheme :=
  { TestScheme.scheme with
    roles :=
      TestScheme.roles.map fun (role, keys) =>
        if role == Role.previousItem then (role, (TestScheme.scheme.roleKey Role.nextItem).getD [])
        else (role, keys) }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that a key that prints and that nothing binds yields nothing, so no
view of it takes typed text, the minibuffer's included. -/
def mute : InputScheme :=
  { State := TestScheme.State
    Binding := Invocation
    init := {}
    step := fun maps view state key =>
      let (pending, yielded) := Keymap.walk (maps view) state.pending key
      ({ pending }, yielded)
    pending := (·.pending)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that it reports a view as in an insert session while keys are
pending, so a key that yields nothing changes its report. -/
def fidgeting : InputScheme :=
  { TestScheme.scheme with
    report := fun (state : TestScheme.State) _ => { session := !state.pending.isEmpty } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that once an unbound key has dropped a prefix it reports every view
as in an insert session. Its state is the test scheme's, and whether a
prefix was dropped. -/
def startled : InputScheme :=
  { State := TestScheme.State × Bool
    Binding := Invocation
    init := ({}, false)
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, state.2 || !state.1.pending.isEmpty && next.pending.isEmpty && yielded.isNone),
        yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader
    report := fun state _ => { session := state.2 } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that a menu item's invocation of any name is made one of another
name. -/
def meddling : InputScheme :=
  { TestScheme.scheme with
    invoked := fun _ state invocation =>
      (state, { invocation with command := invocation.command ++ "-not" }) }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that a menu item's invocation of any name reports the view as in an
insert session from then on. Its state is the test scheme's, and whether a
menu item named one. -/
def menuStartled : InputScheme :=
  { State := TestScheme.State × Bool
    Binding := Invocation
    init := ({}, false)
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, state.2), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader
    report := fun state _ => { session := state.2 }
    invoked := fun _ state invocation => ((state.1, true), invocation) }

/-- The subject the scheme contract is run on: `scheme` over the scheme
checks' keymaps for view 0, the sequences those bind, a key none of them
goes on with, and that same key as the one that prints and that nothing
binds. -/
def subjectOf (scheme : InputScheme) (maps : ViewId → List (Keymap scheme.Binding)) :
    SchemeContract.Subject :=
  { scheme
    maps
    view := ⟨0⟩
    sequences := [keys "C-x C-s", keys "C-x C-f", keys "C-x r t", keys "C-q"]
    unbound := charKey "z"
    printable := charKey "z" }

/-- Whether exactly the properties `expected` of the scheme contract do not
hold of `subject`. -/
def failsOnly (subject : SchemeContract.Subject) (expected : List SchemeContract.Property) : Bool :=
  SchemeContract.failures subject == expected.map (·.name) &&
    SchemeContract.properties.all fun property =>
      property.holds subject != expected.any (·.name == property.name)

/-- The checks of the scheme contract (`Editor/InputScheme/Contract.lean`):
it holds of the test scheme, and it reports schemes written here that each
break it. -/
def schemeContractChecks : List Check :=
  [{  name := "the scheme contract has properties, each with a name of its own"
      run :=
        let names := SchemeContract.properties.map (·.name)
        pure (!names.isEmpty && names.eraseDups.length == names.length) },
    { name :=
        "the scheme contract reports a scheme that yields an invocation for an answer it did not ask for, for that property alone"
      run :=
        let answering : InputScheme :=
          { TestScheme.scheme with
            answered := fun _ answer state => (state, some { command := answer }) }
        pure
          (failsOnly (subjectOf answering schemeMaps)
            [SchemeContract.unaskedAnswerYieldsNothing]) },
    { name := "the scheme contract holds of the test scheme"
      run := pure (SchemeContract.failures (subjectOf TestScheme.scheme schemeMaps) == []) },
    { name :=
        "the scheme contract reports a scheme that emits on a strict prefix of a binding, by the name of the property it breaks"
      run :=
        let subject := subjectOf eager schemeMaps
        pure
          (!SchemeContract.strictPrefixEmitsNothing.holds subject &&
            (SchemeContract.failures subject).contains
              SchemeContract.strictPrefixEmitsNothing.name) },
    { name :=
        "the scheme contract reports a subject with no sequence of two keys, of which its other properties would hold with nothing to show"
      run :=
        let subject := { subjectOf TestScheme.scheme schemeMaps with sequences := [keys "C-q"] }
        pure (failsOnly subject [SchemeContract.hasPrefixes]) },
    { name :=
        "the scheme contract reports a scheme that keeps its pending keys after an unbound key"
      run := pure (failsOnly (subjectOf sticky schemeMaps) [SchemeContract.unboundResets]) },
    { name := "the scheme contract reports a scheme that does not report a pending prefix"
      run :=
        pure (failsOnly (subjectOf silent schemeMaps) [SchemeContract.strictPrefixIsPending]) },
    { name :=
        "the scheme contract reports a sequence said to be complete that yields nothing: one the keymaps do not bind"
      run :=
        let subject :=
          { subjectOf TestScheme.scheme schemeMaps with
            sequences := [keys "C-x C-s", keys "C-x <Escape>"] }
        pure (failsOnly subject [SchemeContract.completeEmits]) },
    { name :=
        "the scheme contract reports a scheme that reports no pending keys after an unbound key and keeps the prefix, so that the input typed next yields something else"
      run :=
        let subject := subjectOf masking schemeMaps
        let (state, yields) := subject.feed (keys "C-x z")
        pure
          (failsOnly subject [SchemeContract.unboundResets] && yields == [none, none] &&
            (subject.scheme.pending state).isEmpty) },
    { name :=
        "the scheme contract reports a scheme that yields an invocation on an unbound key after a prefix"
      run :=
        let subject := subjectOf noisy schemeMaps
        let (state, _) := subject.feed (keys "C-x z")
        pure
          (failsOnly subject [SchemeContract.unboundResets] &&
            (subject.scheme.pending state).isEmpty &&
            (subject.feedFrom state (keys "C-x C-s")).2 == (subject.feed (keys "C-x C-s")).2) },
    { name :=
        "the scheme contract reports a scheme that still reports pending keys after the key that completes an input, for a bound sequence, for a key bound to a named command, for a mode's key and for a key typed in the minibuffer's view"
      run :=
        let subject := subjectOf lingering schemeMaps
        pure
          (failsOnly subject
              [SchemeContract.completeEmits, SchemeContract.namedCommandRuns,
                SchemeContract.modeCommandRuns, SchemeContract.minibufferTakesText] &&
            (subject.feed (keys "C-x C-s")).2.getLast? == some (some (invoke "save"))) },
    { name :=
        "the scheme contract reports a scheme whose binding for a command name runs a command of another name, for that property alone"
      run := pure (failsOnly (subjectOf misnaming schemeMaps) [SchemeContract.namedCommandRuns]) },
    { name :=
        "the scheme contract reports a scheme whose binding for a mode's key runs a command of another name, for that property alone"
      run :=
        pure (failsOnly (subjectOf modeMisnaming schemeMaps) [SchemeContract.modeCommandRuns]) },
    { name :=
        "the scheme contract reports a scheme that yields nothing for a key that prints in the minibuffer's view, for that property alone"
      run :=
        let subject := subjectOf mute schemeMaps
        pure
          (failsOnly subject [SchemeContract.minibufferTakesText] &&
            (subject.feed [charKey "z"]).2 == [none] &&
            ((subjectOf TestScheme.scheme schemeMaps).feed [charKey "z"]).2.all (·.isSome)) },
    { name :=
        "the scheme contract reports a scheme whose role table lacks a registered role, for that property alone"
      run := pure (failsOnly (subjectOf roleless schemeMaps) [SchemeContract.everyRoleHasKey]) },
    { name :=
        "the scheme contract reports a scheme that puts two roles on one key, for that property alone"
      run := pure (failsOnly (subjectOf crowded schemeMaps) [SchemeContract.leaderAndRolesApart]) },
    { name :=
        "the scheme contract reports a scheme with no leader, and one with a role on keys that begin with the leader or begin it, for that property alone"
      run :=
        let leader := TestScheme.leader
        let quit := (TestScheme.scheme.roleKey Role.quit).getD []
        let underLeader :=
          TestScheme.roles.map fun (role, keys) =>
            if role == Role.quit then (role, leader ++ keys) else (role, keys)
        let tables : List (List (Role × List Key) × List Key) :=
          [(TestScheme.roles, []), (underLeader, leader), (TestScheme.roles, quit ++ leader)]
        pure
          (tables.all fun (roles, leader) =>
            failsOnly
              (subjectOf
                { TestScheme.scheme with
                  roles, leader }
                schemeMaps)
              [SchemeContract.leaderAndRolesApart]) },
    { name :=
        "the scheme contract reports a scheme whose report of a view changes while keys are pending, for that property alone"
      run :=
        let subject := subjectOf fidgeting schemeMaps
        pure
          (failsOnly subject [SchemeContract.quietKeyKeepsReport] &&
            (subject.scheme.report (subject.feed (keys "C-x")).1 ⟨0⟩).session &&
            !(subject.scheme.report (subject.feed (keys "C-x z")).1 ⟨0⟩).session) },
    { name :=
        "the scheme contract reports a scheme whose report of a view changes at the unbound key that resets a prefix, for that property alone"
      run :=
        let subject := subjectOf startled schemeMaps
        pure
          (failsOnly subject [SchemeContract.quietKeyKeepsReport] &&
            !(subject.scheme.report (subject.feed (keys "C-x")).1 ⟨0⟩).session &&
            (subject.scheme.report (subject.feed (keys "C-x z")).1 ⟨0⟩).session) },
    { name :=
        "the scheme contract reports a scheme that changes a menu item's invocation of a name it does not know, and one that changes its report of the view for one, for that property alone"
      run :=
        pure
          (failsOnly (subjectOf meddling schemeMaps) [SchemeContract.invokedKeepsUnknown] &&
            failsOnly (subjectOf menuStartled schemeMaps) [SchemeContract.invokedKeepsUnknown]) }]

/-- The delete operator of the Vim checks: it changes text and names no
state. -/
def vimDelete : Vim.Operator :=
  { name := "delete" }

/-- The change operator of the Vim checks: it changes text and enters the
state `insert`. -/
def vimChange : Vim.Operator :=
  { name := "change", enters := some "insert" }

/-- The yank operator of the Vim checks: it changes no text. -/
def vimYank : Vim.Operator :=
  { name := "yank", changes := false }

/-- A command of the Vim checks that changes text and enters the state
`insert`. -/
def vimInsert : Vim.Command :=
  { name := "insert", changes := true, enters := some "insert" }

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

/-- The keymap that binds each key string of `table` to what is beside it.
A string that names no keys binds nothing. -/
def vimKeymap (table : List (String × Vim.Bound)) : Keymap Vim.Bound :=
  Keymap.ofList (table.map fun (text, bound) => (keys text, bound))

/-- What the Vim checks' normal state binds: three operators, the motion
`word` on `w`, a motion on two keys and one on `0`, a text object, and
commands: one that enters `insert` and changes text, one that enters
`visual`, one that does neither, and one that changes text and enters no
state; and the register prefix on `"`. The names are the checks' own, and
are no default's. -/
def vimNormalTable : List (String × Vim.Bound) :=
  [("d", .operator vimDelete), ("c", .operator vimChange), ("y", .operator vimYank),
    ("w", .motion "word"), ("g g", .motion "first-line"), ("0", .motion "line-start"),
    ("t", .textObject "thing"), ("i", .command vimInsert),
    ("v", .command { name := "visual", enters := some "visual" }),
    ("u", .command { name := "undo" }), ("x", .command { name := "delete-char", changes := true }),
    ("\"", .register)]

/-- What the Vim checks' insert and visual states bind first: a command
that enters `normal`. -/
def vimEscapeTable : List (String × Vim.Bound) :=
  [("<Escape>", .command { name := "normal", enters := some "normal" })]

/-- The registry of Vim states the grammar's checks run on, written here so
that no check of the grammar names a default binding: `normal`, the initial
state; `insert`, where typing is text and the selection is exclusive, which
is also the state the registry names for the minibuffer's view; and
`visual`, where an operator acts on the selection and normal's keys are
bound too. -/
def vimStates : Vim.States :=
  { initial := { name := "normal", keymaps := [vimKeymap vimNormalTable] }
    others :=
      [{  name := "insert"
          keymaps := [vimKeymap vimEscapeTable]
          cursor := .bar
          insertsText := true
          shape := .exclusive },
        { name := "visual"
          keymaps := [vimKeymap vimEscapeTable, vimKeymap vimNormalTable]
          operatesOnSelection := true }]
    minibuffer := some "insert" }

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

/-- No active keymaps, for every view: a key is looked up in the keymaps of
the view's Vim state alone. -/
def vimNoMaps (_ : ViewId) : List (Keymap Vim.Bound) :=
  []

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

/-- `Vim.parse` over `states` folded from `state` through the keys the key
string `text` names: the state it is left in, and what each key parsed
to. -/
def vimParsedFrom (state : Vim.State) (text : String)
    (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps) (view : ViewId := ⟨0⟩)
    (states : Vim.States := vimStates) : Vim.State × List Vim.Parsed :=
  (keys text).foldl
    (fun (state, parsed) key =>
      let (next, result) := Vim.parse states maps view state key
      (next, parsed ++ [result]))
    (state, [])

/-- `vimParsedFrom` the scheme's initial state. -/
def vimParsed (text : String) (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps)
    (view : ViewId := ⟨0⟩) (states : Vim.States := vimStates) : Vim.State × List Vim.Parsed :=
  vimParsedFrom (Vim.scheme states).init text maps view states

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

/-- The inputs the Vim checks give the scheme contract as complete, as key
strings. -/
def vimSequences : List String :=
  ["g g", "w", "d w", "d d", "d 2 w", "2 d 3 w", "\" + y w"]

/-- The key the Vim checks give the scheme contract as unbound: a named
key. A key that prints goes on with one strict prefix whatever is bound,
the register prefix, by naming the register. -/
def vimUnbound : Key :=
  namedKey ⟨"F12"⟩

/-- The role table and leader the Vim checks give the scheme, written here
so that no check names a default: each registered role on a key of its own,
and the leader on `SPC`. -/
def vimModeKeys : Vim.ModeKeys :=
  { roles :=
      Role.registered.zip
        ([["n"], ["N"], ["RET"], ["Q"], ["z", "r"], ["TAB"], ["M"]].map fun strokes =>
          keys (" ".intercalate strokes))
    leader := keys "SPC" }

/-- The subject the scheme contract is run on for the Vim scheme over
`states`: the scheme with the checks' role table and leader and no active
keymaps, for view 0, and `z`, which no keymap of the checks' states binds,
as the key that prints. -/
def vimSubjectOver (states : Vim.States) : SchemeContract.Subject :=
  { scheme := Vim.scheme states vimModeKeys
    maps := vimNoMaps
    view := ⟨0⟩
    sequences := vimSequences.map keys
    unbound := vimUnbound
    printable := charKey "z" }

/-- The subject the scheme contract is run on for the Vim scheme: the
scheme over `vimStates`. -/
def vimSubject : SchemeContract.Subject :=
  vimSubjectOver vimStates

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

/-- The default Vim scheme's grammar folded from its initial state through
the keys the key string `text` names, keys for view 0 with no active
keymaps: the state it is left in, and what each key parsed to. -/
def vimDefault (text : String) : Vim.State × List Vim.Parsed :=
  vimParsed text (states := Vim.Default.states)

/-- The edit the last key of `text` completed under the default Vim
scheme, if it completed one. -/
def vimDefaultEdit (text : String) : Option Vim.Edit :=
  match (vimDefault text).2.getLast? with
  | some (.edit edit) => some edit
  | _ => none

/-- The command the last key of `text` runs under the default Vim scheme,
with no count and no register, if it runs one. -/
def vimDefaultCommand (text : String) : Option Vim.Command :=
  match vimDefaultEdit text with
  | some (.run command none none) => some command
  | _ => none

/-- The record of the default Vim state view 0 is in after the keys `text`
names. -/
def vimDefaultRecord (text : String) : Vim.StateRecord :=
  (vimDefault text).1.record Vim.Default.states ⟨0⟩

/-- What the default Vim scheme reports of view 0 after the keys `text`
names. -/
def vimDefaultReport (text : String) : InputScheme.Report :=
  Vim.Default.scheme.report (vimDefault text).1 ⟨0⟩

/-- Whether each of `texts` runs a command under the default Vim scheme,
each a command of another name. -/
def vimDefaultCommands (texts : List String) : Bool :=
  let names := (texts.filterMap vimDefaultCommand).map (·.name)
  names.length == texts.length && names.eraseDups.length == texts.length

/-- The subject the scheme contract is run on for the Vim scheme that
ships: the default scheme, with no active keymaps, for view 0. -/
def vimDefaultSubject : SchemeContract.Subject :=
  { scheme := Vim.Default.scheme
    maps := vimNoMaps
    view := ⟨0⟩
    sequences := ["d 2 w", "2 d 3 w", "d d", "g g", "\" + y w", "i"].map keys
    unbound := vimUnbound
    printable := charKey "z" }

/-- The checks of the Vim scheme's default states and bindings
(`Editor/InputScheme/Vim/Default.lean`). They observe the defaults through
the grammar, by what the default keys parse to, and restate no table: a
check names a key, and no vocabulary or command name. -/
def vimDefaultChecks : List Check :=
  [{  name :=
        "after an operator's key, i or a and the key after it are a text object, the operator's target: i alone still runs the command that enters insert, d i <Escape> and d i x reset and leave nothing pending, the counts of 2 d 3 i w multiply, a register named before the operator is kept, and d z t still yields nothing and leaves nothing pending"
      run :=
        let objectOver (text : String) : Option (String × Option Nat × Option String) :=
          match vimDefaultEdit text with
          | some (.operate _ (.textObject name) count register) => some (name, count, register)
          | _ => none
        let resets (text : String) : Bool :=
          (vimDefault text).2.getLast? == some .nothing && (vimDefault text).1.typed == []
        pure
          ((objectOver "d i w").isSome && (objectOver "c a (").isSome &&
            (objectOver "y i \"").isSome &&
            (vimDefaultCommand "i").bind (·.enters) == some (vimDefaultRecord "i").name &&
            (vimDefaultRecord "i").insertsText &&
            resets "d i <Escape>" &&
            resets "d i x" &&
            resets "d z t" &&
            (objectOver "2 d 3 i w").map (·.2.1) == some (some 6) &&
            (objectOver "\" a d a w").map (·.2.2) == some (some "a")) },
    { name :=
        "each alias of a block object after an operator yields what its primary key yields: i ) and i b as i (, a ) and a b as a (, i ] as i [, a ] as a [, i } and i B as i {, a } and a B as a {"
      run :=
        let aliases :=
          [("i )", "i ("), ("i b", "i ("), ("a )", "a ("), ("a b", "a ("), ("i ]", "i ["),
            ("a ]", "a ["), ("i }", "i {"), ("i B", "i {"), ("a }", "a {"), ("a B", "a {")]
        pure <|
          aliases.all fun (alias, primary) =>
            (vimDefaultEdit s!"d {alias}").isSome &&
              vimDefaultEdit s!"d {alias}" == vimDefaultEdit s!"d {primary}" &&
              vimDefaultEdit s!"d {alias}" != vimDefaultEdit "d i w" },
    { name :=
        "in a visual state a text object's keys select it: v i w yields an edit that is not the last change and leaves the view in v's state, v 2 i w carries the count, a register named before it is dropped, and V a ( leaves the view in v's state"
      run :=
        let selects (text : String) : Option (Option Nat) :=
          match vimDefaultEdit text with
          | some (.select _ count) => some count
          | _ => none
        pure
          (selects "v i w" == some none && (vimDefault "v i w").1.lastChange == none &&
            (vimDefaultRecord "v i w").name == (vimDefaultRecord "v").name &&
            selects "v 2 i w" == some (some 2) &&
            selects "v \" a i w" == some none &&
            (vimDefault "v \" a i w").1.register == none &&
            selects "V a (" == some none &&
            (vimDefaultRecord "V a (").name == (vimDefaultRecord "v").name &&
            (vimDefaultRecord "V").name != (vimDefaultRecord "v").name) },
    { name :=
        "C-g in the initial state runs the interrupt command, which changes no text and enters no state"
      run :=
        pure
          ((vimDefaultCommand "C-g").map
              (fun command => (command.name, command.changes, command.enters)) ==
            some (Shell.interruptName, false, none)) },
    { name := "every row of each default table binds its keys, and no table is empty"
      run :=
        pure <|
          [Vim.Default.motions, Vim.Default.operators, Vim.Default.objects,
                Vim.Default.normalCommands, Vim.Default.insertCommands, Vim.Default.visualCommands,
                Vim.Default.visualLineCommands, Vim.Default.minibufferCommands,
                Vim.Default.scrollCommands].all
            fun table =>
            !table.isEmpty && (Vim.Default.keymap table).bindings.length == table.length },
    { name :=
        "each of the default keys C-d C-u C-f C-b runs a command of its own that changes no text and enters no state, in the initial state and, the same command, in each visual state, which the view stays in; a count typed before one is that command's count; after an operator's key each yields nothing and drops the operator; in the state i enters none runs a command; and in the minibuffer's state C-d C-f C-b run none and C-u runs the minibuffer's command that deletes to the input's start"
      run :=
        let scrollKeys := ["C-d", "C-u", "C-f", "C-b"]
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ Vim.Default.scheme.init
        let runsNone (parsed : List Vim.Parsed) : Bool :=
          match parsed.getLast? with
          | some (.edit _) => false
          | _ => true
        pure
          (vimDefaultCommands scrollKeys &&
            scrollKeys.all fun text =>
              let command := vimDefaultCommand text
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange == none &&
                (["v", "V"].all fun state =>
                  vimDefaultCommand s!"{state} {text}" == command &&
                    (vimDefault s!"{state} {text}").1.current == (vimDefault state).1.current &&
                    (vimDefault s!"{state} {text}").1.lastChange == none) &&
                (match vimDefaultEdit s!"5 {text}" with
                | some (.run counted (some 5) none) => some counted == command
                | _ => false) &&
                (vimDefault s!"d {text}").2.getLast? == some .nothing &&
                vimDefaultEdit s!"d {text} w" == vimDefaultEdit "w" &&
                (vimDefaultEdit "w").isSome &&
                runsNone (vimDefault s!"i {text}").2 &&
                let inMinibuffer :=
                  (vimParsedFrom told text (view := ⟨5⟩) (states := Vim.Default.states)).2
                if text == "C-u" then
                  match inMinibuffer.getLast? with
                  | some (.edit (.run command none none)) =>
                    command.name == Minibuffer.deleteToStartName
                  | _ => false
                else runsNone inMinibuffer) },
    { name :=
        "in the minibuffer's state <ArrowLeft> and <ArrowRight> yield a move by the motions left and right, with no count"
      run :=
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ Vim.Default.scheme.init
        let moved (text : String) : Option Vim.Edit :=
          match
            (vimParsedFrom told text (view := ⟨5⟩) (states := Vim.Default.states)).2.getLast? with
          | some (.edit edit) => some edit
          | _ => none
        pure
          (moved "<ArrowLeft>" == some (.move "left" none) &&
            moved "<ArrowRight>" == some (.move "right" none)) },
    { name :=
        "each of the default keys <Backspace> RET TAB <ArrowLeft> <ArrowRight> <ArrowUp> <ArrowDown>, after i, runs a command of its own that leaves the view in the state i enters and does not replace the last change"
      run :=
        let editingKeys :=
          ["<Backspace>", "RET", "TAB", "<ArrowLeft>", "<ArrowRight>", "<ArrowUp>", "<ArrowDown>"]
        pure
          (vimDefaultCommands (editingKeys.map (s!"i {·}")) &&
            editingKeys.all fun text =>
              (vimDefault s!"i {text}").1.current == (vimDefault "i").1.current &&
                (vimDefault s!"i {text}").1.lastChange == (vimDefault "i").1.lastChange) },
    { name :=
        "<Backspace>, RET and TAB in a session are kept with its typed text, in the order typed, for a repeat: <Backspace> as the backspace character, RET as a line feed and TAB as a tab"
      run :=
        pure
          ((vimDefault "i x <Backspace> y").1.inserted == some "x\x08y" &&
            (vimDefault "i x RET y").1.inserted == some "x\ny" &&
            (vimDefault "i x TAB y").1.inserted == some "x\ty" &&
            (vimDefault "c w <Backspace> <Backspace> y").1.inserted == some "\x08\x08y" &&
            (vimDefault "c w <Backspace>").1.lastChange == (vimDefault "c w").1.lastChange) },
    { name :=
        "an arrow key in a session restarts the last change as i once something is typed after it, as Vim 9.1's ins-special-special says: the text kept is what was typed since; with nothing typed after it the last change and its text stay as they were"
      run :=
        let arrows := ["<ArrowLeft>", "<ArrowRight>", "<ArrowUp>", "<ArrowDown>"]
        pure
          (arrows.all fun arrow =>
            (vimDefault s!"i x {arrow} y").1.inserted == some "y" &&
              (vimDefault s!"A x {arrow} y").1.lastChange == (vimDefault "i").1.lastChange &&
              (vimDefault s!"c w x {arrow} y z").1.inserted == some "yz" &&
              (vimDefault s!"c w x {arrow} <Backspace>").1.inserted == some "\x08" &&
              (vimDefault s!"c w x {arrow} RET").1.lastChange == (vimDefault "i").1.lastChange &&
              (vimDefault s!"c w x {arrow}").1.inserted == some "x" &&
              (vimDefault s!"c w x {arrow} <Escape>").1.lastChange ==
                (vimDefault "c w").1.lastChange &&
              (vimDefault s!"c w x {arrow} <Escape> y").1.inserted == some "x") },
    { name :=
        "every command a key of insert state's table or of the minibuffer's state's table runs is registered under its name by evil's commands or the minibuffer's"
      run :=
        let registered := (Evil.commands ++ Minibuffer.commands).map (·.name)
        pure
          ((Vim.Default.insertCommands ++ Vim.Default.minibufferCommands).all fun
            | (_, .command command) => registered.contains command.name
            | _ => true) },
    { name :=
        "each of the default key sequences z t, z z and z b runs a command of its own that changes no text and enters no state, in the initial state and, the same command, in each visual state, which the view stays in; z alone yields nothing and is pending; and in the state i enters and in the minibuffer's state z is typed text"
      run :=
        let sequences := ["z t", "z z", "z b"]
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ Vim.Default.scheme.init
        pure
          (vimDefaultCommands sequences &&
            (sequences.all fun text =>
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange == none &&
                (Vim.Default.scheme.pending (vimDefault text).1).isEmpty &&
                ["v", "V"].all fun state =>
                  vimDefaultCommand s!"{state} {text}" == vimDefaultCommand text &&
                    (vimDefault s!"{state} {text}").1.current == (vimDefault state).1.current &&
                    (vimDefault s!"{state} {text}").1.lastChange == none) &&
            (vimDefault "z").2 == [.nothing] &&
            Vim.Default.scheme.pending (vimDefault "z").1 == keys "z" &&
            (vimDefault "i z").2.getLast? == some (.text "z") &&
            (vimParsedFrom told "z" (view := ⟨5⟩) (states := Vim.Default.states)).2 ==
              [.text "z"]) },
    { name :=
        "each default motion key yields a move with no count, each by a motion of another name: h j k l w b e W B E 0 ^ $ gg G"
      run :=
        let motionKeys :=
          ["h", "j", "k", "l", "w", "b", "e", "W", "B", "E", "0", "^", "$", "g g", "G"]
        let names :=
          motionKeys.filterMap fun text =>
            match vimDefaultEdit text with
            | some (.move name none) => some name
            | _ => none
        pure (names.length == motionKeys.length && names.eraseDups.length == motionKeys.length) },
    { name :=
        "each default operator key followed by a motion operates over that motion, and typed twice over one line, each an operator of another name: d c y"
      run :=
        let operatorKeys := ["d", "c", "y"]
        let operators :=
          operatorKeys.filterMap fun text =>
            match vimDefaultEdit s!"{text} w", vimDefaultEdit s!"{text} {text}",
              vimDefaultEdit "w" with
            | some (.operate operator (.motion target) none none),
              some (.operate doubled .lines (some 1) none), some (.move motion none) =>
              if operator == doubled && target == motion then some operator.name else none
            | _, _, _ => none
        pure
          (operators.length == operatorKeys.length &&
            operators.eraseDups.length == operatorKeys.length) },
    { name :=
        "of the default operators c leaves the view in a state where typing is text and d and y leave it where it was, and d and c change text and y does not"
      run :=
        pure
          ((vimDefaultRecord "c w").insertsText && (vimDefault "d w").1.current == [] &&
            (vimDefault "y w").1.current == [] &&
            (vimDefault "d w").1.lastChange == vimDefaultEdit "d w" &&
            (vimDefault "c w").1.lastChange == vimDefaultEdit "c w" &&
            (vimDefault "d w").1.lastChange.isSome &&
            (vimDefault "y w").1.lastChange == none) },
    { name :=
        "each of the default keys i a I A o O runs a command of its own that changes text and leaves the view in a state where typing is text"
      run :=
        let insertKeys := ["i", "a", "I", "A", "o", "O"]
        pure
          (vimDefaultCommands insertKeys &&
            insertKeys.all fun text =>
              (vimDefaultRecord text).insertsText && (vimDefault text).1.lastChange.isSome &&
                (vimDefault text).1.lastChange == vimDefaultEdit text) },
    { name :=
        "each of the default keys x p P runs a command of its own that changes text and enters no state"
      run :=
        let changeKeys := ["x", "p", "P"]
        pure
          (vimDefaultCommands changeKeys &&
            changeKeys.all fun text =>
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange.isSome) },
    { name :=
        "each of the default keys u C-r : runs a command of its own that changes no text and enters no state"
      run :=
        let plainKeys := ["u", "C-r", ":"]
        pure
          (vimDefaultCommands plainKeys &&
            plainKeys.all fun text =>
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange == none) },
    { name :=
        "the default key . is the repeat key, and no command's: with no last change it yields nothing, and after x it yields the replay of that change and leaves it the last change"
      run :=
        let deleteChar : Vim.Edit := .run { name := "delete-char", changes := true } none none
        pure
          ((vimDefault ".").2 == [.nothing] && (vimDefault ".").1.lastChange == none &&
            (vimDefault "x .").2.getLast? == some (.edit (.replay deleteChar none)) &&
            (vimDefault "x .").1.lastChange == some deleteChar &&
            (vimDefault "x .").1.current == []) },
    { name :=
        "the default keys v and V enter two different states where operators act on the selection, change no text, and each key typed again, and the other, goes where it should: back to the initial state, or to the other visual state"
      run :=
        pure
          ((vimDefaultRecord "v").operatesOnSelection &&
            (vimDefaultRecord "V").operatesOnSelection &&
            (vimDefaultRecord "v").name != (vimDefaultRecord "V").name &&
            (vimDefault "v").1.lastChange == none &&
            (vimDefault "V").1.lastChange == none &&
            (vimDefault "v v").1.current == [] &&
            (vimDefault "V V").1.current == [] &&
            (vimDefault "v V").1.current == (vimDefault "V").1.current &&
            (vimDefault "V v").1.current == (vimDefault "v").1.current) },
    { name :=
        "the default <Escape> returns to the initial state from each state another default key enters: from the state i enters, and from the two v and V enter"
      run :=
        pure
          (["i", "v", "V"].all fun text =>
            !(vimDefault text).1.current.isEmpty &&
              (vimDefault s!"{text} <Escape>").1.current == []) },
    { name :=
        "in the default visual states an operator key operates over the selection at once and a motion key is a move"
      run :=
        pure
          (["v", "V"].all fun text =>
            (match vimDefaultEdit s!"{text} d" with
              | some (.operate _ .selection none none) => true
              | _ => false) &&
              (vimDefault s!"{text} d").1.current == [] &&
              vimDefaultEdit s!"{text} w" == vimDefaultEdit "w" &&
              (vimDefaultEdit "w").isSome) },
    { name :=
        "the default register prefix names a register for an operator in normal state and in each visual state"
      run :=
        let register (text : String) : Option String :=
          match vimDefaultEdit text with
          | some (.operate _ _ _ register) => register
          | _ => none
        pure
          (register "\" + y w" == some "+" && register "v \" a d" == some "a" &&
            register "V \" a d" == some "a" &&
            register "y w" == none) },
    { name :=
        "in the default state that i enters a key bound to a motion in the initial state is typed text, and after <Escape> it is that motion again"
      run :=
        pure
          ((vimDefault "i h").2.getLast? == some (.text "h") &&
            (vimDefault "i 0").2.getLast? == some (.text "0") &&
            vimDefaultEdit "i <Escape> h" == vimDefaultEdit "h" &&
            (vimDefaultEdit "h").isSome) },
    { name :=
        "the cursor of the default initial state is a block, and that of the state i enters a bar"
      run :=
        pure
          ((vimDefaultRecord "").cursor == .block && Vim.Default.states.initial.cursor == .block &&
            (vimDefaultRecord "i").cursor == .bar &&
            (vimDefaultRecord "i").name != (vimDefaultRecord "").name) },
    { name :=
        "under the default Vim scheme a view opened as the minibuffer's is in a state of its own, where typing is text and the cursor is a bar: a letter, a digit and a key the initial state binds to a motion are text there; RET and <Escape> each run a command, of two different names, that enters no state and leaves nothing pending; a view that was not opened as the minibuffer's is in the initial state"
      run :=
        let states := Vim.Default.states
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ (Vim.scheme states).init
        let record := told.record states ⟨5⟩
        let parsed (text : String) : Vim.State × List Vim.Parsed :=
          vimParsedFrom told text (view := ⟨5⟩) (states := states)
        let command (text : String) : Option String :=
          match (parsed text).2 with
          | [.edit (.run command none none)] => some command.name
          | _ => none
        pure
          (record.insertsText && record.cursor == .bar && record.name != states.initial.name &&
            record.name != (vimDefaultRecord "i").name &&
            (parsed "a 7 w").2 == [.text "a", .text "7", .text "w"] &&
            (vimDefaultEdit "w").isSome &&
            (command "RET").isSome &&
            (command "<Escape>").isSome &&
            command "RET" != command "<Escape>" &&
            (["RET", "<Escape>"].all fun text => (parsed text).1 == told) &&
            told.stateOf states ⟨0⟩ == states.initial.name) },
    { name :=
        "under the default Vim scheme the minibuffer's state binds the keys that move through a prompt's candidates: TAB and C-n each run the minibuffer's command that moves to the next, S-TAB and C-p the one that moves to the previous; each enters no state and leaves nothing pending, and none of the four is text"
      run :=
        let states := Vim.Default.states
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ (Vim.scheme states).init
        let parsed (text : String) : Vim.State × List Vim.Parsed :=
          vimParsedFrom told text (view := ⟨5⟩) (states := states)
        let command (text : String) : Option String :=
          match (parsed text).2 with
          | [.edit (.run command none none)] => some command.name
          | _ => none
        pure
          (command "TAB" == some Minibuffer.nextName && command "C-n" == some Minibuffer.nextName &&
            command "S-TAB" == some Minibuffer.previousName &&
            command "C-p" == some Minibuffer.previousName &&
            Minibuffer.nextName != Minibuffer.previousName &&
            ["TAB", "C-n", "S-TAB", "C-p"].all fun text => (parsed text).1 == told) },
    { name :=
        "the default Vim scheme reports a fresh view as a block with an inclusive selection, no selecting and no insert session; after i a bar, an exclusive selection, an insert session and a view that takes text; and after i and <Escape> what it reported first"
      run :=
        let fresh := vimDefaultReport ""
        let inserting := vimDefaultReport "i"
        pure
          (fresh.cursor.shape == .block && fresh.shape == .inclusive && !fresh.selecting &&
            !fresh.session &&
            !fresh.takesText &&
            inserting.cursor.shape == .bar &&
            inserting.shape == .exclusive &&
            !inserting.selecting &&
            inserting.session &&
            inserting.takesText &&
            inserting.cursor.face != fresh.cursor.face &&
            vimDefaultReport "i <Escape>" == fresh) },
    { name :=
        "the default Vim scheme reports selecting in the states v and V enter, with an inclusive selection after v and a line-shaped one after V, neither an insert session; v then V is reported as V is, and V then v as v is"
      run :=
        let visual := vimDefaultReport "v"
        let line := vimDefaultReport "V"
        pure
          (visual.selecting && visual.shape == .inclusive && !visual.session && !visual.takesText &&
            line.selecting &&
            line.shape == .line &&
            !line.session &&
            !line.takesText &&
            vimDefaultReport "v V" == line &&
            vimDefaultReport "V v" == visual &&
            vimDefaultReport "v v" == vimDefaultReport "" &&
            vimDefaultReport "V V" == vimDefaultReport "") },
    { name :=
        "the default Vim scheme reports the minibuffer's view as a bar with an exclusive selection, in an insert session, taking text; and the status fields and the cursor faces of its five states all differ"
      run :=
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ Vim.Default.scheme.init
        let minibuffer := Vim.Default.scheme.report told ⟨5⟩
        let reports := minibuffer :: ["", "i", "v", "V"].map vimDefaultReport
        pure
          (minibuffer.cursor.shape == .bar && minibuffer.shape == .exclusive &&
            !minibuffer.selecting &&
            minibuffer.session &&
            minibuffer.takesText &&
            Vim.Default.scheme.report told ⟨0⟩ == vimDefaultReport "" &&
            reports.all (·.status.size == 1) &&
            (reports.map (·.status)).eraseDups.length == 5 &&
            (reports.map (·.cursor.face)).eraseDups.length == 5) },
    { name :=
        "criterion 2: in normal state C-w C-n, C-w C-p, C-w C-c and C-w C-w run the window commands Vim binds to C-w n, C-w p, C-w c and C-w w, each changing no text and entering no state"
      run :=
        pure <|
          [("C-w C-n", WindowCommands.newName), ("C-w C-p", WindowCommands.lastName),
                ("C-w C-c", WindowCommands.closeName), ("C-w C-w", WindowCommands.nextName)].all
            fun (text, name) =>
            vimDefaultCommand text == some { name } && (vimDefault text).2.head? == some .nothing },
    { name :=
        "criterion 4: in normal state each key of the tab table runs its tab command, changing no text and entering no state: C-w n the next tab, C-w p the previous, C-w c a new one, C-w & close, C-w w switch, and C-w 1 to C-w 9 the tab of that number"
      run :=
        pure <|
          let rows : List (String × String) :=
            [("C-w n", TabCommands.nextName), ("C-w p", TabCommands.previousName),
                ("C-w c", TabCommands.newName), ("C-w &", TabCommands.closeName),
                ("C-w w", TabCommands.switchName)] ++
              (List.range 9).map fun index =>
                (s!"C-w {index + 1}", TabCommands.selectName (index + 1))
          rows.all fun (text, name) =>
            vimDefaultCommand text == some { name } && (vimDefault text).2.head? == some .nothing },
    { name :=
        "every row of the tab commands' table binds its keys in normal state to the command it names, and every command it names is a tab command that is registered"
      run :=
        pure <|
          let registered := TabCommands.commands.map (·.name)
          Vim.Default.tabKeys.length == 14 &&
            (Vim.Default.keymap Vim.Default.tabCommands).bindings.length ==
              Vim.Default.tabKeys.length &&
            Vim.Default.tabKeys.all fun (text, name) =>
              vimDefaultCommand text == some { name } && registered.contains name },
    { name :=
        "C-w alone is pending in normal state; after an operator's key C-w s resets and leaves nothing pending; in the state i enters C-w runs a command that changes no text and enters no state, so the view stays there"
      run :=
        pure <|
          (vimDefault "C-w").2 == [.nothing] && (vimDefault "C-w").1.typed == keys "C-w" &&
            (vimDefault "d C-w s").2.getLast? == some .nothing &&
            (vimDefault "d C-w s").1.typed == [] &&
            (vimDefaultCommand "i C-w").any
              (fun command => !command.changes && command.enters.isNone) &&
            (vimDefaultRecord "i C-w").name == (vimDefaultRecord "i").name },
    { name :=
        "every row of the window commands' table binds its keys in normal state to the command it names, and every command it names is a window command that is registered"
      run :=
        pure <|
          let registered := WindowCommands.commands.map (·.name)
          !Vim.Default.windowKeys.isEmpty &&
            (Vim.Default.keymap Vim.Default.windowCommands).bindings.length ==
              Vim.Default.windowKeys.length &&
            Vim.Default.windowKeys.all fun (text, name) =>
              vimDefaultCommand text == some { name } && registered.contains name },
    { name :=
        "C-w H, C-w J, C-w K and C-w L run the commands that move a window to the left, bottom, top and right edge and back, each changing no text and entering no state"
      run :=
        pure <|
          [("C-w H", WindowCommands.edgeLeftName), ("C-w J", WindowCommands.edgeBottomName),
                ("C-w K", WindowCommands.edgeTopName), ("C-w L", WindowCommands.edgeRightName)].all
            fun (text, name) =>
            vimDefaultCommand text == some { name } && (vimDefault text).2.head? == some .nothing },
    { name :=
        "C-w F runs the command that moves a window between the tiles and the floating layer, changing no text and entering no state"
      run :=
        pure <|
          vimDefaultCommand "C-w F" == some { name := WindowCommands.floatName } &&
            (vimDefault "C-w F").2.head? == some .nothing }]

/-- The checks that the Vim scheme keeps the scheme contract
(`Editor/InputScheme/Contract.lean`). -/
def vimContractChecks : List Check :=
  [{  name := "the scheme contract holds of the Vim scheme over the registry written for the checks"
      run := pure (SchemeContract.failures vimSubject == []) },
    { name := "the scheme contract holds of the Vim scheme that ships, over its default states"
      run := pure (SchemeContract.failures vimDefaultSubject == []) },
    { name :=
        "a key that prints is not unbound after the register prefix, where it names the register: given one as its unbound key, the scheme contract reports that it does not reset"
      run :=
        pure
          (failsOnly { vimSubject with unbound := charKey "z" } [SchemeContract.unboundResets]) },
    { name :=
        "the Vim scheme over a registry that names no state for the minibuffer leaves the minibuffer's view where a key that prints is no text: the scheme contract reports it, for that property alone"
      run :=
        pure
          (failsOnly (vimSubjectOver { vimStates with minibuffer := none })
            [SchemeContract.minibufferTakesText]) }]

/-- A mode the mode checks run on: `listing`, which fills two roles and has
one suffix, each with a command of its own. -/
def listing : Mode :=
  { name := "listing"
    roles := [(Role.nextItem, "listing-next"), (Role.previousItem, "listing-previous")]
    locals := [("x", "listing-execute")] }

/-- The test scheme with keymaps of its own, which bind `C-x C-s` and
`C-x C-f`, and a hand-tuned key for `listing` that they do not bind: what
`Mode.check` is run against. -/
def checkedScheme : InputScheme :=
  { TestScheme.scheme with
    defaults :=
      [Keymap.ofList [(keys "C-x C-s", invoke "save")],
        Keymap.ofList [(keys "C-x C-f", invoke "find")]]
    tuned := [("listing", keys "C-t", invoke "tuned-t")] }

/-- The keys `role` is on under the test scheme; none when it has no row. -/
def roleKeys (role : Role) : List Key :=
  (TestScheme.scheme.roleKey role).getD []

/-- What the keymaps `mode` makes for the test scheme `scheme` make of
`keys`. -/
def modeLookup (mode : Mode) (keys : List Key) (scheme : InputScheme := TestScheme.scheme)
    (same : scheme.Binding = Invocation := by rfl) : Lookup Invocation :=
  Keymap.resolve (same ▸ mode.keymaps scheme) keys

/-- The checks of roles and of the mode record (`Editor/Role.lean`,
`Editor/Mode.lean`): the roles the core registers, and the keymaps a mode
makes for a scheme, read through the test scheme's role table and leader. -/
def modeRecordChecks : List Check :=
  [{  name := "a mode's role is bound at the scheme's key for the role to the mode's command"
      run :=
        pure
          (modeLookup listing (roleKeys Role.nextItem) == .bound (invoke "listing-next") &&
            modeLookup listing (roleKeys Role.previousItem) == .bound (invoke "listing-previous") &&
            modeLookup listing (roleKeys Role.quit) == .unbound) },
    { name := "a mode's suffix is bound under the scheme's leader to the mode's command"
      run :=
        pure
          (modeLookup listing (TestScheme.scheme.leader ++ keys "x") ==
              .bound (invoke "listing-execute") &&
            modeLookup listing TestScheme.scheme.leader == .pending &&
            modeLookup listing (keys "x") == .unbound) },
    { name := "a role the scheme has no key for binds nothing"
      run :=
        let marking : Mode := { name := "marking", roles := [(Role.mark, "marking-mark")] }
        pure
          ((marking.keymaps roleless).all (·.bindings.isEmpty) &&
            modeLookup marking (roleKeys Role.mark) == .bound (invoke "marking-mark")) },
    { name :=
        "a scheme's hand-tuned key for the mode is in the keymap ahead of the roles and suffixes, and wins over a role on the same key; another mode's is not"
      run :=
        let tuned : InputScheme :=
          { TestScheme.scheme with
            tuned :=
              [("listing", roleKeys Role.nextItem, invoke "tuned-next"),
                ("listing", keys "C-t", invoke "tuned-t"),
                ("other", keys "C-o", invoke "other-o")] }
        pure
          (modeLookup listing (roleKeys Role.nextItem) tuned == .bound (invoke "tuned-next") &&
            modeLookup listing (keys "C-t") tuned == .bound (invoke "tuned-t") &&
            modeLookup listing (roleKeys Role.previousItem) tuned ==
              .bound (invoke "listing-previous") &&
            modeLookup listing (keys "C-o") tuned == .unbound &&
            ((listing.keymaps tuned).head?.map (·.bindings.length)) == some 2) },
    { name :=
        "a mode says nothing of a syntax tree by default, and a lineage's is its nearest mode's that says"
      run :=
        let json : Mode := { name := "json", syntaxTree := some { grammar := "json" } }
        let five : Mode :=
          { name := "five", syntaxTree := some { grammar := "json", highlights := some "x" } }
        pure
          (listing.syntaxTree == none && Mode.syntaxTreeOf [listing] == none &&
            Mode.syntaxTreeOf [json, listing] == some { grammar := "json" } &&
            Mode.syntaxTreeOf [json, five, listing] == five.syntaxTree) },
    { name :=
        "the code mode's syntax tree is its buffer's language's: the nearest mode of a lineage that has its own tree or takes the language's, and has one to give, says; with no language the code mode says nothing, and a mode that does not take the language's never gives it"
      run :=
        let rustTree : Mode.SyntaxTree := { grammar := "rust" }
        let code := Language.codeMode
        let own : Mode :=
          { name := "own-json", parent := some "code", syntaxTree := some { grammar := "json" } }
        let derived : Mode := { name := "derived", parent := some "code" }
        let json : Mode := { name := "json", syntaxTree := some { grammar := "json" } }
        pure
          (code.name == Language.codeName && Language.codeName == "code" &&
            code.syntaxTree == none &&
            code.syntaxTreeOfLanguage &&
            !listing.syntaxTreeOfLanguage &&
            Language.modes.map (·.name) == #["code"] &&
            Mode.syntaxTreeOf [code] (some rustTree) == some rustTree &&
            Mode.syntaxTreeOf [code] none == none &&
            Mode.syntaxTreeOf [code] == none &&
            Mode.syntaxTreeOf [code, own] (some rustTree) == own.syntaxTree &&
            Mode.syntaxTreeOf [code, derived] (some rustTree) == some rustTree &&
            Mode.syntaxTreeOf [json, code] none == json.syntaxTree &&
            Mode.syntaxTreeOf [json, listing] (some rustTree) == json.syntaxTree &&
            Mode.syntaxTreeOf [listing] (some rustTree) == none) },
    { name := "Mode.check reports nothing for a mode with no problem, under a scheme that tunes it"
      run := pure (listing.check TestScheme.scheme == [] && listing.check checkedScheme == []) },
    { name := "Mode.check reports a role that is not registered, by its name"
      run :=
        let mode := { listing with roles := listing.roles ++ [(Role.mk "frobnicate", "f")] }
        pure
          (mode.check checkedScheme == [.unregisteredRole { name := "frobnicate" }] &&
            mode.problems == [.unregisteredRole { name := "frobnicate" }]) },
    { name :=
        "Mode.check reports a suffix used twice once, comparing suffixes as keys, so that two spellings of one key are one suffix"
      run :=
        let twice := { listing with locals := [("x", "a"), ("x", "b"), ("x", "c"), ("y", "d")] }
        let spelled := { listing with locals := [("TAB", "a"), ("<Tab>", "b")] }
        pure
          (twice.check checkedScheme == [.duplicateSuffix (keys "x")] &&
            spelled.check checkedScheme == [.duplicateSuffix (keys "TAB")]) },
    { name := "Mode.check reports a suffix that is not keys, and one that names no keys"
      run :=
        let mode := { listing with locals := listing.locals ++ [("S-a", "a"), ("", "b")] }
        pure (mode.check checkedScheme == [.unreadableSuffix "S-a", .unreadableSuffix ""]) },
    { name :=
        "Mode.check reports a hand-tuned key of the mode that the scheme's own keymaps bind exactly, and not one they bind longer, nor another mode's"
      run :=
        let shadowing : InputScheme :=
          { checkedScheme with
            tuned :=
              [("listing", keys "C-t", invoke "tuned-t"),
                ("listing", keys "C-x C-s", invoke "tuned-save"),
                ("listing", keys "C-x", invoke "tuned-prefix"),
                ("other", keys "C-x C-f", invoke "other-find")] }
        pure
          (listing.check shadowing == [.shadowsScheme (keys "C-x C-s")] &&
            listing.problems == []) },
    { name := "each problem Mode.check reports is described by a sentence naming it"
      run :=
        let described :=
          [Mode.Problem.unregisteredRole { name := "frobnicate" }, .duplicateSuffix (keys "C-x"),
                .unreadableSuffix "S-a", .shadowsScheme (keys "C-x C-s")].map
            Mode.Problem.describe
        pure
          ([("frobnicate", 0), ("C-x", 1), ("S-a", 2), ("C-x C-s", 3)].all fun (name, index) =>
            ((described[index]?).getD "").contains name) },
    { name :=
        "the registered roles are next-item, previous-item, activate, quit, refresh, toggle and mark, each a name of its own"
      run :=
        pure
          (Role.registered.map (·.name) ==
              ["next-item", "previous-item", "activate", "quit", "refresh", "toggle", "mark"] &&
            [Role.nextItem, Role.previousItem, Role.activate, Role.quit, Role.refresh, Role.toggle,
                Role.mark] ==
              Role.registered) }]

/-- A language called `name`, chosen for `patterns`, whose text is parsed
with `grammar`. -/
def testLanguage (name : String) (patterns : List Language.Pattern) (grammar : String := "json") :
    Language :=
  { name, patterns, syntaxTree := { grammar } }

/-- The name of the language `table` chooses for `path` (`Language.forPath`),
if it chooses one. -/
def chosenIn (table : List Language) (path : System.FilePath) : Option String :=
  (Language.forPath table path).map (·.name)

/-- The checks of the matching rule (`Editor/Language.lean`), pure: which
language a table chooses for a path, how a later owner's entries are put
over an earlier owner's, and the shipped table. -/
def languageMatchChecks : List Check :=
  let shipped := Language.shipped.toList
  [{  name :=
        "the shipped table chooses rust for a .rs path, json for a .json path, markdown for a .md path, toml for a .toml path and lean for a .lean path, lakefile.lean included, by extension, and toml for a file named Cargo.lock, by name"
      run :=
        pure
          (chosenIn shipped "/p/src/main.rs" == some "rust" &&
            chosenIn shipped "/p/data.json" == some "json" &&
            chosenIn shipped "/p/notes.md" == some "markdown" &&
            chosenIn shipped "/p/Cargo.toml" == some "toml" &&
            chosenIn shipped "/p/mise.toml" == some "toml" &&
            chosenIn shipped "/p/Cargo.lock" == some "toml" &&
            chosenIn shipped "/p/Editor/Main.lean" == some "lean" &&
            chosenIn shipped "/p/lakefile.lean" == some "lean") },
    { name :=
        "an exact base-name pattern beats an extension pattern, even an earlier entry's, and the extension entry still has the paths the name does not"
      run :=
        let table :=
          [testLanguage "lock" [.extension "lock"], testLanguage "cargo-lock" [.name "Cargo.lock"]]
        pure
          (chosenIn table "/p/Cargo.lock" == some "cargo-lock" &&
            chosenIn table "/p/yarn.lock" == some "lock" &&
            chosenIn table "/p/sub/Cargo.lock.bak" == none) },
    { name :=
        "between entries of equal pattern the earlier one in the table wins, so an entry of a later owner, which Language.over puts first, beats the shipped one"
      run :=
        let rusty := testLanguage "rusty" [.extension "rs"] "rust"
        let twice := [rusty, testLanguage "rustier" [.extension "rs"] "rust"]
        pure
          (chosenIn (Language.over [rusty] shipped) "/p/main.rs" == some "rusty" &&
            chosenIn (Language.over twice shipped) "/p/main.rs" == some "rusty" &&
            chosenIn (Language.over [rusty] shipped) "/p/data.json" == some "json") },
    { name :=
        "Language.over replaces an earlier owner's entry of a name with the later owner's whole entry, the later owner's entries first and in their order"
      run :=
        let mine :=
          [{ Language.rust with patterns := [.extension "rlib"] },
            testLanguage "toml" [.extension "toml"]]
        let table := Language.over mine shipped
        pure
          (table.map (·.name) == ["rust", "toml", "json", "markdown", "lean"] &&
            chosenIn table "/p/main.rs" == none &&
            chosenIn table "/p/x.rlib" == some "rust" &&
            Language.over [] shipped == shipped) },
    { name :=
        "a path that matches no entry has no language: another extension, no extension, a base name that is only the extension with or without its dot, an extension in another case, a lock file not named Cargo.lock, Cargo.lock in another case or with more after it, Lean's toolchain file and build products, and a path with no base name"
      run :=
        pure
          (["/p/notes.txt", "/p/Makefile", "/p/rs", "/p/.rs", "/p/main.RS", "/p/yarn.lock",
                "/p/cargo.lock", "/p/Cargo.lock.bak", "/p/lean-toolchain", "/p/x.olean",
                "/p/x.ilean", "/p/Main.LEAN", "/"].all
            fun path => chosenIn shipped path == none) },
    { name :=
        "the registry's language table is each owner's entries over the earlier owners', the latest owner's first and in its order: config's entry of a shipped language's name replaces it whole, config's entry beats a shipped one of equal pattern, and the loop is told the table"
      run :=
        let compiled := ({} : Config.Registry).replaceLanguages .compiled Language.shipped
        let rusty := testLanguage "rusty" [.extension "rs"] "rust"
        let mine :=
          { Language.rust with syntaxTree := { grammar := "rust", highlights := some "q" } }
        let registry := compiled.replaceLanguages .config #[rusty, mine]
        let names (table : List Language) : List String := table.map (·.name)
        pure
          (names compiled.languageTable == ["rust", "json", "markdown", "toml", "lean"] &&
            names registry.languageTable == ["rusty", "rust", "json", "markdown", "toml", "lean"] &&
            registry.languageTable[1]? == some mine &&
            chosenIn registry.languageTable "/p/main.rs" == some "rusty" &&
            chosenIn (compiled.replaceLanguages .config #[mine]).languageTable "/p/main.rs" ==
              some "rust" &&
            registry.registered.languages == registry.languageTable &&
            (registry.replaceLanguages .config #[]).languageTable == compiled.languageTable) },
    { name :=
        "the shipped table is rust, json, markdown, toml and lean, each parsed with the grammar of its name and the grammar's own queries, toml's booleans drawn in the constant face, lean's booleans in the constant face, its characters in the string face, its namespaces in the module face and its plain identifiers (`variable`) in no face, and no other capture of any mapped; rust indented by four spaces and json, markdown, toml and lean by two; toml for *.toml and Cargo.lock, lean for *.lean"
      run :=
        pure
          (Language.shipped.map (·.name) == #["rust", "json", "markdown", "toml", "lean"] &&
            Language.shipped.all
              (fun language =>
                language.syntaxTree ==
                  { grammar := language.name, captures := language.syntaxTree.captures }) &&
            [Language.rust, Language.json, Language.markdown].all (·.syntaxTree.captures.isEmpty) &&
            Language.toml.syntaxTree.captures == [("boolean", some ⟨"syntax.constant"⟩)] &&
            Language.toml.patterns == [.extension "toml", .name "Cargo.lock"] &&
            Language.lean.syntaxTree.captures ==
              [("boolean", some ⟨"syntax.constant"⟩), ("character", some ⟨"syntax.string"⟩),
                ("namespace", some ⟨"syntax.module"⟩), ("variable", none)] &&
            Language.lean.patterns == [.extension "lean"] &&
            Language.rust.indentUnit == .spaces 4 &&
            Language.json.indentUnit == .spaces 2 &&
            Language.markdown.indentUnit == .spaces 2 &&
            Language.toml.indentUnit == .spaces 2 &&
            Language.lean.indentUnit == .spaces 2) },
    { name := "an entry that says no indent unit is indented by the default unit, four spaces"
      run :=
        pure
          (Language.IndentUnit.default == .spaces 4 &&
            (testLanguage "plain" [.extension "txt"]).indentUnit == Language.IndentUnit.default) }]

/-- A mode called `name` that fills each of `roles` with a command named
after the mode and the role, and derives from `parent`, if given. -/
def filling (name : String) (roles : List Role) (parent : Option String := none) : Mode :=
  { name, parent, roles := roles.map fun role => (role, s!"{name}-{role.name}") }

/-- The invocation of the command `filling name` fills `role` with. -/
def filled (name : String) (role : Role) : Invocation :=
  invoke s!"{name}-{role.name}"

/-- What the active keymaps `registry` makes for the test scheme, in
`state`, for `view`, make of the keys `role` is on. -/
def activeLookup (registry : Config.Registry) (state : EditorState) (view : ViewId) (role : Role) :
    Lookup Invocation :=
  Keymap.resolve (registry.activeMaps TestScheme.scheme state view) (roleKeys role)

/-- `twoBuffers` with the major mode `major` set on buffer 0 and the minor
modes `minors` added to it, in order. -/
def withModes (major : String) (minors : List String) : TextM EditorState := do
  let state := (← twoBuffers).setMajorMode ⟨0⟩ major |>.2
  return minors.foldl (fun state minor => (state.addMinorMode ⟨0⟩ minor).2) state

/-- The registry of the mode registry checks: a global binding of the keys
of `quit` and of `next-item`, two minor modes and a major mode that fill
roles over one another, and a derived mode whose parent derives from a
root. -/
def modeRegistry : Config.Registry :=
  (({} : Config.Registry).replaceBindings .compiled
        #[{ keys := roleKeys Role.quit, command := "global-quit" },
          { keys := roleKeys Role.nextItem, command := "global-next" }]).replaceModes
    .compiled
    #[filling "m1" [Role.nextItem, Role.previousItem], filling "m2" [Role.nextItem],
      filling "major" [Role.nextItem, Role.previousItem, Role.activate],
      filling "root" [Role.toggle, Role.mark],
      filling "base" [Role.refresh, Role.mark] (some "root"),
      filling "child" [Role.mark] (some "base")]

/-- The checks of modes in the registry (`Editor/Config/Registry.lean`): a
mode's lineage, and the active keymaps of a view. -/
def modeRegistryChecks : List Check :=
  [{  name :=
        "a lineage is the mode then its parents, and ends at a name with no mode and at a cycle"
      run :=
        let looped :=
          modeRegistry.replaceModes .config
            #[filling "a" [] (some "b"), filling "b" [] (some "a"),
              filling "orphan" [] (some "missing")]
        pure
          ((modeRegistry.lineage "child").map (·.name) == ["child", "base", "root"] &&
            (modeRegistry.lineage "root").map (·.name) == ["root"] &&
            (looped.lineage "a").map (·.name) == ["a", "b"] &&
            (looped.lineage "orphan").map (·.name) == ["orphan"] &&
            (looped.lineage "missing").isEmpty) },
    { name :=
        "the active keymaps of a view are its buffer's minor modes', the last added first, then its major mode's lineage's, then the global keymap"
      run :=
        pure <|
          match onTextModel (withModes "major" ["m1", "m2"]) with
          | none => false
          | some state =>
            let lookup := activeLookup modeRegistry state ⟨0⟩
            (modeRegistry.activeMaps TestScheme.scheme state ⟨0⟩).length == 7 &&
              lookup Role.nextItem == .bound (filled "m2" Role.nextItem) &&
              lookup Role.previousItem == .bound (filled "m1" Role.previousItem) &&
              lookup Role.activate == .bound (filled "major" Role.activate) &&
              lookup Role.quit == .bound (invoke "global-quit") &&
              lookup Role.mark == .unbound &&
              activeLookup modeRegistry state ⟨1⟩ Role.nextItem == .bound (invoke "global-next") },
    { name :=
        "a derived mode's own role wins over its parents', and a role it does not fill falls to the nearest that fills it"
      run :=
        pure <|
          match onTextModel (withModes "child" []) with
          | none => false
          | some state =>
            let lookup := activeLookup modeRegistry state ⟨0⟩
            lookup Role.mark == .bound (filled "child" Role.mark) &&
              lookup Role.refresh == .bound (filled "base" Role.refresh) &&
              lookup Role.toggle == .bound (filled "root" Role.toggle) &&
              lookup Role.quit == .bound (invoke "global-quit") },
    { name := "a mode name no mode is registered under contributes nothing"
      run :=
        pure <|
          match onTextModel (withModes "ghost" ["phantom"]) with
          | none => false
          | some state =>
            (modeRegistry.activeMaps TestScheme.scheme state ⟨0⟩).length == 1 &&
              activeLookup modeRegistry state ⟨0⟩ Role.nextItem == .bound (invoke "global-next") },
    { name := "a view with no window has the global keymap alone"
      run :=
        pure <|
          match onTextModel (withModes "major" ["m1"]) with
          | none => false
          | some state =>
            (modeRegistry.activeMaps TestScheme.scheme state ⟨9⟩).length == 1 &&
              activeLookup modeRegistry state ⟨9⟩ Role.nextItem == .bound (invoke "global-next") }]

/-- What a step of the mode dispatch checks is handed: the active keymaps
`registry` makes for the test scheme from the loop's state, and, for every
name, a command that inserts its name at the cursors of the window it acts
on. -/
def modeKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  { maps := registry.activeMaps TestScheme.scheme
    command? := fun name =>
      some fun call => do
        Loop.insert call.target name
        return none }

/-- The text each view shows after the keys `role` is on are pressed in a
loop over `registry`'s active keymaps, from the state `start` makes with
the focus on `view`; none when the run was refused. -/
def roleTyped (registry : Config.Registry) (start : TextM EditorState) (keys : List Key)
    (view : ViewId := ⟨0⟩) : Option (Array (Option String)) :=
  let focused : TextM EditorState := do
    return ((← start).focusWindow view).2
  (lastScene (modeKeys registry) (keys.map press) focused).map (·.2.2)

/-- The checks of modes in the loop (`Editor/Loop.lean`), on the editor's
models and the test scheme: a key a mode binds runs its command in a view
of a buffer that has the mode, and the global binding elsewhere. Each key
is the test scheme's for a role, or its leader, so no check names a key of
a scheme. -/
def modeDispatchChecks : List Check :=
  [{  name :=
        "a key of a role the buffer's major mode fills runs the mode's command in a view of that buffer, and the global binding of the key in a view of a buffer without the mode"
      run :=
        let start := withModes "major" []
        pure
          (roleTyped modeRegistry start (roleKeys Role.nextItem) ==
              some #[some "major-next-item", some "other"] &&
            roleTyped modeRegistry start (roleKeys Role.nextItem) ⟨1⟩ ==
              some #[some "", some "global-nextother"]) },
    { name :=
        "when a minor mode and the major mode fill the same role, the minor mode's command runs"
      run :=
        pure
          (roleTyped modeRegistry (withModes "major" ["m2"]) (roleKeys Role.nextItem) ==
            some #[some "m2-next-item", some "other"]) },
    { name :=
        "a derived mode runs its parent's command for a role it does not fill, and its own for one it does"
      run :=
        let start := withModes "child" []
        pure
          (roleTyped modeRegistry start (roleKeys Role.refresh) ==
              some #[some "base-refresh", some "other"] &&
            roleTyped modeRegistry start (roleKeys Role.mark) ==
              some #[some "child-mark", some "other"]) },
    { name := "the scheme's leader followed by a mode's suffix runs that mode's local command"
      run :=
        let registry :=
          modeRegistry.replaceModes .config
            #[{ filling "major" [Role.nextItem] with locals := [("C-x", "major-local")] }]
        let typed := TestScheme.scheme.leader ++ keys "C-x"
        pure
          (roleTyped registry (withModes "major" []) typed ==
              some #[some "major-local", some "other"] &&
            roleTyped registry (withModes "major" []) typed ⟨1⟩ == some #[some "", some "other"]) }]

/-- A mode called `name` whose on-enter action makes a text naming the mode
and the view it was given, and which derives from `parent`, if given. -/
def entering (name : String) (parent : Option String := none) : Mode :=
  { name, parent, onEnter := fun view => makes s!"{name} in {view.index}" }

/-- The registry of the on-enter checks: `listing` and `other`, and `child`,
which derives from `base`, which derives from `root`. -/
def enterRegistry : Config.Registry :=
  ({} : Config.Registry).replaceModes .compiled
    #[entering "listing", entering "other", entering "root", entering "base" (some "root"),
      entering "child" (some "base")]

/-- What the command `enter` of the on-enter checks says of a refusal, in the
echo area. -/
def modeRefusalText : ModeRefusal → String
  | .noSuchWindow id => s!"no window {id.index}"
  | .noSuchMode name => s!"no mode {name}"
  | .noSuchBuffer id => s!"no buffer {id.index}"

/-- The command `enter` of the on-enter checks: it asks for the mode named
by its second argument to be the major mode of the buffer the view of its
first argument shows, by the request (`ViewId.setMajorMode`), and says a
refusal in the echo area. With `fail` it is then refused with
`badRange`. -/
def enter (fail : Bool := false) : Dispatched := fun call => do
  let [.nat view, .str name] := call.arguments | throw .badPosition
  if let .error refusal← (⟨view⟩ : ViewId).setMajorMode name then
    EditorState.ask (.message (modeRefusalText refusal))
  if fail then
    call.target.buffer.text.delete 9 99
  return none

/-- The command `enter-buffer` of the on-enter checks: it asks for the mode
named by its second argument to be the major mode of the buffer its first
argument numbers, by the request (`BufferId.setMajorMode`), and says a
refusal in the echo area. -/
def enterBuffer : Dispatched := fun call => do
  let [.nat buffer, .str name] := call.arguments | throw .badPosition
  if let .error refusal← (⟨buffer⟩ : BufferId).setMajorMode name then
    EditorState.ask (.message (modeRefusalText refusal))
  return none

/-- What a step of the on-enter checks is handed: the commands `enter`,
`enter-fail` and `enter-buffer`, and what `registry` says of its modes. -/
def enterKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ([("enter", enter), ("enter-fail", enter true), ("enter-buffer", enterBuffer)].find?
            (·.1 == name)).map
        (·.2)
    registered := registry.registered }

/-- Sets the major mode of each buffer in `steps`, by its number, in turn,
each by an invocation of `enter-buffer` the loop runs, from `twoBuffers`
with a third buffer, `loose`, that no window shows: the texts made after
the three, what each invocation left in the echo area, and each buffer's
major mode at the end. `none` when the run was refused. -/
def enteredBuffer (steps : List (Nat × String)) :
    Option (Array String × List String × Array (Option String)) :=
  let program : EditorM (List String × EditorState) := do
    let two ← twoBuffers
    let text ← createText "loose"
    let history ← UndoTree.over text
    let mut state :=
      { two with buffers := two.buffers.push (some { name := "loose", text, history }) }
    let mut echoes := []
    for (buffer, name) in steps do
      let invocation : Invocation :=
        { command := "enter-buffer", arguments := [.nat buffer, .str name] }
      state := (← Loop.run (enterKeys enterRegistry) state invocation []).state
      echoes := echoes ++ [state.echo]
    return (echoes, state)
  match program.runModel editorModel with
  | (.ok (echoes, state), model) =>
    let texts := model.texts.contents
    some (texts.extract 3 texts.size, echoes, state.buffers.map (·.bind (·.major)))
  | (.error _, _) => none

/-- The invocation of `command` that sets the mode `name` through `view`. -/
def entersMode (view : ViewId) (name : String) (command : String := "enter") : Invocation :=
  { command, arguments := [.nat view.index, .str name] }

/-- Sets the major mode of the buffer of each view in `steps` in turn, each
by an invocation of `enter` the loop runs (`Loop.run`) over `registry`,
from `twoBuffers`, on the editor's models with the watch model `watch`: the
texts made, in order, after the two the state was made with, what each
invocation left in the echo area, and each buffer's major mode at the end.
`none` when the run was refused. -/
def entered (steps : List (ViewId × String)) (registry : Config.Registry := enterRegistry)
    (watch : WatchModel := {}) : Option (Array String × List String × Array (Option String)) :=
  let program : EditorM (List String × EditorState) := do
    let mut state ← twoBuffers
    let mut echoes := []
    for (view, name) in steps do
      state := (← Loop.run (enterKeys registry) state (entersMode view name) []).state
      echoes := echoes ++ [state.echo]
    return (echoes, state)
  match program.runModel { editorModel with watch } with
  | (.ok (echoes, state), model) =>
    let texts := model.texts.contents
    some (texts.extract 2 texts.size, echoes, state.buffers.map (·.bind (·.major)))
  | (.error _, _) => none

/-- Each face, by name, `-` for none. -/
def faceNames (faces : Array (Option FaceName)) : Array String :=
  faces.map fun face => (face.map (·.name)).getD "-"

/-- The checks of the capture-to-face rule (`Editor/Highlight.lean`), pure:
the shipped default, the fallback of a dotted capture to its first
component, and config's mapping over both. -/
def highlightFaceChecks : List Check :=
  let faceOf (config : List (String × Option FaceName)) (capture : String) : String :=
    ((Highlight.faceOf config capture).map (·.name)).getD "-"
  [{  name :=
        "by the shipped default, each capture of the face vocabulary's syntax captures is drawn in its syntax face, the vocabulary's own"
      run :=
        pure
          (Face.syntaxCaptures.all
              (fun (capture, _) => faceOf [] capture == s!"syntax.{capture}") &&
            Highlight.defaultFaces.map (·.2) == (Face.syntaxEntries.map (·.name)).toList) },
    { name :=
        "a dotted capture with no mapping of its own is drawn in its first component's face, and a capture nothing maps draws nothing"
      run :=
        pure
          (faceOf [] "keyword.control" == "syntax.keyword" &&
            faceOf [] "function.method" == "syntax.function" &&
            faceOf [] "punctuation.bracket" == "syntax.punctuation" &&
            faceOf [] "string.special.key" == "syntax.string" &&
            faceOf [] "escape" == "-" &&
            faceOf [] "label" == "-" &&
            faceOf [] "escape.x" == "-") },
    { name :=
        "config's mapping wins over the default: a full name for itself alone, a first component for every dotted capture under it with no entry of its own, and none draws nothing"
      run :=
        pure
          (faceOf [("keyword.control", some ⟨"my-face"⟩)] "keyword.control" == "my-face" &&
            faceOf [("keyword.control", some ⟨"my-face"⟩)] "keyword" == "syntax.keyword" &&
            faceOf [("string", some ⟨"json-string"⟩)] "string.special.key" == "json-string" &&
            faceOf [("string", some ⟨"json-string"⟩)] "string" == "json-string" &&
            faceOf [("number", none)] "number" == "-" &&
            faceOf [("number", none)] "number.float" == "-" &&
            faceOf [("escape", some ⟨"syntax.string"⟩)] "escape" == "syntax.string") },
    { name := "a full name mapped to none stops the fallback to its first component"
      run :=
        pure
          (faceOf [("keyword.control", none)] "keyword.control" == "-" &&
            faceOf [("keyword.control", none)] "keyword.return" == "syntax.keyword") },
    { name := "a query's faces are each capture name's, in order"
      run :=
        pure
          (faceNames (Highlight.faces [("number", some ⟨"n"⟩)] #["string", "number", "label"]) ==
            #["syntax.string", "n", "-"]) }]

/-- A mode called `name` whose text is parsed and drawn as `syntaxTree`
says. -/
def parsedMode (name : String) (syntaxTree : Mode.SyntaxTree := { grammar := "json" }) : Mode :=
  { name, syntaxTree := some syntaxTree }

/-- Sets each mode of `steps`, in turn, as the major mode of buffer 1
through view 1, by an invocation of `enter` the loop runs, over the
registry of the on-enter checks with `modes` registered for config, and
config's syntax refresh delay `refreshDelay`, the compiled languages
`languages` and buffer 1's language `language`, on the editor's models: what each left in the echo area, buffer 1's major mode at
the end, and the syntax tree model then. `none` when the run was
refused. -/
def highlightedBy (modes : Array Mode) (steps : List String) (refreshDelay : Option Nat := none)
    (languages : Array Language := #[]) (language : Option String := none) :
    Option (List String × Option String × SyntaxTreeModel) :=
  let registry :=
    { (enterRegistry.replaceModes .config modes).replaceLanguages .compiled languages with
      syntaxRefreshDelay := refreshDelay }
  let program : EditorM (List String × EditorState) := do
    let mut state := ((← twoBuffers).setLanguage ⟨1⟩ language).2
    let mut echoes := []
    for name in steps do
      state := (← Loop.run (enterKeys registry) state (entersMode ⟨1⟩ name) []).state
      echoes := echoes ++ [state.echo]
    return (echoes, state)
  match program.runModel editorModel with
  | (.ok (echoes, state), model) =>
    some (echoes, (state.buffer? ⟨1⟩).bind (·.major), model.syntaxTree)
  | (.error _, _) => none

/-- The faces of the syntax tree model's highlighter, by name, `-` for
none; none when no text is highlighted. -/
def highlightedFaces (model : SyntaxTreeModel) : Option (Array String) :=
  model.highlighted.back?.map fun (_, _, faces) => faceNames faces

/-- The checks of setting a major mode with a syntax tree
(`Editor/Highlight.lean`, `Editor/Command/Dispatch.lean`), on the editor's
models through the loop's dispatch: what the syntax tree model is asked and
records. -/
def highlightEnterChecks : List Check :=
  [{  name :=
        "the code mode over a buffer whose language is json attaches its text with json and highlights it with the language's tree, the grammar's shipped query; the language's own query is compiled in its place when it has one"
      run :=
        pure <|
          let numbers :=
            { Language.json with
              syntaxTree := { grammar := "json", highlights := some "(number) @number" } }
          (match
              highlightedBy Language.modes ["code"] (languages := #[Language.json]) (language :=
                some "json") with
            | some (echoes, major, model) =>
              echoes == [""] && major == some "code" && model.attached.map (·.2) == #["json"] &&
                highlightedFaces model ==
                  some #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"]
            | none => false) &&
            match
              highlightedBy Language.modes ["code"] (languages := #[numbers]) (language :=
                some "json") with
            | some (_, _, model) => highlightedFaces model == some #["syntax.number"]
            | none => false },
    { name :=
        "the code mode over a buffer with no language, or with a language no entry is registered under, is set and asks the syntax tree port nothing"
      run :=
        pure <|
          [none, some "cobol"].all fun language =>
            match
              highlightedBy Language.modes ["code"] (languages := #[Language.json]) (language :=
                language) with
            | some (echoes, major, model) =>
              echoes == [""] && major == some "code" && model.attached.isEmpty &&
                model.highlighted.isEmpty &&
                model.refreshAfter == none
            | none => false },
    { name :=
        "entering a major mode with a syntax tree hands the syntax service config's refresh delay, or the default when config sets none"
      run :=
        pure <|
          (match highlightedBy #[parsedMode "json"] ["json"] with
            | some (_, _, model) => model.refreshAfter == some Highlight.defaultRefreshDelay
            | none => false) &&
            Highlight.defaultRefreshDelay == 500 &&
            match highlightedBy #[parsedMode "json"] ["json"] (some 250) with
            | some (_, _, model) => model.refreshAfter == some 250
            | none => false },
    { name :=
        "a major mode with a syntax tree attaches its buffer's text and highlights it with the grammar's shipped query, each capture in its syntax face by the shipped default, and releases the query"
      run :=
        pure <|
          match highlightedBy #[parsedMode "json"] ["json"] with
          | some (echoes, major, model) =>
            echoes == [""] && major == some "json" && model.attached.map (·.2) == #["json"] &&
              highlightedFaces model ==
                some #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"] &&
              model.queries.all (·.isNone)
          | none => false },
    { name := "a capture the mode's config maps to a face is highlighted in that face"
      run :=
        pure <|
          let mapped :=
            parsedMode "json" { grammar := "json", captures := [("string", some ⟨"json-string"⟩)] }
          match highlightedBy #[mapped] ["json"] with
          | some (_, _, model) =>
            highlightedFaces model ==
              some #["json-string", "json-string", "syntax.number", "syntax.constant"]
          | none => false },
    { name :=
        "a mode's own highlights query is compiled in place of the shipped one, a dotted capture falling to its first component and an unmapped one drawing nothing"
      run :=
        pure <|
          let own :=
            parsedMode "numbers"
              { grammar := "json", highlights := some "(number) @number.float\n(null) @label" }
          match highlightedBy #[own] ["numbers"] with
          | some (_, _, model) => highlightedFaces model == some #["syntax.number", "-"]
          | none => false },
    { name :=
        "a query that does not compile, and a grammar the service lacks, are said in the echo area under the mode's name; the mode is set and the command runs to its end"
      run :=
        pure <|
          let broken := parsedMode "broken" { grammar := "json", highlights := some "((" }
          let cobol := parsedMode "cobol-mode" { grammar := "cobol" }
          (match highlightedBy #[broken] ["broken"] with
            | some ([echo], major, model) =>
              echo.startsWith "highlights: `broken`: the query is not one" &&
                major == some "broken" &&
                model.highlighted.isEmpty
            | _ => false) &&
            match highlightedBy #[cobol] ["cobol-mode"] with
            | some ([echo], major, model) =>
              echo == "highlights: `cobol-mode`: no grammar of that name" &&
                major == some "cobol-mode" &&
                model.attached.isEmpty
            | _ => false },
    { name :=
        "a refused mode set over a highlighted one leaves its text detached, so nothing of the mode before is drawn: a grammar the service lacks, and a query of the same grammar that does not compile; the echo area still says the refusal"
      run :=
        pure <|
          let broken := parsedMode "broken" { grammar := "json", highlights := some "((" }
          let cobol := parsedMode "cobol-mode" { grammar := "cobol" }
          let modes := #[parsedMode "json", broken, cobol]
          (match highlightedBy modes ["json", "cobol-mode"] with
            | some (["", echo], major, model) =>
              echo == "highlights: `cobol-mode`: no grammar of that name" &&
                major == some "cobol-mode" &&
                model.attached.isEmpty &&
                model.highlighted.isEmpty
            | _ => false) &&
            match highlightedBy modes ["json", "broken"] with
            | some (["", echo], major, model) =>
              echo.startsWith "highlights: `broken`: the query is not one" &&
                major == some "broken" &&
                model.attached.isEmpty &&
                model.highlighted.isEmpty
            | _ => false },
    { name :=
        "a mode with an injections source finds its text's injections with it, and gives a language for the model's grammar, its shipped highlights in the default faces and the mode's injections; every query is released"
      run :=
        pure <|
          let injecting :=
            parsedMode "injecting"
              { grammar := "json", injections := some "(pair value: (string) @injection.content)" }
          match highlightedBy #[injecting] ["injecting"] with
          | some ([""], _, model) =>
            model.injected.size == 1 &&
              model.languages.map
                  (fun (_, name, _, faces, injections) =>
                    (name, faceNames faces, injections.isSome)) ==
                #[("json", #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"],
                    true)] &&
              model.queries.all (·.isNone)
          | _ => false },
    { name :=
        "a grammar that ships no injections, text objects or indents query records no injection, no language and no kept query"
      run :=
        pure <|
          match highlightedBy #[parsedMode "json"] ["json"] with
          | some ([""], _, model) =>
            model.injected.isEmpty && model.languages.isEmpty && model.kept.isEmpty &&
              !model.highlighted.isEmpty
          | _ => false },
    { name :=
        "a mode's own text objects and indents sources are kept, each as its kind, and their queries released"
      run :=
        pure <|
          let keeping :=
            parsedMode "keeping"
              { grammar := "json", textObjects := some "(object) @function.outer"
                indents := some "(array) @indent.begin" }
          match highlightedBy #[keeping] ["keeping"] with
          | some ([""], _, model) =>
            model.kept.map (fun (_, kind, query) => (kind, query.names)) ==
                #[(.textObjects, #["function.outer"]), (.indents, #["indent.begin"])] &&
              model.queries.all (·.isNone)
          | _ => false },
    { name :=
        "an injections, text objects or indents source that does not compile is said in the echo area under the mode's name, stops its own step alone, and leaves the highlights and the text attached"
      run :=
        pure <|
          let broken (injections textObjects indents : Option String) :=
            parsedMode "broken" { grammar := "json", injections, textObjects, indents }
          let said (mode : Mode) (start : String) : Bool :=
            match highlightedBy #[mode] ["broken"] with
            | some ([echo], major, model) =>
              echo.startsWith start && major == some "broken" && !model.attached.isEmpty &&
                !model.highlighted.isEmpty
            | _ => false
          let keptIndents :=
            match
              highlightedBy #[broken (some "((") none (some "(array) @indent.begin")]
                ["broken"] with
            | some (_, _, model) => model.kept.map (·.2.1) == #[.indents]
            | none => false
          said (broken (some "((") none none) "injections: `broken`: the query is not one" &&
            said (broken none (some "((") none) "text objects: `broken`: the query is not one" &&
            said (broken none none (some "((")) "indents: `broken`: the query is not one" &&
            keptIndents },
    { name := "a derived mode that says nothing of a syntax tree takes its parent's"
      run :=
        pure <|
          let child : Mode := { name := "json-child", parent := some "json" }
          match highlightedBy #[parsedMode "json", child] ["json-child"] with
          | some (_, major, model) =>
            major == some "json-child" &&
              highlightedFaces model ==
                some #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"]
          | none => false },
    { name :=
        "a major mode with no syntax tree set over one with a syntax tree detaches the text, which drops its highlights; one set over a mode with none asks the syntax tree port nothing"
      run :=
        pure <|
          (match highlightedBy #[parsedMode "json"] ["json", "listing"] with
            | some (_, major, model) =>
              major == some "listing" && model.attached.isEmpty && model.highlighted.isEmpty
            | none => false) &&
            match highlightedBy #[] ["listing", "other"] with
            | some (_, major, model) =>
              major == some "other" && model.texts.isEmpty && model.attached.isEmpty
            | none => false },
    { name :=
        "a major mode with no syntax tree set over the code mode on a buffer whose language has a tree detaches the text, which drops its highlights"
      run :=
        pure <|
          match
            highlightedBy Language.modes ["code", "listing"] (languages := #[Language.json])
              (language := some "json") with
          | some (_, major, model) =>
            major == some "listing" && model.attached.isEmpty && model.highlighted.isEmpty
          | none => false }]

/-- A node of the indents query, for the indent rule's checks: its capture's
name, where it starts, and its first and last rows. -/
def indentNode (name : String) (start firstRow lastRow : Nat) : Indent.Captured :=
  { name, start, firstRow, lastRow }

/-- The rows from 0 through `last`, each with its first non-blank at the
offset `firstNonBlanks` gives it, or 1000 past it. -/
def indentLines (firstNonBlanks : List Nat) : Array Indent.Line :=
  (firstNonBlanks.zipIdx.map fun (offset, row) => { row, firstNonBlank := offset }).toArray

/-- The checks of the indent rule (`Indent.rule`, `Editor/Indent.lean`),
pure, over hand-built rows. -/
def indentRuleChecks : List Check :=
  [{  name := "begins on one row count once, and each begin counts on the rows after its first"
      run :=
        pure
          (Indent.rule
              #[indentNode "indent.begin" 0 0 3, indentNode "indent.begin" 4 0 3,
                indentNode "indent.begin" 10 1 2]
              (indentLines [0, 10, 20, 30]) ==
            #[some 0, some 1, some 2, some 1]) },
    { name := "a branch takes a level away only where it starts a row's first non-blank"
      run :=
        pure
          (Indent.rule
              #[indentNode "indent.begin" 0 0 2, indentNode "indent.branch" 20 2 2,
                indentNode "indent.branch" 15 1 1]
              (indentLines [0, 12, 20]) ==
            #[some 0, some 1, some 0]) },
    { name := "the level is never below 0"
      run :=
        pure (Indent.rule #[indentNode "indent.branch" 0 0 0] (indentLines [0]) == #[some 0]) },
    { name :=
        "the rows of an ignored node after its first keep their indent, and so its first does not"
      run :=
        pure
          (Indent.rule #[indentNode "indent.begin" 0 0 3, indentNode "indent.ignore" 10 1 2]
              (indentLines [0, 10, 20, 30]) ==
            #[some 0, some 1, none, some 1]) },
    { name := "a node whose last byte is on the row before reaches no further"
      run :=
        pure
          (Indent.rule #[indentNode "indent.begin" 0 0 1] (indentLines [0, 5, 9]) ==
            #[some 0, some 1, some 0]) },
    { name := "a blank row gets the level a line typed there would have"
      run :=
        pure
          (Indent.rule #[indentNode "indent.begin" 0 0 2] (indentLines [0, 2, 3]) ==
            #[some 0, some 1, some 1]) },
    { name := "names the rule does not read are ignored"
      run :=
        pure
          (Indent.rule
              #[indentNode "indent.align" 0 0 2, indentNode "function.outer" 0 0 2,
                indentNode "indent.begin" 0 0 2]
              (indentLines [0, 2, 3]) ==
            #[some 0, some 1, some 1]) },
    { name :=
        "an opening bracket the tree did not close counts its row for every row after it, not for its own, and with a begin on the same row it counts once"
      run :=
        -- Each is held by an error from the text's start through its last row.
        let error := indentNode "indent.incomplete" 0 0 2
        pure
          (Indent.rule #[indentNode "indent.open" 10 0 0, error] (indentLines [0, 12, 20]) ==
              #[some 0, some 1, some 1] &&
            Indent.rule #[indentNode "indent.open" 10 1 1, error] (indentLines [0, 12, 20]) ==
              #[some 0, some 0, some 1] &&
            Indent.rule #[indentNode "indent.open" 10 0 0, indentNode "indent.begin" 0 0 1, error]
                (indentLines [0, 12, 20]) ==
              #[some 0, some 1, some 1] &&
            Indent.rule #[indentNode "indent.open" 10 0 0, indentNode "indent.open" 30 1 1, error]
                (indentLines [0, 12, 40]) ==
              #[some 0, some 1, some 2]) },
    { name :=
        "an opening bracket counts only on the rows an incomplete node that starts at or before it reaches: a call's `(` whose partner is missing mid-function leaves the rows after its node, the function's `}` and the next function, at their levels"
      run :=
        -- fn a() {        row 0
        --     foo(1;      row 1: `(` at 16, where `arguments` starts
        -- }               row 2
        --                 row 3
        -- fn b() {        row 4
        --     x           row 5
        -- }               row 6
        let captured :=
          #[indentNode "indent.begin" 7 0 2, indentNode "indent.branch" 21 2 2,
            indentNode "indent.open" 16 1 1, indentNode "indent.incomplete" 16 1 1,
            indentNode "indent.begin" 31 4 6, indentNode "indent.branch" 39 6 6]
        pure
          (Indent.rule captured (indentLines [0, 13, 21, 23, 24, 37, 39]) ==
              #[some 0, some 1, some 0, some 0, some 0, some 1, some 0] &&
            -- An incomplete node that ends before the bracket's row, or
            -- starts after the bracket, does not hold it.
            Indent.rule #[indentNode "indent.open" 10 1 1, indentNode "indent.incomplete" 0 0 0]
                (indentLines [0, 5, 20]) ==
              #[some 0, some 0, some 0] &&
            Indent.rule #[indentNode "indent.open" 10 1 1, indentNode "indent.incomplete" 12 1 3]
                (indentLines [0, 5, 20, 30]) ==
              #[some 0, some 0, some 0, some 0] &&
            -- An error that holds the bracket counts it on the rows it
            -- reaches only.
            Indent.rule #[indentNode "indent.open" 10 0 0, indentNode "indent.incomplete" 0 0 2]
                (indentLines [0, 12, 20, 30]) ==
              #[some 0, some 1, some 1, some 0]) },
    { name := "an incomplete node alone adds no level: the rows it holds keep the level they had"
      run :=
        pure
          (Indent.rule #[indentNode "indent.incomplete" 0 0 2] (indentLines [0, 2, 3]) ==
            #[some 0, some 0, some 0]) }]

/-- A node of the indents query, for the opening rule's checks: its
capture's name and the offsets it starts and stops at. -/
def openingNode (name : String) (start stop : Nat) : Indent.Node :=
  { name, start, stop }

/-- The checks of the opening rule (`Indent.openingCounts`,
`Indent.levelOf`) and of the widening (`Indent.widenedStart`), pure, over
hand-built nodes. -/
def indentOpeningChecks : List Check :=
  [{  name :=
        "a begin node that holds the position counts, and one that ends at it or starts at it does not"
      run :=
        pure
          (Indent.openingCounts #[openingNode "indent.begin" 3 20] { offset := 10 } ==
              some (#[3], false) &&
            Indent.openingCounts #[openingNode "indent.begin" 3 10] { offset := 10 } ==
              some (#[], false) &&
            Indent.openingCounts #[openingNode "indent.begin" 10 20] { offset := 10 } ==
              some (#[], false)) },
    { name := "an opening bracket the tree did not close counts when it starts before the position"
      run :=
        pure
          (Indent.openingCounts #[openingNode "indent.open" 3 4] { offset := 10 } ==
              some (#[3], false) &&
            Indent.openingCounts #[openingNode "indent.open" 10 11] { offset := 10 } ==
              some (#[], false) &&
            Indent.openingCounts #[openingNode "indent.open" 12 13] { offset := 10 } ==
              some (#[], false)) },
    { name :=
        "a branch at the first non-blank that moves to the new row says so, and none for an empty new row"
      run :=
        let nodes := #[openingNode "indent.begin" 0 20, openingNode "indent.branch" 12 13]
        pure
          (Indent.openingCounts nodes { offset := 10, firstNonBlank := some 12 } ==
              some (#[0], true) &&
            Indent.openingCounts nodes { offset := 10, firstNonBlank := some 11 } ==
              some (#[0], false) &&
            Indent.openingCounts nodes { offset := 10 } == some (#[0], false)) },
    { name := "a position inside an ignored node adds nothing, and one at its ends does"
      run :=
        let ignored := openingNode "indent.ignore" 5 15
        pure
          (Indent.openingCounts #[openingNode "indent.begin" 0 20, ignored] { offset := 10 } ==
              none &&
            Indent.openingCounts #[ignored] { offset := 5 } == some (#[], false) &&
            Indent.openingCounts #[ignored] { offset := 15 } == some (#[], false)) },
    { name := "names the opening rule does not read are ignored"
      run :=
        pure
          (Indent.openingCounts
              #[openingNode "indent.incomplete" 0 20, openingNode "function.outer" 0 20]
              { offset := 10 } ==
            some (#[], false)) },
    { name :=
        "the level is the number of distinct rows counted, less one for a branch, and never below 0"
      run :=
        pure
          (Indent.levelOf #[0, 0, 2] false == 2 && Indent.levelOf #[0, 0, 2] true == 1 &&
            Indent.levelOf #[] true == 0 &&
            Indent.levelOf #[] false == 0) },
    { name :=
        "the widened start is the earliest start of an incomplete node, or the asked start when that is earlier"
      run :=
        pure
          (Indent.widenedStart
                #[openingNode "indent.incomplete" 4 30, openingNode "indent.incomplete" 2 30,
                  openingNode "indent.begin" 0 30]
                10 ==
              2 &&
            Indent.widenedStart #[openingNode "indent.incomplete" 12 30] 10 == 10 &&
            Indent.widenedStart #[] 10 == 10) }]

/-- A row of a text, as the re-indent reads it, starting at `start` with
the whitespace `leading` before what it holds, `content` bytes of it after
that, and the level `level`. -/
def reindentRow (start : Nat) (leading : String) (content : Nat) (level : Option Nat) :
    Indent.Row :=
  { start, firstNonBlank := start + leading.utf8ByteSize
    content := start + leading.utf8ByteSize + content, leading, level }

/-- The checks of the indent decisions as edits (`Indent.whitespace`,
`Indent.reindent`, `Indent.newLine`, `Indent.breakAt`), pure. -/
def indentEditChecks : List Check :=
  [{  name := "a level is that many units: spaces times the count, or tabs, and level 0 is nothing"
      run :=
        pure
          (Indent.whitespace (.spaces 4) 2 == "        " && Indent.whitespace .tab 2 == "\t\t" &&
            Indent.whitespace (.spaces 2) 0 == "" &&
            Indent.whitespace .tab 0 == "") },
    { name :=
        "the re-indent replaces each row's leading whitespace with its level, from its start to its first non-blank, and leaves a row already right"
      run :=
        pure
          (Indent.reindent (.spaces 2)
              #[reindentRow 0 "" 3 (some 0), reindentRow 4 "" 3 (some 1),
                reindentRow 8 "      " 3 (some 1), reindentRow 18 "\t" 1 (some 2)] ==
            #[(⟨4, 4⟩, "  "), (⟨8, 14⟩, "  "), (⟨18, 19⟩, "    ")]) },
    { name := "a blank row gets no whitespace, whatever its level"
      run :=
        pure
          (Indent.reindent (.spaces 4)
              #[reindentRow 0 "   " 0 (some 2), reindentRow 4 "" 0 (some 1)] ==
            #[(⟨0, 3⟩, "")]) },
    { name := "a row with no level keeps its whitespace, a blank one too"
      run :=
        pure
          (Indent.reindent (.spaces 4)
              #[reindentRow 0 "   " 4 none, reindentRow 8 "     " 0 none] ==
            #[]) },
    { name := "a tab unit indents with tabs"
      run :=
        pure
          (Indent.reindent .tab
              #[reindentRow 0 "    " 1 (some 1), reindentRow 6 "\t\t" 1 (some 2)] ==
            #[(⟨0, 4⟩, "\t")]) },
    { name :=
        "a new line gets its level as whitespace, nothing inside a string or comment, the row's own indent when the text is not parsed yet, and nothing when the text has no tree or no indents query"
      run :=
        pure
          (Indent.newLine (.spaces 4) (.ok (some 2)) "  " == some "        " &&
            Indent.newLine (.spaces 4) (.ok none) "  " == none &&
            Indent.newLine (.spaces 4) (.error .notParsed) "  " == some "  " &&
            Indent.newLine (.spaces 4) (.error .notAttached) "  " == none &&
            Indent.newLine (.spaces 4) (.error .noQuery) "  " == none) },
    { name :=
        "a line break with no indent is the line ending at the bar; with one it replaces the blanks either side of the bar with the line ending and the indent"
      run :=
        pure
          (Indent.breakAt "\n" none 10 2 3 == (⟨10, 10⟩, "\n") &&
            Indent.breakAt "\r\n" (some "  ") 10 2 3 == (⟨8, 13⟩, "\r\n  ") &&
            Indent.breakAt "\n" (some "") 10 0 0 == (⟨10, 10⟩, "\n")) }]

/-- The indents source of the model's test mode: an object and an array
indent what they hold, and their closing brackets lead out. -/
def jsonIndents : String :=
  "(object) @indent.begin\n(array) @indent.begin\n\"}\" @indent.branch\n\"]\" @indent.branch"

/-- The indent levels of rows `first` through `last` of a text of `text`, set
to a test mode with `syntaxTree` when given, on the editor's models: the
levels on the right, a refusal on the left; `none` when the command was
refused. -/
def indentLevelsOf (text : String) (syntaxTree : Option Mode.SyntaxTree) (first last : Nat) :
    Option (Sum SyntaxTreeError (Array (Option Nat))) :=
  let program : EditorM (Except SyntaxTreeError (Array (Option Nat))) := do
    let id ← createText text
    if let some syntaxTree := syntaxTree then
      Highlight.enter "test" id syntaxTree
    id.indentLevels first last
  match program.runModel editorModel with
  | (.ok (.ok levels), _) => some (.inr levels)
  | (.ok (.error refusal), _) => some (.inl refusal)
  | (.error _, _) => none

/-- An indents source of the model's JSON grammar whose array is a node the
parser could not complete and whose opening bracket one the tree did not
close: what the widening reads. -/
def widenedIndents : String :=
  "(array) @indent.incomplete\n\"[\" @indent.open"

/-- The opening level of a line opened at `offset` of a text of `text`, with
what follows it on its row moved to the new row when `rest`, set to a test
mode with `syntaxTree` when given, on the editor's models: the level on the
right, a refusal on the left; `none` when the command was refused. -/
def openingLevelOf (text : String) (syntaxTree : Option Mode.SyntaxTree) (offset : Nat)
    (rest : Bool) : Option (Sum SyntaxTreeError (Option Nat)) :=
  let program : EditorM (Except SyntaxTreeError (Option Nat)) := do
    let id ← createText text
    if let some syntaxTree := syntaxTree then
      Highlight.enter "test" id syntaxTree
    id.openingLevel offset rest
  match program.runModel editorModel with
  | (.ok (.ok level), _) => some (.inr level)
  | (.ok (.error refusal), _) => some (.inl refusal)
  | (.error _, _) => none

/-- The re-indent's edits of rows `first` through `last` of a text of
`text` in `unit`, set to a test mode with `syntaxTree` when given, on the
editor's models: the edits on the right, a refusal on the left; `none` when
the command was refused. -/
def reindentEditsOf (text : String) (syntaxTree : Option Mode.SyntaxTree) (first last : Nat)
    (unit : Language.IndentUnit) : Option (Sum SyntaxTreeError (Array (Extent × String))) :=
  let program : EditorM (Except SyntaxTreeError (Array (Extent × String))) := do
    let id ← createText text
    if let some syntaxTree := syntaxTree then
      Highlight.enter "test" id syntaxTree
    id.reindentEdits first last unit
  match program.runModel editorModel with
  | (.ok (.ok edits), _) => some (.inr edits)
  | (.ok (.error refusal), _) => some (.inl refusal)
  | (.error _, _) => none

/-- The checks of the indent primitive (`TextId.indentLevels`,
`Editor/Indent.lean`), on the editor's models through the syntax tree
model. -/
def indentLevelChecks : List Check :=
  let pretty := "{\n  \"a\": [\n    1,\n    {\n      \"b\": null\n    }\n  ],\n\n  \"c\": {}\n}\n"
  let spaces (line : String) : Nat := (line.toList.takeWhile (· == ' ')).length
  [{  name :=
        "a two-space pretty-printed JSON text, under a test mode's indents query, gets each row's leading spaces divided by two, a blank row the level of what holds it"
      run :=
        pure <|
          let lines := pretty.splitOn "\n"
          let expected :=
            (lines.take (lines.length - 1)).toArray.map fun line =>
              if line.isEmpty then some 1 else some (spaces line / 2)
          indentLevelsOf pretty (some { grammar := "json", indents := some jsonIndents }) 0 9 ==
            some (.inr expected) },
    { name := "rows past the text's last are left out, and a first row past the last answers none"
      run :=
        pure <|
          let mode := some { grammar := "json", indents := some jsonIndents }
          indentLevelsOf "[\n  1\n]" mode 1 7 == some (.inr #[some 1, some 0]) &&
            indentLevelsOf "[\n  1\n]" mode 3 4 == some (.inr #[]) },
    { name := "a text with no syntax tree is refused as not attached"
      run := pure (indentLevelsOf "[1]" none 0 0 == some (.inl .notAttached)) },
    { name := "a text whose grammar ships no indents query is refused as keeping none"
      run := pure (indentLevelsOf "[1]" (some { grammar := "json" }) 0 0 == some (.inl .noQuery)) },
    { name := "a mode with an empty indents source answers 0 for every row"
      run :=
        pure
          (indentLevelsOf pretty (some { grammar := "json", indents := some "" }) 0 3 ==
            some (.inr #[some 0, some 0, some 0, some 0])) },
    { name :=
        "a row inside a node captured incomplete is asked from that node's start, so an opening bracket it holds far above counts"
      run :=
        pure <|
          let mode := some { grammar := "json", indents := some widenedIndents }
          indentLevelsOf "[\n1,\n2,\n3\n]" mode 3 3 == some (.inr #[some 1]) &&
            indentLevelsOf "[\n1,\n2,\n3\n]" mode 0 1 == some (.inr #[some 0, some 1]) },
    { name :=
        "the opening level is the level of a line opened at a position: one in after an opening bracket, at the body's level after an item, one out with a closing bracket moved to the new row, and none asked of a text with no tree or no indents query"
      run :=
        pure <|
          let mode := some { grammar := "json", indents := some jsonIndents }
          let text := "{\n  \"a\": [\n  ]\n}"
          let afterBracket := 10
          openingLevelOf text mode afterBracket true == some (.inr (some 2)) &&
            openingLevelOf text mode 9 true == some (.inr (some 1)) &&
            openingLevelOf text mode 11 true == some (.inr (some 1)) &&
            openingLevelOf text mode 11 false == some (.inr (some 2)) &&
            openingLevelOf text mode (text.utf8ByteSize) true == some (.inr (some 0)) &&
            openingLevelOf text none afterBracket true == some (.inl .notAttached) &&
            openingLevelOf text (some { grammar := "json" }) afterBracket true ==
              some (.inl .noQuery) },
    { name :=
        "the opening level is asked from the start of a node captured incomplete, so an opening bracket it holds far above counts"
      run :=
        pure
          (openingLevelOf "[\n1,\n2,\n3\n]"
              (some { grammar := "json", indents := some widenedIndents }) 7 false ==
            some (.inr (some 1))) },
    { name :=
        "the re-indent's edits of rows read from the text: each row's leading whitespace from its start to its first non-blank becomes its level in the unit, a row already right and a blank row already empty have none; refused as the primitive is"
      run :=
        pure <|
          let mode := some { grammar := "json", indents := some jsonIndents }
          reindentEditsOf "[\n1,\n      2\n\n   \n]" mode 0 5 (.spaces 2) ==
              some (.inr #[(⟨2, 2⟩, "  "), (⟨5, 11⟩, "  "), (⟨14, 17⟩, "")]) &&
            reindentEditsOf "[\n1\n]" mode 1 1 .tab == some (.inr #[(⟨2, 2⟩, "\t")]) &&
            reindentEditsOf "[1]" none 0 0 (.spaces 2) == some (.inl .notAttached) }]

/-- The checks of a mode's on-enter action, on the editor's models: a
command asks for a major mode by the request, and the loop that runs the
command runs the mode's on-enter actions inside it
(`Editor/Command/Dispatch.lean`). -/
def modeEnterChecks : List Check :=
  [{  name :=
        "the on-enter action runs once, with the view, when the mode becomes a buffer's major mode"
      run :=
        pure
          (entered [(⟨0⟩, "listing")] == some (#["listing in 0"], [""], #[some "listing", none]) &&
            entered [(⟨1⟩, "listing")] ==
              some (#["listing in 1"], [""], #[none, some "listing"])) },
    { name :=
        "setting the major mode a buffer already has runs nothing; setting another and then it again runs each"
      run :=
        pure
          (entered [(⟨0⟩, "listing"), (⟨0⟩, "listing")] ==
              some (#["listing in 0"], ["", ""], #[some "listing", none]) &&
            entered [(⟨0⟩, "listing"), (⟨0⟩, "other"), (⟨0⟩, "listing")] ==
              some
                (#["listing in 0", "other in 0", "listing in 0"], ["", "", ""],
                  #[some "listing", none])) },
    { name := "a derived mode's lineage runs its on-enter actions root first, each once"
      run :=
        pure
          (entered [(⟨1⟩, "child")] ==
            some (#["root in 1", "base in 1", "child in 1"], [""], #[none, some "child"])) },
    { name :=
        "setting a mode no mode is registered under is refused with noSuchMode, and one for a view with no window with noSuchWindow; each changes nothing and runs nothing"
      run :=
        pure
          (entered [(⟨0⟩, "ghost")] == some (#[], ["no mode ghost"], #[none, none]) &&
            entered [(⟨9⟩, "listing")] == some (#[], ["no window 9"], #[none, none]) &&
            entered [(⟨9⟩, "ghost")] == some (#[], ["no window 9"], #[none, none])) },
    { name :=
        "a mode set on a buffer by its number needs no window: it becomes the major mode, the lineage's on-enter actions run once with each view that shows the buffer and with none for a buffer no window shows, setting it again runs nothing, and a buffer there is none of is refused with noSuchBuffer and a mode no mode is registered under with noSuchMode"
      run :=
        pure
          (enteredBuffer [(1, "child")] ==
              some (#["root in 1", "base in 1", "child in 1"], [""], #[none, some "child", none]) &&
            enteredBuffer [(2, "listing"), (2, "listing")] ==
              some (#[], ["", ""], #[none, none, some "listing"]) &&
            enteredBuffer [(9, "listing")] == some (#[], ["no buffer 9"], #[none, none, none]) &&
            enteredBuffer [(2, "ghost")] == some (#[], ["no mode ghost"], #[none, none, none])) },
    { name :=
        "an on-enter action's own state requests are answered from the state the command had reached and kept with it: its message is in the echo area, and the minor mode it adds is the buffer's"
      run :=
        pure <|
          let loud : Mode :=
            { name := "loud"
              onEnter := fun view => do
                let state ← editorState
                let some target := state.target? view | throw .noSuchText
                -- The mode is the buffer's major mode by the time its
                -- action runs.
                EditorState.ask
                    (.message s!"{target.buffer.major.getD "none"} entered in {view.index}")
                discard <| EditorState.ask (.addMinorMode target.window.buffer "ringing") }
          let registry := enterRegistry.replaceModes .config #[loud]
          let program : EditorM EditorState := do
            return (← Loop.run (enterKeys registry) (← twoBuffers) (entersMode ⟨1⟩ "loud") []).state
          match (program.runModel editorModel).1 with
          | .ok state =>
            state.echo == "loud entered in 1" &&
              ((state.buffer? ⟨1⟩).map fun buffer => (buffer.major, buffer.minors)) ==
                some (some "loud", #["ringing"]) &&
              ((state.buffer? ⟨0⟩).map (·.minors)) == some #[]
          | .error _ => false },
    { name :=
        "a command that is refused after it set a major mode is rolled back, the mode and what its on-enter action did alike: the buffer has no major mode, the action's edit and its minor mode are gone, and the echo area says the refusal"
      run :=
        pure <|
          let stamping : Mode :=
            { name := "stamping"
              onEnter := fun view => do
                discard <| view.insertAtSelections "!"
                let some target := (← editorState).target? view | throw .noSuchText
                discard <| EditorState.ask (.addMinorMode target.window.buffer "stamped") }
          let keys := enterKeys (enterRegistry.replaceModes .config #[stamping])
          let program (command : String) : EditorM (EditorState × String) := do
            let ran ← Loop.run keys (← twoBuffers) (entersMode ⟨1⟩ "stamping" command) []
            return (ran.state, ← (⟨1⟩ : TextId).read)
          let modes (state : EditorState) :=
            (state.buffer? ⟨1⟩).map fun buffer => (buffer.major, buffer.minors)
          (match ((program "enter").runModel editorModel).1 with
            | .ok (state, text) =>
              text == "!other" && modes state == some (some "stamping", #["stamped"]) &&
                state.echo == ""
            | .error _ => false) &&
            match ((program "enter-fail").runModel editorModel).1 with
            | .ok (state, text) =>
              text == "other" && modes state == some (none, #[]) &&
                state.echo == "enter-fail: refused: bad range"
            | .error _ => false },
    { name :=
        "an on-enter action that is refused refuses the command at the request that set the mode, and the command cannot catch it: neither its handler nor what follows the request runs, the echo area says the refusal under the command's name, and the mode and the action's edit are rolled back"
      run :=
        pure <|
          let broken : Mode :=
            { name := "broken"
              onEnter := fun view => do
                discard <| view.insertAtSelections "!"
                let some target := (← editorState).target? view | throw .noSuchText
                target.buffer.text.delete 9 99 }
          -- What the command went on to do is seen in the texts it made,
          -- which no rollback takes back.
          let catching : Dispatched := fun call => do
            let [.nat view, .str name] := call.arguments | throw .badPosition
            try
              discard <| (⟨view⟩ : ViewId).setMajorMode name
            catch _ =>
              makes "caught"
            makes "went on"
            return none
          let keys : Loop.Keys TestScheme.scheme :=
            { command? := fun _ => some catching
              registered := (enterRegistry.replaceModes .config #[broken]).registered }
          let program : EditorM (EditorState × String) := do
            let ran ← Loop.run keys (← twoBuffers) (entersMode ⟨1⟩ "broken") []
            return (ran.state, ← (⟨1⟩ : TextId).read)
          match program.runModel editorModel with
          | (.ok (state, text), model) =>
            state.echo == "enter: refused: bad range" &&
              ((state.buffer? ⟨1⟩).map (·.major)) == some none &&
              text == "other" &&
              model.texts.contents == #["", "other"]
          | (.error _, _) => false },
    { name :=
        "an on-enter action is guarded with the command that set the mode: with the interrupt flag up its request of the store is not made, and the command is rolled back, so the mode is not the buffer's"
      run :=
        pure
          (entered [(⟨0⟩, "listing")] (watch := { arrived := 1 }) ==
            some (#[], ["enter: interrupted"], #[none, none])) }]

end ModelTest
