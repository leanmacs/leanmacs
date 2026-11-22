import Editor.Event
import Editor.InputScheme
import Editor.InputScheme.Contract
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Keymap
import Editor.Role
import Editor.Scene
import Editor.Test.Keys
import Editor.Text
import ModelTest.Check

/-!
# Model tests: `Editor/InputScheme/Contract.lean`

The model tests of `Editor/InputScheme/Contract.lean`: `schemeContractChecks`,
`continuationsContractChecks` and `keyBindingsContractChecks`, on the test
scheme and on schemes written here. The root module `ModelTest` runs them;
its module doc says what each shows. That the Vim scheme keeps the contract
is `vimContractChecks`, in `packages/evil/EvilTest/Vim/Contract.lean`.
-/

namespace ModelTest

open Editor
open Editor.Test
open Editor.SchemeContract (failsOnly)

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
    leader := TestScheme.leader
    localLeader := TestScheme.localLeader }

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
    leader := TestScheme.leader
    localLeader := TestScheme.localLeader }

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
    leader := TestScheme.leader
    localLeader := TestScheme.localLeader }

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
    leader := TestScheme.leader
    localLeader := TestScheme.localLeader }

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
    leader := TestScheme.leader
    localLeader := TestScheme.localLeader }

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
    leader := TestScheme.leader
    localLeader := TestScheme.localLeader }

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
    leader := TestScheme.leader
    localLeader := TestScheme.localLeader }

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
    localLeader := TestScheme.localLeader
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
    localLeader := TestScheme.localLeader
    report := fun state _ => { session := state.2 }
    invoked := fun _ state invocation => ((state.1, true), invocation) }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that it draws its cursor in `cursor.odd` while keys are pending, a
face it does not list. -/
def miscoloured : InputScheme :=
  { TestScheme.scheme with
    report := fun state _ =>
      if state.pending.isEmpty then {}
      else { cursor := { shape := .bar, face := ⟨"cursor.odd"⟩ } } }

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
        "the scheme contract reports a scheme with no localleader, and one with a role on keys that begin with the localleader or begin it, for the leader's property alone"
      run :=
        let localLeader : List Key.Stroke := [.key (controlKey "l")]
        let localKeys := [controlKey "l"]
        let quit := (TestScheme.scheme.roleKey Role.quit).getD []
        let underLocal :=
          TestScheme.roles.map fun (role, keys) =>
            if role == Role.quit then (role, localKeys ++ keys) else (role, keys)
        let beginsLocal :=
          TestScheme.roles.map fun (role, keys) =>
            if role == Role.quit then (role, localKeys) else (role, keys)
        let tables : List (List (Role × List Key) × List Key.Stroke) :=
          [(TestScheme.roles, []), (underLocal, localLeader),
            (beginsLocal, [.key (controlKey "l"), .key (charKey "x")])]
        pure
          (!quit.isEmpty &&
            tables.all fun (roles, localLeader) =>
              failsOnly
                (subjectOf
                  { TestScheme.scheme with
                    roles, localLeader }
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
            failsOnly (subjectOf menuStartled schemeMaps) [SchemeContract.invokedKeepsUnknown]) },
    { name :=
        "the scheme contract reports a scheme that draws a cursor in a face it does not list, for that property and the quiet key's alone, and keeps it once the scheme lists the face"
      run :=
        let listing : InputScheme := { miscoloured with cursorFaces := [⟨"cursor.odd"⟩] }
        pure
          (failsOnly (subjectOf miscoloured schemeMaps)
              [SchemeContract.quietKeyKeepsReport, SchemeContract.cursorFacesReported] &&
            failsOnly (subjectOf listing schemeMaps) [SchemeContract.quietKeyKeepsReport]) }]

/-- A scheme written for the test that breaks the contract: the test scheme,
except that after a pending prefix it also lists `z`, which the walk does
not continue, as leading to a prefix. -/
def overpromising : InputScheme :=
  { TestScheme.scheme with
    continuations := fun maps names view (state : TestScheme.State) =>
      if state.pending.isEmpty then []
      else Keymap.continuations (maps view) state.pending names ++ [⟨charKey "z", .prefix none 1⟩] }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that it lists the keys that can follow even when nothing is
pending. -/
def restless : InputScheme :=
  { TestScheme.scheme with
    continuations := fun maps names view (state : TestScheme.State) =>
      Keymap.continuations (maps view) state.pending names }

/-- The checks of the scheme contract's property of what can follow a
pending prefix (`SchemeContract.continuationsWalk`). -/
def continuationsContractChecks : List Check :=
  [{  name :=
        "the scheme contract reports a scheme that lists, after a pending prefix, a key as leading to a prefix that the walk does not continue, for that property alone"
      run :=
        pure (failsOnly (subjectOf overpromising schemeMaps) [SchemeContract.continuationsWalk]) },
    { name :=
        "the scheme contract reports a scheme that lists keys that can follow when nothing is pending, for that property alone"
      run := pure (failsOnly (subjectOf restless schemeMaps) [SchemeContract.continuationsWalk]) },
    { name :=
        "the test scheme lists a key that leads to a prefix after a pending prefix, so the contract's property of what can follow has something to hold of"
      run :=
        let subject := subjectOf TestScheme.scheme schemeMaps
        let state := (subject.feed (keys "C-x")).1
        pure
          ((subject.scheme.continuations subject.maps (fun _ => none) subject.view state).any
            fun c =>
            match c.next with
            | .prefix .. => true
            | .bound .. => false) }]

/-- A scheme written for the test that breaks the contract: the test scheme,
except that it lists `q q`, which no keymap binds, as a key binding. -/
def misreporting : InputScheme :=
  { TestScheme.scheme with keyBindings := fun _ _ _ => [{ keys := keys "q q", command := "x" }] }

/-- The checks of the scheme contract's property of the key bindings a
scheme lists (`SchemeContract.keyBindingsWalk`). -/
def keyBindingsContractChecks : List Check :=
  [{  name :=
        "the scheme contract reports a scheme that lists a key binding its walk does not complete, for that property alone"
      run :=
        pure (failsOnly (subjectOf misreporting schemeMaps) [SchemeContract.keyBindingsWalk]) },
    { name :=
        "the test scheme lists the key bindings of its keymaps, so the contract's property of them has something to hold of"
      run :=
        let subject := subjectOf TestScheme.scheme schemeMaps
        pure
          ((subject.scheme.keyBindings subject.maps subject.view subject.scheme.init).map
              (fun b => (b.keys, b.command)) ==
            [(keys "C-x C-s", "save"), (keys "C-x C-f", "find-file"),
              (keys "C-x r t", "string-rectangle"), (keys "C-q", "quit")]) }]

end ModelTest
