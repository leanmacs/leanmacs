import Editor.Api.Cases
import Editor.Buffers.Compiled
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Display.Model
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.File.Cases
import Editor.File.Model
import Editor.FileWatch.Model
import Editor.Files.Compiled
import Editor.Fuzzy.Model
import Editor.InputScheme.Test
import Editor.Job.Contract
import Editor.Job.Model
import Editor.Language
import Editor.Layout
import Editor.Loop.Driver
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.SyntaxTree.Model
import Editor.TabBar
import Editor.Watch.Model
import Editor.Window
import ModelTest.Modes

/-!
# Model tests: the driver and the prompt

The checks of the API's state, the driver, the prompt and its candidates,
opening files and languages, starting a window, file commands, quitting, ex
commands, and reloading stale files.

Its lists of checks: `apiStateChecks`, `driverChecks`, `promptLoopChecks`,
`echoPromptChecks`, `promptModeChecks`, `promptChecks`, `candidateChecks`,
`languageOpenChecks`, `windowStartChecks`, `openFilesChecks`,
`fileCommandChecks`, `dispatchQuitChecks`, `systemQuitChecks`, `exChecks`,
`fileReloadChecks`, `stalenessChecks`, `autoReloadChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- What `command`, run dispatched from the state `start` makes with nothing
told of the registry, returned on the editor's models, and the state it
left; `none` unless it ran to its end. -/
def dispatchedFrom {α : Type} (command : EditorM α) (start : TextM EditorState := twoBuffers) :
    Option (α × EditorState) :=
  let program : EditorM (Guarded α × EditorState) := do
    command.dispatched {} (← start)
  match (program.runModel editorModel).1 with
  | .ok (.finished value, state) => some (value, state)
  | _ => none

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
        "a prompt asked for with a function for its candidates holds what the function answered, and the function is run once: the text it makes is in the store once, beside the minibuffer's"
      run :=
        pure <|
          let made := "made by the function"
          let candidates : EditorM (Array String) := do
            discard <| createText made
            return #["wq", "edit", "w"]
          match dispatchedOn (prompt "Pick: " asked "w" (candidates := candidates)) with
          | some (.finished (.ok view), state, texts) =>
            state.prompt.map (·.candidates) == some { all := #["wq", "edit", "w"] } &&
              state.prompt.map (·.view) == some view &&
              (texts.filter (· == made)).size == 1 &&
              texts.contains "w" &&
              state.wellFormed
          | _ => false },
    { name :=
        "a prompt whose function for its candidates is refused refuses the asking command: no prompt is open and no text was made for a minibuffer"
      run :=
        pure <|
          let candidates : EditorM (Array String) := do
            discard <| (⟨99⟩ : TextId).read
            return #["a"]
          match dispatchedOn (prompt "Pick: " asked "w" (candidates := candidates)),
            dispatchedOn (pure () : EditorM Unit) with
          | some (.refused .noSuchText, state, texts), some (_, _, before) =>
            state.prompt == none && texts == before
          | _, _ => false },
    { name :=
        "while a prompt is open, asking for another with a function for its candidates is refused with alreadyOpen and the function is not run: it makes no text, and the open prompt's candidates are as they were"
      run :=
        pure <|
          let candidates : EditorM (Array String) := do
            discard <| createText "ran"
            return #["x"]
          match
            dispatchedOn do
              let first ← prompt "A: " asked
              return (first, ← prompt "B: " asked "" (candidates := candidates)) with
          | some (.finished (.ok view, .error (.alreadyOpen held)), state, texts) =>
            view == held && !texts.contains "ran" && state.prompt.map (·.candidates) == some {} &&
              state.prompt.map (·.label) == some "A: "
          | _ => false },
    { name :=
        "a prompt asked for with no function has no candidates, and leaves the state and the store as one asked for with a function that answers none"
      run :=
        pure <|
          match dispatchedOn (prompt "Name: " asked "hé"),
            dispatchedOn (prompt "Name: " asked "hé" (candidates := pure #[])) with
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
              let closed ← setCandidates #["a"]
              discard <| prompt "Pick: " asked (candidates := pure #["x", "y"])
              let before := (← editorState).prompt.map (·.candidates)
              return (closed, before, ← setCandidates #["a", "b"]) with
          | some (.finished (.error .notOpen, before, .ok ()), state, _) =>
            before == some { all := #["x", "y"] } &&
              state.prompt.map (·.candidates) == some { all := #["a", "b"] }
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
                state.answered[0]?.map (·.arguments)
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

/-- The driver the job checks run: one over the test scheme. -/
abbrev TestDriver :=
  Loop.Driver TestScheme.scheme

/-- The streaming child the driver checks' `streamer` starts: one that waits
for its input, which is never written. -/
def streamed : Process.Command :=
  { program := "/bin/cat", directory := "/p/d" }

/-- The jobs of the driver checks, by name. `double` doubles the number it
is started with, and its command inserts the result, in brackets, at the
cursor of view 0. `poster` posts `mark` with `p1`, sleeps 10 ms, posts `mark`
with `p2`, and finishes with a command that inserts `[end]`. `streamer`
starts `streamed` as a streaming child, posts `mark` with `s` and reads
the child, and finishes with a command that inserts `[streamed]`. `bad` finishes with a command that inserts and is then
refused. `chain` finishes with a command that starts `double` with 5.

Four reach files, in `fileRoot`. `load` loads the file it is named and
finishes with a command that makes a text of it. `adopt` loads nothing, and
finishes with a command that adopts the job snapshot of the number it is
started with. `save` saves the snapshot of the store whose index it is
started with as `out.txt`, which must not be there. `lose` loads `note.txt`
and then throws. -/
def driverJobs (name : String) : Option (List Argument → Work) :=
  let inserts (text : String) : EditorM Unit := discard <| (⟨0⟩ : ViewId).insertAtSelections text
  match name with
  | "double" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.nat n] := arguments | throw "double takes one number"
          sleep 10
          return 2 * n)
        fun n => inserts s!"[{n}]"
  | "bad" =>
    some fun _ =>
      Work.of (fun _ => pure ()) fun _ => do
        inserts "lost"
        (⟨0⟩ : TextId).delete 9 99
  | "chain" =>
    some fun _ => Work.of (fun _ => pure ()) fun _ => discard <| startJob "double" [.nat 5]
  | "load" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.str name] := arguments | throw "load takes one name"
          return (← JobContract.loaded (fileRoot / name)).snapshot)
        fun file => discard file.toText
  | "adopt" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.nat number] := arguments | throw "adopt takes one number"
          return number)
        fun number => discard (JobSnapshotId.mk number).adopt
  | "save" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.nat index] := arguments | throw "save takes one number"
          discard <| JobContract.saved (.snapshot ⟨index⟩) (fileRoot / "out.txt") .absent)
        fun _ => pure ()
  | "lose" =>
    some fun _ =>
      Work.of
        (fun _ => do
          discard <| JobContract.loaded (fileRoot / "note.txt")
          throw "lost")
        fun (_ : Unit) => pure ()
  | "build" =>
    some fun _ =>
      Work.of (fun _ => Process.run { program := "/bin/true", directory := "/p/d" } 10) fun _ =>
        pure ()
  | "poster" =>
    some fun _ =>
      Work.of
        (fun _ => do
          post { command := "mark", arguments := [.str "p1"] }
          sleep 10
          post { command := "mark", arguments := [.str "p2"] })
        fun _ => inserts "[end]"
  | "streamer" =>
    some fun _ =>
      Work.of
        (fun _ => do
          match ← Process.start streamed { input := true, bound := 64 } with
          | .ok child =>
            post { command := "mark", arguments := [.str "s"] }
            discard <| Process.read child
          | .error _ =>
            throw "streamer: refused")
        fun _ => inserts "[streamed]"
  | _ => none

/-- The commands of the driver checks, bound under `C-c`: `ask` (`a`)
messages `asked` and starts `double` with 21; `missing` (`m`) starts a job
no one registered and messages the refusal; `fail` (`f`) starts `double`
and is then refused; `none` (`n`) starts `double` with no argument; `bad`
(`b`) and `chain` (`c`) start the jobs of those names; `load` (`l`) starts
`load` with `note.txt`, `adopt` (`s`) starts `adopt` with 0, `save` (`w`)
takes a snapshot of its buffer's text and starts `save` with its index, and
`lose` (`t`) starts `lose`, and `build` (`e`) starts `build`, which runs
`/bin/true` in `/p/d`. `keyed` (`k`) starts `double` with 21 under the key
`k`, `cancel` (`x`) cancels the key `k`, `cancelFails` (`y`) cancels it
and is then refused, and `cancelAfterRead` (`z`) reads its buffer's text
and then cancels it. `post` (`p`) starts `poster` under the key `p`,
`stream` (`r`) starts `streamer` under the key `s`, and `cancelStream` (`v`)
cancels the key `s`; `mark`, which no key runs, inserts its argument at the
cursor of view 0, for the jobs' posts. -/
def driverKeys : Loop.Keys TestScheme.scheme :=
  let starts (name : String) (arguments : List Argument := []) : Dispatched := fun _ => do
    discard <| startJob name arguments
    return none
  dispatchKeys
    [("C-c a", invoke "ask"), ("C-c m", invoke "missing"), ("C-c f", invoke "fail"),
      ("C-c n", invoke "none"), ("C-c b", invoke "bad"), ("C-c c", invoke "chain"),
      ("C-c l", invoke "load"), ("C-c s", invoke "adopt"), ("C-c w", invoke "save"),
      ("C-c t", invoke "lose"), ("C-c e", invoke "build"), ("C-c k", invoke "keyed"),
      ("C-c x", invoke "cancel"), ("C-c y", invoke "cancelFails"),
      ("C-c z", invoke "cancelAfterRead"), ("C-c p", invoke "post"), ("C-c r", invoke "stream"),
      ("C-c v", invoke "cancelStream")]
    [("ask", fun _ => do
        message "asked"
        discard <| startJob "double" [.nat 21]
        return none),
      ("missing", fun _ => do
        if let .error (.noSuchJob name)← startJob "nope" [.nat 1] then
          message s!"no job {name}"
        return none),
      ("fail", failingAfter fun _ => discard <| startJob "double" [.nat 1]),
      ("none", starts "double"), ("bad", starts "bad"), ("chain", starts "chain"),
      ("load", starts "load" [.str "note.txt"]), ("adopt", starts "adopt" [.nat 0]),
      ("save", fun call => do
        let taken ← call.target.buffer.text.snapshot
        discard <| startJob "save" [.nat taken.index]
        return none),
      ("lose", starts "lose"), ("build", starts "build"),
      ("keyed", fun _ => do
        discard <| startJob "double" [.nat 21] (key := some "k")
        return none),
      ("cancel", fun _ => do
        cancelJob "k"
        return none),
      ("cancelFails", failingAfter fun _ => cancelJob "k"),
      ("cancelAfterRead", fun call => do
        -- A read of the text is a guarded request, which an interrupt ends:
        -- a command of state requests alone cannot be interrupted.
        discard <| call.target.buffer.text.read
        cancelJob "k"
        return none),
      ("post", fun _ => do
        discard <| startJob "poster" (key := some "p")
        return none),
      ("stream", fun _ => do
        discard <| startJob "streamer" (key := some "s")
        return none),
      ("cancelStream", fun _ => do
        cancelJob "s"
        return none),
      ("mark", fun call => do
        if let [.str text] := call.arguments then
          discard <| (⟨0⟩ : ViewId).insertAtSelections text
        return none)]

/-- A driver over the initial state, with the commands and the jobs of the
driver checks; `none` if making the state was refused. -/
def newDriver : Option TestDriver :=
  (Loop.Driver.over driverKeys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- `newDriver` whose jobs reach the directory `fileRoot`, holding the file
`note.txt` with `FileCases.noteBytes`. -/
def fileDriver : Option TestDriver :=
  newDriver.map fun driver =>
    { driver with jobs := { files := fileModelOf #[("note.txt", FileCases.noteBytes)] } }

/-- Feeds `driver` the `events` in order: the driver after them, and what
each step handed back, `none` for a step that was refused. -/
def fedTo (driver : TestDriver) (events : List Event) :
    TestDriver × Array (Option (Loop.Stepped TestScheme.scheme)) :=
  events.foldl
    (fun (driver, steps) event =>
      let (driver, stepped) := driver.feed { event, stamp := 0 }
      (driver, steps.push stepped.toOption))
    (driver, #[])

/-- What the buffer of view 0 holds in `driver`'s text model. -/
def driverText (driver : TestDriver) : Option String :=
  driver.model.texts.contents[0]?

/-- The checks of jobs started from commands (`Editor/Loop.lean`,
`Editor/Loop/Driver.lean`), on the loop's driver over the editor's models
and the job model: a command starts a job by its name with arguments, and
the job's result comes back as a command the loop delivers. -/
def driverChecks : List Check :=
  let started (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array JobStart :=
    steps.flatMap fun step => (step.map (·.starts)).getD #[]
  let echoOf (driver : TestDriver) : Option String := driver.model.display.scenes.back?.map (·.echo)
  [{  name :=
        "a job that posts is held at each post until it arrives: the post runs as a command labelled with the job, the job then goes on to its next post, and its own command runs after its posts"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c p")
            let (first, firstStep) := asked.posted 1
            let (typed, _) := fedTo first [.commit "-"]
            let (second, _) := typed.posted 1
            let (finished, _) := second.finish 1
            asked.posting.map (fun job => (job.id, job.invocation)) ==
                #[(1, { command := "mark", arguments := [.str "p1"] })] &&
              asked.pending.isEmpty &&
              driverText asked == some "" &&
              (firstStep.map (·.ended)) == some (some .finished) &&
              driverText first == some "p1" &&
              first.posting.map (fun job => (job.id, job.invocation)) ==
                #[(1, { command := "mark", arguments := [.str "p2"] })] &&
              first.jobs.now == 10 &&
              driverText typed == some "p1-" &&
              driverText second == some "p1-p2" &&
              second.posting.isEmpty &&
              second.pending.map (·.id) == #[1] &&
              driverText finished == some "p1-p2[end]" &&
              (asked.posted 2).2.isNone },
    { name :=
        "a job held at a post keeps its streaming child: another job that ends meanwhile leaves the child running, and a cancel of the held job's key drops it, its post never runs, and its child is recorded killed"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let driver :=
              { driver with
                jobs :=
                  {
                    processes :=
                      { streams := #[{ command := streamed, steps := #[.awaitClosed] }] } } }
            let (streaming, _) := fedTo driver (presses "C-c r")
            let (other, _) := fedTo streaming (presses "C-c a")
            let (cancelled, steps) := fedTo other (presses "C-c v")
            let (after, delivered) := cancelled.posted 1
            streaming.posting.map (fun job => (job.id, job.children.size)) == #[(1, 1)] &&
              streaming.jobs.processes.children.isEmpty &&
              other.pending.map (·.id) == #[2] &&
              other.jobs.processes.killed.isEmpty &&
              other.posting.map (fun job => job.children.size) == #[1] &&
              steps.flatMap (fun step => (step.map (·.cancels)).getD #[]) == #["s"] &&
              cancelled.posting.isEmpty &&
              cancelled.jobs.processes.killed == #[streamed] &&
              delivered.isNone &&
              driverText after == some "" },
    { name :=
        "a job whose directory's lookup fails leaves the loop's echo area saying why, as the host says it"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let child : Process.Command := { program := "/bin/true", directory := "/p/d" }
            let lookup := Process.lookupCommand "/opt/mise" "/p/d"
            let driver :=
              { driver with
                jobs :=
                  { environments := { setting := .mise (some "/opt/mise") }
                    processes :=
                      {
                        scripts :=
                          #[{ command := lookup
                              reply :=
                                .ok { exit := .code 1, stdout := .empty, stderr := .empty } },
                            { command := child
                              reply :=
                                .ok { exit := .code 0, stdout := .empty, stderr := .empty } }] } } }
            let (built, _) := fedTo driver (presses "C-c e")
            built.loop.state.echo == Process.failureMessage "/p/d" (.exited 1 "") &&
              built.jobs.processes.started == #[lookup, child] },
    { name :=
        "a command that starts a job with an argument: the step hands the start back, the job is run with that argument, and once it is finished a command has run that received the value the job computed from it; the delivery publishes a scene and leaves the echo the command left"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (asked, steps) := fedTo driver (presses "C-c a")
            let (finished, delivered) := asked.finish 1
            started steps == #[{ name := "double", arguments := [.nat 21] }] &&
              asked.pending.map (fun job => (job.id, job.name)) == #[(1, "double")] &&
              asked.loop.state.starts.isEmpty &&
              driverText asked == some "" &&
              echoOf asked == some "asked" &&
              (delivered.map (·.ended)) == some (some .finished) &&
              finished.pending.isEmpty &&
              driverText finished == some "[42]" &&
              echoOf finished == some "asked" &&
              finished.model.display.scenes.size == asked.model.display.scenes.size + 1 &&
              finished.jobs.now == 10 },
    { name :=
        "events fed after a job started and before its result is delivered are each handled before the result's command: two commits are both in the text, in order, after their own steps, the result's command has run after neither, and it runs when the job is finished"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c a")
            let (first, _) := fedTo asked [.commit "a"]
            let (second, _) := fedTo first [.commit "b"]
            let (finished, _) := second.finish 1
            driverText asked == some "" && driverText first == some "a" &&
              driverText second == some "ab" &&
              second.pending.size == 1 &&
              driverText finished == some "ab[42]" },
    { name :=
        "starting a job no one registered is refused with noSuchJob, a value the command sees, and starts nothing; a job started with arguments it does not take fails, and no command is delivered for it"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (missing, steps) := fedTo driver (presses "C-c m")
            let (wrong, wrongSteps) := fedTo driver (presses "C-c n")
            let (failed, delivered) := wrong.finish 1
            started steps == #[] && missing.pending.isEmpty &&
              echoOf missing == some "no job nope" &&
              started wrongSteps == #[{ name := "double" }] &&
              (wrong.pending.map fun job =>
                  job.outcome matches .failed "double takes one number") ==
                #[true] &&
              delivered.isNone &&
              failed.pending.isEmpty &&
              driverText failed == some "" },
    { name :=
        "a command that asked for a job and was then refused starts nothing: the step hands back no start, the state keeps none, and the echo says the refusal"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (failed, steps) := fedTo driver (presses "C-c f")
            started steps == #[] && failed.pending.isEmpty && failed.loop.state.starts.isEmpty &&
              (steps.back?.join.map (·.ended)) == some (some (.refused .badRange)) &&
              echoOf failed == some "fail: refused: bad range" },
    { name :=
        "a delivered command that is refused is rolled back: the text is as it was before the delivery, the echo names the job and the refusal, a scene is still published, and the loop goes on"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver ([.commit "ab"] ++ presses "C-c b")
            let (finished, delivered) := typed.finish 1
            let (after, _) := fedTo finished [.commit "c"]
            driverText typed == some "ab" && driverText finished == some "ab" &&
              (delivered.map (·.ended)) == some (some (.refused .badRange)) &&
              echoOf finished == some "job 1 bad: refused: bad range" &&
              finished.model.display.scenes.size == typed.model.display.scenes.size + 1 &&
              driverText after == some "abc" },
    { name :=
        "a command that cancels a key ends the pending job of that key: the step hands the key back, the job is no longer pending, and finishing it delivers nothing"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (asked, steps) := fedTo driver (presses "C-c k")
            let (cancelled, cancelSteps) := fedTo asked (presses "C-c x")
            let (finished, delivered) := cancelled.finish 1
            started steps == #[{ name := "double", arguments := [.nat 21], key := some "k" }] &&
              asked.pending.map (·.id) == #[1] &&
              cancelSteps.flatMap (fun step => (step.map (·.cancels)).getD #[]) == #["k"] &&
              cancelled.loop.state.cancels.isEmpty &&
              cancelled.pending.isEmpty &&
              delivered.isNone &&
              driverText finished == some "" },
    { name :=
        "a command that cancels a key and is then refused, or is interrupted, cancels nothing: the job of that key is still pending, and the refused one's job is delivered when it finishes"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c k")
            let (refused, refusedSteps) := fedTo asked (presses "C-c y")
            let flagged := { asked with model := { asked.model with watch := { arrived := 1 } } }
            let (interrupted, interruptedSteps) := fedTo flagged (presses "C-c z")
            let (finished, _) := refused.finish 1
            let cancels (steps : Array (Option (Loop.Stepped TestScheme.scheme))) :=
              steps.flatMap fun step => (step.map (·.cancels)).getD #[]
            cancels refusedSteps == #[] && refused.pending.map (·.id) == #[1] &&
              refused.loop.state.cancels.isEmpty &&
              echoOf refused == some "cancelFails: refused: bad range" &&
              cancels interruptedSteps == #[] &&
              interrupted.pending.map (·.id) == #[1] &&
              echoOf interrupted == some "cancelAfterRead: interrupted" &&
              driverText finished == some "[42]" },
    { name :=
        "a command that starts a job of a key while one of that key is pending cancels the first: only the second is pending, finishing the first delivers nothing, and the second's command is delivered"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (first, _) := fedTo driver (presses "C-c k")
            let (second, _) := fedTo first (presses "C-c k")
            let (gone, nothing) := second.finish 1
            let (finished, _) := gone.finish 2
            second.pending.map (·.id) == #[2] && nothing.isNone && driverText gone == some "" &&
              driverText finished == some "[42]" },
    { name :=
        "a delivered command may itself start a job: the delivery hands the start back, the job gets the next id, and its result is delivered in its turn; finishing an id that names no job started changes nothing"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (chained, _) := fedTo driver (presses "C-c c")
            let (first, delivered) := chained.finish 1
            let (unknown, nothing) := first.finish 7
            let (second, _) := unknown.finish 2
            (delivered.map (·.starts)) == some #[{ name := "double", arguments := [.nat 5] }] &&
              first.pending.map (fun job => (job.id, job.name)) == #[(2, "double")] &&
              nothing.isNone &&
              unknown.pending.size == 1 &&
              driverText unknown == some "" &&
              driverText second == some "[10]" },
    { name :=
        "a command run by its name is run as a key's is, with the focused window, no keys and the echo cleared, and a scene is published after it; a name no command has is said in the echo, and the step says which it was"
      run :=
        pure <|
          let program : EditorM (Array (Option Loop.Ending) × Array String × String) := do
            let loop : TestLoop := { state := { (← holding "abcd" #[⟨1, 3⟩]) with echo := "old" } }
            let keys := dispatchKeys [] [("stamp", stamp), ("boom", boom)]
            let stamped ← loop.runNamed keys "stamp"
            let failed ← stamped.loop.runNamed keys "boom"
            let unknown ← failed.loop.runNamed keys "nope"
            return (#[stamped.ended, failed.ended, unknown.ended],
                #[stamped.loop.state.echo, failed.loop.state.echo, unknown.loop.state.echo],
                ← (← focusedOf unknown.loop).buffer.text.read)
          match program.runModel editorModel with
          | (.ok (endings, echoes, text), model) =>
            endings == #[some .finished, some (.refused .badRange), some .noSuchCommand] &&
              echoes == #["", "boom: refused: bad range", "nope: no such command"] &&
              text == "ad" &&
              model.display.scenes.map (·.echo) == echoes
          | (.error _, _) => false },
    { name :=
        "a finished job's command is handed what the job loaded: a job that loads a file finishes with a command that makes a text of it, and once the job is finished the store holds the file's text in a new text, no snapshot more than before, and nothing is left as handed or held"
      run :=
        pure <|
          match fileDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c l")
            let (finished, delivered) := asked.finish 1
            asked.model.texts.contents == #[""] &&
              (delivered.map (·.ended)) == some (some .finished) &&
              finished.model.texts.contents == #["", FileCases.noteText] &&
              finished.model.texts.snapshots.filterMap id ==
                asked.model.texts.snapshots.filterMap id &&
              finished.model.texts.arrived.isEmpty &&
              finished.jobs.files.held == #[none] },
    { name :=
        "what a job loaded is handed to its own command and to no other: a second job's command that adopts the first job's snapshot is refused with noSuchSnapshot when it is delivered before the first job's command and when it is delivered after it, and the first job's command still makes its text"
      run :=
        pure <|
          match fileDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c l C-c s")
            let (early, stolen) := asked.finish 2
            let (made, delivered) := early.finish 1
            let (again, _) := fedTo made (presses "C-c s")
            let (late, gone) := again.finish 3
            (stolen.map (·.ended)) == some (some (.refused .noSuchSnapshot)) &&
              (delivered.map (·.ended)) == some (some .finished) &&
              (gone.map (·.ended)) == some (some (.refused .noSuchSnapshot)) &&
              late.model.texts.contents == #["", FileCases.noteText] },
    { name :=
        "a job reads a snapshot its command took: a command takes a snapshot of its buffer's text and starts a job with its index, the job saves that snapshot, and the files then hold its bytes"
      run :=
        pure <|
          match fileDriver with
          | none => false
          | some driver =>
            let (saved, _) := fedTo driver ([.commit "héllo"] ++ presses "C-c w")
            (saved.pending.map fun job => job.outcome matches .finished _) == #[true] &&
              (saved.jobs.files.file? (fileRoot / "out.txt")).map (·.bytes) ==
                some "héllo".toUTF8 },
    { name :=
        "a job that loads and then throws holds nothing afterwards: its snapshot is released when it ends, and no command is delivered for it"
      run :=
        pure <|
          match fileDriver with
          | none => false
          | some driver =>
            let (lost, _) := fedTo driver (presses "C-c t")
            let (finished, delivered) := lost.finish 1
            (lost.pending.map fun job => job.outcome matches .failed "lost") == #[true] &&
              lost.jobs.files.held == #[none] &&
              delivered.isNone &&
              finished.model.texts.contents == #[""] }]

/-- What the command `greet` of the prompt checks says in the echo area: the
arguments it was called with, the view of its target, and how many keys it
was told of. -/
def greeted (arguments : List Argument) (view : Nat := 0) (keys : Nat := 0) : String :=
  s!"greet {arguments.map argumentText} in view {view} with {keys} keys"

/-- The invocation the command `hand` of the prompt checks asks to be run
after it: `greet`, with two arguments of its own. -/
def handed : Invocation :=
  { command := "greet", arguments := [.str "handed", .nat 3] }

/-- The commands of the prompt checks, by name.

- `ask` asks `Name: ` with the continuation `asked`, the command `greet`
  and the argument 7, and says the refusal when it is refused. `ask-missing`,
  `ask-boom`, `ask-again` and `ask-job` ask the same with the continuations
  `nobody`, which no command is registered under, `boom`, `ask` and `start`.
  `ask-then-fail` asks and is then refused.
- `accept` and `cancel` are the API's operations.
- `greet` says what it was called with (`greeted`).
- The test scheme's self-insert inserts its argument at its target's
  cursors.
- `boom` inserts and is then refused, `other` says `other`, and `start`
  starts the job `double`.
- `hand` says `handing` and asks for `handed` to be run after it
  (`invoke`, `Editor/Api.lean`), with no prompt; `hand-then-fail` asks the
  same and is then refused; `hand-missing` asks for a command nobody
  registered. -/
def promptCommands : List (String × Dispatched) :=
  let asks (continuation : Invocation) : Dispatched := fun _ => do
    if let .error refusal← prompt "Name: " continuation then
      message s!"not asked: {refusal.describe}"
    return none
  let says (text : String) : Dispatched := fun _ => do
    message text
    return none
  [("ask", asks asked), ("ask-missing", asks { command := "nobody" }),
    ("ask-boom", asks { command := "boom" }), ("ask-again", asks { command := "ask" }),
    ("ask-job", asks { command := "start" }),
    ("ask-then-fail", failingAfter fun _ => discard <| prompt "Name: " asked),
    ("accept", fun _ => do
      discard acceptPrompt
      return none),
    ("cancel", fun _ => do
      discard cancelPrompt
      return none),
    ("greet", fun call =>
      says (greeted call.arguments call.target.window.id.index call.keys.length) call),
    ((TestScheme.selfInsert "").command, fun call => do
      let [.str text] := call.arguments | throw .badRange
      call.target.insertAtSelections text
      return none),
    ("boom", boom), ("other", says "other"),
    ("start", fun _ => do
      discard <| startJob "double" [.nat 21]
      return none),
    ("hand", fun _ => do
      message "handing"
      Editor.invoke handed
      return none),
    ("hand-then-fail", failingAfter fun _ => Editor.invoke handed),
    ("hand-missing", fun _ => do
      Editor.invoke { command := "nobody" }
      return none)]

/-- What a step of the prompt checks is handed: one keymap, the same for
every view, the minibuffer's among them, that binds a key sequence under
`C-c` to each command of `promptCommands` but the self-insert, `greet` and
`start`, which no key runs. No key of it prints, so a key that prints is a
self-insert. -/
def promptKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    [("C-c a", invoke "ask"), ("C-c m", invoke "ask-missing"), ("C-c x", invoke "ask-boom"),
      ("C-c r", invoke "ask-again"), ("C-c j", invoke "ask-job"), ("C-c f", invoke "ask-then-fail"),
      ("C-c y", invoke "accept"), ("C-c n", invoke "cancel"), ("C-c b", invoke "boom"),
      ("C-c o", invoke "other"), ("C-c h", invoke "hand"), ("C-c g", invoke "hand-then-fail"),
      ("C-c k", invoke "hand-missing")]
    promptCommands

/-- A driver over the initial state, with the commands of the prompt checks
and the jobs of the driver checks; `none` if making the state was
refused. -/
def promptDriver : Option TestDriver :=
  (Loop.Driver.over promptKeys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- What the minibuffer holds in `driver`'s text model, while a prompt is
open. -/
def minibufferText (driver : TestDriver) : Option String := do
  let state := driver.loop.state
  let buffer ← state.buffer? (← state.minibufferBuffer?)
  (← driver.model.texts.texts[buffer.text.index]?).map (·.contents)

/-- The echo area of `driver`'s loop. -/
def promptEcho (driver : TestDriver) : String :=
  driver.loop.state.echo

/-- The checks of prompts through the loop and its host (`Editor/Loop.lean`,
`Editor/Loop/Driver.lean`), on the loop's driver over the editor's models
and the test scheme, with commands written here under keys of the global
keymap: the answer a step hands back, the answer's command run before the
next event, and rollback and the interrupt around an open prompt. -/
def promptLoopChecks : List Check :=
  let answer (text : String) : List Argument := [.str text, .nat 7]
  let closed (driver : TestDriver) : Bool :=
    let state := driver.loop.state
    state.prompt == none && state.windows.map (·.id) == #[⟨0⟩] && state.frame.focused == ⟨0⟩ &&
      state.answered.isEmpty &&
      state.wellFormed
  [{  name :=
        "ask, then accept: the accepting step hands back one answered invocation, the continuation with the answer first, and the answer's command has then run with those arguments, the asking view as its target and no keys; the loop's state keeps no answer, and the scene after it has one view"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (accepted, steps) := fedTo asking (presses "C-c y")
            asking.loop.state.prompt.map (·.continuation) == some asked &&
              asking.loop.state.frame.focused == ⟨1⟩ &&
              steps.map (·.map (·.answered)) ==
                #[some #[], some #[{ command := "greet", arguments := answer "" }]] &&
              promptEcho accepted == greeted (answer "") &&
              closed accepted &&
              accepted.model.display.scenes.size == asking.model.display.scenes.size + 3 &&
              (accepted.model.display.scenes.back?.map fun scene =>
                  (scene.views.map (·.id), scene.echo)) ==
                some (#[⟨0⟩], greeted (answer "")) },
    { name :=
        "ask, two keys that print, then accept: the keys are typed into the minibuffer and not into the asking window, and the answer's command receives the two characters, in order"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            let (accepted, _) := fedTo typed (presses "C-c y")
            minibufferText typed == some "hi" && driverText typed == some "" &&
              promptEcho accepted == greeted (answer "hi") &&
              closed accepted &&
              driverText accepted == some "" },
    { name :=
        "ask, accept, then a key bound to another command: the answer's command ran before that key was handled, and the echo area is then the other command's"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (after, _) := fedTo asking (presses "C-c y C-c o")
            (after.model.display.scenes.map (·.echo)).extract asking.model.display.scenes.size ==
                #["", "", greeted (answer ""), greeted (answer ""), "other"] &&
              promptEcho after == "other" },
    { name :=
        "a continuation no command is registered under: the echo area says there is no such command, by the continuation's name, and the prompt is closed with the focus on the asking view"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (accepted, _) := fedTo driver (presses "C-c m C-c y")
            promptEcho accepted == "nobody: no such command" && closed accepted },
    { name :=
        "a continuation that is refused after an edit: the echo area says the refusal under the continuation's name, the edit is rolled back, the prompt stays closed, and nothing is answered again"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (accepted, steps) := fedTo driver (presses "C-c x C-c y")
            promptEcho accepted == "boom: refused: bad range" && driverText accepted == some "" &&
              closed accepted &&
              (steps.back?.join.map (·.answered.map (·.command))) == some #["boom"] },
    { name :=
        "a command that asks for an invocation to be run after it, with no prompt: its step hands the invocation back, the invocation's command then runs as a step of its own, with the invocation's arguments, the focused view as its target and no keys, before a key fed next is handled, and the loop's state keeps nothing to run"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (ran, steps) := fedTo driver (presses "C-c h")
            let (after, _) := fedTo ran (presses "C-c o")
            steps.map (·.map (·.answered)) == #[some #[], some #[handed]] &&
              promptEcho ran == greeted handed.arguments &&
              closed ran &&
              (after.model.display.scenes.map (·.echo)).extract driver.model.display.scenes.size ==
                #["", "handing", greeted handed.arguments, greeted handed.arguments, "other"] },
    { name :=
        "a command that asks for an invocation to be run after it and is then refused has nothing run: its step hands back no invocation, and the echo area says the refusal under the command's name"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (failed, steps) := fedTo driver (presses "C-c g")
            steps.map (·.map (·.answered)) == #[some #[], some #[]] &&
              promptEcho failed == "hand-then-fail: refused: bad range" &&
              closed failed },
    { name :=
        "a command that asks for a command nobody registered to be run after it: the echo area says there is no such command, by that name, and the next key's command runs"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (ran, _) := fedTo driver (presses "C-c k")
            let (after, _) := fedTo ran (presses "C-c o")
            promptEcho ran == "nobody: no such command" && closed ran &&
              promptEcho after == "other" },
    { name :=
        "a command that asks and is then refused opens no prompt: there is one window, with the focus, and the echo area says the refusal under the command's name"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (failed, _) := fedTo driver (presses "C-c f")
            promptEcho failed == "ask-then-fail: refused: bad range" && closed failed },
    { name :=
        "a command that fails in the minibuffer while a prompt is open is rolled back with the prompt open: its edit is taken back, and the minibuffer holds what was typed"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            let (failed, _) := fedTo typed (presses "C-c b")
            promptEcho failed == "boom: refused: bad range" &&
              failed.loop.state.prompt == typed.loop.state.prompt &&
              failed.loop.state.prompt.isSome &&
              failed.loop.state.frame.focused == ⟨1⟩ &&
              minibufferText failed == some "hi" &&
              failed.loop.state.wellFormed },
    { name :=
        "the interrupt key arriving as the accept command reads the minibuffer: the echo area says the command was interrupted, the prompt is open with its text, and nothing was answered; once the key is taken off the queue a second accept answers"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            -- The accept command's first request of the library is its read
            -- of the minibuffer's text: the key arrives as the flag is asked
            -- before it.
            let arriving : TestDriver :=
              { typed with model := { typed.model with watch := { arrivesAfter := some 0 } } }
            let (stopped, steps) := fedTo arriving (presses "C-c y")
            let (lowered, _) := stopped.feed interruptArrives
            let (accepted, _) := fedTo lowered (presses "C-c y")
            (steps.back?.join.map fun step => (step.ended, step.answered)) ==
                some (some .interrupted, #[]) &&
              promptEcho stopped == "accept: interrupted" &&
              stopped.loop.state.prompt == typed.loop.state.prompt &&
              stopped.loop.state.answered.isEmpty &&
              minibufferText stopped == some "hi" &&
              stopped.model.watch.arrived == 1 &&
              lowered.model.watch.arrived == 0 &&
              lowered.loop.state.prompt.isSome &&
              promptEcho accepted == greeted (answer "hi") &&
              closed accepted },
    { name :=
        "cancel makes no request of the library: with the interrupt flag up it still closes the prompt, and the continuation does not run"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let raised : TestDriver :=
              { asking with model := { asking.model with watch := { arrived := 1 } } }
            let (cancelled, steps) := fedTo raised (presses "C-c n")
            (steps.back?.join.map fun step => (step.ended, step.answered)) ==
                some (some .finished, #[]) &&
              promptEcho cancelled == "" &&
              closed cancelled },
    { name :=
        "a continuation that asks again leaves a second prompt open, in a view no view had, whose asker is the first asking view"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (again, _) := fedTo driver (presses "C-c r C-c y")
            again.loop.state.prompt ==
                some { label := "Name: ", view := ⟨2⟩, asker := ⟨0⟩, continuation := asked } &&
              again.loop.state.frame.focused == ⟨2⟩ &&
              again.loop.state.windows.map (·.id) == #[⟨0⟩, ⟨2⟩] &&
              promptEcho again == "" &&
              again.loop.state.wellFormed },
    { name :=
        "an answer's command that starts a job has the job started: the driver holds it as started and not delivered, and its result's command runs when it is finished"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (accepted, _) := fedTo driver (presses "C-c j C-c y")
            let (finished, _) := accepted.finish 1
            accepted.pending.map (fun job => (job.id, job.name)) == #[(1, "double")] &&
              closed accepted &&
              driverText finished == some "[42]" }]

/-- The keys of the echo checks: `C-c b` runs `say-then-ask`, which says
`before` and then asks as `ask` does, and `C-c n` cancels. -/
def echoKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys [("C-c b", invoke "say-then-ask"), ("C-c n", invoke "cancel")]
    (promptCommands ++
      [("say-then-ask", fun _ => do
          message "before"
          discard <| prompt "Name: " asked
          return none)])

/-- A driver over the initial state with `echoKeys`, after `C-c b`: the
prompt `say-then-ask` asked for is open. `none` if making the state was
refused. -/
def echoAsking : Option TestDriver :=
  (Loop.Driver.over echoKeys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => (fedTo driver (presses "C-c b")).1

/-- `driver` after the loop has delivered `command` as a finished job's
(`Loop.deliver`), which clears no echo. -/
def echoDelivered (driver : TestDriver) (command : EditorM Unit) : TestDriver :=
  (driver.stepped (driver.loop.deliver driver.handed "job 1 test" command)).1

/-- The checks that opening a prompt clears the echo area (`EditorState.openPrompt`,
D7 of the display pipeline's last phase), through the loop: a command that
says something and then asks leaves no echo, and what a job's command says
while the prompt is open is kept. A key's command clears the echo before it
runs (`Loop.run`), so the checks close the prompt from a delivered job's
command too, which clears nothing: only then does the echo the prompt was
opened over show whether the open cleared it. -/
def echoPromptChecks : List Check :=
  let asking := echoAsking
  let delivered := echoDelivered
  let sceneEcho (driver : TestDriver) : Option String :=
    driver.model.display.scenes.back?.map (·.echo)
  let cancels : EditorM Unit := discard cancelPrompt
  [{  name :=
        "a command that says something and then asks for a prompt leaves the echo empty: in the state and in the scene after its key, and once the prompt is closed by the cancel key or by a job's command"
      run :=
        pure <|
          match asking with
          | none => false
          | some driver =>
            let (cancelled, _) := fedTo driver (presses "C-c n")
            let closedByJob := delivered driver cancels
            driver.loop.state.prompt.isSome && promptEcho driver == "" &&
              sceneEcho driver == some "" &&
              cancelled.loop.state.prompt.isNone &&
              promptEcho cancelled == "" &&
              closedByJob.loop.state.prompt.isNone &&
              promptEcho closedByJob == "" &&
              sceneEcho closedByJob == some "" },
    { name :=
        "a job's command that says something while the prompt is open leaves it in the echo, and it is still there once that command has closed the prompt: it was said after the prompt opened"
      run :=
        pure <|
          match asking with
          | none => false
          | some driver =>
            let loaded := delivered driver (message "loaded")
            let closed :=
              delivered driver
                (do
                  message "loaded";
                  cancels)
            loaded.loop.state.prompt.isSome && promptEcho loaded == "loaded" &&
              sceneEcho loaded == some "loaded" &&
              closed.loop.state.prompt.isNone &&
              promptEcho closed == "loaded" &&
              sceneEcho closed == some "loaded" }]

/-- The commands of the minibuffer checks that `promptCommands` does not
have, by name: `ask-ada` asks as `ask` does, with the initial value `Ada`;
`to-window` focuses view 0, and `to-minibuffer` the minibuffer's view;
`close-asker` closes the view the open prompt was asked from. -/
def minibufferCommands : List (String × Dispatched) :=
  let ran (run : EditorM Unit) : Dispatched := fun _ => do
    run
    return none
  [("ask-ada", ran (discard <| prompt "Name: " asked "Ada")),
    ("to-window", ran (discard <| (⟨0⟩ : ViewId).focus)),
    ("to-minibuffer",
      ran do
        if let some view := (← editorState).minibufferView? then
          discard view.focus),
    ("close-asker",
      ran do
        if let some asking := (← editorState).prompt then
          discard asking.asker.close)]

/-- The global bindings of the minibuffer checks: a key sequence under `C-c`
and the name of the command it runs. The last two run the minibuffer's own
commands by their names, from any view. -/
def minibufferBindings : List (String × String) :=
  [("C-c a", "ask"), ("C-c i", "ask-ada"), ("C-c s", "start"), ("C-c w", "to-window"),
    ("C-c v", "to-minibuffer"), ("C-c k", "close-asker"), ("C-c 1", Minibuffer.acceptName),
    ("C-c 2", Minibuffer.cancelName)]

/-- The registry of the minibuffer checks: the minibuffer's commands and its
mode registered for the owner `compiled`, as a host registers them, and the
checks' bindings as config's. -/
def minibufferRegistry : Config.Registry :=
  ((({} : Config.Registry).replace .compiled Minibuffer.commands).replaceModes .compiled
        Minibuffer.modes).replaceBindings
    .config (minibufferBindings.toArray.map fun (text, command) => { keys := keys text, command })

/-- What a step of the minibuffer checks is handed: the active keymaps the
registry makes for the test scheme from the loop's state, so the
minibuffer's mode holds in the minibuffer's view and nowhere else; the
registry's commands, each given its call; and, for any other name, the
commands of the prompt checks and of these. -/
def minibufferKeys : Loop.Keys TestScheme.scheme :=
  { maps := minibufferRegistry.activeMaps TestScheme.scheme
    command? := fun name =>
      match minibufferRegistry.find? name with
      | some { registration := { action := .call run, .. }, .. } =>
        some fun call => do
          run call
          return none
      | _ => ((promptCommands ++ minibufferCommands).find? (·.1 == name)).map (·.2) }

/-- A driver of the minibuffer checks over the state `start` makes, with the
jobs of the driver checks; `none` if making the state was refused. -/
def minibufferDriver (start : TextM EditorState := EditorState.initial ⟨640, 480⟩) :
    Option TestDriver :=
  (Loop.Driver.over minibufferKeys driverJobs start editorModel).toOption

/-- A press of each key the test scheme has `role` on. -/
def rolePresses (role : Role) : List Event :=
  (roleKeys role).map press

/-- What reading the text `text` comes to on `driver`'s models. -/
def readOn (driver : TestDriver) (text : TextId) : TextError ⊕ String :=
  let read : EditorM String := text.read
  resulted (read.runModel driver.model).1

/-- The text of the minibuffer's buffer in `driver`'s state, while a prompt
is open. -/
def minibufferTextId (driver : TestDriver) : Option TextId := do
  let state := driver.loop.state
  return (← state.buffer? (← state.minibufferBuffer?)).text

/-- What the last scene `driver`'s display recorded shows of the open
prompt: the text and the status line of the minibuffer's view, whether it
is the focused view, and the status line of view 0. `none` when no prompt
is open or the scene lacks either view. -/
def promptScene (driver : TestDriver) :
    Option (Option String × Array StatusField × Bool × Array StatusField) := do
  let scene ← driver.model.display.scenes.back?
  let view ← driver.loop.state.minibufferView?
  let minibuffer ← scene.views.find? (·.id == view)
  let window ← scene.views.find? (·.id == ⟨0⟩)
  return (shownText driver.model minibuffer, minibuffer.status, scene.focused == some view,
      window.status)

/-- The checks of the minibuffer's commands and its mode
(`Editor/Minibuffer.lean`, `Editor/Minibuffer/Compiled.lean`), on the
loop's driver over the editor's models and the test scheme, with the
registry's active keymaps: the phase's acceptance criteria on the models.
The accept key and the cancel key are the test scheme's keys for the roles
the mode fills (`InputScheme.roleKey`), so no check names a key of
either. -/
def promptModeChecks : List Check :=
  let accept := rolePresses Role.activate
  let cancel := rolePresses Role.quit
  let answer (text : String) : List Argument := [.str text, .nat 7]
  let closed (driver : TestDriver) (view : ViewId := ⟨0⟩) : Bool :=
    let state := driver.loop.state
    state.prompt == none && state.frame.focused == view && state.answered.isEmpty &&
      state.wellFormed
  [{  name :=
        "criterion 1: a command prompts, keys are typed and the accept key is pressed: the continuation's command receives the typed string, with the asking view as its target, and the minibuffer's window is closed; the state has no prompt, one window, the tree it had and the focus on the asking view, the minibuffer's buffer slot is empty and its text refuses noSuchText, and the scene has one view"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            let (accepted, _) := fedTo typed accept
            !accept.isEmpty && minibufferText typed == some "hi" &&
              typed.loop.state.minibufferBuffer? == some ⟨1⟩ &&
              (minibufferTextId typed).map (readOn typed) == some (.inr "hi") &&
              promptEcho accepted == greeted (answer "hi") &&
              closed accepted &&
              accepted.loop.state.windows.map (·.id) == #[⟨0⟩] &&
              accepted.loop.state.frame.windows == driver.loop.state.frame.windows &&
              accepted.loop.state.buffers[1]? == some none &&
              (minibufferTextId typed).map (readOn accepted) == some (.inl .noSuchText) &&
              (accepted.model.display.scenes.back?.map (·.views.map (·.id))) == some #[⟨0⟩] },
    { name :=
        "criterion 2: a prompt given an initial value and accepted with no key typed: the continuation's command receives the initial value"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c i")
            let (accepted, _) := fedTo asking accept
            minibufferText asking == some "Ada" && promptEcho accepted == greeted (answer "Ada") &&
              closed accepted },
    { name :=
        "criterion 3: the prompt is cancelled: the continuation's command does not run, nothing is answered, the focus returns to the view that had it, and the minibuffer's text is released; the same keys with the accept key in place of the cancel key do run it"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            let (cancelled, steps) := fedTo typed cancel
            let (accepted, _) := fedTo typed accept
            !cancel.isEmpty && cancel != accept && typed.loop.state.frame.focused == ⟨1⟩ &&
              promptEcho cancelled == "" &&
              steps.all (·.all (·.answered.isEmpty)) &&
              closed cancelled &&
              cancelled.loop.state.windows.map (·.id) == #[⟨0⟩] &&
              (minibufferTextId typed).map (readOn cancelled) == some (.inl .noSuchText) &&
              cancelled.model.display.scenes.all (·.echo != greeted (answer "hi")) &&
              promptEcho accepted == greeted (answer "hi") },
    { name :=
        "criterion 4: a job completes while a prompt is open: its result's command runs, to its end, before the prompt is answered, and inserts in the window's buffer; the prompt is still open, with its text and the focus, and the keys typed afterwards and the accept key answer it with everything typed"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c s C-c a h")
            let (delivered, step) := typed.finish 1
            let (accepted, _) := fedTo delivered (presses "i" ++ accept)
            typed.pending.map (·.id) == #[1] && driverText typed == some "" &&
              (step.map (·.ended)) == some (some .finished) &&
              driverText delivered == some "[42]" &&
              delivered.loop.state.prompt == typed.loop.state.prompt &&
              delivered.loop.state.prompt.isSome &&
              delivered.loop.state.frame.focused == ⟨1⟩ &&
              minibufferText delivered == some "h" &&
              promptEcho accepted == greeted (answer "hi") &&
              closed accepted &&
              driverText accepted == some "[42]" },
    { name :=
        "criterion 5: while a prompt is open the scene shows the prompt text and the input typed so far in the minibuffer's view: after the prompt is asked for and after each key that prints, the last scene has that view with the text so far, the label alone as its status line, in the prompt's face, and the focus, and view 0 with its own status line"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (one, _) := fedTo asking (presses "h")
            let (two, _) := fedTo one (presses "i")
            let showing (text : String) :=
              some
                (some text, #[({ text := "Name: ", face := Loop.promptFace } : StatusField)], true,
                  modeLineOf)
            promptScene driver == none && promptScene asking == showing "" &&
              promptScene one == showing "h" &&
              promptScene two == showing "hi" },
    { name :=
        "with no prompt open the minibuffer's accept command and its cancel command, each run by a key of the global keymap, say that no prompt is open and change nothing else; and the keys of the two roles, typed in a view whose buffer does not have the minibuffer's mode, run no command"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let said (typed : String) : Bool :=
              let (after, _) := fedTo driver (presses typed)
              after.loop.state == { driver.loop.state with echo := Minibuffer.notOpen }
            let (unbound, steps) := fedTo driver (accept ++ cancel)
            !Minibuffer.notOpen.isEmpty && said "C-c 1" && said "C-c 2" &&
              steps.all (·.all (·.ended.isNone)) &&
              unbound.loop.state == driver.loop.state },
    { name :=
        "a second prompt asked for while one is open, by a key of the global keymap typed in the minibuffer: the command says the refusal, the first prompt is still open with its text, and no text was made"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h")
            let (again, _) := fedTo typed (presses "C-c a")
            promptEcho again == s!"not asked: {(PromptRefusal.alreadyOpen ⟨1⟩).describe}" &&
              again.loop.state.prompt == typed.loop.state.prompt &&
              again.loop.state.prompt.isSome &&
              minibufferText again == some "h" &&
              again.model.texts.texts.size == typed.model.texts.texts.size },
    { name :=
        "a prompt does not capture the keyboard: with the focus moved to the window while the prompt is open, a key that prints goes to the window's buffer and the prompt waits; with the focus moved back, the accept key answers with what the minibuffer held"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (away, _) := fedTo driver (presses "C-c a h C-c w x")
            let (back, _) := fedTo away (presses "C-c v")
            let (accepted, _) := fedTo back accept
            away.loop.state.frame.focused == ⟨0⟩ && away.loop.state.prompt.isSome &&
              driverText away == some "x" &&
              minibufferText away == some "h" &&
              back.loop.state.frame.focused == ⟨1⟩ &&
              promptEcho accepted == greeted (answer "h") &&
              closed accepted &&
              driverText accepted == some "x" },
    { name :=
        "with the asking view closed while the prompt is open: the prompt stays open, and after the accept key the focus is on the first window of the list, which is the target of the continuation's command"
      run :=
        pure <|
          match minibufferDriver twoBuffers with
          | none => false
          | some driver =>
            let (closing, _) := fedTo driver (presses "C-c a h C-c k")
            let (accepted, _) := fedTo closing accept
            closing.loop.state.prompt.map (·.asker) == some ⟨0⟩ &&
              closing.loop.state.windows.map (·.id) == #[⟨1⟩, ⟨2⟩] &&
              closing.loop.state.frame.focused == ⟨2⟩ &&
              promptEcho accepted == greeted (answer "h") 1 &&
              closed accepted ⟨1⟩ &&
              accepted.loop.state.windows.map (·.id) == #[⟨1⟩] },
    { name :=
        "the minibuffer's commands are registered under their seven names, each another, the one that asks for the input scheme under the name the Vim scheme yields; its one mode is called by the name the minibuffer's buffer is made with, fills four roles, to accept, to cancel and to move to the next and the previous candidate, each with its command, and has no problem under the test scheme"
      run :=
        pure
          (Minibuffer.commands.map (·.name) ==
              #[Minibuffer.acceptName, Minibuffer.cancelName, Minibuffer.nextName,
                Minibuffer.previousName, Minibuffer.deleteBackwardName,
                Minibuffer.deleteToStartName, Minibuffer.askName] &&
            (Minibuffer.commands.map (·.name)).toList.eraseDups.length == 7 &&
            Minibuffer.askName == Vim.askCommand &&
            Minibuffer.modes.map (·.name) == #[Prompt.mode] &&
            Minibuffer.modes.map (·.roles) ==
              #[[(Role.activate, Minibuffer.acceptName), (Role.quit, Minibuffer.cancelName),
                  (Role.nextItem, Minibuffer.nextName),
                  (Role.previousItem, Minibuffer.previousName)]] &&
            Minibuffer.modes.all fun mode => mode.check TestScheme.scheme == []) }]

/-- The checks of prompts on the loop's driver: the loop's part and its
host's (`promptLoopChecks`), the echo an open prompt clears
(`echoPromptChecks`), then the minibuffer's commands and its mode
(`promptModeChecks`). -/
def promptChecks : List Check :=
  promptLoopChecks ++ echoPromptChecks ++ promptModeChecks

/-- The candidates the prompts of the candidate checks are asked with. The
one a check types whole, `w`, is last, and two before it hold a `w`. -/
def pickCandidates : Array String :=
  #["wq", "edit", "rewrite", "w"]

/-- The continuation the prompts of the candidate checks are asked with:
the command `picked` and an argument of the asker's own. -/
def pickContinuation : Invocation :=
  { command := "picked", arguments := [.nat 7] }

/-- What the command `picked` of the candidate checks says in the echo
area: the arguments it was called with. -/
def picked (arguments : List Argument) : String :=
  s!"picked {arguments.map argumentText}"

/-- The label of the prompts of the candidate checks. -/
def pickLabel : String :=
  "Pick: "

/-- The commands of the candidate checks, by name.

- `ask-pick` asks `Pick: ` with the candidates `pickCandidates`, from a
  function, and the continuation `pickContinuation`; `ask-pick-w` asks the
  same with the initial value `w`; `ask-plain` asks with no candidates.
- `picked` says what it was called with (`picked`).
- `accept` and `cancel` are the API's operations.
- The test scheme's self-insert inserts its argument at its target's
  cursors.
- `still` does nothing, and `edit-then-fail` inserts `x` at its target's
  cursors and is then refused. -/
def candidateCommands : List (String × Dispatched) :=
  let asks (initial : String) (candidates : EditorM (Array String)) : Dispatched := fun _ => do
    discard <| prompt pickLabel pickContinuation initial (candidates := candidates)
    return none
  [("ask-pick", asks "" (pure pickCandidates)), ("ask-pick-w", asks "w" (pure pickCandidates)),
    ("ask-plain", asks "" (pure #[])),
    ("picked", fun call => do
      message (picked call.arguments)
      return none),
    ("accept", fun _ => do
      discard acceptPrompt
      return none),
    ("cancel", fun _ => do
      discard cancelPrompt
      return none),
    ((TestScheme.selfInsert "").command, fun call => do
      let [.str text] := call.arguments | throw .badRange
      call.target.insertAtSelections text
      return none),
    ("still", fun _ => return none),
    ("edit-then-fail", failingAfter fun call => call.target.insertAtSelections "x")]

/-- What a step of the candidate checks is handed: one keymap, the same for
every view, the minibuffer's among them, that binds a key sequence under
`C-c` to each command of `candidateCommands` but the self-insert and
`picked`, which no key runs. No key of it prints, so a key that prints is
a self-insert. -/
def candidateKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    [("C-c a", invoke "ask-pick"), ("C-c w", invoke "ask-pick-w"), ("C-c p", invoke "ask-plain"),
      ("C-c y", invoke "accept"), ("C-c n", invoke "cancel"), ("C-c s", invoke "still"),
      ("C-c f", invoke "edit-then-fail")]
    candidateCommands

/-- A driver over the initial state, with the commands of the candidate
checks and the jobs of the driver checks, on the models `model`; `none` if
making the state was refused. -/
def candidateDriver (model : EditorModel := editorModel) : Option TestDriver :=
  (Loop.Driver.over candidateKeys driverJobs (EditorState.initial ⟨640, 480⟩) model).toOption

/-- The registry of the candidate checks that press the minibuffer's keys:
the minibuffer's commands and its mode registered for the owner `compiled`,
as a host registers them, and as config's bindings two that ask and two
that run the commands that move through the list by their names, from any
view. -/
def pickRegistry : Config.Registry :=
  ((({} : Config.Registry).replace .compiled Minibuffer.commands).replaceModes .compiled
        Minibuffer.modes).replaceBindings
    .config
    ([("C-c a", "ask-pick"), ("C-c p", "ask-plain"), ("C-c 3", Minibuffer.nextName),
          ("C-c 4", Minibuffer.previousName)].toArray.map
      fun (text, command) => { keys := keys text, command })

/-- What a step of those checks is handed: the active keymaps `pickRegistry`
makes for the test scheme from the loop's state, so the minibuffer's mode
holds in the minibuffer's view and nowhere else; the registry's commands,
each given its call; and, for any other name, the commands of the candidate
checks. -/
def pickKeys : Loop.Keys TestScheme.scheme :=
  { maps := pickRegistry.activeMaps TestScheme.scheme
    command? := fun name =>
      match pickRegistry.find? name with
      | some { registration := { action := .call run, .. }, .. } =>
        some fun call => do
          run call
          return none
      | _ => (candidateCommands.find? (·.1 == name)).map (·.2) }

/-- A driver of those checks over the initial state, with the jobs of the
driver checks; `none` if making the state was refused. -/
def pickDriver : Option TestDriver :=
  (Loop.Driver.over pickKeys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- The candidates of the prompt open in `driver`'s loop, with their listing
and the choice. -/
def candidatesOf (driver : TestDriver) : Option Candidates :=
  driver.loop.state.prompt.map (·.candidates)

/-- What a prompt asked with `pickCandidates` holds once they are listed
for `pattern`, with `chosen` as its choice: the listing is what the fuzzy
model answers for the pattern, so no order is written out here. -/
def pickListed (pattern : String) (chosen : Option Nat := none) : Candidates :=
  { all := pickCandidates, listedFor := some pattern
    listed := (FuzzyModel.rank pattern pickCandidates).filterMap (pickCandidates[·]?), chosen }

/-- `driver` with the choice of its open prompt moved by `steps`, through
the state and not by a command. -/
def chose (driver : TestDriver) (steps : List Candidates.Step) : TestDriver :=
  { driver with
    loop :=
      { driver.loop with
        state :=
          steps.foldl (fun state step => (state.chooseCandidate step).2) driver.loop.state } }

/-- The status line of the view `id` in the last scene `driver`'s display
model holds. -/
def statusIn (driver : TestDriver) (id : ViewId) : Option (Array StatusField) := do
  ((← driver.model.display.scenes.back?).views.find? (·.id == id)).map (·.status)

/-- The status line of the minibuffer's view in the last scene `driver`'s
display model holds. -/
def pickStatus (driver : TestDriver) : Option (Array StatusField) := do
  statusIn driver (← driver.loop.state.minibufferView?)

/-- The status line of the minibuffer's view of a prompt of the candidate
checks whose minibuffer holds `pattern`: the label, then a field for each
candidate the fuzzy model answers for the pattern, in its order, with the
one at `chosen` of them, if any, in the chosen face. -/
def pickFields (pattern : String) (chosen : Option Nat := none) : Array StatusField :=
  #[{ text := pickLabel, face := Loop.promptFace }] ++
    (pickListed pattern).listed.mapIdx fun index candidate =>
      { text := candidate
        face := if chosen == some index then Loop.chosenFace else Loop.candidateFace }

/-- The editor's models, but that every read of a whole text is refused
with `noSuchText` and changes nothing: a fake written for the one check
that needs the listing's read refused where no history and no view is. A
released text refuses all three, so its check cannot tell whose refusal the
echo holds. -/
def refusingReads : (request : EditorRequest) → EditorModel → request.Reply × EditorModel
  | .text (.read _), model => (.error .noSuchText, model)
  | request, model => EditorModel.handle request model

/-- The checks of a prompt's candidates through the loop
(`Editor/Loop.lean`, "Prompts"), on the loop's driver over the editor's
models and the test scheme, with commands written here: the listing the
loop makes before each scene, and the scene's fields for it, and what the
loop does when the listing's read is refused. What is listed is compared
with what the fuzzy model answers for the same pattern and candidates. -/
def candidateChecks : List Check :=
  [{  name :=
        "after the step that asked for a prompt with candidates the listing is for the initial text, the empty one or one given, and nothing is chosen"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (given, _) := fedTo driver (presses "C-c w")
            candidatesOf asking == some (pickListed "") &&
              (candidatesOf asking).map (·.listed.size) == some pickCandidates.size &&
              candidatesOf given == some (pickListed "w") &&
              minibufferText given == some "w" },
    { name :=
        "after each key typed into a prompt with candidates the listing is for the text typed so far: a candidate that is the text is first though it is last among the candidates, a text one candidate matches lists that one, and a text none matches lists none"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (one, _) := fedTo driver (presses "C-c a w")
            let (two, _) := fedTo one (presses "q")
            let (three, _) := fedTo two (presses "z")
            candidatesOf one == some (pickListed "w") &&
              (candidatesOf one).map (·.listed[0]?) == some (some "w") &&
              (candidatesOf one).map (·.listed.size) == some 3 &&
              pickCandidates.back? == some "w" &&
              candidatesOf two == some (pickListed "wq") &&
              (candidatesOf two).map (·.listed) == some #["wq"] &&
              candidatesOf three == some (pickListed "wqz") &&
              (candidatesOf three).map (·.listed) == some #[] &&
              minibufferText three == some "wqz" },
    { name :=
        "a key whose command leaves the minibuffer's text as it was leaves the listing and a choice as they were, and a key typed after it forgets the choice with the listing it was made in"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let chosen := chose typed [.next, .next]
            let (still, _) := fedTo chosen (presses "C-c s")
            let (more, _) := fedTo still (presses "q")
            candidatesOf chosen == some (pickListed "w" (some 1)) &&
              candidatesOf still == some (pickListed "w" (some 1)) &&
              candidatesOf more == some (pickListed "wq") },
    { name :=
        "a command that edits the minibuffer and is then refused is rolled back to the text, the listing and the choice from before it"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let chosen := chose typed [.next]
            let (failed, _) := fedTo chosen (presses "C-c f")
            minibufferText failed == some "w" &&
              candidatesOf failed == some (pickListed "w" (some 0)) &&
              failed.loop.state.prompt.isSome },
    { name :=
        "what the listing costs, counted on the watch model's clock: a prompt with candidates is published with one request more than one with none, the read of the minibuffer, while its text is as it was, and with two more, the read and the ranking, at the step that asked for it and at each step that changed the text"
      run :=
        pure <|
          match candidateDriver countingModel with
          | none => false
          | some driver =>
            -- How many requests the last of `keys` took.
            let cost (keys : String) : Nat :=
              let events := presses keys
              let (before, _) := fedTo driver events.dropLast
              let (after, _) := fedTo before (events.drop (events.length - 1))
              after.model.watch.clock - before.model.watch.clock
            let plainAsk := cost "C-c p"
            let plainStill := cost "C-c p C-c s"
            let plainTyped := cost "C-c p w"
            plainAsk > 0 && plainStill > 0 && cost "C-c a" == plainAsk + 2 &&
              cost "C-c a C-c s" == plainStill + 1 &&
              cost "C-c a w" == plainTyped + 2 &&
              cost "C-c a w C-c s" == plainStill + 1 },
    { name :=
        "text typed into a prompt with candidates: in the scene, the minibuffer's view's status line is the label, in the prompt's face, and then one field for each candidate the fuzzy model answers for that text, in its order, each in the candidates' face; the other view's status line lists none"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (typed, _) := fedTo asking (presses "e")
            pickStatus asking == some (pickFields "") &&
              (pickStatus asking).map (·.size) == some (1 + pickCandidates.size) &&
              pickStatus typed == some (pickFields "e") &&
              (pickStatus typed).map (·.size) == some 3 &&
              (statusIn typed ⟨0⟩).map (·.any (·.face == Loop.candidateFace)) == some false },
    { name :=
        "where a candidate is the typed text and others match it too, its field is the first after the label, though it is the last of the candidates"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            pickStatus typed == some (pickFields "w") &&
              ((pickStatus typed).map fun fields => (fields.map (·.text)).extract 0 2) ==
                some #[pickLabel, "w"] &&
              (pickStatus typed).map (·.size) == some 4 &&
              pickCandidates.back? == some "w" },
    { name :=
        "a text no candidate matches: the scene lists none, and the minibuffer's status line is the label alone; so is that of a prompt asked with no candidates"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a z")
            let (plain, _) := fedTo driver (presses "C-c p w")
            let label : Array StatusField := #[{ text := pickLabel, face := Loop.promptFace }]
            pickStatus typed == some label && pickStatus plain == some label &&
              minibufferText typed == some "z" },
    { name :=
        "with a candidate chosen, its field of the minibuffer's status line and no other is in the chosen face, and the fields say what they said"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let (second, _) := fedTo (chose typed [.next, .next]) (presses "C-c s")
            let (unchosen, _) := fedTo (chose second [.next, .next]) (presses "C-c s")
            pickStatus second == some (pickFields "w" (some 1)) &&
              ((pickStatus second).map fun fields => fields.map (·.face == Loop.chosenFace)) ==
                some #[false, false, true, false] &&
              Loop.chosenFace != Loop.candidateFace &&
              candidatesOf unchosen == some (pickListed "w") &&
              pickStatus unchosen == some (pickFields "w") },
    { name :=
        "text is typed, the key of the role next-item is pressed and then the accept key: the continuation's command runs with the first listed candidate as its first argument, which is not the typed text, and its own argument after it; the prompt is closed"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a e")
            let (chosen, _) := fedTo typed (rolePresses Role.nextItem)
            let (accepted, _) := fedTo chosen (rolePresses Role.activate)
            let first := (pickListed "e").listed[0]?
            !(rolePresses Role.nextItem).isEmpty && first.isSome && first != some "e" &&
              candidatesOf chosen == some (pickListed "e" (some 0)) &&
              minibufferText chosen == some "e" &&
              first.map (fun candidate => picked [.str candidate, .nat 7]) ==
                some (promptEcho accepted) &&
              accepted.loop.state.prompt == none },
    { name :=
        "the keys of the roles next-item and previous-item move the choice through the listing, and the scene's chosen field follows: next twice is the second, previous then the first, previous again nothing, and previous from nothing the last"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let next := rolePresses Role.nextItem
            let previous := rolePresses Role.previousItem
            let (typed, _) := fedTo driver (presses "C-c a w")
            let (second, _) := fedTo typed (next ++ next)
            let (first, _) := fedTo second previous
            let (unchosen, _) := fedTo first previous
            let (last, _) := fedTo unchosen previous
            !previous.isEmpty && previous != next &&
              candidatesOf second == some (pickListed "w" (some 1)) &&
              pickStatus second == some (pickFields "w" (some 1)) &&
              candidatesOf first == some (pickListed "w" (some 0)) &&
              pickStatus first == some (pickFields "w" (some 0)) &&
              candidatesOf unchosen == some (pickListed "w") &&
              pickStatus unchosen == some (pickFields "w") &&
              candidatesOf last == some (pickListed "w" (some 2)) &&
              pickStatus last == some (pickFields "w" (some 2)) &&
              minibufferText last == some "w" },
    { name :=
        "the next key from the last listed candidate chooses nothing, and the accept key then gives the continuation the typed text"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let next := rolePresses Role.nextItem
            let (typed, _) := fedTo driver (presses "C-c a e")
            let (last, _) := fedTo typed (next ++ next)
            let (past, _) := fedTo last next
            let (accepted, _) := fedTo past (rolePresses Role.activate)
            (pickListed "e").listed.size == 2 &&
              candidatesOf last == some (pickListed "e" (some 1)) &&
              candidatesOf past == some (pickListed "e") &&
              promptEcho accepted == picked [.str "e", .nat 7] },
    { name :=
        "a key typed after a choice forgets it: the listing is the one for the new text, with nothing chosen, and the accept key gives the typed text"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (chosen, _) := fedTo driver (presses "C-c a e" ++ rolePresses Role.nextItem)
            let (typed, _) := fedTo chosen (presses "d")
            let (accepted, _) := fedTo typed (rolePresses Role.activate)
            candidatesOf chosen == some (pickListed "e" (some 0)) &&
              candidatesOf typed == some (pickListed "ed") &&
              pickStatus typed == some (pickFields "ed") &&
              promptEcho accepted == picked [.str "ed", .nat 7] },
    { name :=
        "a text no candidate matches: the scene lists none, the next key and the previous key change nothing, and the accept key gives the continuation the typed text"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a z")
            let (moved, _) :=
              fedTo typed (rolePresses Role.nextItem ++ rolePresses Role.previousItem)
            let (accepted, _) := fedTo moved (rolePresses Role.activate)
            let label : Array StatusField := #[{ text := pickLabel, face := Loop.promptFace }]
            candidatesOf typed == some (pickListed "z") &&
              (candidatesOf typed).map (·.listed) == some #[] &&
              pickStatus typed == some label &&
              candidatesOf moved == candidatesOf typed &&
              pickStatus moved == some label &&
              minibufferText moved == some "z" &&
              promptEcho accepted == picked [.str "z", .nat 7] &&
              accepted.loop.state.prompt == none },
    { name :=
        "in a prompt with no candidates the next key and the previous key change nothing, and the accept key gives the typed text"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c p w")
            let (moved, _) :=
              fedTo typed (rolePresses Role.nextItem ++ rolePresses Role.previousItem)
            let (accepted, _) := fedTo moved (rolePresses Role.activate)
            candidatesOf moved == some {} && minibufferText moved == some "w" &&
              promptEcho accepted == picked [.str "w", .nat 7] },
    { name :=
        "with no prompt open, the command that moves to the next candidate and the one that moves to the previous, each run by its name, say that no prompt is open, and nothing else changes"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (next, _) := fedTo driver (presses "C-c 3")
            let (previous, _) := fedTo driver (presses "C-c 4")
            !Minibuffer.notOpen.isEmpty && promptEcho next == Minibuffer.notOpen &&
              promptEcho previous == Minibuffer.notOpen &&
              next.loop.state.prompt == none &&
              { next.loop.state with echo := "" } == driver.loop.state },
    { name :=
        "an event once the minibuffer's text was released behind a prompt with candidates is not refused: a scene is published with the refusal in its echo, the loop keeps that echo, and the prompt's listing and choice are as they were"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let chosen := chose typed [.next, .next]
            match minibufferTextId chosen with
            | none => false
            | some text =>
              let (released, texts) := text.release.runModel chosen.model.texts
              let (after, steps) :=
                fedTo { chosen with model := { chosen.model with texts } } [pressF5]
              released.toOption.isSome && promptEcho chosen == "" && steps.size == 1 &&
                steps.all (·.isSome) &&
                promptEcho after == "refused: no such text" &&
                after.model.display.scenes.size == chosen.model.display.scenes.size + 1 &&
                after.model.display.scenes.back?.map (·.echo) == some "refused: no such text" &&
                candidatesOf chosen == some (pickListed "w" (some 1)) &&
                candidatesOf after == candidatesOf chosen &&
                after.loop.state.wellFormed },
    { name :=
        "a refusal of the listing's read alone, on models that refuse every read of a text and nothing else: the step is not refused, the scene has the refusal in its echo with every view and the minibuffer's status line as it was, and the listing and the choice are as they were"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let (chosen, _) := fedTo (chose typed [.next, .next]) (presses "C-c s")
            let step := chosen.loop.take chosen.handed { event := pressF5, stamp := 0 }
            match Program.run (port := editorPort) refusingReads step.run chosen.model with
            | (.error _, _) => false
            | (.ok stepped, model) =>
              let after := chosen.took stepped model
              promptEcho chosen == "" && stepped.next == .continue &&
                promptEcho after == "refused: no such text" &&
                model.display.scenes.size == chosen.model.display.scenes.size + 1 &&
                model.display.scenes.back?.map (·.echo) == some "refused: no such text" &&
                (model.display.scenes.back?.map fun scene => scene.views.map (·.id)) ==
                  (chosen.model.display.scenes.back?.map fun scene => scene.views.map (·.id)) &&
                pickStatus chosen == some (pickFields "w" (some 1)) &&
                pickStatus after == pickStatus chosen &&
                candidatesOf after == some (pickListed "w" (some 1)) &&
                after.loop.state.wellFormed }]

/-- A file of three lines of which two end in CRLF and one in a line
feed. -/
def mostlyCrlf : ByteArray :=
  "a\r\nb\r\nc\n".toUTF8

/-- A file of three lines of which two end in a line feed and one in
CRLF. -/
def mostlyLf : ByteArray :=
  "a\nb\nc\r\n".toUTF8

/-- A file with no line break. -/
def unbroken : ByteArray :=
  "no break".toUTF8

/-- The files of the file command checks, in `fileRoot`: `note.txt`, with a
two-byte character, a four-byte one and a byte that is not UTF-8
(`FileCases.noteBytes`), three files that differ in their line endings,
and two files called `x.txt`, in the directories `a` and `b`. -/
def commandFiles : FileModel :=
  [("a", "first x\n"), ("b", "second x\n")].foldl
    (fun (model : FileModel) (directory, text) =>
      (model.withDirectory (fileRoot / directory)).withFile (fileRoot / directory / "x.txt")
        text.toUTF8)
    (fileModelOf
      #[("note.txt", FileCases.noteBytes), ("crlf.txt", mostlyCrlf), ("lf.txt", mostlyLf),
        ("plain.txt", unbroken)])

/-- The path of a file of the file command checks, by its name. -/
def inFiles (name : String) : System.FilePath :=
  fileRoot / name

/-- The keys of the file command checks that open a file, and the path each
opens: `missing.txt` is not there, and `relative.txt` is not an absolute
path. -/
def openKeys : List (String × System.FilePath) :=
  [("C-o n", inFiles "note.txt"), ("C-o c", inFiles "crlf.txt"), ("C-o l", inFiles "lf.txt"),
    ("C-o p", inFiles "plain.txt"), ("C-o m", inFiles "missing.txt"), ("C-o r", "relative.txt"),
    ("C-o a", fileRoot / "a" / "x.txt"), ("C-o b", fileRoot / "b" / "x.txt")]

/-- The invocation that opens `path`: the open command, with the path as
its argument. -/
def opens (path : System.FilePath) : Invocation :=
  { command := Files.openName, arguments := [.str path.toString] }

/-- What a step of the file command checks is handed: the keys of
`openKeys`, each bound to the open command with its path, `C-o o` bound to
the open command with no argument, `C-o V` to the open command with the
arguments the Vim scheme gives a command a key is bound to, a count and a
register, and the open command under its name. `C-o 2` is bound to the open
command with two paths, `note.txt` and then `crlf.txt`, and `C-o 3` with
`missing.txt` and then `lf.txt`.

`C-o w` is bound to the save command, under its name, `C-o f` to the save
command with `true` as its argument, and `C-o v` to the save command with
the arguments the Vim scheme gives a command a key is bound to, a count
and a register.

Eight more commands, written here: `scratch` (`C-o 0`) shows the scratch
buffer in the window it is called with, `split` (`C-o s`) splits that
window and focuses the new one, `close` (`C-o k`) closes it, `shut`
(`C-o K`) closes the view 1, the first a split makes, whichever window it
is called with, `undo` (`C-o u`) undoes one step of its buffer's history,
`drop` (`C-o d`) removes the buffer 1, the first a file is opened into, and
`save-absent` (`C-o x`) saves a buffer there is none of. Two more visit a
file in the view 0, focusing it (`Files.visit`): `visit-note` (`C-o g`)
`note.txt` at row 0, character column 2, and `visit-missing` (`C-o G`)
`missing.txt`. -/
def fileKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    (openKeys.map (fun (text, path) => (text, opens path)) ++
      [("C-o o", invoke Files.openName),
        ("C-o V", { command := Files.openName, arguments := [.nat 0, .str ""] }),
        ("C-o 0", invoke "scratch"), ("C-o s", invoke "split"), ("C-o k", invoke "close"),
        ("C-o K", invoke "shut"), ("C-o w", invoke Files.saveName),
        ("C-o f", { command := Files.saveName, arguments := [.bool true] }),
        ("C-o v", { command := Files.saveName, arguments := [.nat 0, .str ""] }),
        ("C-o u", invoke "undo"), ("C-o d", invoke "drop"), ("C-o x", invoke "save-absent"),
        ("C-o g", invoke "visit-note"), ("C-o G", invoke "visit-missing"),
        ("C-o 2",
          { command := Files.openName
            arguments :=
              [.str (inFiles "note.txt").toString, .str (inFiles "crlf.txt").toString] }),
        ("C-o 3",
          { command := Files.openName
            arguments :=
              [.str (inFiles "missing.txt").toString, .str (inFiles "lf.txt").toString] })])
    [(Files.openName, fun call => do
        Files.openCommand call
        return none),
      (Files.saveName, fun call => do
        Files.saveCommand call
        return none),
      ("undo", fun call => do
        discard <| call.target.window.buffer.undo
        return none),
      ("drop", fun _ => do
        discard <| (⟨1⟩ : BufferId).remove
        return none),
      ("save-absent", fun _ => do
        Files.save ⟨9⟩
        return none),
      ("scratch", fun call => do
        discard <| call.target.window.id.show ⟨0⟩
        return none),
      ("split", fun call => do
        if let .ok made← call.target.window.id.split then
          discard <| made.focus
        return none),
      ("close", fun call => do
        discard <| call.target.window.id.close
        return none),
      ("shut", fun _ => do
        discard <| (⟨1⟩ : ViewId).close
        return none),
      ("visit-note", fun _ => do
        Files.visit ⟨0⟩ (inFiles "note.txt") ⟨0, 2⟩ true
        return none),
      ("visit-missing", fun _ => do
        Files.visit ⟨0⟩ (inFiles "missing.txt") ⟨1, 0⟩ true
        return none)]

/-- The jobs of the file command checks, by name: the load job, whose loads
are refused over `limit` bytes, and the save job. -/
def fileJobs (limit : Nat := Files.limit) (name : String) : Option (List Argument → Work) :=
  if name == Files.loadJob then some (Files.loadWork limit)
  else if name == Files.saveJob then some Files.saveWork else none

/-- A driver over the initial state with the keys of the file command
checks, the jobs `registered`, and `files` as the files its jobs reach;
`none` if making the state was refused. -/
def filesDriver (registered : String → Option (List Argument → Work) := fileJobs)
    (files : FileModel := commandFiles) : Option TestDriver :=
  (Loop.Driver.over fileKeys registered (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files } }

/-- A driver whose commands and jobs are the ones compiled code registers
(`Files.commands`, `Files.jobs`, and `Minibuffer.commands`), each under the
name it is registered under, over the files of the file command checks:
`C-o n` is bound to the open command with the path of `note.txt`, `C-o o`
to the open command with no argument, `C-o w` to the save command, and
`C-o y` to the minibuffer's accept command, in every view. -/
def compiledDriver : Option TestDriver :=
  let keys : Loop.Keys TestScheme.scheme :=
    dispatchKeys
      [("C-o n", opens (inFiles "note.txt")), ("C-o o", invoke Files.openName),
        ("C-o w", invoke Files.saveName), ("C-o y", invoke Minibuffer.acceptName)]
      ((Files.commands ++ Minibuffer.commands).toList.filterMap fun registration =>
        match registration.action with
        | .call run =>
          some
            (registration.name, fun call => do
              run call
              return none)
        | _ => none)
  (Loop.Driver.over keys (fun name => (Files.jobs.find? (·.name == name)).map (·.work))
        (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

/-- What a view of a driver shows. -/
structure Showing where
  /-- The buffer's id. -/
  id : BufferId
  /-- The buffer. -/
  buffer : Buffer
  /-- What the buffer's text holds in the text model; `none` if it was
  released. -/
  text : Option String
  /-- The ranges of the window's selection, as the text model has them;
  `none` if the marker was given up. -/
  cursors : Option (Array SelectionRange)

/-- What the view `view` of `driver` shows; `none` if it has no window. -/
def showing (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option Showing := do
  let target ← driver.loop.state.target? view
  return {
      id := target.window.buffer
      buffer := target.buffer
      text := (driver.model.texts.texts[target.buffer.text.index]?).join.map (·.contents)
      cursors := (target.selection.runModel driver.model.texts).1.toOption.map (·.ranges) }

/-- The echo area of the last scene `driver`'s display recorded. -/
def echoOf (driver : TestDriver) : Option String :=
  driver.model.display.scenes.back?.map (·.echo)

/-- The buffer's fields of the status line of the view `view` in the last
scene `driver`'s display recorded: those in the faces of the buffer's name,
of the modified mark and of the changed mark (`ModeLine.buffer`,
`ModeLine.modified`, `ModeLine.changed`), which is what the file checks
read. The other segments are `modeLineChecks`'s. -/
def statusOf (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option (Array StatusField) :=
  driver.model.display.scenes.back?.bind fun scene =>
    (scene.views.find? (·.id == view)).map fun view =>
      view.status.filter fun field =>
        field.face == ModeLine.bufferFace || field.face == ModeLine.modifiedFace ||
          field.face == ModeLine.changedFace

/-- The buffer's fields of the status line of the view `view` in the last
scene `driver`'s display recorded, a view that is not selected: what
`statusOf` reads of a selected view, for a view every field of which is in
`ModeLine.inactiveFace` (`ModeLine.fields`). The faces no longer tell the
buffer's fields from the others, so they are told by their text: the
buffer's name `name`, the modified mark and the changed mark
(`ModeLine.modifiedMark`, `ModeLine.changedMark`), each on the left. A
position field on the right, such as `1:1` or `All`, is not one of them. -/
def inactiveStatusOf (driver : TestDriver) (view : ViewId) (name : String) :
    Option (Array StatusField) :=
  driver.model.display.scenes.back?.bind fun scene =>
    (scene.views.find? (·.id == view)).map fun view =>
      view.status.filter fun field =>
        field.face == ModeLine.inactiveFace && field.side == .left &&
          [name, ModeLine.modifiedMark, ModeLine.changedMark].contains field.text

/-- The buffer's fields of the status line of a selected view of a buffer
called `name` that is not modified: the name alone, in its face. -/
def named (name : String) : Array StatusField :=
  #[ModeLine.field name ModeLine.bufferFace]

/-- The buffer's fields of the status line of a selected view of a buffer
called `name` that is modified: the name, then the modified mark. -/
def namedModified (name : String) : Array StatusField :=
  named name ++ #[ModeLine.field ModeLine.modifiedMark ModeLine.modifiedFace]

/-- The stamp the files `driver`'s jobs reach have for `path`. -/
def stampOf (driver : TestDriver) (path : System.FilePath) : Option File.Stamp :=
  (driver.jobs.files.file? path).map (·.stamp)

/-- The bytes the files `driver`'s jobs reach hold at `path`. -/
def bytesOf (driver : TestDriver) (path : System.FilePath) : Option ByteArray :=
  (driver.jobs.files.file? path).map (·.bytes)

/-- `driver` once another program has written `bytes` as the file at
`path`. -/
def rewritten (driver : TestDriver) (path : System.FilePath) (bytes : ByteArray) : TestDriver :=
  { driver with jobs := { driver.jobs with files := driver.jobs.files.withFile path bytes } }

/-- The file the buffer the view `view` of `driver` shows holds. -/
def heldFile (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option Buffer.File :=
  (showing driver view).bind (·.buffer.file)

/-- What reading `snapshot` is refused with in `driver`'s text model:
`some none` when it reads. -/
def snapshotRefusal (driver : TestDriver) (snapshot : SnapshotId) : Option (Option TextError) :=
  ((refusalOf snapshot.read).runModel driver.model.texts).1.toOption

/-- A driver of the file command checks with the file `note.txt` open in
view 0, and the step that opened it: the open command, and its job
finished. The load is job 1. -/
def noteOpen (files : FileModel := commandFiles) : Option TestDriver :=
  (filesDriver (files := files)).map fun driver => ((fedTo driver (presses "C-o n")).1.finish 1).1

/-- A test language for the language open checks: `*.rs`, parsed with the
syntax tree model's one grammar, `json`, so a path's extension is seen to
choose it on the models. -/
def modelRs : Language :=
  { name := "model-rs", patterns := [.extension "rs"], syntaxTree := { grammar := "json" } }

/-- The registry of the language open checks: the `code` mode, and the
languages `json` and `modelRs`, as compiled code registers them. -/
def languageRegistry : Config.Registry :=
  (({} : Config.Registry).replaceModes .compiled Language.modes).replaceLanguages .compiled
    #[Language.json, modelRs]

/-- The files of the language open checks: the file command checks', and,
beside `note.txt`, `data.json` and `main.rs`, each holding a JSON text. -/
def languageFiles : FileModel :=
  (commandFiles.withFile (inFiles "data.json") "[1, null]".toUTF8).withFile (inFiles "main.rs")
    "[2]".toUTF8

/-- What a step of the language open checks is handed: `C-o j`, `C-o r` and
`C-o n` bound to the open command with the paths of `data.json`, `main.rs`
and `note.txt`, `C-o 1` and `C-o 2` to the on-enter checks' `enter` of the
modes `own-json` and `derived` through view 0, and what `registry` says of
its modes and languages. -/
def languageKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  {
    dispatchKeys
      [("C-o j", opens (inFiles "data.json")), ("C-o r", opens (inFiles "main.rs")),
        ("C-o n", opens (inFiles "note.txt")), ("C-o 1", entersMode ⟨0⟩ "own-json"),
        ("C-o 2", entersMode ⟨0⟩ "derived")]
      [(Files.openName, fun call => do
          Files.openCommand call
          return none),
        ("enter", enter)] with
    registered := registry.registered }

/-- A driver of the language open checks over `languageRegistry` with
`modes` and `languages` registered for config, over `languageFiles`; `none`
if making the state was refused. -/
def languageDriver (modes : Array Mode := #[]) (languages : Array Language := #[]) :
    Option TestDriver :=
  let registry := (languageRegistry.replaceModes .config modes).replaceLanguages .config languages
  (Loop.Driver.over (languageKeys registry) fileJobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver => { driver with jobs := { files := languageFiles } }

/-- `driver` once the keys `keys` were pressed and the job `job` their open
started is finished. -/
def openedBy (driver : TestDriver) (keys : String) (job : Nat := 1) : TestDriver :=
  ((fedTo driver (presses keys)).1.finish job).1

/-- The language and the major mode of the buffer view 0 of `driver`
shows. -/
def languageAndMajor (driver : TestDriver) : Option (Option String × Option String) :=
  (showing driver).map fun shown => (shown.buffer.language, shown.buffer.major)

/-- The faces the syntax tree model's shipped `json` highlights query is
drawn in by the shipped default: each of its capture names'. -/
def modelJsonFaces : Array String :=
  #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"]

/-- The checks of what opening a file does with its language
(`Editor/Files.lean`, "Open"; `Editor/Language.lean`), on the loop's driver
over the editor's models and the model of files. The syntax tree model
knows one grammar, `json`, so every language here is parsed with it; Rust
and Markdown are `ConfigTest.languageChecks`'s, over the real binding. -/
def languageOpenChecks : List Check :=
  [{  name :=
        "opening a .json file gives its buffer the language json and the major mode code, and its text is attached with json and highlighted in the faces of the grammar's shipped query"
      run :=
        pure <|
          match languageDriver with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o j"
            languageAndMajor opened == some (some "json", some "code") &&
              opened.model.syntaxTree.attached.map (·.2) == #["json"] &&
              highlightedFaces opened.model.syntaxTree == some modelJsonFaces },
    { name :=
        "opening a .rs file chooses the language whose extension pattern is rs, and puts its buffer in code, attached with that language's grammar"
      run :=
        pure <|
          match languageDriver with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o r"
            languageAndMajor opened == some (some "model-rs", some "code") &&
              opened.model.syntaxTree.attached.map (·.2) == #["json"] &&
              highlightedFaces opened.model.syntaxTree == some modelJsonFaces },
    { name :=
        "opening a file whose name matches no language gives its buffer no language and no major mode, and asks the syntax tree port nothing"
      run :=
        pure <|
          match languageDriver with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o n"
            (showing opened).map (·.buffer.name) == some "note.txt" &&
              languageAndMajor opened == some (none, none) &&
              opened.model.syntaxTree.attached.isEmpty &&
              opened.model.syntaxTree.highlighted.isEmpty &&
              opened.model.syntaxTree.refreshAfter == none },
    { name :=
        "opening a file a buffer already holds shows it and asks the syntax tree port nothing more"
      run :=
        pure <|
          match languageDriver with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o j"
            let (again, _) := fedTo opened (presses "C-o j")
            again.pending.isEmpty && languageAndMajor again == some (some "json", some "code") &&
              again.model.syntaxTree.attached == opened.model.syntaxTree.attached &&
              again.model.syntaxTree.highlighted == opened.model.syntaxTree.highlighted &&
              again.model.syntaxTree.queries.size == opened.model.syntaxTree.queries.size },
    { name :=
        "a config mode with its own syntax tree, set over an opened json buffer, is highlighted with its own query and not the language's; a config mode derived from code with none is highlighted with the language's"
      run :=
        pure <|
          let own : Mode :=
            { name := "own-json",
              syntaxTree := some { grammar := "json", highlights := some "(number) @number" } }
          let derived : Mode := { name := "derived", parent := some "code" }
          match languageDriver #[own, derived] with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o j"
            let (owned, _) := fedTo opened (presses "C-o 1")
            let (back, _) := fedTo owned (presses "C-o 2")
            (showing owned).bind (·.buffer.major) == some "own-json" &&
              highlightedFaces owned.model.syntaxTree == some #["syntax.number"] &&
              (showing back).bind (·.buffer.major) == some "derived" &&
              highlightedFaces back.model.syntaxTree == some modelJsonFaces },
    { name :=
        "config's entry of the json language, with its own highlights query, is the one an opened .json buffer is highlighted with"
      run :=
        pure <|
          let numbers :=
            { Language.json with
              syntaxTree := { grammar := "json", highlights := some "(number) @number" } }
          match languageDriver (languages := #[numbers]) with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o j"
            languageAndMajor opened == some (some "json", some "code") &&
              highlightedFaces opened.model.syntaxTree == some #["syntax.number"] }]

/-- The checks of what the window mode posts to the editor loop before the
first event (`Window.Options.starts`), and of the loop it starts, on the
driver whose commands and jobs are the compiled ones (`compiledDriver`):
each open of the starts is run as the host's open request runs it. -/
def windowStartChecks : List Check :=
  let parsed (arguments : List String) : Option Window.Options :=
    (Window.parse windowEnvironment arguments).toOption
  let started (starts : Array Window.Start) : Option TestDriver :=
    compiledDriver.map fun driver =>
      starts.foldl
        (fun driver start =>
          match start with
          | .open path =>
            (driver.stepped
                (driver.loop.invoke driver.handed
                  { command := Files.openName, arguments := [.str path] })).1
          | _ => driver)
        driver
  [{  name :=
        "the window mode started with no file opens nothing: it posts what it has to say and the reload, and no open; and the editor loop it starts holds one buffer, scratch, empty, with one window on it"
      run :=
        let empty := (parsed []).map (·.starts (.load "/xdg/leanmacs") #["hi"])
        let withFile := (parsed [(inFiles "note.txt").toString]).map (·.starts (.skip none) #[])
        pure <|
          empty == some #[.say "hi", .reload] &&
            (parsed ["f"]).map (·.starts (.skip none) #[]) == some #[.open "/work/project/f"] &&
            (parsed ["f"]).map (·.starts (.load "/c") #["a", "b"]) ==
              some #[.open "/work/project/f", .say "a", .say "b", .reload] &&
            match empty.bind started, withFile.bind started with
            | some opened, some loading =>
              opened.loop.state.buffers.size == 1 &&
                (opened.loop.state.buffers[0]?).join.map (·.name) == some "scratch" &&
                (showing opened).bind (·.text) == some "" &&
                opened.loop.state.windows.size == 1 &&
                opened.pending.isEmpty &&
                loading.pending.map (·.name) == #[Files.loadJob]
            | _, _ => false },
    { name :=
        "the window mode started with no file and then handed an open-files input of one path shows that file's buffer once its load is finished, beside scratch"
      run :=
        pure <|
          let path := inFiles "note.txt"
          match ((parsed []).map (·.starts (.load "/xdg/leanmacs") #[])).bind started with
          | none => false
          | some empty =>
            let (asked, _) := fedTo empty [.openFiles [path.toString]]
            let (opened, _) := asked.finish 1
            let state := opened.loop.state
            empty.pending.isEmpty && asked.pending.map (·.name) == #[Files.loadJob] &&
              state.buffers.size == 2 &&
              (state.buffer? ⟨0⟩).map (·.name) == some "scratch" &&
              state.findFile path == some ⟨1⟩ &&
              (showing opened state.frame.focused).map (·.id) == some ⟨1⟩ &&
              (showing opened state.frame.focused).bind (·.text) == some FileCases.noteText }]

/-- The checks of the files a window asks to open (`Event.openFiles`): the
loop runs the open command with them (`Editor/Loop.lean`, "What each event
does"), on the driver of the file command checks. No file is touched. -/
def openFilesChecks : List Check :=
  let note := inFiles "note.txt"
  let crlf := inFiles "crlf.txt"
  let asked (paths : List System.FilePath) : Option TestDriver :=
    filesDriver.map fun driver => (fedTo driver [.openFiles (paths.map (·.toString))]).1
  [{  name :=
        "an open-files input of two paths, once both loads are finished, leaves two new buffers holding those files"
      run :=
        pure <|
          match asked [note, crlf] with
          | none => false
          | some asked =>
            let (both, _) := (asked.finish 1).1.finish 2
            let state := both.loop.state
            state.buffers.size == 3 && state.findFile note == some ⟨1⟩ &&
              state.findFile crlf == some ⟨2⟩ &&
              (state.buffer? ⟨1⟩).map (·.name) == some "note.txt" &&
              (state.buffer? ⟨2⟩).map (·.name) == some "crlf.txt" &&
              both.model.texts.contents[1]? == some FileCases.noteText &&
              state.wellFormed },
    { name :=
        "after an open-files input the focused view shows the buffer of its last path, whichever order its loads would finish in: only one is in flight at a time"
      run :=
        pure <|
          match asked [note, crlf] with
          | none => false
          | some asked =>
            let (first, _) := asked.finish 1
            let (both, _) := first.finish 2
            -- Only the first path's load is in flight after the event: the
            -- second cannot finish before it, since it has not started.
            asked.pending.map (·.name) == #[Files.loadJob] && (asked.finish 2).2.isNone &&
              first.pending.map (·.id) == #[2] &&
              (showing both both.loop.state.frame.focused).map (·.id) ==
                both.loop.state.findFile crlf &&
              (both.loop.state.findFile crlf).isSome },
    { name := "an open-files input of one path selects that path's buffer once its load is finished"
      run :=
        pure <|
          match asked [note] with
          | none => false
          | some asked =>
            let (opened, _) := asked.finish 1
            (showing asked).map (·.id) == some ⟨0⟩ && (showing opened).map (·.id) == some ⟨1⟩ &&
              (showing opened).bind (·.text) == some FileCases.noteText },
    { name := "an open-files input with no path starts nothing and publishes a scene"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (after, steps) := fedTo driver [.openFiles []]
            after.pending.isEmpty && steps.map (·.map (·.next)) == #[some .continue] &&
              after.model.display.scenes.size == driver.model.display.scenes.size + 1 &&
              after.loop.state.buffers.size == 1 },
    { name :=
        "an open-files input is run as `open-file` is: config's command of that name runs in its place"
      run :=
        pure <|
          let keys : Loop.Keys TestScheme.scheme :=
            dispatchKeys []
              [(Files.openName, fun call => do
                  message s!"mine: {call.arguments.length}"
                  return none)]
          match
            (Loop.Driver.over keys fileJobs (EditorState.initial ⟨640, 480⟩)
                editorModel).toOption with
          | none => false
          | some driver =>
            let driver := { driver with jobs := { files := commandFiles } }
            let (after, _) := fedTo driver [.openFiles [note.toString, crlf.toString]]
            echoOf after == some "mine: 2" && after.pending.isEmpty &&
              after.loop.state.buffers.size == 1 }]

/-- The checks of the file commands (`Editor/Files.lean`), on the loop's
driver over the editor's models and the model of files: opening a file into
a buffer, and saving a buffer to its file. No file is touched. -/
def fileCommandChecks : List Check :=
  let started (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array JobStart :=
    steps.flatMap fun step => (step.map (·.starts)).getD #[]
  [{  name :=
        "the open command on a file: once its job is finished, the view the command was called in shows a new buffer whose text is the file's, a byte that is not UTF-8 as its escape, named by the file's base name, with one cursor at its start, not modified, holding the file's path and the stamp the files have for it; the view's status line is that name alone"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, steps) := fedTo driver (presses "C-o n")
            let (opened, delivered) := asked.finish 1
            match showing opened with
            | none => false
            | some shown =>
              started steps ==
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path, view := ⟨0⟩ } }] &&
                (delivered.map (·.ended)) == some (some .finished) &&
                shown.id == ⟨1⟩ &&
                shown.buffer.name == "note.txt" &&
                shown.text == some FileCases.noteText &&
                shown.cursors == some #[⟨0, 0⟩] &&
                !shown.buffer.isModified &&
                (shown.buffer.file.map fun file => (file.path, some file.stamp, file.saving)) ==
                  some (path, (opened.jobs.files.file? path).map (·.stamp), none) &&
                statusOf opened == some (named "note.txt") &&
                opened.loop.state.wellFormed &&
                opened.loop.state.buffers.size == 2 &&
                opened.model.texts.contents == #["", FileCases.noteText] },
    { name :=
        "a buffer's line ending is its file's dominant one: CRLF for a file most of whose lines end in CRLF, a line feed for one most of whose lines end in a line feed, and a line feed for a file with no line break"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let ending (key : String) : Option File.LineEnding :=
              let (asked, _) := fedTo driver (presses key)
              (showing (asked.finish 1).1).bind fun shown =>
                shown.buffer.file.map fun _ => shown.buffer.lineEnding
            ending "C-o c" == some .crlf && ending "C-o l" == some .lf &&
              ending "C-o p" == some .lf },
    { name :=
        "events that arrive while a load is in flight are handled before the load's result: after the open command the view still shows the scratch buffer, two commits fed before the job is finished are each in the scratch buffer's text after their own steps, and the file's buffer is there, and shown, only once the job is finished"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o n")
            let (first, _) := fedTo asked [.commit "a"]
            let (second, _) := fedTo first [.commit "b"]
            let (opened, _) := second.finish 1
            (showing asked).map (·.id) == some ⟨0⟩ && asked.pending.size == 1 &&
              driverText first == some "a" &&
              driverText second == some "ab" &&
              (showing second).map (·.id) == some ⟨0⟩ &&
              second.loop.state.buffers.size == 1 &&
              second.model.texts.contents == #["ab"] &&
              (showing opened).map (·.id) == some ⟨1⟩ &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              opened.model.texts.contents == #["ab", FileCases.noteText] },
    { name :=
        "the open command on a path with no file: the echo area says the refusal, the view still shows the buffer it showed, with its cursor, and there is no new buffer and no new text"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver ([.commit "kept"] ++ presses "C-o m")
            let (refused, delivered) := asked.finish 1
            (delivered.map (·.ended)) == some (some .finished) &&
              echoOf refused == some (Files.notOpened (inFiles "missing.txt") .notFound) &&
              (showing refused).map (fun shown => (shown.id, shown.text, shown.cursors)) ==
                some (⟨0⟩, some "kept", some #[⟨4, 4⟩]) &&
              refused.loop.state.buffers.size == 1 &&
              refused.model.texts.texts.size == 1 &&
              refused.model.texts.snapshots.size == asked.model.texts.snapshots.size &&
              refused.jobs.files == asked.jobs.files },
    { name :=
        "a file longer than the limit the load job is registered with is refused as too large, with its size and the limit, and a path that is not absolute as a relative path: each is said in the echo area by the same route, and nothing is opened"
      run :=
        pure <|
          match filesDriver (fileJobs 4), filesDriver with
          | some small, some driver =>
            let (large, _) := fedTo small (presses "C-o n")
            let (large, _) := large.finish 1
            let (relative, _) := fedTo driver (presses "C-o r")
            let (relative, _) := relative.finish 1
            echoOf large ==
                some
                  (Files.notOpened (inFiles "note.txt") (.tooLarge FileCases.noteBytes.size 4)) &&
              large.loop.state.buffers.size == 1 &&
              echoOf relative == some (Files.notOpened "relative.txt" .relativePath) &&
              relative.loop.state.buffers.size == 1
          | _, _ => false },
    { name :=
        "a load order's arguments are read back as the order, and arguments that are no order as none; the load job started with arguments that are no order fails"
      run :=
        pure <|
          let orders : List Files.LoadOrder :=
            [{ path := inFiles "note.txt", view := ⟨0⟩ }, { path := "relative.txt", view := ⟨7⟩ },
              { path := "/a b/é.txt", view := ⟨12⟩ }]
          orders.all (fun order => Files.LoadOrder.ofArguments? order.arguments == some order) &&
            [[], [.str "/a"], [.nat 0, .str "/a"], [.str "/a", .nat 0, .nat 1]].all
              (fun arguments => Files.LoadOrder.ofArguments? arguments == none) &&
            ((Files.loadWork Files.limit [.nat 1] ()).runModel { files := commandFiles }).1 matches
              .failed _ },
    { name :=
        "a load order with paths to open next crosses as arguments and back, and one with none crosses as before"
      run :=
        pure <|
          let order : Files.LoadOrder :=
            { path := inFiles "note.txt", view := ⟨3⟩, next := [inFiles "crlf.txt", "/a b/é.txt"] }
          Files.LoadOrder.ofArguments? order.arguments == some order &&
            order.arguments ==
              [.str (inFiles "note.txt").toString, .nat 3, .str (inFiles "crlf.txt").toString,
                .str "/a b/é.txt"] &&
            ({ path := "/a", view := ⟨0⟩ } : Files.LoadOrder).arguments == [.str "/a", .nat 0] &&
            Files.LoadOrder.ofArguments? [.str "/a", .nat 0, .str "/b", .nat 1] == none },
    { name :=
        "the open command given two paths starts one load, of the first; once it is finished the first file's buffer is shown and the second's load starts; once that is finished two new buffers hold the two files and the view shows the second"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let note := inFiles "note.txt"
            let crlf := inFiles "crlf.txt"
            let (asked, steps) := fedTo driver (presses "C-o 2")
            let (first, delivered) := asked.finish 1
            let (both, _) := first.finish 2
            let state := both.loop.state
            started steps ==
                #[{ name := Files.loadJob
                    arguments :=
                      Files.LoadOrder.arguments { path := note, view := ⟨0⟩, next := [crlf] } }] &&
              asked.pending.size == 1 &&
              (showing first).map (·.id) == some ⟨1⟩ &&
              (delivered.map (·.starts)) ==
                some
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path := crlf, view := ⟨0⟩ } }] &&
              first.pending.size == 1 &&
              state.buffers.size == 3 &&
              state.findFile note == some ⟨1⟩ &&
              state.findFile crlf == some ⟨2⟩ &&
              (showing both).map (·.id) == some ⟨2⟩ &&
              both.pending.isEmpty &&
              state.wellFormed },
    { name :=
        "the open command given an open path and then another shows the open one and starts the second's load at once"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some noted =>
            let crlf := inFiles "crlf.txt"
            let (scratch, _) := fedTo noted (presses "C-o 0")
            let (asked, steps) := fedTo scratch (presses "C-o 2")
            let (both, _) := asked.finish 2
            (showing scratch).map (·.id) == some ⟨0⟩ && (showing asked).map (·.id) == some ⟨1⟩ &&
              started steps ==
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path := crlf, view := ⟨0⟩ } }] &&
              both.loop.state.buffers.size == 3 &&
              (showing both).map (·.id) == both.loop.state.findFile crlf &&
              (both.loop.state.findFile crlf).isSome },
    { name :=
        "the open command given a path that cannot be opened and then one that can says the first cannot be opened and shows the second"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let lf := inFiles "lf.txt"
            let (asked, _) := fedTo driver (presses "C-o 3")
            let (refused, delivered) := asked.finish 1
            let (opened, _) := refused.finish 2
            echoOf refused == some (Files.notOpened (inFiles "missing.txt") .notFound) &&
              (showing refused).map (·.id) == some ⟨0⟩ &&
              (delivered.map (·.starts)) ==
                some
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path := lf, view := ⟨0⟩ } }] &&
              opened.loop.state.buffers.size == 2 &&
              (showing opened).map (·.id) == opened.loop.state.findFile lf &&
              (opened.loop.state.findFile lf).isSome },
    { name :=
        "the markers of the window that showed the scratch buffer are given up once the file's buffer is shown in it, and not before: they answer while the load is in flight and refuse noSuchMarker after the delivery"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o n")
            let (opened, _) := asked.finish 1
            match driver.loop.state.window? ⟨0⟩ with
            | none => false
            | some old =>
              ((markerRefusals old).runModel asked.model.texts).1.toOption == some [none, none] &&
                ((markerRefusals old).runModel opened.model.texts).1.toOption ==
                  some [some .noSuchMarker, some .noSuchMarker] },
    { name :=
        "a file whose asking view was closed while it loaded is shown in the focused view: the command is called in a second view, that view is closed before the job is finished, and the file's buffer is then shown in the view that has the focus"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, steps) := fedTo driver (presses "C-o s C-o n")
            let (closed, _) := fedTo asked (presses "C-o k")
            let (opened, _) := closed.finish 1
            started steps ==
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path, view := ⟨1⟩ } }] &&
              asked.loop.state.frame.focused == ⟨1⟩ &&
              closed.loop.state.frame.focused == ⟨0⟩ &&
              (showing closed ⟨1⟩).isNone &&
              opened.loop.state.findFile path == some ⟨1⟩ &&
              (showing opened).map (·.id) == some ⟨1⟩ &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              opened.loop.state.wellFormed },
    { name :=
        "a file whose asking view was closed while it loaded, delivered while a prompt has the focus, is shown in the view the prompt was asked from, which is not the first window: the prompt is still open with the focus, the first window shows what it showed, and nothing is said"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            -- Views 0, 1 and 2; the open command is called in view 2, which
            -- is then closed, and the prompt is asked from view 1.
            let (asked, _) := fedTo driver (presses "C-o s C-o s C-o n")
            let (prompted, _) := fedTo asked (presses "C-o k C-o o")
            let (opened, delivered) := prompted.finish 1
            let state := opened.loop.state
            asked.loop.state.frame.focused == ⟨2⟩ && (showing prompted ⟨2⟩).isNone &&
              prompted.loop.state.prompt.map (·.asker) == some ⟨1⟩ &&
              (delivered.map (·.ended)) == some (some .finished) &&
              state.prompt.isSome &&
              state.prompt == prompted.loop.state.prompt &&
              some state.frame.focused == state.minibufferView? &&
              (state.findFile path).isSome &&
              (showing opened ⟨1⟩).map (·.id) == state.findFile path &&
              (showing opened ⟨1⟩).bind (·.text) == some FileCases.noteText &&
              (showing opened).map (·.id) == some ⟨0⟩ &&
              echoOf opened == some "" &&
              state.wellFormed },
    { name :=
        "a file delivered while a prompt has the focus, whose asking view and the view the prompt was asked from were both closed, is shown in the first window of the list, with the prompt still open"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            -- Views 0 and 1; the open command is called in view 1, the
            -- prompt is asked from it, and it is closed with the prompt open.
            let (asked, _) := fedTo driver (presses "C-o s C-o n C-o o")
            let (closed, _) := fedTo asked (presses "C-o K")
            let (opened, delivered) := closed.finish 1
            let state := opened.loop.state
            asked.loop.state.prompt.map (·.asker) == some ⟨1⟩ && (showing closed ⟨1⟩).isNone &&
              closed.loop.state.prompt == asked.loop.state.prompt &&
              (delivered.map (·.ended)) == some (some .finished) &&
              state.prompt.isSome &&
              state.prompt == asked.loop.state.prompt &&
              some state.frame.focused == state.minibufferView? &&
              (state.findFile path).isSome &&
              (showing opened).map (·.id) == state.findFile path &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              echoOf opened == some "" &&
              state.wellFormed },
    { name :=
        "the open command called in the minibuffer's view, with a path, shows the file in the view the prompt was asked from and leaves the prompt open: a file that is not open once its job is finished, and one that is open at once, with no job started"
      run :=
        pure <|
          match filesDriver, noteOpen with
          | some driver, some noted =>
            let path := inFiles "note.txt"
            let behind (before after : TestDriver) : Bool :=
              let state := after.loop.state
              state.prompt.isSome && state.prompt == before.loop.state.prompt &&
                some state.frame.focused == state.minibufferView? &&
                (state.findFile path).isSome &&
                (showing after).map (·.id) == state.findFile path &&
                (showing after).bind (·.text) == some FileCases.noteText &&
                echoOf after == some "" &&
                state.wellFormed
            let (prompted, _) := fedTo driver (presses "C-o o")
            let (asked, steps) := fedTo prompted (presses "C-o n")
            let (opened, delivered) := asked.finish 1
            -- The file is open in view 0, which then shows the scratch
            -- buffer again.
            let (shown, _) := fedTo noted (presses "C-o 0 C-o o")
            let (again, repeated) := fedTo shown (presses "C-o n")
            started steps ==
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path, view := ⟨1⟩ } }] &&
              prompted.loop.state.minibufferView? == some ⟨1⟩ &&
              (delivered.map (·.ended)) == some (some .finished) &&
              behind prompted opened &&
              (showing shown).map (·.id) == some ⟨0⟩ &&
              started repeated == #[] &&
              again.pending.isEmpty &&
              behind shown again
          | _, _ => false },
    { name :=
        "a file loaded where no window can show it is said in the echo area as loaded and not shown: in a state whose focused view has no window, for an order whose view has none either, the buffer is there and holds the file, and the windows show what they showed"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let state := driver.loop.state
            let astray : TestDriver :=
              { driver with
                loop :=
                  { driver.loop with
                    state := { state with frame := { state.frame with focused := ⟨7⟩ } } } }
            let asked :=
              astray.started
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path, view := ⟨9⟩ } }]
            let (opened, _) := asked.finish 1
            echoOf opened == some (Files.notShown path) &&
              Files.notShown path != Files.notOpened path .notFound &&
              (showing opened).map (·.id) == some ⟨0⟩ &&
              opened.loop.state.findFile path == some ⟨1⟩ },
    { name :=
        "opening a path that is open shows its buffer and makes no second one: with the file open and another buffer shown in the view since, the open command shows the file's buffer again, with one cursor at its start, the step hands back no job to start, and there are as many buffers and texts as before"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o n")
            let (opened, _) := asked.finish 1
            let (back, _) := fedTo opened (presses "C-o 0")
            let (again, steps) := fedTo back (presses "C-o n")
            (showing back).map (·.id) == some ⟨0⟩ && started steps == #[] &&
              again.pending.isEmpty &&
              (showing again).map (fun shown => (shown.id, shown.text, shown.cursors)) ==
                some (⟨1⟩, some FileCases.noteText, some #[⟨0, 0⟩]) &&
              again.loop.state.buffers.size == opened.loop.state.buffers.size &&
              again.model.texts.texts.size == opened.model.texts.texts.size &&
              echoOf again == some "" },
    { name :=
        "two opens of one path in flight make one buffer: the command is run twice before either job is finished, and once both are, one buffer holds the path, the view shows it, and the second delivery made no text and left no snapshot"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, _) := fedTo driver (presses "C-o n C-o n")
            let (first, _) := asked.finish 1
            let (second, delivered) := first.finish 2
            asked.pending.size == 2 && (delivered.map (·.ended)) == some (some .finished) &&
              second.loop.state.findFile path == some ⟨1⟩ &&
              second.loop.state.buffers.size == 2 &&
              (showing second).map (·.id) == some ⟨1⟩ &&
              second.model.texts.texts.size == first.model.texts.texts.size &&
              second.model.texts.snapshots.filterMap id ==
                first.model.texts.snapshots.filterMap id &&
              second.jobs.files.held.all (·.isNone) &&
              echoOf second == echoOf first },
    { name :=
        "a second file with the base name a buffer has gets a name of its own: two files called x.txt in two directories open as x.txt and x.txt<2>, each buffer holding its own path and its own text"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o a")
            let (first, _) := asked.finish 1
            let (asked, _) := fedTo first (presses "C-o b")
            let (second, _) := asked.finish 2
            let seen (driver : TestDriver) :=
              (showing driver).map fun shown =>
                (shown.buffer.name, shown.buffer.file.map (·.path), shown.text)
            seen first == some ("x.txt", some (fileRoot / "a" / "x.txt"), some "first x\n") &&
              seen second ==
                some ("x.txt<2>", some (fileRoot / "b" / "x.txt"), some "second x\n") &&
              statusOf second == some (named "x.txt<2>") &&
              second.loop.state.buffers.size == 3 },
    { name :=
        "the open command where no load job is registered says so in the echo area, by the job's name, starts nothing and leaves the view as it was"
      run :=
        pure <|
          match filesDriver (fun _ => none) with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, steps) := fedTo driver (presses "C-o n")
            started steps == #[] && asked.pending.isEmpty &&
              echoOf asked == some (Files.notOpening path (.noSuchJob Files.loadJob)) &&
              Files.notOpening path (.noSuchJob Files.loadJob) != Files.notOpened path .notFound &&
              (showing asked).map (·.id) == some ⟨0⟩ &&
              asked.loop.state.buffers.size == 1 },
    { name :=
        "a refused start in an open of several paths is said once, for its own path, and opens nothing after it: refused for the first path, a path after it that a buffer holds is not shown; refused for the second path, when the first one's load is delivered, the third is not said"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let note := inFiles "note.txt"
            let lf := inFiles "lf.txt"
            let crlf := inFiles "crlf.txt"
            let unregistered (driver : TestDriver) : TestDriver :=
              { driver with registered := fun _ => none }
            -- `lf.txt` is open in buffer 1, and view 0 shows the scratch
            -- buffer again; then no load job is registered.
            let (held, _) := fedTo ((fedTo driver (presses "C-o l")).1.finish 1).1 (presses "C-o 0")
            let (first, steps) :=
              fedTo (unregistered held) [.openFiles [note.toString, lf.toString, crlf.toString]]
            -- The first load is started; the load job is then unregistered,
            -- so the start its delivery asks for is refused.
            let (asked, _) := fedTo driver [.openFiles [note.toString, crlf.toString, lf.toString]]
            let (second, delivered) := (unregistered asked).finish 1
            held.loop.state.findFile lf == some ⟨1⟩ && (showing held).map (·.id) == some ⟨0⟩ &&
              started steps == #[] &&
              first.pending.isEmpty &&
              echoOf first == some (Files.notOpening note (.noSuchJob Files.loadJob)) &&
              (showing first).map (·.id) == some ⟨0⟩ &&
              first.loop.state.buffers.size == 2 &&
              asked.pending.size == 1 &&
              (delivered.map (·.ended)) == some (some .finished) &&
              (delivered.map (·.starts)) == some #[] &&
              second.pending.isEmpty &&
              echoOf second == some (Files.notOpening crlf (.noSuchJob Files.loadJob)) &&
              (showing second).map (·.id) == second.loop.state.findFile note &&
              (second.loop.state.findFile note).isSome &&
              second.loop.state.findFile lf == none &&
              second.loop.state.buffers.size == 2 },
    { name :=
        "an open of several paths whose asking view is closed while the first one loads opens every path, in order, in the focused view: the first file's buffer is shown there, a path after it that a buffer holds is shown there at once, after it, the load after that is started for that view, and its buffer is shown there last; with no path a buffer holds after the first, the first file's buffer is what the focused view shows once its load is delivered"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let note := inFiles "note.txt"
            let lf := inFiles "lf.txt"
            let crlf := inFiles "crlf.txt"
            -- `lf.txt` is open in buffer 1 and view 0 shows the scratch
            -- buffer again; view 0 is split, and the open is asked in view
            -- 1, which is then closed.
            let (held, _) := fedTo ((fedTo driver (presses "C-o l")).1.finish 1).1 (presses "C-o 0")
            let (split, _) := fedTo held (presses "C-o s")
            let (asked, steps) :=
              fedTo split [.openFiles [note.toString, lf.toString, crlf.toString]]
            let (closed, _) := fedTo asked (presses "C-o k")
            let (first, delivered) := closed.finish 2
            let (last, _) := first.finish 3
            let state := last.loop.state
            -- The same with no path a buffer holds: view 0 shows the scratch
            -- buffer until the first file's load is delivered.
            let (alone, _) :=
              fedTo (fedTo driver (presses "C-o s")).1 [.openFiles [note.toString, crlf.toString]]
            let (aloneClosed, _) := fedTo alone (presses "C-o k")
            let (aloneFirst, aloneDelivered) := aloneClosed.finish 1
            (showing held).map (·.id) == some ⟨0⟩ && (showing split).map (·.id) == some ⟨0⟩ &&
              split.loop.state.frame.focused == ⟨1⟩ &&
              started steps ==
                #[{ name := Files.loadJob
                    arguments :=
                      Files.LoadOrder.arguments
                        { path := note, view := ⟨1⟩, next := [lf, crlf] } }] &&
              closed.loop.state.frame.focused == ⟨0⟩ &&
              (showing closed ⟨1⟩).isNone &&
              (delivered.map (·.ended)) == some (some .finished) &&
              (first.loop.state.findFile note).isSome &&
              (showing first).map (·.id) == some ⟨1⟩ &&
              echoOf first == some "" &&
              (delivered.map (·.starts)) ==
                some
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path := crlf, view := ⟨0⟩ } }] &&
              state.buffers.size == 4 &&
              (state.findFile crlf).isSome &&
              (showing last).map (·.id) == state.findFile crlf &&
              (heldFile last).map (·.path) == some crlf &&
              last.pending.isEmpty &&
              state.wellFormed &&
              aloneClosed.loop.state.frame.focused == ⟨0⟩ &&
              (showing aloneClosed).map (·.id) == some ⟨0⟩ &&
              aloneFirst.loop.state.findFile note == some ⟨1⟩ &&
              (showing aloneFirst).map (·.id) == some ⟨1⟩ &&
              (aloneDelivered.map (·.starts)) ==
                some
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path := crlf, view := ⟨0⟩ } }] },
    { name :=
        "an interrupted delivery of a load in an open of several paths is rolled back with the rest of the open: wherever the interrupt key arrives in it, no buffer is made, the path after it that a buffer holds is not shown, and no later load is started; run to its end it starts the last load; and once the flag is down the same open opens every path"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let note := inFiles "note.txt"
            let lf := inFiles "lf.txt"
            let crlf := inFiles "crlf.txt"
            let paths := [note.toString, lf.toString, crlf.toString]
            -- `lf.txt` is open in buffer 1, view 0 shows the scratch buffer
            -- again, and the open's first load is job 2.
            let (held, _) := fedTo ((fedTo driver (presses "C-o l")).1.finish 1).1 (presses "C-o 0")
            let (asked, _) := fedTo held [.openFiles paths]
            -- The interrupt key arrives once the delivery has made `asks`
            -- requests of the models.
            let arriving (asks : Nat) : TestDriver :=
              let watch := { asked.model.watch with arrivesAfter := some asks }
              { asked with model := { asked.model with watch } }
            let delivered (asks : Nat) := (arriving asks).finish 2
            let rolledBack (asks : Nat) : Bool :=
              let (after, stepped) := delivered asks
              match stepped.map (·.ended) with
              | some (some Loop.Ending.interrupted) =>
                stepped.map (·.starts) == some #[] && after.pending.isEmpty &&
                  after.loop.state.buffers.size == 2 &&
                  after.loop.state.findFile note == none &&
                  (showing after).map (·.id) == some ⟨0⟩
              | some (some Loop.Ending.finished) =>
                stepped.map (·.starts) ==
                  some
                    #[{ name := Files.loadJob
                        arguments := Files.LoadOrder.arguments { path := crlf, view := ⟨0⟩ } }]
              | _ => false
            let (stopped, _) := delivered 0
            let (lowered, _) := stopped.feed interruptArrives
            let (again, _) := fedTo lowered [.openFiles paths]
            let (opened, _) := (again.finish 3).1.finish 4
            asked.pending.size == 1 &&
              ((delivered 0).2.map (·.ended)) == some (some .interrupted) &&
              ((delivered 40).2.map (·.ended)) == some (some .finished) &&
              (List.range 41).all rolledBack &&
              opened.loop.state.buffers.size == 4 &&
              (opened.loop.state.findFile note).isSome &&
              (showing opened).map (·.id) == opened.loop.state.findFile crlf &&
              (opened.loop.state.findFile crlf).isSome &&
              opened.loop.state.wellFormed },
    { name :=
        "the open command with no path among its arguments, with none and with the count and the register an input scheme hands a command, starts no job and asks for the path: a prompt is open, labelled as the open command's, whose continuation is the open command with no argument of its own, asked from the view the command was called in"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            ["C-o o", "C-o V"].all fun typed =>
              let (asked, steps) := fedTo driver (presses typed)
              started steps == #[] && asked.pending.isEmpty && echoOf asked == some "" &&
                asked.loop.state.prompt ==
                  some
                    { label := Files.openPrompt, view := ⟨1⟩, asker := ⟨0⟩
                      continuation := { command := Files.openName } } &&
                !Files.openPrompt.isEmpty &&
                asked.loop.state.frame.focused == ⟨1⟩ &&
                asked.loop.state.wellFormed },
    { name :=
        "the open command with no path while a prompt is open cannot ask: the echo area says so, with the refusal, and the one prompt is still open"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o o")
            let (again, steps) := fedTo asked (presses "C-o o")
            started steps == #[] && echoOf again == some (Files.notAsking (.alreadyOpen ⟨1⟩)) &&
              again.loop.state.prompt == asked.loop.state.prompt &&
              again.loop.state.prompt.isSome &&
              again.loop.state.windows.size == 2 },
    { name :=
        "the open command asks for its path and opens the answer: with the commands compiled code registers, the open command with no argument, the path of a file committed into the minibuffer, the accept command and the load job finished leave the view the command was called in showing the file's text, in a buffer called by the file's base name, with the prompt closed, and one job was started"
      run :=
        pure <|
          match compiledDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, _) := fedTo driver (presses "C-o o")
            let (typed, _) := fedTo asked [.commit path.toString]
            let (accepted, _) := fedTo typed (presses "C-o y")
            let (opened, delivered) := accepted.finish 1
            asked.loop.state.prompt.isSome && asked.pending.isEmpty &&
              minibufferText typed == some path.toString &&
              accepted.loop.state.prompt == none &&
              accepted.loop.state.frame.focused == ⟨0⟩ &&
              accepted.pending.map (fun job => (job.id, job.name)) == #[(1, Files.loadJob)] &&
              (delivered.map (·.ended)) == some (some .finished) &&
              opened.pending.isEmpty &&
              opened.next == 2 &&
              (showing opened).map (fun shown => (shown.buffer.name, shown.text)) ==
                some ("note.txt", some FileCases.noteText) &&
              statusOf opened == some (named "note.txt") &&
              opened.loop.state.wellFormed },
    { name :=
        "the save command on a modified buffer: once its job is finished, the file's bytes are the buffer's text as a save writes it, the buffer is not modified, its stamp is the one the files now have, no save is in flight, the snapshot the command took is released, the echo area says the file was written, and the view's status line has no modified field"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (saved, delivered) := saving.finish 2
            match (heldFile saving).bind (·.saving), showing saved with
            | some flight, some shown =>
              (delivered.map (·.ended)) == some (some .finished) && shown.text == some text &&
                bytesOf saved path == some (FileModel.encode text) &&
                !shown.buffer.isModified &&
                shown.buffer.file.map (·.stamp) == stampOf saved path &&
                stampOf saved path != stampOf opened path &&
                (shown.buffer.file.map (·.saving)) == some none &&
                snapshotRefusal saved flight.snapshot == some (some .noSuchSnapshot) &&
                echoOf saved == some (Files.wrote path) &&
                statusOf saved == some (named "note.txt")
            | _, _ => false },
    { name :=
        "while a save is in flight the buffer is still modified: after the save command and before its job is finished, the step has handed back the save job with its order, the buffer's save is in flight with a snapshot that reads as the buffer's text and the stamp the file was opened with, and the view's status line has the modified field"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (edited, _) := fedTo opened [.commit "x"]
            let (saving, steps) := fedTo edited (presses "C-o w")
            match (heldFile saving).bind (·.saving), (heldFile opened).map (·.stamp) with
            | some flight, some stamp =>
              started steps ==
                  #[{ name := Files.saveJob
                      arguments :=
                        Files.SaveOrder.arguments
                          { buffer := ⟨1⟩, snapshot := flight.snapshot, path
                            expect := .unchanged stamp } }] &&
                saving.pending.size == 1 &&
                (showing saving).map (·.buffer.isModified) == some true &&
                (heldFile saving).map (·.stamp) == some stamp &&
                ((flight.snapshot.read.runModel saving.model.texts).1.toOption) ==
                  some ("x" ++ FileCases.noteText) &&
                some flight.state == (showing edited).map (·.buffer.history.state) &&
                statusOf saving == some (namedModified "note.txt")
            | _, _ => false },
    { name :=
        "a save of a buffer whose file changed on disk after it was loaded leaves the file as it is and says the changed-on-disk refusal in the echo area, with the stamp the file now has: the buffer is still modified, with the stamp it was opened with, no save is in flight, and the snapshot is released"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let changed := rewritten opened path JobContract.otherFile
            let (saving, _) := fedTo changed ([.commit "x"] ++ presses "C-o w")
            let (refused, delivered) := saving.finish 2
            match (heldFile saving).bind (·.saving), stampOf changed path with
            | some flight, some found =>
              (delivered.map (·.ended)) == some (some .finished) &&
                bytesOf refused path == some JobContract.otherFile &&
                stampOf refused path == some found &&
                some found != stampOf opened path &&
                echoOf refused == some (Files.notSaved path (.changed (some found))) &&
                (showing refused).map (·.buffer.isModified) == some true &&
                (heldFile refused).map (fun file => (some file.stamp, file.saving)) ==
                  some (stampOf opened path, none) &&
                snapshotRefusal refused flight.snapshot == some (some .noSuchSnapshot) &&
                statusOf refused == some (namedModified "note.txt")
            | _, _ => false },
    { name :=
        "open then save with no edit writes the file and leaves its bytes as they were, for a file whose lines end in line feeds, one whose lines end in CRLF, one with both and two with bytes that are not UTF-8: the save's job has run, the files have a new stamp for the path, which is the buffer's, the echo area says the file was written, and the bytes are byte for byte what they were"
      run :=
        pure <|
          ["a\nb\n".toUTF8, "a\r\nb\r\n".toUTF8, mostlyCrlf, FileCases.noteBytes,
                JobContract.rawFile].all
            fun bytes =>
            match noteOpen (fileModelOf #[("note.txt", bytes)]) with
            | none => false
            | some opened =>
              let path := inFiles "note.txt"
              let (saving, _) := fedTo opened (presses "C-o w")
              let (saved, delivered) := saving.finish 2
              (saving.pending.map fun job => (job.name, job.outcome matches .finished _)) ==
                  #[(Files.saveJob, true)] &&
                (delivered.map (·.ended)) == some (some .finished) &&
                bytesOf saved path == some bytes &&
                (stampOf saved path).isSome &&
                stampOf saved path != stampOf opened path &&
                (heldFile saved).map (·.stamp) == stampOf saved path &&
                echoOf saved == some (Files.wrote path) &&
                (showing saved).map (·.buffer.isModified) == some false },
    { name :=
        "a save order's arguments are read back as the order, for each thing a save can expect and for a stamp from before 1970, and arguments that are no order as none; the save job started with arguments that are no order fails"
      run :=
        pure <|
          let stamps : List File.Stamp :=
            [{ seconds := 5, nanoseconds := 7, size := 9 },
              { seconds := -3, nanoseconds := 999999999, size := 0 }]
          let expects : List File.Expect := stamps.map .unchanged ++ [.absent, .whatever]
          expects.all
                (fun expect =>
                  let order : Files.SaveOrder :=
                    { buffer := ⟨3⟩, snapshot := ⟨11⟩, path := "/a b/é.txt", expect }
                  Files.SaveOrder.ofArguments? order.arguments == some order) &&
              [[], [.nat 1], [.nat 1, .nat 2, .str "/a"],
                    [.nat 1, .nat 2, .str "/a", .str "sometimes"],
                    [.nat 1, .nat 2, .str "/a", .str "absent", .nat 1],
                    [.str "/a", .nat 1, .nat 2, .str "absent"]].all
                (fun arguments => Files.SaveOrder.ofArguments? arguments == none) &&
            ((Files.saveWork [.nat 1] ()).runModel { files := commandFiles }).1 matches .failed _ },
    { name :=
        "the save command on a buffer with no file says so in the echo area, by the buffer's name, starts no job and takes no snapshot; saving a buffer there is none of says so too"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (shown, _) := fedTo driver [pressF5]
            let (asked, steps) := fedTo shown (presses "C-o w")
            let (absent, absentSteps) := fedTo shown (presses "C-o x")
            match (showing driver).map (·.buffer.name) with
            | none => false
            | some name =>
              started steps == #[] && asked.pending.isEmpty &&
                echoOf asked == some (Files.noFile name) &&
                asked.model.texts.snapshots.size == shown.model.texts.snapshots.size &&
                started absentSteps == #[] &&
                echoOf absent == some Files.noBuffer &&
                absent.model.texts.snapshots.size == shown.model.texts.snapshots.size &&
                Files.noBuffer != Files.noFile name },
    { name :=
        "a second save while one is in flight is refused when it is asked: the echo area says the file is being saved, no second job is started and no snapshot is taken, and once the first is finished the buffer is saved once, not modified, with the stamp the files have"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (again, steps) := fedTo saving (presses "C-o w")
            let (saved, _) := again.finish 2
            started steps == #[] && again.pending.size == 1 &&
              echoOf again == some (Files.beingSaved path) &&
              again.model.texts.snapshots.size == saving.model.texts.snapshots.size &&
              heldFile again == heldFile saving &&
              (showing saved).map (·.buffer.isModified) == some false &&
              (heldFile saved).map (fun file => (some file.stamp, file.saving)) ==
                some (stampOf saved path, none) &&
              saved.jobs.files.writes == opened.jobs.files.writes + 1 &&
              echoOf saved == some (Files.wrote path) },
    { name :=
        "a save that reports late marks the state it wrote: a commit fed between the save command and its job's end leaves the buffer modified once the job is finished, with the new stamp, and one undo, back to the state that was written, leaves it not modified"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (typed, _) := fedTo saving [.commit "y"]
            let (saved, _) := typed.finish 2
            let (undone, _) := fedTo saved (presses "C-o u")
            bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              (showing saved).bind (·.text) == some ("xy" ++ FileCases.noteText) &&
              (showing saved).map (·.buffer.isModified) == some true &&
              (heldFile saved).map (fun file => (some file.stamp, file.saving)) ==
                some (stampOf saved path, none) &&
              statusOf saved == some (namedModified "note.txt") &&
              (showing undone).bind (·.text) == some ("x" ++ FileCases.noteText) &&
              (showing undone).map (·.buffer.isModified) == some false &&
              statusOf undone == some (named "note.txt") },
    { name :=
        "a forced save writes over a file that changed on disk: with the file written by another program since it was opened, the save command with true as its argument writes the buffer's text as the file, and the buffer is not modified, with the new stamp; with the arguments the Vim scheme gives a bound command it is a plain save, and is refused as changed on disk"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (edited, _) := fedTo (rewritten opened path JobContract.otherFile) [.commit "x"]
            let (forcing, steps) := fedTo edited (presses "C-o f")
            let (forced, _) := forcing.finish 2
            let (plain, _) := fedTo edited (presses "C-o v")
            let (refused, _) := plain.finish 2
            (started steps).map
                  (fun start => (Files.SaveOrder.ofArguments? start.arguments).map (·.expect)) ==
                #[some .whatever] &&
              bytesOf forced path == some (FileModel.encode text) &&
              (showing forced).map (·.buffer.isModified) == some false &&
              (heldFile forced).map (fun file => (some file.stamp, file.saving)) ==
                some (stampOf forced path, none) &&
              echoOf forced == some (Files.wrote path) &&
              bytesOf refused path == some JobContract.otherFile &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf edited path))) &&
              (showing refused).map (·.buffer.isModified) == some true },
    { name :=
        "the save command where no save job is registered says so in the echo area, by the job's name, and leaves no save in flight: nothing is started, the snapshot it took is released, the buffer is as it was, and once the job is registered the buffer is saved"
      run :=
        pure <|
          match
            (filesDriver fun name =>
                  if name == Files.loadJob then fileJobs Files.limit name else none).map
              fun driver => ((fedTo driver (presses "C-o n")).1.finish 1).1 with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (edited, _) := fedTo opened [.commit "x"]
            let (asked, steps) := fedTo edited (presses "C-o w")
            let registered : TestDriver := { asked with registered := fileJobs }
            let (saving, _) := fedTo registered (presses "C-o w")
            let (saved, _) := saving.finish 2
            let live (driver : TestDriver) := (driver.model.texts.snapshots.filterMap id).size
            started steps == #[] && asked.pending.isEmpty &&
              echoOf asked == some (Files.notSaving path (.noSuchJob Files.saveJob)) &&
              Files.notSaving path (.noSuchJob Files.saveJob) != Files.notSaved path .notFound &&
              heldFile asked == heldFile edited &&
              (heldFile asked).map (·.saving) == some none &&
              asked.model.texts.snapshots.size == edited.model.texts.snapshots.size + 1 &&
              live asked == live edited &&
              bytesOf asked path == some FileCases.noteBytes &&
              echoOf saved == some (Files.wrote path) &&
              (showing saved).map (·.buffer.isModified) == some false &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) },
    { name :=
        "a buffer removed while its save runs: the file is written, the delivery says so in the echo area and is not refused, and the buffer stays removed"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (removed, _) := fedTo saving (presses "C-o 0 C-o d")
            let (saved, delivered) := removed.finish 2
            removed.loop.state.buffer? ⟨1⟩ == none &&
              (delivered.map (·.ended)) == some (some .finished) &&
              echoOf saved == some (Files.wrote path) &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              saved.loop.state.buffers == removed.loop.state.buffers &&
              saved.loop.state.wellFormed },
    { name :=
        "the file commands and their jobs as compiled code registers them: the open, save, edit and reload commands are registered under their names and the load, save and reload jobs under theirs, the open command with a path opens the file and the save command saves the buffer, and the open command with no path starts nothing and asks for one"
      run :=
        pure <|
          match compiledDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (bare, steps) := fedTo driver (presses "C-o o")
            let (asked, _) := fedTo driver (presses "C-o n")
            let (opened, _) := asked.finish 1
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            -- The first edit starts a check of the file too: the save is
            -- found by its name.
            let saveId := ((saving.pending.find? (·.name == Files.saveJob)).map (·.id)).getD 0
            let (saved, _) := saving.finish saveId
            Files.commands.map (·.name) ==
                #[Files.openName, Files.saveName, Files.editName, Files.reloadName,
                  Files.autoReloadName] &&
              Files.jobs.map (·.name) ==
                #[Files.loadJob, Files.saveJob, Files.reloadJob, Files.checkJob, Files.followJob] &&
              started steps == #[] &&
              bare.pending.isEmpty &&
              bare.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                some (Files.openPrompt, { command := Files.openName }) &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              (showing saved).bind (·.text) == some text &&
              bytesOf saved path == some (FileModel.encode text) &&
              echoOf saved == some (Files.wrote path) },
    { name :=
        "a point's offset is its row's start and the bytes of its first column characters: the row is clamped to the last line, the column to the row's content"
      run :=
        let offset (point : Files.At) : Option Nat :=
          ((do
                  let text ← createText "ab\nαβγ\n"
                  Files.offsetAt text point).runModel
              {}).1.toOption
        pure
          (offset ⟨1, 2⟩ == some 7 && offset ⟨1, 9⟩ == some 9 && offset ⟨7, 0⟩ == some 3 &&
            offset ⟨0, 1⟩ == some 1) },
    { name :=
        "a visit of a path no buffer holds loads it, and once the load is delivered the view shows it with one cursor at the row and the character column, and is focused"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, steps) := fedTo driver (presses "C-o s C-o g")
            let (visited, _) := asked.finish 1
            started steps ==
                #[{ name := Files.loadJob
                    arguments :=
                      Files.LoadOrder.arguments
                        { path := inFiles "note.txt", view := ⟨0⟩, point := some ⟨0, 2⟩
                          focus := true } }] &&
              asked.loop.state.frame.focused == ⟨1⟩ &&
              (showing visited).map (·.buffer.name) == some "note.txt" &&
              (showing visited).bind (·.cursors) == some #[⟨6, 6⟩] &&
              visited.loop.state.frame.focused == ⟨0⟩ },
    { name :=
        "a visit of a path a buffer holds shows that buffer at once, puts its cursor at the point and focuses the view, with no job"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (opened, _) := (fedTo driver (presses "C-o n")).1.finish 1
            let (visited, steps) := fedTo opened (presses "C-o 0 C-o s C-o g")
            started steps == #[] && visited.pending.isEmpty &&
              (showing visited).map (·.buffer.name) == some "note.txt" &&
              (showing visited).bind (·.cursors) == some #[⟨6, 6⟩] &&
              visited.loop.state.frame.focused == ⟨0⟩ },
    { name :=
        "a visit whose load is refused says so and leaves the view, its cursor and the focus as they were"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o s C-o G")
            let (refused, _) := asked.finish 1
            echoOf refused == some (Files.notOpened (inFiles "missing.txt") .notFound) &&
              (showing refused).map (·.id) == some ⟨0⟩ &&
              (showing refused).bind (·.cursors) == some #[⟨0, 0⟩] &&
              refused.loop.state.frame.focused == ⟨1⟩ &&
              refused.loop.state.buffers.size == 1 },
    { name :=
        "a load order crosses as arguments and back with a point and the focus and without, an order with no point crosses as it did, and arguments of that shape still read"
      run :=
        let order : Files.LoadOrder := { path := "/a", view := ⟨2⟩, next := ["/b"] }
        let pointed : Files.LoadOrder :=
          { order with
            point := some ⟨3, 4⟩, focus := true }
        pure
          (Files.LoadOrder.ofArguments? order.arguments == some order &&
            Files.LoadOrder.ofArguments? pointed.arguments == some pointed &&
            Files.LoadOrder.ofArguments? { pointed with focus := false }.arguments ==
              some { pointed with focus := false } &&
            order.arguments == [.str "/a", .nat 2, .str "/b"] &&
            Files.LoadOrder.ofArguments? [.str "/a", .nat 2] ==
              some { path := "/a", view := ⟨2⟩ }) }]

/-- What the command `leave` of the quit checks says in the echo area when
it is refused, for a buffer called `name`. -/
def notLeaving (name : String) : String :=
  s!"not leaving: {name}"

/-- What a step of the quit checks is handed: the open command with the
path of `note.txt` (`C-o n`) and the save command (`C-o w`), as the file
command checks have them, and six commands written here, under `C-l`:
`leave` (`l`) asks the editor to quit and says a refusal (`notLeaving`),
`leave-then-fail` (`f`) asks and is then refused, `stamp` (`s`) edits its
buffer, `other` (`o`) says `other`, `hand-leave` (`h`) asks for `leave`
to be run after it, and `hand-leave-other` (`t`) asks for `leave` and then
`other` to be run after it. Two more ask for the config to be reloaded: `again`
(`r`), and `again-then-fail` (`g`), which asks and is then refused; and two
ask for the theme `second` to be loaded, which the loop is told is
registered: `pick` (`p`), and `pick-then-fail` (`k`), which asks and is then
refused. -/
def quitKeys : Loop.Keys TestScheme.scheme :=
  {
    dispatchKeys
      [("C-o n", opens (inFiles "note.txt")), ("C-o w", invoke Files.saveName),
        ("C-l l", invoke "leave"), ("C-l f", invoke "leave-then-fail"), ("C-l s", invoke "stamp"),
        ("C-l o", invoke "other"), ("C-l h", invoke "hand-leave"),
        ("C-l t", invoke "hand-leave-other"), ("C-l r", invoke "again"),
        ("C-l g", invoke "again-then-fail"), ("C-l p", invoke "pick"),
        ("C-l k", invoke "pick-then-fail")]
      [(Files.openName, fun call => do
          Files.openCommand call
          return none),
        (Files.saveName, fun call => do
          Files.saveCommand call
          return none),
        ("leave", fun _ => do
          if let .error (.unsaved name)← quit then
            message (notLeaving name)
          return none),
        ("leave-then-fail", failingAfter fun _ => discard quit), ("stamp", stamp),
        ("other", fun _ => do
          message "other"
          return none),
        ("hand-leave", fun _ => do
          Editor.invoke { command := "leave" }
          return none),
        ("hand-leave-other", fun _ => do
          Editor.invoke { command := "leave" }
          Editor.invoke { command := "other" }
          return none),
        ("again", fun _ => do
          reloadConfig
          return none),
        ("again-then-fail", failingAfter fun _ => reloadConfig),
        ("pick", fun _ => do
          discard <| loadTheme "second"
          return none),
        ("pick-then-fail", failingAfter fun _ => discard <| loadTheme "second")] with
    registered := { themeNames := #["second"] } }

/-- A driver of the quit checks over the files `files`, with the file
`note.txt` open in view 0: the open command, and its job finished. The load
is job 1. -/
def quitDriver (files : FileModel := commandFiles) : Option TestDriver :=
  (Loop.Driver.over quitKeys fileJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => ((fedTo { driver with jobs := { files } } (presses "C-o n")).1.finish 1).1

/-- The checks of quitting in the loop (`Editor/Loop.lean`, "Quit"), on the
loop's driver over the editor's models and the model of files, with
commands written here: the step says stop once the editor can leave, a quit
waits for a save in flight, and a quit that cannot go ahead is withdrawn.
They name no ex name. -/
def dispatchQuitChecks : List Check :=
  let next (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array (Option Loop.Next) :=
    steps.map (·.map (·.next))
  let path := inFiles "note.txt"
  [{  name :=
        "a key whose command asks the editor to quit: the step publishes a scene, the last, and says stop, and the driver has stopped; a step that ran another command says continue"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (other, went) := fedTo driver (presses "C-l o")
            let (left, steps) := fedTo other (presses "C-l l")
            next went == #[some .continue, some .continue] && !other.stopped &&
              next steps == #[some .continue, some .stop] &&
              left.stopped &&
              left.loop.state.quitting &&
              left.model.display.scenes.size == other.model.display.scenes.size + 2 },
    { name :=
        "a command that asks the editor to quit and is then refused says continue, and the state is not asked to quit"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (failed, steps) := fedTo driver (presses "C-l f")
            next steps == #[some .continue, some .continue] && !failed.stopped &&
              !failed.loop.state.quitting &&
              promptEcho failed == "leave-then-fail: refused: bad range" },
    { name :=
        "asked to quit while a save is in flight, the step says continue and the editor waits: a key fed meanwhile is handled, the delivery of the save's result says stop, and the file then holds the buffer's text"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let text := "x" ++ FileCases.noteText
            let (saving, _) := fedTo driver ([.commit "x"] ++ presses "C-o w")
            let (asked, steps) := fedTo saving (presses "C-l l")
            let (meanwhile, went) := fedTo asked (presses "C-l o")
            let (left, delivered) := meanwhile.finish 2
            next steps == #[some .continue, some .continue] && promptEcho asked == "" &&
              asked.loop.state.quitting &&
              !asked.stopped &&
              next went == #[some .continue, some .continue] &&
              promptEcho meanwhile == "other" &&
              meanwhile.loop.state.quitting &&
              !meanwhile.stopped &&
              delivered.map (·.next) == some .stop &&
              left.stopped &&
              bytesOf left path == some (FileModel.encode text) &&
              (showing left).map (·.buffer.isModified) == some false },
    { name :=
        "asked to quit while a save is in flight that is then refused, the file having changed behind the editor: the delivery says continue, the state is no longer asked to quit, the echo area has the save's refusal, and the buffer is still modified"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let changed := rewritten driver path JobContract.otherFile
            let (asked, _) := fedTo changed ([.commit "x"] ++ presses "C-o w C-l l")
            let (refused, delivered) := asked.finish 2
            asked.loop.state.quitting && delivered.map (·.next) == some .continue &&
              !refused.stopped &&
              !refused.loop.state.quitting &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
              (showing refused).map (·.buffer.isModified) == some true &&
              bytesOf refused path == some JobContract.otherFile },
    { name :=
        "asked to quit while a save of a buffer that is not modified is in flight, which is then refused, the file having changed behind the editor: the delivery says continue, the driver has not stopped, the state is no longer asked to quit, and the echo area has the save's refusal"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let changed := rewritten driver path JobContract.otherFile
            let (asked, _) := fedTo changed (presses "C-o w C-l l")
            let (refused, delivered) := asked.finish 2
            asked.loop.state.quitting && !asked.stopped &&
              (showing asked).map (·.buffer.isModified) == some false &&
              delivered.map (·.next) == some .continue &&
              !refused.stopped &&
              !refused.loop.state.quitting &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
              bytesOf refused path == some JobContract.otherFile },
    { name :=
        "an edit made while a quit waits for a save withdraws it: the state is no longer asked to quit after the edit's step, and the delivery of the save's result says continue, with the file written and the buffer still modified"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver ([.commit "x"] ++ presses "C-o w C-l l")
            let (edited, steps) := fedTo asked [.commit "y"]
            let (saved, delivered) := edited.finish 2
            asked.loop.state.quitting && next steps == #[some .continue] &&
              !edited.loop.state.quitting &&
              delivered.map (·.next) == some .continue &&
              !saved.stopped &&
              !saved.loop.state.quitting &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              (showing saved).map (·.buffer.isModified) == some true },
    { name :=
        "a command that asks to quit with a file's buffer modified is refused and the editor goes on; once the buffer is saved the same key stops it"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (refused, steps) := fedTo driver ([.commit "x"] ++ presses "C-l l")
            let (saved, _) := fedTo refused (presses "C-o w")
            let (saved, _) := saved.finish 2
            let (left, last) := fedTo saved (presses "C-l l")
            promptEcho refused == notLeaving "note.txt" && !refused.loop.state.quitting &&
              steps.all (·.all (·.next == .continue)) &&
              !saved.stopped &&
              next last == #[some .continue, some .stop] &&
              left.stopped },
    { name :=
        "a close request while a file's buffer has unsaved changes: the step says continue and publishes one scene, whose echo area has the quit command's refusal, the state is not asked to quit, and the next key's command runs"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (edited, _) := fedTo driver [.commit "x"]
            let (refused, steps) := fedTo edited [.closeRequested]
            let (after, _) := fedTo refused (presses "C-l o")
            next steps == #[some .continue] &&
              refused.model.display.scenes.size == edited.model.display.scenes.size + 1 &&
              echoOf refused == some (Ex.notQuitting (.unsaved "note.txt")) &&
              !refused.loop.state.quitting &&
              !refused.stopped &&
              promptEcho after == "other" },
    { name :=
        "a close request with nothing unsaved publishes one scene, the last, and says stop, and the driver has stopped"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (left, steps) := fedTo driver [.closeRequested]
            next steps == #[some .stop] && left.stopped &&
              left.model.display.scenes.size == driver.model.display.scenes.size + 1 },
    { name :=
        "a close request while a save is in flight says continue, and the delivery of the save's result says stop"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (asked, steps) :=
              fedTo driver ([.commit "x"] ++ presses "C-o w" ++ [.closeRequested])
            let (left, delivered) := asked.finish 2
            steps.back?.join.map (·.next) == some .continue && asked.loop.state.quitting &&
              !asked.stopped &&
              delivered.map (·.next) == some .stop &&
              left.stopped },
    { name :=
        "a close request while a save is in flight that is then refused, the file having changed behind the editor: the delivery says continue, the driver has not stopped, and the echo area has the save's refusal"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let changed := rewritten driver path JobContract.otherFile
            let (asked, steps) :=
              fedTo changed ([.commit "x"] ++ presses "C-o w" ++ [.closeRequested])
            let (refused, delivered) := asked.finish 2
            steps.back?.join.map (·.next) == some .continue && asked.loop.state.quitting &&
              delivered.map (·.next) == some .continue &&
              !refused.stopped &&
              !refused.loop.state.quitting &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) },
    { name :=
        "the driver records that a step said stop when the step was one it ran for an invocation a command asked for: the fed step says continue and the driver has stopped"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (left, steps) := fedTo driver (presses "C-l h")
            next steps == #[some .continue, some .continue] && left.stopped &&
              left.loop.state.quitting },
    { name :=
        "once a step said stop the driver runs no further invocation: a command that asks for a quitting command and then another to be run after it stops the driver at the first, whose scene is the last, and the second never runs: no scene says its message; where the first is refused, the second runs"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let echoes (before after : TestDriver) : Array String :=
              (after.model.display.scenes.map (·.echo)).extract before.model.display.scenes.size
            let (left, steps) := fedTo driver (presses "C-l t")
            let (went, _) := fedTo driver ([.commit "x"] ++ presses "C-l t")
            next steps == #[some .continue, some .continue] && left.stopped &&
              left.model.display.scenes.size == driver.model.display.scenes.size + 3 &&
              !(echoes driver left).contains "other" &&
              !went.stopped &&
              promptEcho went == "other" &&
              (echoes driver went).contains (notLeaving "note.txt") },
    { name :=
        "a step whose command asked for the config to be reloaded hands the request back, and the state after it is not asking; a step that ran another command hands back none, and so does one whose command asked and was then refused; the driver counts the reloads asked for"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let asked (steps : Array (Option (Loop.Stepped TestScheme.scheme))) :=
              steps.map (·.map (·.reload))
            let (once, steps) := fedTo driver (presses "C-l r")
            let (other, went) := fedTo once (presses "C-l o")
            let (failed, lost) := fedTo other (presses "C-l g")
            let (twice, _) := fedTo failed (presses "C-l r")
            asked steps == #[some false, some true] && !once.loop.state.reload &&
              once.reloads == 1 &&
              asked went == #[some false, some false] &&
              asked lost == #[some false, some false] &&
              !failed.loop.state.reload &&
              failed.reloads == 1 &&
              twice.reloads == 2 &&
              driver.reloads == 0 },
    { name :=
        "a step whose command asked for a theme to be loaded hands its name back, and the state after it holds none; a step that ran another command hands back none, and so does one whose command asked and was then refused; the driver records the themes asked for"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let asked (steps : Array (Option (Loop.Stepped TestScheme.scheme))) :=
              steps.map (·.map (·.theme))
            let (once, steps) := fedTo driver (presses "C-l p")
            let (other, went) := fedTo once (presses "C-l o")
            let (failed, lost) := fedTo other (presses "C-l k")
            asked steps == #[some none, some (some "second")] && once.loop.state.theme == none &&
              once.themes == #["second"] &&
              asked went == #[some none, some none] &&
              asked lost == #[some none, some none] &&
              failed.loop.state.theme == none &&
              failed.themes == #["second"] &&
              driver.themes == #[] }]

/-- The compiled quit command (`Ex.quitCommand`), as the system quit checks
register it. -/
def compiledQuit : Dispatched := fun call => do
  Ex.quitCommand call
  return none

/-- What a step of the system quit checks is handed: the open command with
the path of `note.txt` (`C-o n`) and the save command (`C-o w`), as the
quit checks have them, and `quit` (`Ex.quitName`), bound to `C-l q`, as
`command` does it: the compiled one, or one config registered in its
place. -/
def systemQuitKeys (command : Dispatched := compiledQuit) : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    [("C-o n", opens (inFiles "note.txt")), ("C-o w", invoke Files.saveName),
      ("C-l q", invoke Ex.quitName)]
    [(Files.openName, fun call => do
        Files.openCommand call
        return none),
      (Files.saveName, fun call => do
        Files.saveCommand call
        return none),
      (Ex.quitName, command)]

/-- A driver of the system quit checks, with `quit` as `command` does it
and the file `note.txt` open in view 0, as `quitDriver` opens it. -/
def systemQuitDriver (command : Dispatched := compiledQuit) : Option TestDriver :=
  (Loop.Driver.over (systemQuitKeys command) fileJobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver =>
    ((fedTo { driver with jobs := { files := commandFiles } } (presses "C-o n")).1.finish 1).1

/-- How many times `driver`'s frame was asked to keep running. -/
def keptRunning (driver : TestDriver) : Nat :=
  (driver.model.display.asked.filter (· == .keepRunning)).size

/-- The checks of the system's quit in the loop (`Editor/Loop.lean`,
"Quit"): `Event.quitRequested` runs `quit` as an invocation no key yielded,
so the editor leaves as it does for `:q`, or keeps running and asks the
frame `keepRunning` once, when `quit` is refused or a quit it asked is
withdrawn. -/
def systemQuitChecks : List Check :=
  let next (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array (Option Loop.Next) :=
    steps.map (·.map (·.next))
  let path := inFiles "note.txt"
  [{  name :=
        "the system asks to quit with nothing unsaved: the step says stop, the driver has stopped, and the frame is not asked to keep running"
      run :=
        pure <|
          match systemQuitDriver with
          | none => false
          | some driver =>
            let (left, steps) := fedTo driver [.quitRequested]
            next steps == #[some .stop] && left.stopped && keptRunning left == 0 },
    { name :=
        "the system asks to quit with a file's buffer that has unsaved changes: the editor goes on, the echo area says why, the frame is asked to keep running once, and the system's quit is no longer pending; a later edit asks nothing more"
      run :=
        pure <|
          match systemQuitDriver with
          | none => false
          | some driver =>
            let (refused, steps) := fedTo driver [.commit "x", .quitRequested]
            let (edited, _) := fedTo refused [.commit "y"]
            next steps == #[some .continue, some .continue] && !refused.stopped &&
              echoOf refused == some (Ex.notQuitting (.unsaved "note.txt")) &&
              echoOf refused == some "quit: note.txt has unsaved changes" &&
              keptRunning refused == 1 &&
              !refused.loop.state.systemQuit &&
              keptRunning edited == 1 },
    { name :=
        "the system asks to quit with a save in flight: the step says continue and asks nothing, and the delivery of the save's result says stop; when that save is refused, the delivery says continue, the frame is asked to keep running once, and the echo area has the save's refusal"
      run :=
        pure <|
          match systemQuitDriver with
          | none => false
          | some driver =>
            let (saving, _) := fedTo driver ([.commit "x"] ++ presses "C-o w")
            let (asked, steps) := fedTo saving [.quitRequested]
            let (left, delivered) := asked.finish 2
            let changed := rewritten driver path JobContract.otherFile
            let (refusing, _) := fedTo changed ([.commit "x"] ++ presses "C-o w")
            let (pending, _) := fedTo refusing [.quitRequested]
            let (refused, undelivered) := pending.finish 2
            next steps == #[some .continue] && !asked.stopped && keptRunning asked == 0 &&
              delivered.map (·.next) == some .stop &&
              left.stopped &&
              keptRunning left == 0 &&
              keptRunning pending == 0 &&
              undelivered.map (·.next) == some .continue &&
              !refused.stopped &&
              keptRunning refused == 1 &&
              !refused.loop.state.systemQuit &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) },
    { name :=
        "config's command named quit runs in place of the compiled one on the system's quit: its message is the echo, and since nothing asked to quit the frame is asked to keep running once"
      run :=
        pure <|
          match
            systemQuitDriver fun _ => do
              message "mine"
              return none with
          | none => false
          | some driver =>
            let (ran, steps) := fedTo driver [.commit "x", .quitRequested]
            next steps == #[some .continue, some .continue] && !ran.stopped &&
              echoOf ran == some "mine" &&
              keptRunning ran == 1 &&
              !ran.loop.state.systemQuit },
    { name :=
        "a quit typed, not asked by the system, that is refused asks the frame nothing: it was the editor's own quit"
      run :=
        pure <|
          match systemQuitDriver with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver ([.commit "x"] ++ presses "C-l q")
            !refused.stopped && echoOf refused == some (Ex.notQuitting (.unsaved "note.txt")) &&
              keptRunning refused == 0 }]

/-- The ex bindings of the ex line's own checks, written here: `say` runs
the command `greet` of the prompt checks with the rest of the line, and
`plain` runs it and takes nothing; `ghost` is bound to a command nobody
registered, and `burst` to `boom`, which inserts and is then refused. -/
def exTestBindings : Array Ex.Binding :=
  #[{ name := "say", command := "greet", takes := .text }, { name := "plain", command := "greet" },
    { name := "ghost", command := "nobody" }, { name := "burst", command := "boom" }]

/-- The names of `bindings`, each once, in the order they are first bound:
what a step of the ex checks is told the bound ex names are. -/
def exNamesOf (bindings : Array Ex.Binding) : Array String :=
  bindings.foldl
    (fun names binding => if names.contains binding.name then names else names.push binding.name)
    #[]

/-- What the ex prompt of a driver told of `bindings` holds once its
candidates are listed for `pattern`, with `chosen` as its choice: the
bound names, and of them what the fuzzy model answers for the pattern. -/
def exListed (pattern : String) (chosen : Option Nat := none)
    (bindings : Array Ex.Binding := exTestBindings) : Candidates :=
  let names := exNamesOf bindings
  { all := names, listedFor := some pattern
    listed := (FuzzyModel.rank pattern names).filterMap (names[·]?), chosen }

/-- What a step of the ex checks is handed. The commands are the ones
compiled code registers for the ex line, the minibuffer and files
(`Ex.commands`, `Minibuffer.commands`, `Files.commands`), each under the
name it is registered under, and then the commands of the prompt checks:
`greet`, which says what it was called with, `boom`, `other` and the test
scheme's self-insert. The ex bindings a command is told of are `bindings`,
the latest of a name, and the ex names it is told of are theirs
(`exNamesOf`): both are filled from the one list, so that no name is told
without its binding.

One keymap, the same for every view: `C-e e` runs the ex command, `C-e V`
runs it with the arguments the Vim scheme gives a command a key is bound
to, a count and a register, `C-e l` runs it with the line `say hello there`
as its first argument, `C-e y` and `C-e n` run the minibuffer's accept and
cancel commands, `C-e t` runs its command that moves to the next
candidate, and `C-e o` runs `other`. -/
def exKeys (bindings : Array Ex.Binding := exTestBindings) : Loop.Keys TestScheme.scheme :=
  let compiled : List (String × Dispatched) :=
    (Ex.commands ++ Minibuffer.commands ++ Files.commands).toList.filterMap fun registration =>
      match registration.action with
      | .call run =>
        some
          (registration.name, fun call => do
            run call
            return none)
      | _ => none
  {
    dispatchKeys
      [("C-e e", invoke Ex.name), ("C-e V", { command := Ex.name, arguments := [.nat 0, .str ""] }),
        ("C-e l", { command := Ex.name, arguments := [.str "say hello there"] }),
        ("C-e y", invoke Minibuffer.acceptName), ("C-e n", invoke Minibuffer.cancelName),
        ("C-e t", invoke Minibuffer.nextName), ("C-e o", invoke "other")]
      (compiled ++ promptCommands) with
    registered :=
      { ex := fun name => bindings.findRev? (·.name == name), exNames := exNamesOf bindings } }

/-- A driver of the ex checks over the initial state, told of the ex
bindings `bindings`, with the file commands' jobs and the files of the file
command checks; `none` if making the state was refused. -/
def exDriver (bindings : Array Ex.Binding := exTestBindings) : Option TestDriver :=
  (Loop.Driver.over (exKeys bindings) fileJobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

/-- The events of one ex line: the key that opens the ex line, `line`
committed into the minibuffer, and the accept key. -/
def exLine (line : String) : List Event :=
  presses "C-e e" ++ [.commit line] ++ presses "C-e y"

/-- The echo area of each scene `after` recorded that `before` had not. -/
def echoesSince (before after : TestDriver) : Array String :=
  (after.model.display.scenes.map (·.echo)).extract before.model.display.scenes.size

/-- A driver of the ex checks told of the ex names that ship
(`Ex.bindings`), with the file `note.txt` open in view 0 by the ex line
`e` and its path, its load finished. The load is job 1. -/
def exNoteOpen : Option TestDriver :=
  (exDriver Ex.bindings).map fun driver =>
    ((fedTo driver (exLine s!"e {inFiles "note.txt"}")).1.finish 1).1

/-- The checks of the ex command line (`Editor/Ex.lean`,
`Editor/Ex/Compiled.lean`), on the loop's driver over the editor's models,
the model of files and the test scheme: the ex command opens a prompt and
runs its answer as the command the line's name is bound to. Each message is
read from the function that makes it. -/
def exChecks : List Check :=
  let closed (driver : TestDriver) : Bool :=
    let state := driver.loop.state
    state.prompt == none && state.frame.focused == ⟨0⟩ && state.answered.isEmpty && state.wellFormed
  let hello : List Argument := [.str "hello there"]
  [{  name :=
        "the ex command opens a prompt labelled with the ex line's label, whose continuation is the ex command itself, with the focus in the minibuffer's view; called with a count and a register first, as a key under the Vim scheme calls it, it asks the same"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let asked (keys : String) :=
              let (asking, _) := fedTo driver (presses keys)
              asking.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                  some (Ex.label, { command := Ex.name }) &&
                asking.loop.state.minibufferView? == some asking.loop.state.frame.focused &&
                asking.loop.state.frame.focused != ⟨0⟩ &&
                asking.loop.state.wellFormed
            asked "C-e e" && asked "C-e V" },
    { name :=
        "a line typed on the ex line and accepted runs the command its name is bound to, with the rest of the line as its first argument, a string, in the view the line was asked from and with no keys; the accept key is three steps, the accept command, the ex command and the bound command, each with a scene"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say hello there"])
            let (accepted, _) := fedTo typed (presses "C-e y")
            minibufferText typed == some "say hello there" &&
              promptEcho accepted == greeted hello &&
              closed accepted &&
              echoesSince typed accepted == #["", "", "", greeted hello] },
    { name :=
        "criterion 5: a name nobody bound leaves the ex line's message for it in the echo area, with the prompt closed, and the editor goes on: the next key's command runs"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (unknown, _) := fedTo driver (exLine "nope 1 2")
            let (after, _) := fedTo unknown (presses "C-e o")
            promptEcho unknown == Ex.unknown "nope" && closed unknown &&
              echoOf unknown == some (Ex.unknown "nope") &&
              promptEcho after == "other" },
    { name :=
        "an argument for an ex name that takes nothing leaves the ex line's message for it in the echo area and runs nothing; the name alone runs its command with no arguments"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver (exLine "plain hello")
            let (ran, _) := fedTo driver (exLine "plain")
            promptEcho refused == Ex.noArgument "plain" && closed refused &&
              !(echoesSince driver refused).contains (greeted hello) &&
              promptEcho ran == greeted [] },
    { name :=
        "a range before an ex name, which no shipped name takes, leaves the ex line's message for it in the echo area and runs nothing; a range alone, which would go to a line in Vim, says that is not built"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver (exLine "3,5plain")
            let (spaced, _) := fedTo driver (exLine "% plain")
            let (alone, _) := fedTo driver (exLine "3")
            promptEcho refused == Ex.noRange "plain" && closed refused &&
              !(echoesSince driver refused).contains (greeted []) &&
              promptEcho spaced == Ex.noRange "plain" &&
              promptEcho alone == Ex.rangeAlone &&
              closed alone },
    { name :=
        "an empty line and a line of white space run nothing and leave the echo area empty, with the prompt closed"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (empty, _) := fedTo driver (presses "C-e e C-e y")
            let (blank, _) := fedTo driver (exLine "   ")
            promptEcho empty == "" && closed empty && promptEcho blank == "" && closed blank },
    { name :=
        "an ex name bound to a command nobody registered says there is no such command, by the command's name"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (ran, _) := fedTo driver (exLine "ghost")
            promptEcho ran == "nobody: no such command" && closed ran },
    { name :=
        "a command an ex line runs that is refused is rolled back, and the echo area says the refusal under the command's own name, not the ex command's"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (ran, _) := fedTo driver (exLine "burst")
            promptEcho ran == "boom: refused: bad range" && driverText ran == some "" &&
              closed ran },
    { name :=
        "a key fed after the accept key is handled after the command the line runs: the scenes show the bound command's message before the other command's"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say hello there"])
            let (after, _) := fedTo typed (presses "C-e y C-e o")
            echoesSince typed after == #["", "", "", greeted hello, greeted hello, "other"] },
    { name :=
        "the ex command called with a string as its first argument runs that line and opens no prompt"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (ran, steps) := fedTo driver (presses "C-e l")
            promptEcho ran == greeted hello && closed ran &&
              steps.map (·.map (·.answered)) ==
                #[some #[], some #[{ command := "greet", arguments := hello }]] &&
              ran.model.display.scenes.all (·.views.size == 1) },
    { name :=
        "the ex command while a prompt is open says the refusal after its own name and leaves that prompt open, with what was typed"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say"])
            let (again, _) := fedTo typed (presses "C-e e")
            (typed.loop.state.minibufferView?).map
                  (fun view => promptEcho again == Ex.notAsking (.alreadyOpen view)) ==
                some true &&
              again.loop.state.prompt == typed.loop.state.prompt &&
              again.loop.state.prompt.isSome &&
              minibufferText again == some "say" },
    { name := "cancelling the ex line runs nothing: the prompt is closed and no command is run"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (cancelled, steps) :=
              fedTo driver (presses "C-e e" ++ [.commit "say hello there"] ++ presses "C-e n")
            promptEcho cancelled == "" && closed cancelled &&
              steps.all (·.all (·.answered.isEmpty)) &&
              !(echoesSince driver cancelled).contains (greeted hello) },
    { name :=
        "the ex name e with a path: once the load is finished the view the line was asked from shows a buffer with the file's text, holding the file's path; before that it shows the scratch buffer"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, _) := fedTo driver (exLine s!"e {path}")
            let (opened, _) := asked.finish 1
            (showing asked).map (·.id) == some ⟨0⟩ && asked.pending.size == 1 && closed asked &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              (heldFile opened).map (·.path) == some path &&
              closed opened },
    { name :=
        "the ex name e with no argument asks for a path, with the open command's prompt, and starts nothing"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (exLine "e")
            asking.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                some (Files.openPrompt, { command := Files.openName }) &&
              asking.pending.isEmpty },
    { name :=
        "the ex name w after an edit starts a save, which is in flight until its job is finished: the file then holds the buffer's text, the buffer is not modified, and the echo area says the file was written"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (saving, _) := fedTo opened ([.commit "x"] ++ exLine "w")
            let (saved, _) := saving.finish 2
            (heldFile saving).bind (·.saving) != none && saving.pending.size == 1 &&
              (showing saving).map (·.buffer.isModified) == some true &&
              (showing saved).bind (·.text) == some text &&
              bytesOf saved path == some (FileModel.encode text) &&
              (showing saved).map (·.buffer.isModified) == some false &&
              echoOf saved == some (Files.wrote path) },
    { name :=
        "the ex name w with an argument says it takes none, by the ex line's message, and starts no save: the file is as it was and the buffer is still modified"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (refused, _) := fedTo opened ([.commit "x"] ++ exLine "w other.txt")
            promptEcho refused == Ex.noArgument "w" && refused.pending.isEmpty &&
              (heldFile refused).bind (·.saving) == none &&
              bytesOf refused path == some FileCases.noteBytes &&
              statusOf refused == some (namedModified "note.txt") },
    { name :=
        "the ex name w in the scratch buffer says the buffer has no file, by the save command's message, and starts nothing"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver (exLine "w")
            promptEcho refused == Files.noFile "scratch" && refused.pending.isEmpty &&
              closed refused },
    { name :=
        "the ex name q in an editor with nothing modified stops the driver; and so does q after text was typed in the scratch buffer alone, which holds no file"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (fresh, _) := fedTo driver (exLine "q")
            let (typed, _) := fedTo driver ([.commit "typed"] ++ exLine "q")
            !driver.stopped && fresh.stopped && typed.stopped && driverText typed == some "typed" },
    { name :=
        "the ex name q while a file's buffer is modified says the quit command's refusal, with the buffer's name, and the editor goes on: the driver has not stopped and the next key's command runs"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let (refused, _) := fedTo opened ([.commit "x"] ++ exLine "q")
            let (after, _) := fedTo refused (presses "C-e o")
            promptEcho refused == Ex.notQuitting (.unsaved "note.txt") && !refused.stopped &&
              !refused.loop.state.quitting &&
              closed refused &&
              promptEcho after == "other" },
    { name :=
        "criterion 1 on the models: w and then q with the save not yet finished does not stop the driver until the save is finished, and then the file holds the buffer's text"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (asked, _) := fedTo opened ([.commit "x"] ++ exLine "w" ++ exLine "q")
            let (left, _) := asked.finish 2
            asked.pending.size == 1 && !asked.stopped && asked.loop.state.quitting &&
              promptEcho asked == "" &&
              left.stopped &&
              bytesOf left path == some (FileModel.encode text) &&
              (showing left).map (·.buffer.isModified) == some false },
    { name := "the ex name q with an argument says it takes none and does not stop the driver"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver (exLine "q now")
            promptEcho refused == Ex.noArgument "q" && !refused.stopped &&
              !refused.loop.state.quitting },
    { name :=
        "criterion 2 on the models: the ex name wq on a modified buffer of a file starts the save and asks to quit: the driver has not stopped while the save is not finished, and once it is finished the file holds the buffer's text and the driver has stopped"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (asked, _) := fedTo opened ([.commit "x"] ++ exLine "wq")
            let (left, _) := asked.finish 2
            asked.pending.size == 1 && (heldFile asked).bind (·.saving) != none && !asked.stopped &&
              asked.loop.state.quitting &&
              left.stopped &&
              bytesOf left path == some (FileModel.encode text) &&
              (showing left).map (·.buffer.isModified) == some false },
    { name :=
        "the ex name wq on a buffer of a file that is not modified saves it all the same and stops the driver once the save is finished, with the file's bytes as they were"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (asked, _) := fedTo opened (exLine "wq")
            let (left, _) := asked.finish 2
            asked.pending.size == 1 && !asked.stopped && left.stopped &&
              bytesOf left path == some FileCases.noteBytes &&
              stampOf left path != stampOf opened path },
    { name :=
        "the ex name w and then wq with the save not yet finished: the save command says the file is being saved and starts no second save, the quit is asked and waits for the one save, and the driver stops once it is finished, with the buffer's text in the file"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (asked, _) := fedTo opened ([.commit "x"] ++ exLine "w" ++ exLine "wq")
            let (left, _) := asked.finish 2
            asked.pending.size == 1 && !asked.stopped && asked.loop.state.quitting &&
              promptEcho asked == Files.beingSaved path &&
              left.stopped &&
              bytesOf left path == some (FileModel.encode text) &&
              (showing left).map (·.buffer.isModified) == some false },
    { name :=
        "the ex name w, an edit, and then wq with the save not yet finished: no second save is started and the quit is refused with the buffer's name, by the quit command's message, which is what the echo area says; the driver does not stop when the save is finished, the file holds the text from before the edit, and the buffer is still modified"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (asked, _) :=
              fedTo opened ([.commit "x"] ++ exLine "w" ++ [.commit "y"] ++ exLine "wq")
            let (saved, _) := asked.finish 2
            asked.pending.size == 1 && !asked.stopped && !asked.loop.state.quitting &&
              promptEcho asked == Ex.notQuitting (.unsaved "note.txt") &&
              !saved.stopped &&
              !saved.loop.state.quitting &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              (showing saved).map (·.buffer.isModified) == some true },
    { name :=
        "the ex name wq in the scratch buffer says the buffer has no file, by the save command's message, starts nothing and does not ask to quit"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver ([.commit "typed"] ++ exLine "wq")
            promptEcho refused == Files.noFile "scratch" && refused.pending.isEmpty &&
              !refused.stopped &&
              !refused.loop.state.quitting },
    { name :=
        "the ex name wq with the file changed behind the editor: the save is refused, the echo area says so by the save command's message, the quit is withdrawn and the driver has not stopped; a later q is refused, the buffer being still modified"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let changed := rewritten opened path JobContract.otherFile
            let (asked, _) := fedTo changed ([.commit "x"] ++ exLine "wq")
            let (refused, _) := asked.finish 2
            let (later, _) := fedTo refused (exLine "q")
            asked.loop.state.quitting && !refused.stopped && !refused.loop.state.quitting &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
              bytesOf refused path == some JobContract.otherFile &&
              promptEcho later == Ex.notQuitting (.unsaved "note.txt") &&
              !later.stopped },
    { name :=
        "the ex name wq on a buffer that is not modified, with the file changed behind the editor: the save is refused, the echo area says so by the save command's message, the quit is withdrawn and the driver has not stopped; and so with w and then q in place of wq"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let changed := rewritten opened path JobContract.otherFile
            [exLine "wq", exLine "w" ++ exLine "q"].all fun lines =>
              let (asked, _) := fedTo changed lines
              let (refused, _) := asked.finish 2
              asked.loop.state.quitting && !asked.stopped &&
                (showing asked).map (·.buffer.isModified) == some false &&
                !refused.stopped &&
                !refused.loop.state.quitting &&
                echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
                bytesOf refused path == some JobContract.otherFile },
    { name :=
        "the ex name wq while another file's buffer has unsaved changes starts this buffer's save and is refused the quit, with the other buffer's name: the file is written and the driver has not stopped"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "crlf.txt"
            let (second, _) := fedTo opened ([.commit "x"] ++ exLine s!"e {path}")
            let (second, _) := second.finish 2
            let (asked, _) := fedTo second ([.commit "y"] ++ exLine "wq")
            let (saved, _) := asked.finish 3
            (showing second).map (·.buffer.name) == some "crlf.txt" &&
              promptEcho asked == Ex.notQuitting (.unsaved "note.txt") &&
              asked.pending.size == 1 &&
              !asked.loop.state.quitting &&
              !saved.stopped &&
              (bytesOf saved path).map (·.size) == some (mostlyCrlf.size + 1) &&
              echoOf saved == some (Files.wrote path) &&
              bytesOf saved (inFiles "note.txt") == some FileCases.noteBytes },
    { name :=
        "the ex name reload asks for the config to be reloaded: the driver counts one reload, and two once the line is typed twice; with an argument it says it takes none and asks for none"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (once, _) := fedTo driver (exLine "reload")
            let (twice, _) := fedTo once (exLine "reload")
            let (refused, _) := fedTo driver (exLine "reload now")
            driver.reloads == 0 && once.reloads == 1 && twice.reloads == 2 && closed twice &&
              !twice.stopped &&
              promptEcho once == "" &&
              promptEcho refused == Ex.noArgument "reload" &&
              refused.reloads == 0 },
    { name :=
        "the ex prompt's candidates are the ex names that are bound, each once, listed for the empty line when it opens; a typed letter lists the names the fuzzy model answers for it, and the scene shows them after the ex line's label"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-e e")
            let (typed, _) := fedTo asking (presses "s")
            let names := exTestBindings.map (·.name)
            candidatesOf asking == some (exListed "") &&
              (candidatesOf asking).map (·.all) == some names &&
              (candidatesOf asking).map (·.listed.size) == some names.size &&
              candidatesOf typed == some (exListed "s") &&
              (candidatesOf typed).map (·.listed.size) == some 3 &&
              ((pickStatus typed).map fun fields => fields.map (·.text)) ==
                some (#[Ex.label] ++ (exListed "s").listed) },
    { name :=
        "in the ex prompt, text that is no name is typed, the key that moves to the next candidate and the accept key are pressed: the command the first listed name is bound to runs, as the whole name typed and accepted runs it, and not as the typed text alone does, which is no ex name"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-e e p l")
            let (chosen, _) := fedTo typed (presses "C-e t")
            let (ran, _) := fedTo chosen (presses "C-e y")
            let (whole, _) := fedTo driver (exLine "plain")
            let (bare, _) := fedTo typed (presses "C-e y")
            candidatesOf typed == some (exListed "pl") &&
              (candidatesOf typed).map (·.listed) == some #["plain"] &&
              candidatesOf chosen == some (exListed "pl" (some 0)) &&
              minibufferText chosen == some "pl" &&
              promptEcho ran == promptEcho whole &&
              promptEcho ran == greeted [] &&
              closed ran &&
              promptEcho bare == Ex.unknown "pl" },
    { name :=
        "an ex line with an argument matches no name, so the scene lists none, and the accept key runs the line as typed"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say hello there"])
            let (moved, _) := fedTo typed (presses "C-e t")
            let (ran, _) := fedTo moved (presses "C-e y")
            candidatesOf typed == some (exListed "say hello there") &&
              (candidatesOf typed).map (·.listed) == some #[] &&
              ((pickStatus typed).map fun fields => fields.map (·.text)) == some #[Ex.label] &&
              candidatesOf moved == candidatesOf typed &&
              promptEcho ran == greeted hello &&
              closed ran },
    { name :=
        "with the ex names that ship, the letter e lists the name e first, which is the letter, and then e!, autoread, noautoread, reload, compile, compile-command, recompile, next-error and previous-error, and no other; the prompt the name e then asks for a path with, on the scratch buffer, which has no file, has no candidates"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-e e e")
            let (opening, _) := fedTo typed (presses "C-e t C-e y")
            candidatesOf typed == some (exListed "e" none Ex.bindings) &&
              (candidatesOf typed).map (·.listed) ==
                some
                  #["e", "e!", "autoread", "noautoread", "reload", "compile", "compile-command",
                    "recompile", "next-error", "previous-error"] &&
              opening.loop.state.prompt.map (·.label) == some Files.openPrompt &&
              candidatesOf opening == some {} }]

/-- The commands compiled code registers for files, the minibuffer and the ex
line, each under its name, and `undo` and `redo`, which move one step of the
history of the buffer of the window they are called with. -/
def reloadCommands : List (String × Dispatched) :=
  let compiled : List (String × Dispatched) :=
    (Ex.commands ++ Minibuffer.commands ++ Files.commands ++ Buffers.commands).toList.filterMap
      fun (registration : Config.Registration) =>
      match registration.action with
      | .call run =>
        let dispatched : Dispatched := fun call => do
          run call
          return none
        some (registration.name, dispatched)
      | _ => none
  compiled ++
    [("undo", fun call => do
        discard <| call.target.window.buffer.undo
        return none),
      ("redo", fun call => do
        discard <| call.target.window.buffer.redo
        return none),
      ("type-x", fun call => do
        Loop.insert call.target "x"
        return none)]

/-- A driver of the reload checks: the commands of `reloadCommands`, every job
compiled code registers for files (`Files.jobs`), the ex names that ship, and
the files of the file command checks. `C-o n` opens `note.txt`, `C-o r` runs
the reload command, `C-o R` the forced reload, `C-o u` undoes and `C-o U`
redoes; `C-e e` opens the ex line and `C-e y` accepts it. -/
def reloadDriver : Option TestDriver :=
  let keys : Loop.Keys TestScheme.scheme :=
    {
      dispatchKeys
        [("C-o n", opens (inFiles "note.txt")), ("C-o l", opens (inFiles "lf.txt")),
          ("C-o x", invoke "type-x"), ("C-o r", invoke Files.reloadName),
          ("C-o R", { command := Files.reloadName, arguments := [.bool true] }),
          ("C-o u", invoke "undo"), ("C-o U", invoke "redo"), ("C-e e", invoke Ex.name),
          ("C-e y", invoke Minibuffer.acceptName)]
        reloadCommands with
      registered :=
        { ex := fun name => Ex.bindings.findRev? (·.name == name)
          exNames := exNamesOf Ex.bindings } }
  (Loop.Driver.over keys (fun name => (Files.jobs.find? (·.name == name)).map (·.work))
        (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

/-- The text another program writes over `note.txt` in the reload checks:
a new first line before what was there. -/
def reloadedText : String :=
  "a new first line\n" ++ FileCases.noteText

/-- `reloadedText` as the file's bytes. -/
def reloadedBytes : ByteArray :=
  "a new first line\n".toUTF8 ++ FileCases.noteBytes

/-- The id of the job of `driver` started under `name` and not yet
delivered, the latest if there are several. -/
def pendingOf (driver : TestDriver) (name : String) : Option Nat :=
  ((driver.pending.filter (·.name == name)).back?).map (·.id)

/-- Finishes the job of `driver` started under `name` and not yet delivered;
`driver` as it was when there is none. -/
def finishNamed (driver : TestDriver) (name : String) : TestDriver :=
  match pendingOf driver name with
  | some id => (driver.finish id).1
  | none => driver

/-- `reloadDriver` with `note.txt` open in view 0, its load finished, and
then `note.txt` rewritten by another program with `reloadedBytes`. -/
def noteRewritten : Option TestDriver :=
  reloadDriver.map fun driver =>
    rewritten (finishNamed (fedTo driver (presses "C-o n")).1 Files.loadJob) (inFiles "note.txt")
      reloadedBytes

/-- Whether some piece of the whole text of the buffer `driver`'s view 0
shows was written by an edit of origin `origin`. -/
def tracedTo (driver : TestDriver) (origin : Origin) : Bool :=
  match showing driver with
  | none => false
  | some shown =>
    match shown.text with
    | none => false
    | some text =>
      match ((shown.buffer.text.trace 0 text.utf8ByteSize).runModel driver.model.texts).1 with
      | .ok pieces =>
        pieces.any fun piece =>
          match piece.author with
          | .entry _ by_ => by_ == origin
          | .earlier _ => false
      | .error _ => false

/-- The checks of reloading a buffer from its file (`Files.reload`,
`Files.reloaded`, `Editor/Files.lean`), on the loop's driver over the
editor's models and the model of files, with the commands and the jobs
compiled code registers. -/
def fileReloadChecks : List Check :=
  let textOf (driver : TestDriver) : Option String := (showing driver).bind (·.text)
  [{  name :=
        "one undo after a reload is the text from before it: the reload shows the file's new text, not modified, as one step over the opened root traced to the disk origin, and one undo brings the old text back, modified"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (asked, _) := fedTo rewritten (presses "C-o r")
            let reloaded := finishNamed asked Files.reloadJob
            let (undone, _) := fedTo reloaded (presses "C-o u")
            (pendingOf asked Files.reloadJob).isSome && textOf reloaded == some reloadedText &&
              statusOf reloaded == some (named "note.txt") &&
              (showing reloaded).map (·.buffer.history.nodes.size) == some 2 &&
              tracedTo reloaded Origin.disk &&
              (heldFile reloaded).map (·.stamp) == stampOf reloaded (inFiles "note.txt") &&
              textOf undone == some FileCases.noteText &&
              statusOf undone == some (namedModified "note.txt") },
    { name :=
        "a reload of a buffer with unsaved edits changes nothing and says why: no reload job is started, the text is the edited text, and the echo area names :e!; edits made while the file loaded refuse it the same way when it is delivered"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (edited, _) := fedTo rewritten [.commit "x"]
            let (refused, _) := fedTo edited (presses "C-o r")
            let (asked, _) := fedTo rewritten (presses "C-o r")
            let (late, _) := fedTo asked [.commit "x"]
            let lateRefused := finishNamed late Files.reloadJob
            (pendingOf refused Files.reloadJob).isNone &&
              textOf refused == some ("x" ++ FileCases.noteText) &&
              echoOf refused == some (Files.notReloading "note.txt") &&
              textOf lateRefused == some ("x" ++ FileCases.noteText) &&
              echoOf lateRefused == some (Files.notReloading "note.txt") &&
              (pendingOf lateRefused Files.reloadJob).isNone },
    { name :=
        "a forced reload takes the file's text as one step: after it the buffer is not modified, one undo brings the edited text back, modified, and one redo the file's text again; the ex line e! does the same"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (edited, _) := fedTo rewritten [.commit "x"]
            let forced := finishNamed (fedTo edited (presses "C-o R")).1 Files.reloadJob
            let (undone, _) := fedTo forced (presses "C-o u")
            let (redone, _) := fedTo undone (presses "C-o U")
            let byEx := finishNamed (fedTo edited (exLine "e!")).1 Files.reloadJob
            textOf forced == some reloadedText && statusOf forced == some (named "note.txt") &&
              textOf undone == some ("x" ++ FileCases.noteText) &&
              statusOf undone == some (namedModified "note.txt") &&
              textOf redone == some reloadedText &&
              textOf byEx == some reloadedText &&
              (showing byEx).map (·.buffer.isModified) == some false },
    { name :=
        "a forced reload whose text moves while it loads applies nothing and starts one more reload, which reloads; if the text moves again the echo area says it was overtaken and the edited text stays"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (asked, _) := fedTo rewritten (presses "C-o R")
            let (moved, _) := fedTo asked [.commit "x"]
            let retried := finishNamed moved Files.reloadJob
            let settled := finishNamed retried Files.reloadJob
            let (movedAgain, _) := fedTo retried [.commit "y"]
            let overtaken := finishNamed movedAgain Files.reloadJob
            textOf retried == textOf moved && (pendingOf retried Files.reloadJob).isSome &&
              pendingOf retried Files.reloadJob != pendingOf moved Files.reloadJob &&
              textOf settled == some reloadedText &&
              echoOf overtaken == some (Files.reloadOvertaken (inFiles "note.txt")) &&
              textOf overtaken == textOf movedAgain &&
              (pendingOf overtaken Files.reloadJob).isNone },
    { name :=
        "the ex line e with no argument reloads the window's buffer, and on the scratch buffer, which has no file, still asks for a path; a reload of a buffer with no file says so"
      run :=
        pure <|
          match noteRewritten, reloadDriver with
          | some rewritten, some fresh =>
            let byEx := finishNamed (fedTo rewritten (exLine "e")).1 Files.reloadJob
            let (asking, _) := fedTo fresh (exLine "e")
            let (noFile, _) := fedTo fresh (presses "C-o r")
            textOf byEx == some reloadedText &&
              asking.loop.state.prompt.map (·.label) == some Files.openPrompt &&
              echoOf noFile == some (Files.noReloadFile "scratch") &&
              (pendingOf noFile Files.reloadJob).isNone
          | _, _ => false }]

/-- The mode line's field that says a buffer's file changed on disk: the
`changed` segment's (`ModeLine.changed`). -/
def changedField : StatusField :=
  ModeLine.field ModeLine.changedMark ModeLine.changedFace

/-- `driver` once the file at `path` is gone. -/
def removed (driver : TestDriver) (path : System.FilePath) : TestDriver :=
  { driver with
    jobs :=
      { driver.jobs with
        files :=
          { driver.jobs.files with files := driver.jobs.files.files.filter (·.path != path) } } }

/-- `driver` after the frame lost the keyboard focus and gained it again, and
the check that started finished. -/
def focusChecked (driver : TestDriver) : TestDriver :=
  finishNamed (fedTo driver [.focus false, .focus true]).1 Files.checkJob

/-- The checks of the staleness check (`Files.checkWork`, `Loop.fileJobs`,
`Editor/Loop.lean`, "Files that changed on disk"), with auto-reload off, on
the loop's driver over the editor's models and the model of files, with the
commands and the jobs compiled code registers. -/
def stalenessChecks : List Check :=
  let textOf (driver : TestDriver) : Option String := (showing driver).bind (·.text)
  let note := inFiles "note.txt"
  [{  name :=
        "criterion 5: the first edit to a buffer whose file changed is refused and the next lands: after a check started by the focus coming back, the first edit leaves the text, says the file changed and names :e, with no modified field, and the second edit lands"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let checked := focusChecked rewritten
            let (refused, _) := fedTo checked (presses "C-o x")
            let (landed, _) := fedTo refused (presses "C-o x")
            textOf refused == some FileCases.noteText &&
              echoOf refused == some (Files.changedOnDisk note) &&
              statusOf refused == some (named "note.txt" ++ #[changedField]) &&
              textOf landed == some ("x" ++ FileCases.noteText) &&
              statusOf landed == some (namedModified "note.txt" ++ #[changedField]) },
    { name :=
        "a committed text after a change on disk is dropped the same way, and the next commit lands"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (refused, _) := fedTo (focusChecked rewritten) [.commit "a"]
            let (landed, _) := fedTo refused [.commit "b"]
            textOf refused == some FileCases.noteText &&
              echoOf refused == some (Files.changedOnDisk note) &&
              textOf landed == some ("b" ++ FileCases.noteText) },
    { name :=
        "the first edit of an unmodified file buffer starts a check: the edit lands, and once the check is finished the buffer is marked and the echo area gives both resolutions"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (edited, _) := fedTo rewritten (presses "C-o x")
            let checked := finishNamed edited Files.checkJob
            textOf edited == some ("x" ++ FileCases.noteText) &&
              (pendingOf edited Files.checkJob).isSome &&
              statusOf checked == some (namedModified "note.txt" ++ #[changedField]) &&
              echoOf checked == some (Files.changedUnderEdits note) },
    { name :=
        "a file that is gone is marked: the first edit is refused saying :w! writes it again, and the next lands"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let checked := focusChecked (removed rewritten note)
            let (refused, _) := fedTo checked (presses "C-o x")
            let (landed, _) := fedTo refused (presses "C-o x")
            ((heldFile checked).bind (·.changed)).map (·.found) == some none &&
              echoOf refused == some (Files.goneFromDisk note) &&
              textOf refused == some FileCases.noteText &&
              textOf landed == some ("x" ++ FileCases.noteText) },
    { name :=
        "criterion 6: switching to a buffer whose file changed marks its status line and leaves its text; switching to one whose file did not change adds no field; and the focus coming back marks every changed buffer"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (both, _) := fedTo rewritten (presses "C-o l")
            let both := finishNamed both Files.loadJob
            let (switched, _) := fedTo both (exLine "b note.txt")
            let switched := finishNamed switched Files.checkJob
            let (back, _) := fedTo switched (exLine "b lf.txt")
            let back := finishNamed back Files.checkJob
            let focused := focusChecked both
            let noteOf (driver : TestDriver) : Option Bool :=
              (driver.loop.state.buffer? ⟨1⟩).bind (·.file.map (·.changed.isSome))
            let lfOf (driver : TestDriver) : Option Bool :=
              (driver.loop.state.buffer? ⟨2⟩).bind (·.file.map (·.changed.isSome))
            (showing switched).map (·.buffer.name) == some "note.txt" &&
              statusOf switched == some (named "note.txt" ++ #[changedField]) &&
              textOf switched == some FileCases.noteText &&
              statusOf back == some (named "lf.txt") &&
              noteOf focused == some true &&
              lfOf focused == some false },
    { name :=
        "with no check job registered nothing is checked: the focus coming back and a first edit start nothing"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let rewritten := rewritten opened (inFiles "note.txt") reloadedBytes
            let (stepped, steps) := fedTo rewritten [.focus false, .focus true, .commit "x"]
            (steps.all fun step => (step.map (·.starts.isEmpty)).getD false) &&
              stepped.pending.isEmpty },
    { name :=
        "the save criterion, with no check run: a save of a buffer whose file changed on disk writes nothing and says so, both with no check job registered and with the check the first edit started still unfinished; the file keeps the other program's bytes"
      run :=
        pure <|
          match noteOpen, noteRewritten with
          | some unchecked, some behind =>
            -- No check job is registered here: the first edit starts none.
            let changed := rewritten unchecked note reloadedBytes
            let (saving, _) := fedTo changed ([.commit "x"] ++ presses "C-o w")
            let refused := finishNamed saving Files.saveJob
            -- The check the first edit starts is left unfinished.
            let (pending, _) := fedTo behind [.commit "x"]
            let (asked, _) := fedTo pending (exLine "w")
            let held := finishNamed asked Files.saveJob
            (pendingOf saving Files.checkJob).isNone && (pendingOf saving Files.saveJob).isSome &&
              bytesOf refused note == some reloadedBytes &&
              echoOf refused == some (Files.notSaved note (.changed (stampOf changed note))) &&
              (pendingOf pending Files.checkJob).isSome &&
              (pendingOf held Files.checkJob).isSome &&
              (heldFile held).bind (·.changed) == none &&
              (pendingOf asked Files.saveJob).isSome &&
              bytesOf held note == some reloadedBytes &&
              echoOf held == some (Files.notSaved note (.changed (stampOf behind note))) &&
              textOf held == some ("x" ++ FileCases.noteText)
          | _, _ => false },
    { name :=
        "the mark's state requests: a result for another stamp changes nothing, one for the buffer's stamp marks it, one that finds that stamp clears it, telling sets told, and a save that wrote the file clears it"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let state := rewritten.loop.state
            match (heldFile rewritten) with
            | none => false
            | some file =>
              let other : File.Stamp := { file.stamp with size := file.stamp.size + 1 }
              let changedOf (state : EditorState) :=
                (state.buffer? ⟨1⟩).bind (·.file.bind (·.changed))
              let (_, stale) := state.markChanged ⟨1⟩ other (some other) false
              let (_, marked) := state.markChanged ⟨1⟩ file.stamp (some other) false
              let (_, cleared) := marked.markChanged ⟨1⟩ file.stamp (some file.stamp) false
              let (_, told) := marked.tellChanged ⟨1⟩
              let (_, began) := told.beginSave ⟨1⟩ ⟨0⟩ ⟨0⟩
              let (_, saved) := began.endSave ⟨1⟩ ⟨0⟩ (some other)
              let text := ((state.buffer? ⟨1⟩).map (·.text)).getD ⟨0⟩
              changedOf stale == none &&
                changedOf marked == some { found := some other, told := false } &&
                changedOf cleared == none &&
                changedOf told == some { found := some other, told := true } &&
                (marked.untold? text).isSome &&
                (told.untold? text).isNone &&
                changedOf saved == none }]

/-- `reloadDriver` whose watches may be made in `fileRoot`, with `note.txt`
open in view 0 and its load finished. -/
def watchedNote : Option TestDriver :=
  reloadDriver.map fun driver =>
    let driver :=
      { driver with
        jobs :=
          { driver.jobs with
            fileWatches := { driver.jobs.fileWatches with directories := #[fileRoot] } } }
    finishNamed (fedTo driver (presses "C-o n")).1 Files.loadJob

/-- The starts every step of `steps` handed back, by name. -/
def startNames (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array String :=
  steps.flatMap fun step => ((step.map (·.starts)).getD #[]).map (·.name)

/-- The checks of auto-reload (`Editor/Loop.lean`, "Auto-reload"), on the
loop's driver over the editor's models, the model of files and the model of
watches, whose waiting jobs it holds parked (`Loop.Driver.touch`). -/
def autoReloadChecks : List Check :=
  let textOf (driver : TestDriver) : Option String := (showing driver).bind (·.text)
  let note := inFiles "note.txt"
  [{  name :=
        "criterion 7: with auto-reload off no file buffer has a watch open: through opening two files, switching, the focus going and coming, an edit, a reload, closing one and a change on disk, no follow job is started, none is parked, and the watch model started none; with autoread two are open, bd ends one and noautoread the other"
      run :=
        pure <|
          match watchedNote with
          | none => false
          | some opened =>
            let (two, s1) := fedTo opened (presses "C-o l")
            let two := finishNamed two Files.loadJob
            let (switched, s2) := fedTo two (exLine "b note.txt")
            let (focused, s3) :=
              fedTo (finishNamed switched Files.checkJob) [.focus false, .focus true]
            let (edited, s4) := fedTo (finishNamed focused Files.checkJob) (presses "C-o x")
            let (reloading, s5) := fedTo (finishNamed edited Files.checkJob) (presses "C-o R")
            let (closed, s6) := fedTo (finishNamed reloading Files.reloadJob) (exLine "bd lf.txt")
            let touched := (rewritten closed note reloadedBytes).touch #[(note, .written)]
            let steps := s1 ++ s2 ++ s3 ++ s4 ++ s5 ++ s6
            let (on, _) := fedTo two (exLine "autoread")
            let (one, _) := fedTo on (exLine "bd lf.txt")
            let (off, _) := fedTo one (exLine "noautoread")
            !(startNames steps).contains Files.followJob &&
              [two, switched, focused, edited, reloading, closed, touched].all
                (fun driver =>
                  driver.openWatches == 0 && driver.jobs.fileWatches.next == 1 &&
                    driver.jobs.fileWatches.ended.isEmpty) &&
              on.openWatches == 2 &&
              one.openWatches == 1 &&
              off.openWatches == 0 &&
              off.jobs.fileWatches.ended.size == 2 },
    { name :=
        "criterion 8: with auto-reload on, an injected change shows the file's new text: one watch is parked, the change resumes it, its follow finishes and reloads, and the buffer then holds the new text with no modified or changed field, and a watch parked again"
      run :=
        pure <|
          match watchedNote with
          | none => false
          | some opened =>
            let (on, _) := fedTo opened (exLine "autoread")
            let changed := (rewritten on note reloadedBytes).touch #[(note, .written)]
            let followed := finishNamed changed Files.followJob
            let reloaded := finishNamed followed Files.reloadJob
            -- After the reload the follow is on the new stamp: a later
            -- change to the buffer, now edited, marks it.
            let (edited, _) := fedTo reloaded (presses "C-o x")
            let edited := finishNamed edited Files.checkJob
            let again := rewritten edited note ("again\n".toUTF8 ++ reloadedBytes)
            let marked := finishNamed (again.touch #[(note, .written)]) Files.followJob
            on.openWatches == 1 && (pendingOf changed Files.followJob).isSome &&
              (pendingOf followed Files.reloadJob).isSome &&
              textOf reloaded == some reloadedText &&
              statusOf reloaded == some (named "note.txt") &&
              reloaded.openWatches == 1 &&
              statusOf marked == some (namedModified "note.txt" ++ #[changedField]) &&
              marked.openWatches == 1 },
    { name :=
        "a deleted file is marked and waited on: no reload, the text kept, the changed field with nothing found, one watch parked and a further step starts no follow; the file put back is reloaded"
      run :=
        pure <|
          match watchedNote with
          | none => false
          | some opened =>
            let (on, _) := fedTo opened (exLine "autoread")
            let gone := finishNamed ((removed on note).touch #[(note, .removed)]) Files.followJob
            let (later, steps) := fedTo gone [.preedit ""]
            let back :=
              finishNamed ((rewritten later note reloadedBytes).touch #[(note, .created)])
                Files.followJob
            let reloaded := finishNamed back Files.reloadJob
            (pendingOf gone Files.reloadJob).isNone && textOf gone == some FileCases.noteText &&
              statusOf gone == some (named "note.txt" ++ #[changedField]) &&
              ((heldFile gone).bind (·.changed)).map (·.found) == some none &&
              gone.openWatches == 1 &&
              !(startNames steps).contains Files.followJob &&
              textOf reloaded == some reloadedText &&
              statusOf reloaded == some (named "note.txt") },
    { name :=
        "criterion 10 on the model: a modified buffer keeps its text and is marked, the follow armed again on what was found, so a touch with no further change starts nothing; two changes leave one parked watch, the mark on the second stamp"
      run :=
        pure <|
          match watchedNote with
          | none => false
          | some opened =>
            let (on, _) := fedTo opened (exLine "autoread")
            let (edited, _) := fedTo on (presses "C-o x")
            let edited := finishNamed edited Files.checkJob
            let first := rewritten edited note reloadedBytes
            let marked := finishNamed (first.touch #[(note, .written)]) Files.followJob
            let quiet := marked.touch #[(note, .written)]
            let second := rewritten quiet note ("again\n".toUTF8 ++ reloadedBytes)
            let twice := finishNamed (second.touch #[(note, .written)]) Files.followJob
            let (later, steps) := fedTo twice [.preedit ""]
            textOf marked == some ("x" ++ FileCases.noteText) &&
              (pendingOf marked Files.reloadJob).isNone &&
              statusOf marked == some (namedModified "note.txt" ++ #[changedField]) &&
              (pendingOf quiet Files.followJob).isNone &&
              quiet.openWatches == 1 &&
              ((heldFile twice).bind (·.changed)).map (·.found) == some (stampOf twice note) &&
              twice.openWatches == 1 &&
              (pendingOf twice Files.followJob).isNone &&
              !(startNames steps).contains Files.followJob &&
              later.openWatches == 1 },
    { name :=
        "a refused watch is said in words and says how to retry: the echo area has the refusal's sentence, not its constructor, and that auto-reload is off for the buffer until noautoread then autoread, which starts a follow again"
      run :=
        pure <|
          -- No directory may be watched here, so the follow's watch is
          -- refused.
          match reloadDriver with
          | none => false
          | some fresh =>
            let opened := finishNamed (fedTo fresh (presses "C-o n")).1 Files.loadJob
            let (on, _) := fedTo opened (exLine "autoread")
            let refused := finishNamed on Files.followJob
            let (later, steps) := fedTo refused [.preedit ""]
            let (off, _) := fedTo later (exLine "noautoread")
            let (retried, _) := fedTo off (exLine "autoread")
            let error : FileWatchError := .notFound s!"cannot watch {note}: {fileRoot} is not there"
            (pendingOf on Files.followJob).isSome &&
              echoOf refused == some (Files.notFollowing note error.describe) &&
              (echoOf refused).map (·.endsWith Files.followRetry) == some true &&
              !((echoOf refused).getD "").contains "FileWatchError" &&
              !(startNames steps).contains Files.followJob &&
              (pendingOf retried Files.followJob).isSome },
    { name :=
        "config's setting decides while no command has: under it the next step arms the watches, and noautoread then wins over it"
      run :=
        pure <|
          match watchedNote with
          | none => false
          | some opened =>
            let configured :=
              { opened with
                keys :=
                  { opened.keys with
                    registered := { opened.keys.registered with autoReload := true } } }
            let (armed, _) := fedTo configured [.preedit ""]
            let (off, _) := fedTo armed (exLine "noautoread")
            armed.openWatches == 1 && off.openWatches == 0 }]

end ModelTest
