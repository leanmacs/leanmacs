import Editor.Api
import Editor.Command.Call
import Editor.Completion.Filtering
import Editor.Completion.Later
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.State
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Opener
import Editor.Test.Prompts
import Editor.Test.Sources
import Editor.Test.Workspace
import Editor.Workspace
import EnvironmentApi
import EnvironmentApiTest.Fake
import EnvironmentApiTest.Model
import FilesApi
import FilesApiTest.Fake
import Workspace.FindFile
import Workspace.Lister
import WorkspaceTest.Check
import WorkspaceTest.Finder.Model
import WorkspaceTest.Support.FindFile

/-!
# Model tests: `Workspace/FindFile.lean`

The model tests of `Workspace/FindFile.lean`: `findFileChecks`. The test
driver's root, `WorkspaceTest/Model.lean`, runs them; its module doc says
what each shows.
-/

namespace WorkspaceTest

open Editor
open Editor.Test

namespace FindFileTest

/-- A job that does nothing, in place of the source's, for the checks that
show no step runs the lister or the filter. -/
def idle (name : String) : Option (List Argument → Work) :=
  if name == Workspace.FindFile.job then some fun _ => Work.of (fun _ => pure ()) fun _ => pure ()
  else workspaceJobsWith FilesApiTest.jobs name

/-- The lister the prompt open in `driver` was asked with: its context. -/
def listerOf (driver : TestDriver) : Option Workspace.Lister :=
  (candidatesOf driver).bind fun candidates => Workspace.Lister.ofArguments? candidates.context

/-- The commands `driver` started after the first `before`. -/
def startedAfter (driver : TestDriver) (before : Nat) : Array Process.Command :=
  driver.jobs.processes.started.extract before driver.jobs.processes.started.size

/-- The commands `driver` started that list a workspace's files or filter
them: none of the finder's git runs. -/
def listings (driver : TestDriver) : Array Process.Command :=
  driver.jobs.processes.started.filter fun command =>
    !command.arguments.contains "rev-parse" && !command.arguments.contains "remote"

/-- The start of the source's job a step handed back, as its order. -/
def orderOf (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Option Completion.Order :=
  ((steps.back?.join).bind (·.starts.find? (·.name == Workspace.FindFile.job))).bind fun start =>
    Completion.Order.ofArguments? start.arguments

/-- What `driver` says once `keys` are pressed after the file `/w/src/b.lean`
opened: the echo area, whether a prompt is open, how many jobs it holds,
and whether it started no process for them. -/
def refused (driver : TestDriver) (keys : String) : String × Bool × Nat × Bool :=
  let opened := settledAfter driver "C-o w"
  let before := opened.jobs.processes.started.size
  let after := drainedAfter opened keys
  (after.loop.state.echo, after.loop.state.prompt.isSome, after.pending.size + after.posting.size,
    after.jobs.processes.started.size == before)

/-- The fake base's `PATH` in the layered checks: Homebrew's directory
first. The fakes of `environment-api` (`EnvironmentApiTest.fakeBase`,
`EnvironmentApiTest.fakeDirectory`) stand for the default set's
`login-shell` base and `mise` source, which this package may not import.
The default set's choice of those is pinned by `LoginShellTest`,
`ConfigTest.environmentHostChecks` and the headless fixture
`tests/headless/environment-sources`; the order of the lookups and what each
runs over by the core's `ModelTest.environmentLayerChecks`; that a bare
`fzf` is then found on the `PATH` a child is given by the process contracts
(`JobContract.processProperties`, and `ENVIRONMENT` in
`crates/editor-process/src/contract.rs`). -/
def basePath : String :=
  "/opt/homebrew/bin:/usr/bin:/bin"

/-- What the fake directory source, standing for mise, prints in `/w`: its
own entry, then the base's `PATH`. -/
def toolsPath : String :=
  "/w/.tools/bin:" ++ basePath

/-- The home directory of the window mode in the layered checks, where the
fake base is looked up, as login-shell looks its base up there. -/
def home : System.FilePath :=
  "/home/u"

/-- The mode of the layered checks: the window mode, with `home`. -/
def windowMode : Process.Host :=
  .window (some home)

/-- The lookup the fake base, `EnvironmentApiTest.fakeBase` in `home`, runs
in the window mode: built from the fake itself, over no variables. -/
def baseLookup : Option Process.Command :=
  match (EnvironmentApiTest.fakeBase (directory := home)).base windowMode with
  | .lookup resolved directory =>
    match resolved.program with
    | .at path => some (resolved.command path directory {})
    | _ => none
  | .inherited => none

/-- The lookup `EnvironmentApiTest.fakeDirectory` runs in `/w` over
`below`: built from the fake itself. -/
def directoryLookup (below : Process.Environment) : Option Process.Command :=
  (EnvironmentApiTest.fakeDirectory.source windowMode).bind fun resolved =>
    match resolved.program with
    | .at path => some (resolved.command path "/w" below)
    | _ => none

/-- `command` with `path` as its `PATH` layer, under its own environment, as
the core's `Environment.over` puts it: so git's lister keeps its own
variables under the layer. -/
def preparedWith (path : String) (command : Process.Command) : Process.Command :=
  { command with environment := Process.Environment.over #[("PATH", path)] command.environment }

/-- The finder's filter over git's lister at `/w`, for the empty text. -/
def wFilter : Process.Command :=
  (Workspace.FindFile.filtering git "/w").filterFor ""

/-- The scripts of a layered scene whose topmost `PATH` is `path`: the fake
base's lookup printing `basePath`, the fake directory source's (when
`directory`) printing `toolsPath`, and the finder's lister and filter with
`path` as their layer, each answering `wRecords`. -/
def layeredScripts (path : String) (directory : Bool) : Array Process.Script :=
  let lookups : Array Process.Script :=
    (baseLookup.map fun command =>
            #[{ command,
                reply :=
                  EnvironmentApiTest.printed
                    (EnvironmentApiTest.linesOf #[("PATH", basePath)]) }]).getD
        #[] ++
      if directory then
        ((directoryLookup { set := #[("PATH", basePath)] }).map fun command =>
              #[{ command,
                  reply :=
                    EnvironmentApiTest.printed
                      (EnvironmentApiTest.linesOf #[("PATH", toolsPath)]) }]).getD
          #[]
      else #[]
  lookups ++
    #[{ command := preparedWith path (git.command "/w"), reply := ran wRecords },
      { command := preparedWith path wFilter, reply := ran wRecords }]

/-- `driver` reloaded with the fake base and `directories` installed in the
window mode, as the host installs a registry (`EnvironmentApi.registered`),
and `scripts` added. It is applied after the workspace is attached, so the
attach's git runs stay on the driver's own scripts and only the finder's
job runs over the layers. -/
def withLayers (driver : TestDriver) (directories : Array EnvironmentApi.DirectorySource)
    (scripts : Array Process.Script) : TestDriver :=
  { driver with
    jobs :=
      { driver.jobs with
        environments :=
          ({ host := windowMode } : Process.Environments).install
            (EnvironmentApi.registered directories
                #[EnvironmentApiTest.fakeBase (directory := home)] "fake-base").1
        processes :=
          { driver.jobs.processes with scripts := driver.jobs.processes.scripts ++ scripts } } }

/-- The finder's own children among `commands`: its lister, git, and its
filter, fzf; none of the lookups. -/
def finderChildren (commands : Array Process.Command) : Array Process.Command :=
  commands.filter fun command => command.program == "git" || command.program == "fzf"

/-- The `PATH` `command` is started with, split into its entries. -/
def pathEntries (command : Process.Command) : Option (List String) :=
  (command.environment.set.find? (·.1 == "PATH")).map fun (_, value) => value.splitOn ":"

/-- `driver` with no script for the finder's filter at `/w`, whatever its
text: on the process model a command with no script is refused `notFound`,
which stands for a bare `fzf` on no directory of the `PATH` it is started
with. The real refusal is the process contracts' (`ENVIRONMENT` in
`crates/editor-process/src/contract.rs`, `JobContract.processProperties`). -/
def unfiltered (driver : TestDriver) : TestDriver :=
  let filter := (Workspace.FindFile.filtering git "/w").filter
  { driver with
    jobs :=
      { driver.jobs with
        processes :=
          { driver.jobs.processes with
            scripts :=
              driver.jobs.processes.scripts.filter fun script =>
                !(script.command.program == filter.program &&
                    script.command.directory == filter.directory &&
                    script.command.arguments.pop == filter.arguments) } } }

end FindFileTest

open FindFileTest in
/-- The checks of `find-file-in-workspace` (`Workspace/FindFile.lean`),
on the loop's driver over the editor's models, the job model and the
workspace driver's world, its listers and filters scripted by their exact
command lines. -/
def findFileChecks : List Check :=
  [{    name :=
          "the text after the location is typed into the finder's input, and the list opens matched against it"
        run :=
          pure <|
            match driver with
            | none => false
            | some driver =>
              let typed := drainedAfter (settledAfter driver "C-o w") "C-o t"
              labelOf typed == some "Find file in r@feature: " &&
                minibufferText typed == some "b" &&
                listedTexts typed == some #["src/b.lean"] },
      { name := "the typed text travels as one argument after the location, none when it is empty"
        run :=
          pure
            ((["", "b", "src/fin"].all fun text =>
                Workspace.FindFile.typedOf (Workspace.FindFile.typedArguments text) == text) &&
              Workspace.FindFile.typedArguments "" == [] &&
              Workspace.FindFile.typedArguments "b" == [.str "b"]) },
      { name :=
          "criterion 1 on the models: in a buffer of /w, find-file-in-workspace lists what the filter answers for the typed text fed git ls-files -z --cached --others --exclude-standard run at /w, and nothing of /r, the other workspace of the project the table holds; no lister runs anywhere but /w"
        run :=
          pure <|
            match driver with
            | none => false
            | some driver =>
              let opened := settledAfter (settledAfter driver "C-o a") "C-o w"
              let before := opened.jobs.processes.started.size
              let asked := drainedAfter opened "C-o f"
              let typed := drainedAfter asked "b"
              let filter := (Workspace.FindFile.filtering git "/w").filterFor "b"
              let ran := startedAfter typed before
              listedTexts asked == some #["src/w.lean", "src/b.lean", "only-w"] &&
                listedTexts typed == some #["src/b.lean"] &&
                ran.all (·.directory == "/w") &&
                ran.filter (·.program == "git") == #[git.command "/w", git.command "/w"] &&
                ran.back? == some filter &&
                typed.jobs.processes.fed.back? == some (filter, nul wRecords) &&
                typed.loop.state.workspaces.workspaces.size == 2 },
      { name :=
          "criterion 2 on the models: config's lister for the root /w runs at /w in place of git's, while /r still lists with git; config's lister for the project runs at /r and at /w; the prompt's context is the lister of origin config"
        run :=
          pure <|
            let first (listers : Array Workspace.DeclaredLister) (opens : String) :
              Option (Array Process.Command × Option ByteArray × Option Workspace.Lister) := do
              let driver ← driver listers
              let opened := settledAfter driver opens
              let asked := drainedAfter opened "C-o f"
              return (listings asked, asked.jobs.processes.fed.back?.map (·.2), listerOf asked)
            let fd := Workspace.Lister.ofDeclared rootDeclared
            let rg := Workspace.Lister.ofDeclared projectDeclared
            first #[rootDeclared] "C-o w" ==
                some
                  (#[fd.command "/w", (Workspace.FindFile.filtering fd "/w").filterFor ""],
                    some (nul ["src/fd-w"]), some fd) &&
              (first #[rootDeclared] "C-o a").map (fun (ran, fed, _) => (ran.take 1, fed)) ==
                some (#[git.command "/r"], some (nul rRecords)) &&
              (first #[projectDeclared] "C-o a").map (fun (ran, fed, _) => (ran.take 1, fed)) ==
                some (#[rg.command "/r"], some (nul ["proj-r"])) &&
              (first #[projectDeclared] "C-o w").map
                  (fun (ran, fed, lister) => (ran.take 1, fed, lister.map (·.origin))) ==
                some (#[rg.command "/w"], some (nul ["proj-w"]), some .config) },
      { name :=
          "criterion 3 on the models: a workspace with no repository, found by its marker /m/mise.toml, is listed with find . -type f -not -path */.git/* -print0 at /m, its records listed without ./, and the prompt's context is the fallback"
        run :=
          pure <|
            let world :=
              { workspaceWorld with markers := workspaceWorld.markers.push "/m/mise.toml" }
            match driver (world := world) with
            | none => false
            | some driver =>
              let opened := settledAfter driver "C-o m"
              let asked := drainedAfter opened "C-o f"
              listings asked ==
                  #[Workspace.Lister.fallback.command "/m",
                    (Workspace.FindFile.filtering .fallback "/m").filterFor ""] &&
                listedTexts asked == some #["src/a.txt", "mise.toml"] &&
                (listerOf asked).map (·.origin) == some .fallback &&
                labelOf asked == some "Find file in m@m: " },
      { name :=
          "criterion 4 on the models: choosing the first candidate and accepting runs find-file-in-workspace with it, true and the root; the file /w/src/w.lean is loaded and the focused window shows it"
        run :=
          pure <|
            match driver with
            | none => false
            | some driver =>
              let opened := settledAfter driver "C-o w"
              let asked := drainedAfter opened "C-o f"
              let (accepted, _) := fedTo asked (presses "C-o j C-o y")
              let settled := drained accepted
              (asked.loop.state.prompt.map (·.continuation)) ==
                  some
                    { command := Workspace.FindFile.name, arguments := [.bool true, .str "/w"] } &&
                accepted.loop.state.prompt.isNone &&
                accepted.pending.any (·.name == Opener.loadJob) &&
                (heldFile settled).map (·.path) == some "/w/src/w.lean" },
      { name :=
          "criterion 4 on the models: the accepted file is opened through the name open-file, so a command registered in its place, as config's would be, is handed the path under the root"
        run :=
          pure <|
            let standIn : Dispatched := fun call => do
              message s!"stand-in {call.arguments.map argumentText}"
              return none
            match driver (commands := (FilesApi.openFileName, standIn) :: commands) with
            | none => false
            | some driver =>
              -- The stand-in opens nothing, so the window's buffer has no
              -- workspace: the finder searches the editor's working
              -- directory, `/`.
              let asked := drainedAfter driver "C-o f"
              let accepted := drainedAfter asked "C-o j C-o y"
              listedTexts asked == some #["etc/hosts"] &&
                accepted.loop.state.echo == s!"stand-in {[argumentText (.str "/etc/hosts")]}" },
      { name :=
          "a typed answer that is absolute is opened as it is, not under the root: accepting /etc typed into the finder over /w, and into the finder over /, whose root ends in a separator, hands the stand-in open-file /etc"
        run :=
          pure <|
            -- The stand-in says what it is handed, then opens it, so `C-o w`
            -- still gives the window's buffer the workspace /w.
            let standIn : Dispatched := fun call => do
              message s!"stand-in {call.arguments.map argumentText}"
              Opener.openCommand call
              return none
            match driver (commands := (FilesApi.openFileName, standIn) :: commands) with
            | none => false
            | some driver =>
              let accepted (asked : TestDriver) : TestDriver :=
                (fedTo asked (presses "/ e t c C-o y")).1
              let overW := drainedAfter (settledAfter driver "C-o w") "C-o f"
              -- A buffer with no file: the finder searches the editor's
              -- working directory, `/`.
              let overRoot := drainedAfter driver "C-o f"
              let said := s!"stand-in {[argumentText (.str "/etc")]}"
              labelOf overW == some "Find file in r@feature: " &&
                labelOf overRoot == some "Find file in /: " &&
                (accepted overW).loop.state.prompt.isNone &&
                (accepted overW).loop.state.echo == said &&
                (accepted overRoot).loop.state.echo == said },
      { name :=
          "a prompt the finder cannot open is said in the echo area, naming the command and why: asked again while its own prompt is open, it is refused as a prompt open already, and that prompt stays"
        run :=
          pure <|
            match driver with
            | none => false
            | some driver =>
              let asked := drainedAfter (settledAfter driver "C-o w") "C-o f"
              let (again, _) := fedTo asked (presses "C-o f")
              match asked.loop.state.minibufferView? with
              | none => false
              | some view =>
                again.loop.state.echo ==
                    s!"{Workspace.FindFile.name}: {(PromptRefusal.alreadyOpen view).describe}" &&
                  labelOf again == some "Find file in r@feature: " },
      { name :=
          "criterion 5 on the models: the prompt's label names the workspace searched, Find file in r@feature: in /w and Find file in r@main: in /r"
        run :=
          pure <|
            match driver with
            | none => false
            | some driver =>
              labelOf (drainedAfter (settledAfter driver "C-o w") "C-o f") ==
                  some "Find file in r@feature: " &&
                labelOf (drainedAfter (settledAfter driver "C-o a") "C-o f") ==
                  some "Find file in r@main: " },
      { name :=
          "criterion 6 on the models: in a buffer with no workspace the finder lists the files under its file's directory, /x, with the fallback; in one with no file, under the editor's working directory"
        run :=
          pure <|
            match driver with
            | none => false
            | some driver =>
              let inX := drainedAfter (settledAfter driver "C-o x") "C-o f"
              let bare := drainedAfter driver "C-o f"
              listings inX ==
                  #[Workspace.Lister.fallback.command "/x",
                    (Workspace.FindFile.filtering .fallback "/x").filterFor ""] &&
                listedTexts inX == some #["a.txt", "d/e.txt"] &&
                labelOf inX == some "Find file in /x: " &&
                (listings bare).take 1 == #[Workspace.Lister.fallback.command "/"] &&
                labelOf bare == some "Find file in /: " },
      { name :=
          "under a login-shell base and a directory source, in the window mode, find-file-in-workspace's lister and its filter fzf are started with the layered environment: with no directory source fzf's PATH is the base's; with one, fzf's PATH is the directory source's entries, then the base's; the prompt lists what the filter answered"
        run :=
          pure <|
            match driver with
            | none => false
            | some driver =>
              let scene (directories : Array EnvironmentApi.DirectorySource) (path : String) :
                TestDriver × Nat :=
                let opened := settledAfter driver "C-o w"
                let before := opened.jobs.processes.started.size
                (drainedAfter
                    (withLayers opened directories (layeredScripts path !directories.isEmpty))
                    "C-o f",
                  before)
              let (baseOnly, beforeBase) := scene #[] basePath
              let (both, beforeBoth) := scene #[EnvironmentApiTest.fakeDirectory] toolsPath
              let bothChildren := finderChildren (startedAfter both beforeBoth)
              finderChildren (startedAfter baseOnly beforeBase) ==
                  #[preparedWith basePath (git.command "/w"), preparedWith basePath wFilter] &&
                listedTexts baseOnly == some #["src/w.lean", "src/b.lean", "only-w"] &&
                baseOnly.jobs.reported.isEmpty &&
                bothChildren ==
                  #[preparedWith toolsPath (git.command "/w"), preparedWith toolsPath wFilter] &&
                (bothChildren.back?.bind pathEntries) ==
                  some ("/w/.tools/bin" :: basePath.splitOn ":") &&
                listedTexts both == some #["src/w.lean", "src/b.lean", "only-w"] &&
                both.jobs.reported.isEmpty },
      { name :=
          "with the built-in base and no fzf on the PATH the filter is started with, find-file-in-workspace says in the echo area that the filter is not there, naming the source, fzf and the lister, and lists nothing: the base's absence reads as an error, not as no files"
        run :=
          -- A filter that starts and exits 1 with an error on its standard
          -- error (a mise shim with no version set) is
          -- rdm:task/filter-failure-reads-as-no-matches, not this check.
          pure <|
            match driver with
            | none => false
            | some driver =>
              let opened := settledAfter (unfiltered driver) "C-o w"
              let before := opened.jobs.processes.started.size
              let asked := drainedAfter opened "C-o f"
              let echo := asked.loop.state.echo
              -- The fixed head of a not-found refusal, before the platform's detail.
              let notThere := (ProcessError.notFound "").describe
              echo.startsWith s!"{Workspace.FindFile.sourceName}: fzf: {notThere}" &&
                echo.endsWith s!", listing with the {git.origin.name} lister" &&
                listedTexts asked == some #[] &&
                startedAfter asked before == #[git.command "/w"] },
      { name :=
          "criterion 7 on the models: a workspace whose location cannot read files, the buffer's own or one handed as the argument, is refused with a message that names it, and no prompt opens, no job starts and no process runs; a local location the table does not know is refused too"
        run :=
          pure <|
            match driver with
            | none => false
            | some driver =>
              let said :=
                s!"{Workspace.FindFile.name}: r@main is reachable through ssh host at /srv/r, where files cannot be listed"
              refused driver "C-o s C-o f" == (said, false, 0, true) &&
                refused driver "C-o r C-o g" == (said, false, 0, true) &&
                refused driver "C-o u" ==
                  (s!"{Workspace.FindFile.name}: no workspace is known at local /nowhere", false, 0,
                    true) },
      { name :=
          "criterion 8 on the models: no key's handling waits on the lister or the filter: the steps of C-o f, b and c each return with the minibuffer showing the typed text and no process run, each handing back a start of the source's job, b's and c's after the pause, each cancelling the job before; only that job runs the lister and the filter"
        run :=
          pure <|
            match driver (registered := idle) with
            | none => false
            | some driver =>
              let opened := settledAfter driver "C-o w"
              let before := opened.jobs.processes.started
              let (asked, first) := fedTo opened (presses "C-o f")
              let (b, second) := fedTo asked (presses "b")
              let (c, third) := fedTo b (presses "c")
              match asked.loop.state.minibufferView?, orderOf third with
              | some view, some order =>
                let key := Loop.sourceKey view Workspace.FindFile.sourceName
                let cancels (steps : Array (Option (Loop.Stepped TestScheme.scheme))) :=
                  (steps.back?.join).map (·.cancels)
                let (outcome, model) :=
                  (Completion.answering Workspace.FindFile.answer (Completion.Order.arguments order)
                        ()).runModel
                    c.jobs
                let timed (order : Option Completion.Order) : Option (String × Nat × Nat) :=
                  order.map fun order => (order.query.text, order.generation, order.pause)
                c.jobs.processes.started == before && minibufferText asked == some "" &&
                  minibufferText b == some "b" &&
                  minibufferText c == some "bc" &&
                  timed (orderOf first) == some ("", 1, 0) &&
                  timed (orderOf second) == some ("b", 2, 50) &&
                  timed (some order) == some ("bc", 3, 50) &&
                  cancels second == some #[key] &&
                  cancels third == some #[key] &&
                  (outcome matches .finished _) &&
                  model.processes.started ==
                    before ++
                      #[git.command "/w", (Workspace.FindFile.filtering git "/w").filterFor "bc"]
              | _, _ => false },
      { name :=
          "the source's job asked with no lister or no root in its query fails, saying so; a lister that fails is named with its origin"
        run :=
          pure <|
            let failed (query : Completion.Query) : Option String :=
              match ((Workspace.FindFile.answer query fun _ => pure ()).runModel {}).1 with
              | .failed said => some said
              | _ => none
            let unasked := some Workspace.FindFile.noWorkspaceAsked
            let failing : Process.Script :=
              { command := git.command "/w"
                reply := .ok { exit := .code 128, stdout := .empty, stderr := "fatal: no".toUTF8 } }
            failed { text := "", view := ⟨0⟩ } == unasked &&
              failed { text := "", view := ⟨0⟩, context := git.toArguments } == unasked &&
              failed { text := "", view := ⟨0⟩, place := { directory := some "/w" } } == unasked &&
              match
                ((Workspace.FindFile.found (Workspace.FindFile.filtering git "/w") git "").runModel
                    { processes := { scripts := #[failing] } }).1 with
              | .finished (.error said) =>
                said == "git: exited with status 128: fatal: no, listing with the git lister"
              | _ => false },
      { name :=
          "a fallback find that exits 1, as it does past a directory it cannot read or an entry that vanishes, still lists the records it printed, without ./; git's lister exiting 1 still fails the source, naming its origin"
        run :=
          pure <|
            let partly : Process.Script :=
              { command := Workspace.Lister.fallback.command "/x"
                reply :=
                  .ok {
                      exit := .code 1, stdout := nul ["./a.txt", "./d/e.txt"]
                      stderr := "find: ./locked: Permission denied".toUTF8 } }
            let gitPartly : Process.Script := { partly with command := git.command "/w" }
            match driver with
            | none => false
            | some driver =>
              let driver :=
                { driver with
                  jobs :=
                    { driver.jobs with
                      processes :=
                        { driver.jobs.processes with
                          scripts := #[partly] ++ driver.jobs.processes.scripts } } }
              let inX := drainedAfter (settledAfter driver "C-o x") "C-o f"
              listedTexts inX == some #["a.txt", "d/e.txt"] &&
                match
                  ((Workspace.FindFile.found (Workspace.FindFile.filtering git "/w") git
                          "").runModel
                      { processes := { scripts := #[gitPartly] } }).1 with
                | .finished (.error said) =>
                  said ==
                    "git: exited with status 1: find: ./locked: Permission denied, listing with the git lister"
                | _ => false }] ++
    -- The completion sources' contract over the workspace's find-file source,
    -- the workspace feature's shipped value; the core's
    -- `sourceContractChecks` run it over the model and the core's sources.
    (sourceContract Workspace.FindFile.source).map fun (name, held) => { name, run := pure held }

end WorkspaceTest
