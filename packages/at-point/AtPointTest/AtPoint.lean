import AtPoint
import AtPoint.Compiled
import AtPointTest.Check
import AtPointTest.Support.Words
import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Completion.Fake
import Editor.InputScheme.Test
import Editor.Loop.Driver
import Editor.State
import Editor.Test.AtPoint
import Editor.Test.Editing
import Editor.Test.Models
import Editor.Test.States
import Editor.Text
import Editor.Text.Model

/-!
# Model tests: `AtPoint.lean`

The model tests of `AtPoint.lean`: `atPointChecks`, on a driver of the test
scheme over the models, with keys of the checks' own on the package's
commands (`AtPointTest/Support/Words.lean`). The test driver's root,
`AtPointTest/Model.lean`, runs them. They were the core's
(`ModelTest.atPointChecks`) while completion at point was a module of the
core, and moved here with their sentences and assertions; since evil
became a package they type no key of the Vim scheme, whose table of
at-point's keys is evil's to pin.
-/

namespace AtPointTest

open Editor
open Editor.Test

/-- The checks of asking for completion at point (the core's
`lean/Editor/Api.lean`, "Completion at point", `AtPoint.lean`), on a driver
of the test scheme over the models. -/
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
          match shippedAtPointDriver "|" #["silent", "second", "refusing"] atPoints,
            shippedAtPointDriver "|" #["silent", "refusing"] atPoints with
          | some first, some refused =>
            let opened := keysFed first "C-n"
            let failed := keysFed refused "C-n"
            opened.loop.state.atPoint.map (·.source) == some "second" &&
              (opened.loop.state.atPoint.map (·.candidates.all.map (·.text))) ==
                some #["wq", "w"] &&
              sessionChosen opened == none &&
              !opened.loop.state.echo.startsWith "at-point-next" &&
              failed.loop.state.atPoint.isNone &&
              failed.loop.state.echo == "at-point-next: refused: bad range"
          | _, _ => false },
    { name :=
        "the at-point package registers its commands under the names the core's test kit registers, in its order: every command a scheme's table of the state where typing is text runs that the scheme's package does not register, and the two the core runs at a trigger and a pause"
      run :=
        pure <|
          Editor.AtPoint.package.registered.commands.map (·.name) == Test.AtPoint.names &&
            Editor.AtPoint.triggeredName == Completion.AtPoint.triggeredCommand &&
            Editor.AtPoint.pausedName == Completion.AtPoint.pausedCommand },
    { name :=
        "the chain asked at point is the one of the focused buffer's major mode and minor modes"
      run :=
        pure <|
          -- `second` answers only on the chain of the buffer's major mode
          -- and minor mode together; every other pair of modes gets `silent`.
          let handed := shippedAtPointHanded #[] atPoints
          let chained : Loop.Keys TestScheme.scheme :=
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
            let state ← barState "" 0
            return { state with buffers := state.buffers.map (·.map notes) }
          match (Loop.Driver.over chained (fun _ => none) moded editorModel).toOption with
          | none => false
          | some driver =>
            let opened := keysFed driver "C-n"
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
          match shippedAtPointDriver "ab|c" #["silent"] atPoints #[quitting],
            shippedAtPointDriver "ab|c" #["away"] [away],
            shippedAtPointDriver "ab|c" #["missing"] [missing] with
          | some silent, some outside, some unknown =>
            (keysFed silent "C-SPC").loop.state.echo == AtPoint.nothing &&
              (keysFed outside "C-SPC").loop.state.echo ==
                (AtPointRefusal.outside "away").describe &&
              (keysFed unknown "C-SPC").loop.state.echo ==
                (AtPointRefusal.source (.noSuchSource "nobody")).describe &&
              shownOf (keysFed silent "S-TAB") == "ab|c" &&
              (keysFed silent "S-TAB").loop.state.echo == "" &&
              (keysFed silent "C-g").loop.state.echo == "quit ran" &&
              (keysFed silent "C-g").loop.state.atPoint.isNone
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
          match shippedAtPointDriver "é|é" #["starting"] [starting],
            shippedAtPointDriver "é|é" #["stopping"] [stopping] with
          | some starts, some stops =>
            let started := keysFed starts "C-SPC"
            let stopped := keysFed stops "C-SPC"
            started.loop.state.echo == (AtPointRefusal.outside "starting").describe &&
              started.loop.state.atPoint.isNone &&
              stopped.loop.state.echo == (AtPointRefusal.outside "stopping").describe &&
              stopped.loop.state.atPoint.isNone
          | _, _ => false },
    { name :=
        "a session is refused while a prompt is open, and asking again while one is open does nothing; C-g closes it and the loop gives its markers up"
      run :=
        pure <|
          match shippedAtPointDriver "|" #["second"] atPoints with
          | none => false
          | some driver =>
            let opened := keysFed driver "C-n"
            let again := keysFed opened "C-SPC"
            match opened.loop.state.atPoint with
            | none => false
            | some session =>
              let quit := keysFed opened "C-g"
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
            { sources := fun name => shippedAtPointSources.find? (·.name == name),
              jobs := fun _ => true }
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
          | _, _ => false },
    { name :=
        "with no session open, at-point-return runs the command evil-api declares for a line break and at-point-tab the one it declares for a tab: on evil-api's fake, RET breaks the line at the cursor and TAB types a tab there"
      run :=
        pure <|
          match shippedAtPointDriver "ab|cd" #[] [] with
          | some driver =>
            shownOf (keysFed driver "RET") == "ab\n|cd" &&
              shownOf (keysFed driver "TAB") == "ab\t|cd"
          | none => false }]

end AtPointTest
