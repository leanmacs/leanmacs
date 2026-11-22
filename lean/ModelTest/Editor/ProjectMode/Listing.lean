import Editor.Config.Registry
import Editor.File
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Model
import Editor.ProjectMode
import Editor.ProjectMode.Listing
import Editor.State
import Editor.Store
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Hosted
import Editor.Test.Keys
import Editor.Test.Listing
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Opener
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.Workspace
import FilesApi
import FilesApiTest.Fake
import ModelTest.Check

/-!
# Model tests: `Editor/ProjectMode/Listing.lean`

The model tests of `Editor/ProjectMode/Listing.lean`: `listingChecks` and
`turnOnModesChecks`. The root module `ModelTest` runs them; its module doc
says what each shows.

The listing is a core module, so these checks name core modules only: their
host is handed the kit's opener's commands and jobs, with the job
`compile-list`, and no package outside the core. Where the workspace finds a
file's workspace and its marker search turns modes on, they run the kit's
stand-ins written over the core's API (`listingOpened`, `kubeOpened`,
`Editor/Test/Listing.lean`: the kit's `attachAt` and
`Workspace.turnOnModes`, as the kit's `markedPackage` does);
that the workspace's marker search starts a listing after it is held by the
workspace's `workspaceModesChecks`. What the compile mode makes of a listing, the
commands `compile-command` offers and runs, is checked with the compile mode
(`CompileTest.compileListedChecks`, `CompileTest.compileOfferChecks`).
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The bindings of the listing checks: the keys that open the listing
checks' files (`listingFiles`). -/
def listingBindings : List (String × Invocation) :=
  listingFiles.map fun (key, path) => (key, opens path)

/-- The jobs of the listing checks: the kit's opener's, whose load runs
`opened`, `listingOpened` by default, and the listing job. -/
def listingJobs (opened : BufferId → System.FilePath → EditorM Unit := listingOpened)
    (name : String) : Option (List Argument → Work) :=
  if name == Compile.listJob then some Compile.listWork else Opener.jobsWith opened (name := name)

/-- A driver of the listing checks over `registry`, by default `t-mode`
registered in config (`listingRegistry`), whose opener runs `opened`
(`listingOpened` by default): the files and the listings' runs of the listing
checks (`listingRuns`), with the kit's opener's commands, and the loop told
`registry`'s contributions; `none` if making the state was refused. -/
def listingDriver (registry : Config.Registry := listingRegistry)
    (opened : BufferId → System.FilePath → EditorM Unit := listingOpened) : Option TestDriver :=
  let keys := dispatchKeys listingBindings Opener.commands
  let keys := toldHook keys registry
  (Loop.Driver.over keys (listingJobs opened) (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver => { driver with jobs := listingRuns }

/-- `driver` in which `t-list` cannot be run in `/t2`: the program is not
found. -/
def listingRefusedIn (driver : TestDriver) : TestDriver :=
  withScript driver { command := tList "/t2", reply := .error (.notFound "t-list") }

/-- The on-modes the turning checks hand `Workspace.turnOnModes`, nearest
first: `t-mode` at `/t`, which has a listing, and `u-mode` at `/`, which has
no contribution. -/
def turnedOn : Array Workspace.OnMode :=
  #[{ mode := "t-mode", root := "/t" }, { mode := "u-mode", root := "/" }]

/-- A driver of the listing checks (`listingDriver`'s keys, jobs and world)
in which `C-p t` turns `on` on in the window's buffer through the core's
`Workspace.turnOnModes`. -/
def turningDriver (on : Array Workspace.OnMode) : Option TestDriver :=
  let turn : Dispatched := fun call => do
    Workspace.turnOnModes call.target.window.buffer on
    return none
  let keys :=
    dispatchKeys (listingBindings ++ [("C-p t", invoke "turn-on")])
      (Opener.commands ++ [("turn-on", turn)])
  let keys := toldHook keys listingRegistry
  (Loop.Driver.over keys (listingJobs) (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := listingRuns }

/-- The checks of turning a buffer's on-modes on, the core's
(`Workspace.turnOnModes`, `Workspace.onModesOf`,
`Editor/ProjectMode/Listing.lean`), on the listing checks' driver. -/
def turnOnModesChecks : List Check :=
  [{  name :=
        "turning on-modes on keeps them as the buffer's marker-modes value, nearest first, which onModesOf reads back, adds each as a minor mode so the nearest is first, and checks the listing of each that has one in the buffer's place"
      run :=
        pure <|
          match turningDriver turnedOn with
          | none => false
          | some driver =>
            let (turned, names) := settledNames driver "C-p t"
            Workspace.onModesOf turned.loop.state ⟨0⟩ == turnedOn &&
              ((turned.loop.state.buffer? ⟨0⟩).map (·.minors)) == some #["t-mode", "u-mode"] &&
              names.contains Compile.listJob &&
              startedCount turned (tList "/t") == 1 &&
              (Compile.entriesOf turned.loop.state none).size == 1 },
    { name :=
        "turning no on-mode on leaves the buffer as it was: no value, no minor mode, no listing; a buffer that keeps none has no on-modes"
      run :=
        pure <|
          match turningDriver #[] with
          | none => false
          | some driver =>
            let (turned, names) := settledNames driver "C-p t"
            Workspace.onModesOf turned.loop.state ⟨0⟩ == #[] &&
              turned.loop.state.value? ⟨0⟩ Workspace.modesLocal == none &&
              ((turned.loop.state.buffer? ⟨0⟩).map (·.minors)) == some #[] &&
              !names.contains Compile.listJob },
    { name :=
        "the kit's stand-in for modes on markers, markedPackage, turns its on-modes on in a buffer that takes in a file, at files-api's Opened hook: onModesOf reads them back, nearest first, and each is a minor mode"
      run :=
        pure <|
          let on : Array Workspace.OnMode :=
            #[{ mode := "t-mode", root := "/t" }, { mode := "u-mode", root := "/" }]
          match hostedDriver #[FilesApiTest.fake, markedPackage on] (files := commandFiles) with
          | none => false
          | some driver =>
            let opened :=
              hostedRan driver
                { command := FilesApi.openFileName,
                  arguments := [.str (inFiles "note.txt").toString] }
            shownOnModes opened == some on &&
              (showing opened).map (·.buffer.minors) == some #["t-mode", "u-mode"] },
    { name :=
        "the marker settings are the workspace settings and the config generation the loop answers, with the marker modes of the hook's contributions in the hook's order, config's before a package's; the loop's own answer holds no marker mode, and with no contribution the marker settings hold none"
      run :=
        let roots : Array Workspace.ConfigRoot := #[{ root := "/r/tools", project := some "tools" }]
        let shipping : Package :=
          { name := "shipping"
            setup :=
              compileContribution
                { mode := "a-mode", markers := #["a.toml", "a2.toml"], outermost := true } }
        let registry : Config.Registry :=
          {
            hostedRegistry #[shipping]
              (compileContribution { mode := "b-mode", markers := #["b.toml"] }) with
            workspaceRoots := roots, generation := 3 }
        let plain : Config.Registry :=
          { hostedRegistry #[] with
            workspaceRoots := roots, generation := 3 }
        pure
          (hostedAsked registry Workspace.markerSettings ==
              some ({
                    roots
                    markerModes :=
                      #[{ mode := "b-mode", markers := #["b.toml"] },
                        { mode := "a-mode", markers := #["a.toml", "a2.toml"],
                          outermost := true }] },
                  3) &&
            hostedAsked registry (RegistryRequest.ask .workspaceSettings) == some ({ roots }, 3) &&
            hostedAsked plain Workspace.markerSettings == some ({ roots }, 3)) }]

/-- The checks of a contribution's computed commands
(`Editor/ProjectMode/Listing.lean`), on the loop's driver over the editor's
models, the job model and the process model, with `t-mode`. -/
def listingChecks : List Check :=
  [{  name :=
        "turning t-mode on runs its listing t-list in its root once; a second file under the root starts compile-list again and runs nothing"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let (first, names) := settledNames driver "C-p 1"
            let (second, again) := settledNames first "C-p 2"
            shownOnModes first == some #[{ mode := "t-mode", root := "/t" }] &&
              names.contains Compile.listJob &&
              startedCount first (tList "/t") == 1 &&
              again.contains Compile.listJob &&
              startedCount second (tList "/t") == 1 &&
              (Compile.entriesOf second.loop.state (some (.local "/t"))).size == 1 },
    { name :=
        "a listing that fails lists no command, keeps why it failed and says it once, with its first line of standard error: a second file under the root starts the job again, which runs nothing"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 3"
            let (again, names) := settledNames opened "C-p 5"
            let why := "t-list exited with status 3: t-list: broken"
            echoOf opened == some s!"t-mode in /t2: {why}" &&
              (Compile.entriesOf opened.loop.state (some (.local "/t2"))).map (·.outcome) ==
                #[.failed why] &&
              (Compile.listedCommands opened.loop.state (some (.local "/t2")) "t-mode"
                  "/t2").isEmpty &&
              names.contains Compile.listJob &&
              startedCount again (tList "/t2") == 1 &&
              Compile.entriesOf again.loop.state (some (.local "/t2")) ==
                Compile.entriesOf opened.loop.state (some (.local "/t2")) },
    { name :=
        "a listing that could not be run, as mise is not found by an editor started from the Finder, lists no command and says why once"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter (listingRefusedIn driver) "C-p 3"
            let again := settledAfter opened "C-p 5"
            echoOf opened ==
                some
                  "t-mode in /t2: t-list could not be run: the program or the directory is not there: t-list" &&
              (Compile.listedCommands opened.loop.state (some (.local "/t2")) "t-mode"
                  "/t2").isEmpty &&
              startedCount again (tList "/t2") == 1 },
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
            let dropped := { waiting with keys := toldHook waiting.keys {} }
            let listed :=
              match dropped.pending.find? (·.name == Compile.listJob) with
              | some job => (dropped.finish job.id).1
              | none => dropped
            startedCount listed (tList "/t") == 1 &&
              (Compile.entriesOf listed.loop.state (some (.local "/t"))).isEmpty },
    { name :=
        "a file in a directory holding t.toml and no repository has t-mode on there: its listing runs there once and what it lists is kept in the unscoped store"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 4"
            (shownWorkspace opened).isNone &&
              shownOnModes opened == some #[{ mode := "t-mode", root := "/u" }] &&
              startedCount opened (tList "/u") == 1 &&
              (Compile.entriesOf opened.loop.state none).map
                  (fun entry => (entry.mode, entry.root.toString)) ==
                #[("t-mode", "/u")] &&
              (Compile.listedCommands opened.loop.state none "t-mode" "/u").map (·.name) ==
                #["u-only"] },
    { name :=
        "in a workspace whose location cannot run commands no listing is started when t-mode turns on"
      run :=
        let reachable := Location.reachable "kube" "pod" "/app"
        pure <|
          match listingDriver (opened := kubeOpened) with
          | none => false
          | some driver =>
            let moved := settledAfter driver "C-p 1"
            !reachable.can.runCommands &&
              (shownWorkspace moved).map (·.1.location) == some reachable &&
              shownOnModes moved == some #[{ mode := "t-mode", root := "/t" }] &&
              startedCount moved (tList "/t") == 0 &&
              !(moved.pending.any (·.name == Compile.listJob)) &&
              (Compile.entriesOf moved.loop.state (some reachable)).isEmpty },
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
