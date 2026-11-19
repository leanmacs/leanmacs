import Editor.Api
import Editor.AtPoint
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Completion.Fake
import Editor.Completion.Styles
import Editor.Config.Registry
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.File
import Editor.InputScheme.Vim.Default
import Editor.Language
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Program
import Editor.ProjectMode
import Editor.Scene
import Editor.State
import Editor.Test.Models
import Editor.Test.States
import Editor.Text
import Editor.Text.Model
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.AtPoint
import ModelTest.Support.Evil

/-!
# Model tests: `Editor/AtPoint.lean`

The model tests of `Editor/AtPoint.lean`: `atPointChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of asking for completion at point (`Editor/Api.lean`,
"Completion at point", `Editor/AtPoint.lean`), on the evil driver over the
models. -/
def atPointChecks : List Check :=
  let second : Completion.AtPoint :=
    .fixed "second" fun spot =>
      some { start := spot.offset, stop := spot.offset, sources := [.source "pick"] }
  let atPoints :=
    [Completion.AtPoint.silent "silent", second, Completion.Fake.AtPoint.refusing "refusing"]
  [{  name :=
        "the first at-point source of the chain that answers is used, and the later ones are not asked"
      run :=
        pure <|
          match atPointDriver "|" #["silent", "second", "refusing"] atPoints,
            atPointDriver "|" #["silent", "refusing"] atPoints with
          | some first, some refused =>
            let opened := evilFed first "i C-n"
            let failed := evilFed refused "i C-n"
            opened.loop.state.atPoint.map (·.source) == some "second" &&
              (opened.loop.state.atPoint.map (·.candidates.all.map (·.text))) ==
                some #["wq", "w"] &&
              sessionChosen opened == none &&
              !opened.loop.state.echo.startsWith "at-point-next" &&
              failed.loop.state.atPoint.isNone &&
              failed.loop.state.echo == "at-point-next: refused: bad range"
          | _, _ => false },
    { name :=
        "the chain asked at point is the one of the focused buffer's major mode and minor modes"
      run :=
        pure <|
          -- `second` answers only on the chain of the buffer's major mode
          -- and minor mode together; every other pair of modes gets `silent`.
          let handed := atPointHanded #[] atPoints
          let chained : Loop.Keys Vim.Default.scheme :=
            { handed with
              registered :=
                { handed.registered with
                  atPointNames := fun major minors =>
                    if major == some "notes" && minors == #["one"] then #["second"]
                    else #["silent"] } }
          let notes (buffer : Buffer) : Buffer :=
            { buffer with
              major := some "notes", minors := #["one"] }
          let moded : TextM EditorState := do
            let state ← evilState "" 0
            return { state with buffers := state.buffers.map (·.map notes) }
          match (Loop.Driver.over chained (fun _ => none) moded editorModel).toOption with
          | none => false
          | some driver =>
            let opened := evilFed driver "i C-n"
            opened.loop.state.atPoint.map (·.source) == some "second" &&
              (opened.loop.state.atPoint.map (·.candidates.all.map (·.text))) ==
                some #["wq", "w"] },
    { name :=
        "with no at-point source answering a key says nothing to complete at point; one whose region is away from the cursor is refused outside; one naming a source nobody registered is refused with it; S-TAB with no session does nothing; C-g with no session runs keyboard-quit"
      run :=
        pure <|
          let away : Completion.AtPoint :=
            .fixed "away" fun spot =>
              some { start := spot.offset + 1, stop := spot.offset + 1, sources := [] }
          let missing : Completion.AtPoint :=
            .fixed "missing" fun spot =>
              some { start := spot.offset, stop := spot.offset, sources := [.source "nobody"] }
          let quitting : Config.Registration :=
            { name := "keyboard-quit", action := .call fun _ => message "quit ran" }
          match atPointDriver "ab|c" #["silent"] atPoints #[quitting],
            atPointDriver "ab|c" #["away"] [away], atPointDriver "ab|c" #["missing"] [missing] with
          | some silent, some outside, some unknown =>
            (evilFed silent "i C-SPC").loop.state.echo == AtPoint.nothing &&
              (evilFed outside "i C-SPC").loop.state.echo ==
                (AtPointRefusal.outside "away").describe &&
              (evilFed unknown "i C-SPC").loop.state.echo ==
                (AtPointRefusal.source (.noSuchSource "nobody")).describe &&
              evilShown (evilFed silent "i S-TAB") == "ab|c" &&
              (evilFed silent "i S-TAB").loop.state.echo == "" &&
              (evilFed silent "i C-g").loop.state.echo == "quit ran" &&
              (evilFed silent "i C-g").loop.state.atPoint.isNone
          | _, _, _ => false },
    { name :=
        "a region that holds the cursor but starts or stops inside a character is refused outside, and no session opens"
      run :=
        pure <|
          let starting : Completion.AtPoint :=
            .fixed "starting" fun spot =>
              some { start := spot.offset - 1, stop := spot.offset, sources := [.source "pick"] }
          let stopping : Completion.AtPoint :=
            .fixed "stopping" fun spot =>
              some { start := spot.offset, stop := spot.offset + 1, sources := [.source "pick"] }
          match atPointDriver "é|é" #["starting"] [starting],
            atPointDriver "é|é" #["stopping"] [stopping] with
          | some starts, some stops =>
            let started := evilFed starts "i C-SPC"
            let stopped := evilFed stops "i C-SPC"
            started.loop.state.echo == (AtPointRefusal.outside "starting").describe &&
              started.loop.state.atPoint.isNone &&
              stopped.loop.state.echo == (AtPointRefusal.outside "stopping").describe &&
              stopped.loop.state.atPoint.isNone
          | _, _ => false },
    { name :=
        "a session is refused while a prompt is open, and asking again while one is open does nothing; C-g closes it and the loop gives its markers up"
      run :=
        pure <|
          match atPointDriver "|" #["second"] atPoints with
          | none => false
          | some driver =>
            let opened := evilFed driver "i C-n"
            let again := evilFed opened "C-SPC"
            match opened.loop.state.atPoint with
            | none => false
            | some session =>
              let quit := evilFed opened "C-g"
              let state := opened.loop.state
              let (_, prompting) := prompted state
              again.loop.state.atPoint == opened.loop.state.atPoint &&
                quit.loop.state.atPoint.isNone &&
                markerGone quit session.start &&
                markerGone quit session.stop &&
                ((completeAtPoint .key).runModel opened.model |>.1 |> fun
                  | .ok _ => true
                  | _ => false) &&
                (EditorState.openAtPoint session {} prompting).1 matches .error .promptOpen },
    { name :=
        "a source that reads the open buffers' texts has a snapshot taken of each, the asking view's buffer's first; a source that does not has none"
      run :=
        pure <|
          let registered : Loop.Registered :=
            { sources := fun name => atPointSources.find? (·.name == name), jobs := fun _ => true }
          let asking (refs : List Completion.SourceRef) (view : ViewId) :
            EditorM (Guarded (Except SourceRefusal Completion.Collected) × EditorState) := do
            let state ← twoBuffers
            (collectSources refs { text := "", view }).dispatched registered
                { state with frame := { state.frame with focused := view } }
          match (asking [.named "words"] ⟨1⟩).runModel editorModel,
            (asking [.named "say"] ⟨1⟩).runModel editorModel with
          | (.ok (.finished (.ok words), _), model), (.ok (.finished (.ok plain), _), _) =>
            let contents (id : SnapshotId) : Option String :=
              (model.texts.snapshots[id.index]?).join.map (·.contents)
            words.texts.size == 2 && words.texts.toList.map contents == [some "other", some ""] &&
              plain.texts.isEmpty
          | _, _ => false }]

end ModelTest
