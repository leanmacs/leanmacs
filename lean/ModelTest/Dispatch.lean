import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Display.Model
import Editor.Ex.Line
import Editor.Face
import Editor.Floating
import Editor.InputScheme.Test
import Editor.Key.Notation
import Editor.Language
import Editor.Layout
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.TabBar
import Editor.Watch.Model
import ModelTest.Layout

/-!
# Model tests: keys and dispatch

The checks of commits, keymaps, key notation, invocations, the ex line,
input schemes and dispatch.

Its lists of checks: `commitChecks`, `keymapChecks`, `keyNotationChecks`,
`invocationChecks`, `exLineChecks`, `schemeChecks`, `dispatchKeyChecks`,
`dispatchRollbackChecks`, `dispatchInterruptChecks`, `dispatchSlowChecks`,
`twoWindowChecks`, `dispatchStateChecks`, `dispatchGiveUpChecks`,
`dispatchCloseViewChecks`, `dispatchMinibufferNoticeChecks`,
`dispatchUndoChecks`, `dispatchReportChecks`,
`dispatchCommandGivesUpChecks`, `dispatchCommandBreaksOffChecks`,
`dispatchRunCommandChecks`, `dispatchChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- The focused window's buffer and window in `loop`'s state, or a refusal
for a state with none. -/
def focusedOf (loop : TestLoop) : EditorM Target := do
  let some target := loop.state.focusedTarget? | throw .noSuchText
  return target

/-- The ranges of the focused window's selection marker in `loop`'s state. -/
def cursorsOf (loop : TestLoop) : EditorM (Array SelectionRange) := do
  let target ← focusedOf loop
  let .selection selection ← target.buffer.text.marker target.window.selection | throw .noSuchMarker
  return selection.ranges

/-- The initial state at 640 by 480, its buffer holding `text`, and the
focused window's selection placed at `ranges`, exclusive. -/
def holding (text : String) (ranges : Array SelectionRange) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let some target := state.focusedTarget? | throw .noSuchText
  target.buffer.text.insert 0 text
  target.buffer.text.place target.window.selection (.selection { ranges })
  return state

/-- A scheme written for the commit checks: the test scheme, which keeps
what it is told was committed, the newest first, and says of every view
that it takes text or that it takes none, as `takesText` says. -/
def telling (takesText : Bool) : InputScheme :=
  { State := TestScheme.State × List (ViewId × String)
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, state.2), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    committed := fun view text state => (state.1, (view, text) :: state.2)
    report := fun _ _ => { takesText } }

/-- The checks of a text commit in the loop, on the editor's models. -/
def commitChecks : List Check :=
  [{  name :=
        "commits of a, b and c publish one scene each, whose focused view shows the text so far, with the window's cursor just after what was committed"
      run :=
        pure <|
          let program : EditorM (Array (SnapshotId × String × Array SelectionRange)) := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            let mut seen := #[]
            for text in ["a", "b", "c"] do
              loop := (← stepped loop (.commit text)).1
              let some shown := loop.shown[0]? | throw .noSuchSnapshot
              seen := seen.push (shown.snapshot, ← shown.snapshot.read, ← cursorsOf loop)
            return seen
          match program.runModel editorModel with
          | (.ok seen, model) =>
            let scenes := model.display.scenes
            seen.map (·.2) == #[("a", #[⟨1, 1⟩]), ("ab", #[⟨2, 2⟩]), ("abc", #[⟨3, 3⟩])] &&
              scenes.size == 3 &&
              (scenes.zip seen).all fun (scene, (snapshot, _)) =>
                scene.focused == some ⟨0⟩ &&
                  (scene.views.find? (·.id == ⟨0⟩)).map (·.snapshot) == some snapshot
          | (.error _, _) => false },
    { name :=
        "after a commit, one undo of the buffer's history, as the loop left it, restores the text from before the commit, and the commit was the user's"
      run :=
        pure <|
          let program : EditorM (String × String × String × Array Attribution) := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            loop := (← stepped loop (.commit "hello")).1
            loop := (← stepped loop (.commit " world")).1
            let target ← focusedOf loop
            let before ← target.buffer.text.read
            let some moved ← target.buffer.history.undo | throw .noInverse
            let once ← target.buffer.text.read
            let trace ← target.buffer.text.trace 0 5
            let some _ ← moved.tree.undo | throw .noInverse
            return (before, once, ← target.buffer.text.read, trace)
          match (program.runModel editorModel).1 with
          | .ok (before, once, twice, trace) =>
            before == "hello world" && once == "hello" && twice == "" &&
              trace == #[{ start := 0, stop := 5, author := .entry 1 Origin.user }]
          | .error _ => false },
    { name :=
        "a commit replaces what each range of the selection covers, and leaves a cursor after each insertion"
      run :=
        pure <|
          let program : EditorM (String × Array SelectionRange) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨0, 1⟩, ⟨3, 3⟩] }
            let (loop, _) ← stepped loop (.commit "xy")
            return (← (← focusedOf loop).buffer.text.read, ← cursorsOf loop)
          match (program.runModel editorModel).1 with
          | .ok (text, cursors) => text == "xybcxyd" && cursors == #[⟨2, 2⟩, ⟨6, 6⟩]
          | .error _ => false },
    { name :=
        "a commit whose selection marker was given up leaves the state as it was, with the refusal in the echo area"
      run :=
        pure <|
          let program : EditorM (EditorState × TestLoop × Option String) := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some target := state.focusedTarget? | throw .noSuchText
            target.buffer.text.unmark target.window.selection
            let (loop, _) ← stepped { state } (.commit "x")
            return (state, loop, ← target.buffer.text.read)
          match program.runModel editorModel with
          | (.ok (state, loop, text), model) =>
            loop.state ==
                { state with
                  echo := "refused: no such marker",
                  heights := editorModel.display.cells.heights } &&
              text == "" &&
              (model.display.scenes.map (·.echo)) == #["refused: no such marker"]
          | (.error _, _) => false },
    { name :=
        "after a commit the snapshot the previous scene named is released, and asking it is refused with noSuchSnapshot"
      run :=
        pure <|
          let program : EditorM (SnapshotId × SnapshotId × Bool) := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            loop := (← stepped loop (.commit "a")).1
            let some first := loop.shown[0]? | throw .noSuchSnapshot
            loop := (← stepped loop (.commit "b")).1
            let some second := loop.shown[0]? | throw .noSuchSnapshot
            let refused ←
              try
                discard first.snapshot.read
                pure false
              catch refusal =>
                pure (refusal == .noSuchSnapshot)
            return (first.snapshot, second.snapshot, refused)
          match (program.runModel editorModel).1 with
          | .ok (first, second, refused) => first != second && refused
          | .error _ => false },
    { name := "a commit clears the preedit"
      run :=
        pure <|
          match looped (EditorState.initial ⟨640, 480⟩) [.preedit "k", .commit "か"] with
          | some ((loop, _), scenes, _) =>
            scenes.map (·.preedit) == #[some "k", none] && loop.state.preedit == none
          | none => false },
    { name :=
        "a text committed where the scheme reports that the focused view takes no text is not inserted: the text and the selection are as they were, and the preedit is cleared all the same"
      run :=
        pure <|
          match switched (holding "abcd" #[⟨1, 3⟩]) "C-d" [.preedit "ka", .commit "x"] with
          | some (loop, scenes, model) =>
            let selection :=
              loop.state.focusedTarget?.bind fun target =>
                (target.selection.runModel model.texts).1.toOption
            model.texts.contents == #["abcd"] && selection.map (·.ranges) == some #[⟨1, 3⟩] &&
              loop.state.preedit == none &&
              scenes.map (·.preedit) == #[none, some "ka", none]
          | none => false },
    { name :=
        "once the scheme reports that the focused view takes text again, a committed text replaces what the selection covers, as under a scheme that says nothing"
      run :=
        pure <|
          let events : List Event :=
            [.commit "x"] ++ (keys "C-p").map (Event.key · true "") ++ [.commit "y"]
          match switched (holding "abcd" #[⟨1, 3⟩]) "C-d" events with
          | some (_, _, model) => model.texts.contents == #["ayd"]
          | none => false },
    { name :=
        "the loop tells the scheme of a committed text it inserted, for the focused view, in both states of the scheme it keeps; a commit that is dropped, where the scheme says the view takes no text, is not told; and the test scheme's notice changes nothing"
      run :=
        pure <|
          let told (takesText : Bool) :
            Option (List (ViewId × String) × List (ViewId × String) × Array String) :=
            let program : EditorM (Loop (telling takesText)) := do
              let mut loop ← Loop.start (telling takesText) ⟨640, 480⟩
              for event in [Event.commit "ab", .preedit "k", .commit "c"] do
                loop := (← loop.step {} event).loop
              return loop
            match program.runModel editorModel with
            | (.ok loop, model) =>
              let input : TestScheme.State × List (ViewId × String) := loop.input
              let atRest : TestScheme.State × List (ViewId × String) := loop.atRest
              some (input.2, atRest.2, model.texts.contents)
            | (.error _, _) => none
          told true == some ([(⟨0⟩, "c"), (⟨0⟩, "ab")], [(⟨0⟩, "c"), (⟨0⟩, "ab")], #["abc"]) &&
            told false == some ([], [], #[""]) &&
            (TestScheme.scheme.pending
                (TestScheme.scheme.committed ⟨0⟩ "x" TestScheme.scheme.init)).isEmpty }]

/-- The key of the character `text`, with `modifiers` held, as a binding
names it. -/
def charKey (text : String) (modifiers : Modifiers := {}) : Key :=
  { logical := .character text, modifiers }

/-- The named key `key`, with `modifiers` held, as a binding names it. -/
def namedKey (key : NamedKey) (modifiers : Modifiers := {}) : Key :=
  { logical := .named key, modifiers }

/-- The character `text` with control held: `C-x` for `"x"`. -/
def controlKey (text : String) : Key :=
  charKey text { control := true }

/-- The checks of a keymap (`Editor/Keymap.lean`): what a sequence is bound
to, which sequences a binding begins with, and the form of a key a binding
names. -/
def keymapChecks : List Check :=
  let save : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "s"] 1
  let other : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "s"] 2
  let find : Keymap Nat := Keymap.empty.bind [charKey "f"] 3
  let long : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "r", charKey "t"] 4
  let prefixBound : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "r"] 5
  [{  name := "a key sequence bound in a keymap is found, bound to what it was given"
      run := pure (save.find? [controlKey "x", controlKey "s"] == some 1) },
    { name :=
        "a strict prefix of a bound sequence is not found, and a binding begins with it; a binding begins with the bound sequence too"
      run :=
        pure
          (save.find? [controlKey "x"] == none && save.continues [controlKey "x"] &&
            save.continues [controlKey "x", controlKey "s"]) },
    { name :=
        "a sequence no binding begins with is not found and nothing begins with it: another key, a bound sequence's second key, and a bound sequence with a key after it"
      run :=
        pure <|
          [[charKey "x"], [controlKey "s"], [controlKey "x", controlKey "x"],
                [controlKey "x", controlKey "s", controlKey "s"]].all
            fun keys => save.find? keys == none && !save.continues keys },
    { name := "binding a sequence a second time replaces what it was bound to"
      run :=
        let again := save.bind [controlKey "x", controlKey "s"] 2
        pure
          (again.find? [controlKey "x", controlKey "s"] == some 2 && again.bindings.length == 1) },
    { name := "a keymap made from a list binds each sequence, a later entry replacing an earlier"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofList [([charKey "a"], 1), ([charKey "b"], 2), ([charKey "a"], 3)]
        pure
          (keymap.find? [charKey "a"] == some 3 && keymap.find? [charKey "b"] == some 2 &&
            keymap.bindings.length == 2) },
    { name := "the empty sequence binds nothing"
      run :=
        let keymap : Keymap Nat := Keymap.empty.bind [] 1
        pure (keymap.bindings.isEmpty && keymap.find? [] == none && !keymap.continues []) },
    { name :=
        "a key from a window finds a binding by its chord: its physical code, whether it was repeated, and shift on a character are not part of it"
      run :=
        let typed : Key :=
          { logical := .character "A"
            physical := .code "KeyA"
            modifiers := { shift := true }
            repeated := true }
        let written : Keymap Nat := Keymap.empty.bind [charKey "A"] 1
        let fromWindow : Keymap Nat := Keymap.empty.bind [typed] 1
        pure
          (typed.chord == charKey "A" && written.find? [typed.chord] == some 1 &&
            fromWindow.find? [charKey "A"] == some 1 &&
            (controlKey "x").chord == controlKey "x") },
    { name :=
        "shift on a named key is part of its chord: the shifted key does not find the unshifted key's binding"
      run :=
        let shifted : Key :=
          { logical := .named .tab, physical := .code "Tab", modifiers := { shift := true } }
        let keymap : Keymap Nat := Keymap.empty.bind [namedKey .tab] 1
        pure
          (shifted.chord == namedKey .tab { shift := true } &&
            keymap.find? [shifted.chord] == none &&
            keymap.find? [namedKey .tab] == some 1 &&
            (keymap.bind [shifted] 2).find? [shifted.chord] == some 2) },
    { name := "of two keymaps that bind one sequence, the earlier in the list gives its binding"
      run :=
        pure
          (Keymap.resolve [other, save] [controlKey "x", controlKey "s"] == .bound 2 &&
            Keymap.resolve [save, other] [controlKey "x", controlKey "s"] == .bound 1) },
    { name :=
        "a sequence that begins a binding is pending, whichever keymap of the list the binding is in, and one that begins none is unbound"
      run :=
        pure
          (Keymap.resolve [save, find] [controlKey "x"] == .pending &&
            Keymap.resolve [save, long] [controlKey "x", controlKey "r"] == .pending &&
            Keymap.resolve [save, long] [controlKey "x", controlKey "q"] == .unbound &&
            Keymap.resolve ([] : List (Keymap Nat)) [controlKey "x"] == .unbound) },
    { name :=
        "a sequence a later keymap binds is bound although an earlier keymap has a longer binding that begins with it"
      run :=
        pure (Keymap.resolve [long, prefixBound] [controlKey "x", controlKey "r"] == .bound 5) },
    { name := "the walk given a key that begins a binding keeps it pending and yields nothing"
      run :=
        let (first, firstBound) := Keymap.walk [long] [] (controlKey "x")
        let (second, secondBound) := Keymap.walk [long] first (controlKey "r")
        pure
          (first == [controlKey "x"] && firstBound == none &&
            second == [controlKey "x", controlKey "r"] &&
            secondBound == none) },
    { name :=
        "the walk given the last key of a bound sequence yields its binding and leaves nothing pending"
      run :=
        pure
          (Keymap.walk [save] [controlKey "x"] (controlKey "s") == ([], some 1) &&
            Keymap.walk [find] [] (charKey "f") == ([], some 3)) },
    { name :=
        "the walk given an unbound key after a pending prefix yields nothing and leaves nothing pending"
      run :=
        pure
          (Keymap.walk [save] [controlKey "x"] (charKey "z") == ([], none) &&
            Keymap.walk [save] [] (charKey "z") == ([], none)) },
    { name := "the walk takes a key by its chord"
      run :=
        let typed : Key :=
          { logical := .character "s"
            physical := .code "KeyS"
            modifiers := { control := true }
            repeated := true }
        pure
          (Keymap.walk [save] [controlKey "x"] typed == ([], some 1) &&
            Keymap.walk [save] [] { controlKey "x" with physical := .code "KeyX" } ==
              ([controlKey "x"], none)) },
    { name :=
        "filtering a keymap keeps exactly the bindings whose binding is kept, in order, and what it binds is found by find? and continues"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofList
            [([charKey "a"], 1), ([controlKey "x", charKey "b"], 2), ([charKey "c"], 3),
              ([controlKey "x", charKey "d"], 4)]
        let odd := keymap.filter (· % 2 == 1)
        pure
          (odd.bindings == [([charKey "a"], 1), ([charKey "c"], 3)] &&
            odd.find? [charKey "c"] == some 3 &&
            odd.find? [controlKey "x", charKey "b"] == none &&
            !odd.continues [controlKey "x"] &&
            (keymap.filter (· > 3)).continues [controlKey "x"] &&
            (keymap.filter fun _ => true).bindings == keymap.bindings) },
    { name :=
        "keysFor gives the sequences bound to the bindings a predicate keeps, in the order each was last bound, and a sequence rebound to another binding is not among them"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofList
            [([charKey "a"], 1), ([charKey "b"], 2), ([controlKey "x", charKey "c"], 1),
              ([charKey "d"], 1), ([charKey "a"], 1), ([charKey "d"], 2)]
        pure
          (keymap.keysFor (· == 1) == [[controlKey "x", charKey "c"], [charKey "a"]] &&
            keymap.keysFor (· == 2) == [[charKey "b"], [charKey "d"]] &&
            keymap.keysFor (· == 3) == []) },
    { name :=
        "the walk over specific keymaps and defaults: a specific prefix shadows a default binding of the same keys, so C-w is pending where the specific maps bind C-w h and the defaults bind C-w alone, and h then gives the specific binding"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [controlKey "w", charKey "h"] 1
        let defaults : Keymap Nat := Keymap.empty.bind [controlKey "w"] 2
        let (first, firstBound) := Keymap.walkOver [specific] [defaults] [] (controlKey "w")
        pure
          (first == [controlKey "w"] && firstBound == none &&
            Keymap.walkOver [specific] [defaults] first (charKey "h") == ([], some 1) &&
            Keymap.walkOver [] [defaults] [] (controlKey "w") == ([], some 2)) },
    { name :=
        "the walk over specific keymaps and defaults gives the specific binding of a sequence both bind exactly, and the default binding of one the specific maps leave unbound"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [charKey "x"] 1
        let defaults : Keymap Nat := (Keymap.empty.bind [charKey "x"] 2).bind [charKey "b"] 3
        pure
          (Keymap.walkOver [specific] [defaults] [] (charKey "x") == ([], some 1) &&
            Keymap.walkOver [specific] [defaults] [] (charKey "b") == ([], some 3)) },
    { name :=
        "the walk over specific keymaps and defaults merges prefixes: with g r specific and g g default, g is pending, then g g gives the default and g r the specific binding"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [charKey "g", charKey "r"] 1
        let defaults : Keymap Nat := Keymap.empty.bind [charKey "g", charKey "g"] 2
        let (pending, bound) := Keymap.walkOver [specific] [defaults] [] (charKey "g")
        pure
          (pending == [charKey "g"] && bound == none &&
            Keymap.walkOver [specific] [defaults] pending (charKey "g") == ([], some 2) &&
            Keymap.walkOver [specific] [defaults] pending (charKey "r") == ([], some 1)) },
    { name :=
        "the walk over specific keymaps and defaults resets on a sequence neither binds nor begins: alone, after a specific prefix, and after a prefix of both"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [controlKey "w", charKey "h"] 1
        let defaults : Keymap Nat :=
          (Keymap.empty.bind [controlKey "w"] 2).bind [charKey "g", charKey "g"] 3
        pure
          (Keymap.walkOver [specific] [defaults] [] (charKey "z") == ([], none) &&
            Keymap.walkOver [specific] [defaults] [controlKey "w"] (charKey "x") == ([], none) &&
            Keymap.walkOver [specific] [defaults] [charKey "g"] (charKey "q") == ([], none)) }]

/-- Whether `text` is a key string that names exactly `keys`. -/
def parses (text : String) (keys : List Key) : Bool :=
  match Key.parse text with
  | .ok named => named == keys
  | .error _ => false

/-- Whether `text` is refused as a key string, with a reason that names
`token`. -/
def refusesKey (text token : String) : Bool :=
  match Key.parse text with
  | .ok _ => false
  | .error reason => (reason.splitOn token).length > 1

/-- The checks of key strings (`Editor/Key/Notation.lean`): the keys a
string names, the strings that are refused, and that a chord's notation
names it. -/
def keyNotationChecks : List Check :=
  [{  name := "a key string names its strokes in order, each with the modifiers written before it"
      run := pure (parses "C-x C-s" [controlKey "x", controlKey "s"]) },
    { name :=
        "a stroke of one character is that character, whatever it is: a capital, the minus sign, an angle bracket"
      run :=
        pure
          (parses "A" [charKey "A"] && parses "-" [charKey "-"] && parses "C--" [controlKey "-"] &&
            parses "<" [charKey "<"] &&
            parses "x - >" [charKey "x", charKey "-", charKey ">"]) },
    { name := "a name in angle brackets is the named key of that name"
      run :=
        pure
          (parses "<Escape>" [namedKey .escape] && parses "<ArrowLeft>" [namedKey .arrowLeft] &&
            parses "<F5>" [namedKey ⟨"F5"⟩]) },
    { name := "RET, ESC and TAB are Enter, Escape and Tab, and SPC is the space character"
      run :=
        pure
          (parses "RET ESC TAB SPC"
            [namedKey .enter, namedKey .escape, namedKey .tab, charKey " "]) },
    { name :=
        "each modifier prefix holds its modifier: C- control, M- alt, s- super, and S- shift on a named key"
      run :=
        pure
          (parses "M-s-<ArrowLeft>" [namedKey .arrowLeft { alt := true, superKey := true }] &&
            parses "S-<Tab>" [namedKey .tab { shift := true }] &&
            parses "S-TAB" [namedKey .tab { shift := true }] &&
            parses "C-M-x" [charKey "x" { control := true, alt := true }] &&
            parses "s-s" [charKey "s" { superKey := true }]) },
    { name := "the empty string names no keys, and spaces around strokes name none"
      run :=
        pure
          (parses "" [] && parses "   " [] &&
            parses " C-x  C-s " [controlKey "x", controlKey "s"]) },
    { name :=
        "a string with a stroke that is not a key is refused, naming the stroke: shift on a character, a modifier with no key, two characters, a name that is not closed, an empty name"
      run :=
        pure
          (refusesKey "S-a" "S-a" && refusesKey "x C-" "C-" && refusesKey "C-x xy" "xy" &&
            refusesKey "<Escape" "<Escape" &&
            refusesKey "<>" "<>" &&
            refusesKey "S-SPC" "S-SPC") },
    { name :=
        "a name in angle brackets that is not letters and digits is refused, naming the stroke: a modifier prefix inside the brackets, an underscore"
      run := pure (refusesKey "<C-x>" "<C-x>" && refusesKey "x <a_b>" "<a_b>") },
    { name :=
        "a letter that is no modifier's is not a prefix: the stroke it begins is refused, naming it, and it is the minus key's stroke that stays a key"
      run :=
        pure
          (refusesKey "X-a" "X-a" && refusesKey "C-X-a" "C-X-a" && refusesKey "c-x" "c-x" &&
            parses "C-- X" [controlKey "-", charKey "X"]) },
    { name := "the keys a key string names are chords"
      run :=
        pure <|
          ["C-x C-s", "A", "S-<Tab>", "M-s-<ArrowLeft>", "RET SPC"].all fun text =>
            match Key.parse text with
            | .ok keys => keys.map Key.chord == keys
            | .error _ => false },
    { name := "a key's notation is its modifiers, then the character or the name in angle brackets"
      run :=
        pure
          (Key.notation (controlKey "x") == "C-x" && Key.notation (charKey "A") == "A" &&
            Key.notation (charKey " ") == "SPC" &&
            Key.notation (namedKey .enter) == "<Enter>" &&
            Key.notation
                (namedKey .arrowLeft
                  { shift := true, control := true, alt := true, superKey := true }) ==
              "C-M-s-S-<ArrowLeft>" &&
            Key.notation { logical := .dead none } == "<Dead>" &&
            Key.notation { logical := .unidentified } == "<Unidentified>" &&
            Key.notations [controlKey "x", controlKey "s"] == "C-x C-s" &&
            Key.notations [] == "") },
    { name := "the notation of chords of characters and named keys names those chords"
      run :=
        pure <|
          [[controlKey "x", controlKey "s"], [charKey "A"], [charKey "-"], [controlKey "-"],
                [charKey "<"], [charKey " ", charKey "s" { superKey := true }],
                [namedKey .escape, namedKey .enter, namedKey .tab { shift := true }],
                [namedKey .arrowLeft { control := true, alt := true, superKey := true }],
                [charKey "é" { alt := true }], []].all
            fun keys => parses (Key.notations keys) keys }]

/-- The checks of invocations (`Editor/Invocation.lean`): two can be
compared, by their command names and their arguments. -/
def invocationChecks : List Check :=
  let save : Invocation := { command := "save" }
  let insert (text : String) : Invocation := { command := "self-insert", arguments := [.str text] }
  [{  name := "two invocations of one command with the same arguments are equal"
      run :=
        pure
          (decide (save = { command := "save" }) && decide (insert "a" = insert "a") &&
            decide
              (({ command := "move", arguments := [.nat 2, .int (-1), .bool true] } : Invocation) =
                { command := "move", arguments := [.nat 2, .int (-1), .bool true] })) },
    { name := "invocations of commands with different names are unequal"
      run := pure (decide (save ≠ { command := "quit" })) },
    { name :=
        "invocations of one command are unequal when an argument differs: in its value, in its kind, in how many there are, or in their order"
      run :=
        pure
          (decide (insert "a" ≠ insert "b") &&
            decide
              (({ command := "move", arguments := [.nat 1] } : Invocation) ≠
                { command := "move", arguments := [.int 1] }) &&
            decide (save ≠ { command := "save", arguments := [.bool false] }) &&
            decide
              (({ command := "move", arguments := [.nat 1, .nat 2] } : Invocation) ≠
                { command := "move", arguments := [.nat 2, .nat 1] })) }]

/-- The checks of an ex line (`Editor/Ex/Line.lean`): what a line typed on
the ex command line parses to, and the invocation an ex binding makes of a
line's argument. -/
def exLineChecks : List Check :=
  let parsed (line : String) : Option (String × Option String) :=
    (Ex.parse line).map fun parsed => (parsed.name, parsed.argument)
  [{  name := "an ex line of one word is that name, with no argument"
      run := pure (parsed "w" == some ("w", none)) },
    { name := "an ex line of a word and more is the word as its name and the rest as its argument"
      run := pure (parsed "e notes.txt" == some ("e", some "notes.txt")) },
    { name :=
        "white space round an ex line and after its name is dropped, and the argument is kept whole, the spaces inside it included"
      run := pure (parsed "  e   /tmp/my notes.txt  " == some ("e", some "/tmp/my notes.txt")) },
    { name := "a tab separates an ex name from its argument as a space does"
      run := pure (parsed "e\tnotes.txt" == some ("e", some "notes.txt")) },
    { name := "an ex name may hold a hyphen, and its argument a digit"
      run := pure (parsed "greet-all 2" == some ("greet-all", some "2")) },
    { name :=
        "an ex name is everything up to the first white space: a mark after letters is part of the name, and so is a leading colon"
      run := pure (parsed "w!" == some ("w!", none) && parsed ":w" == some (":w", none)) },
    { name := "the empty line and a line of white space are no ex line"
      run := pure (parsed "" == none && parsed "  \t " == none) },
    { name :=
        "an ex binding that takes nothing gives its command with no arguments for a line with no argument, and nothing for a line with one"
      run :=
        let binding : Ex.Binding := { name := "w", command := "write" }
        pure
          (binding.invocation? none == some { command := "write" } &&
            binding.invocation? (some "notes.txt") == none) },
    { name :=
        "an ex binding that takes text gives its command with the line's argument as its first argument, a string, and its command with no arguments for a line with none"
      run :=
        let binding : Ex.Binding := { name := "e", command := "edit", takes := .text }
        pure
          (binding.invocation? (some "my notes.txt") ==
              some { command := "edit", arguments := [.str "my notes.txt"] } &&
            binding.invocation? none == some { command := "edit" }) },
    { name :=
        "an ex binding's own arguments come before the line's, with an argument and without; one that takes nothing still refuses an argument"
      run :=
        let forced : Ex.Binding :=
          { name := "e!", command := "edit", takes := .text, arguments := [.bool true] }
        let write : Ex.Binding := { name := "w!", command := "write", arguments := [.bool true] }
        pure
          (forced.invocation? (some "a b") ==
              some { command := "edit", arguments := [.bool true, .str "a b"] } &&
            forced.invocation? none == some { command := "edit", arguments := [.bool true] } &&
            write.invocation? none == some { command := "write", arguments := [.bool true] } &&
            write.invocation? (some "x") == none &&
            (Ex.parse "e! /tmp/a").map (·.name) == some "e!") },
    { name :=
        "criterion 1: an ex line whose first non-blank after its range is `!` is the bang form, named `!`, with the rest as its argument: `!echo hi` has no range, `%!sort` the range 1,$, `.,$!sort` the range .,$ and `3,5!sort` the range 3,5; `w!` is still the name `w!`, with no range and no bang"
      run :=
        let shell (range : Option Ex.Range) (argument : String) : Option Ex.Line :=
          some { name := "!", argument := some argument, range, bang := true }
        pure
          (Ex.parse "!echo hi" == shell none "echo hi" &&
            Ex.parse "%!sort" == shell (some { start := .line 1, stop := .last }) "sort" &&
            Ex.parse ".,$!sort" == shell (some { start := .current, stop := .last }) "sort" &&
            Ex.parse "3,5!sort" == shell (some { start := .line 3, stop := .line 5 }) "sort" &&
            Ex.parse "w!" == some { name := "w!" }) },
    { name :=
        "a range of one address is that line to itself, an address left out beside the comma is the cursor's line, spaces may stand between the range, the `!` and the command, `!` alone is the bang form with no argument, line 0 and a range that runs backwards still parse, and a range before a name is kept with the name"
      run :=
        pure
          (Ex.parse "3!sort" ==
              some
                { name := "!", argument := some "sort",
                  range := some { start := .line 3, stop := .line 3 }
                  bang := true } &&
            Ex.parse "  % !  sort -r " ==
              some
                { name := "!", argument := some "sort -r"
                  range := some { start := .line 1, stop := .last }, bang := true } &&
            Ex.parse "!" == some { name := "!", bang := true } &&
            Ex.parse " ! " == some { name := "!", bang := true } &&
            (Ex.parse "0!x").bind (·.range) == some { start := .line 0, stop := .line 0 } &&
            (Ex.parse "5,3!x").bind (·.range) == some { start := .line 5, stop := .line 3 } &&
            Ex.parse "3,5w" ==
              some { name := "w", range := some { start := .line 3, stop := .line 5 } } &&
            (Ex.parse ",5!x").bind (·.range) == some { start := .current, stop := .line 5 } &&
            (Ex.parse "3,!x").bind (·.range) == some { start := .line 3, stop := .current } &&
            Ex.parse "12,$ e a b" ==
              some
                { name := "e", argument := some "a b"
                  range := some { start := .line 12, stop := .last } }) },
    { name :=
        "criterion 2: a range is resolved against the buffer's lines and the cursor's: over three lines `%` is 1 to 3 and `.` the cursor's line, and line 0, a range that runs backwards and a line past the end are refused, the last with a message naming the line and the count"
      run :=
        let over (range : Ex.Range) (current : Nat) : String ⊕ (Nat × Nat) :=
          match range.resolve current 3 with
          | .ok lines => .inr lines
          | .error why => .inl why
        pure
          (over { start := .line 1, stop := .line 7 } 1 == .inl (Ex.pastEnd 7 3) &&
            Ex.pastEnd 7 3 == "line 7 is past the end of the buffer (3 lines)" &&
            over { start := .line 1, stop := .last } 2 == .inr (1, 3) &&
            over { start := .current, stop := .current } 2 == .inr (2, 2) &&
            over { start := .current, stop := .last } 2 == .inr (2, 3) &&
            over { start := .line 0, stop := .line 0 } 1 == .inl Ex.lineZero &&
            over { start := .line 3, stop := .line 2 } 1 == .inl (Ex.backwards 3 2) &&
            over { start := .line 5, stop := .line 3 } 1 == .inl (Ex.pastEnd 5 3) &&
            over { start := .line 9, stop := .line 8 } 1 == .inl (Ex.pastEnd 9 3)) },
    { name :=
        "a text's lines are its rows, but for the empty row after a last line feed: three lines and a last line feed are three lines, the empty text is one, and a last line with no line feed counts; a snapshot of the text counts the same"
      run :=
        let counted (initial : String) : Option (Nat × Nat) :=
          onTextModel do
            let text ← createText initial
            return (← text.lineCount, ← (← text.snapshot).lineCount)
        pure
          ([("b\nc\na\n", 3), ("", 1), ("a", 1), ("a\nb", 2), ("\n", 1), ("a\n\n", 2)].all
            fun (initial, lines) => counted initial == some (lines, lines)) }]

/-- The key strings the scheme fixtures are written with. -/
def schemeKeyStrings : List String :=
  ["C-x C-s", "C-x C-f", "C-x r t", "C-q", "C-x", "C-x r", "z", "a", "<Escape>", "C-z M-z s-z",
    "SPC"]

/-- A keymap for the scheme checks: sequences of two keys and of three, and
one of one key. -/
def globalMap : Keymap Invocation :=
  Keymap.ofList
    [(keys "C-x C-s", invoke "save"), (keys "C-x C-f", invoke "find-file"),
      (keys "C-x r t", invoke "string-rectangle"), (keys "C-q", invoke "quit")]

/-- A keymap that binds one of `globalMap`'s sequences to another command. -/
def localMap : Keymap Invocation :=
  Keymap.ofList [(keys "C-x C-s", invoke "save-as")]

/-- The keymaps of the scheme checks' views: `localMap` before `globalMap`
for view 1, `globalMap` alone for every other. -/
def schemeMaps (view : ViewId) : List (Keymap Invocation) :=
  if view.index == 1 then [localMap, globalMap] else [globalMap]

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

/-- A press of `key` with no text, as a window reports one. -/
def press (key : Key) : Event :=
  .key key true ""

/-- A press of each key the key string `text` names, in order. -/
def presses (text : String) : List Event :=
  (keys text).map press

/-- What a command of the dispatch checks is: given its call, a program
whose value is what to write back. -/
abbrev Dispatched :=
  Call → EditorM (Option Config.Write)

/-- What a step of the dispatch checks is handed: one keymap, the same for
every view, that binds each key string of `bindings` to the invocation
beside it, and the commands `commands`, by name. -/
def dispatchKeys (bindings : List (String × Invocation))
    (commands : List (String × Dispatched) := []) : Loop.Keys TestScheme.scheme :=
  { maps := fun _ _ =>
      [Keymap.ofList (bindings.map fun (text, invocation) => (keys text, invocation))]
    command? := fun name => (commands.find? (·.1 == name)).map (·.2) }

/-- What a command was called with, as one line: its arguments, then its
keys as a key string. -/
def calledWith (call : Call) : String :=
  " ".intercalate (call.arguments.map argumentText ++ [Key.notations call.keys])

/-- The command `stamp` of the dispatch checks: it inserts what it was
called with (`calledWith`) at the cursors of the window it is handed. -/
def stamp : Dispatched := fun call => do
  Loop.insert call.target (calledWith call)
  return none

/-- Feeds `loop` the `events` in order, each step handed `keys`: the loop
after them and what each step handed back. -/
def stepsWith {scheme : InputScheme} (keys : Loop.Keys scheme) (loop : Loop scheme)
    (events : List Event) : EditorM (Loop scheme × Array (Loop.Stepped scheme)) := do
  let mut loop := loop
  let mut steps := #[]
  for event in events do
    let after ← loop.step keys event
    loop := after.loop
    steps := steps.push after
  return (loop, steps)

/-- What a run of the loop over the state `start` makes came to on the
models `model`, each step handed `keys`: the loop and what each step handed
back, the scenes the display recorded, and the models. `none` when it was
refused. -/
def dispatched (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩)
    (model : EditorModel := editorModel) :
    Option ((TestLoop × Array (Loop.Stepped TestScheme.scheme)) × Array Scene × EditorModel) :=
  let program : EditorM (TestLoop × Array (Loop.Stepped TestScheme.scheme)) := do
    stepsWith keys { state := ← start } events
  match program.runModel model with
  | (.ok result, model) => some (result, model.display.scenes, model)
  | (.error _, _) => none

/-- The pending keys each scene of a run showed; none of them when the run
was refused. -/
def pendingShown (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩) : Array String :=
  match dispatched keys events start with
  | some (_, scenes, _) => scenes.map (·.pending)
  | none => #[]

/-- What the last scene of a run showed: its echo, its pending keys, and the
text of each of its views. `none` when the run was refused or published
nothing. -/
def lastScene (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩)
    (model : EditorModel := editorModel) : Option (String × String × Array (Option String)) :=
  match dispatched keys events start model with
  | some (_, scenes, model) =>
    scenes.back?.map fun scene => (scene.echo, scene.pending, scene.views.map (shownText model))
  | none => none

/-- The checks of keys in the loop (`Editor/Loop.lean`), on the editor's
models and the test scheme, with keymaps written here: which keys are
stepped through the scheme, the pending keys the scene shows, and the
command a completed sequence runs. -/
def dispatchKeyChecks : List Check :=
  let saves := dispatchKeys [("C-x C-s", invoke "save"), ("C-x r t", invoke "rectangle")]
  [{  name :=
        "after the first key of a bound sequence the scene shows it as pending, after each further key of a longer one the keys so far, and after the key that completes the sequence none"
      run :=
        pure
          (pendingShown saves (presses "C-x C-s") == #["C-x", ""] &&
            pendingShown saves (presses "C-x r t") == #["C-x", "C-x r", ""]) },
    { name :=
        "after a prefix and then a key that goes on with no binding, the scene shows no pending keys, and the sequence typed next is pending from its first key again"
      run :=
        pure
          (pendingShown saves (presses "C-x" ++ [pressF5] ++ presses "C-x") ==
            #["C-x", "", "C-x"]) },
    { name :=
        "a key release, and a press and a release of a modifier key by itself, between two keys of a sequence are not stepped: the prefix is still pending after each"
      run :=
        let shift : Key :=
          { logical := .named ⟨"Shift"⟩, physical := .code "ShiftLeft",
            modifiers := { shift := true } }
        let between : List Event :=
          [.key (controlKey "x") false "", press shift,
            .key { shift with modifiers := {} } false ""]
        pure
          (pendingShown saves (presses "C-x" ++ between ++ presses "r") ==
            #["C-x", "C-x", "C-x", "C-x", "C-x r"]) },
    { name :=
        "a press the platform repeated is stepped like any press, and a key from a window is taken by its chord"
      run :=
        let held : Key :=
          { controlKey "x" with
            physical := .code "KeyX", repeated := true }
        pure (pendingShown saves [press held] == #["C-x"]) },
    { name :=
        "a key is for the focused view: it is looked up in that view's keymaps, and in no other's"
      run :=
        let onlyFirst : Loop.Keys TestScheme.scheme :=
          { maps := fun state view => if view == ⟨1⟩ then saves.maps state view else [] }
        let focusedOn (view : ViewId) : TextM EditorState := do
          return ((← threeWindows).focusWindow view).2
        pure
          (pendingShown onlyFirst (presses "C-x") (focusedOn ⟨1⟩) == #["C-x"] &&
            pendingShown onlyFirst (presses "C-x") (focusedOn ⟨0⟩) == #[""]) },
    { name :=
        "a modifier key by itself is each named key of the W3C modifier names, with or without modifiers held, and no other key: not a character with shift held, and not another named key"
      run :=
        pure
          (["Shift", "Control", "Alt", "AltGraph", "Meta", "Super", "Hyper", "CapsLock", "NumLock",
                  "ScrollLock", "Fn", "FnLock", "Symbol", "SymbolLock"].all
              (fun name =>
                (namedKey ⟨name⟩).isModifier &&
                  (namedKey ⟨name⟩ { shift := true, control := true }).isModifier) &&
            !(charKey "A" { shift := true }).isModifier &&
            !(namedKey .escape).isModifier &&
            !(namedKey ⟨"F5"⟩).isModifier &&
            !({ logical := .dead none } : Key).isModifier &&
            !({ logical := .unidentified } : Key).isModifier) },
    { name :=
        "a bound key sequence runs its command once, with the count the binding gives and the keys typed: the scene after the prefix shows the text unchanged, the scene after the last key shows the command's effect, and a further key that is bound to nothing adds nothing"
      run :=
        let keys :=
          dispatchKeys [("C-x i", { command := "stamp", arguments := [.nat 3] })] [("stamp", stamp)]
        pure
          (lastScene keys (presses "C-x") == some ("", "C-x", #[some ""]) &&
            lastScene keys (presses "C-x i") == some ("", "", #[some "3 C-x i"]) &&
            lastScene keys (presses "C-x i" ++ [pressF5]) == some ("", "", #[some "3 C-x i"])) },
    { name :=
        "a command is handed the focused window and its buffer, the arguments of the invocation in order, and every key of the sequence as a chord, though the keys came from a window with their physical codes"
      run :=
        let seen : Dispatched := fun call => do
          let editor := (← call.target.buffer.text.read)
          makes
              s!"{call.target.window.id.index} {call.target.buffer.name} {editor.length} {calledWith call}"
          return none
        let keys :=
          dispatchKeys
            [("C-x r t", { command := "seen", arguments := [.str "w", .int (-2), .bool true] })]
            [("seen", seen)]
        let fromWindow : List Event :=
          (Editor.Key.parse "C-x r t" |>.toOption.getD []).map fun key =>
            press
              { key with
                physical := .code "KeyQ", repeated := true }
        let focusedOn : TextM EditorState := do
          return ((← threeWindows).focusWindow ⟨2⟩).2
        pure <|
          match dispatched keys fromWindow focusedOn with
          | some (_, _, model) => model.texts.contents.back? == some "2 scratch 0 w -2 true C-x r t"
          | none => false },
    { name :=
        "an invocation of a name no command is registered under says so in the echo area, and the next key is handled: a key that yields nothing leaves the echo, and the next command that runs clears it"
      run :=
        let keys :=
          dispatchKeys [("C-c n", invoke "nope"), ("C-c s", invoke "stamp")] [("stamp", stamp)]
        pure
          (lastScene keys (presses "C-c n") == some ("nope: no such command", "", #[some ""]) &&
            lastScene keys (presses "C-c n" ++ [pressF5] ++ presses "C-c") ==
              some ("nope: no such command", "C-c", #[some ""]) &&
            lastScene keys (presses "C-c n C-c s") == some ("", "", #[some "C-c s"])) },
    { name :=
        "a key bound to a registered command, in a state whose focused window is not in the state, says in the echo area that no window is focused: the command makes no request, and nothing is left pending"
      run :=
        let made : Dispatched := fun _ => do
          discard <| createText "made"
          return none
        let keys := dispatchKeys [("C-c m", invoke "made")] [("made", made)]
        let unfocused : TextM EditorState := do
          let state ← EditorState.initial ⟨640, 480⟩
          return { state with frame := { state.frame with focused := ⟨9⟩ } }
        pure <|
          match dispatched keys (presses "C-c m") unfocused with
          | some ((loop, _), scenes, model) =>
            loop.state.echo == "made: no window is focused" &&
              scenes.back?.map (·.echo) == some "made: no window is focused" &&
              model.texts.contents == #[""] &&
              loop.pending == "" &&
              scenes.back?.map (·.pending) == some ""
          | none => false },
    { name :=
        "a command that is refused says so in the echo area, with its name and the refusal, and the step is not refused: the next key runs its command"
      run :=
        let gone : Dispatched := fun _ => do
          (⟨7⟩ : TextId).insert 0 "x"
          return none
        let keys :=
          dispatchKeys [("C-c g", invoke "gone"), ("C-c s", invoke "stamp")]
            [("gone", gone), ("stamp", stamp)]
        pure
          (lastScene keys (presses "C-c g") ==
              some ("gone: refused: no such text", "", #[some ""]) &&
            lastScene keys (presses "C-c g C-c s") == some ("", "", #[some "C-c s"])) },
    { name :=
        "under the test scheme a key that prints and is bound to nothing yields its self-insert, which no command is registered under: the echo area says so"
      run :=
        pure
          (lastScene (dispatchKeys []) (presses "a") ==
            some ("self-insert: no such command", "", #[some ""])) },
    { name :=
        "a step hands back what the command it ran asked to be written, and nothing for a step that ran no command or whose command was refused"
      run :=
        let writes : Dispatched := fun _ =>
          return some { owner := .config, store := "counter", value := .nat 5 }
        let refuses : Dispatched := fun _ => do
          (⟨7⟩ : TextId).insert 0 "x"
          return some { owner := .config, store := "counter", value := .nat 9 }
        let keys :=
          dispatchKeys [("C-c w", invoke "writes"), ("C-c r", invoke "refuses")]
            [("writes", writes), ("refuses", refuses)]
        pure <|
          match dispatched keys (presses "C-c w C-c r" ++ [pressF5, .focus true]) with
          | some ((_, steps), _, _) =>
            steps.map
                (fun step =>
                  step.write.map fun write => (write.owner.name, write.store, write.value)) ==
              #[none, some ("config", "counter", Value.nat 5), none, none, none, none]
          | none => false }]

/-- A command of the rollback checks that is refused with `badRange`, after
`before` has run on what it was called with. -/
def failingAfter (before : Call → EditorM Unit) : Dispatched := fun call => do
  before call
  call.target.buffer.text.delete 9 99
  return none

/-- The command `boom` of the rollback checks: it replaces what the
selection covers with `boom`, which edits the text and moves the selection,
and is then refused. -/
def boom : Dispatched :=
  failingAfter fun call => Loop.insert call.target "boom"

/-- `hiddenBuffer`'s state with the buffer `hidden`, which no window shows,
holding a file: a buffer a save can be begun for. -/
def savable : TextM EditorState := do
  let (state, _) ← hiddenBuffer
  return (state.attachFile ⟨2⟩ notePath noteStamp .lf).2

/-- The save in flight of the buffer `hidden` of `savable`, in `state`. -/
def savingOf (state : EditorState) : Option Buffer.Saving :=
  ((state.buffer? ⟨2⟩).bind (·.file)).bind (·.saving)

/-- The commands of the checks of a save in flight, on `savable`, bound
under `C-c`. `begin` (`g`) takes a snapshot of the buffer's text and begins
a save of it, with the state the buffer's history is in. `end` (`e`) ends
the save in flight with a stamp, as a save that wrote the file does, and
`unsaved` (`n`) with none, as one that was refused does. `remove` (`r`)
removes the buffer. `fail` (`f`) ends the save with a stamp and is then
refused. `twice` (`t`) releases the save's snapshot itself and then ends
the save. -/
def saveKeys : Loop.Keys TestScheme.scheme :=
  let ends (stamp : Option File.Stamp) (first : SnapshotId → EditorM Unit := fun _ => pure ()) :
    EditorM Unit := do
    let some saving := savingOf (← editorState) | throw .noSuchSnapshot
    first saving.snapshot
    discard <| EditorState.ask (.endSave ⟨2⟩ saving.snapshot stamp)
  let later : File.Stamp :=
    { noteStamp with
      seconds := 9, size := 12 }
  let run (command : EditorM Unit) : Dispatched := fun _ => do
    command
    return none
  dispatchKeys
    [("C-c g", invoke "begin"), ("C-c e", invoke "end"), ("C-c n", invoke "unsaved"),
      ("C-c r", invoke "remove"), ("C-c f", invoke "fail"), ("C-c t", invoke "twice")]
    [("begin",
        run do
          let some buffer := (← editorState).buffer? ⟨2⟩ | throw .noSuchText
          let taken ← buffer.text.snapshot
          discard <| EditorState.ask (.beginSave ⟨2⟩ taken buffer.history.state)),
      ("end", run (ends (some later))), ("unsaved", run (ends none)),
      ("remove", run (discard <| EditorState.ask (.removeBuffer ⟨2⟩))),
      ("fail", failingAfter fun _ => ends (some later)),
      ("twice", run (ends (some later) fun taken => taken.release))]

/-- A scheme written for the rollback checks: the test scheme, with two
counts beside its state that no reset clears, as a scheme's state may hold
what a reset must keep. The first counts the keys that yielded an
invocation, and the second the keys that yielded nothing and left nothing
pending. -/
def tallying : InputScheme :=
  { State := TestScheme.State × Nat × Nat
    Binding := Invocation
    init := ({}, 0, 0)
    step := fun maps view state key =>
      match TestScheme.step maps view state.1 key with
      | (next, some invocation) => ((next, state.2.1 + 1, state.2.2), some invocation)
      | (next, none) =>
        ((next, state.2.1, if next.pending.isEmpty then state.2.2 + 1 else state.2.2), none)
    pending := (·.1.pending)
    command := fun name => { command := name } }

/-- The two counts of `tallying` in a loop's state: the keys that yielded an
invocation, and the keys that yielded nothing and left nothing pending. -/
def tallies (loop : Loop tallying) : Nat × Nat :=
  let state : TestScheme.State × Nat × Nat := loop.input
  state.2

/-- The focused window's scroll anchor in `loop`'s state, as the text holds
it. -/
def scrollOf {scheme : InputScheme} (loop : Loop scheme) : EditorM (Option Anchor) := do
  let some target := loop.state.focusedTarget? | throw .noSuchText
  match ← target.buffer.text.marker target.window.scroll with
  | .anchor anchor =>
    return some anchor
  | .selection _ =>
    return none

/-- The checks of rollback in the loop (`Editor/Loop.lean`), on the editor's
models: what a command that failed leaves, in the text, in the windows'
markers, in the history and in the scheme's state. -/
def dispatchRollbackChecks : List Check :=
  let keys :=
    dispatchKeys [("C-c b", invoke "boom"), ("C-c s", invoke "stamp")]
      [("boom", boom), ("stamp", stamp)]
  [{  name :=
        "a command that fails after editing: the echo area shows its error, the buffer's text and the window's selection are those before the command, the history has no step for it, and the next key runs its command"
      run :=
        pure <|
          let program :
            EditorM ((String × Array SelectionRange × String × Nat) × Nat × String × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith keys loop (presses "C-c")
            let nodes := (← focusedOf loop).buffer.history.nodes.size
            let (loop, _) ← stepsWith keys loop (presses "b")
            let target ← focusedOf loop
            let failed :=
              (← target.buffer.text.read, ← cursorsOf loop, loop.state.echo,
                target.buffer.history.nodes.size)
            let (loop, _) ← stepsWith keys loop (presses "C-c s")
            let target ← focusedOf loop
            let after ← target.buffer.text.read
            let some _ ← target.buffer.history.undo | throw .noInverse
            return (failed, nodes, after, ← target.buffer.text.read)
          match program.runModel editorModel with
          | (.ok (failed, nodes, after, undone), model) =>
            failed == ("abcd", #[⟨1, 3⟩], "boom: refused: bad range", nodes) &&
              after == "aC-c sd" &&
              undone == "abcd" &&
              model.display.scenes.map (·.echo) ==
                #["", "boom: refused: bad range", "boom: refused: bad range", ""]
          | (.error _, _) => false },
    { name :=
        "a command that placed the window's selection and its scroll anchor without editing, and then failed, has both put back where they were"
      run :=
        pure <|
          let wander : Dispatched :=
            failingAfter fun call => do
              let text := call.target.buffer.text
              text.place call.target.window.selection (.selection { ranges := #[⟨0, 0⟩, ⟨4, 4⟩] })
              text.place call.target.window.scroll (.anchor { offset := 2, bias := .after })
          let keys := dispatchKeys [("C-c w", invoke "wander")] [("wander", wander)]
          let program : EditorM (Array SelectionRange × Option Anchor × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith keys loop (presses "C-c w")
            return (← cursorsOf loop, ← scrollOf loop, loop.state.echo)
          match (program.runModel editorModel).1 with
          | .ok (cursors, scroll, echo) =>
            cursors == #[⟨1, 3⟩] && scroll == some { offset := 0, bias := .before } &&
              echo == "wander: refused: bad range"
          | .error _ => false },
    { name :=
        "a command that fails after editing two buffers has both texts as they were before it, and one that edited nothing leaves the texts and their revisions as they were"
      run :=
        pure <|
          let both : Dispatched :=
            failingAfter fun call => do
              call.target.buffer.text.insert 0 "x"
              (⟨1⟩ : TextId).insert 5 "!"
              call.target.buffer.text.insert 0 "y"
          let idle : Dispatched := failingAfter fun _ => pure ()
          let keys :=
            dispatchKeys [("C-c 2", invoke "both"), ("C-c 0", invoke "idle")]
              [("both", both), ("idle", idle)]
          let revisions (loop : TestLoop) : EditorM (Array Nat) :=
            loop.state.buffers.filterMap id |>.mapM fun buffer => buffer.text.revision
          let program : EditorM (Array String × Array Nat × Array Nat) := do
            let (loop, _) ← stepsWith keys { state := ← twoBuffers } (presses "C-c 2")
            let texts ← (loop.state.buffers.filterMap id).mapM fun buffer => buffer.text.read
            let before ← revisions loop
            let (loop, _) ← stepsWith keys loop (presses "C-c 0")
            return (texts, before, ← revisions loop)
          match (program.runModel editorModel).1 with
          | .ok (texts, before, after) => texts == #["", "other"] && before == after
          | .error _ => false },
    { name :=
        "a key's command that sets a register and is then refused leaves the register the name had: a register is editor state, and the state is the one from before the command; a command that sets one and runs to its end leaves it set"
      run :=
        pure <|
          let kept : Register := { text := "kept" }
          let lost : Register := { text := "lost\n", linewise := true }
          let keeps : Dispatched := fun _ => do
            setRegister "a" kept
            return none
          let loses : Dispatched :=
            failingAfter fun _ => do
              setRegister "a" lost
              setRegister "b" lost
          let keys :=
            dispatchKeys [("C-c k", invoke "keeps"), ("C-c l", invoke "loses")]
              [("keeps", keeps), ("loses", loses)]
          let program :
            EditorM
              (Option Register × Option Register × Option Register × Option Register × String) :=
            do
            let loop : TestLoop := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (set, _) ← stepsWith keys loop (presses "C-c k")
            let (failed, _) ← stepsWith keys set (presses "C-c l")
            return (loop.state.register? "a", set.state.register? "a", failed.state.register? "a",
                failed.state.register? "b", failed.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (none, some kept, some kept, none, "loses: refused: bad range") },
    { name :=
        "after a command that failed the scheme is as it was before the first key of the sequence, with what it keeps across a reset: the key that yielded the failed invocation is not counted, a key that yielded nothing before it still is, and nothing is pending"
      run :=
        pure <|
          let keys : Loop.Keys tallying :=
            { maps := fun _ _ =>
                [Keymap.ofList
                    [(ModelTest.keys "C-c b", invoke "boom"),
                      (ModelTest.keys "C-c s", invoke "stamp")]]
              command? := fun name =>
                ([("boom", boom), ("stamp", stamp)].find? (·.1 == name)).map (·.2) }
          let program : EditorM (List (Nat × Nat) × String) := do
            let loop : Loop tallying := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (ran, _) ← stepsWith keys loop (presses "C-c s")
            let (reset, _) ← stepsWith keys ran [pressF5]
            let (failed, _) ← stepsWith keys reset (presses "C-c b")
            let (again, _) ← stepsWith keys failed (presses "C-c s")
            return ([tallies ran, tallies reset, tallies failed, tallies again], failed.pending)
          match (program.runModel editorModel).1 with
          | .ok (counts, pending) => counts == [(1, 0), (1, 1), (1, 1), (2, 1)] && pending == ""
          | .error _ => false },
    { name :=
        "a command that gave up the window's selection marker and then failed cannot be rolled back whole: the echo area says what was not, after the command's error, the text is still put back, and the step is not refused"
      run :=
        pure <|
          let forget : Dispatched :=
            failingAfter fun call => do
              call.target.buffer.text.insert 0 "x"
              call.target.buffer.text.unmark call.target.window.selection
          let keys := dispatchKeys [("C-c f", invoke "forget")] [("forget", forget)]
          lastScene keys (presses "C-c f") (holding "abcd" #[⟨1, 3⟩]) ==
            some
              ("forget: refused: bad range; not rolled back: no such marker", "", #[some "abcd"]) },
    { name :=
        "a command that released a buffer's text and then failed: running it says what was not rolled back and still rolls back the other buffer, and the step that runs it is not refused"
      run :=
        pure <|
          let release : Dispatched :=
            failingAfter fun call => do
              (⟨1⟩ : TextId).insert 5 "!"
              call.target.buffer.text.release
          let keys := dispatchKeys [("C-c r", invoke "release")] [("release", release)]
          let ran : EditorM (String × String) := do
            let state ← twoBuffers
            let ran ← Loop.run keys state (invoke "release") (ModelTest.keys "C-c r")
            return (ran.state.echo, ← (⟨1⟩ : TextId).read)
          (match (ran.runModel editorModel).1 with
            | .ok (echo, other) =>
              echo == "release: refused: no such text; not rolled back: no such text" &&
                other == "other"
            | .error _ => false) &&
            (dispatched keys (presses "C-c r") twoBuffers).isSome },
    { name :=
        "a rollback after the history moved does not take the move back: it reverts the edits made since the move, leaves the text at the node the move reached, says the command moved in the history, and what was undone can be redone"
      run :=
        pure <|
          let program : EditorM (String × String × String × String) := do
            let state ← holding "one" #[⟨3, 3⟩]
            let (state, _) ← state.recordHistories
            let kept ← Loop.keep state
            -- What a command that moved in the history would have done: an
            -- undo, to the root, and then an edit.
            let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
            let some moved ← buffer.history.undo Origin.user | throw .noInverse
            buffer.text.insert 0 "x"
            let during := { state with buffers := #[some { buffer with history := moved.tree }] }
            let before ← buffer.text.read
            let (restored, said) ← kept.restore state during
            let after ← buffer.text.read
            let some again := restored.buffer? ⟨0⟩ | throw .noSuchText
            let some _ ← again.history.redo Origin.user | throw .noInverse
            return (before, after, said, ← buffer.text.read)
          (program.runModel editorModel).1.toOption ==
            some ("x", "", "; the command moved in the history", "one") },
    { name :=
        "a command that ended a save with a stamp, which marks the buffer's state as saved, and was then refused is rolled back whole: the buffer is modified as it was before the command, its stamp is the one from before, and its save is still in flight"
      run :=
        pure <|
          let program : EditorM (Bool × Bool × Option Buffer × Option Buffer × String) := do
            let state ← savable
            (⟨2⟩ : TextId).insert 0 "x"
            let (edited, _) ← stepsWith saveKeys ({ state } : TestLoop) [pressF5]
            let (begun, _) ← stepsWith saveKeys edited (presses "C-c g")
            let (failed, _) ← stepsWith saveKeys begun (presses "C-c f")
            return (((begun.state.buffer? ⟨2⟩).map (·.isModified)) == some true,
                (savingOf begun.state).isSome, failed.state.buffer? ⟨2⟩, begun.state.buffer? ⟨2⟩,
                failed.state.echo)
          match (program.runModel editorModel).1 with
          | .ok (modified, saving, after, before, echo) =>
            modified && saving && after == before && echo == "fail: refused: bad range"
          | .error _ => false },
    { name :=
        "a command that recorded its buffer's history marked as saved and was then refused leaves the buffer modified as it was: a rollback takes back a mark of the saved state"
      run :=
        pure <|
          let marking : Dispatched :=
            failingAfter fun call => do
              let .ok buffer ← call.target.window.buffer.synced | throw .noSuchText
              discard <|
                  EditorState.ask (.setHistory call.target.window.buffer buffer.history.markSaved)
          let keys := dispatchKeys [("C-c m", invoke "mark")] [("mark", marking)]
          let program : EditorM (Option Buffer × Option Buffer × String) := do
            let (edited, _) ←
              stepsWith keys ({ state := ← EditorState.initial ⟨640, 480⟩ } : TestLoop)
                  [.commit "a"]
            let (failed, _) ← stepsWith keys edited (presses "C-c m")
            return (edited.state.buffer? ⟨0⟩, failed.state.buffer? ⟨0⟩, failed.state.echo)
          match (program.runModel editorModel).1 with
          | .ok (before, after, echo) =>
            (before.map (·.isModified)) == some true && after == before &&
              echo == "mark: refused: bad range"
          | .error _ => false }]

/-- The events of `events` as they arrive, none of them marked as an
interrupt key. -/
def arriving (events : List Event) : List Received :=
  events.map fun event => { event, stamp := 0 }

/-- A press of the interrupt key as it arrives, marked as one: the event
the loop lowers the flag for. -/
def interruptArrives : Received :=
  { event := press Watch.interruptKey, stamp := 0, interrupt := true }

/-- Feeds `loop` what arrived, in order, as a host does (`Loop.take`), each
step handed `keys`: the loop after them. -/
def takes {scheme : InputScheme} (keys : Loop.Keys scheme) (loop : Loop scheme)
    (received : List Received) : EditorM (Loop scheme) := do
  let mut loop := loop
  for one in received do
    loop := (← loop.take keys one).loop
  return loop

/-- What a run of the loop over the buffer holding `abcd`, its selection
over `bc`, came to when it was fed what arrived, on the editor's models
with the watch model `watch`: the buffer's text, the selection's ranges, the
echo of each scene, and the watch model after. `none` when it was
refused. -/
def tookFrom (keys : Loop.Keys TestScheme.scheme) (received : List Received) (watch : WatchModel) :
    Option (String × Array SelectionRange × Array String × WatchModel) :=
  let program : EditorM (String × Array SelectionRange) := do
    let loop ← takes keys { state := ← holding "abcd" #[⟨1, 3⟩] } received
    return (← (← focusedOf loop).buffer.text.read, ← cursorsOf loop)
  match program.runModel { editorModel with watch } with
  | (.ok (text, cursors), model) =>
    some (text, cursors, model.display.scenes.map (·.echo), model.watch)
  | (.error _, _) => none

/-- The command `spin` of the interrupt checks: it replaces what the
selection covers with `spin`, and then asks the text its revision a thousand
times. -/
def spin : Dispatched := fun call => do
  Loop.insert call.target "spin"
  for _ in [0:1000] do
    discard <| call.target.buffer.text.revision
  return none

/-- The checks of the interrupt in the loop (`Editor/Loop.lean`), on the
editor's models: a command the loop runs stops once the flag is up, and the
flag comes down when the loop takes the interrupt key off the queue. -/
def dispatchInterruptChecks : List Check :=
  let keys :=
    dispatchKeys [("C-c l", invoke "spin"), ("C-c s", invoke "stamp"), ("C-g", invoke "stamp")]
      [("spin", spin), ("stamp", stamp)]
  let unbound := dispatchKeys [("C-c s", invoke "stamp")] [("stamp", stamp)]
  [{  name :=
        "when the interrupt key arrives while a command is looping over requests, the command stops: the buffer's text and the selection are those before it, the echo area says it was interrupted, and the flag is still up"
      run :=
        pure <|
          match tookFrom keys (arriving (presses "C-c l")) { arrivesAfter := some 20 } with
          | some (text, cursors, echoes, watch) =>
            text == "abcd" && cursors == #[⟨1, 3⟩] && echoes == #["", "spin: interrupted"] &&
              watch.arrived == 1
          | none => false },
    { name := "with no interrupt key arriving the same command runs to its end, and its edit stays"
      run :=
        pure <|
          match tookFrom keys (arriving (presses "C-c l")) {} with
          | some (text, _, echoes, _) => text == "aspind" && echoes == #["", ""]
          | none => false },
    { name :=
        "the event the library marked as the interrupt key lowers the flag and is then stepped like any key: the command bound to it runs to its end; the same key unmarked lowers nothing, and its command is interrupted"
      run :=
        pure <|
          (match tookFrom keys [interruptArrives] { arrived := 1 } with
            | some (text, _, echoes, watch) =>
              text == "aC-gd" && echoes == #[""] && watch.arrived == 0
            | none => false) &&
            match tookFrom keys (arriving [press Watch.interruptKey]) { arrived := 1 } with
            | some (text, _, echoes, watch) =>
              text == "abcd" && echoes == #["stamp: interrupted"] && watch.arrived == 1
            | none => false },
    { name :=
        "an interrupt key that arrived while no command was running interrupts nothing: once the loop has taken it off the queue, the next key's command runs to its end"
      run :=
        pure <|
          match
            tookFrom unbound (interruptArrives :: arriving (presses "C-c s")) { arrived := 1 } with
          | some (text, _, echoes, watch) =>
            text == "aC-c sd" && echoes == #["", "", ""] && watch.arrived == 0
          | none => false },
    { name :=
        "a command for a key queued ahead of the interrupt key is interrupted before its first request, and its echo is still there after the interrupt key is stepped and found bound to nothing; the key after it runs its command"
      run :=
        pure <|
          let queued := arriving (presses "C-c s") ++ [interruptArrives]
          (match tookFrom unbound queued { arrived := 1 } with
            | some (text, cursors, echoes, watch) =>
              text == "abcd" && cursors == #[⟨1, 3⟩] &&
                echoes == #["", "stamp: interrupted", "stamp: interrupted"] &&
                watch.arrived == 0
            | none => false) &&
            match tookFrom unbound (queued ++ arriving (presses "C-c s")) { arrived := 1 } with
            | some (text, _, echoes, _) => text == "aC-c sd" && echoes.back? == some ""
            | none => false },
    { name :=
        "with two interrupt keys arrived, the command of a key between them is interrupted, and the one after the second runs to its end"
      run :=
        pure <|
          let between := interruptArrives :: arriving (presses "C-c s") ++ [interruptArrives]
          (match tookFrom unbound between { arrived := 2 } with
            | some (text, _, echoes, watch) =>
              text == "abcd" && echoes.back? == some "stamp: interrupted" && watch.arrived == 0
            | none => false) &&
            match tookFrom unbound (between ++ arriving (presses "C-c s")) { arrived := 2 } with
            | some (text, _, echoes, _) => text == "aC-c sd" && echoes.back? == some ""
            | none => false },
    { name :=
        "for an event taken off the queue with no loop to step it, the flag is lowered once if the library marked the event, and not at all if it did not"
      run :=
        pure
          ((watched (Loop.lowerFor true) { arrived := 2 }).2.arrived == 1 &&
            (watched (Loop.lowerFor false) { arrived := 2 }).2.arrived == 2) }]

/-- A command of the slow-command checks that makes `requests` requests of
the text port, each a question that changes nothing, and is then refused if
`refused`. -/
def asking (requests : Nat) (refused : Bool := false) : Dispatched := fun call => do
  for _ in [0:requests] do
    discard <| call.target.buffer.text.revision
  if refused then
    throw .badRange
  return none

/-- What each step of a run handed back as its log, on the editor's models
with a clock that moves on by 10 milliseconds at each text request and each
display request; nothing when the run was refused. -/
def logged (keys : Loop.Keys TestScheme.scheme) (events : List Event) : Array (Array String) :=
  match
    dispatched keys events (model :=
      { editorModel with watch := { clock := 1000, pace := 10 } }) with
  | some ((_, steps), _, _) => steps.map (·.log)
  | none => #[]

/-- The checks of the slow-command log in the loop (`Editor/Loop.lean`), on
the model's clock: a command that took longer than the threshold is logged
once, with its name and how long it took. -/
def dispatchSlowChecks : List Check :=
  let keys : Loop.Keys TestScheme.scheme :=
    {
      dispatchKeys
        [("C-c 6", invoke "stamp"), ("C-c 5", invoke "five"), ("C-c 2", invoke "two"),
          ("C-c r", invoke "refused"), ("C-c n", invoke "nope")]
        [("stamp", asking 6), ("five", asking 5), ("two", asking 2),
          ("refused", asking 7 true)] with
      slowAfter := 50 }
  [{  name :=
        "a command that takes longer than the threshold produces one log entry with its name and how long it took, in the step that ran it and in no other"
      run :=
        pure
          (logged keys (presses "C-c 6" ++ [pressF5]) ==
            #[#[], #["slow command: stamp took 60 ms"], #[]]) },
    { name :=
        "a command that takes less than the threshold, or exactly as long, produces no log entry"
      run := pure (logged keys (presses "C-c 2 C-c 5") == #[#[], #[], #[], #[]]) },
    { name :=
        "a slow command that was refused is logged like one that finished, with the time the command took and not the time its rollback took"
      run :=
        pure (logged keys (presses "C-c r") == #[#[], #["slow command: refused took 70 ms"]]) },
    { name := "an invocation of a name no command is registered under produces no log entry"
      run := pure (logged keys (presses "C-c n") == #[#[], #[]]) },
    { name :=
        "the threshold a step is handed by default is the loop's, 100 milliseconds: a command of ten requests is not logged and one of eleven is"
      run :=
        let keys :=
          dispatchKeys [("C-c a", invoke "ten"), ("C-c b", invoke "eleven")]
            [("ten", asking 10), ("eleven", asking 11)]
        pure
          (keys.slowAfter == Loop.slowAfter && Loop.slowAfter == 100 &&
            logged keys (presses "C-c a C-c b") ==
              #[#[], #[], #[], #["slow command: eleven took 110 ms"]]) }]

/-- Splits the window a command was called on by the state
request, with markers the command makes on the buffer's text first: the new
view. Refused with `noSuchMarker` if the split is. -/
def splitting (call : Call) : EditorM ViewId := do
  let text := call.target.buffer.text
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
  match ← EditorState.ask (.split call.target.window.id scroll selection) with
  | .ok view =>
    return view
  | .error _ =>
    throw .noSuchMarker

/-- The text of the checks of two windows on one buffer: a hundred lines,
`l00` to `l99`, four bytes each with its line feed, so line `n` starts at
`4 * n`: many more rows than a window of a frame 40 pixels tall shows in
the display model's pixel cells. -/
def hundredLines : String :=
  "\n".intercalate ((List.range 100).map fun line => s!"l{line / 10}{line % 10}")

/-- A state of one window, view 0, over `hundredLines` in a buffer called
`scratch`, its scroll anchor and its cursor at the text's start, in a frame
of 640 by 40. -/
def tallState : TextM EditorState := do
  let text ← createText hundredLines
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
  let history ← UndoTree.over text
  return {
      buffers := #[some { name := EditorState.scratchName, text, history }]
      windows := #[{ id := ⟨0⟩, buffer := ⟨0⟩, scroll, selection }]
      frame := { size := ⟨640, 40⟩, windows := #[⟨0⟩], focused := ⟨0⟩ }
      recent := #[⟨0⟩] }

/-- The checks of two windows on one buffer (criterion 4 of the window
management's phase 1), on the editor's models: each window keeps a cursor
and a scroll anchor of its own, and an edit in one shows in both. -/
def twoWindowChecks : List Check :=
  -- Line 80 starts at byte 320.
  let deep := 320
  let keys :=
    dispatchKeys [("C-c s", invoke "split"), ("C-c o", invoke "other"), ("C-c g", invoke "deep")]
      [("split", fun call => do
          discard <| call.target.window.id.split
          return none),
        ("other", fun call => do
          let windows := (← editorState).frame.windows
          if let some next := windows.find? (· != call.target.window.id) then
            discard <| next.focus
          return none),
        ("deep", fun call => do
          call.target.select { ranges := #[⟨deep, deep⟩] }
          call.target.scrollTo deep
          return none)]
  [{  name :=
        "criterion 4, on the models: two windows split on one buffer of a hundred lines in a frame of 640 by 40 keep markers of their own; with view 1's cursor and anchor moved to line 80 and an edit typed in view 0 at the top, view 0's anchor and cursor are at the top and view 1's at line 80, moved by the edit; both views show the one snapshot, which holds the edit"
      run :=
        pure <|
          let program : EditorM (Option (Array Marker × String)) := do
            let (loop, _) ←
              stepsWith keys { state := ← tallState }
                  (presses "C-c s C-c o C-c g C-c o" ++ [.commit "X"])
            let some zero := loop.state.target? ⟨0⟩ | return none
            let some one := loop.state.target? ⟨1⟩ | return none
            let text := zero.buffer.text
            let markers ←
              [zero.window.scroll, one.window.scroll, zero.window.selection,
                      one.window.selection].mapM
                  fun marker => (text.marker marker : TextM Marker)
            return some (markers.toArray, ← text.read)
          match program.runModel editorModel with
          | (.ok (some (markers, contents)), model) =>
            let scenes := model.display.scenes
            match scenes.back? with
            | some scene =>
              match scene.views with
              | #[zero, one] =>
                let anchor (offset : Nat) : Marker := .anchor { offset, bias := .before }
                let cursor (at_ : Nat) : Marker := .selection { ranges := #[⟨at_, at_⟩] }
                zero.id == ⟨0⟩ && one.id == ⟨1⟩ && scene.focused == some ⟨0⟩ &&
                  zero.scroll != one.scroll &&
                  zero.selections != one.selections &&
                  markers == #[anchor 0, anchor (deep + 1), cursor 1, cursor (deep + 1)] &&
                  zero.snapshot == one.snapshot &&
                  shownText model zero == some ("X" ++ hundredLines) &&
                  contents == "X" ++ hundredLines &&
                  one.rect == { x := 320, y := 0, width := 320, height := 39 }
              | _ => false
            | none => false
          | _ => false }]

/-- The checks of a command's state requests in the loop
(`Editor/Command/Dispatch.lean`, `Editor/Loop.lean`), on the editor's
models: the loop answers them from the state it holds, keeps the state a
command that ran to its end left, and goes back to the state from before
one that did not. -/
def dispatchStateChecks : List Check :=
  let split : Dispatched := fun call => do
    discard <| splitting call
    return none
  let moving : Dispatched :=
    failingAfter fun call => do
      -- A move in the history, recorded as a command records one: an undo
      -- to the root, the moved tree set as the buffer's, and then an edit.
      let state ← editorState
      let some buffer := state.buffer? call.target.window.buffer | throw .noSuchText
      let some moved ← (← buffer.history.sync).undo Origin.user | throw .noInverse
      discard <| EditorState.ask (.setHistory call.target.window.buffer moved.tree)
      buffer.text.insert 0 "x"
  let keys :=
    dispatchKeys [("C-c s", invoke "split"), ("C-c f", invoke "fail"), ("C-c m", invoke "moving")]
      [("split", split), ("fail", failingAfter fun call => discard <| splitting call),
        ("moving", moving)]
  [{  name :=
        "a dispatched command that asks for the display rules is answered the rules the loop was told of, and the state is as it was"
      run :=
        let rules : Array DisplayRule :=
          #[{ mode := some "notes", target := .edge .left }, { target := .main, focus := false }]
        let program : EditorM (Guarded (Array DisplayRule) × EditorState × EditorState) := do
          let state ← twoBuffers
          let (ended, after) ←
            (EditorState.ask .displayRules).dispatched { displayRules := rules } state
          return (ended, after, state)
        pure <|
          match (program.runModel editorModel).1 with
          | .ok (.finished answer, after, state) => answer == rules && after == state
          | _ => false },
    { name :=
        "criterion 3, on the models: a step handed monocle as its layout shows only the focused window, in the whole tiled area, and focusing the other window shows it in its place; a step handed no layout keeps the frame's; a step handed the default shows both again; no window is lost on the way"
      run :=
        pure <|
          let others : Dispatched := fun call => do
            let windows := (← editorState).frame.windows
            if let some next := windows.find? (· != call.target.window.id) then
              discard <| next.focus
            return none
          let keyed :=
            dispatchKeys [("C-c s", invoke "split"), ("C-c o", invoke "other")]
              [("split", split), ("other", others)]
          let program : EditorM (Array EditorState) := do
            let (split, _) ←
              stepsWith keyed { state := ← EditorState.initial ⟨640, 480⟩ } (presses "C-c s")
            let (alone, _) ← stepsWith { keyed with layout := some .monocle } split [pressF5]
            let (kept, _) ← stepsWith keyed alone [pressF5]
            let (other, _) ← stepsWith { keyed with layout := some .monocle } kept (presses "C-c o")
            let (both, _) ← stepsWith { keyed with layout := some Layout.default } other [pressF5]
            return #[split.state, alone.state, kept.state, other.state, both.state]
          match program.runModel editorModel with
          | (.ok states, model) =>
            let scenes := model.display.scenes
            let laid (scene : Scene) := scene.views.map fun view => (view.id, view.rect)
            -- Every event publishes a scene: `C-c s` and `C-c o` are two
            -- presses each, and the scene after a sequence's last key is the
            -- one its command's step published.
            match states, scenes with
            | #[split, alone, kept, other, both], #[_, first, second, third, _, fourth, fifth] =>
              states.all (·.frame.windows == #[⟨0⟩, ⟨1⟩]) && states.all (·.wellFormed) &&
                split.frame.layout == Layout.default &&
                alone.frame.layout == .monocle &&
                kept.frame.layout == .monocle &&
                both.frame.layout == Layout.default &&
                first.views.map (·.id) == #[⟨0⟩, ⟨1⟩] &&
                laid second == #[(⟨0⟩, alone.tiled)] &&
                second.focused == some ⟨0⟩ &&
                laid third == #[(⟨0⟩, kept.tiled)] &&
                laid fourth == #[(⟨1⟩, other.tiled)] &&
                fourth.focused == some ⟨1⟩ &&
                laid fifth == both.rects &&
                fifth.views.map (·.id) == #[⟨0⟩, ⟨1⟩]
            | _, _ => false
          | (.error _, _) => false },
    { name :=
        "a layout change a command made lasts until config chooses another layout: a zoom survives three steps handed the default layout, and a resized share a step handed it; handing monocle and then the manual split layout rearranges the same windows and leaves the zoom"
      run :=
        pure <|
          let arranging (change : Arrange) : Dispatched := fun call => do
            discard <| call.target.window.id.arrange change
            return none
          let keyed :=
            dispatchKeys
              [("C-c s", invoke "split"), ("C-c z", invoke "zoom"), ("C-c g", invoke "grow")]
              [("split", split), ("zoom", arranging .zoom),
                ("grow", arranging (.resize .columns true 1))]
          let chosen := { keyed with layout := some Layout.default }
          let program : EditorM (Array EditorState) := do
            let (split, _) ←
              stepsWith chosen { state := ← EditorState.initial ⟨640, 480⟩ } (presses "C-c s")
            let (zoomed, _) ← stepsWith chosen split (presses "C-c z")
            let (kept, _) ← stepsWith chosen zoomed [pressF5, pressF5, pressF5]
            let (back, _) ← stepsWith chosen kept (presses "C-c z")
            let (grown, _) ← stepsWith chosen back (presses "C-c g")
            let (still, _) ← stepsWith chosen grown [pressF5]
            let (again, _) ← stepsWith chosen still (presses "C-c z")
            let (monocle, _) ← stepsWith { keyed with layout := some .monocle } again [pressF5]
            let (manual, _) ←
              stepsWith { keyed with layout := some Layout.manual } monocle [pressF5]
            return #[kept.state, back.state, grown.state, still.state, again.state, monocle.state,
                manual.state]
          match program.runModel editorModel with
          | (.ok #[kept, back, grown, still, again, monocle, manual], _) =>
            let grownLayout := Layout.masterStack { share := 55 }
            #[kept, back, grown, still, again, monocle, manual].all
                (fun state => state.wellFormed && state.frame.windows == #[⟨0⟩, ⟨1⟩]) &&
              kept.frame.layout == .monocle &&
              kept.frame.zoomedFrom == some Layout.default &&
              back.frame.layout == Layout.default &&
              grown.frame.layout == grownLayout &&
              still.frame.layout == grownLayout &&
              again.frame.zoomedFrom == some grownLayout &&
              monocle.frame.layout == .monocle &&
              monocle.frame.zoomedFrom == none &&
              manual.frame.layout == .splits (.split .rows 1 1 .tile .tile) &&
              manual.frame.zoomedFrom == none
          | _ => false },
    { name :=
        "a key's command that splits its window by a state request: the loop keeps the new window after the step, well formed, and the scene shows both views"
      run :=
        pure <|
          match dispatched keys (presses "C-c s") with
          | some ((loop, _), scenes, _) =>
            loop.state.wellFormed && loop.state.windows.map (·.id) == #[⟨0⟩, ⟨1⟩] &&
              loop.state.frame.windows == #[⟨0⟩, ⟨1⟩] &&
              loop.state.echo == "" &&
              scenes.back?.map (·.views.map (·.id)) == some #[⟨0⟩, ⟨1⟩]
          | none => false },
    { name :=
        "a command that splits its window and is then refused leaves the state from before it: one window, the list as it was, and the refusal in the echo"
      run :=
        pure <|
          match dispatched keys (presses "C-c f") with
          | some ((loop, _), scenes, _) =>
            loop.state.wellFormed && loop.state.windows.map (·.id) == #[⟨0⟩] &&
              loop.state.frame.windows == #[⟨0⟩] &&
              loop.state.echo == "fail: refused: bad range" &&
              scenes.back?.map (·.views.map (·.id)) == some #[⟨0⟩]
          | none => false },
    { name :=
        "the interrupt flag is asked before each request that reaches the models and not before a state request: with the interrupt key arriving at a command's second ask, the state request before it is answered, the text request after it is not made, and the state the command had reached is handed back"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            EditorState.ask (.message "said")
            discard <| createText "two"
            EditorState.ask (.message "late")
          let program : EditorM (Guarded Unit × EditorState) := do
            command.dispatched {} (← EditorState.initial ⟨640, 480⟩)
          let ran (arrivesAfter : Nat) :=
            program.runModel { editorModel with watch := { arrivesAfter := some arrivesAfter } }
          (match ran 1 with
            | (.ok (outcome, state), model) =>
              outcome == .interrupted && state.echo == "said" &&
                model.texts.contents == #["", "one"]
            | (.error _, _) => false) &&
            -- Two asks for the four requests: the key placed two asks away
            -- has not arrived when the command ends, and is one ask off.
            match ran 2 with
            | (.ok (outcome, state), model) =>
              outcome == .finished () && state.echo == "late" &&
                model.texts.contents == #["", "one", "two"] &&
                model.watch.arrivesAfter == some 0 &&
                model.watch.arrived == 0
            | (.error _, _) => false },
    { name :=
        "a command that edits, says something, gives up and would edit again ends as having given up, with its reason and the state it had reached: the first edit was made, the second was not, and a try round the call does not go on"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            EditorState.ask (.message "said")
            try
              giveUp "cannot go on"
            catch _ =>
              pure ()
            discard <| createText "two"
            EditorState.ask (.message "late")
          let program : EditorM (Guarded Unit × EditorState) := do
            command.dispatched {} (← EditorState.initial ⟨640, 480⟩)
          match program.runModel editorModel with
          | (.ok (outcome, state), model) =>
            outcome == .gaveUp "cannot go on" && state.echo == "said" &&
              model.texts.contents == #["", "one"]
          | (.error _, _) => false },
    { name :=
        "a command that gives up where no loop dispatches it is refused with badSelection, and nothing of its reason is kept: the handler of the runners changes nothing"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            giveUp "cannot go on"
          match command.runModel editorModel with
          | (.error refusal, model) => refusal == .badSelection && model.texts.contents == #["one"]
          | (.ok _, _) => false },
    { name :=
        "a command that edits, says something, breaks off and would edit again ends as having broken off, with its reason and the state it had reached: the first edit was made, the second was not, and a try round the call does not go on"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            EditorState.ask (.message "said")
            try
              breakOff "far enough"
            catch _ =>
              pure ()
            discard <| createText "two"
            EditorState.ask (.message "late")
          let program : EditorM (Guarded Unit × EditorState) := do
            command.dispatched {} (← EditorState.initial ⟨640, 480⟩)
          match program.runModel editorModel with
          | (.ok (outcome, state), model) =>
            outcome == .brokeOff "far enough" && state.echo == "said" &&
              model.texts.contents == #["", "one"]
          | (.error _, _) => false },
    { name :=
        "a command that breaks off where no loop dispatches it is refused with badSelection, and nothing of its reason is kept: the handler of the runners changes nothing"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            breakOff "far enough"
          match command.runModel editorModel with
          | (.error refusal, model) => refusal == .badSelection && model.texts.contents == #["one"]
          | (.ok _, _) => false },
    { name :=
        "a command that edits, moves in the history and records the move, edits again and is then refused: the rollback reverts the edit made since the move from the tree the command left, leaves the text at the node the move reached, says the command moved in the history, and what was undone can be redone"
      run :=
        pure <|
          let program : EditorM (String × String × Array String × String) := do
            let loop : TestLoop := { state := ← holding "one" #[⟨3, 3⟩] }
            -- The first step records the insertion as a step of the history.
            let (loop, _) ← stepsWith keys loop ([pressF5] ++ presses "C-c m")
            let target ← focusedOf loop
            let text ← target.buffer.text.read
            let some _ ← target.buffer.history.redo Origin.user | throw .noInverse
            return (text, loop.state.echo, loop.state.windows.map fun _ => "window",
                ← target.buffer.text.read)
          (program.runModel editorModel).1.toOption ==
            some
              ("", "moving: refused: bad range; the command moved in the history", #["window"],
                "one") },
    { name :=
        "a command that asks which command an ex name is bound to is answered what the loop was told of the registry: the binding of a name it knows, with what it takes, and none for another name; the state is as it was"
      run :=
        pure <|
          let greet : Ex.Binding := { name := "greet", command := "greet-named", takes := .text }
          let registered : Loop.Registered :=
            { ex := fun name => if name == "greet" then some greet else none }
          let command : EditorM (Option Ex.Binding × Option Ex.Binding) := do
            return (← exBinding "greet", ← exBinding "other")
          let program : EditorM (Guarded (Option Ex.Binding × Option Ex.Binding) × Bool) := do
            let start ← EditorState.initial ⟨640, 480⟩
            let (outcome, state) ← command.dispatched registered start
            return (outcome, state == start)
          (program.runModel editorModel).1.toOption == some (.finished (some greet, none), true) },
    { name :=
        "what the loop is told of a registry's ex bindings is the latest entry of each name: config's binding of a name a compiled binding has, the compiled one of a name config does not bind, and none for a name nobody bound"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" },
                  { name := "q", command := "kept" }]).replaceEx
            .config #[{ name := "w", command := "config", takes := .text }]
        let told := registry.registered
        pure
          (told.ex "w" == some { name := "w", command := "config", takes := .text } &&
            told.ex "q" == some { name := "q", command := "kept" } &&
            told.ex "missing" == none) },
    { name :=
        "a command that asks which ex names are bound is answered the names the loop was told of the registry, in their order, and none where it was told none; the state is as it was"
      run :=
        pure <|
          let registered : Loop.Registered := { exNames := #["w", "q", "greet"] }
          let asks (registered : Loop.Registered) : Option (Guarded (Array String) × Bool) :=
            let program : EditorM (Guarded (Array String) × Bool) := do
              let start ← EditorState.initial ⟨640, 480⟩
              let (outcome, state) ← exNames.dispatched registered start
              return (outcome, state == start)
            (program.runModel editorModel).1.toOption
          asks registered == some (.finished #["w", "q", "greet"], true) &&
            asks {} == some (.finished #[], true) },
    { name :=
        "a command that asks which themes are registered is answered the names the loop was told, in their order, with the state as it was"
      run :=
        pure <|
          let asks (registered : Loop.Registered) : Option (Guarded (Array String) × Bool) :=
            let program : EditorM (Guarded (Array String) × Bool) := do
              let start ← EditorState.initial ⟨640, 480⟩
              let (outcome, state) ← themeNames.dispatched registered start
              return (outcome, state == start)
            (program.runModel editorModel).1.toOption
          asks { themeNames := #["default", "second"] } ==
              some (.finished #["default", "second"], true) &&
            asks {} == some (.finished #[], true) },
    { name :=
        "a command that asks to load a theme the loop was told is registered is answered ok, and the state keeps the name for the loop to take out; one nobody registered is refused with its name, and the state is as it was"
      run :=
        pure <|
          let registered : Loop.Registered := { themeNames := #["default", "second"] }
          let asks (name : String) : Option (Option (ThemeRefusal ⊕ Unit) × Option String × Bool) :=
            let program : EditorM (Option (ThemeRefusal ⊕ Unit) × Option String × Bool) := do
              let start ← EditorState.initial ⟨640, 480⟩
              let (outcome, state) ← (loadTheme name).dispatched registered start
              let reply :=
                match outcome with
                | .finished reply => some (replied reply)
                | _ => none
              return (reply, state.theme, { state with theme := none } == start)
            (program.runModel editorModel).1.toOption
          asks "second" == some (some (.inr ()), some "second", true) &&
            asks "nope" == some (some (.inl (.noSuchTheme "nope")), none, true) &&
            ThemeRefusal.describe (.noSuchTheme "nope") == Theme.unknown "nope" },
    { name :=
        "a command that asks for the command of a name to be run inside it: the command the loop was told of under that name runs there, with the call it is handed, before the asking command goes on, and what it said is in the state the asking command then reads; a name the loop was told no command of is answered false, and nothing runs"
      run :=
        pure <|
          let inner (call : Call) : EditorM Unit := do
            discard <| createText "inner"
            message s!"handed {call.arguments.length} arguments"
          let registered : Loop.Registered :=
            { command := fun name => if name == "inner" then some inner else none }
          let command : EditorM (Bool × String × Bool) := do
            let some target := (← editorState).focusedTarget? | throw .noSuchText
            let ran ← runCommand "inner" { target, arguments := [.nat 1, .nat 2] }
            let said := (← editorState).echo
            let missing ← runCommand "other" { target }
            discard <| createText "outer"
            return (ran, said, missing)
          let program : EditorM (Guarded (Bool × String × Bool) × EditorState) := do
            command.dispatched registered (← EditorState.initial ⟨640, 480⟩)
          match program.runModel editorModel with
          | (.ok (outcome, _), model) =>
            outcome == .finished (true, "handed 2 arguments", false) &&
              model.texts.contents == #["", "inner", "outer"]
          | (.error _, _) => false },
    { name :=
        "a command run inside another is part of it: one that gives up ends the asking command as having given up, one that is refused refuses it, and one that the interrupt stops at a request ends it as interrupted, each with nothing of the asking command run after it"
      run :=
        pure <|
          let registered : Loop.Registered :=
            {
              command := fun name =>
                match name with
                | "quits" => some fun _ => giveUp "no"
                | "fails" => some fun _ => throw .badRange
                | "works" =>
                  some fun _ => do
                    discard <| createText "one"
                    discard <| createText "two"
                | _ => none }
          let asking (name : String) : EditorM Unit := do
            let some target := (← editorState).focusedTarget? | throw .noSuchText
            discard <| runCommand name { target }
            discard <| createText "late"
          let ended (name : String) (watch : WatchModel := {}) :
            Option (Guarded Unit × Array String) :=
            let program : EditorM (Guarded Unit × EditorState) := do
              (asking name).dispatched registered (← EditorState.initial ⟨640, 480⟩)
            match program.runModel { editorModel with watch } with
            | (.ok (outcome, _), model) => some (outcome, model.texts.contents)
            | (.error _, _) => none
          ended "quits" == some (.gaveUp "no", #[""]) &&
            ended "fails" == some (.refused .badRange, #[""]) &&
            ended "works" == some (.finished (), #["", "one", "two", "late"]) &&
            ended "works" { arrivesAfter := some 1 } == some (.interrupted, #["", "one"]) },
    { name :=
        "a command that asks for another to be run inside it where no loop dispatches it is answered false: the handler of the runners knows no registry"
      run :=
        pure <|
          let command : EditorM Bool := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some target := state.focusedTarget? | throw .noSuchText
            runCommand "inner" { target }
          (command.runModel editorModel).1.toOption == some false }]

/-- The refusal `program` ends with, if it is refused. -/
def refusalOf {α : Type} (program : TextM α) : TextM (Option TextError) := do
  match ← observing program with
  | .ok _ =>
    return none
  | .error refusal =>
    return some refusal

/-- The refusals reading each of a window's two markers ends with, the
scroll anchor's first. -/
def markerRefusals (window : Window) : TextM (List (Option TextError)) :=
  return [← refusalOf (window.scroll.text.marker window.scroll),
      ← refusalOf (window.selection.text.marker window.selection)]

/-- The checks of what the loop gives up after a command (`Editor/Loop.lean`,
"What a finished command gave up"), on the editor's models: the markers of
a window a command closed, the text of a buffer it removed and the snapshot
of a save it ended, once the command has run to its end and not before. -/
def dispatchGiveUpChecks : List Check :=
  let asks (requests : List StateRequest) : EditorM Unit := do
    for request in requests do
      discard <| EditorState.ask request
  let bound (run : Dispatched) := dispatchKeys [("C-c g", invoke "go")] [("go", run)]
  let ran (run : EditorM Unit) : Loop.Keys TestScheme.scheme :=
    bound fun _ => do
      run
      return none
  [{  name :=
        "after a command that closed a window has run to its end, the window's two markers are given up: each refuses noSuchMarker, the other windows' markers still answer, and nothing is in the echo"
      run :=
        pure <|
          let program :
            EditorM (List (Option TextError) × List (Option TextError) × String × Bool) := do
            let state ← threeWindows
            let some closed := state.window? ⟨1⟩ | throw .noSuchMarker
            let some stays := state.window? ⟨2⟩ | throw .noSuchMarker
            let (loop, _) ←
              stepsWith (ran (asks [.removeWindow ⟨1⟩])) ({ state } : TestLoop) (presses "C-c g")
            return (← markerRefusals closed, ← markerRefusals stays, loop.state.echo,
                loop.state.wellFormed && loop.state.windows.map (·.id) == #[⟨0⟩, ⟨2⟩])
          (program.runModel editorModel).1.toOption ==
            some ([some .noSuchMarker, some .noSuchMarker], [none, none], "", true) },
    { name :=
        "after a command that removed a buffer has run to its end, the buffer's text is released: it refuses noSuchText, the other buffers' texts still answer, and nothing is in the echo"
      run :=
        pure <|
          let program : EditorM (List (Option TextError) × String × Bool) := do
            let (state, text) ← hiddenBuffer
            let (loop, _) ←
              stepsWith (ran (asks [.removeBuffer ⟨2⟩])) ({ state } : TestLoop) (presses "C-c g")
            return ([← refusalOf text.read, ← refusalOf (⟨0⟩ : TextId).read,
                  ← refusalOf (⟨1⟩ : TextId).read],
                loop.state.echo, loop.state.wellFormed && loop.state.buffer? ⟨2⟩ == none)
          (program.runModel editorModel).1.toOption ==
            some ([some .noSuchText, none, none], "", true) },
    { name :=
        "a buffer a command removed keeps its empty slot through the loop's pass over the histories, in the step that removed it and in the next event's: the buffers after it keep their ids, the window on one still shows it, and a buffer added afterwards gets an id no buffer had"
      run :=
        pure <|
          -- `hidden`, which no window shows, is in the slot before `other`,
          -- which view 1 shows.
          let middle : TextM EditorState := do
            let state ← EditorState.initial ⟨640, 480⟩
            let hidden ← createText "hidden"
            let text ← createText "other"
            let scroll ← text.mark (.anchor { offset := 0, bias := .before })
            let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
            return {
                state with
                buffers :=
                  state.buffers ++
                    #[some { name := "hidden", text := hidden, history := ← UndoTree.over hidden },
                      some { name := "other", text, history := ← UndoTree.over text }]
                windows := state.windows.push { id := ⟨1⟩, buffer := ⟨2⟩, scroll, selection }
                frame := { state.frame with windows := #[⟨0⟩, ⟨1⟩] } }
          let removing : Dispatched := fun _ => do
            asks [.removeBuffer ⟨1⟩]
            return none
          let adding : Dispatched := fun _ => do
            let text ← createText "new"
            let .ok id ←
              EditorState.ask (.addBuffer "new" text (← UndoTree.over text)) | throw .noSuchText
            EditorState.ask (.message s!"added {id.index}")
            return none
          let keys :=
            dispatchKeys [("C-c g", invoke "go"), ("C-c a", invoke "add")]
              [("go", removing), ("add", adding)]
          let slots (loop : TestLoop) : Array (Option String) × Option String × Bool :=
            (loop.state.buffers.map (·.map (·.name)), (loop.state.target? ⟨1⟩).map (·.buffer.name),
              loop.state.wellFormed)
          let program : EditorM (List (Array (Option String) × Option String × Bool) × String) := do
            let (removed, _) ← stepsWith keys ({ state := ← middle } : TestLoop) (presses "C-c g")
            let (next, _) ← stepsWith keys removed [pressF5]
            let (added, _) ← stepsWith keys next (presses "C-c a")
            return ([slots removed, slots next, slots added], added.state.echo)
          match program.runModel editorModel with
          | (.ok (seen, echo), model) =>
            let kept := (#[some "scratch", none, some "other"], some "other", true)
            seen ==
                [kept, kept,
                  (#[some "scratch", none, some "other", some "new"], some "other", true)] &&
              echo == "added 3" &&
              (model.display.scenes.back?.map fun scene => scene.views.map (shownText model)) ==
                some #[some "", some "other"]
          | (.error _, _) => false },
    { name :=
        "a command that closes a window and removes the buffer it showed gives up both with nothing refused: the markers before the text, and the scene shows the window that is left"
      run :=
        pure <|
          match
            dispatched (ran (asks [.removeWindow ⟨1⟩, .removeBuffer ⟨1⟩])) (presses "C-c g")
              twoBuffers with
          | some ((loop, _), scenes, model) =>
            loop.state.wellFormed && loop.state.echo == "" && model.texts.contents == #[""] &&
              (scenes.back?.map fun scene => (scene.echo, scene.views.map (·.id))) ==
                some ("", #[⟨0⟩])
          | none => false },
    { name :=
        "a window shown another buffer has the markers it had given up, and keeps the ones it was shown with"
      run :=
        pure <|
          let showing : EditorM Unit := do
            let text : TextId := ⟨1⟩
            let scroll ← text.mark (.anchor { offset := 0, bias := .before })
            let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
            asks [.show ⟨0⟩ ⟨1⟩ scroll selection]
          let program : EditorM (List (Option TextError) × List (Option TextError) × String) := do
            let state ← twoBuffers
            let some was := state.window? ⟨0⟩ | throw .noSuchMarker
            let (loop, _) ← stepsWith (ran showing) ({ state } : TestLoop) (presses "C-c g")
            let some now := loop.state.window? ⟨0⟩ | throw .noSuchMarker
            return (← markerRefusals was, ← markerRefusals now, loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some ([some .noSuchMarker, some .noSuchMarker], [none, none], "") },
    { name :=
        "a command that closed a window and removed its buffer and was then refused gave up nothing: the window and the buffer are back, the window's markers and the buffer's text answer, and the scene shows both views"
      run :=
        pure <|
          let failing : Dispatched :=
            failingAfter fun _ => asks [.removeWindow ⟨1⟩, .removeBuffer ⟨1⟩]
          let program : EditorM (List (Option TextError) × String × Bool × String) := do
            let state ← twoBuffers
            let some closed := state.window? ⟨1⟩ | throw .noSuchMarker
            let (loop, _) ← stepsWith (bound failing) ({ state } : TestLoop) (presses "C-c g")
            return (← markerRefusals closed, ← (⟨1⟩ : TextId).read,
                loop.state.wellFormed && loop.state.windows == state.windows &&
                  loop.state.buffer? ⟨1⟩ == state.buffer? ⟨1⟩ &&
                  loop.state.frame == state.frame,
                loop.state.echo)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result == ([none, none], "other", true, "go: refused: bad range") &&
              (model.display.scenes.back?.map fun scene => scene.views.map (shownText model)) ==
                some #[some "", some "other"]
          | (.error _, _) => false },
    { name :=
        "a release the store refuses, of a text the command released itself before it removed the buffer, is in the echo area of the scene, and the buffer is still removed"
      run :=
        pure <|
          let twice : EditorM Unit := do
            (⟨2⟩ : TextId).release
            asks [.removeBuffer ⟨2⟩]
          match dispatched (ran twice) (presses "C-c g") ((·.1) <$> hiddenBuffer) with
          | some ((loop, _), scenes, _) =>
            loop.state.echo == "refused: no such text" && loop.state.buffer? ⟨2⟩ == none &&
              loop.state.wellFormed &&
              scenes.back?.map (·.echo) == some "refused: no such text"
          | none => false },
    { name :=
        "the text of a buffer a command removed is not released while a buffer that is left is over the same text: the text still reads, the view of the buffer that is left shows it, and nothing is in the echo"
      run :=
        pure <|
          -- `alias`, which no window shows, is over the text of `other`,
          -- which view 1 shows.
          let shared : TextM EditorState := do
            let state ← twoBuffers
            let text : TextId := ⟨1⟩
            return { state with
                buffers :=
                  state.buffers.push
                    (some { name := "alias", text, history := ← UndoTree.over text }) }
          let program : EditorM (Option TextError × Array (Option String) × String × Bool) := do
            let (loop, _) ←
              stepsWith (ran (asks [.removeBuffer ⟨2⟩])) ({ state := ← shared } : TestLoop)
                  (presses "C-c g")
            return (← refusalOf (⟨1⟩ : TextId).read, loop.state.buffers.map (·.map (·.name)),
                loop.state.echo, loop.state.wellFormed)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result == (none, #[some "scratch", some "other", none], "", true) &&
              (model.display.scenes.back?.map fun scene =>
                  (scene.echo, scene.views.map (shownText model))) ==
                some ("", #[some "", some "other"])
          | (.error _, _) => false },
    { name :=
        "a marker the store refuses to give up, the selection marker of a window the command gave up itself before it closed the window, is in the echo area of the scene: the window is still closed, and its other marker is still given up"
      run :=
        pure <|
          let program : EditorM (List (Option TextError) × String × Array ViewId × Bool) := do
            let state ← threeWindows
            let some closed := state.window? ⟨1⟩ | throw .noSuchMarker
            let twice : EditorM Unit := do
              closed.selection.text.unmark closed.selection
              asks [.removeWindow ⟨1⟩]
            let (loop, _) ← stepsWith (ran twice) ({ state } : TestLoop) (presses "C-c g")
            return (← markerRefusals closed, loop.state.echo, loop.state.windows.map (·.id),
                loop.state.wellFormed)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result ==
                ([some .noSuchMarker, some .noSuchMarker], "refused: no such marker", #[⟨0⟩, ⟨2⟩],
                  true) &&
              model.display.scenes.back?.map (·.echo) == some "refused: no such marker"
          | (.error _, _) => false },
    { name :=
        "the snapshot of a save is released once a command that ended the save has run to its end, and not before: it still reads after the command that took it and began the save, and refuses noSuchSnapshot after the command that ended it, whether the save wrote the file or was refused, with nothing in the echo"
      run :=
        pure <|
          let program (key : String) :
            EditorM (Option TextError × Option TextError × Option Buffer.Saving × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let some taken := (savingOf begun.state).map (·.snapshot) | throw .noSuchSnapshot
            let held ← refusalOf taken.read
            let (ended, _) ← stepsWith saveKeys begun (presses key)
            return (held, ← refusalOf taken.read, savingOf ended.state, ended.state.echo)
          ["C-c e", "C-c n"].all fun key =>
            ((program key).runModel editorModel).1.toOption ==
              some (none, some .noSuchSnapshot, none, "") },
    { name :=
        "a buffer removed while its save is in flight has the save's snapshot released with its text: each refuses, and nothing is in the echo"
      run :=
        pure <|
          let program : EditorM (Option TextError × Option TextError × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let some taken := (savingOf begun.state).map (·.snapshot) | throw .noSuchSnapshot
            let (removed, _) ← stepsWith saveKeys begun (presses "C-c r")
            return (← refusalOf taken.read, ← refusalOf (⟨2⟩ : TextId).read, removed.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (some .noSuchSnapshot, some .noSuchText, "") },
    { name :=
        "a command that ended a save and was then refused released nothing: the snapshot still reads, and the buffer's file is as it was before the command, with the save in flight and its old stamp"
      run :=
        pure <|
          let program : EditorM (Option TextError × Bool × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let some taken := (savingOf begun.state).map (·.snapshot) | throw .noSuchSnapshot
            let (failed, _) ← stepsWith saveKeys begun (presses "C-c f")
            return (← refusalOf taken.read,
                (savingOf failed.state).isSome &&
                  (failed.state.buffer? ⟨2⟩).map (·.file) == (begun.state.buffer? ⟨2⟩).map (·.file),
                failed.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (none, true, "fail: refused: bad range") },
    { name :=
        "a release of a save's snapshot that the store refuses, because the command released the snapshot itself before it ended the save, is in the echo area of the scene, and the save is still ended"
      run :=
        pure <|
          let program : EditorM (Option Buffer.Saving × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let (ended, _) ← stepsWith saveKeys begun (presses "C-c t")
            return (savingOf ended.state, ended.state.echo)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result == (none, "refused: no such snapshot") &&
              model.display.scenes.back?.map (·.echo) == some "refused: no such snapshot"
          | (.error _, _) => false },
    { name :=
        "after a command that cancelled a prompt has run to its end the minibuffer is given up, though the last scene named a snapshot of its text: its text refuses noSuchText and each of its window's markers refuses, the window's text and markers still answer, and nothing is in the echo; the same after a command that accepted it"
      run :=
        pure <|
          [cancelPrompt, acceptPrompt].all fun close =>
            let keys := ran (discard close)
            let program :
              EditorM
                (Option TextError ×
                  Bool × Option TextError × List (Option TextError) × String × Bool) :=
              do
              let state ← promptedOver "ab"
              let some minibuffer := state.window? ⟨1⟩ | throw .noSuchMarker
              let some window := state.window? ⟨0⟩ | throw .noSuchMarker
              -- A scene of the open prompt first, so that the loop holds a
              -- snapshot of the minibuffer's text when the text is released.
              let (shown, _) ← stepsWith keys ({ state } : TestLoop) [pressF5]
              let (loop, _) ← stepsWith keys shown (presses "C-c g")
              return (← refusalOf minibuffer.scroll.text.read,
                  (← markerRefusals minibuffer).all (·.isSome), ← refusalOf window.scroll.text.read,
                  ← markerRefusals window, loop.state.echo,
                  loop.state.wellFormed && loop.state.prompt == none &&
                    loop.state.windows.map (·.id) == #[⟨0⟩])
            (program.runModel editorModel).1.toOption ==
              some (some .noSuchText, true, none, [none, none], "", true) },
    { name :=
        "a command that accepts a prompt and is then refused gives nothing up: the prompt is open again, its text reads what was typed, its window's markers answer, and nothing is answered"
      run :=
        pure <|
          let keys := bound (failingAfter fun _ => discard acceptPrompt)
          let program : EditorM (Option String × List (Option TextError) × String × Bool × Bool) :=
            do
            let state ← promptedOver "ab"
            let some minibuffer := state.window? ⟨1⟩ | throw .noSuchMarker
            let (loop, steps) ←
              stepsWith keys ({ state } : TestLoop) (.commit "c" :: presses "C-c g")
            return ((← observing minibuffer.scroll.text.read).toOption, ← markerRefusals minibuffer,
                loop.state.echo,
                loop.state.prompt == state.prompt && loop.state.frame.focused == ⟨1⟩ &&
                  loop.state.wellFormed,
                loop.state.answered.isEmpty &&
                  steps.back?.map (·.ended) == some (some (.refused .badRange)))
          (program.runModel editorModel).1.toOption ==
            some (some "abc", [none, none], "go: refused: bad range", true, true) }]

/-- A scheme written for the closed-view checks: the test scheme, with the
views it was stepped for kept beside its state, in the order they first
had a key, and a view it is told is closed dropped from them. -/
def remembering : InputScheme :=
  { State := TestScheme.State × List ViewId
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, if state.2.contains view then state.2 else state.2 ++ [view]), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    closeView := fun view state => (state.1, state.2.filter (· != view)) }

/-- The views `remembering` keeps in a loop's two states of the scheme: the
one after the last key, and the one at rest. -/
def remembered (loop : Loop remembering) : List ViewId × List ViewId :=
  let input : TestScheme.State × List ViewId := loop.input
  let atRest : TestScheme.State × List ViewId := loop.atRest
  (input.2, atRest.2)

/-- The checks of the scheme's notice of a closed view in the loop
(`Editor/Loop.lean`), on the editor's models. -/
def dispatchCloseViewChecks : List Check :=
  let focus : Dispatched := fun _ => do
    discard <| EditorState.ask (.focus ⟨1⟩)
    return none
  let close (call : Call) : EditorM Unit :=
    discard <| EditorState.ask (.removeWindow call.target.window.id)
  let keys : Loop.Keys remembering :=
    { maps := fun _ _ =>
        [Keymap.ofList
            [(ModelTest.keys "C-c 1", invoke "focus"), (ModelTest.keys "C-c x", invoke "close"),
              (ModelTest.keys "C-c f", invoke "fail")]]
      command? := fun name =>
        ([("focus", focus),
                  ("close", fun call => do
                    close call
                    return none),
                  ("fail", failingAfter close)].find?
              (·.1 == name)).map
          (·.2) }
  let program (last : String) : EditorM ((List ViewId × List ViewId) × Array ViewId) := do
    let loop : Loop remembering := { state := ← threeWindows }
    -- The key after the focus moved is view 1's, yields nothing and leaves
    -- nothing pending: the scheme then keeps view 1 in both its states.
    let (loop, _) ← stepsWith keys loop (presses "C-c 1" ++ [pressF5] ++ presses last)
    return (remembered loop, loop.state.windows.map (·.id))
  [{  name :=
        "after a command closed a view, the loop has told its scheme: neither state of the scheme it keeps holds anything for the view, and what they hold for the other views is kept"
      run :=
        pure <|
          ((program "C-c").runModel editorModel).1.toOption ==
              some (([⟨0⟩, ⟨1⟩], [⟨0⟩, ⟨1⟩]), #[⟨0⟩, ⟨1⟩, ⟨2⟩]) &&
            ((program "C-c x").runModel editorModel).1.toOption ==
              some (([⟨0⟩], [⟨0⟩]), #[⟨0⟩, ⟨2⟩]) },
    { name :=
        "a command that closed a view and was then refused closed nothing: the scheme is told of no closed view"
      run :=
        pure <|
          ((program "C-c f").runModel editorModel).1.toOption ==
            some (([⟨0⟩, ⟨1⟩], [⟨0⟩, ⟨1⟩]), #[⟨0⟩, ⟨1⟩, ⟨2⟩]) }]

/-- What `noticing` was told of a view. -/
inductive Notice where
  /-- The view is the minibuffer's. -/
  | minibuffer (view : ViewId)
  /-- The view is closed. -/
  | closed (view : ViewId)
  deriving DecidableEq, Repr

/-- A scheme written for the minibuffer-notice checks: the test scheme, with
what it was told kept beside its state, in the order it was told. -/
def noticing : InputScheme :=
  { State := TestScheme.State × List Notice
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, state.2), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    closeView := fun view state => (state.1, state.2 ++ [.closed view])
    openMinibuffer := fun view state => (state.1, state.2 ++ [.minibuffer view]) }

/-- What `noticing` was told, in a loop's two states of the scheme: the one
after the last key, and the one at rest. -/
def noticed (loop : Loop noticing) : List Notice × List Notice :=
  let input : TestScheme.State × List Notice := loop.input
  let atRest : TestScheme.State × List Notice := loop.atRest
  (input.2, atRest.2)

/-- The checks of the scheme's notice of the minibuffer's view in the loop
(`Editor/Loop.lean`), on the editor's models. -/
def dispatchMinibufferNoticeChecks : List Check :=
  let asks : EditorM Unit := discard <| prompt "Name: " asked
  let ran (run : EditorM Unit) : Dispatched := fun _ => do
    run
    return none
  let keys : Loop.Keys noticing :=
    { maps := fun _ _ =>
        [Keymap.ofList
            [(ModelTest.keys "C-c a", invoke "ask"), (ModelTest.keys "C-c f", invoke "fail"),
              (ModelTest.keys "C-c y", invoke "accept"), (ModelTest.keys "C-c s", invoke "swap"),
              (ModelTest.keys "C-c n", invoke "idle")]]
      command? := fun name =>
        ([("ask", ran asks), ("fail", failingAfter fun _ => asks), ("idle", ran (pure ())),
                  ("accept", ran (discard acceptPrompt)),
                  ("swap",
                    ran do
                      discard cancelPrompt
                      asks)].find?
              (·.1 == name)).map
          (·.2) }
  let told (typed : String) : Option ((List Notice × List Notice) × Option ViewId) :=
    let program : EditorM ((List Notice × List Notice) × Option ViewId) := do
      let loop : Loop noticing := { state := ← EditorState.initial ⟨640, 480⟩ }
      let (loop, _) ← stepsWith keys loop (presses typed)
      return (noticed loop, loop.state.minibufferView?)
    (program.runModel editorModel).1.toOption
  -- What the scheme was told once a prompt was asked for and `next` then ran
  -- one more command from the loop with the prompt open, with the
  -- minibuffer's view after that command and how it ended.
  let toldAfter (next : Loop noticing → EditorM (Option (Loop.Stepped noticing))) :
    Option ((List Notice × List Notice) × Option ViewId × Option Loop.Ending) :=
    let program :
      EditorM (Option ((List Notice × List Notice) × Option ViewId × Option Loop.Ending)) := do
      let loop : Loop noticing := { state := ← EditorState.initial ⟨640, 480⟩ }
      let (loop, _) ← stepsWith keys loop (presses "C-c a")
      return (← next loop).map fun stepped =>
          (noticed stepped.loop, stepped.loop.state.minibufferView?, stepped.ended)
    (program.runModel editorModel).1.toOption.join
  let typing (typed : String) (loop : Loop noticing) : EditorM (Option (Loop.Stepped noticing)) :=
    (·.2.back?) <$> stepsWith keys loop (presses typed)
  let both (notices : List Notice) := (notices, notices)
  [{  name :=
        "after a command that asked for a prompt, the loop has told its scheme that the new view is the minibuffer's, once, in both states of the scheme it keeps"
      run := pure (told "C-c a" == some (both [.minibuffer ⟨1⟩], some ⟨1⟩)) },
    { name :=
        "a key's command that runs to its end while the prompt stays open opened nothing: the scheme is told of the minibuffer's view by the command that opened it alone, so both its states still hold the one notice after a command that does nothing, and after one that asks again and is refused as a value"
      run :=
        pure <|
          ["C-c n", "C-c a"].all fun typed =>
            toldAfter (typing typed) == some (both [.minibuffer ⟨1⟩], some ⟨1⟩, some .finished) },
    { name :=
        "a job's command that runs to its end while the prompt stays open opened nothing: after its delivery both states of the scheme still hold the one notice"
      run :=
        pure
          (toldAfter (fun loop => return some (← loop.deliver keys "job" (pure ()))) ==
            some (both [.minibuffer ⟨1⟩], some ⟨1⟩, some .finished)) },
    { name :=
        "a command that asked for a prompt and was then refused opened nothing: the scheme is told nothing"
      run := pure (told "C-c f" == some (both [], none)) },
    { name :=
        "after the command that accepted the prompt, the loop has told both states of its scheme that the minibuffer's view is closed"
      run := pure (told "C-c a C-c y" == some (both [.minibuffer ⟨1⟩, .closed ⟨1⟩], none)) },
    { name :=
        "a command that closes one prompt and asks for another tells the scheme the first view is closed and then that the second is the minibuffer's"
      run :=
        pure
          (told "C-c a C-c s" ==
            some (both [.minibuffer ⟨1⟩, .closed ⟨1⟩, .minibuffer ⟨2⟩], some ⟨2⟩)) }]

/-- The history of the buffer `buffer` in `loop`'s state, as the loop keeps
it. -/
def treeOf {scheme : InputScheme} (loop : Loop scheme) (buffer : Nat := 0) : EditorM UndoTree := do
  let some held := loop.state.buffer? ⟨buffer⟩ | throw .noSuchText
  return held.history

/-- The checks of undo from a command in the loop (`Editor/Api.lean`,
`Editor/Loop.lean`), on the editor's models: a move in the history a key's
command made is the loop's after the step, and a boundary set by a command
that does not run to its end is rolled back with its edits; and, with the
scheme `switching`, two of whose keys begin and end an insert session of
the focused view, that what is edited in a session is one step of the
history. -/
def dispatchUndoChecks : List Check :=
  let undo : Dispatched := fun call => do
    discard <| call.target.window.buffer.undo
    return none
  let redo : Dispatched := fun call => do
    discard <| call.target.window.buffer.redo
    return none
  let keys :=
    dispatchKeys [("C-c s", invoke "stamp"), ("C-c u", invoke "undo"), ("C-c r", invoke "redo")]
      [("stamp", stamp), ("undo", undo), ("redo", redo)]
  -- What a step of a loop over `switching` is handed: beside the keys that
  -- begin and end a session, a key that stamps, one whose command edits and
  -- is refused, one that edits the second buffer, and one that focuses the
  -- second window.
  let sessions : Loop.Keys switching :=
    switchingKeys
      [("C-c s", invoke "stamp"), ("C-c f", invoke "fail"), ("C-c o", invoke "elsewhere"),
        ("C-c w", invoke "window")]
      [("stamp", stamp), ("fail", boom),
        ("elsewhere", fun _ => do
          discard <| (⟨1⟩ : BufferId).insertAt 0 "x"
          return none),
        ("window", fun _ => do
          discard <| (⟨1⟩ : ViewId).focus
          return none)]
  [{  name :=
        "a key's command that undoes keeps the move after the step: the text is the one before the last key's edit, the buffer's tree has nothing pending and no node made for the move, and the next key's redo gives the edit back"
      run :=
        pure <|
          let program : EditorM (List String × List Nat × Bool) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- The first step records what the buffer was made holding as a
            -- step of the history, and the second the stamp.
            let (loop, _) ← stepsWith keys loop ([pressF5] ++ presses "C-c s")
            let stamped ← focusedOf loop
            let (loop, _) ← stepsWith keys loop (presses "C-c u")
            let undone ← focusedOf loop
            let afterUndo ← undone.buffer.text.read
            let (again, _) ← stepsWith keys loop (presses "C-c r")
            let redone ← focusedOf again
            return ([afterUndo, ← redone.buffer.text.read],
                [stamped.buffer.history.nodes.size, undone.buffer.history.nodes.size,
                  redone.buffer.history.nodes.size],
                !undone.buffer.history.pending && loop.state.echo == "" &&
                  undone.buffer.history.current != stamped.buffer.history.current &&
                  redone.buffer.history.current == stamped.buffer.history.current)
          (program.runModel editorModel).1.toOption ==
            some (["abcd", "aC-c sd"], [3, 3, 3], true) },
    { name :=
        "a command that edits, sets a boundary in the history, edits again and then does not run to its end, refused or interrupted, is rolled back whole: the text and the window's selection are those before it, the echo area says how it ended and nothing of a move, the history has no step for it and nothing to redo, and the next key's edit is undone as one step"
      run :=
        pure <|
          -- An edit that moves the selection, the boundary, and an edit in
          -- the group the boundary opened.
          let bounded (call : Call) : EditorM Unit := do
            Loop.insert call.target "boom"
            discard <| call.target.window.buffer.closeGroup
            call.target.buffer.text.insert 0 "x"
          let spun : Dispatched := fun call => do
            bounded call
            for _ in [0:1000] do
              discard <| call.target.buffer.text.revision
            return none
          let keys :=
            dispatchKeys
              [("C-c b", invoke "bounded"), ("C-c l", invoke "spun"), ("C-c s", invoke "stamp")]
              [("bounded", failingAfter bounded), ("spun", spun), ("stamp", stamp)]
          -- `lowering` is what arrives after the command: the interrupt key
          -- that stopped it, taken off the queue, which lowers the flag.
          let program (failing : String) (lowering : List Received) :
            EditorM ((String × Array SelectionRange × String) × Bool × Bool × String × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- The first step records what the buffer was made holding as a
            -- step of the history.
            let (loop, _) ← stepsWith keys loop [pressF5]
            let nodes := (← focusedOf loop).buffer.history.nodes.size
            let (loop, _) ← stepsWith keys loop (presses failing)
            let target ← focusedOf loop
            let failed := (← target.buffer.text.read, ← cursorsOf loop, loop.state.echo)
            let stepless :=
              target.buffer.history.nodes.size == nodes && !target.buffer.history.pending
            let redone ← target.buffer.history.redo Origin.user
            let loop ← takes keys loop lowering
            let (loop, _) ← stepsWith keys loop (presses "C-c s")
            let target ← focusedOf loop
            let after ← target.buffer.text.read
            let some _ ← target.buffer.history.undo | throw .noInverse
            return (failed, stepless, redone.isNone, after, ← target.buffer.text.read)
          let rolledBack (failing echo : String) (lowering : List Received) (watch : WatchModel) :
            Bool :=
            ((program failing lowering).runModel { editorModel with watch }).1.toOption ==
              some (("abcd", #[⟨1, 3⟩], echo), true, true, "aC-c sd", "abcd")
          rolledBack "C-c b" "bounded: refused: bad range" [] {} &&
            rolledBack "C-c l" "spun: interrupted" [interruptArrives] { arrivesAfter := some 20 } },
    { name :=
        "a command run while an edit is pending in the open group, which sets a boundary and is then refused, is rolled back to the point of the group it began at: the text is the one before it, no node was made, the edit from before it is still pending, and it is one step at the next boundary, which an undo takes back and a redo gives again"
      run :=
        pure <|
          let bounded : Dispatched :=
            failingAfter fun call => do
              Loop.insert call.target "boom"
              discard <| call.target.window.buffer.closeGroup
              call.target.buffer.text.insert 0 "x"
          let keys := dispatchKeys [] [("bounded", bounded)]
          let program : EditorM ((String × String × Nat × Bool) × Nat × String × String) := do
            -- No scene was published since the buffer was made holding
            -- `abcd`, so that edit is in the open group when the command
            -- starts.
            let ran ← Loop.run keys (← holding "abcd" #[⟨1, 3⟩]) (invoke "bounded") []
            let some left := ran.state.buffer? ⟨0⟩ | throw .noSuchText
            let failed :=
              (← left.text.read, ran.state.echo, left.history.nodes.size, left.history.pending)
            let (state, _) ← ran.state.recordHistories
            let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
            let some undone ← buffer.history.undo Origin.user | throw .noInverse
            let before ← buffer.text.read
            let some _ ← undone.tree.redo Origin.user | throw .noInverse
            return (failed, buffer.history.nodes.size, before, ← buffer.text.read)
          (program.runModel editorModel).1.toOption ==
            some (("abcd", "bounded: refused: bad range", 1, true), 2, "", "abcd") },
    { name :=
        "a command that sets a boundary, moves over the step it closed, there and back, and is then refused moved in the history: the move is not taken back, the echo area says so, and the tree the loop keeps is the one the command left, so the next key's undo takes the step back"
      run :=
        pure <|
          let crossing : Dispatched :=
            failingAfter fun call => do
              let buffer := call.target.window.buffer
              call.target.buffer.text.insert 0 "x"
              discard <| buffer.closeGroup
              discard <| buffer.undo
              discard <| buffer.redo
          let keys :=
            dispatchKeys [("C-c x", invoke "crossing"), ("C-c u", invoke "undo")]
              [("crossing", crossing), ("undo", undo)]
          let program : EditorM (String × String × String × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith keys loop ([pressF5] ++ presses "C-c x")
            let failed ← (← focusedOf loop).buffer.text.read
            let echo := loop.state.echo
            let (loop, _) ← stepsWith keys loop (presses "C-c u")
            return (failed, echo, ← (← focusedOf loop).buffer.text.read, loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some
              ("xabcd", "crossing: refused: bad range; the command moved in the history", "abcd",
                "") },
    { name :=
        "two keys' edits made while the scheme reports the focused view as in an insert session, and then the key that ends the session, are one step of the history: no node is made inside the session, one is made when it ends, one undo gives the text from before the session and one redo the text after it"
      run :=
        pure <|
          let program : EditorM (List Nat × List Bool × List String) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- The first step records what the buffer was made holding as a
            -- step of the history.
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-b C-c s C-c s")
            let inside ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-e")
            let ended ← treeOf loop
            let typed ← ended.text.read
            let some undone ← ended.undo Origin.user | throw .noInverse
            let back ← ended.text.read
            let some _ ← undone.tree.redo Origin.user | throw .noInverse
            return ([before.nodes.size, inside.nodes.size, ended.nodes.size],
                [before.pending, inside.pending, ended.pending], [typed, back, ← ended.text.read])
          (program.runModel editorModel).1.toOption ==
            some ([2, 2, 3], [false, true, false], ["aC-c sC-c sd", "abcd", "aC-c sC-c sd"]) },
    { name :=
        "the same two keys' edits with no view in an insert session are two steps of the history, each closed after its event"
      run :=
        pure <|
          let program : EditorM (List Nat × Bool) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            let between ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            let after ← treeOf loop
            return ([before.nodes.size, between.nodes.size, after.nodes.size],
                between.pending || after.pending)
          (program.runModel editorModel).1.toOption == some ([2, 3, 4], false) },
    { name :=
        "a buffer is modified in the scene published after the first edit of an insert session, while its history has gained no node"
      run :=
        pure <|
          let program : EditorM (Nat × Nat) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (loop, _) ← stepsWith sessions loop (presses "C-b")
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            return (before.nodes.size, (← treeOf loop).nodes.size)
          match program.runModel editorModel with
          | (.ok (before, inside), model) =>
            before == inside &&
              -- One scene a key: the key that begins the session, the
              -- prefix of the stamping sequence, and the key that stamps.
              model.display.scenes.map
                  (·.views.map (·.status.any (·.face == ModeLine.modifiedFace))) ==
                #[#[false], #[false], #[true]]
          | (.error _, _) => false },
    { name :=
        "a command that is refused inside an insert session is rolled back to the text from before it, with the session's earlier edit still pending and no node made; a later edit and the end of the session then make one step of both, which one undo takes back"
      run :=
        pure <|
          let program : EditorM ((String × String × Nat × Bool) × Nat × String × String) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith sessions loop ([pressF5] ++ presses "C-b C-c s C-c f")
            let failed ← treeOf loop
            let rolled := (← failed.text.read, loop.state.echo, failed.nodes.size, failed.pending)
            let (loop, _) ← stepsWith sessions loop (presses "C-c s C-e")
            let ended ← treeOf loop
            let typed ← ended.text.read
            let some _ ← ended.undo Origin.user | throw .noInverse
            return (rolled, ended.nodes.size, typed, ← ended.text.read)
          (program.runModel editorModel).1.toOption ==
            some (("aC-c sd", "fail: refused: bad range", 2, true), 3, "aC-c sC-c sd", "abcd") },
    { name :=
        "an insert session in which nothing was edited makes no step of the history: the tree has no node more and nothing pending"
      run :=
        pure <|
          let program : EditorM (List Nat × Bool) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-b")
            let inside ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-e")
            let ended ← treeOf loop
            return ([before.nodes.size, inside.nodes.size, ended.nodes.size],
                inside.pending || ended.pending)
          (program.runModel editorModel).1.toOption == some ([2, 2, 2], false) },
    { name :=
        "of two buffers, the one shown by a view in an insert session has its group left open, and the one no such view shows has its group closed after each event"
      run :=
        pure <|
          let program : EditorM (List Nat × List Bool) := do
            let loop : Loop switching := { state := ← twoBuffers }
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let (held, other) := (← treeOf loop, ← treeOf loop 1)
            let (loop, _) ← stepsWith sessions loop (presses "C-b C-c s C-c o")
            let (heldAfter, otherAfter) := (← treeOf loop, ← treeOf loop 1)
            return ([held.nodes.size, other.nodes.size, heldAfter.nodes.size,
                  otherAfter.nodes.size],
                [heldAfter.pending, otherAfter.pending])
          (program.runModel editorModel).1.toOption == some ([1, 1, 1, 2], [true, false]) },
    { name :=
        "of two windows on one buffer, one in an insert session, the buffer's group is left open after an edit made through the other window"
      run :=
        pure <|
          let program : EditorM (List Nat × List Bool × Option ViewId) := do
            let loop : Loop switching := { state := ← threeWindows }
            let (loop, _) ← stepsWith sessions loop (presses "C-b C-c w")
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            let after ← treeOf loop
            return ([before.nodes.size, after.nodes.size], [before.pending, after.pending],
                some loop.state.frame.focused)
          (program.runModel editorModel).1.toOption == some ([1, 1], [false, true], some ⟨1⟩) }]

/-- A report as a command of the checks says it in the echo area. -/
def reportText (report : InputScheme.Report) : String :=
  reprStr report

/-- The command `say` of the report checks: it says the report its call
carries in the echo area (`reportText`). -/
def say : Dispatched := fun call => do
  message (reportText call.report)
  return none

/-- The checks of what a command is told of its view
(`Editor/Command/Call.lean`, `Editor/Loop.lean`), on the editor's models,
with the scheme `switching`, whose report a key's invocation switches, and
a command that says the report it was called with. -/
def dispatchReportChecks : List Check :=
  let handed (commands : List (String × Dispatched) := []) : Loop.Keys switching :=
    switchingKeys [("C-s", invoke "say")] (("say", say) :: commands)
  let echoes (text : String) (commands : List (String × Dispatched) := []) :
    Option (Array String) :=
    (switched (EditorState.initial ⟨640, 480⟩) text (handed := handed commands)).map
      (·.2.1.map (·.echo))
  [{  name :=
        "a command is called with what the scheme reports of its view: the default before any key switched it, and, for the key whose invocation switches the report, the switched report, since the command sees the scheme's state after its key; the next key's command is called with it too"
      run :=
        pure
          (echoes "C-s C-m C-s" [("mark", say)] ==
              some #[reportText {}, reportText markedReport, reportText markedReport] &&
            reportText markedReport != reportText {}) },
    { name :=
        "a command that is refused leaves the scheme at rest: the next key's command is called with the report from before the failed key, and not with the one that key would have switched to"
      run :=
        pure <|
          let failing : Dispatched := fun _ => throw .badRange
          match echoes "C-m C-b C-s" [("begin", failing)], echoes "C-m C-b C-s" with
          | some #[_, failed, after], some #[_, _, begun] =>
            failed == "begin: refused: bad range" && after == reportText markedReport &&
              begun == reportText { session := true }
          | _, _ => false },
    { name :=
        "a command run by its name, which no key yielded, is called with what the scheme reports of the focused view in the state the scheme is in"
      run :=
        pure <|
          let program : EditorM (String × String) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let fresh := (← loop.runNamed (handed []) "say").loop.state.echo
            let (loop, _) ← stepsWith (handed []) loop (presses "C-m")
            return (fresh, (← loop.runNamed (handed []) "say").loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (reportText {}, reportText markedReport) },
    { name :=
        "under a scheme that says nothing of a view a command is called with the default report, by a key and by its name"
      run :=
        pure <|
          let keys := dispatchKeys [("C-s", invoke "say")] [("say", say)]
          let program : EditorM (String × String) := do
            let loop : TestLoop := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (loop, _) ← stepsWith keys loop (presses "C-s")
            return (loop.state.echo, (← loop.runNamed keys "say").loop.state.echo)
          (program.runModel editorModel).1.toOption == some (reportText {}, reportText {}) }]

/-- The checks of a command that gives up (`giveUp`, `Editor/Api.lean`;
`Editor/Loop.lean`, "Running an invocation"), on the editor's models, with
the scheme `switching`, whose report a key's invocation switches, and
commands written here: the loop rolls the command back, says its reason in
the echo area with no `refused:`, and puts the scheme back in its state at
rest. -/
def dispatchCommandGivesUpChecks : List Check :=
  let reason := "nothing to do here"
  -- Edits the text, moves the selection, and then gives up.
  let quitter : Dispatched := fun call => do
    Loop.insert call.target "typed"
    giveUp reason
  let handed (commands : List (String × Dispatched) := []) : Loop.Keys switching :=
    switchingKeys [("C-s", invoke "say"), ("C-g", invoke "quitter")]
      ([("say", say), ("quitter", quitter)] ++ commands)
  [{  name :=
        "a key whose command edits and then gives up: the text and the selection are those before the command, the history has no step for it, the echo area reads the command's name and its reason with no refused, and the step says the command gave up"
      run :=
        pure <|
          let program :
            EditorM (String × Array SelectionRange × String × Bool × Bool × Option Loop.Ending) :=
            do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- A key that runs nothing: its publish records the fixture's own
            -- insertion as a step, so the count read here is the one to keep.
            let (loop, _) ← stepsWith (handed []) loop [pressF5]
            let some before := loop.state.focusedTarget? | throw .noSuchText
            let (loop, steps) ← stepsWith (handed []) loop (presses "C-g")
            let some target := loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, (← target.selection).ranges, loop.state.echo,
                target.buffer.history.nodes.size == before.buffer.history.nodes.size,
                target.buffer.history.pending, (steps.back?).bind (·.ended))
          (program.runModel editorModel).1.toOption ==
            some
              ("abcd", #[⟨1, 3⟩], s!"quitter: {reason}", true, false,
                some (Loop.Ending.gaveUp reason)) },
    { name :=
        "a command that gives up leaves the scheme at rest: the next key's command is told the report from before the key that gave up, and not the one that key would have switched to; the same key with a command that runs to its end switches it"
      run :=
        pure <|
          let giving : Dispatched := fun _ => giveUp reason
          let echoes (commands : List (String × Dispatched)) : Option (Array String) :=
            (switched (EditorState.initial ⟨640, 480⟩) "C-m C-b C-s" (handed :=
                  handed commands)).map
              (·.2.1.map (·.echo))
          match echoes [("begin", giving)], echoes [] with
          | some #[_, gave, after], some #[_, _, begun] =>
            gave == s!"begin: {reason}" && after == reportText markedReport &&
              begun == reportText { session := true }
          | _, _ => false },
    { name :=
        "a command that has its buffer keep a value and then gives up leaves the editor state as it was: the buffer keeps no value under the name"
      run :=
        pure <|
          let keeping : Dispatched := fun call => do
            discard <| call.target.window.buffer.setValue "count" (.nat 7)
            giveUp reason
          let kept : Dispatched := fun call => do
            discard <| call.target.window.buffer.setValue "count" (.nat 7)
            return none
          let bound (name : String) : Loop.Keys switching :=
            switchingKeys [("C-k", invoke name)] [("keeping", keeping), ("kept", kept)]
          let after (name : String) : Option (Option Value × String) :=
            (switched (EditorState.initial ⟨640, 480⟩) "C-k" (handed := bound name)).map
              fun (loop, _, _) => (loop.state.value? ⟨0⟩ "count", loop.state.echo)
          after "keeping" == some (none, s!"keeping: {reason}") &&
            after "kept" == some (some (.nat 7), "") },
    { name :=
        "a command that gives up inside an insert session leaves the session's earlier edit pending in the open group, with the text as the session left it: only what the command itself made is taken back"
      run :=
        pure <|
          let typing : Dispatched := fun call => do
            Loop.insert call.target "one"
            return none
          let program : EditorM (String × Bool × Nat × String) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let handed := handed [("begin", typing)]
            let (loop, _) ← stepsWith handed loop (presses "C-b C-g")
            let some target := loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, target.buffer.history.pending,
                target.buffer.history.nodes.size, loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some ("one", true, 1, s!"quitter: {reason}") },
    { name :=
        "a command that gives up, run by its name, ends the same way: rolled back, with its name and its reason in the echo area, and the step says it gave up"
      run :=
        pure <|
          let program : EditorM (String × String × Option Loop.Ending) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let stepped ← loop.runNamed (handed []) "quitter"
            let some target := stepped.loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, stepped.loop.state.echo, stepped.ended)
          (program.runModel editorModel).1.toOption ==
            some ("abcd", s!"quitter: {reason}", some (Loop.Ending.gaveUp reason)) }]

/-- The checks of a command that breaks off (`breakOff`, `Editor/Api.lean`;
`Editor/Loop.lean`, "Running an invocation"), on the editor's models, with
the scheme `switching`, whose report a key's invocation switches, and
commands written here: the loop keeps what the command did, says its reason
in the echo area with no `refused:`, and puts the scheme back in its state
at rest. -/
def dispatchCommandBreaksOffChecks : List Check :=
  let reason := "far enough"
  -- Edits the text, which moves the selection, and then breaks off or, with
  -- no reason, runs to its end.
  let editing (reason : Option String) : Dispatched := fun call => do
    Loop.insert call.target "typed"
    match reason with
    | some reason =>
      breakOff reason
    | none =>
      return none
  let handed (commands : List (String × Dispatched) := []) : Loop.Keys switching :=
    switchingKeys [("C-s", invoke "say"), ("C-g", invoke "stopper"), ("C-f", invoke "finisher")]
      ([("say", say), ("stopper", editing (some reason)), ("finisher", editing none)] ++ commands)
  -- What the key `key` leaves from a text with a selection: the text, the
  -- selection, the echo area, the history's nodes and whether an edit is
  -- pending in it, and how the step says the command ended.
  let left (key : String) :
    Option (String × Array SelectionRange × String × Nat × Bool × Option Loop.Ending) :=
    let program :
      EditorM (String × Array SelectionRange × String × Nat × Bool × Option Loop.Ending) := do
      let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
      let (loop, steps) ← stepsWith (handed []) loop (presses key)
      let some target := loop.state.focusedTarget? | throw .noSuchText
      return (← target.buffer.text.read, (← target.selection).ranges, loop.state.echo,
          target.buffer.history.nodes.size, target.buffer.history.pending,
          (steps.back?).bind (·.ended))
    (program.runModel editorModel).1.toOption
  [{  name :=
        "a key whose command edits and then breaks off: the text, the selection and the history are those the same command leaves when it runs to its end, which are not those from before it; the echo area reads the command's name and its reason with no refused, and the step says the command broke off"
      run :=
        pure <|
          match left "C-g", left "C-f" with
          | some (text, ranges, echo, nodes, pending, ended),
            some (finished, placed, said, steps, unclosed, how) =>
            text == finished && text != "abcd" && ranges == placed && ranges != #[⟨1, 3⟩] &&
              nodes == steps &&
              pending == unclosed &&
              echo == s!"stopper: {reason}" &&
              said.isEmpty &&
              ended == some (Loop.Ending.brokeOff reason) &&
              how == some .finished
          | _, _ => false },
    { name :=
        "a command that breaks off leaves the scheme at rest: the next key's command is told the report from before the key that broke off, and not the one that key would have switched to; the same key with a command that runs to its end switches it"
      run :=
        pure <|
          let breaking : Dispatched := fun _ => breakOff reason
          let echoes (commands : List (String × Dispatched)) : Option (Array String) :=
            (switched (EditorState.initial ⟨640, 480⟩) "C-m C-b C-s" (handed :=
                  handed commands)).map
              (·.2.1.map (·.echo))
          match echoes [("begin", breaking)], echoes [] with
          | some #[_, broke, after], some #[_, _, begun] =>
            broke == s!"begin: {reason}" && after == reportText markedReport &&
              begun == reportText { session := true }
          | _, _ => false },
    { name :=
        "a command that has its buffer keep a value, asks for an invocation to be run after it and then breaks off leaves the editor state it reached: the buffer keeps the value, and the step hands the invocation back"
      run :=
        pure <|
          let keeping : Dispatched := fun call => do
            discard <| call.target.window.buffer.setValue "count" (.nat 7)
            Editor.invoke { command := "say" }
            breakOff reason
          let bound : Loop.Keys switching :=
            switchingKeys [("C-k", invoke "keeping")] [("keeping", keeping)]
          let program : EditorM (Option Value × String × Array (Array String)) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (loop, steps) ← stepsWith bound loop (presses "C-k")
            return (loop.state.value? ⟨0⟩ "count", loop.state.echo,
                steps.map fun step => step.answered.map (·.command))
          (program.runModel editorModel).1.toOption ==
            some (some (.nat 7), s!"keeping: {reason}", #[#["say"]]) },
    { name :=
        "a command that breaks off, run by its name, ends the same way: what it did stays, its name and its reason are in the echo area, and the step says it broke off"
      run :=
        pure <|
          let program : EditorM (String × String × Option Loop.Ending) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let stepped ← loop.runNamed (handed []) "stopper"
            let some target := stepped.loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, stepped.loop.state.echo, stepped.ended)
          match (program.runModel editorModel).1.toOption, left "C-f" with
          | some (text, echo, ended), some (finished, _) =>
            text == finished && echo == s!"stopper: {reason}" &&
              ended == some (Loop.Ending.brokeOff reason)
          | _, _ => false }]

/-- The checks of a command that has another run inside it (`runCommand`,
`Editor/Api.lean`; `Editor/Loop.lean`, "A command run inside another"), on
the editor's models, with commands written here: the command it names is
the one a key's invocation of that name runs, looked up in what the step
was handed. -/
def dispatchRunCommandChecks : List Check :=
  -- Runs the command its first argument names inside itself, with its own
  -- call but for the arguments, and says whether there was one.
  let outer : Dispatched := fun call => do
    let .str name :: arguments := call.arguments | giveUp "no command named"
    let ran ← runCommand name { call with arguments }
    message s!"{name} ran: {ran}"
    return none
  let write : Config.Write := { owner := .config, store := "cell", value := .nat 1 }
  let commands : List (String × Dispatched) :=
    [("outer", outer), ("stamp", stamp), ("writer", fun _ => return some write),
      ("quitter", fun call => do
        Loop.insert call.target "typed"
        giveUp "nothing to do here")]
  let handed : Loop.Keys TestScheme.scheme :=
    dispatchKeys
      [("C-s", { command := "outer", arguments := [.str "stamp", .nat 7] }),
        ("C-m", { command := "outer", arguments := [.str "missing"] }),
        ("C-w", { command := "outer", arguments := [.str "writer"] }),
        ("C-q", { command := "outer", arguments := [.str "quitter"] }), ("C-t", invoke "stamp")]
      commands
  -- What the key `key` leaves from a text with a cursor: the text, the echo
  -- area, the history's nodes, and how the step says the command ended.
  let left (key : String) : Option (String × String × Nat × Option Loop.Ending) :=
    let program : EditorM (String × String × Nat × Option Loop.Ending) := do
      let loop : TestLoop := { state := ← holding "ab" #[⟨2, 2⟩] }
      let (loop, _) ← stepsWith handed loop [pressF5]
      let (loop, steps) ← stepsWith handed loop (presses key)
      let some target := loop.state.focusedTarget? | throw .noSuchText
      return (← target.buffer.text.read, loop.state.echo, target.buffer.history.nodes.size,
          (steps.back?).bind (·.ended))
    (program.runModel editorModel).1.toOption
  [{  name :=
        "a command that has the command of a name run inside it runs the one a key's invocation of that name runs, with the call it hands it, as part of itself: what the two did is one step of the history, and the asking command goes on after it"
      run :=
        pure <|
          match left "C-s", left "C-t" with
          | some (text, echo, nodes, ended), some (alone, _, steps, _) =>
            text == "ab7 C-s" && alone == "abC-t" && echo == "stamp ran: true" && nodes == steps &&
              ended == some .finished
          | _, _ => false },
    { name :=
        "a name no command is registered under is answered false, and nothing runs: the asking command goes on"
      run :=
        pure <|
          (left "C-m").map (fun (text, echo, _, ended) => (text, echo, ended)) ==
            some ("ab", "missing ran: false", some .finished) },
    { name :=
        "a command run inside another that gives up gives the asking command up: both are rolled back, and the reason is said under the asking command's name"
      run :=
        pure <|
          (left "C-q").map (fun (text, echo, _, ended) => (text, echo, ended)) ==
            some ("ab", "outer: nothing to do here", some (.gaveUp "nothing to do here")) },
    { name :=
        "a command run inside another that asks for a store to be written gives the asking command up, with the sentence the loop makes of its name: only a command the loop runs has its write written back"
      run :=
        pure <|
          !(Loop.writesInside "writer").isEmpty &&
            (left "C-w").map (fun (text, echo, _, ended) => (text, echo, ended)) ==
              some
                ("ab", s!"outer: {Loop.writesInside "writer"}",
                  some (.gaveUp (Loop.writesInside "writer"))) }]

/-- The checks of key dispatch in the loop (`Editor/Loop.lean`), on the
editor's models: keys through the scheme and the commands they run,
rollback, the interrupt, the slow-command log, a command's state requests,
what the loop gives up after a command, a command that gives up, a command
that breaks off, a command that has another run inside it, the scheme's
notice of a closed view, undo from a command, and what a command is told of
its view. -/
def dispatchChecks : List Check :=
  dispatchKeyChecks ++ dispatchRollbackChecks ++ dispatchInterruptChecks ++ dispatchSlowChecks ++
    dispatchStateChecks ++
    twoWindowChecks ++
    dispatchGiveUpChecks ++
    dispatchCloseViewChecks ++
    dispatchMinibufferNoticeChecks ++
    dispatchUndoChecks ++
    dispatchReportChecks ++
    dispatchCommandGivesUpChecks ++
    dispatchCommandBreaksOffChecks ++
    dispatchRunCommandChecks

end ModelTest
