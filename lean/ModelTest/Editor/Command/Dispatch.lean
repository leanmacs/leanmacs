import Editor.Api
import Editor.Clipboard
import Editor.Clipboard.Model
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Command.Registry
import Editor.Compile.Contribution
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.File
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.TabBar
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Value
import Editor.Watch.Model
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Loop
import ModelTest.Support.Models
import ModelTest.Support.Modes
import ModelTest.Support.States

/-!
# Model tests: `Editor/Command/Dispatch.lean`

The model tests of `Editor/Command/Dispatch.lean`: `guardChecks`,
`modeEnterChecks` and `dispatchRegistryChecks`. `guardChecks` are of the
loop's guard, `modeEnterChecks` of entering a mode and
`dispatchRegistryChecks` of the loop's answers to the questions to the
registry and config (`Loop.Registered.answer`), all in
`Editor/Command/Dispatch.lean`. The root module `ModelTest` runs them; its
module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A command that makes a text of each of `labels`, in order, and returns
how many it made. -/
def makesEach (labels : List String) : EditorM Nat := do
  for label in labels do
    makes label
  return labels.length

/-- `command` as the loop runs one (`EditorM.dispatched`), told nothing of
the registry, from an editor state with nothing in it: how it ended. The
commands of the guard checks make no state request, so the state it left is
not looked at. -/
def guarded {α : Type} (command : EditorM α) : EditorM (Guarded α) :=
  return (← command.dispatched {} EditorState.none).1

/-- The checks of the guard of a dispatched command
(`Editor/Command/Dispatch.lean`, "The guard") on the editor's models: it
stops at its next request once the interrupt flag is up. They run the
transformation the loop runs, on commands that make no state request. -/
def guardChecks : List Check :=
  [{  name :=
        "with the interrupt flag down a guarded command finishes with its value, and leaves the models as the command alone does"
      run := do
        let command := makesEach ["1", "2", "3"]
        let (bare, alone) := command.runModel countingModel
        let (ended, model) := (guarded command).runModel countingModel
        return resulted bare == .inr 3 && resulted ended == .inr (.finished 3) &&
            model.texts.contents == alone.texts.contents &&
            model.display.scenes == alone.display.scenes &&
            model.watch == alone.watch },
    { name :=
        "a guarded command that is refused is not itself refused: the refusal comes back as its outcome, with what the command did before it"
      run := do
        let command : EditorM Nat := do
          makes "1"
          (⟨7⟩ : TextId).insert 0 "x"
          makesEach ["2"]
        let (ended, model) := (guarded command).runModel countingModel
        return resulted ended == .inr (.refused .noSuchText) && model.texts.contents == #["1"] },
    { name :=
        "with the interrupt flag up before it starts, a guarded command makes no request and is interrupted, and the flag stays up"
      run := do
        let (ended, model) :=
          (guarded (makesEach ["1", "2"])).runModel (countingModel { arrived := 1 })
        return resulted ended == .inr .interrupted && model.texts.contents == #[] &&
            model.watch.clock == 0 &&
            model.watch.arrived == 1 },
    { name :=
        "when the interrupt key arrives as a guarded command is about to make its fourth request, the command has made exactly three and makes no more"
      run := do
        let (ended, model) :=
          (guarded (makesEach ["1", "2", "3", "4", "5"])).runModel
            (countingModel { arrivesAfter := some 3 })
        return resulted ended == .inr .interrupted && model.texts.contents == #["1", "2", "3"] &&
            model.watch.clock == 3 },
    { name :=
        "a command that catches every refusal of every request cannot go on past an interrupt: nothing is thrown for it to catch"
      run := do
        let stubborn : EditorM Nat := do
          let mut made := 0
          for label in ["1", "2", "3", "4"] do
            try
              makes label
              made := made + 1
            catch _ =>
              made := made + 100
          return made
        let (ended, model) := (guarded stubborn).runModel (countingModel { arrivesAfter := some 2 })
        return resulted ended == .inr .interrupted && model.texts.contents == #["1", "2"] &&
            model.watch.clock == 2 },
    { name :=
        "a guarded command that makes no request finishes with its value though the interrupt flag is up: there is no request to stop it at"
      run := do
        let (ended, model) :=
          (guarded (pure 7 : EditorM Nat)).runModel (countingModel { arrived := 1 })
        return resulted ended == .inr (.finished 7) && model.watch.arrived == 1 },
    { name :=
        "a clipboard request is guarded like a text request: with the interrupt flag up before a clipboard write the write is not made and the clipboard holds what it held, and with the flag down the same command writes"
      run := do
        let command : EditorM Unit := discard <| Clipboard.write "copied"
        let (ended, model) := (guarded command).runModel (countingModel { arrived := 1 })
        let (finished, wrote) := (guarded command).runModel countingModel
        return resulted ended == .inr .interrupted && model.clipboard.held == none &&
            model.watch.clock == 0 &&
            resulted finished == .inr (.finished ()) &&
            wrote.clipboard.held == some "copied" &&
            wrote.watch.clock == 1 },
    { name :=
        "a fuzzy request is guarded like a text request: with the interrupt flag up before a ranking the request is not made, and with the flag down the same command is answered"
      run := do
        let candidates := #["wq", "edit", "w"]
        let command : EditorM (Array Nat) := Fuzzy.rank "w" candidates
        let (ended, model) := (guarded command).runModel (countingModel { arrived := 1 })
        let (finished, asked) := (guarded command).runModel countingModel
        return resulted ended == .inr .interrupted && model.watch.clock == 0 &&
            resulted finished == .inr (.finished (FuzzyModel.rank "w" candidates)) &&
            asked.watch.clock == 1 }]

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

/-- The checks of the loop's answers to the questions to the registry and
config (`Loop.Registered.answer`, `Editor/Command/Dispatch.lean`), and of
where its arms for them stand towards the guard. -/
def dispatchRegistryChecks : List Check :=
  [{  name :=
        "a question to the registry is not guarded: with the interrupt flag up from the first request, a dispatched command that asks which ex names are bound finishes with the names the loop was told"
      run := do
        let asking : EditorM (Array String) := RegistryRequest.ask .exNames
        let (ended, model) :=
          (asking.dispatched { exNames := #["w"] } EditorState.none).runModel
            (countingModel { arrived := 1 })
        return resulted ended == .inr (.finished #["w"], EditorState.none) &&
            model.watch.clock == 0 },
    { name :=
        "a dispatched command that asks for a path's language is answered the name of the language the loop's table chooses for the path, or none"
      run :=
        let program : EditorM (Guarded (Option String × Option String) × EditorState) := do
          (do
                  return (← RegistryRequest.ask (.languageOf "/p/main.rs"),
                      ← RegistryRequest.ask (.languageOf "/p/notes.txt"))).dispatched
              { languages := Language.shipped.toList } (← twoBuffers)
        pure <|
          match (program.runModel editorModel).1 with
          | .ok (.finished answer, _) => answer == (some "rust", none)
          | _ => false }]

end ModelTest
