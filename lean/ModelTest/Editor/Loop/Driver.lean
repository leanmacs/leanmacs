import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Config.Owner
import Editor.Config.Stores
import Editor.Display.Model
import Editor.Event
import Editor.File.Cases
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Menu
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.SyntaxTree.Model
import Editor.SyntaxTree.Registration
import Editor.SyntaxTree.Registration.Model
import Editor.Test.Driver
import Editor.Test.Jobs
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Prompts
import Editor.Test.States
import Editor.Text
import Editor.Text.Model
import Editor.Watch.Model
import EnvironmentApiTest.Fake
import ModelTest.Check

/-!
# Model tests: `Editor/Loop/Driver.lean`

The model tests of `Editor/Loop/Driver.lean`: `driverChecks`,
`promptLoopChecks`, `echoPromptChecks` and `promptChecks`. `echoPromptChecks`
check `EditorState.openPrompt` through the loop's driver, beside the other
prompt checks. The root module `ModelTest` runs them; its module doc says what
each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- `newDriver` whose jobs reach the directory `fileRoot`, holding the file
`note.txt` with `FileCases.noteBytes`. -/
def fileDriver : Option TestDriver :=
  newDriver.map fun driver =>
    { driver with jobs := { files := fileModelOf #[("note.txt", FileCases.noteBytes)] } }

/-- The checks of jobs started from commands (`Editor/Loop.lean`,
`Editor/Loop/Driver.lean`), on the loop's driver over the editor's models
and the job model: a command starts a job by its name with arguments, and
the job's result comes back as a command the loop delivers. -/
def driverChecks : List Check :=
  let started (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array JobStart :=
    steps.flatMap fun step => (step.map (·.starts)).getD #[]
  let echoOf (driver : TestDriver) : Option String := driver.model.display.scenes.back?.map (·.echo)
  [{  name :=
        "a grammar a job registers on the job model is listed by the syntax tree model once the job has run, before its command is delivered"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let library := "/g/libtree-sitter-ini.so"
            -- The library holds the test grammars, registered as every
            -- test registers them, on the job model as on the syntax tree's.
            let driver :=
              { driver with
                jobs :=
                  {
                    grammars :=
                      { GrammarRegistry.testGrammars with
                        libraries :=
                          some #[(library, .exports #[("tree_sitter_ini", .grammar)])] } } }
            let work : Work :=
              Work.of (fun _ => Grammar.register { library, symbol := "tree_sitter_ini" }) fun _ =>
                makes "registered"
            let started := driver.startWork "register" work
            let tests := GrammarRegistry.testGrammarNames.map (·.1)
            driver.model.syntaxTree.grammars == tests &&
              started.model.syntaxTree.grammars == tests.push "ini" &&
              started.pending.map (·.id) == #[1] &&
              !started.model.texts.contents.contains "registered" },
    { name :=
        "work started outside a step runs on the job model under the next id and is delivered by finish"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let work : Work := Work.of (fun _ => pure "done") makes
            let started := driver.startWork "own" work
            let (delivered, stepped) := started.finish 1
            started.next == 2 &&
              started.pending.map (fun job => (job.id, job.name)) == #[(1, "own")] &&
              !started.model.texts.contents.contains "done" &&
              stepped.isSome &&
              delivered.model.texts.contents.contains "done" &&
              delivered.pending.isEmpty },
    { name :=
        "a command that hands a restart's plan over has it handed back with its step, kept by the driver, and the outbox emptied"
      run :=
        pure <|
          match fileDriver with
          | none => false
          | some driver =>
            let plan : Restart.Plan := { record := "/s/session/handover", handover := default }
            let (handed, stepped) :=
              driver.stepped (driver.loop.deliver driver.handed "job 1 test" (Editor.handOver plan))
            (stepped.toOption.bind (·.handOver)) == some plan && handed.handOver == some plan &&
              handed.loop.state.outbox.handOver.isNone },
    { name :=
        "a step that hands back a spawn has its work run on the job model under the spawn's key, kept under the spawn's label, and its command delivered at finish; a second spawn of the key ends the first undelivered, and a cancel of the key ends the second undelivered"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let candidates := #["wq", "edit", "w"]
            let spawn (pattern : String) : Loop.Spawn :=
              { key := "m", label := "matching"
                work := fun _ => do
                  let ranked ← Job.embedFuzzy (Fuzzy.rank pattern candidates)
                  return discard <| (⟨0⟩ : ViewId).insertAtSelections (toString ranked) }
            let handed (driver : TestDriver) (spawns : Array Loop.Spawn)
              (cancels : Array String := #[]) : TestDriver :=
              driver.took { loop := driver.loop, next := .continue, spawns, cancels } driver.model
            let one := handed driver #[spawn "w"]
            let (delivered, stepped) := one.finish 1
            let two := handed one #[spawn "e"]
            let three := handed two #[] #["m"]
            one.pending.map (fun job => (job.id, job.name, job.key)) ==
                #[(1, "matching", some "m")] &&
              stepped.isSome &&
              driverText delivered == some (toString (FuzzyModel.rank "w" candidates)) &&
              delivered.pending.isEmpty &&
              two.pending.map (fun job => (job.id, job.key)) == #[(2, some "m")] &&
              three.pending.isEmpty &&
              (three.finish 2).2.isNone },
    { name :=
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
            let lookup : Process.Command := { program := "/opt/mise", directory := "/p/d" }
            let driver :=
              { driver with
                jobs :=
                  { environments :=
                      {
                        sources :=
                          { directories := #[EnvironmentApiTest.fakeSource "mise" "/opt/mise"] } }
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
            built.loop.state.echo ==
                Process.failureMessage (.directory "/p/d" "mise") (.exited 1 "") &&
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
              asked.loop.state.outbox.starts.isEmpty &&
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
            started steps == #[] && failed.pending.isEmpty &&
              failed.loop.state.outbox.starts.isEmpty &&
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
              cancelled.loop.state.outbox.cancels.isEmpty &&
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
              refused.loop.state.outbox.cancels.isEmpty &&
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
              finished.model.texts.contents == #[""] },
    { name :=
        "with a key hint delay of 500, the hints after a prefix are not shown until 500 ms have passed and are shown then; a sequence completed before the delay shows none after it; and a delay that fires for another generation changes nothing"
      run :=
        pure <|
          match
            (Loop.Driver.over (hintedKeys 500) (fun _ => none) (EditorState.initial ⟨640, 480⟩)
                editorModel).toOption with
          | none => false
          | some driver =>
            let lastHints (driver : TestDriver) : Option (Array KeyHint) :=
              driver.model.display.scenes.back?.map (·.keyHints)
            let (prefixed, _) := fedTo driver (presses "C-x")
            let early := prefixed.pass 499
            let due := early.pass 1
            let (completed, _) := fedTo prefixed (presses "C-s")
            let after := completed.pass 500
            let (stale, _) := prefixed.stepped (prefixed.loop.keyHintsDue prefixed.handed 7)
            prefixed.hinted == some (1, 500) && lastHints early == some #[] &&
              lastHints due == some afterPrefix &&
              due.hinted == none &&
              completed.hinted == none &&
              lastHints after == some #[] &&
              after.model.display.scenes.size == completed.model.display.scenes.size &&
              lastHints stale == some #[] &&
              stale.loop.state.keyHints == prefixed.loop.state.keyHints },
    { name :=
        "a pass past a key hint delay and pauses on either side of it fires them in the order of their deadlines: the pause due before the hints and the pause due at the same reading first, their scenes with no hints, then the hints, then the pause due after them, its scene with the hints"
      run :=
        pure <|
          match
            (Loop.Driver.over (hintedKeys 500) (fun _ => none) (EditorState.initial ⟨640, 480⟩)
                editorModel).toOption with
          | none => false
          | some driver =>
            let (prefixed, _) := fedTo driver (presses "C-x")
            -- Pauses for the focused view due at 300, at the hints' 500 and
            -- at 700, as a typed key arms them (`Loop.Stepped.pause`).
            let armed : TestDriver :=
              { prefixed with armed := #[(⟨0⟩, 300, 300), (⟨0⟩, 500, 500), (⟨0⟩, 700, 700)] }
            let passed := armed.pass 700
            let before := armed.model.display.scenes.size
            let scenes := passed.model.display.scenes
            prefixed.hinted == some (1, 500) && passed.armed.isEmpty && passed.hinted == none &&
              (scenes.extract before scenes.size).map (·.keyHints) ==
                #[#[], #[], afterPrefix, afterPrefix] },
    { name :=
        "a journal order the file model refuses is kept, its path and why, and the orders after it are still handed"
      run :=
        pure <|
          match fileDriver with
          | none => false
          | some driver =>
            let missing := fileRoot / "missing" / "log"
            let kept := fileRoot / "kept"
            let after :=
              driver.journaled
                #[{ request := .append missing "x".toUTF8 }, { request := .append kept "y".toUTF8 }]
            after.journalFailures == #[s!"{missing}: {FileError.notFound.describe}"] &&
              (after.jobs.files.file? kept).map (·.bytes.toList) == some "y".toUTF8.toList }]

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
      state.outbox.answered.isEmpty &&
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
              stopped.loop.state.outbox.answered.isEmpty &&
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

/-- The checks of prompts on the loop's driver: the loop's part and its
host's (`promptLoopChecks`), then the echo an open prompt clears
(`echoPromptChecks`). The checks of the minibuffer's commands and its mode
(`MinibufferTest.promptModeChecks`) are the package `minibuffer`'s own
(`packages/minibuffer/`). -/
def promptChecks : List Check :=
  promptLoopChecks ++ echoPromptChecks

end ModelTest
