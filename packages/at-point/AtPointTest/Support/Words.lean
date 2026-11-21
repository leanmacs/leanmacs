import AtPoint.Compiled
import AtPoint.Words
import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.AtPointContract
import Editor.Completion.Later
import Editor.Config.Packages
import Editor.InputScheme.Vim.Default
import Editor.Job
import Editor.Loop.Driver
import Editor.State
import Editor.Test.Keys
import Editor.Test.Models
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree

/-!
# Model tests: support: Words

The fixture of the checks of the `at-point` package (`AtPointTest.atPointChecks`,
`wordsChecks`): a driver of the Vim scheme that ships, over the models,
running the commands the package registers (`AtPoint.package`,
`AtPoint/Compiled.lean`) and its source `words`, its job and its at-point
source `words` beside the sources the checks complete from; the
contract's runner of at-point sources; and what a check reads of the
driver. It holds no checks of its own.

These were the core's test support (`ModelTest/Support/Evil.lean`,
`ModelTest/Support/AtPoint.lean` and this module, `ModelTest.…`) while
completion at point was a module of the core. A package's tests may not
import the core's own test modules (`docs/design/packages.md`, "What a
package may import"), so what the package's checks use of them is copied
here, each definition under its name, with two changes:

- **Evil's commands are not run.** Evil's package is the core's and is no
  module a package may import, so a step is handed the at-point package's
  commands, a stand-in for evil's `insert` (`insertStandIn`, which does
  nothing) and the commands a check adds. The keys of the checks are `i`
  and then at-point's: the Vim scheme enters insert state at `i` by itself,
  and evil's `insert` only reshapes the selection for that state, which no
  check reads.
- **Listings are matched and drawn by the core's own style and display**
  (`Completion.Matching.unregistered`, `Completion.Displaying.unregistered`),
  the defaults of a step's keys, where the core's tests hand the style and
  display written for them: no check here reads a range, a face or a row.
-/

namespace AtPointTest

open Editor
open Editor.Test

/-- A fixture of the checks, which writes the cursor into the text as a
bar: the text without the bar, and the bar's byte offset. A fixture with no
bar has its cursor at 0. -/
def barred (fixture : String) : String × Nat :=
  match fixture.splitOn "|" with
  | [before, after] => (before ++ after, before.utf8ByteSize)
  | _ => (fixture, 0)

/-- `contents` with a bar written before the character at the byte offset
`offset`, or at its end. An offset that is no character's start, and none
past the end, writes no bar, so a fixture's expectation does not match. -/
def withBar (contents : String) (offset : Nat) : String :=
  let (shown, walked) :=
    contents.foldl
      (fun (shown, walked) char =>
        ((if walked == offset then shown.push '|' else shown).push char, walked + char.utf8Size))
      ("", 0)
  if walked == offset then shown.push '|' else shown

/-- The driver the checks run: one over the Vim scheme that ships. -/
abbrev EvilDriver :=
  Loop.Driver Vim.Default.scheme

/-- A state of the checks: one buffer, `scratch`, over a text made holding
`contents`, so that nothing is pending in its history, and one window on
it, focused, in a frame of 640 by 480, whose selection is one cursor at the
byte offset `head`, of the shape the Vim scheme that ships reports of a
view before any key. -/
def evilState (contents : String) (head : Nat) : TextM EditorState := do
  let text ← createText contents
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let shape := (Vim.Default.scheme.report Vim.Default.scheme.init ⟨0⟩).shape
  let selection ← text.mark (.selection { ranges := #[⟨head, head⟩], shape })
  let history ← UndoTree.over text
  return {
      buffers := #[some { name := "scratch", text, history }]
      windows := #[{ id := ⟨0⟩, buffer := ⟨0⟩, scroll, selection }]
      frame := { size := ⟨640, 480⟩, windows := #[⟨0⟩], focused := ⟨0⟩ } }

/-- `driver` fed a press of each key the key string `text` names, in
order. -/
def evilFed (driver : EvilDriver) (text : String) : EvilDriver :=
  (keys text).foldl (fun driver key => (driver.feed { event := press key, stamp := 0 }).1) driver

/-- The selection of the view `view` of `driver`, as the text model has
it. -/
def evilSelection (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option Selection := do
  let target ← driver.loop.state.target? view
  (target.selection.runModel driver.model.texts).1.toOption

/-- What the view `view` of `driver` shows, as a fixture writes it: its
buffer's text with a bar at the head of its selection's primary range. -/
def evilShown (driver : EvilDriver) (view : ViewId := ⟨0⟩) : String :=
  match driver.loop.state.target? view, evilSelection driver view with
  | some target, some selection =>
    match (driver.model.texts.texts[target.buffer.text.index]?).join,
      selection.ranges[selection.primary]? with
    | some content, some range => withBar content.contents range.head
    | _, _ => "no text"
  | _, _ => "no view"

/-- The contract's runner of at-point sources on the editor's models
(`Completion.AtPointContract.Runner`): the at-point source asked at
`offset`, on `occasion`, from the one window of a state of one buffer over a
text holding `text` (`evilState`), dispatched with no registry. `some` with
what it answered and whether the editor state and the texts the store holds
were left as they were; `none` when it was refused, or the fixture could not
be made. -/
def atPointRunner : Completion.AtPointContract.Runner := fun text offset occasion atPoint =>
  match (TextM.lift (evilState text offset)).runModel editorModel with
  | (.error _, _) => none
  | (.ok start, model) =>
    let asking : EditorM (Guarded (Option Completion.Region) × EditorState) :=
      (atPoint.ask { view := ⟨0⟩, offset, occasion }).dispatched {} start
    match asking.runModel model with
    | (.ok (.finished answer, after), left) =>
      some (answer, after == start && left.texts.contents == model.texts.contents)
    | _ => none

/-- The completion sources the checks complete from, by name, beside the
shipped `words`: `say` and `pick`. -/
def atPointSources : List Completion.Source :=
  [.ofTexts "say" "say" #["say hello", "say hi"], .ofTexts "pick" "pick" #["wq", "w"]]

/-- The completion sources at-point's checks complete from: `atPointSources`
and the shipped `words`. -/
def shippedAtPointSources : List Completion.Source :=
  atPointSources ++ [Completion.Words.source]

/-- The stand-in for evil's `insert`, which the Vim scheme's `i` runs: a
command that does nothing. The scheme enters insert state at the key
itself; evil's command only reshapes the selection for it. -/
def insertStandIn : Config.Registration :=
  { name := "insert", action := .call fun _ => pure () }

/-- What a step of at-point's checks is handed: told that a buffer's chain
is `chain`, that the at-point sources are `atPoints` and the shipped
`words`, and that the sources are `shippedAtPointSources`, by name and by
category; the commands the `at-point` package registers, `insertStandIn`
and those of `more`, each under the name it is registered under. A command
of `more` runs in place of one of the same name, as the registry's latest
entry of a name does. -/
def shippedAtPointHanded (chain : Array String) (atPoints : List Completion.AtPoint)
    (more : Array Config.Registration := #[]) : Loop.Keys Vim.Default.scheme :=
  let sources := shippedAtPointSources
  let commands := AtPoint.package.registered.commands ++ #[insertStandIn] ++ more
  { command? := fun name =>
      match commands.findRev? (·.name == name) with
      | some { action := .call run, .. } =>
        some fun call => do
          run call
          return none
      | _ => none
    registered :=
      { atPoint := fun name => (atPoints ++ [Completion.AtPoint.words]).find? (·.name == name)
        atPointNames := fun _ _ => chain
        sources := fun name => sources.find? (·.name == name)
        categorySources := fun category =>
          (sources.filter (·.category == category)).toArray.map (·.name) } }

/-- A driver of at-point's checks over the fixture `fixture`
(`evilState`), handed `shippedAtPointHanded chain atPoints more`, with the
job `words` registered. -/
def shippedAtPointDriver (fixture : String) (chain : Array String)
    (atPoints : List Completion.AtPoint) (more : Array Config.Registration := #[]) :
    Option EvilDriver :=
  let jobs (name : String) : Option (List Argument → Work) :=
    if name == Completion.Words.job then some (Completion.answering Completion.Words.gather)
    else none
  let (contents, head) := barred fixture
  (Loop.Driver.over (shippedAtPointHanded chain atPoints more) jobs (evilState contents head)
      editorModel).toOption

/-- The open session's choice in `driver`. -/
def sessionChosen (driver : EvilDriver) : Option Nat :=
  driver.loop.state.atPoint.bind (·.candidates.chosen)

/-- Whether the text model refuses the marker `id`: given up. -/
def markerGone (driver : EvilDriver) (id : MarkerId) : Bool :=
  match ((id.text.marker id).runModel driver.model.texts).1 with
  | .error .noSuchMarker => true
  | _ => false

end AtPointTest
