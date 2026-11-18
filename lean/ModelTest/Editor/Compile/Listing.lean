import Editor.Command
import Editor.Command.Dispatch
import Editor.Compile.Contribution
import Editor.Compile.Errors
import Editor.Compile.Listing
import Editor.Config.Registry
import Editor.Event
import Editor.File
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.Store
import Editor.Text
import Editor.Text.Model
import Editor.Value
import Editor.Workspace
import Editor.Workspace.Model
import Editor.Workspace.Modes
import ModelTest.Check
import ModelTest.Support.Compile
import ModelTest.Support.Driver
import ModelTest.Support.Keys
import ModelTest.Support.Models
import ModelTest.Support.Prompts
import ModelTest.Support.Shell
import ModelTest.Support.Workspace

/-!
# Model tests: `Editor/Compile/Listing.lean`

The model tests of `Editor/Compile/Listing.lean`: `listingChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- What `t-mode`'s listing prints, read: one command a line, `name=line`
or `name=line=directory`. -/
def tRead (bytes : ByteArray) : Except String (Array Compile.NamedCommand) := do
  let some text := String.fromUTF8? bytes | throw "it is not UTF-8"
  ((text.splitOn "\n").filter (!·.isEmpty)).toArray.mapM fun line =>
      match line.splitOn "=" with
      | [name, line] => pure { name, line }
      | [name, line, directory] => pure { name, line, directory := some directory }
      | _ => throw s!"{line} is no command"

/-- The contribution of the listing checks: `t-mode` on `t.toml`, with the
commands `build` (`t-fixed-build`) and `check` (`t-check`), and its listing
`t-list`, read by `tRead`. -/
def tContribution : Compile.Contribution :=
  { mode := "t-mode", markers := #["t.toml"]
    commands :=
      #[{ name := "build", line := "t-fixed-build" }, { name := "check", line := "t-check" }]
    listing := some { program := "t-list", read := tRead } }

/-- The listing `t-list` in `directory`. -/
def tList (directory : System.FilePath) : Process.Command :=
  { program := "t-list", directory }

/-- The world of the listing checks: the repositories `/t` and `/t2`, each
holding `t.toml`, and `/u`, a directory holding `t.toml` in no
repository. -/
def listingWorld : Workspace.World :=
  { repositories :=
      #[{ toplevel := "/t", commonDir := "/t/.git" },
        { toplevel := "/t2", commonDir := "/t2/.git" }]
    markerDirectories := #["/t/.git", "/t2/.git"]
    markers := #["/t/t.toml", "/t2/t.toml", "/u/t.toml"] }

/-- What each run of the listing checks does: `t-list` in `/t` lists
`build`, `fmt` and `sub`, in `sub`; in `/t2` it fails; in `/u` it lists
`u-only`. -/
def listingScripts : Array Process.Script :=
  #[{ command := tList "/t", reply := shellReply "build=t-build\nfmt=t-fmt\nsub=t-sub=sub\n" },
    { command := tList "/t2", reply := shellReply "" "t-list: broken\nmore\n" (.code 3) },
    { command := tList "/u", reply := shellReply "u-only=u-only\n" }]

/-- The streaming children of the listing checks. -/
def listingStreams : Array Process.StreamScript :=
  #[{ command := shellCommand "/t" "t-build", steps := linesSteps ["ok"] },
    { command := shellCommand "/t/sub" "t-sub", steps := linesSteps ["ok"] },
    { command := shellCommand "/u" "u-only", steps := linesSteps ["ok"] }]

/-- A driver of the listing checks over `registry`, by default `t-mode`
registered in config: the world of `listingWorld`, with its bindings, the
compile checks' jobs, its files, runs and children; `none` if making the
state was refused. -/
def listingDriver (registry : Config.Registry := hookRegistry (compileContribution tContribution)) :
    Option TestDriver :=
  let model := listingWorld.jobModel "git" #["/t", "/t2", "/u"]
  let files :=
    [("/t/a.txt", "a"), ("/t/b.txt", "b"), ("/t2/a.txt", "a"), ("/u/a.txt", "a")].foldl
      (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8) model.files
  let keys := compileKeysOf listingBindings
  let keys := { keys with registered := { keys.registered with compile := registry.compileHook } }
  (Loop.Driver.over keys compileJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver =>
    { driver with
      jobs :=
        { model with
          files
          processes :=
            { model.processes with
              scripts := model.processes.scripts ++ listingScripts, streams := listingStreams } } }

/-- `driver` once every pending job not called `name` is finished, oldest
first, with those they start; bounded. -/
def settledBut (driver : TestDriver) (name : String) : TestDriver :=
  (List.range 8).foldl
    (fun driver _ =>
      match driver.pending.find? (·.name != name) with
      | some job => (driver.finish job.id).1
      | none => driver)
    driver

/-- The checks of a contribution's computed commands
(`Editor/Compile/Listing.lean`), on the loop's driver over the editor's
models, the job model and the process model, with `t-mode`. -/
def listingChecks : List Check :=
  [{  name :=
        "turning t-mode on runs its listing t-list in its root once, after find-mode-markers; a second file under the root starts compile-list again and runs nothing"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let (first, names) := settledNames driver "C-p 1"
            let (second, again) := settledNames first "C-p 2"
            shownOnModes first == some #[{ mode := "t-mode", root := "/t" }] &&
              names.filter (fun name => name == Workspace.markerJob || name == Compile.listJob) ==
                #[Workspace.markerJob, Compile.listJob] &&
              startedCount first (tList "/t") == 1 &&
              again.contains Compile.listJob &&
              startedCount second (tList "/t") == 1 &&
              (Compile.entriesOf second.loop.state (some (.local "/t"))).size == 1 },
    { name :=
        "compile-command offers the listed commands after the contribution's own, a listed name in place of its own: build runs t-build in /t, and sub, listed in sub, runs t-sub in /t/sub"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 1"
            let asked := pressedOn opened "C-k i"
            let built := drained (fedTo opened (exLine "compile-command build")).1
            let subbed := drained (fedTo opened (exLine "compile-command sub")).1
            (candidatesOf asked).map (·.all) ==
                some #["build (t-mode)", "check (t-mode)", "fmt (t-mode)", "sub (t-mode)"] &&
              built.jobs.processes.started.back? == some (shellCommand "/t" "t-build") &&
              subbed.jobs.processes.started.back? == some (shellCommand "/t/sub" "t-sub") &&
              startedCount subbed (tList "/t") == 1 },
    { name :=
        "offers puts a mode's listed commands after its own, a listed name in place of its own, and a project's command in place of a listed one; a listed directory resolves against the root and an absolute one is kept"
      run :=
        let listed (mode : String) (root : System.FilePath) : Array Compile.NamedCommand :=
          if mode == "t-mode" && root == "/t" then
            #[{ name := "build", line := "t-build" }, { name := "fmt", line := "t-fmt" },
              { name := "sub", line := "t-sub", directory := some "sub" },
              { name := "abs", line := "t-abs", directory := some "/elsewhere" }]
          else #[]
        let project : Array Compile.ProjectCommands :=
          #[{ project := .remote "github.com/o/r", mode := "t-mode"
              commands := #[{ name := "fmt", line := "p-fmt" }] }]
        let offer (name line : String) (root : System.FilePath := "/t") : Compile.Offer :=
          { mode := "t-mode", name, line, root }
        pure
          (Compile.offers #[tContribution] project #[{ mode := "t-mode", root := "/t" }] listed ==
              #[offer "build" "t-build", offer "check" "t-check", offer "fmt" "p-fmt",
                offer "sub" "t-sub" "/t/sub", offer "abs" "t-abs" "/elsewhere"] &&
            Compile.offers #[tContribution] #[] #[{ mode := "t-mode", root := "/t2" }] listed ==
              #[offer "build" "t-fixed-build" "/t2", offer "check" "t-check" "/t2"]) },
    { name :=
        "a listing that fails offers none of its commands and says why once, with its first line of standard error"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 3"
            let asked := settledAfter opened "C-k i"
            echoOf opened == some "t-mode in /t2: t-list exited with status 3: t-list: broken" &&
              (candidatesOf asked).map (·.all) == some #["build (t-mode)", "check (t-mode)"] &&
              startedCount asked (tList "/t2") == 1 },
    { name :=
        "a listing that could not be run, as mise is not found by an editor started from the Finder, offers none of its commands and says why once"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let refused : Process.Script :=
              { command := tList "/t2", reply := .error (.notFound "t-list") }
            let driver :=
              { driver with
                jobs :=
                  { driver.jobs with
                    processes :=
                      { driver.jobs.processes with
                        scripts := #[refused] ++ driver.jobs.processes.scripts } } }
            let opened := settledAfter driver "C-p 3"
            let asked := settledAfter opened "C-k i"
            echoOf opened ==
                some
                  "t-mode in /t2: t-list could not be run: the program or the directory is not there: t-list" &&
              (candidatesOf asked).map (·.all) == some #["build (t-mode)", "check (t-mode)"] &&
              startedCount asked (tList "/t2") == 1 },
    { name :=
        "each end of a listing's run has its own words: a status with its first line of standard error, a status whose first line is empty, a signal, output its read refuses, a run that ran out of time, and one that could not be run"
      run :=
        let order : Compile.ListOrder :=
          { place := none, mode := "mise-mode", root := "/m", generation := 0, markers := #[]
            held := none, program := "mise", programArguments := #["tasks", "ls", "--json"] }
        let say := Compile.outcomeOf order tRead
        pure
          (say (shellReply "" "not trusted\nmore\n" (.code 1)) ==
              .failed "mise tasks ls --json exited with status 1: not trusted" &&
            say (shellReply "" "" (.code 2)) ==
              .failed "mise tasks ls --json exited with status 2" &&
            say (shellReply "" "\nsecond\n" (.code 2)) ==
              .failed "mise tasks ls --json exited with status 2" &&
            say (shellReply "" "" (.signal 9)) ==
              .failed "mise tasks ls --json was ended by signal 9" &&
            say (shellReply "nope\n") ==
              .failed "mise tasks ls --json printed no list of commands: nope is no command" &&
            say (.error (.timedOut 10000)) ==
              .failed "mise tasks ls --json did not finish within 10000 ms and was killed" &&
            say (.error (.denied "Permission denied")) ==
              .failed
                "mise tasks ls --json could not be run: the system does not allow it: Permission denied" &&
            say (shellReply "a=b\n") == .listed #[{ name := "a", line := "b" }]) },
    { name :=
        "with t-mode dropped from the hook before its listing job's command runs, the command keeps no entry"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let waiting := settledBut (fedTo driver (presses "C-p 1")).1 Compile.listJob
            let dropped :=
              { waiting with
                keys :=
                  { waiting.keys with
                    registered := { waiting.keys.registered with compile := {} } } }
            let listed :=
              match dropped.pending.find? (·.name == Compile.listJob) with
              | some job => (dropped.finish job.id).1
              | none => dropped
            startedCount listed (tList "/t") == 1 &&
              (Compile.entriesOf listed.loop.state (some (.local "/t"))).isEmpty },
    { name :=
        "a file in a directory holding t.toml and no repository has t-mode on there: its listing runs there once, is kept in the unscoped store, and compile-command offers and runs what it lists"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 4"
            let asked := settledAfter opened "C-k i"
            let ran := drained (fedTo opened (exLine "compile-command u-only")).1
            (shownWorkspace opened).isNone &&
              shownOnModes opened == some #[{ mode := "t-mode", root := "/u" }] &&
              startedCount asked (tList "/u") == 1 &&
              (Compile.entriesOf opened.loop.state none).map
                  (fun entry => (entry.mode, entry.root.toString)) ==
                #[("t-mode", "/u")] &&
              (candidatesOf asked).map (·.all) ==
                some #["build (t-mode)", "check (t-mode)", "u-only (t-mode)"] &&
              ran.jobs.processes.started.back? == some (shellCommand "/u" "u-only") },
    { name :=
        "in a workspace whose location cannot run commands no listing is started when t-mode turns on, and compile-command offers nothing"
      run :=
        let reachable := Location.reachable "kube" "pod" "/app"
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let waiting := settledBut (fedTo driver (presses "C-p 1")).1 Workspace.markerJob
            let moved := settledOn (pressedOn waiting "C-e k") []
            let asked := pressedOn moved "C-k i"
            !reachable.can.runCommands &&
              (shownWorkspace moved).map (·.1.location) == some reachable &&
              shownOnModes moved == some #[{ mode := "t-mode", root := "/t" }] &&
              startedCount asked (tList "/t") == 0 &&
              !(asked.pending.any (·.name == Compile.listJob)) &&
              asked.loop.state.prompt.isNone &&
              (echoOf asked).map (·.endsWith "where commands cannot run") == some true },
    { name :=
        "a listing order and an entry cross as arguments and as a tree and back, and arguments that are no order read as none; the listing job started with them fails"
      run :=
        let stamp : File.Stamp := { seconds := -3, nanoseconds := 4, size := 5 }
        let orders : List Compile.ListOrder :=
          [{ place := some (.local "/t"), mode := "t-mode", root := "/t/a", generation := 2,
             markers := #["t.toml", "u.toml"], held := some #[some stamp, none],
             program := "t-list", programArguments := #["a", "b c"] },
            { place := none, mode := "m", root := "/x", generation := 0, markers := #[],
              held := none
              program := "p", programArguments := #[] },
            { place := some (.reachable "kube" "pod" "/app"), mode := "m", root := "/app",
              generation := 1, markers := #["m.toml"], held := none, program := "p"
              programArguments := #["q"] }]
        let entries : Array Compile.Listing.Entry :=
          #[{ mode := "t-mode", root := "/t", generation := 1, stamps := #[some stamp, none],
              outcome :=
                .listed
                  #[{ name := "a", line := "x" },
                    { name := "b", line := "y", directory := some "s" }] },
            { mode := "u", root := "/u", generation := 0, stamps := #[], outcome := .failed "why" }]
        pure
          (orders.all (fun order => Compile.ListOrder.ofArguments? order.arguments == some order) &&
            [[], [.str "unscoped", .str "m"],
                  [.str "unscoped", .str "m", .str "/x", .nat 0, .nat 1],
                  [.str "workspace", .str "/t", .str "m", .str "/x", .nat 0, .nat 0, .bool false,
                    .str "p"]].all
              (Compile.ListOrder.ofArguments? · == none) &&
            Compile.listingStore.decode (Compile.listingStore.encode entries) == some entries &&
            Compile.listingStore.name == "compile-listings" &&
            ((Compile.listWork [.nat 1] ()).runModel {}).1 matches .failed _) }]

end ModelTest
