import Editor.Api
import Editor.Api.Cases
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
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.File
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Language
import Editor.Loop
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.Mode
import Editor.Program
import Editor.ProjectMode
import Editor.Scene
import Editor.State
import Editor.Test.Completion
import Editor.Test.Driver
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.States
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Value
import Editor.Watch
import Editor.Watch.Model
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Candidates
import ModelTest.Support.Evil

/-!
# Model tests: `Editor/Api.lean`

The model tests of `Editor/Api.lean`: `apiStateChecks` and
`insertCandidateChecks`, which run `insertCandidate` and the accept of a
partial candidate through the minibuffer's commands under the Vim scheme that
ships. The root module `ModelTest` runs them; its module doc says what each
shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- `command` run dispatched from `twoBuffers` with nothing told of the
registry, on the editor's models: how it ended, the state it left, and the
texts the text model then holds. `none` when the run itself was refused. -/
def dispatchedOn {α : Type} (command : EditorM α) :
    Option (Guarded α × EditorState × Array String) :=
  let program : EditorM (Guarded α × EditorState) := do
    command.dispatched {} (← twoBuffers)
  match program.runModel editorModel with
  | (.ok (ended, state), model) => some (ended, state, model.texts.contents)
  | (.error _, _) => none

/-- `twoBuffers` whose buffer `other` holds a file, for the checks of
`quit`. With `edited` its text was edited since, and its history told so:
the buffer is modified. -/
def quitStart (edited : Bool) : TextM EditorState := do
  let state ← twoBuffers
  let (_, state) :=
    state.attachFile ⟨1⟩ "/files/note.txt" { seconds := 3, nanoseconds := 0, size := 9 } .lf
  let some buffer := state.buffer? ⟨1⟩ | throw .noSuchText
  if edited then
    buffer.text.insert 0 "edited"
    return (state.setHistory ⟨1⟩ (← buffer.history.sync)).2
  else
    return state

/-- The checks of the operations of the editor API that are Lean state
alone (`Editor/Api.lean`): they make no request of the library, so they are
pinned here, once, on the editor's models; and of `quit`, on the same
models, whose one case on the real binding is in `Editor/Api/Cases.lean`. -/
def apiStateChecks : List Check :=
  let one : BufferId := ⟨1⟩
  let absent : BufferId := ⟨9⟩
  [{  name :=
        "a prompt asks its sources with the place of the asking view: a source that answers its query's place lists the editor's working directory, for a buffer with no file, and the home, and the prompt's candidates keep the place"
      run :=
        pure <|
          let start : TextM EditorState := do
            return { (← twoBuffers) with
                workingDirectory := "/work", home := some "/home/me" }
          match
            dispatchedFrom (start := start) do
              discard <|
                  prompt "Place: " { command := "placed" } ""
                    [.given (Completion.Fake.placed "placed" "place")] with
          | some (_, state) =>
            state.prompt.map (·.candidates.all.map (·.text)) ==
                some #["directory /work", "home /home/me"] &&
              state.prompt.map (·.candidates.place) ==
                some { directory := some "/work", home := some "/home/me" }
          | none => false },
    { name :=
        "a buffer-local value set from a command is read back by its name, a second value of the name replaces the first, another buffer has none, and setting one on a buffer there is none of is refused with noSuchBuffer"
      run :=
        pure <|
          match
            dispatchedFrom do
              let set ← one.setValue "count" (.nat 1)
              let first ← one.value? "count"
              discard <| one.setValue "count" (.nat 2)
              return (set, first, ← one.value? "count", ← (⟨0⟩ : BufferId).value? "count",
                  ← absent.setValue "count" .null, ← absent.value? "count") with
          | some ((set, first, second, other, refused, nothing), state) =>
            replied set == .inr () && first == some (.nat 1) && second == some (.nat 2) &&
              other == none &&
              replied refused == .inl (.noSuchBuffer absent) &&
              nothing == none &&
              state.value? one "count" == some (.nat 2)
          | none => false },
    { name :=
        "a minor mode added from a command is the buffer's, first, and one removed is gone; each is refused with noSuchBuffer for a buffer there is none of"
      run :=
        pure <|
          match
            dispatchedFrom do
              let added ← one.addMinorMode "first"
              discard <| one.addMinorMode "second"
              let both := ((← editorState).buffer? one).map (·.minors)
              let removed ← one.removeMinorMode "first"
              return (added, both, removed, ← absent.addMinorMode "first",
                  ← absent.removeMinorMode "first") with
          | some ((added, both, removed, unadded, unremoved), state) =>
            replied added == .inr () && both == some #["second", "first"] &&
              replied removed == .inr () &&
              replied unadded == .inl (.noSuchBuffer absent) &&
              replied unremoved == .inl (.noSuchBuffer absent) &&
              ((state.buffer? one).map (·.minors)) == some #["second"] &&
              ((state.buffer? ⟨0⟩).map (·.minors)) == some #[]
          | none => false },
    { name :=
        "a major mode asked for where nothing was told of the registry is refused with noSuchMode, and a view with no window with noSuchWindow first; the state is as it was"
      run :=
        pure <|
          match
            dispatchedFrom do
              return (← (⟨0⟩ : ViewId).setMajorMode "listing",
                  ← (⟨9⟩ : ViewId).setMajorMode "listing") with
          | some ((unknown, unseen), state) =>
            replied unknown == .inl (.noSuchMode "listing") &&
              replied unseen == .inl (.noSuchWindow ⟨9⟩) &&
              some state == onTextModel twoBuffers
          | none => false },
    { name :=
        "a wanted column set from a command is the window's, with its head, and setting none clears it; a view with no window is refused with noSuchWindow; none of it makes a request of the library"
      run :=
        pure <|
          let kept : Window.Wanted := { column := .goal 3, head := 7 }
          let view : ViewId := ⟨1⟩
          let program : EditorM _ := do
            let start ← twoBuffers
            let before ← Watch.now
            let ran ←
              EditorM.dispatched
                  (do
                    let set ← view.setWanted (some kept)
                    let held := ((← editorState).window? view).map (·.wanted)
                    let cleared ← (⟨0⟩ : ViewId).setWanted none
                    return (set, held, cleared, ← (⟨9⟩ : ViewId).setWanted (some kept)))
                  {} start
            return (ran, start, before, ← Watch.now)
          match (program.runModel countingModel).1 with
          | .ok ((.finished (set, held, cleared, refused), state), start, before, after) =>
            replied set == .inr () && held == some (some kept) && replied cleared == .inr () &&
              replied refused == .inl (.noSuchWindow ⟨9⟩) &&
              state == (start.setWanted view (some kept)).2 &&
              before > 0 &&
              after == before
          | _ => false },
    { name :=
        "a register set from a command is the editor state's, which the command then reads it from, and a second set under the name replaces it; none of it makes a request of the library"
      run :=
        pure <|
          let word : Register := { text := "word" }
          let line : Register := { text := "a line\n", linewise := true }
          let program : EditorM _ := do
            let start ← twoBuffers
            let before ← Watch.now
            let ran ←
              EditorM.dispatched
                  (do
                    setRegister "a" word
                    let first := (← editorState).register? "a"
                    setRegister "a" line
                    return (first, (← editorState).register? "a", (← editorState).register? "b"))
                  {} start
            return (ran, start, before, ← Watch.now)
          match (program.runModel countingModel).1 with
          | .ok ((.finished (first, second, other), state), start, before, after) =>
            first == some word && second == some line && other == none &&
              state == start.setRegister "a" line &&
              before > 0 &&
              after == before
          | _ => false },
    { name :=
        "a scroll margin set from a command is the editor state's, which the command then reads it from, and a second one set replaces it; none of it makes a request of the library"
      run :=
        pure <|
          let program : EditorM _ := do
            let start ← twoBuffers
            let before ← Watch.now
            let ran ←
              EditorM.dispatched
                  (do
                    let unset := (← editorState).scrollMargin
                    setScrollMargin 2
                    let first := (← editorState).scrollMargin
                    setScrollMargin 5
                    return (unset, first, (← editorState).scrollMargin))
                  {} start
            return (ran, start, before, ← Watch.now)
          match (program.runModel countingModel).1 with
          | .ok ((.finished (unset, first, second), state), start, before, after) =>
            unset == 0 && first == 2 && second == 5 && state == start.setScrollMargin 5 &&
              before > 0 &&
              after == before
          | _ => false },
    { name :=
        "quit from a command asks the editor to quit when no buffer has unsaved changes, and when the only modified buffer holds no file, though the command itself edited it"
      run :=
        pure <|
          let clean := dispatchedFrom quit
          let scratch :=
            dispatchedFrom do
              discard <| (⟨0⟩ : BufferId).insertAt 0 "typed"
              quit
          (clean.map fun (reply, state) => (replied reply, state.quitting)) ==
              some (.inr (), true) &&
            (scratch.map fun (reply, state) => (replied reply, state.quitting)) ==
              some (.inr (), true) },
    { name :=
        "quit from a command is refused with the name of a buffer that holds a file and has unsaved changes, with the state as it was and the editor not asked: for a buffer that was modified before the command, and for an edit the command itself made before it asked"
      run :=
        pure <|
          let before :=
            dispatchedFrom (start := quitStart true) do
              let state ← editorState
              return (← quit, (← editorState) == state)
          let during :=
            dispatchedFrom (start := quitStart false) do
              discard <| one.insertAt 0 "typed"
              let state ← editorState
              return (← quit, (← editorState) == state)
          let refused (ran : Option ((Except QuitRefusal Unit × Bool) × EditorState)) : Bool :=
            (ran.map fun ((reply, same), state) => (replied reply, same, state.quitting)) ==
              some (.inl (.unsaved "other"), true, false)
          refused before && refused during },
    { name :=
        "quit from a command asks when the modified buffer's save in flight is writing the state its text is in, and is refused once the command has edited the buffer since"
      run :=
        pure <|
          let saving : TextM EditorState := do
            let state ← quitStart true
            let some buffer := state.buffer? one | throw .noSuchText
            let snapshot ← buffer.text.snapshot
            return (state.beginSave one snapshot buffer.history.state).2
          let covered := dispatchedFrom quit saving
          let since :=
            dispatchedFrom (start := saving) do
              discard <| one.insertAt 0 "more"
              quit
          (covered.map fun (reply, state) => (replied reply, state.quitting)) ==
              some (.inr (), true) &&
            (since.map fun (reply, state) => (replied reply, state.quitting)) ==
              some (.inl (.unsaved "other"), false) },
    { name :=
        "a prompt asked for with a source holds what the source answered, in the source's group, and the source is run once: the text it makes is in the store once, beside the minibuffer's"
      run :=
        pure <|
          let made := "made by the source"
          let source : Completion.Source :=
            { name := "made", category := "test"
              candidates := fun _ => do
                discard <| createText made
                return offered #["wq", "edit", "w"] }
          match dispatchedOn (prompt "Pick: " asked "w" [.given source]) with
          | some (.finished (.ok view), state, texts) =>
            state.prompt.map (·.candidates) ==
                some
                  { all := (offered #["wq", "edit", "w"]).map (·.inGroup "made")
                    category := some "test", place := { directory := some "/" } } &&
              state.prompt.map (·.view) == some view &&
              (texts.filter (· == made)).size == 1 &&
              texts.contains "w" &&
              state.wellFormed
          | _ => false },
    { name :=
        "a prompt asked for with a source that answers later, where its job is registered, opens with that source asking, not yet asked, for the initial text, and runs none of it; where no job is registered under its job's name it is refused with noSuchJob, with no text made"
      run :=
        pure <|
          let source : Completion.Source :=
            { Completion.Source.answeringLater "later" "pick" "later-pick" with
              candidates := fun _ => do
                discard <| createText "ran"
                return #[] }
          let registered : Loop.Registered := { jobs := (· == "later-pick") }
          let asking : EditorM (Except PromptRefusal ViewId) :=
            prompt "Pick: " asked "w" [.given source]
          let program : EditorM (Guarded (Except PromptRefusal ViewId) × EditorState) := do
            asking.dispatched registered (← twoBuffers)
          match (program.runModel editorModel), dispatchedOn asking,
            dispatchedOn (pure () : EditorM Unit) with
          | (.ok (.finished (.ok _), state), model), some (.finished refused, unasked, texts),
            some (_, _, before) =>
            state.prompt.map (·.candidates) ==
                some
                  { category := some "pick", place := { directory := some "/" }
                    asking :=
                      #[{ source := "later", later := { job := "later-pick" },
                          askedFor := "w" }] } &&
              !model.texts.contents.contains "ran" &&
              state.wellFormed &&
              replied refused == .inl (.noSuchJob "later-pick") &&
              unasked.prompt == none &&
              texts == before
          | _, _, _ => false },
    { name :=
        "a prompt that asks for a category no source is registered in, with no defaults, is not refused: it opens with no candidates, having asked for none, and the state is well formed"
      run :=
        pure <|
          match dispatchedOn (prompt "Pick: " asked "" [.ofCategory "none"]) with
          | some (.finished (.ok view), state, _) =>
            state.prompt.map (·.candidates) == some {} && state.prompt.map (·.view) == some view &&
              state.wellFormed
          | _ => false },
    { name :=
        "a prompt whose source is refused refuses the asking command: no prompt is open and no text was made for a minibuffer"
      run :=
        pure <|
          let source : Completion.Source :=
            { name := "reads", category := "test"
              candidates := fun _ => do
                discard <| (⟨99⟩ : TextId).read
                return offered #["a"] }
          match dispatchedOn (prompt "Pick: " asked "w" [.given source]),
            dispatchedOn (pure () : EditorM Unit) with
          | some (.refused .noSuchText, state, texts), some (_, _, before) =>
            state.prompt == none && texts == before
          | _, _ => false },
    { name :=
        "while a prompt is open, asking for another with a source is refused with alreadyOpen and the source is not run: it makes no text, and the open prompt's candidates are as they were"
      run :=
        pure <|
          let source : Completion.Source :=
            { name := "ran", category := "test"
              candidates := fun _ => do
                discard <| createText "ran"
                return offered #["x"] }
          match
            dispatchedOn do
              let first ← prompt "A: " asked
              return (first, ← prompt "B: " asked "" [.given source]) with
          | some (.finished (.ok view, .error (.alreadyOpen held)), state, texts) =>
            view == held && !texts.contains "ran" && state.prompt.map (·.candidates) == some {} &&
              state.prompt.map (·.label) == some "A: "
          | _ => false },
    { name :=
        "a prompt asked for with no source has no candidates, and leaves the state and the store as one asked for with a source that answers none"
      run :=
        pure <|
          match dispatchedOn (prompt "Name: " asked "hé"),
            dispatchedOn (prompt "Name: " asked "hé" [.given (.fixed "none" "test" #[])]) with
          | some (.finished (.ok view), state, texts), some (.finished (.ok same), again, others) =>
            view == same && state == again && texts == others &&
              state.prompt.map (·.candidates) == some {}
          | _, _ => false },
    { name :=
        "setting the candidates from a command replaces an open prompt's, and with no prompt open it is refused with notOpen, a value"
      run :=
        pure <|
          match
            dispatchedOn do
              let closed ← setCandidates { all := offered #["a"] }
              discard <| prompt "Pick: " asked "" [.given (.ofTexts "xy" "test" #["x", "y"])]
              let before := (← editorState).prompt.map (·.candidates)
              return (closed, before, ← setCandidates { all := offered #["a", "b"] }) with
          | some (.finished (.error .notOpen, before, .ok ()), state, _) =>
            before.map (·.all.map (·.text)) == some #["x", "y"] &&
              state.prompt.map (·.candidates) == some { all := offered #["a", "b"] }
          | _ => false },
    { name :=
        "accepting a prompt answers with the chosen candidate when its listing is for the minibuffer's text; with the text when nothing is chosen, when the choice was made for another text than the minibuffer holds, and when there are no candidates; the continuation's own arguments follow the answer"
      run :=
        pure <|
          let all := #["wq", "edit", "w"]
          -- What the continuation was recorded with by accepting from `start`.
          let answered (start : TextM EditorState) : Option (List Argument) :=
            (dispatchedFrom acceptPrompt start).bind fun (reply, state) =>
              if reply matches .ok () && state.prompt.isNone then
                state.outbox.answered[0]?.map (·.arguments)
              else none
          answered (ApiCases.choosing "w" all "w" #[2, 0] [.next, .next]) ==
              some [.str "wq", .nat 7] &&
            answered (ApiCases.choosing "w" all "w" #[2, 0] [.previous, .previous]) ==
              some [.str "w", .nat 7] &&
            answered (ApiCases.choosing "w" all "w" #[2, 0] []) == some [.str "w", .nat 7] &&
            answered (ApiCases.choosing "wx" all "w" #[2, 0] [.next, .next]) ==
              some [.str "wx", .nat 7] &&
            answered (ApiCases.choosing "typed" #[] "" #[] [.next]) ==
              some [.str "typed", .nat 7] }]

/-- The checks of putting a prompt's candidate into its minibuffer
(`minibuffer-insert`, `insertCandidate`, `Editor/Api.lean`) and of going
into a partial candidate (`Completion.Candidate.isPartial`, `acceptPrompt`),
under the Vim scheme that ships, whose minibuffer state binds `TAB` to the
insert and `RET` to the accept. -/
def insertCandidateChecks : List Check :=
  let ask (candidates : Array Completion.Candidate) : Dispatched := fun _ => do
    discard <|
        prompt pickLabel { command := "picked" } "" [.given (.fixed "pick" "pick" candidates)]
    return none
  let handed :=
    evilHanded #[]
      [("pick", ask (offered pickCandidates)),
        ("dirs", ask #[{ text := "src/", isPartial := true }, .ofText "a.txt"]),
        ("picked", fun call => do
          message (picked call.arguments)
          return none)]
  let asked (command : String) : Option EvilDriver := do
    let driver ← evilDriver "|" handed
    return (driver.stepped (driver.loop.runNamed driver.handed command)).1
  let listed (driver : EvilDriver) : Array String :=
    ((driver.loop.state.prompt.map (·.candidates.listed.map (·.text))).getD #[])
  [{  name :=
        "TAB, minibuffer-insert, with a candidate chosen replaces the input with its text, the bar at its end, and leaves the prompt open; with nothing chosen it inserts the first listed; with nothing listed it changes nothing"
      run :=
        pure <|
          match asked "pick" with
          | none => false
          | some asking =>
            let chosen := evilFed asking "C-n C-n TAB"
            let typed := evilFed asking "e"
            let first := evilFed typed "TAB"
            let unmatched := evilFed asking "z z TAB"
            let second := (listed asking)[1]?.getD ""
            evilShown chosen ⟨1⟩ == second ++ "|" && chosen.loop.state.prompt.isSome &&
              second != (listed asking)[0]?.getD "" &&
              evilShown first ⟨1⟩ == (listed typed)[0]?.getD "" ++ "|" &&
              first.loop.state.prompt.isSome &&
              evilShown unmatched ⟨1⟩ == "zz|" &&
              unmatched.loop.state.prompt.isSome },
    { name :=
        "a candidate is inserted only from a listing for the text: chosen, or the first listed with none chosen; a listing for another text inserts nothing, and with no prompt the command says it is not open"
      run :=
        pure <|
          let candidates : Candidates :=
            { listedFor := some "e", listed := #[.of (.ofText "edit"), .of (.ofText "rewrite")] }
          let unasked :=
            match evilDriver "a|bc" handed with
            | none => false
            | some driver =>
              let (ran, _) :=
                driver.stepped (driver.loop.runNamed driver.handed Minibuffer.insertName)
              ran.loop.state.echo == Minibuffer.notOpen && evilShown ran == "a|bc"
          (candidates.toInsert "e").map (·.text) == some "edit" &&
            (Candidates.toInsert { candidates with chosen := some 1 } "e").map (·.text) ==
              some "rewrite" &&
            (candidates.toInsert "ed").isNone &&
            (({} : Candidates).toInsert "").isNone &&
            unasked },
    { name :=
        "RET on a chosen partial candidate inserts it and keeps the prompt open; on a candidate that is not partial it closes the prompt and answers it"
      run :=
        pure <|
          match asked "dirs" with
          | none => false
          | some asking =>
            let entered := evilFed asking "C-n RET"
            let answered := evilFed asking "C-n C-n RET"
            evilShown entered ⟨1⟩ == "src/|" && entered.loop.state.prompt.isSome &&
              answered.loop.state.prompt.isNone &&
              answered.loop.state.echo == picked [.str "a.txt"] }]

end ModelTest
