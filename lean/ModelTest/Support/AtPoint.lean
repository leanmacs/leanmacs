import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.AtPointContract
import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Completion.Later
import Editor.Completion.Styles
import Editor.Completion.Words
import Editor.Config.Registry
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.File
import Editor.GeneratedView
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Language
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Program
import Editor.ProjectMode
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Text.Model
import Editor.Workspace
import ModelTest.Support.Evil
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models

/-!
# Model tests: support: AtPoint

The fixture of the checks of completion at point: the at-point sources and the
drivers over the evil fixture they run on, the contract's runner of at-point
sources, and what a scene and the state show of a session at point. Shared by
several test modules under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

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

/-- The at-point source `line` of the loop checks: the region from the start
of the cursor's line to the cursor, read from the text, completed from the
source `say`. -/
def lineAtPoint (sources : List Completion.Named := [.source "say"]) : Completion.AtPoint :=
  { name := "line"
    ask := fun spot => do
      let .ok target ← spot.view.target | return none
      let start ← target.buffer.text.motion .lineStart spot.offset
      return some { start, stop := spot.offset, sources } }

/-- The at-point source `last2` of the loop checks: the two bytes before the
cursor, or from the text's start, completed from the source `alphas`. -/
def lastTwoAtPoint : Completion.AtPoint :=
  .fixed "last2" fun spot =>
    some { start := spot.offset - 2, stop := spot.offset, sources := [.source "alphas"] }

/-- The completion sources the loop checks complete from, by name. -/
def atPointSources : List Completion.Source :=
  [.ofTexts "say" "say" #["say hello", "say hi"], .ofTexts "pick" "pick" #["wq", "w"],
    .ofTexts "alphas" "alpha" #["alpha", "alpine"], .ofTexts "threes" "three" #["a1", "a2", "a3"],
    Completion.Words.source]

/-- What a step of the at-point loop checks is handed: `evilHanded`, told
that a buffer's chain is `chain`, that the at-point sources are `atPoints`
and the shipped `words`, and that the sources are `atPointSources`, by name
and by category. -/
def atPointHanded (chain : Array String) (atPoints : List Completion.AtPoint)
    (more : Array Config.Registration := #[]) : Loop.Keys Vim.Default.scheme :=
  let handed := evilHanded more
  { handed with
    registered :=
      { handed.registered with
        atPoint := fun name => (atPoints ++ [Completion.AtPoint.words]).find? (·.name == name)
        atPointNames := fun _ _ => chain
        sources := fun name => atPointSources.find? (·.name == name)
        categorySources := fun category =>
          (atPointSources.filter (·.category == category)).toArray.map (·.name) } }

/-- A driver of the at-point loop checks over the fixture `fixture`
(`evilState`), handed `atPointHanded chain atPoints`, with the job `words`
registered. -/
def atPointDriver (fixture : String) (chain : Array String) (atPoints : List Completion.AtPoint)
    (more : Array Config.Registration := #[]) : Option EvilDriver :=
  let (contents, head) := barred fixture
  let jobs (name : String) : Option (List Argument → Work) :=
    if name == Completion.Words.job then some (Completion.answering Completion.Words.gather)
    else none
  (Loop.Driver.over (atPointHanded chain atPoints more) jobs (evilState contents head)
      editorModel).toOption

/-- Whether the last scene `driver` published shows the candidate list's
view. -/
def listShown (driver : EvilDriver) : Bool :=
  match driver.loop.state.candidateList, driver.model.display.scenes.back? with
  | some drawn, some scene => scene.views.any (·.id == drawn.view)
  | _, _ => false

/-- The texts the candidate list's last sheet shows, of the open session. -/
def sessionRows (driver : EvilDriver) : Array String :=
  (driver.loop.state.atPoint.map fun session => session.sheet.rows.map (·.text)).getD #[]

/-- The open session's choice in `driver`. -/
def sessionChosen (driver : EvilDriver) : Option Nat :=
  driver.loop.state.atPoint.bind (·.candidates.chosen)

/-- Whether the text model refuses the marker `id`: given up. -/
def markerGone (driver : EvilDriver) (id : MarkerId) : Bool :=
  match ((id.text.marker id).runModel driver.model.texts).1 with
  | .error .noSuchMarker => true
  | _ => false

/-- `driver` fed a press of each key `text` names, and the steps the feeds
handed back, in order. -/
def evilSteps (driver : EvilDriver) (text : String) :
    EvilDriver × Array (Loop.Stepped Vim.Default.scheme) :=
  (keys text).foldl
    (fun (driver, steps) key =>
      let (driver, stepped) := driver.feed { event := press key, stamp := 0 }
      (driver, steps ++ stepped.toOption.toArray))
    (driver, #[])

/-- `driver` once every post is delivered and every pending job finished,
oldest first, a post before a job's end; bounded. -/
def evilDrained (driver : EvilDriver) : EvilDriver :=
  (List.range 64).foldl
    (fun driver _ =>
      match driver.posting[0]? with
      | some job => (driver.posted job.id).1
      | none =>
        match driver.pending[0]? with
        | some job => (driver.finish job.id).1
        | none => driver)
    driver

/-- The at-point source `dots` of the trigger checks: an empty region at
the cursor, completed from the source `pick`, asked by itself when `.` is
typed. -/
def dotsAtPoint : Completion.AtPoint :=
  {
    Completion.AtPoint.fixed "dots" fun spot =>
      some { start := spot.offset, stop := spot.offset, sources := [.source "pick"] } with
    triggers := ['.'] }

end ModelTest
