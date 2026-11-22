import AtPoint
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
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Loop.Driver
import Editor.State
import Editor.Test.Driver
import Editor.Test.Editing
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Text
import Editor.Text.Model

/-!
# Model tests: support: Words

The fixture of the checks of the `at-point` package (`AtPointTest.atPointChecks`,
`wordsChecks`): a driver of the test scheme, over the models, with keys of
the checks' own on the commands the package registers (`AtPoint.package`,
`AtPoint/Compiled.lean`) and its source `words`, its job and its at-point
source `words` beside the sources the checks complete from; the
contract's runner of at-point sources; and what a check reads of the
driver. It holds no checks of its own.

The checks drive no key of a shipped scheme: which keys the Vim scheme puts
at-point's commands on is evil's (`vimDefaultChecks`). Here each command is
on a key that prints nothing, under the test scheme
(`Editor/InputScheme/Test.lean`), with the kit's editing commands and keys
(`Editor/Test/Editing.lean`), which also hold the fixture notation (a
cursor written as a bar) and what a check reads of a driver (`keysFed`,
`shownOf`):

- **The keys** (`atPointBindings`): `C-SPC` on `at-point-complete`, `C-n`
  on `at-point-next`, `C-p` on `at-point-previous`, `TAB` on `at-point-tab`,
  `S-TAB` on `at-point-backtab`, `RET` on `at-point-return` and `C-g` on
  `at-point-quit`, with the kit's editing keys but `RET`.
- **The commands a scheme's package registers that at-point runs by name**,
  `insert-newline` and `insert-tab`, are stand-ins written here
  (`fallbackStandIns`), registered under those names as text.
- **Listings are matched and drawn by the core's own style and display**
  (`Completion.Matching.unregistered`, `Completion.Displaying.unregistered`),
  the defaults of a step's keys, where the core's tests hand the style and
  display written for them: no check here reads a range, a face or a row.
-/

namespace AtPointTest

open Editor
open Editor.Test

/-- The contract's runner of at-point sources on the editor's models
(`Completion.AtPointContract.Runner`): the at-point source asked at
`offset`, on `occasion`, from the one window of a state of one buffer over a
text holding `text` (`barState`), dispatched with no registry. `some` with
what it answered and whether the editor state and the texts the store holds
were left as they were; `none` when it was refused, or the fixture could not
be made. -/
def atPointRunner : Completion.AtPointContract.Runner := fun text offset occasion atPoint =>
  match (TextM.lift (barState text offset)).runModel editorModel with
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

/-- Stand-ins for the two commands a scheme's package registers that
at-point runs by name with no session open: `insert-newline`, a line break
at the selections, and `insert-tab`, a tab there. -/
def fallbackStandIns : Array Config.Registration :=
  #[{ name := "insert-newline", action := .call fun call => call.target.insertLineBreak },
    { name := "insert-tab", action := .call fun call => call.target.insertAtSelections "\t" }]

/-- The keys of at-point's checks under the test scheme: the kit's editing
keys but `RET`, and each of at-point's commands a scheme's table of the
state where typing is text binds, on a key that prints nothing. -/
def atPointBindings : List (String × Invocation) :=
  editingBindings.filter (·.1 != "RET") ++
    [("C-SPC", invoke AtPoint.completeName), ("C-n", invoke AtPoint.nextName),
      ("C-p", invoke AtPoint.previousName), ("TAB", invoke AtPoint.tabName),
      ("S-TAB", invoke AtPoint.backtabName), ("RET", invoke AtPoint.returnName),
      ("C-g", invoke AtPoint.quitName)]

/-- What a step of at-point's checks is handed: the keys of
`atPointBindings`; told that a buffer's chain is `chain`, that the at-point
sources are `atPoints` and the shipped `words`, and that the sources are
`shippedAtPointSources`, by name and by category; the commands the
`at-point` package registers, `fallbackStandIns` and those of `more`, each
under the name it is registered under, and the kit's editing commands. A
command of `more` runs in place of one of the same name, as the registry's
latest entry of a name does. -/
def shippedAtPointHanded (chain : Array String) (atPoints : List Completion.AtPoint)
    (more : Array Config.Registration := #[]) : Loop.Keys TestScheme.scheme :=
  let sources := shippedAtPointSources
  let commands := AtPoint.package.registered.commands ++ fallbackStandIns ++ more
  { maps := fun _ _ =>
      [Keymap.ofList (atPointBindings.map fun (text, invocation) => (keys text, invocation))]
    command? := fun name =>
      match commands.findRev? (·.name == name) with
      | some { action := .call run, .. } =>
        some fun call => do
          run call
          return none
      | _ => (editingDispatched.find? (·.1 == name)).map (·.2)
    registered :=
      { atPoint := fun name => (atPoints ++ [Completion.AtPoint.words]).find? (·.name == name)
        atPointNames := fun _ _ => chain
        sources := fun name => sources.find? (·.name == name)
        categorySources := fun category =>
          (sources.filter (·.category == category)).toArray.map (·.name) } }

/-- A driver of at-point's checks over the fixture `fixture`
(`barred`, `barState`), handed `shippedAtPointHanded chain atPoints more`,
with the job `words` registered. -/
def shippedAtPointDriver (fixture : String) (chain : Array String)
    (atPoints : List Completion.AtPoint) (more : Array Config.Registration := #[]) :
    Option TestDriver :=
  let jobs (name : String) : Option (List Argument → Work) :=
    if name == Completion.Words.job then some (Completion.answering Completion.Words.gather)
    else none
  let (contents, head) := barred fixture
  (Loop.Driver.over (shippedAtPointHanded chain atPoints more) jobs (barState contents head)
      editorModel).toOption

/-- The open session's choice in `driver`. -/
def sessionChosen (driver : TestDriver) : Option Nat :=
  driver.loop.state.atPoint.bind (·.candidates.chosen)

/-- Whether the text model refuses the marker `id`: given up. -/
def markerGone (driver : TestDriver) (id : MarkerId) : Bool :=
  match ((id.text.marker id).runModel driver.model.texts).1 with
  | .error .noSuchMarker => true
  | _ => false

end AtPointTest
