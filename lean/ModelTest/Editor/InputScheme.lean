import Editor.Event
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Loop
import Editor.Loop.Driver
import Editor.Package
import Editor.Scene
import Editor.Setup
import Editor.Test.Hosted
import Editor.Test.Keys
import Editor.Test.Models
import Editor.Text
import ModelTest.Check

/-!
# Model tests: `Editor/InputScheme.lean`

The model tests of `Editor/InputScheme.lean`: `schemeChecks`, and
`schemePackageChecks`, the scheme a package supplies. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The key strings the scheme fixtures are written with. -/
def schemeKeyStrings : List String :=
  ["C-x C-s", "C-x C-f", "C-x r t", "C-q", "C-x", "C-x r", "z", "a", "<Escape>", "C-z M-z s-z",
    "SPC"]

/-- The test scheme's initial state, at its own type: the scheme's `State`
is a field, and instance search does not see through it to the type's
decidable equality. -/
def schemeInit : TestScheme.State :=
  TestScheme.scheme.init

/-- The test scheme stepped from `state` through `typed`, keys for `view`:
the state it is left in, at its own type, and what each key yielded. -/
def typedFrom (view : ViewId) (state : TestScheme.State) (typed : List Key) :
    TestScheme.State × List (Option Invocation) :=
  TestScheme.scheme.feed schemeMaps view state typed

/-- `typedFrom` the test scheme's initial state. -/
def typedInto (view : ViewId) (typed : List Key) : TestScheme.State × List (Option Invocation) :=
  typedFrom view schemeInit typed

/-- `typedInto`, of the keys a key string names. -/
def fed (view : ViewId) (text : String) : TestScheme.State × List (Option Invocation) :=
  typedInto view (keys text)

/-- What the test scheme binds a key that holds only in the state `insert`
to, to run `x`, at its own type. -/
def schemeStateBinding : Invocation :=
  TestScheme.scheme.stateCommand ["insert"] "x"

/-- What the test scheme binds a key bound to the command name `x` to, at
its own type. -/
def schemeCommandBinding : Invocation :=
  TestScheme.scheme.command "x"

/-- The checks of input schemes (`Editor/InputScheme.lean`) on the test
scheme (`Editor/InputScheme/Test.lean`): what the keys of a bound sequence
yield, what an unbound key does, which keymap wins, the pending keys, and
the test scheme's self-insert. -/
def schemeChecks : List Check :=
  [{  name :=
        "the leaders in force are the scheme's leader and its localleader expanded over it, or the leader given in its place, with the localleader over that, or both given"
      run :=
        let scheme : InputScheme :=
          { TestScheme.scheme with localLeader := [.leader, .key (charKey "m")] }
        let backslash := [charKey "\\"]
        pure
          (scheme.leaders == { leader := keys "C-c", localLeader := keys "C-c m" } &&
            scheme.leaders (some backslash) ==
              { leader := backslash, localLeader := backslash ++ [charKey "m"] } &&
            scheme.leaders (some backslash) (some [.key (charKey "z")]) ==
              { leader := backslash, localLeader := [charKey "z"] } &&
            TestScheme.scheme.leaders == { leader := keys "C-c", localLeader := keys "C-c" }) },
    { name :=
        "a scheme that holds no binding to states of its own binds a key given states as it binds one to the command name"
      run := pure (schemeStateBinding == schemeCommandBinding) },
    { name := "every key string the scheme fixtures are written with names keys"
      run := pure (schemeKeyStrings.all fun text => !(keys text).isEmpty) },
    { name :=
        "the keys of a bound sequence stepped through the test scheme: the last yields the bound invocation and each earlier key yields none"
      run :=
        pure
          ((fed ⟨0⟩ "C-x C-s").2 == [none, some (invoke "save")] &&
            (fed ⟨0⟩ "C-x r t").2 == [none, none, some (invoke "string-rectangle")] &&
            (fed ⟨0⟩ "C-q").2 == [some (invoke "quit")]) },
    { name :=
        "an unbound key after a pending prefix yields no invocation and leaves the test scheme in its initial state"
      run :=
        let (state, yields) := fed ⟨0⟩ "C-x z"
        let (deeper, deeperYields) := fed ⟨0⟩ "C-x r z"
        pure
          (yields == [none, none] && decide (state = schemeInit) &&
            deeperYields == [none, none, none] &&
            decide (deeper = schemeInit)) },
    { name := "a bound sequence typed after an unbound key reset the prefix yields its invocation"
      run := pure ((fed ⟨0⟩ "C-x z C-x C-s").2 == [none, none, none, some (invoke "save")]) },
    { name :=
        "of two keymaps in a view's list that bind one sequence, the earlier's invocation is yielded"
      run :=
        pure
          ((fed ⟨1⟩ "C-x C-s").2 == [none, some (invoke "save-as")] &&
            (fed ⟨1⟩ "C-x C-f").2 == [none, some (invoke "find-file")]) },
    { name :=
        "a scheme is stepped with the keymaps of the view the key is for: another view's are not asked"
      run :=
        pure
          ((fed ⟨0⟩ "C-x C-s").2 == [none, some (invoke "save")] &&
            (fed ⟨2⟩ "C-x C-s").2 == [none, some (invoke "save")] &&
            (fed ⟨1⟩ "C-x C-s").2 != (fed ⟨0⟩ "C-x C-s").2) },
    { name :=
        "the test scheme reports a pending prefix as its pending keys, and none before a key and after the sequence completes"
      run :=
        let pendingAfter (text : String) : List Key := TestScheme.scheme.pending (fed ⟨0⟩ text).1
        pure
          (TestScheme.scheme.pending schemeInit == [] && pendingAfter "C-x" == keys "C-x" &&
            pendingAfter "C-x r" == keys "C-x r" &&
            pendingAfter "C-x C-s" == [] &&
            pendingAfter "C-x r t" == [] &&
            pendingAfter "C-x z" == []) },
    { name :=
        "the invocations the test scheme yields for one key sequence are equal, and those for sequences bound to different commands are unequal"
      run :=
        pure
          (decide ((fed ⟨0⟩ "C-x C-s").2 = (fed ⟨0⟩ "C-x C-s").2) &&
            decide ((fed ⟨0⟩ "C-x C-s").2 ≠ (fed ⟨0⟩ "C-x C-f").2) &&
            decide ((fed ⟨0⟩ "C-x C-s").2 ≠ (fed ⟨1⟩ "C-x C-s").2) &&
            decide ((fed ⟨0⟩ "a").2 = (fed ⟨0⟩ "a").2) &&
            decide ((fed ⟨0⟩ "a").2 ≠ (fed ⟨0⟩ "z").2)) },
    { name :=
        "an unbound printable key with nothing pending yields the test scheme's self-insert of its character and leaves nothing pending"
      run :=
        let typed : Key :=
          { logical := .character "A", physical := .code "KeyA", modifiers := { shift := true } }
        pure
          (fed ⟨0⟩ "a" == ({}, [some (TestScheme.selfInsert "a")]) &&
            (fed ⟨0⟩ "SPC").2 == [some (TestScheme.selfInsert " ")] &&
            (typedInto ⟨0⟩ [typed]).2 == [some (TestScheme.selfInsert "A")] &&
            (fed ⟨0⟩ "C-x z a").2 == [none, none, some (TestScheme.selfInsert "a")]) },
    { name :=
        "an unbound key that is not printable yields nothing: a named key, and a character with control, alt or super held"
      run :=
        pure
          (fed ⟨0⟩ "<Escape>" == ({}, [none]) &&
            fed ⟨0⟩ "C-z M-z s-z" == ({}, [none, none, none]) &&
            (typedInto ⟨0⟩ [{ logical := .dead (some '´') }, { logical := .unidentified }]).2 ==
              [none, none]) },
    { name :=
        "the test scheme takes a key by its chord: a key from a window, with its physical code and repeated, continues and completes a sequence"
      run :=
        let fromWindow (key : Key) (code : String) : Key :=
          { key with
            physical := .code code, repeated := true }
        let typed := [fromWindow (controlKey "x") "KeyX", fromWindow (controlKey "s") "KeyS"]
        pure
          ((typedInto ⟨0⟩ typed).2 == [none, some (invoke "save")] &&
            TestScheme.scheme.pending (typedInto ⟨0⟩ (typed.take 1)).1 == keys "C-x") },
    { name :=
        "feeding a scheme keys yields one entry a key, in order, and starts from the state it is given"
      run :=
        let (afterPrefix, first) := fed ⟨0⟩ "C-x"
        let (state, second) := typedFrom ⟨0⟩ afterPrefix (keys "C-s a")
        pure
          (first ++ second == (fed ⟨0⟩ "C-x C-s a").2 && decide (state = (fed ⟨0⟩ "C-x C-s a").1) &&
            fed ⟨0⟩ "" == ({}, [])) },
    { name :=
        "a scheme that says nothing of a closed view keeps its state as it was: the notice defaults to changing nothing"
      run :=
        let (pending, _) := fed ⟨0⟩ "C-x"
        let closed : TestScheme.State := TestScheme.scheme.closeView ⟨0⟩ pending
        pure (decide (closed = pending) && TestScheme.scheme.pending closed == keys "C-x") },
    { name :=
        "a scheme that says nothing of the minibuffer's view keeps its state as it was: the notice defaults to changing nothing"
      run :=
        let (pending, _) := fed ⟨0⟩ "C-x"
        let told : TestScheme.State := TestScheme.scheme.openMinibuffer ⟨1⟩ pending
        pure (decide (told = pending) && TestScheme.scheme.pending told == keys "C-x") },
    { name :=
        "a scheme that says nothing of a view reports the default: a bar in the face cursor, no status field, an exclusive selection, no selecting, no insert session, and a view that takes text; the test scheme reports it of every view, before a key, while keys are pending and after a sequence completes"
      run :=
        let plain : InputScheme.Report := {}
        let reported (text : String) (view : ViewId) : InputScheme.Report :=
          TestScheme.scheme.report (fed ⟨0⟩ text).1 view
        pure
          (plain ==
              { cursor := { shape := .bar, face := ⟨"cursor"⟩ }, status := #[], shape := .exclusive
                selecting := false, session := false, takesText := true } &&
            TestScheme.scheme.report schemeInit ⟨0⟩ == plain &&
            reported "C-x" ⟨0⟩ == plain &&
            reported "C-x" ⟨1⟩ == plain &&
            reported "C-x C-s" ⟨0⟩ == plain &&
            reported "a" ⟨0⟩ == plain) }]

/-- A scheme that says nothing of what can follow a pending prefix: the test
scheme's state and walk, with every field that has a default left out. -/
def silentScheme : InputScheme :=
  { State := TestScheme.State, Binding := Invocation, init := {}, step := TestScheme.step
    pending := (·.pending), command := fun name => { command := name } }

/-- The hints the test scheme gives for view 0 after the keys `text` name,
with `C-x r` named `rect`. -/
def schemeHints (text : String) : List KeyHint :=
  let names (typed : List Key) : Option String :=
    if typed == keys "C-x r" then some "rect" else none
  (TestScheme.scheme.continuations schemeMaps names ⟨0⟩ (fed ⟨0⟩ text).1).map (·.hint)

/-- The checks of what a scheme says can follow a pending prefix
(`InputScheme.continuations`) and of a continuation as a key hint
(`Keymap.Continuation.hint`), on the test scheme. -/
def schemeHintChecks : List Check :=
  [{  name := "a scheme that says nothing of what can follow a pending prefix lists nothing"
      run :=
        let state : TestScheme.State := { pending := keys "C-x" }
        pure (silentScheme.continuations schemeMaps (fun _ => none) ⟨0⟩ state).isEmpty },
    { name :=
        "the test scheme lists the keys that can follow its pending keys in the view's keymaps, and nothing at rest"
      run :=
        pure
          (schemeHints "C-x" ==
              [{ key := "C-s", leads := .binding none }, { key := "C-f", leads := .binding none },
                { key := "r", leads := .prefix (some "rect") 1 }] &&
            schemeHints "C-x r" == [{ key := "t", leads := .binding none }] &&
            schemeHints "" == [] &&
            schemeHints "C-x C-s" == []) },
    { name :=
        "a continuation as a key hint is its key's notation and what it leads to, without the binding: a binding's description, or a prefix's name and count"
      run :=
        let bound : Keymap.Continuation Invocation :=
          { key := controlKey "s", next := .bound (invoke "save") (some "Save") }
        let named : Keymap.Continuation Invocation :=
          { key := charKey " ", next := .prefix (some "file") 3 }
        pure
          (bound.hint == { key := "C-s", leads := .binding (some "Save") } &&
            named.hint == { key := "SPC", leads := .prefix (some "file") 3 }) }]

/-- What the hand-written scheme `letters` remembers: how many keys it has
been handed. It is the scheme's own state type, which no other scheme has. -/
structure LettersState where
  /-- The keys handed so far. -/
  seen : Nat := 0

/-- The hand-written scheme's own table: the key `x` runs the command
`greet`, and no other key is bound. -/
def lettersTable : List (Key × String) :=
  [(charKey "x", "greet")]

/-- An input scheme written here, by hand: its own state, a command's name
as its binding, and its own table in place of the keymaps it is handed. A
key of the table yields an invocation of its command, and every other key
nothing. -/
def letters : InputScheme :=
  { State := LettersState, Binding := String, init := {}
    step := fun _ _ state key =>
      ({ seen := state.seen + 1 },
        (lettersTable.find? (·.1 == key)).map fun (_, name) => { command := name })
    pending := fun _ => []
    command := id }

/-- A package written here: the command `greet`, which inserts `hello` at
the selections of the view it is called for. -/
def greetPackage : Package :=
  { name := "greeter"
    setup :=
      commandWith "greet" fun call => discard <| call.target.window.id.insertAtSelections "hello" }

/-- What the buffer of view 0 holds after each of `typed`, fed in order as
key presses to a driver of the scheme `supplied` gives over the initial
state, with what `greetPackage` registers, installed as a host installs it;
`none` if making the state was refused. -/
def greeted (supplied : SchemePackage) (typed : List Key) : Option (List (Option String)) :=
  let registry := hostedRegistry #[greetPackage]
  let keys : Loop.Keys supplied.scheme :=
    { command? := fun name =>
        (registry.find? name).bind fun entry =>
          match entry.registration.action with
          | .call run =>
            some fun call => do
              run call
              return none
          | _ => none
      registered := registry.registered }
  match Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) editorModel with
  | .error _ => none
  | .ok driver =>
    some
      (typed.foldl
          (fun (driver, texts) key =>
            let driver := (driver.feed { event := press key, stamp := 0 }).1
            (driver, texts ++ [driver.model.texts.contents[0]?]))
          (driver, [])).2

/-- The checks of the scheme a package supplies (`SchemePackage`,
`Editor/InputScheme.lean`): which of the supplied schemes an editor runs,
what it says when none is supplied, and the loop driven by a scheme written
here and supplied as a package's. -/
def schemePackageChecks : List Check :=
  [{  name :=
        "with no scheme package none is chosen, and the refusal says no input scheme is installed"
      run :=
        pure
          ((SchemePackage.chosen? #[]).isNone &&
            SchemePackage.noneInstalled ==
              "no input scheme is installed: no package of this editor's package set supplies one") },
    { name := "of two scheme packages the one supplied last is chosen"
      run :=
        let supplied : Array SchemePackage :=
          #[{ name := "first", scheme := TestScheme.scheme },
            { name := "letters", scheme := letters }]
        pure
          ((SchemePackage.chosen? supplied).map (·.name) == some "letters" &&
            (SchemePackage.chosen? supplied.reverse).map (·.name) == some "first") },
    { name := "a hand-written input scheme registered as a scheme package drives the loop"
      run :=
        pure <|
          match SchemePackage.chosen? #[{ name := "letters", scheme := letters }] with
          | none => false
          | some supplied =>
            supplied.name == "letters" &&
              greeted supplied [charKey "y", charKey "x", charKey "y"] ==
                some [some "", some "hello", some "hello"] }]

end ModelTest
