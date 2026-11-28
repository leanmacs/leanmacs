import Editor.Config.Registry
import Editor.Fold
import Editor.Folds
import Editor.InputScheme.Test
import Editor.Jumps
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Package
import Editor.Role
import Editor.Test.Driver
import Editor.Test.Editing
import Editor.Test.Hosted
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Prompts
import ModelTest.Check

/-!
# Model tests: `Editor/Folds.lean`

The model tests of `Editor/Folds.lean`: `foldToggleChecks` and
`foldRegenerateChecks`, on a hosted driver over a test package whose
`setup` is the core's `Folds.setup`, so `fold-toggle` and the folds mode are
registered as the package `fold-commands` registers them, with the commands
of the checks: `fill` makes the buffer `sections` of `foldText` with
`foldRanges` declared and its major mode `sections`, which fills `toggle`
with `section-toggle` (it says `toggled`), and shows it; `fill-bare` makes
the buffer `bare` of the same text and ranges and no mode; `fill-two` and
`regenerate` declare and redeclare the ranges of the regeneration check;
and `at` puts the cursor at the byte its argument names. The active keymaps
are the registry's (`Config.Registry.activeMaps`), so the `toggle` role's
key reaches the folds mode first in a buffer with foldable ranges. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The text of the fold checks: eight rows of three bytes, `a0` to `e6`,
and an empty one; row `r` starts at `3 * r`. -/
def foldText : String :=
  "a0\nb1\nb2\nb3\nc4\nd5\ne6\n"

/-- A foldable range keyed `key` over the rows `first` to `last` of
`foldText`, folded or not. -/
def foldRows (key : String) (first last : Nat) (folded : Bool) : Foldable :=
  { start := 3 * first, stop := 3 * last + 2, key, text := s!"[{key}]", folded }

/-- The ranges of the buffer `sections`: `outer` over rows 1 to 3 and
`inner` over row 2, both folded, `open` over row 4, unfolded, and `shut`
over row 5, folded. -/
def foldRanges : Array Foldable :=
  #[foldRows "outer" 1 3 true, foldRows "inner" 2 2 true, foldRows "open" 4 4 false,
    foldRows "shut" 5 5 true]

/-- The mode `sections`, which fills `toggle` with `section-toggle`. -/
def foldSections : Mode :=
  { name := "sections", roles := [(Role.toggle, "section-toggle")] }

/-- The text of the regeneration check before it regenerates: `a` at row 1,
`b` at row 3. -/
def foldTwoText : String :=
  "x\na1\ny\nb1\nz\n"

/-- The text of the regeneration check once regenerated: `b` at row 1, `a`
at row 3 and `c` at row 4. -/
def foldAgainText : String :=
  "new\nb1\nmid\na1\nc1\n"

/-- Makes the buffer `name` of `text` with `ranges` declared, shows it in the
call's window and sets its major mode `major`, when given. -/
def fillFolded (name text : String) (ranges : Array Foldable) (major : Option String)
    (call : Call) : EditorM Unit := do
  let .ok id ← createBuffer name text | return
  discard <| id.setFolds ranges
  let view := call.target.window.id
  discard <| view.show id
  if let some major := major then
    discard <| view.setMajorMode major

/-- The test package of the fold checks: the core's `Folds.setup`, and the
commands and the mode of the module docs. -/
def foldsTestPackage : Package :=
  { name := "folds-test"
    setup := do
      Folds.setup
      commandWith "fill" (fillFolded "sections" foldText foldRanges (some foldSections.name))
      commandWith "fill-bare" (fillFolded "bare" foldText foldRanges none)
      commandWith "fill-two"
          (fillFolded "two" foldTwoText
            #[{ start := 2, stop := 4, key := "a", text := "[a]", folded := true },
              { start := 7, stop := 9, key := "b", text := "[b]", folded := false },
              { start := 10, stop := 11, key := "gone", text := "[gone]", folded := false }]
            none)
      commandWith "regenerate" fun call => do
          let id := call.target.window.buffer
          let text := call.target.buffer.text
          text.delete 0 (← text.byteLength)
          text.insert 0 foldAgainText
          discard <|
              id.setFolds
                #[{ start := 4, stop := 6, key := "b", text := "[b]", folded := false },
                  { start := 11, stop := 13, key := "a", text := "[a]", folded := true },
                  { start := 14, stop := 16, key := "c", text := "[c]", folded := true }]
      commandWith "section-toggle" fun _ => message "toggled"
      commandWith "at" fun call =>
          match call.arguments with
          | [.nat offset] => Jumps.placeCursor call.target.window.id offset
          | _ => pure ()
      defineMode foldSections }

/-- The driver of the fold checks over the test package's registry, on a
buffer that holds `foldText`; `none` if making the state was refused. -/
def foldDriver : Option TestDriver :=
  let registry := hostedRegistry #[foldsTestPackage]
  let keys := hostedKeys registry
  (Loop.Driver.over { keys with maps := registry.activeMaps TestScheme.scheme } (fun _ => none)
      (holding foldText #[⟨0, 0⟩]) editorModel).toOption

/-- `driver` once `name` has run with `arguments` (`hostedRan`). -/
def foldRan (driver : TestDriver) (name : String) (arguments : List Argument := []) : TestDriver :=
  hostedRan driver { command := name, arguments }

/-- `driver` once the `toggle` role's key has been pressed. -/
def foldToggled (driver : TestDriver) : TestDriver :=
  hostedSettled (fedTo driver (rolePresses Role.toggle)).1

/-- The fold checks' driver once `fill` (or `fill`'s `name`) has shown its
buffer and the cursor is at the byte `offset`. -/
def foldAt (offset : Nat) (fill : String := "fill") : Option TestDriver :=
  foldDriver.map fun driver => foldRan (foldRan driver fill) "at" [.nat offset]

/-- Whether each range of the buffer of view 0 of `driver` is folded, by
key, in its order. -/
def foldStates (driver : TestDriver) : Option (List (String × Bool)) := do
  let target ← driver.loop.state.target? ⟨0⟩
  return target.buffer.folds.toList.map fun range => (range.key, range.folded)

/-- The placeholder texts of the folds of view 0 in the last scene `driver`
published. -/
def sceneFoldTexts (driver : TestDriver) : Option (List String) :=
  driver.model.display.scenes.back?.bind fun scene =>
    (scene.views.find? (·.id == ⟨0⟩)).map (·.folds.toList.map (·.text))

/-- The content and the revision of the text of view 0's buffer in
`driver`. -/
def foldTextNow (driver : TestDriver) : Option (String × Nat) := do
  let target ← driver.loop.state.target? ⟨0⟩
  let read : TextM (String × Nat) := do
    return (← target.buffer.text.read, ← target.buffer.text.revision)
  (read.runModel driver.model.texts).1.toOption

/-- The head of the cursor of view 0 of `driver`. -/
def foldHead (driver : TestDriver) : Option Nat :=
  (selectionOf driver).bind fun selection => selection.ranges[0]?.map (·.head)

/-- The checks of `fold-toggle` (`Editor/Folds.lean`, "Toggling" and "Off
every foldable range"), on the fold checks' driver in the buffer
`sections`. -/
def foldToggleChecks : List Check :=
  [{  name :=
        "toggle on a folded range unfolds it, its placeholder gone from the next scene, and the buffer's text and revision stay as they were"
      run :=
        pure <|
          match foldAt 16 with
          | none => false
          | some driver =>
            let toggled := foldToggled driver
            (foldStates toggled).bind (·.lookup "shut") == some false &&
              sceneFoldTexts driver == some ["[outer]", "[shut]"] &&
              sceneFoldTexts toggled == some ["[outer]"] &&
              foldTextNow toggled == foldTextNow driver &&
              (foldTextNow driver).map (·.1) == some foldText },
    { name :=
        "toggle on an unfolded foldable range folds it and puts the cursor at its start, and toggle again unfolds it, the text and revision unchanged throughout"
      run :=
        pure <|
          match foldAt 13 with
          | none => false
          | some driver =>
            let folded := foldToggled driver
            let unfolded := foldToggled folded
            (foldStates folded).bind (·.lookup "open") == some true && foldHead folded == some 12 &&
              sceneFoldTexts folded == some ["[outer]", "[open]", "[shut]"] &&
              (foldStates unfolded).bind (·.lookup "open") == some false &&
              sceneFoldTexts unfolded == some ["[outer]", "[shut]"] &&
              foldTextNow folded == foldTextNow driver &&
              foldTextNow unfolded == foldTextNow driver },
    { name :=
        "on nested folded ranges toggle unfolds the outer first, showing the inner as a placeholder, and then the inner"
      run :=
        pure <|
          match foldAt 7 with
          | none => false
          | some driver =>
            let once := foldToggled driver
            let twice := foldToggled once
            (foldStates once).map (·.take 2) == some [("outer", false), ("inner", true)] &&
              sceneFoldTexts once == some ["[inner]", "[shut]"] &&
              (foldStates twice).map (·.take 2) == some [("outer", false), ("inner", false)] &&
              sceneFoldTexts twice == some ["[shut]"] },
    { name :=
        "off every foldable range toggle runs the command the buffer's own mode fills toggle with, and with none says there is no fold at the cursor"
      run :=
        pure <|
          (foldAt 0).map (fun driver => (foldToggled driver).loop.state.echo) == some "toggled" &&
            (foldAt 0 "fill-bare").map (fun driver => (foldToggled driver).loop.state.echo) ==
              some "fold-toggle: no fold at the cursor" &&
            (foldAt 0).bind (fun driver => foldStates (foldToggled driver)) ==
              some (foldRanges.toList.map fun range => (range.key, range.folded)) }]

/-- The checks of declaring a buffer's foldable ranges again
(`Editor/Fold.lean`, "Declaring again keeps the toggles"), on the fold
checks' driver: `a` declared folded and `b` unfolded, both toggled, then the
buffer regenerated with `a` and `b` at each other's rows, each declared as
at first, a new `c` declared folded, and `gone` no longer declared. -/
def foldRegenerateChecks : List Check :=
  [{  name :=
        "regenerating a buffer keeps the toggled state of each range whose key survives, a new key takes its declared state, a dropped key is gone, and the scene follows"
      run :=
        pure <|
          match foldAt 2 "fill-two" with
          | none => false
          | some driver =>
            let toggled := foldToggled (foldRan (foldToggled driver) "at" [.nat 7])
            let regenerated := foldRan toggled "regenerate"
            foldStates toggled == some [("a", false), ("b", true), ("gone", false)] &&
              foldStates regenerated == some [("b", true), ("a", false), ("c", true)] &&
              sceneFoldTexts regenerated == some ["[b]", "[c]"] &&
              (foldTextNow regenerated).map (·.1) == some foldAgainText }]

end ModelTest
