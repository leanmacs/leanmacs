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
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.File
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Keymap
import Editor.Language
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Program
import Editor.RichText
import Editor.Scene
import Editor.State
import Editor.Test.Completion
import Editor.Test.Driver
import Editor.Test.Editing
import Editor.Test.Excerpt
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Test.Prompts
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
import ModelTest.Support.Excerpt

/-!
# Model tests: `Editor/Api.lean`

The model tests of `Editor/Api.lean`: `apiStateChecks`,
`insertExcerptChecks` and `insertCandidateChecks`, which run `insertCandidate` and the accept of a
partial candidate through the minibuffer's commands under the Vim scheme that
ships; and `richTextCallChecks` and `richTextAppendChecks`, which write a
read-only buffer from a rich-text description on the stepped loop over the
models. The root module `ModelTest` runs them; its module doc says what each
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
under the test scheme with the kit's minibuffer (`minibufferKeys`,
`Editor/Test/Prompts.lean`), whose mode has `C-n` choose the next candidate
and `RET` accept, and with `TAB` bound here to the insert, as a scheme's
minibuffer table binds it. -/
def insertCandidateChecks : List Check :=
  let ask (candidates : Array Completion.Candidate) : Dispatched := fun _ => do
    discard <|
        prompt pickLabel { command := "picked" } "" [.given (.fixed "pick" "pick" candidates)]
    return none
  let commands : List (String × Dispatched) :=
    [("pick", ask (offered pickCandidates)),
      ("dirs", ask #[{ text := "src/", isPartial := true }, .ofText "a.txt"]),
      ("picked", fun call => do
        message (picked call.arguments)
        return none)]
  let handed : Loop.Keys TestScheme.scheme :=
    { minibufferKeys with
      maps := fun state view =>
        Keymap.ofList [(keys "TAB", invoke Test.Minibuffer.insertName)] ::
          minibufferKeys.maps state view
      command? := fun name =>
        match commands.find? (·.1 == name) with
        | some (_, command) => some command
        | none => minibufferKeys.command? name }
  let over (fixture : String) : Option TestDriver :=
    let (contents, head) := barred fixture
    (Loop.Driver.over handed (fun _ => none) (barState contents head) editorModel).toOption
  let asked (command : String) : Option TestDriver := do
    let driver ← over "|"
    return (driver.stepped (driver.loop.runNamed driver.handed command)).1
  let listed (driver : TestDriver) : Array String :=
    ((driver.loop.state.prompt.map (·.candidates.listed.map (·.text))).getD #[])
  [{  name :=
        "a key bound to minibuffer-insert, with a candidate chosen, replaces the input with its text, the bar at its end, and leaves the prompt open; with nothing chosen it inserts the first listed; with nothing listed it changes nothing"
      run :=
        pure <|
          match asked "pick" with
          | none => false
          | some asking =>
            let chosen := keysFed asking "C-n C-n TAB"
            let typed := keysFed asking "e"
            let first := keysFed typed "TAB"
            let unmatched := keysFed asking "z z TAB"
            let second := (listed asking)[1]?.getD ""
            shownOf chosen ⟨1⟩ == second ++ "|" && chosen.loop.state.prompt.isSome &&
              second != (listed asking)[0]?.getD "" &&
              shownOf first ⟨1⟩ == (listed typed)[0]?.getD "" ++ "|" &&
              first.loop.state.prompt.isSome &&
              shownOf unmatched ⟨1⟩ == "zz|" &&
              unmatched.loop.state.prompt.isSome },
    { name :=
        "a candidate is inserted only from a listing for the text: chosen, or the first listed with none chosen; a listing for another text inserts nothing, and with no prompt the command says it is not open"
      run :=
        pure <|
          let candidates : Candidates :=
            { listedFor := some "e", listed := #[.of (.ofText "edit"), .of (.ofText "rewrite")] }
          let unasked :=
            match over "a|bc" with
            | none => false
            | some driver =>
              let (ran, _) :=
                driver.stepped (driver.loop.runNamed driver.handed Test.Minibuffer.insertName)
              ran.loop.state.echo == PromptRefusal.notOpen.describe && shownOf ran == "a|bc"
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
            let entered := keysFed asking "C-n RET"
            let answered := keysFed asking "C-n C-n RET"
            shownOf entered ⟨1⟩ == "src/|" && entered.loop.state.prompt.isSome &&
              answered.loop.state.prompt.isNone &&
              answered.loop.state.echo == picked [.str "a.txt"] }]

/-- The commands of the insert checks, beside the excerpt buffer checks':
`insert-beta` inserts the excerpt of `two`'s second row, headed `beta`, into
`ex` before its second excerpt; and `make-empty` makes an excerpt buffer
`empty` of no excerpt, inserts `one`'s first row, headed `h`, into it, and
shows it. -/
def insertRegistrations : Array Config.Registration :=
  #[{ name := "insert-beta"
      action :=
        .call fun _ => do
          let some ex ← findBuffer "ex" | return
          let some two ← findBuffer "two" | return
          discard <|
              ex.insertExcerpts 1 #[{ buffer := two, start := 6, stop := 11, header := "beta" }] },
    { name := "make-empty"
      action :=
        .call fun call => do
          let some one ← findBuffer "one" | return
          let .ok empty ← createExcerptBuffer "empty" #[] | return
          discard <|
              empty.insertExcerpts 0 #[{ buffer := one, start := 0, stop := 4, header := "h" }]
          discard <| call.target.window.id.show empty }]

/-- A driver of the insert checks: the excerpt buffer checks' driver with the
insert commands, once `make-ex` has run. -/
def insertDriver : Option ExcerptDriver :=
  excerptDriverWith insertRegistrations

/-- The headers of the excerpt buffer called `name`. -/
def headersOf (driver : ExcerptDriver) (name : String) : Option (Array String) := do
  let buffer ← excerptBufferNamed driver name
  let excerpts ← buffer.excerpts
  return excerpts.entries.map (·.header)

/-- The checks of `BufferId.insertExcerpts`, on the loop's driver over the
editor's models: excerpts inserted after an edit typed in the first keep its
text, its anchor and its header, and the new one is at its index; and an
empty excerpt buffer takes one. -/
def insertExcerptChecks : List Check :=
  [{  name :=
        "inserting an excerpt after an edit typed in excerpt 0 keeps its text, its anchor and its header, and leaves the new excerpt at index 1"
      run :=
        pure <|
          match insertDriver with
          | none => false
          | some driver =>
            let typed := sessionTyped driver "<ArrowRight>" ["X"]
            let inserted := excerptInvoked typed "insert-beta"
            -- An edit before the first excerpt in its source, and one typed
            -- in it again: an anchored range follows both.
            let moved := excerptInvoked inserted "edit-one"
            let typedAgain := sessionTyped moved "C-<Home>" ["Y"]
            excerptRead inserted "ex" == some "tXwo\n\nbeta\n\nalpha\n" &&
              headersOf inserted "ex" == some #["one", "beta", "two"] &&
              excerptRead moved "ex" == some "tXwo\n\nbeta\n\nalpha\n" &&
              excerptRead typedAgain "ex" == some "YtXwo\n\nbeta\n\nalpha\n" &&
              excerptRead typedAgain "one" == some "Zone\nYtXwo\nthree\n" },
    { name := "an excerpt is inserted into an excerpt buffer of none"
      run :=
        pure <|
          match insertDriver with
          | none => false
          | some driver =>
            let made := excerptInvoked driver "make-empty"
            excerptRead made "empty" == some "one\n" && headersOf made "empty" == some #["h"] }]

/-- A driver of the checks of giving up on a layout refusal: `C-a` runs
`give`, which gives up on the refusal of closing the last window and would
then say `after`, and `C-b` runs `pass`, which says the value it was handed. -/
def givingUpDriver : Option TestDriver :=
  let keys :=
    dispatchKeys [("C-a", invoke "give"), ("C-b", invoke "pass")]
      [("give", fun _ => do
          let _ : Unit ← orGiveUp (.error .onlyWindow)
          message "after"
          return none),
        ("pass", fun _ => do
          let value : Nat ← orGiveUp (.ok 3)
          message s!"passed {value}"
          return none)]
  (Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- The checks of giving up on a layout refusal (`orGiveUp`,
`Editor/Api.lean`). -/
def orGiveUpChecks : List Check :=
  [{  name :=
        "a layout refusal given up on ends the command with the refusal's sentence, under the command's name, and nothing after it runs; a value that is no refusal is handed on"
      run :=
        pure <|
          match givingUpDriver with
          | none => false
          | some driver =>
            echoOf (fedTo driver (presses "C-a")).1 ==
                some s!"give: {LayoutRefusal.onlyWindow.describe}" &&
              echoOf (fedTo driver (presses "C-a")).1 ==
                some "give: the last window cannot be closed" &&
              echoOf (fedTo driver (presses "C-b")).1 == some "passed 3" }]

/-- The head of the rich-text call checks: two rows, `head one` and `head
two`, with a span over `head`, a stop, a link over `one` to an absolute
path, a hanging indent over the second row, a fold `head` over the first
row and a fold `whole` over both, every one unfolded. -/
def richHead : RichText :=
  { text := "head one\nhead two\n"
    spans := #[{ start := 0, stop := 4, face := ⟨"rich.head"⟩ }]
    stops := #[{ offset := 5, x := 40 }]
    links := #[{ start := 5, stop := 8, target := .location "/rich/head.txt" 1 2 }]
    folds :=
      #[{ start := 0, stop := 9, key := "head", text := "[head]" },
        { start := 0, stop := 18, key := "whole", text := "[whole]" }]
    indents := #[{ start := 9, stop := 18, first := 0, rest := .lead 5 }] }

/-- The tail of the rich-text call checks, a row `tail` with a part of each
kind of its own. -/
def richTail : RichText :=
  { text := "tail\n"
    spans := #[{ start := 0, stop := 4, face := ⟨"rich.tail"⟩ }]
    stops := #[{ offset := 1, x := 10 }]
    links := #[{ start := 0, stop := 4, target := .url "https://example.com/tail" }]
    folds := #[{ start := 0, stop := 5, key := "tail", text := "[tail]" }]
    indents := #[{ start := 0, stop := 5, first := 4 }] }

/-- The description `rich-redo` writes from the end of `richHead`'s text: it
disagrees with the head in its text's bytes (`HEAD`) and in every part
before that end (another face, stop x, link target and indent, and `head`
declared unfolded with another placeholder); its fold `whole` crosses that
end, and its tail, `redo`, is new. -/
def richRedo : RichText :=
  { text := "HEAD one\nhead two\nredo\n"
    spans :=
      #[{ start := 0, stop := 4, face := ⟨"rich.redo"⟩ },
        { start := 18, stop := 22, face := ⟨"rich.new"⟩ }]
    stops := #[{ offset := 5, x := 99 }, { offset := 19, x := 3 }]
    links :=
      #[{ start := 5, stop := 8, target := .url "https://example.com/redo" },
        { start := 18, stop := 22, target := .url "https://example.com/new" }]
    folds :=
      #[{ start := 0, stop := 9, key := "head", text := "[HEAD]" },
        { start := 0, stop := 23, key := "whole", text := "[redo whole]" },
        { start := 18, stop := 23, key := "new", text := "[new]" }]
    indents :=
      #[{ start := 9, stop := 18, first := 7, rest := .points 7 },
        { start := 18, stop := 23, first := 2 }] }

/-- What a rich-text call answered, as words: `ok`, or its refusal. -/
def richWords : Except BufferRefusal Unit → String
  | .ok () => "ok"
  | .error (.noSuchBuffer _) => "noSuchBuffer"
  | .error _ => "refused"

/-- Keeps, as the value `name` of `buffer`, the smallest start of an edit of
its text since the revision its value `revision` holds, or a million with
none; then keeps the text's revision now as `revision`. -/
def keepEdited (buffer : BufferId) (name : String) : EditorM Unit := do
  let .ok text ← buffer.text | return
  if let some (.nat revision)← buffer.value? "revision" then
    let patch ← text.changesSince revision
    discard <| buffer.setValue name (.nat ((patch.edits.map (·.old.start)).foldl min 1000000))
  discard <| buffer.setValue "revision" (.nat (← text.revision))

/-- Makes a read-only buffer `rich`, shows it in `call`'s window, and writes
it from `rich`, keeping the answer as its value `result`. -/
def richSet (call : Call) (rich : RichText) : EditorM (Option BufferId) := do
  let .ok buffer ← createBuffer "rich" | return none
  discard <| buffer.setReadOnly true
  discard <| call.target.window.id.show buffer
  discard <| buffer.setValue "result" (.str (richWords (← buffer.setRichText rich)))
  return some buffer

/-- The commands of the rich-text call checks:

- `rich-set` makes a read-only buffer `rich`, shows it, and writes it from
  `richHead`;
- `rich-folded` does the same from `richHead` with `head` declared folded;
- `rich-absent` writes and appends to a buffer there is none of, keeping
  each answer on `rich` as `absent-set` and `absent-append`;
- `rich-head` is `rich-set`, then keeps the text's revision as `revision`
  and folds `head`;
- `rich-tail` appends `richTail` to `rich`, and keeps the smallest start of
  an edit since `revision` as `edited` (`keepEdited`);
- `rich-redo` writes `rich` from `richRedo` from the end of `richHead`'s
  text, and keeps the smallest start of an edit since the tail as
  `redone`. -/
def richTextCommands : List (String × Dispatched) :=
  [("rich-set", fun call => do
      discard <| richSet call richHead
      return none),
    ("rich-folded", fun call => do
      discard <|
          richSet call
            { richHead with
              folds := richHead.folds.map fun fold => { fold with folded := fold.key == "head" } }
      return none),
    ("rich-absent", fun _ => do
      let some rich ← findBuffer "rich" | return none
      let absent : BufferId := ⟨99⟩
      discard <| rich.setValue "absent-set" (.str (richWords (← absent.setRichText richHead)))
      discard <| rich.setValue "absent-append" (.str (richWords (← absent.appendRichText richTail)))
      return none),
    ("rich-head", fun call => do
      let some rich ← richSet call richHead | return none
      keepEdited rich "unused"
      discard <| rich.setFolded "head" true
      return none),
    ("rich-tail", fun _ => do
      let some rich ← findBuffer "rich" | return none
      discard <| rich.setValue "result" (.str (richWords (← rich.appendRichText richTail)))
      keepEdited rich "edited"
      return none),
    ("rich-redo", fun _ => do
      let some rich ← findBuffer "rich" | return none
      discard <|
          rich.setValue "result"
            (.str (richWords (← rich.setRichText richRedo richHead.text.utf8ByteSize)))
      keepEdited rich "redone"
      return none)]

/-- A driver whose window shows an empty buffer, with each of
`richTextCommands` on a key (`C-c` and a letter); `none` if making the state
was refused. -/
def richDriver : Option TestDriver :=
  let keys :=
    dispatchKeys
      [("C-c s", invoke "rich-set"), ("C-c f", invoke "rich-folded"),
        ("C-c x", invoke "rich-absent"), ("C-c h", invoke "rich-head"),
        ("C-c t", invoke "rich-tail"), ("C-c r", invoke "rich-redo")]
      richTextCommands
  (Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- `richDriver` fed the key strings `keys`. -/
def richFed (keys : String) : Option TestDriver :=
  richDriver.map fun driver => (fedTo driver (presses keys)).1

/-- The buffer `rich` of `driver`. -/
def richBuffer (driver : TestDriver) : Option Buffer := do
  driver.loop.state.buffer? (← driver.loop.state.findBuffer "rich")

/-- What the buffer `rich` of `driver` holds in its text model. -/
def richContents (driver : TestDriver) : Option String := do
  let buffer ← richBuffer driver
  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents)

/-- The value `name` of the buffer `rich` of `driver`. -/
def richValue (driver : TestDriver) (name : String) : Option Value := do
  driver.loop.state.value? (← driver.loop.state.findBuffer "rich") name

/-- The view 0 of the last scene `driver` published. -/
def richView (driver : TestDriver) : Option View :=
  driver.model.display.scenes.back?.bind fun scene => scene.views.find? (·.id == ⟨0⟩)

/-- Whether `view` draws every part of `rich` but its folds: each span, a
link decoration over each link, its stops and its indents. -/
def drawsRich (view : View) (rich : RichText) : Bool :=
  rich.spans.all view.decorations.contains &&
    rich.links.all
      (fun link =>
        view.decorations.contains { start := link.start, stop := link.stop, face := Link.face }) &&
    rich.stops.all view.stops.contains &&
    rich.indents.all view.indents.contains

/-- The checks that one call writes every part of a generated buffer from a
rich-text description (**criterion 1** of the rich-text roadmap's phase 7). -/
def richTextCallChecks : List Check :=
  let set := richFed "C-c s"
  [{  name :=
        "after rich-set the read-only buffer holds richHead's text and its spans, stops, links, folds and indents, with no rendered document, and the call answered ok"
      run :=
        pure <|
          match set with
          | none => false
          | some driver =>
            match richBuffer driver with
            | none => false
            | some buffer =>
              richValue driver "result" == some (.str "ok") && buffer.readOnly &&
                richContents driver == some richHead.text &&
                buffer.spans == richHead.spans &&
                buffer.stops == richHead.stops &&
                buffer.links == richHead.links &&
                buffer.folds == richHead.folds &&
                buffer.indents == richHead.indents &&
                buffer.markdown == none },
    { name :=
        "the next scene's view of the buffer carries every span, text.link over the link, the stops and the indents, and no fold, since every range is declared unfolded"
      run :=
        pure <|
          match set.bind richView with
          | none => false
          | some view => drawsRich view richHead && view.folds.isEmpty },
    { name := "with head declared folded the view's folds hold its placeholder"
      run :=
        pure <|
          match (richFed "C-c f").bind richView with
          | none => false
          | some view => view.folds.map (·.text) == #["[head]"] },
    { name :=
        "a write and an append of a buffer there is none of answer noSuchBuffer and change nothing"
      run :=
        pure <|
          match set, set.map fun driver => (fedTo driver (presses "C-c x")).1 with
          | some before, some after =>
            richValue after "absent-set" == some (.str "noSuchBuffer") &&
              richValue after "absent-append" == some (.str "noSuchBuffer") &&
              richContents after == richContents before &&
              after.loop.state.buffers.size == before.loop.state.buffers.size &&
              ((richBuffer after).map fun buffer =>
                  (buffer.spans, buffer.stops, buffer.links, buffer.folds, buffer.indents)) ==
                ((richBuffer before).map fun buffer =>
                  (buffer.spans, buffer.stops, buffer.links, buffer.folds, buffer.indents))
          | _, _ => false }]

/-- The checks that a description extended at its tail updates only the
buffer's tail, and that a write from a start keeps the buffer's prefix
(**criterion 2** of the rich-text roadmap's phase 7). -/
def richTextAppendChecks : List Check :=
  let size := richHead.text.utf8ByteSize
  let shifted := richTail.shift size
  let appended := richFed "C-c h C-c t"
  let redone := richFed "C-c h C-c t C-c r"
  [{  name :=
        "after rich-head then rich-tail the text is the head then the tail, and the text's log has no edit before the tail"
      run :=
        pure <|
          match appended with
          | none => false
          | some driver =>
            richValue driver "result" == some (.str "ok") &&
              richContents driver == some (richHead.text ++ richTail.text) &&
              match richValue driver "edited" with
              | some (.nat edited) => edited ≥ size
              | _ => false },
    { name :=
        "after the append each part before the head's end is exactly the head's, in order, and the rest the tail's moved past it; head is still folded, as toggled"
      run :=
        pure <|
          match appended.bind richBuffer with
          | none => false
          | some buffer =>
            buffer.spans == richHead.spans ++ shifted.spans &&
              buffer.stops == richHead.stops ++ shifted.stops &&
              buffer.links == richHead.links ++ shifted.links &&
              buffer.indents == richHead.indents ++ shifted.indents &&
              buffer.folds ==
                #[{ start := 0, stop := 9, key := "head", text := "[head]", folded := true },
                    { start := 0, stop := 18, key := "whole", text := "[whole]" }] ++
                  shifted.folds },
    { name := "the scene's view after the append carries both halves"
      run :=
        pure <|
          match appended.bind richView with
          | none => false
          | some view =>
            drawsRich view richHead && drawsRich view shifted &&
              view.folds.map (·.text) == #["[head]"] },
    { name :=
        "a write from the head's end whose description disagrees on the prefix keeps the buffer's bytes before it, with no edit there, and every prefix part as the buffer had it; from there on, and the fold crossing it, are the description's, each key declared once"
      run :=
        pure <|
          match redone with
          | none => false
          | some driver =>
            match richBuffer driver with
            | none => false
            | some buffer =>
              let fromEnd (rich : RichText) : RichText := RichText.replaceFrom {} size rich
              let tail := fromEnd richRedo
              richValue driver "result" == some (.str "ok") &&
                richContents driver == some (richHead.text ++ "redo\n") &&
                (match richValue driver "redone" with
                | some (.nat redone) => redone ≥ size
                | _ => false) &&
                buffer.spans == richHead.spans ++ tail.spans &&
                buffer.stops == richHead.stops ++ tail.stops &&
                buffer.links == richHead.links ++ tail.links &&
                buffer.indents == richHead.indents ++ tail.indents &&
                buffer.folds ==
                  #[{ start := 0, stop := 9, key := "head", text := "[head]", folded := true },
                    { start := 0, stop := 23, key := "whole", text := "[redo whole]" },
                    { start := 18, stop := 23, key := "new", text := "[new]" }] &&
                tail.spans == #[{ start := 18, stop := 22, face := ⟨"rich.new"⟩ }] }]

end ModelTest
