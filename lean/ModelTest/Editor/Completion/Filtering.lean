import Editor.Api
import Editor.Completion.Candidate
import Editor.Completion.Filtering
import Editor.Completion.Later
import Editor.Job
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Model
import Editor.State
import Editor.Test.Completion
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Listings
import Editor.Test.Loop
import Editor.Test.Prompts
import ModelTest.Check
import ModelTest.Editor.Completion.Later
import ModelTest.Support.Candidates

/-!
# Model tests: `Editor/Completion/Filtering.lean`

The model tests of `Editor/Completion/Filtering.lean`: `filteringChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

namespace FilteringTest

/-- The directory the checks' commands run in. -/
def root : System.FilePath :=
  "/w"

/-- The lister of the checks. -/
def lister : Process.Command :=
  { program := "/usr/bin/git", arguments := #["ls-files"], directory := root }

/-- What the lister writes. -/
def listed : ByteArray :=
  "ab\nxa\nzz\n".toUTF8

/-- A run that exits with `status`, writing `stdout` and `stderr`. -/
def ran (stdout : String) (status : Nat := 0) (stderr : String := "") :
    Except ProcessError Process.Ran :=
  .ok { exit := .code status, stdout := stdout.toUTF8, stderr := stderr.toUTF8 }

/-- The filtering of the checks: the lister, and fzf for `separator`,
delivering at most `limit` records. -/
def filtering (separator : Completion.Filtering.Separator := .newline) (limit : Nat := 200) :
    Completion.Filtering :=
  { lister, filter := Completion.Filtering.fzf root separator, separator, limit }

/-- The order a job of the checks is started with: the source 0 of the
prompt in view 3, at generation 1, for `text`. -/
def order (text : String) : Completion.Order :=
  { view := ⟨3⟩, index := 0, generation := 1, query := { text, view := ⟨0⟩ } }

/-- The job of a source over `filtering`, run on a job model with `scripts`
for the text `text`: how it ended, and the model after it. -/
def answered (filtering : Completion.Filtering) (scripts : Array Process.Script) (text : String) :
    Job.Outcome (EditorM Unit) × JobModel :=
  (Completion.answering (Completion.Filtering.answer fun _ => pure filtering) (order text).arguments
        ()).runModel
    { processes := { scripts } }

/-- What `filtering.found text` answers on a job model with `scripts`: the
error on the left, the records on the right; `none` if the job did not
finish. -/
def matched (filtering : Completion.Filtering) (scripts : Array Process.Script) (text : String) :
    Option (String ⊕ Array String) :=
  match ((filtering.found text).runModel { processes := { scripts } }).1 with
  | .finished (.error message) => some (.inl message)
  | .finished (.ok records) => some (.inr records)
  | _ => none

/-- The batches `model`'s job posted, decoded. -/
def batches (model : JobModel) : Array (Option (ViewId × Nat × Nat × Array Completion.Candidate)) :=
  model.posted.map fun posted =>
    if posted.command == Completion.candidatesCommand then
      Completion.batchOfArguments? posted.arguments
    else none

/-- Whether `reply` is an error that starts with `start`. -/
def failsWith (start : String) : Option (String ⊕ Array String) → Bool
  | some (.inl message) => message.startsWith start
  | _ => false

/-- The filtering the driver's `files` source answers with. -/
def filesFiltering : Completion.Filtering :=
  filtering

/-- The filtering the driver's `missing` source answers with: a filter
with no script, as a program that is not installed is. -/
def missingFiltering : Completion.Filtering :=
  { filtering with filter := { program := "fzf", arguments := #["--missing"], directory := root } }

/-- The scripts the driver's job model has: the lister, and the filter for
the empty text, which prints every record, for `a`, which prints `zz`
though the style does not match it, and for `q`, which matches nothing and
exits 1, as fzf does. -/
def driverScripts : Array Process.Script :=
  #[{ command := lister, reply := .ok { exit := .code 0, stdout := listed, stderr := .empty } },
    { command := filesFiltering.filterFor "", reply := ran "ab\nxa\nzz\n" },
    { command := filesFiltering.filterFor "a", reply := ran "xa\nab\nzz\n" },
    { command := filesFiltering.filterFor "q", reply := ran "" 1 }]

/-- The sources of the driver: `files`, of the category `file`, answered by
the job `filtering-files`, and `missing`, by `filtering-missing`. -/
def filesSource : Completion.Source :=
  Completion.Filtering.source "files" "file" "filtering-files"

/-- The source whose filter is not there. -/
def missingSource : Completion.Source :=
  Completion.Filtering.source "missing" "file" "filtering-missing"

/-- The commands of the driver: `ask-files` and `ask-missing` ask with one
of the sources, and the candidate checks' commands take a batch and insert
what is typed. -/
def commands : List (String × Dispatched) :=
  let asks (source : Completion.Source) : Dispatched := fun _ => do
    discard <| prompt pickLabel pickContinuation "" [.given source]
    return none
  [("ask-files", asks filesSource), ("ask-missing", asks missingSource)] ++ candidateCommands

/-- The jobs of the driver. -/
def jobs (name : String) : Option (List Argument → Work) :=
  match name with
  | "filtering-files" =>
    some (Completion.answering (Completion.Filtering.answer fun _ => pure filesFiltering))
  | "filtering-missing" =>
    some (Completion.answering (Completion.Filtering.answer fun _ => pure missingFiltering))
  | _ => none

/-- A driver whose `C-c f` asks with `files` and `C-c g` with `missing`, its
jobs run on a job model with `driverScripts`, its prompts matched with the
style written for the core's tests (`marking`); `none` if making the state
was refused. -/
def driver : Option TestDriver :=
  (Loop.Driver.over
        {
          dispatchKeys [("C-c f", invoke "ask-files"), ("C-c g", invoke "ask-missing")]
            commands with
          matching := markingMatching }
        jobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { processes := { scripts := driverScripts } } }

/-- The texts listed in the prompt `driver` holds. -/
def listedTexts (driver : TestDriver) : Option (Array String) :=
  (candidatesOf driver).map (·.listed.map (·.text))

end FilteringTest

open FilteringTest in
/-- The checks of a source a command filters
(`Editor/Completion/Filtering.lean`): its job on the job model, with
canned process answers, and the source through the loop on its driver. -/
def filteringChecks : List Check :=
  [{  name :=
        "a filtering source's job runs its lister, then its filter fed the lister's output with the typed text as its last argument, one argument though it holds a space, and posts one batch of the filter's first limit records, in order, and finishes"
      run :=
        pure <|
          let f := filtering (limit := 2)
          let filter := f.filterFor "x; y"
          let (outcome, model) :=
            answered f
              #[{ command := lister,
                  reply := .ok { exit := .code 0, stdout := listed, stderr := .empty } },
                { command := filter, reply := ran "a\nb\nc\n" }]
              "x; y"
          (outcome matches .finished _) && model.processes.started == #[lister, filter] &&
            model.processes.fed == #[(filter, listed)] &&
            filter.arguments == #["--filter", "x; y"] &&
            batches model == #[some (⟨3⟩, 0, 1, offered #["a", "b"])] },
    { name :=
        "with NUL-separated records the filter is fzf --read0 --print0 --filter, fed the lister's NUL-separated output, and its NUL-separated records are delivered"
      run :=
        pure <|
          let f := filtering .nul 2
          let filter := f.filterFor "x"
          let nul (texts : List String) : ByteArray :=
            texts.foldl (fun bytes text => (bytes ++ text.toUTF8).push 0) .empty
          let (_, model) :=
            answered f
              #[{ command := lister
                  reply := .ok { exit := .code 0, stdout := nul ["a b", "c"], stderr := .empty } },
                { command := filter
                  reply :=
                    .ok { exit := .code 0, stdout := nul ["c", "a b", "d"], stderr := .empty } }]
              "x"
          filter.arguments == #["--read0", "--print0", "--filter", "x"] &&
            model.processes.fed == #[(filter, nul ["a b", "c"])] &&
            batches model == #[some (⟨3⟩, 0, 1, offered #["c", "a b"])] },
    { name :=
        "a filter's output past its byte limit is cut to its head: the whole records in it are answered, the last part of one dropped, and the filter is ended"
      run :=
        pure <|
          let f := { filtering with filterBytes := 5 }
          let filter := f.filterFor ""
          let scripts : Array Process.Script :=
            #[{ command := lister,
                reply := .ok { exit := .code 0, stdout := listed, stderr := .empty } },
              { command := filter, reply := ran "aa\nbb\ncc\n" }]
          let (_, model) := answered f scripts ""
          matched f scripts "" == some (.inr #["aa"]) &&
            batches model == #[some (⟨3⟩, 0, 1, offered #["aa"])] &&
            model.processes.killed == #[filter] },
    { name :=
        "records split on the separator: an empty record and one that is not UTF-8 are dropped, and the bytes after the last separator are a record unless the output was cut"
      run :=
        pure <|
          let bytes := ("a\n\n".toUTF8.push 0xFF |>.push 10) ++ "c".toUTF8
          Completion.Filtering.records .newline bytes false == #["a", "c"] &&
            Completion.Filtering.records .newline bytes true == #["a"] &&
            Completion.Filtering.records .nul ("a\nb".toUTF8.push 0) true == #["a\nb"] },
    { name :=
        "a filter exit declared as no matches answers no records and posts one empty batch, which is no failure; with no status declared the same exit fails, naming the filter's program and its status"
      run :=
        pure <|
          let f := filtering
          let scripts : Array Process.Script :=
            #[{ command := lister,
                reply := .ok { exit := .code 0, stdout := listed, stderr := .empty } },
              { command := f.filterFor "q", reply := ran "" 1 }]
          let (outcome, model) := answered f scripts "q"
          matched f scripts "q" == some (.inr #[]) && (outcome matches .finished _) &&
            batches model == #[some (⟨3⟩, 0, 1, #[])] &&
            matched { f with noMatches := [] } scripts "q" ==
              some (.inl "fzf: exited with status 1") },
    { name :=
        "a filter that is not there, or a lister that fails, answers an error naming the program, with the lister's status and the first line of its standard error; the job then posts nothing"
      run :=
        pure <|
          let f := filtering
          let lists : Process.Script :=
            { command := lister,
              reply := .ok { exit := .code 0, stdout := listed, stderr := .empty } }
          let failing : Process.Script :=
            { command := lister, reply := ran "" 128 "fatal: not a git repository\nmore" }
          let (_, model) := answered f #[lists] "x"
          failsWith "fzf: the program or the directory is not there" (matched f #[lists] "x") &&
            matched f #[failing] "x" ==
              some (.inl "/usr/bin/git: exited with status 128: fatal: not a git repository") &&
            model.posted.isEmpty },
    { name :=
        "a lister exit declared as a partial listing still answers: its records are fed to the filter and the filter's are answered; with no status declared, as by default, the same exit fails, naming the lister's program, its status and its standard error"
      run :=
        pure <|
          let f := filtering
          let partly : Process.Script :=
            { command := lister, reply := ran "ab\nxa\nzz\n" 1 "find: ./locked: Permission denied" }
          let scripts : Array Process.Script :=
            #[partly, { command := f.filterFor "a", reply := ran "xa\nab\n" }]
          matched { f with partialListing := [1] } scripts "a" == some (.inr #["xa", "ab"]) &&
            matched { f with partialListing := [2] } scripts "a" ==
              some (.inl "/usr/bin/git: exited with status 1: find: ./locked: Permission denied") &&
            matched f scripts "a" ==
              some (.inl "/usr/bin/git: exited with status 1: find: ./locked: Permission denied") &&
            f.partialListing == [] },
    { name :=
        "a filter that outlives its time limit answers an error naming the filter's program and the time-out, and the job posts nothing"
      run :=
        pure <|
          let f := filtering
          let scripts : Array Process.Script :=
            #[{ command := lister,
                reply := .ok { exit := .code 0, stdout := listed, stderr := .empty } },
              { command := f.filterFor "x", reply := .error (.timedOut f.time) }]
          let (_, model) := answered f scripts "x"
          failsWith "fzf: the run did not end within 10000 ms" (matched f scripts "x") &&
            model.posted.isEmpty },
    { name :=
        "a lister that outlives its time limit answers an error naming the lister's program and the time-out, the filter is never run, and the job posts nothing"
      run :=
        pure <|
          let f := filtering
          let scripts : Array Process.Script :=
            #[{ command := lister, reply := .error (.timedOut f.time) },
              { command := f.filterFor "x", reply := ran "ab\n" }]
          let (_, model) := answered f scripts "x"
          failsWith "/usr/bin/git: the run did not end within 10000 ms" (matched f scripts "x") &&
            model.processes.started == #[lister] &&
            model.posted.isEmpty },
    { name :=
        "through the loop: a new text cancels the source's job and starts the next generation for it after the pause; a batch of the cancelled generation is never listed, and the new one's is listed in the filter's order, none dropped, the style's ranges on those it matches"
      run :=
        pure <|
          match driver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c f")
            match asked.posting[0]?, asked.loop.state.minibufferView? with
            | some first, some view =>
              let (one, _) := asked.posted first.id
              let (typed, steps) := fedTo one (presses "a")
              let stepped := steps.back?.join
              let started :=
                (stepped.bind (·.starts[0]?)).bind fun start =>
                  Completion.Order.ofArguments? start.arguments
              let stale :=
                deliveredBatch typed (Completion.batchArguments view 0 1 (offered #["stale"]))
              match typed.posting[0]? with
              | none => false
              | some second =>
                let (answered, _) := stale.posted second.id
                let marked (text : String) : Array Completion.Span :=
                  if text == "zz" then #[] else markedSpans "a" text
                listedTexts one == some #["ab", "xa", "zz"] &&
                  stepped.map (·.cancels) == some #[Loop.sourceKey view "files"] &&
                  started.map (fun order => (order.query.text, order.generation, order.pause)) ==
                    some ("a", 2, 50) &&
                  !((listedTexts stale).getD #[]).contains "stale" &&
                  listedTexts answered == some #["xa", "ab", "zz"] &&
                  (candidatesOf answered).map (·.listed.map (·.ranges)) ==
                    some (#["xa", "ab", "zz"].map marked) &&
                  !(markedSpans "a" "xa").isEmpty
            | _, _ => false },
    { name :=
        "through the loop: a source whose filter is not there fails, saying the source and the program in the echo area, and lists nothing; one whose filter answers no matches for the typed text lists nothing once its batch arrives, and says nothing"
      run :=
        pure <|
          match driver with
          | none => false
          | some driver =>
            let (missing, _) := fedTo driver (presses "C-c g")
            let failed :=
              match missing.pending[0]? with
              | some job => (missing.finish job.id).1
              | none => missing
            let (asked, _) := fedTo driver (presses "C-c f")
            match asked.posting[0]? with
            | none => false
            | some first =>
              let (one, _) := asked.posted first.id
              let (typed, _) := fedTo one (presses "q")
              match typed.posting[0]? with
              | none => false
              | some second =>
                let (empty, _) := typed.posted second.id
                let done :=
                  match empty.pending.find? (·.id == second.id) with
                  | some job => (empty.finish job.id).1
                  | none => empty
                failed.loop.state.echo.startsWith "missing: fzf: " &&
                  listedTexts failed == some #[] &&
                  listedTexts typed == some #["ab", "xa", "zz"] &&
                  listedTexts empty == some #[] &&
                  listedTexts done == some #[] &&
                  done.loop.state.echo == "" }]

end ModelTest
