import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Ex.Line
import Editor.File.Model
import Editor.FileWatch.Model
import Editor.InputScheme.Test
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Model
import Editor.Language
import Editor.Loop.Driver
import Editor.Mode
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Scene
import Editor.State
import Editor.State.Request
import ModelTest.Views

/-!
# Model tests: the workspace

The checks of file watching, the process environment, the workspace's data,
git and state, and the mode marker.

Its lists of checks: `fileWatchModelChecks`, `fileWatchRunnerChecks`,
`processEnvironmentChecks`, `environmentLookupChecks`,
`workspaceDataChecks`, `workspaceGitChecks`, `workspaceStateChecks`,
`workspaceChecks`, `modeMarkerChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- What the watch model answers a start of `target` coalesced as
`coalescing`, made at `now`. -/
def watchStart (model : FileWatchModel) (target : FileWatch.Target)
    (coalescing : FileWatch.Coalescing) (now : Nat := 0) :
    Except FileWatchError FileWatch.Id × FileWatchModel × Nat :=
  model.handle now none (.start target coalescing)

/-- What the watch model answers a `next` of `watch` made at `now` by a job
cancelled at `cancelAt`. -/
def watchNext (model : FileWatchModel) (watch : Nat) (now : Nat := 0)
    (cancelAt : Option Nat := none) :
    Except FileWatchError (Array FileWatch.Change) × FileWatchModel × Nat :=
  model.handle now cancelAt (.next ⟨watch⟩)

/-- The change of `path` with `kinds`. -/
def changeOf (path : System.FilePath) (kinds : List FileWatch.Kind) : FileWatch.Change :=
  { path, kinds := kinds.foldl FileWatch.Kinds.add {} }

/-- A model with `watchRoot` and its subdirectory `sub` there. -/
def watchModel : FileWatchModel :=
  { directories := #[watchRoot, watchRoot / "sub"] }

/-- No window, and room for every check's paths. -/
def atOnce : FileWatch.Coalescing :=
  { window := 0, bound := 100 }

/-- The checks of the watch model (`Editor/FileWatch/Model.lean`), exactly:
the kinds of a change as an exact set, the window moving the clock, the
bound, the routing of each kind of target, the order of the refusals, and a
watch ended with its job. -/
def fileWatchModelChecks : List Check :=
  [{  name :=
        "the watch model delivers one change a path with exactly the kinds recorded there, in the order of each path's first change"
      run := do
        let (_, model, _) := watchStart watchModel (.directory watchRoot false) atOnce
        let model :=
          model.touch
            #[(watchRoot / "b", .written), (watchRoot / "a", .created), (watchRoot / "b", .removed),
              (watchRoot / "a", .written)]
            0
        let (reply, _, _) := watchNext model 1
        return reply ==
            .ok
              #[changeOf (watchRoot / "b") [.written, .removed],
                changeOf (watchRoot / "a") [.created, .written]] },
    { name :=
        "the watch model answers a next at the window from the first change, moving the clock there, or now if that is later"
      run := do
        let window : FileWatch.Coalescing := { window := 300, bound := 10 }
        let (_, model, _) := watchStart watchModel (.file (watchRoot / "f")) window
        let model :=
          (model.touch #[(watchRoot / "f", .written)] 100).touch #[(watchRoot / "f", .written)] 350
        let (early, _, earlyNow) := watchNext model 1 150
        let (late, _, lateNow) := watchNext model 1 500
        let written := Except.ok #[changeOf (watchRoot / "f") [.written]]
        return early == written && earlyNow == 400 && late == written && lateNow == 500 },
    { name :=
        "the watch model collapses a delivery past its bound to missed of the watch's own path, keeps it collapsed until it is taken, then records anew"
      run := do
        let bound : FileWatch.Coalescing := { window := 0, bound := 2 }
        let (_, model, _) := watchStart watchModel (.directory watchRoot false) bound
        let model :=
          model.touch
            #[(watchRoot / "a", .written), (watchRoot / "b", .written), (watchRoot / "c", .written),
              (watchRoot / "a", .removed)]
            0
        let (collapsed, model, _) := watchNext model 1
        let (after, _, _) := watchNext (model.touch #[(watchRoot / "d", .created)] 0) 1
        return collapsed == .ok #[changeOf watchRoot [.missed]] &&
            after == .ok #[changeOf (watchRoot / "d") [.created]] },
    { name :=
        "the watch model's file watch keeps its file and drops its siblings; an entries watch keeps what is directly inside, and a recursive one what is deeper too"
      run := do
        let (_, model, _) := watchStart watchModel (.file (watchRoot / "f")) atOnce
        let (_, model, _) := watchStart model (.directory watchRoot false) atOnce
        let (_, model, _) := watchStart model (.directory watchRoot true) atOnce
        let model :=
          model.touch
            #[(watchRoot / "g", .written), (watchRoot / "sub" / "x", .written),
              (watchRoot / "f", .written), ("/elsewhere/f", .written)]
            0
        let (file, model, _) := watchNext model 1
        let (entries, model, _) := watchNext model 2
        let (tree, _, _) := watchNext model 3
        return file == .ok #[changeOf (watchRoot / "f") [.written]] &&
            entries ==
              .ok #[changeOf (watchRoot / "g") [.written], changeOf (watchRoot / "f") [.written]] &&
            tree ==
              .ok
                #[changeOf (watchRoot / "g") [.written],
                  changeOf (watchRoot / "sub" / "x") [.written],
                  changeOf (watchRoot / "f") [.written]] },
    { name :=
        "the watch model refuses a relative path or a parent component as not absolute, then a bound of 0 as failed, then a missing directory as not found, and starts none of them"
      run := do
        let zero : FileWatch.Coalescing := { window := 0, bound := 0 }
        let isNotAbsolute : Except FileWatchError FileWatch.Id → Bool
          | .error (.notAbsolute _) => true
          | _ => false
        let isFailed : Except FileWatchError FileWatch.Id → Bool
          | .error (.failed _) => true
          | _ => false
        let isNotFound : Except FileWatchError FileWatch.Id → Bool
          | .error (.notFound _) => true
          | _ => false
        let (relative, a, _) := watchStart watchModel (.file "watched/f") zero
        let (parent, b, _) := watchStart watchModel (.directory "/watched/../watched" false) atOnce
        let (bound, c, _) := watchStart watchModel (.file "/nowhere/f") zero
        let (missing, d, _) := watchStart watchModel (.directory "/nowhere" true) atOnce
        let (fileMissing, e, _) := watchStart watchModel (.file "/nowhere/f") atOnce
        -- The library refuses a file with no directory as not found too.
        let (noDirectory, f, _) := watchStart watchModel (.file "/") atOnce
        return isNotAbsolute relative && isNotAbsolute parent && isFailed bound &&
            isNotFound missing &&
            isNotFound fileMissing &&
            isNotFound noDirectory &&
            [a, b, c, d, e, f].all (·.watches.isEmpty) },
    { name :=
        "the watch model's next with nothing recorded fails, or is the cancel at its instant, and a next of a watch it does not have is noSuchWatch"
      run := do
        let (_, model, _) := watchStart watchModel (.file (watchRoot / "f")) atOnce
        let (nothing, _, nothingNow) := watchNext model 1 5
        let (atCancel, _, cancelledNow) := watchNext model 1 5 (some 40)
        let (unknown, _, _) := watchNext model 9
        let isFailed : Except FileWatchError (Array FileWatch.Change) → Bool
          | .error (.failed _) => true
          | _ => false
        return isFailed nothing && nothingNow == 5 && isFailed atCancel && cancelledNow == 40 &&
            unknown == .error .noSuchWatch },
    { name :=
        "in the job model a command a job runs changes what its watch sees, the delivery comes at the window, and the watch ends with its job, finished, failed or cancelled"
      run := do
        let command := JobContract.sh watchRoot "printf x >> f"
        let model : JobModel :=
          { processes :=
              {
                scripts :=
                  #[{ command
                      reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty }
                      takes := 2 }] }
            fileWatches :=
              { watchModel with effects := #[(command, #[(watchRoot / "f", .written)])] } }
        let job (ending : Nat) : JobM Bool := do
          let .ok watch ←
            FileWatch.start (.file (watchRoot / "f")) { window := 10, bound := 4 } | return false
          discard <| Process.run command 100
          let .ok changes ← FileWatch.next watch | return false
          let reached ← now
          match ending with
          | 0 =>
            return changes == #[changeOf (watchRoot / "f") [.written]] && reached == 12
          | 1 =>
            throw "failed"
          | _ =>
            discard <| FileWatch.next watch
            return true
        let (finished, afterFinished) := (job 0).runModel model
        let (failed, afterFailed) := (job 1).runModel model
        let (whenCancelled, afterCancelled) := (job 2).runModel { model with cancelAt := some 50 }
        let endedOne (after : JobModel) :=
          after.fileWatches.ended == #[1] && after.fileWatches.watches.isEmpty
        return finished == .finished true && failed == .failed "failed" &&
            whenCancelled == .cancelled &&
            [afterFinished, afterFailed, afterCancelled].all endedOne }]

/-- A watch model with `watchRoot` there, for the runner's watch checks. -/
def rootWatches : FileWatchModel :=
  { directories := #[watchRoot] }

/-- A job that watches `watchRoot / "f"` and then sleeps for `ms`. -/
def watchesThenSleeps (ms : Nat) : JobM Bool := do
  let .ok _ ← FileWatch.start (.file (watchRoot / "f")) atOnce | return false
  sleep ms
  return true

/-- The checks of the runner's watch waits, on the fake of the watch
service: a watch is named for its job, it ends with its job however the job
ends, a cancelled job's pending read is withdrawn, and removing an owner
ends its jobs' watches. -/
def fileWatchRunnerChecks : List Check :=
  [{  name := "a watch is named for its job: another job's next of it is noSuchWatch, asked of no service"
      run := do
        let (rig, _, watches) ← Rig.withWatches {} rootWatches
        let holder ← rig.spawn (reporting fun _ => watchesThenSleeps 1000)
        unless ← eventually (return (← watches.watching) == 1) do
          return false
        let id := ((← watches.started)[0]?.map (·.1)).getD 0
        let other ←
          rig.spawn
              (reporting fun _ => do
                let .error .noSuchWatch ← FileWatch.next ⟨id.toNat⟩ | return false
                return true)
        let refused ← other.endedAs (.finished #["true"])
        holder.handle.cancel
        let asked :=
          (← watches.started).any fun (_, request) =>
            match request with
            | .next _ => true
            | _ => false
        return refused && !asked },
    { name := "a watch ends with its job, finished, failed or cancelled, through the watch service's cancel"
      run := do
        let (rig, _, watches) ← Rig.withWatches {} rootWatches
        let finished ← rig.spawn (reporting fun _ => watchesThenSleeps 0)
        let failed ←
          rig.spawn
              (reporting fun _ => (do
                discard <| watchesThenSleeps 0
                throw "failed" : JobM Bool))
        let cancelled ← rig.spawn (reporting fun _ => watchesThenSleeps 1000000)
        let ended ←
          (return (← finished.endedAs (.finished #["true"])) && (← failed.endedAs (.failed "failed")))
        unless ← eventually (return (← watches.watching) == 1) do
          return false
        cancelled.handle.cancel
        let cancelledEnded ← cancelled.endedAs .cancelled
        let ids := (← watches.started).map (·.1)
        return ended && cancelledEnded && (← watches.watching) == 0 &&
            (← watches.ended).qsort (· < ·) == (ids.map (·.toNat)).qsort (· < ·) &&
            ids.all (← watches.withdrawn).contains },
    { name := "a cancelled job's pending next is withdrawn from the watch service, and its watch ended"
      run := do
        let (rig, _, watches) ← Rig.withWatches {} rootWatches
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                let .ok watch ← FileWatch.start (.file (watchRoot / "f")) atOnce | return false
                discard <| FileWatch.next watch
                return true)
        unless ← eventually (return (← watches.started).size == 2) do
          return false
        let started ← watches.started
        spawned.handle.cancel
        let ended ← spawned.endedAs .cancelled
        let withdrawn ← watches.withdrawn
        return ended && started.all (withdrawn.contains ·.1) && (← watches.watching) == 0 &&
            (← watches.waiting) == 0 },
    { name := "Jobs.removeOwner ends the watches of the owner's jobs, and leaves another owner's"
      run := do
        let (rig, _, watches) ← Rig.withWatches {} rootWatches
        let sleeps : Work := reporting fun _ => watchesThenSleeps 1000000
        let jobs : Job.Jobs := { services := rig.services }
        let (_, jobs) ← jobs.start anna "watches" sleeps fun _ => pure ()
        let (_, jobs) ← jobs.start ben "watches" sleeps fun _ => pure ()
        unless ← eventually (return (← watches.watching) == 2) do
          return false
        let (_, jobs) ← jobs.removeOwner anna
        let annasEnded ← eventually (return (← watches.watching) == 1)
        let one := (← watches.ended).size == 1
        jobs.cancelAll
        let allEnded ← eventually (return (← watches.watching) == 0)
        return annasEnded && one && allEnded }]

/-! ## A child's environment, looked up for its directory -/

/-- What `mise env --json` prints, in its layout: one name a line, indented
two spaces, with a `PATH` of 400 characters. -/
def miseOutput : String :=
  let path := String.ofList (List.replicate 400 'p')
  "{\n  \"PATH\": \"" ++ path ++
    "\",\n  \"MACOSX_DEPLOYMENT_TARGET\": \"27.2\",\n  \"RUST\": \"1.98\"\n}\n"

/-- Whether `parseVariables` reads `bytes` as `expected`. -/
def readsVariables (bytes : ByteArray) (expected : Array (String × String)) : Bool :=
  match Process.parseVariables bytes with
  | .ok variables => variables == expected
  | .error _ => false

/-- Whether `parseVariables` refuses `text` with `why`. -/
def refusesVariables (text : String) (why : String) : Bool :=
  match Process.parseVariables text.toUTF8 with
  | .error said => said == why
  | .ok _ => false

/-- An entry of a lookup that failed with `failure`, its config files' stamps
`stamps`. -/
def failedEntry (failure : Process.Failure) (stamps : Array (Option File.Stamp) := #[]) :
    Process.Entry :=
  { stamps, found := .failed failure }

/-- The checks of the pure part of a child's environment
(`Editor/Process/Environment.lean`): the parser of what mise prints, how the
lookup's variables and a command's own environment combine, the config files
whose stamps keep an entry, the shared state's answers and the messages. -/
def processEnvironmentChecks : List Check :=
  [{  name :=
        "parseVariables reads mise's layout, a multi-line object with a PATH of 400 characters"
      run :=
        pure
          (readsVariables miseOutput.toUTF8
            #[("PATH", String.ofList (List.replicate 400 'p')),
              ("MACOSX_DEPLOYMENT_TARGET", "27.2"), ("RUST", "1.98")]) },
    { name :=
        "parseVariables reads every escape, a surrogate pair among them, and the empty object; the last of a name that comes twice wins"
      run :=
        pure
          (readsVariables
              "{\"A\":\"\\\" \\\\ \\/ \\b \\f \\n \\r \\t \\u00e9 \\ud83d\\ude00\",\"B\":\"1\",\"B\":\"2\"}".toUTF8
              #[("A", "\" \\ / \x08 \x0c \n \r \t é 😀"), ("B", "2")] &&
            readsVariables " { } ".toUTF8 #[]) },
    { name :=
        "parseVariables refuses a number, null, a nested object, an array, trailing text, bytes that are not UTF-8, a name holding =, an empty name and a NUL, each with its reason"
      run :=
        pure
          (refusesVariables "{\"A\":1}" "a value is not a string" &&
            refusesVariables "{\"A\":null}" "a value is not a string" &&
            refusesVariables "{\"A\":{}}" "a value is not a string" &&
            refusesVariables "[\"A\"]" "it is not an object" &&
            refusesVariables "{\"A\":\"a\"} x" "there is more after the object" &&
            (match Process.parseVariables ⟨#[0x7B, 0xFF, 0x7D]⟩ with
            | .error why => why == "it is not UTF-8"
            | .ok _ => false) &&
            refusesVariables "{\"A=B\":\"a\"}" "the name A=B holds =" &&
            refusesVariables "{\"\":\"a\"}" "a name is empty" &&
            refusesVariables "{\"A\":\"a\\u0000\"}" "a string holds a NUL" &&
            refusesVariables "{\"A\":\"a\nb\"}" "a string holds a control character" &&
            refusesVariables "{\"A\":\"\\ud83d\"}"
              "a high surrogate is not followed by a low one") },
    { name :=
        "a lookup's variables are set over the editor's, the command's own set wins over one of the same name, its unset removes one, and clear drops them all"
      run :=
        let variables := #[("PATH", "/m/bin"), ("A", "mise"), ("DROP", "x")]
        pure
          (Process.Environment.over variables {} == { set := variables } &&
            Process.Environment.over variables { set := #[("A", "own")], unset := #["DROP"] } ==
              { set := #[("PATH", "/m/bin"), ("A", "own")], unset := #["DROP"] } &&
            Process.Environment.over variables { clear := true, set := #[("ONLY", "x")] } ==
              { clear := true, set := #[("ONLY", "x")] }) },
    { name := "configPaths of /p/d is mise's four config names in /p/d, then in /p, then in /"
      run :=
        let four (directory : String) : Array System.FilePath :=
          #[s!"{directory}mise.toml", s!"{directory}.mise.toml", s!"{directory}.tool-versions",
                s!"{directory}mise.local.toml"].map
            System.FilePath.mk
        pure
          (Process.configPaths "/p/d" == four "/p/d/" ++ four "/p/" ++ four "/" &&
            Process.configPaths "/p/d/" == Process.configPaths "/p/d") },
    { name :=
        "the shared state gives back the entry a record kept; a failure recorded says its message once, the same failure again says nothing, and with new stamps it says it again"
      run :=
        let state : Process.Environments := {}
        let failure := Process.Failure.exited 1 "untrusted"
        let first := failedEntry failure #[none]
        let message := Process.failureMessage "/p/d" failure
        let ((), state, said) := state.handle (.record "/p/d" first)
        let (cached, state, quiet) := state.handle (.cached "/p/d")
        let cached : Option Process.Entry := cached
        let ((), state, again) := state.handle (.record "/p/d" first)
        let ((), _, renewed) :=
          state.handle (.record "/p/d" (failedEntry failure #[some ⟨1, 0, 3⟩]))
        let variables : Process.Entry := { stamps := #[], found := .variables #[("A", "a")] }
        let ((), _, found) := ({} : Process.Environments).handle (.record "/p/e" variables)
        pure
          (said == some message && cached == some first && quiet.isNone && again.isNone &&
            renewed == some message &&
            found.isNone) },
    { name := "install drops what was resolved and every entry, and keeps the mode and the limit"
      run :=
        let state : Process.Environments :=
          { host := .window (some "/u"), limit := 7, resolved := some (.mise "/m")
            entries := #[("/p", failedEntry (.signalled 9))] }
        let ((), after, said) := state.handle (.install .inherited)
        pure
          (after ==
              { setting := .inherited, host := .window (some "/u"), limit := 7, resolved := none
                entries := #[] } &&
            said.isNone) },
    { name := "the policy is the setting, the mode, what was resolved and the limit"
      run :=
        let state : Process.Environments := { setting := .mise none, resolved := some .inherited }
        let (policy, after, said) := state.handle .policy
        let policy : Process.Policy := policy
        pure
          (policy ==
              { setting := .mise none, host := .headless, resolved := some .inherited
                limit := 5000 } &&
            after == state &&
            said.isNone) },
    { name := "each failure's message has its own words"
      run :=
        let say := Process.failureMessage "/p/d"
        let tail := "; its children get the editor's environment"
        pure
          (say (.exited 1 "not trusted") ==
              "environment: /p/d: mise exited with status 1: not trusted" ++ tail &&
            say (.exited 2 "") == "environment: /p/d: mise exited with status 2" ++ tail &&
            say (.signalled 9) == "environment: /p/d: mise was ended by signal 9" ++ tail &&
            say (.unparsable "it is not an object") ==
              "environment: /p/d: mise's output is not a JSON object of strings: it is not an object" ++
                tail &&
            say (.timedOut 5000) ==
              "environment: /p/d: mise did not finish within 5000 ms and was killed" ++ tail &&
            say (.refused (.denied "Permission denied")) ==
              "environment: /p/d: mise could not be run: the system does not allow it: Permission denied" ++
                tail &&
            say (.missing (Process.miseCandidates (some "/u"))) ==
              "environment: /p/d: mise is not at /u/.local/bin/mise, /opt/homebrew/bin/mise or /usr/local/bin/mise" ++
                tail) },
    { name :=
        "what a lookup's run came to: variables for status 0 and an object, and else the failure, with the first line of standard error"
      run :=
        let ran (exit : Process.Exit) (stdout stderr : String) : Except ProcessError Process.Ran :=
          .ok { exit, stdout := stdout.toUTF8, stderr := stderr.toUTF8 }
        pure
          (Process.foundOf (ran (.code 0) "{\"A\":\"a\"}" "") == .variables #[("A", "a")] &&
            Process.foundOf (ran (.code 1) "" "first\nsecond\n") == .failed (.exited 1 "first") &&
            Process.foundOf (ran (.signal 9) "" "") == .failed (.signalled 9) &&
            Process.foundOf (ran (.code 0) "[1]" "") ==
              .failed (.unparsable "it is not an object") &&
            Process.foundOf (.error .noSuchProcess) == .failed (.refused .noSuchProcess) &&
            Process.foundOf (.error (.timedOut 5000)) == .failed (.timedOut 5000)) }]

/-- The requests `job` makes when it runs against the job port's model from
`model`, in order. -/
def requestsOf {α : Type} (job : JobM α) (model : JobModel) : Array JobRequest :=
  go 10000 job.run model #[]
where
  /-- The requests of `program` from `model`, with `fuel` steps at most. -/
  go : Nat → Program jobPort (Except String α) → JobModel → Array JobRequest → Array JobRequest
    | 0, _, _, seen => seen
    | _, .done _, _, seen => seen
    | fuel + 1, .step request next, model, seen =>
      let (reply, after) := JobModel.handle request model
      go fuel (next reply) after (seen.push request)

/-- A run that ends with the status 0 and prints `stdout`. -/
def printed (stdout : String) : Except ProcessError Process.Ran :=
  .ok { exit := .code 0, stdout := stdout.toUTF8, stderr := .empty }

/-- The command the lookup checks start in `/p/d`: a bare `lake`, with a
variable of its own set and one unset. -/
def lakeBuild : Process.Command :=
  { program := "lake", arguments := #["build"]
    environment := { set := #[("A", "own")], unset := #["DROP"] }, directory := "/p/d" }

/-- What the lookup prints for `/p/d`: a `PATH`, a variable the command sets
too, one it unsets, and one of its own. -/
def lookupJson : String :=
  "{\"PATH\":\"/m/bin:/usr/bin\",\"A\":\"mise\",\"DROP\":\"x\",\"B\":\"b\"}"

/-- `command` with the lookup's variables of `lookupJson` set under its own. -/
def mergedOf (command : Process.Command) : Process.Command :=
  { command with
    environment :=
      { set := #[("PATH", "/m/bin:/usr/bin"), ("B", "b"), ("A", "own")], unset := #["DROP"] } }

/-- `command` in `directory`. -/
def movedTo (command : Process.Command) (directory : System.FilePath) : Process.Command :=
  { command with directory }

/-- A file model holding each of `paths`, written in that order. -/
def filesAt (paths : List System.FilePath) : FileModel :=
  paths.foldl (fun model path => model.withFile path "x".toUTF8) {}

/-- `model` with the file at `path` gone. -/
def withoutFile (model : FileModel) (path : System.FilePath) : FileModel :=
  { model with files := model.files.filter (·.path != path) }

/-- Whether `requests` read the stamp of any of `paths`. -/
def stampsAny (requests : Array JobRequest) (paths : List System.FilePath) : Bool :=
  requests.any fun request =>
    match request with
    | .file (.stamp path) => paths.contains path
    | _ => false

/-- The job model the lookup checks start from: the files `files`, the
scripts of `mise` at `executable` printing `lookupJson` in each of
`directories` and of each command merged there, and the environments with
`setting` and `host`. -/
def lookupModel (setting : Process.Setting) (host : Process.Host) (files : FileModel)
    (executable : System.FilePath := "/opt/mise") (directories : List System.FilePath := ["/p/d"])
    (reply : Except ProcessError Process.Ran := printed lookupJson) (takes : Nat := 0) : JobModel :=
  let scripts : Array Process.Script :=
    directories.toArray.flatMap fun directory =>
      #[{ command := Process.lookupCommand executable directory, reply, takes },
        { command := mergedOf (movedTo lakeBuild directory), reply := printed "built" },
        { command := movedTo lakeBuild directory, reply := printed "built inherited" }]
  { files, processes := { scripts }, environments := { setting, host } }

/-- A run of `command` that the model answers. -/
def runsOn (command : Process.Command) : JobM Bool := do
  return (← Process.run command 1000) matches .ok _

/-- Runs `job` on the model, and gives the model after it. -/
def after {α : Type} (job : JobM α) (model : JobModel) : JobModel :=
  (job.runModel model).2

/-- The checks of a child's environment on the models (AC 1 to 5 of
`docs/design/concurrency.md`, "A child's environment, as built"): each runs
jobs with `JobM.runModel` on one `JobModel`, carried from job to job. -/
def environmentLookupChecks : List Check :=
  let candidates := ["/opt/homebrew/bin/mise", "/usr/local/bin/mise"].map System.FilePath.mk
  [{  name :=
        "auto in the window mode runs the first candidate that exists: Homebrew's, with nothing under the home directory, and the home directory's once it is there"
      run :=
        let homebrew :=
          lookupModel .auto (.window (some "/u")) (filesAt candidates) "/opt/homebrew/bin/mise"
        let home :=
          lookupModel .auto (.window (some "/u")) (filesAt ("/u/.local/bin/mise" :: candidates))
            "/u/.local/bin/mise"
        pure
          ((after (runsOn lakeBuild) homebrew).processes.started ==
              #[Process.lookupCommand "/opt/homebrew/bin/mise" "/p/d", mergedOf lakeBuild] &&
            (after (runsOn lakeBuild) home).processes.started ==
              #[Process.lookupCommand "/u/.local/bin/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "auto in the window mode keeps what it resolved until a reload: with Homebrew's mise gone, a start in another directory still runs it and reads no candidate's stamp, and after install the next start resolves again"
      run :=
        let all : List System.FilePath := "/u/.local/bin/mise" :: candidates
        let model :=
          lookupModel .auto (.window (some "/u")) (filesAt candidates) "/opt/homebrew/bin/mise"
            (directories := ["/p/d", "/p/e"])
        let model :=
          { model with
            processes :=
              { model.processes with
                scripts :=
                  model.processes.scripts.push
                    { command := Process.lookupCommand "/usr/local/bin/mise" "/p/d"
                      reply := printed lookupJson } } }
        let inE := movedTo lakeBuild "/p/e"
        let once := after (runsOn lakeBuild) model
        let gone := { once with files := withoutFile once.files "/opt/homebrew/bin/mise" }
        let second := after (runsOn inE) gone
        let installed := { second with environments := second.environments.install .auto }
        let third := after (runsOn lakeBuild) installed
        pure
          (second.processes.started ==
              #[Process.lookupCommand "/opt/homebrew/bin/mise" "/p/d", mergedOf lakeBuild,
                Process.lookupCommand "/opt/homebrew/bin/mise" "/p/e", mergedOf inE] &&
            !stampsAny (requestsOf (runsOn inE) gone) all &&
            stampsAny (requestsOf (runsOn lakeBuild) installed) all &&
            third.processes.started ==
              second.processes.started ++
                #[Process.lookupCommand "/usr/local/bin/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "mise with no path runs the first candidate that exists, in the headless mode and in the window mode"
      run :=
        let headless :=
          lookupModel (.mise none) .headless (filesAt candidates) "/opt/homebrew/bin/mise"
        let window :=
          lookupModel (.mise none) (.window (some "/u"))
            (filesAt ("/u/.local/bin/mise" :: candidates)) "/u/.local/bin/mise"
        pure
          ((after (runsOn lakeBuild) headless).processes.started ==
              #[Process.lookupCommand "/opt/homebrew/bin/mise" "/p/d", mergedOf lakeBuild] &&
            (after (runsOn lakeBuild) window).processes.started ==
              #[Process.lookupCommand "/u/.local/bin/mise" "/p/d", mergedOf lakeBuild] &&
            (after (runsOn lakeBuild) headless).reported.isEmpty) },
    { name :=
        "auto in the window mode with none of the candidates starts the child as it would have"
      run :=
        pure
          ((after (runsOn lakeBuild)
                (lookupModel .auto (.window (some "/u")) {})).processes.started ==
            #[lakeBuild]) },
    { name := "auto in the headless mode starts the child as it would have and reads no stamp"
      run :=
        let model :=
          lookupModel .auto .headless (filesAt ("/u/.local/bin/mise" :: candidates))
            "/opt/homebrew/bin/mise"
        pure
          ((after (runsOn lakeBuild) model).processes.started == #[lakeBuild] &&
            !(requestsOf (runsOn lakeBuild) model).any fun request =>
                request matches .file (.stamp _)) },
    { name :=
        "with mise at a path, a run first runs mise env --json in its directory, then the command with the lookup's variables under its own: the bare name keeps its name and gets the lookup's PATH"
      run :=
        let model := lookupModel (.mise (some "/opt/mise")) .headless {}
        pure
          ((after (runsOn lakeBuild) model).processes.started ==
            #[Process.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild]) },
    { name := "with mise at a path, a streaming start gets the lookup's variables the same way"
      run :=
        let model := lookupModel (.mise (some "/opt/mise")) .headless {}
        let model :=
          { model with
            processes :=
              { model.processes with
                streams :=
                  #[{ command := mergedOf lakeBuild, steps := #[.write .out "built\n".toUTF8] }] } }
        let starts : JobM Bool := do
          return (← Process.start lakeBuild { bound := 64 }) matches .ok _
        pure
          ((starts.runModel model).1 == .finished true &&
            (after starts model).processes.started ==
              #[Process.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "a second start in the directory runs no lookup; after mise.toml there or a parent's .tool-versions is rewritten, or a config file appears, the next one looks up again"
      run :=
        let model :=
          lookupModel (.mise (some "/opt/mise")) .headless
            (filesAt ["/p/d/mise.toml", "/p/.tool-versions"])
        let lookup := Process.lookupCommand "/opt/mise" "/p/d"
        let once := after (runsOn lakeBuild) model
        let twice := after (runsOn lakeBuild) once
        let rewritten :=
          after (runsOn lakeBuild)
            { twice with files := twice.files.withFile "/p/d/mise.toml" "y".toUTF8 }
        let parent :=
          after (runsOn lakeBuild)
            { rewritten with files := rewritten.files.withFile "/p/.tool-versions" "y".toUTF8 }
        let appeared :=
          after (runsOn lakeBuild)
            { parent with files := parent.files.withFile "/.mise.toml" "y".toUTF8 }
        let merged := mergedOf lakeBuild
        pure
          (once.processes.started == #[lookup, merged] &&
            twice.processes.started == #[lookup, merged, merged] &&
            rewritten.processes.started == #[lookup, merged, merged, lookup, merged] &&
            parent.processes.started == #[lookup, merged, merged, lookup, merged, lookup, merged] &&
            appeared.processes.started ==
              #[lookup, merged, merged, lookup, merged, lookup, merged, lookup, merged]) },
    { name :=
        "a start in another directory runs its own lookup, and a reload's install drops every entry"
      run :=
        let model :=
          lookupModel (.mise (some "/opt/mise")) .headless {} (directories := ["/p/d", "/p/e"])
        let inD := after (runsOn lakeBuild) model
        let inE := after (runsOn (movedTo lakeBuild "/p/e")) inD
        let installed :=
          { inE with environments := inE.environments.install (.mise (some "/opt/mise")) }
        let again := after (runsOn lakeBuild) installed
        pure
          (inE.processes.started ==
              #[Process.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild,
                Process.lookupCommand "/opt/mise" "/p/e", mergedOf (movedTo lakeBuild "/p/e")] &&
            again.processes.started ==
              inE.processes.started ++
                #[Process.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "a lookup that exits non-zero starts the child inherited and reports once for the directory; a second start looks up nothing and says nothing"
      run :=
        let model :=
          lookupModel (.mise (some "/opt/mise")) .headless {} (reply :=
            .ok { exit := .code 1, stdout := .empty, stderr := "not trusted\n".toUTF8 })
        let once := after (runsOn lakeBuild) model
        let twice := after (runsOn lakeBuild) once
        pure
          (once.processes.started.back? == some lakeBuild &&
            once.reported == #[Process.failureMessage "/p/d" (.exited 1 "not trusted")] &&
            twice.processes.started == once.processes.started.push lakeBuild &&
            twice.reported == once.reported) },
    { name :=
        "a lookup whose output is not a JSON object of strings starts the child inherited and reports once for the directory"
      run :=
        let model := lookupModel (.mise (some "/opt/mise")) .headless {} (reply := printed "[1]")
        let once := after (runsOn lakeBuild) model
        let twice := after (runsOn lakeBuild) once
        pure
          (once.processes.started.back? == some lakeBuild &&
            once.reported == #[Process.failureMessage "/p/d" (.unparsable "it is not an object")] &&
            twice.processes.started == once.processes.started.push lakeBuild &&
            twice.reported == once.reported) },
    { name :=
        "a lookup that outlives the default limit of 5000 ms is killed at its start plus the limit, the child starts inherited, and the directory is reported once"
      run :=
        let model :=
          { lookupModel (.mise (some "/opt/mise")) .headless {} (takes := 6000) with now := 100 }
        let lookup := Process.lookupCommand "/opt/mise" "/p/d"
        let once := after (runsOn lakeBuild) model
        let twice := after (runsOn lakeBuild) once
        pure
          (once.processes.started == #[lookup, lakeBuild] && once.processes.killed == #[lookup] &&
            once.now == 5100 &&
            once.reported == #[Process.failureMessage "/p/d" (.timedOut 5000)] &&
            twice.processes.started == #[lookup, lakeBuild, lakeBuild] &&
            twice.reported == once.reported) },
    { name :=
        "with the inherited setting, a run and a start start their command exactly, read no stamp, and make only the policy request beyond the process request"
      run :=
        let model :=
          lookupModel .inherited (.window (some "/u"))
            (filesAt ("/u/.local/bin/mise" :: candidates))
        let model :=
          { model with
            processes :=
              { model.processes with
                streams := #[{ command := lakeBuild, steps := #[.write .out "built\n".toUTF8] }] } }
        let starts : JobM Bool := do
          return (← Process.start lakeBuild { bound := 64 }) matches .ok _
        pure
          ((after (runsOn lakeBuild) model).processes.started == #[lakeBuild] &&
            (after starts model).processes.started == #[lakeBuild] &&
            (after (runsOn lakeBuild) model).files == model.files &&
            requestsOf (runsOn lakeBuild) model ==
              #[.environment .policy, .process (.run lakeBuild 1000)]) },
    { name :=
        "a command that clears its environment runs no lookup, and a relative directory or program is refused as before, with no lookup"
      run :=
        let model := lookupModel (.mise (some "/opt/mise")) .headless {}
        let cleared := { lakeBuild with environment := { clear := true } }
        let model :=
          { model with
            processes :=
              { model.processes with
                scripts :=
                  model.processes.scripts.push { command := cleared, reply := printed "" } } }
        let relative := movedTo lakeBuild "p/d"
        let program := { lakeBuild with program := "bin/lake" }
        let refused (command : Process.Command) (error : ProcessError) : Bool :=
          match (Process.run command 1000).runModel model with
          | (.finished (.error refusal), after) =>
            refusal == error && after.processes.started.isEmpty
          | _ => false
        pure
          ((after (runsOn cleared) model).processes.started == #[cleared] &&
            refused relative .relativeDirectory &&
            refused program .relativeProgram) },
    { name :=
        "mise with no path and none of the candidates reports mise is not at them once for each directory, and runs no lookup"
      run :=
        let model :=
          lookupModel (.mise none) (.window (some "/u")) {} (directories := ["/p/d", "/p/e"])
        let once := after (runsOn lakeBuild) model
        let twice := after (runsOn lakeBuild) once
        let other := after (runsOn (movedTo lakeBuild "/p/e")) twice
        let missing := Process.Failure.missing (Process.miseCandidates (some "/u"))
        pure
          (other.processes.started == #[lakeBuild, lakeBuild, movedTo lakeBuild "/p/e"] &&
            other.reported ==
              #[Process.failureMessage "/p/d" missing, Process.failureMessage "/p/e" missing]) }]

/-- The checks of projects, workspaces and locations as data
(`Editor/Workspace.lean`): how an `origin` URL is normalised, how a project
is identified and named, how a workspace is labelled, what each location can
do, and a location's round trip through a buffer-local value. -/
def workspaceDataChecks : List Check :=
  let origin := "git@github.com:o/r.git"
  [{  name :=
        "an origin URL normalises to host/path whatever its form: git@github.com:o/r.git, https://github.com/o/r, ssh://git@github.com/o/r.git and https://github.com/o/r.git/ are one, and so are a host in capitals and an ssh port"
      run :=
        pure <|
          [origin, "https://github.com/o/r", "ssh://git@github.com/o/r.git",
                  "https://github.com/o/r.git/", "https://GitHub.com/o/r",
                  "ssh://git@github.com:22/o/r"].map
              Workspace.normaliseRemote ==
            List.replicate 6 "github.com/o/r" },
    { name :=
        "a project is identified by its normalised origin, else by its common git directory, else by its root, and a name config declares wins; it is named by the origin's last component, else by the common directory's parent's, else by the root's"
      run :=
        let byOrigin := Project.of "/x/clone" (some "/x/clone/.git") (some origin) none
        let byCommon := Project.of "/w" (some "/r/.git") none none
        let byRoot := Project.of "/m" none none none
        let declared := Project.of "/r/tools" none none (some "tools")
        let both := Project.of "/r" (some "/r/.git") (some origin) (some "mine")
        pure
          ((byOrigin.identity, byOrigin.name, byOrigin.remote, byOrigin.commonDir) ==
              (Project.Identity.remote "github.com/o/r", "r", some origin,
                some ("/x/clone/.git" : System.FilePath)) &&
            (byCommon.identity, byCommon.name) == (Project.Identity.commonDir "/r/.git", "r") &&
            (byRoot.identity, byRoot.name) == (Project.Identity.root "/m", "m") &&
            (declared.identity, declared.name) == (Project.Identity.declared "tools", "tools") &&
            (both.identity, both.name) == (Project.Identity.declared "mine", "mine")) },
    { name :=
        "a workspace is labelled name@branch, and name@ and its root's last component when it is detached or has no branch"
      run :=
        let project := Project.of "/r" (some "/r/.git") (some origin) none
        let onMain : Workspace :=
          { location := .local "/r", branch := some (.named "main"), project }
        let detached : Workspace := { location := .local "/w", branch := some .detached, project }
        let marked : Workspace :=
          { location := .local "/m", project := Project.of "/m" none none none }
        pure ([onMain, detached, marked].map Workspace.label == ["r@main", "r@w", "m@m"]) },
    { name :=
        "a local location can read files, run commands and watch files; one reachable by a command and one known only by its branch can do none of them"
      run :=
        let all : Location.Capabilities :=
          { readFiles := true, runCommands := true, watchFiles := true }
        let none : Location.Capabilities :=
          { readFiles := false, runCommands := false, watchFiles := false }
        pure
          ((Location.local "/r").can == all &&
            (Location.reachable "kube" "pod/dev" "/src").can == none &&
            (Location.branchOnly origin "agent/x").can == none) },
    { name :=
        "a location crosses as a buffer-local value and back, and a value that is no location reads as none"
      run :=
        let locations : List Location :=
          [.local "/r", .reachable "kube" "pod/dev" "/src", .branchOnly origin "agent/x"]
        pure
          (locations.all (fun location => Location.decode? location.encode == some location) &&
            [Value.null, .str "/r", .record [("local", .nat 1)], .record []].all
              (Location.decode? · == none)) }]

/-- The checks of how the git adapter reads what git prints
(`Editor/Workspace.lean`, "The git adapter's command lines"). -/
def workspaceGitChecks : List Check :=
  let printed (text : String) : ByteArray := text.toUTF8
  [{  name :=
        "rev-parse's three lines are the top level, the common directory and the branch; HEAD is a detached checkout, and a common directory that is not absolute is resolved against the directory asked about"
      run :=
        pure
          (Workspace.Git.parseRevParse "/r/src" (printed "/r\n/r/.git\nmain\n") ==
              some { toplevel := "/r", commonDir := "/r/.git", branch := .named "main" } &&
            Workspace.Git.parseRevParse "/r" (printed "/r\n.git\nHEAD\n") ==
              some { toplevel := "/r", commonDir := "/r/.git", branch := .detached }) },
    { name :=
        "output that is not three lines, a top level that is not absolute and bytes that are not UTF-8 are no answer"
      run :=
        pure
          ([printed "/r\n/r/.git\n", printed "", printed "r\n/r/.git\nmain\n",
                printed "/r\n/r/.git\nmain\nextra\n", ByteArray.mk #[0xff, 0x0a]].all
            (Workspace.Git.parseRevParse "/r" · == none)) },
    { name := "the origin is the first line git prints, and an empty output is no origin"
      run :=
        pure
          (Workspace.Git.parseOrigin (printed "git@github.com:o/r.git\n") ==
              some "git@github.com:o/r.git" &&
            Workspace.Git.parseOrigin (printed "") == none) }]

/-- A store of a number, for the checks of the workspace and project
stores. -/
def countStore : Store Nat :=
  { name := "count", version := 1, initial := 0, encode := .nat
    decode := fun
      | .nat n => some n
      | _ => none }

/-- The checks of the workspaces and projects the editor state keeps
(`EditorState.workspaces`, `Editor/Workspace.lean`, "The table"), through
the state requests that change them (`Editor/State/Request.lean`) and the
editor API (`Editor/Api.lean`, "Workspaces"). -/
def workspaceStateChecks : List Check :=
  let origin := "git@github.com:o/r.git"
  let main :=
    Workspace.Found.ofGit { toplevel := "/r", commonDir := "/r/.git", branch := .named "main" } none
  let worktree :=
    Workspace.Found.ofGit { toplevel := "/w", commonDir := "/r/.git", branch := .named "feature" }
      none
  let request (state : EditorState) (request : StateRequest) : EditorState :=
    (state.handle request).2
  let recorded : EditorState :=
    request (request EditorState.none (.recordWorkspace "/r/src" 0 (some main)))
      (.recordWorkspace "/w/src" 0 (some worktree))
  let one : BufferId := ⟨1⟩
  [{  name :=
        "a workspace registered with a location known only by its branch and one reachable through kube belong to the project of their remote, whichever form it is in, and neither can run commands or read files; registering a local location is refused, with the state as it was"
      run :=
        let branchOnly := Location.branchOnly origin "agent/x"
        let reachable := Location.reachable "kube" "pod/dev" "/src"
        let (first, state) :=
          EditorState.none.handle (.registerWorkspace branchOnly origin (some "agent/x"))
        let (second, state) :=
          state.handle (.registerWorkspace reachable "https://github.com/o/r" none)
        let (refused, after) := state.handle (.registerWorkspace (.local "/r") origin none)
        let table := state.workspaces
        pure
          (replied first == .inr () && replied second == .inr () &&
            [branchOnly, reachable].all
              (fun location =>
                ((table.workspace? location).map (·.project.identity)) ==
                    some (.remote "github.com/o/r") &&
                  !location.can.runCommands &&
                  !location.can.readFiles) &&
            table.projects.size == 1 &&
            replied refused == .inl .local &&
            after.workspaces == table) },
    { name :=
        "a main checkout and a linked worktree found once each are two workspaces of one project: a value in one's workspace store is not seen from the other's, and one in the project store is seen through both"
      run :=
        let mainAt := Location.local "/r"
        let worktreeAt := Location.local "/w"
        let (set, state) := recorded.handle (.setWorkspaceValue mainAt "x" (.nat 1))
        let identity := (state.workspaces.workspace? mainAt).map (·.project.identity)
        let shared := (state.workspaces.workspace? worktreeAt).map (·.project.identity)
        match identity with
        | none => pure false
        | some identity =>
          let (told, state) := state.handle (.setProjectValue identity "h" (.str "make"))
          let table := state.workspaces
          pure
            (replied set == .inr () && replied told == .inr () &&
              table.workspaceValue? mainAt "x" == some (.nat 1) &&
              table.workspaceValue? worktreeAt "x" == none &&
              shared == some identity &&
              table.projectValue? identity "h" == some (.str "make") &&
              table.workspaces.size == 2 &&
              table.projects.size == 1) },
    { name :=
        "a value for a workspace or a project there is none of is refused, noSuchWorkspace and noSuchProject, with the state as it was"
      run :=
        let (noWorkspace, kept) := recorded.handle (.setWorkspaceValue (.local "/z") "x" .null)
        let (noProject, held) := recorded.handle (.setProjectValue (.root "/z") "x" .null)
        pure
          (replied noWorkspace == .inl (.noSuchWorkspace (.local "/z")) &&
            replied noProject == .inl (.noSuchProject (.root "/z")) &&
            kept.workspaces == recorded.workspaces &&
            held.workspaces == recorded.workspaces) },
    { name :=
        "a workspace found again keeps its root, its project and its store, and takes the branch it now has"
      run :=
        let (_, stored) := recorded.handle (.setWorkspaceValue (.local "/r") "x" (.nat 1))
        let moved :=
          Workspace.Found.ofGit
            { toplevel := "/r", commonDir := "/r/.git", branch := .named "other" } (some origin)
        let again := request stored (.recordWorkspace "/r/lib" 0 (some moved))
        let workspace := again.workspaces.workspace? (.local "/r")
        pure
          ((workspace.map fun found => (found.branch, found.project.identity)) ==
              some (some (.named "other"), .commonDir "/r/.git") &&
            again.workspaces.workspaceValue? (.local "/r") "x" == some (.nat 1) &&
            again.workspaces.workspaces.size == 2) },
    { name :=
        "each directory's answer is cached under the generation it was found under, a directory with no workspace included, and is not an answer under another"
      run :=
        let none' := request recorded (.recordWorkspace "/x/" 0 none)
        let table := none'.workspaces
        pure
          (table.cached? "/r/src" 0 == some (some (.local "/r")) &&
            table.cached? "/r/src" 1 == none &&
            table.cached? "/x" 0 == some none &&
            table.cached? "/y" 0 == none) },
    { name :=
        "with no loop to answer, the shell time limit is none; a dispatched command that asks is answered the limit the loop was told of"
      run :=
        let program : EditorM (Guarded (Option Nat) × EditorState) := do
          (EditorState.ask .shellTimeLimit).dispatched { shellTimeLimit := some 5000 }
              (← twoBuffers)
        pure <|
          (EditorState.none.handle .shellTimeLimit).1 == none &&
            match (program.runModel editorModel).1 with
            | .ok (.finished answer, _) => answer == some 5000
            | _ => false },
    { name :=
        "with no loop to answer, the syntax refresh delay is none; a dispatched command that asks is answered the delay the loop was told of"
      run :=
        let program : EditorM (Guarded (Option Nat) × EditorState) := do
          (EditorState.ask .syntaxRefreshDelay).dispatched { syntaxRefreshDelay := some 250 }
              (← twoBuffers)
        pure <|
          (EditorState.none.handle .syntaxRefreshDelay).1 == none &&
            match (program.runModel editorModel).1 with
            | .ok (.finished answer, _) => answer == some 250
            | _ => false },
    { name :=
        "with no loop to answer, the workspace settings are config's defaults under generation 0"
      run := pure ((EditorState.none.handle .workspaceSettings).1 == ({}, 0)) },
    { name := "with no loop to answer, the compile hook is empty"
      run :=
        let hook := (EditorState.none.handle .compileHook).1
        pure (hook.contributions.isEmpty && hook.projects.isEmpty) },
    { name :=
        "a dispatched command that asks for the compile hook is answered what the loop was told, and the workspace settings carry the contributions' marker modes in registration order"
      run :=
        let hook : Compile.Hook :=
          { contributions :=
              #[{ mode := "b-mode", markers := #["b.toml"] },
                { mode := "a-mode", markers := #["a.toml", "a2.toml"] }]
            projects := #[{ project := .remote "github.com/o/r", mode := "b-mode" }] }
        let asking : EditorM (Compile.Hook × Workspace.Settings) := do
          return (← EditorState.ask .compileHook, (← EditorState.ask .workspaceSettings).1)
        let program : EditorM (Guarded (Compile.Hook × Workspace.Settings) × EditorState) := do
          asking.dispatched { compile := hook } (← twoBuffers)
        pure <|
          match (program.runModel editorModel).1 with
          | .ok (.finished (told, settings), _) =>
            told.contributions.map (·.mode) == #["b-mode", "a-mode"] &&
              told.projects == hook.projects &&
              settings.markerModes ==
                #[{ mode := "b-mode", markers := #["b.toml"] },
                  { mode := "a-mode", markers := #["a.toml", "a2.toml"] }]
          | _ => false },
    { name :=
        "a dispatched command that asks for the workspace settings is answered config's roots and the config generation the loop was told of"
      run :=
        let roots : Array Workspace.ConfigRoot := #[{ root := "/r/tools", project := some "tools" }]
        let registered : Loop.Registered := { workspaceRoots := roots, generation := 3 }
        let program : EditorM (Guarded (Workspace.Settings × Nat) × EditorState) := do
          (EditorState.ask .workspaceSettings).dispatched registered (← twoBuffers)
        pure <|
          match (program.runModel editorModel).1 with
          | .ok (.finished answer, _) => answer == ({ roots }, 3)
          | _ => false },
    { name :=
        "from a command: a buffer whose local value names a workspace has that workspace and its project; one that inherits from it has the same, and its working directory is the workspace's root; a buffer with none has no workspace and no working directory, and a store's value reads as its initial until it is set"
      run :=
        pure <|
          match
            dispatchedFrom do
              discard <| EditorState.ask (.recordWorkspace "/r/src" 0 (some main))
              discard <| one.setValue Workspace.bufferLocal (Location.local "/r").encode
              let found ← one.workspace?
              let none' ← (⟨0⟩ : BufferId).workspace?
              let before := (← editorState).workspaces.get countStore (.local "/r")
              let set ← Workspace.set countStore (.local "/r") 3
              let inherited ← (⟨0⟩ : BufferId).inheritWorkspace one
              return (found, none', before, set, inherited, ← (⟨0⟩ : BufferId).workspace?,
                  ← (⟨0⟩ : BufferId).workingDirectory) with
          | some ((found, none', before, set, inherited, after, directory), state) =>
            (found.map fun (workspace, project) => (workspace.location, project.identity)) ==
                some (.local "/r", .commonDir "/r/.git") &&
              none'.isNone &&
              before == 0 &&
              replied set == .inr () &&
              state.workspaces.get countStore (.local "/r") == 3 &&
              state.workspaces.get countStore (.local "/w") == 0 &&
              replied inherited == .inr () &&
              after == found &&
              directory == .workspace "/r"
          | none => false },
    { name :=
        "from a command: the unscoped store, for buffers outside any workspace, reads a store as its initial value until it is set there, then as what was set, a value of its own name beside it; and the editor's working directory is / until a host sets it, while a buffer with no workspace and no file still has none"
      run :=
        pure <|
          match
            dispatchedFrom do
              let before := (← editorState).workspaces.getUnscoped countStore
              Workspace.setUnscoped countStore 4
              Workspace.setUnscopedValue "other" (.str "kept")
              return (before, ← (⟨0⟩ : BufferId).workingDirectory) with
          | some ((before, directory), state) =>
            before == 0 && state.workspaces.getUnscoped countStore == 4 &&
              state.workspaces.unscopedValue? "other" == some (.str "kept") &&
              state.workspaces.unscopedValue? "missing" == none &&
              state.workspaces.workspaces.isEmpty &&
              state.workingDirectory == ("/" : System.FilePath) &&
              EditorState.none.workingDirectory == ("/" : System.FilePath) &&
              directory == .none
          | none => false },
    { name :=
        "from a command: a buffer with no workspace and no file has no working directory, and the API's registration and project values are the state requests'"
      run :=
        pure <|
          match
            dispatchedFrom do
              let directory ← (⟨0⟩ : BufferId).workingDirectory
              let local' ← Workspace.register (.local "/r") origin none
              let registered ←
                Workspace.register (.branchOnly origin "agent/x") origin (some "agent/x")
              let told ← Project.setValue (.remote "github.com/o/r") "h" (.nat 2)
              let typed ← Project.set countStore (.remote "github.com/o/r") 5
              let unknown ← Workspace.setValue (.local "/z") "x" .null
              return (directory, local', registered, told, typed, unknown) with
          | some ((directory, local', registered, told, typed, unknown), state) =>
            directory == .none && replied local' == .inl .local && replied registered == .inr () &&
              replied told == .inr () &&
              replied typed == .inr () &&
              replied unknown == .inl (.noSuchWorkspace (.local "/z")) &&
              state.workspaces.projectValue? (.remote "github.com/o/r") "h" == some (.nat 2) &&
              state.workspaces.getOfProject countStore (.remote "github.com/o/r") == 5
          | none => false }]

/-- The `origin` of the repository of the workspace driver checks. -/
def workspaceOrigin : String :=
  "git@github.com:o/r.git"

/-- The world of the workspace driver checks: a main checkout at `/r` on
`main` and a linked worktree of it at `/w` on `feature`, both with
`workspaceOrigin`; `/x` is in no repository and holds no marker. -/
def workspaceWorld : Workspace.World :=
  { repositories :=
      #[{ toplevel := "/r", commonDir := "/r/.git", origin := some workspaceOrigin },
        { toplevel := "/w", commonDir := "/r/.git", branch := some "feature"
          origin := some workspaceOrigin }]
    markerDirectories := #["/r/.git"], markers := #["/w/.git"] }

/-- The jobs of the workspace driver checks: the find job, the mode marker
job and the file command checks' jobs. -/
def workspaceJobs (name : String) : Option (List Argument → Work) :=
  if name == Workspace.findJob then some Workspace.findWork
  else if name == Workspace.markerJob then some Workspace.markerWork else fileJobs Files.limit name

/-- The bindings of the workspace driver checks: `C-o a`, `C-o b`
and `C-o c` open `a.lean`, `b.lean` and `c.lean` in `/r/src`, `C-o w`
opens `/w/src/b.lean` and `C-o x` opens `/x/a.txt`; `C-o i` runs
`workspace-current`; `C-o n` makes a buffer `made` that inherits the
workspace of the window's buffer, and a buffer `bare` that does not. -/
def workspaceBindings : List (String × Invocation) :=
  [("C-o a", opens "/r/src/a.lean"), ("C-o b", opens "/r/src/b.lean"),
    ("C-o c", opens "/r/src/c.lean"), ("C-o w", opens "/w/src/b.lean"), ("C-o x", opens "/x/a.txt"),
    ("C-o i", invoke Workspace.currentName), ("C-o n", invoke "inherit")]

/-- The commands of the workspace driver checks, by name: the open command,
`workspace-current` and `inherit` (`workspaceBindings`). -/
def workspaceCommands : List (String × Dispatched) :=
  [(Files.openName, fun call => do
      Files.openCommand call
      return none),
    (Workspace.currentName, fun call => do
      Workspace.currentCommand call
      return none),
    ("inherit", fun call => do
      if let .ok made← createBuffer "made" then
        discard <| made.inheritWorkspace call.target.window.buffer
      discard <| createBuffer "bare"
      return none)]

/-- The keys of the workspace driver checks (`workspaceBindings`,
`workspaceCommands`). -/
def workspaceKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys workspaceBindings workspaceCommands

/-- A driver with the keys `keys`, those of the workspace driver checks by
default, and the jobs `registered`, whose jobs meet the processes and the
files of `workspaceWorld` for its three directories, with the files the
keys open, and two more in `/r/src` for the shell checks' filters; `none`
if making the state was refused. -/
def workspaceDriver (registered : String → Option (List Argument → Work) := workspaceJobs)
    (keys : Loop.Keys TestScheme.scheme := workspaceKeys) : Option TestDriver :=
  let model := workspaceWorld.jobModel "git" #["/r/src", "/w/src", "/x"]
  let files :=
    [("/r/src/a.lean", "a"), ("/r/src/b.lean", "b"), ("/r/src/c.lean", "c"), ("/w/src/b.lean", "w"),
          ("/x/a.txt", "x"), ("/r/src/s.txt", "b\nc\na\n"), ("/r/src/t.txt", "d\nb\nc\na")].foldl
      (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8) model.files
  (Loop.Driver.over keys registered (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { model with files } }

/-- `driver` once `events` are fed and every job they start, and every job
those jobs' commands start, is finished, oldest first. -/
def settledOn (driver : TestDriver) (events : List Event) : TestDriver :=
  (List.range 8).foldl
    (fun driver _ =>
      match driver.pending[0]? with
      | some job => (driver.finish job.id).1
      | none => driver)
    (fedTo driver events).1

/-- `driver` once `keys` are pressed and every job they start, and every job
those jobs' commands start, is finished, oldest first. -/
def settledAfter (driver : TestDriver) (keys : String) : TestDriver :=
  settledOn driver (presses keys)

/-- The workspace of the buffer the view 0 of `driver` shows, and its
project. -/
def shownWorkspace (driver : TestDriver) : Option (Workspace × Project) := do
  driver.loop.state.workspaceOf? (← showing driver).id

/-- The two git commands the finder runs in `directory`. -/
def gitAsked (directory : System.FilePath) : Array Process.Command :=
  #[Workspace.Git.revParseCommand "git" directory, Workspace.Git.originCommand "git" directory]

/-- The checks of a buffer's workspace (`Editor/Workspace/Attach.lean`), on
the loop's driver over the editor's models and the job model of
`workspaceWorld`. -/
def workspaceChecks : List Check :=
  [{  name :=
        "a file under /r/src opens into a buffer whose workspace has root /r, branch main and location local /r, and whose project is identified by the normalised origin, with the common git directory /r/.git"
      run :=
        pure <|
          match workspaceDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            (shownWorkspace opened).map
                (fun (workspace, project) =>
                  (workspace.location, workspace.branch, project.identity, project.commonDir,
                    project.remote)) ==
              some
                (.local "/r", some (.named "main"), .remote "github.com/o/r",
                  some ("/r/.git" : System.FilePath), some workspaceOrigin) },
    { name :=
        "a file in the linked worktree /w has workspace root /w and branch feature, of the same project as /r's: two workspaces, each with its own store, and one project, with one store"
      run :=
        pure <|
          match workspaceDriver with
          | none => false
          | some driver =>
            let main := settledAfter driver "C-o a"
            let both := settledAfter main "C-o w"
            let state := both.loop.state
            match shownWorkspace main, shownWorkspace both with
            | some (first, project), some (second, shared) =>
              let (_, state) := state.handle (.setWorkspaceValue first.location "x" (.nat 1))
              let (_, state) := state.handle (.setProjectValue project.identity "h" (.nat 2))
              second.location == .local "/w" && second.branch == some (.named "feature") &&
                shared == project &&
                state.workspaces.workspaceValue? second.location "x" == none &&
                state.workspaces.workspaceValue? first.location "x" == some (.nat 1) &&
                state.workspaces.projectValue? shared.identity "h" == some (.nat 2) &&
                state.workspaces.workspaces.size == 2 &&
                state.workspaces.projects.size == 1
            | _, _ => false },
    { name :=
        "with no adapter answering, a buffer has no workspace, and workspace-current says so, naming the file's directory"
      run :=
        pure <|
          match workspaceDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o x"
            let asked := settledAfter opened "C-o i"
            (shownWorkspace opened).isNone &&
              (showing opened).map (·.buffer.name) == some "a.txt" &&
              echoOf asked == some (Workspace.noWorkspace "/x") },
    { name :=
        "two open workspaces of one project are labelled name@branch, and workspace-current in /r's buffer says its label, location, branch and what it can do, its project's name and identity, and the project's other open workspace by label"
      run :=
        pure <|
          match workspaceDriver with
          | none => false
          | some driver =>
            let both := settledAfter (settledAfter driver "C-o a") "C-o w"
            let back := settledAfter both "C-o a"
            let asked := settledAfter back "C-o i"
            match showing back, shownWorkspace back, shownWorkspace both with
            | some shown, some (main, _), some (worktree, _) =>
              let current := Workspace.current back.loop.state shown.id
              main.label == "r@main" && worktree.label == "r@feature" &&
                back.loop.state.workspaces.others main == #[worktree] &&
                current ==
                  .workspace
                    { label := "r@main", location := .local "/r", branch := some (.named "main")
                      can := (Location.local "/r").can, projectName := "r"
                      identity := .remote "github.com/o/r", others := #["r@feature"] } &&
                echoOf asked == some current.text
            | _, _, _ => false },
    { name :=
        "with one open workspace of its project, workspace-current says the buffer's workspace and lists no other"
      run :=
        pure <|
          match workspaceDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let asked := settledAfter opened "C-o i"
            match showing opened with
            | some shown =>
              let current := Workspace.current opened.loop.state shown.id
              current ==
                  .workspace
                    { label := "r@main", location := .local "/r", branch := some (.named "main")
                      can := (Location.local "/r").can, projectName := "r"
                      identity := .remote "github.com/o/r", others := #[] } &&
                echoOf asked == some current.text
            | none => false },
    { name :=
        "a second file in the same directory asks git nothing and starts no find job, and has the workspace; once a reload has installed a new generation, the next file asks git again"
      run :=
        pure <|
          match workspaceDriver with
          | none => false
          | some driver =>
            let first := settledAfter driver "C-o a"
            let second := settledAfter first "C-o b"
            let reloaded :=
              { second with
                keys :=
                  { second.keys with
                    registered := { second.keys.registered with generation := 1 } } }
            let third := settledAfter reloaded "C-o c"
            first.jobs.processes.started == gitAsked "/r/src" &&
              second.jobs.processes.started == gitAsked "/r/src" &&
              second.next == first.next + 1 &&
              (shownWorkspace second).map (·.1.location) == some (.local "/r") &&
              third.jobs.processes.started == gitAsked "/r/src" ++ gitAsked "/r/src" &&
              (shownWorkspace third).map (·.1.location) == some (.local "/r") },
    { name :=
        "a buffer made from a buffer with a workspace inherits it, and one made without inheriting has none"
      run :=
        pure <|
          match workspaceDriver with
          | none => false
          | some driver =>
            let made := settledAfter (settledAfter driver "C-o a") "C-o n"
            let state := made.loop.state
            match state.findBuffer "made", state.findBuffer "bare" with
            | some inherited, some bare =>
              (state.workspaceOf? inherited).isSome &&
                state.workspaceOf? inherited == shownWorkspace made &&
                (state.workspaceOf? bare).isNone
            | _, _ => false },
    { name :=
        "the unscoped store is the editor state's, so a new config generation and the files opened under it leave it as it was"
      run :=
        pure <|
          match workspaceDriver with
          | none => false
          | some driver =>
            let ((), state) := driver.loop.state.handle (.setUnscopedValue countStore.name (.nat 7))
            let set := { driver with loop := { driver.loop with state } }
            let reloaded :=
              { set with
                keys :=
                  { set.keys with registered := { set.keys.registered with generation := 1 } } }
            let opened := settledAfter (settledAfter reloaded "C-o a") "C-o x"
            opened.loop.state.workspaces.getUnscoped countStore == 7 &&
              (shownWorkspace opened).isNone },
    { name :=
        "with no find job registered, a file still opens, its buffer has no workspace, and nothing is said"
      run :=
        pure <|
          match workspaceDriver (fileJobs Files.limit) with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            (showing opened).map (·.buffer.name) == some "a.lean" &&
              (shownWorkspace opened).isNone &&
              echoOf opened == some "" &&
              opened.jobs.processes.started.isEmpty },
    { name :=
        "a find order crosses as arguments and back, its roots with and without a project, and arguments that are no order read as none; the find job started with them fails"
      run :=
        let orders : List Workspace.FindOrder :=
          [{ buffer := ⟨1⟩, directory := "/r/src", generation := 0 },
            { buffer := ⟨4⟩, directory := "/a b/é", git := "/usr/bin/git", generation := 7
              roots := #[{ root := "/r/tools", project := some "tools" }, { root := "/notes" }] }]
        pure
          (orders.all
              (fun order => Workspace.FindOrder.ofArguments? order.arguments == some order) &&
            [[], [.nat 1, .str "/r"], [.nat 1, .str "/r", .str "git", .nat 0, .str "/t"]].all
              (Workspace.FindOrder.ofArguments? · == none) &&
            ((Workspace.findWork [.nat 1] ()).runModel {}).1 matches .failed _) }]

/-- The checks of the pure rules of the search for a minor mode's markers
within a workspace (`Editor/Workspace.lean`, "Modes on markers"): where it
looks, which modes the markers it found turn on, and how an on-mode
crosses as a tree. -/
def modeMarkerChecks : List Check :=
  [{  name :=
        "markerSearchPaths looks from /r/a/b/c up to and including the bound /r, each marker in order, and with a bound that does not hold the directory in the directory alone"
      run :=
        let expected : Array (System.FilePath × System.FilePath × String) :=
          #[("/r/a/b/c", "/r/a/b/c/x.toml", "x.toml"), ("/r/a/b/c", "/r/a/b/c/y.toml", "y.toml"),
            ("/r/a/b", "/r/a/b/x.toml", "x.toml"), ("/r/a/b", "/r/a/b/y.toml", "y.toml"),
            ("/r/a", "/r/a/x.toml", "x.toml"), ("/r/a", "/r/a/y.toml", "y.toml"),
            ("/r", "/r/x.toml", "x.toml"), ("/r", "/r/y.toml", "y.toml")]
        let alone : Array (System.FilePath × System.FilePath × String) :=
          #[("/r/a", "/r/a/x.toml", "x.toml")]
        pure
          (Workspace.markerSearchPaths #["x.toml", "y.toml"] "/r/a/b/c" "/r" == expected &&
            Workspace.markerSearchPaths #["x.toml", "y.toml"] "/r/a/b/c/" "/r/" == expected &&
            Workspace.markerSearchPaths #["x.toml"] "/r/a" "/w" == alone &&
            Workspace.markerSearchPaths #["x.toml"] "/r/a" "/r/a/b" == alone) },
    { name :=
        "onModes puts the nearest root first and, at one root, keeps registration order, whatever order the markers were found in"
      run :=
        let modes : Array Workspace.MarkerMode :=
          #[{ mode := "b-mode", markers := #["b.toml"] },
            { mode := "a-mode", markers := #["a.toml"] },
            { mode := "c-mode", markers := #["b.toml"] }]
        let present : Array (System.FilePath × String) :=
          #[("/r/k/l", "a.toml"), ("/r/k", "b.toml")]
        let expected : Array Workspace.OnMode :=
          #[{ mode := "a-mode", root := "/r/k/l" }, { mode := "b-mode", root := "/r/k" },
            { mode := "c-mode", root := "/r/k" }]
        pure
          (Workspace.onModes modes "/r/k/l" "/r" present == expected &&
            Workspace.onModes modes "/r/k/l" "/r" present.reverse == expected &&
            -- A mode is on at its nearest marker only.
            Workspace.onModes #[{ mode := "a-mode", markers := #["a.toml"] }] "/r/k/l" "/r"
                #[("/r/k", "a.toml"), ("/r/k/l", "a.toml")] ==
              #[{ mode := "a-mode", root := "/r/k/l" }] &&
            Workspace.onModes modes "/r/k/l" "/r" #[] == #[] &&
            Workspace.markersOf modes == #["b.toml", "a.toml"]) },
    { name :=
        "an outermost mode's root is its farthest marker within the bound: a nearest mode at a deeper root still comes first, a marker above the bound is not looked at, and with one marker the root is that one's"
      run :=
        let outer : Workspace.MarkerMode :=
          { mode := "o-mode", markers := #["o.toml"], outermost := true }
        let nearest : Workspace.MarkerMode := { mode := "n-mode", markers := #["n.toml"] }
        let present : Array (System.FilePath × String) :=
          #[("/r/k/l", "o.toml"), ("/r/k", "n.toml"), ("/r", "o.toml"), ("/", "o.toml")]
        pure
          (Workspace.onModes #[outer, nearest] "/r/k/l" "/r" present ==
              #[{ mode := "n-mode", root := "/r/k" }, { mode := "o-mode", root := "/r" }] &&
            Workspace.onModes #[{ outer with outermost := false }, nearest] "/r/k/l" "/r" present ==
              #[{ mode := "o-mode", root := "/r/k/l" }, { mode := "n-mode", root := "/r/k" }] &&
            Workspace.onModes #[outer, nearest] "/r/k/l" "/r" #[("/r/k/l", "o.toml")] ==
              #[{ mode := "o-mode", root := "/r/k/l" }] &&
            (Compile.Contribution.markerMode
                { mode := "o-mode", markers := #["o.toml"], outermost := true }) ==
              outer) },
    { name := "an on-mode crosses as a tree and back; a tree that is no on-mode reads as none"
      run :=
        let on : Workspace.OnMode := { mode := "a-mode", root := "/a b/é" }
        pure
          (Workspace.OnMode.decode? on.encode == some on &&
            [Value.str "a-mode", .list [.str "a-mode"], .list [.nat 1, .str "/r"]].all
              (Workspace.OnMode.decode? · == none) &&
            Workspace.modesLocal == "marker-modes") }]

end ModelTest
