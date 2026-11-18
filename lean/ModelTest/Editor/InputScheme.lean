import Editor.Event
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Scene
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Keys

/-!
# Model tests: `Editor/InputScheme.lean`

The model tests of `Editor/InputScheme.lean`: `schemeChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

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

/-- The checks of input schemes (`Editor/InputScheme.lean`) on the test
scheme (`Editor/InputScheme/Test.lean`): what the keys of a bound sequence
yield, what an unbound key does, which keymap wins, the pending keys, and
the test scheme's self-insert. -/
def schemeChecks : List Check :=
  [{  name := "every key string the scheme fixtures are written with names keys"
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

end ModelTest
