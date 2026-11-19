import Editor.Api
import Editor.Command.Call
import Editor.Completion.Filtering
import Editor.Completion.Later
import Editor.Files
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.Process
import Editor.Process.Model
import Editor.State
import Editor.Workspace
import Editor.Workspace.Attach
import Editor.Workspace.FindFile
import Editor.Workspace.Lister
import Editor.Workspace.Model
import ModelTest.Check
import ModelTest.Support.Candidates
import ModelTest.Support.Driver
import ModelTest.Support.Files
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Prompts
import ModelTest.Support.Workspace

/-!
# Model tests: `Editor/Workspace/FindFile.lean`

The model tests of `Editor/Workspace/FindFile.lean`: `findFileChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

namespace FindFileTest

/-- `texts` as NUL-ended records. -/
def nul (texts : List String) : ByteArray :=
  texts.foldl (fun bytes text => (bytes ++ text.toUTF8).push 0) .empty

/-- A run that exits 0, writing `texts` as NUL-ended records. -/
def ran (texts : List String) : Except ProcessError Process.Ran :=
  .ok { exit := .code 0, stdout := nul texts, stderr := .empty }

/-- Git's lister, as the driver's git is `git`. -/
def git : Workspace.Lister :=
  .git "git"

/-- The lister config declares for the root `/w`. -/
def rootDeclared : Workspace.DeclaredLister :=
  { scope := .root "/w", program := "fd", arguments := #["-0", "--type", "f"], nul := true }

/-- The lister config declares for the project of `/r` and `/w`. -/
def projectDeclared : Workspace.DeclaredLister :=
  { scope := .project (.remote "github.com/o/r"), program := "rg",
    arguments := #["--files", "--null"]
    nul := true }

/-- The scripts of `lister` at `root`: it lists `records`, and the filter
answers each text of `filters` with its records. -/
def listing (lister : Workspace.Lister) (root : System.FilePath) (records : List String)
    (filters : List (String × List String)) : Array Process.Script :=
  #[{ command := lister.command root, reply := ran records }] ++
    (filters.map fun (text, matched) =>
        ({  command := (Workspace.FindFile.filtering lister root).filterFor text
            reply := ran matched } : Process.Script)).toArray

/-- What git lists in `/w`. -/
def wRecords : List String :=
  ["src/w.lean", "src/b.lean", "only-w"]

/-- What git lists in `/r`. -/
def rRecords : List String :=
  ["src/a.lean", "only-r"]

/-- The process scripts of the checks: each root's lister and its filters. -/
def scripts : Array Process.Script :=
  listing git "/w" wRecords [("", wRecords), ("b", ["src/b.lean"]), ("bc", [])] ++
    listing git "/r" rRecords [("", rRecords)] ++
    listing .fallback "/x" ["./a.txt", "./d/e.txt"] [("", ["./a.txt", "./d/e.txt"])] ++
    listing .fallback "/" ["./etc/hosts"] [("", ["./etc/hosts"])] ++
    listing .fallback "/m" ["./src/a.txt", "./mise.toml"] [("", ["./src/a.txt", "./mise.toml"])] ++
    -- Config's listers: their filters' command lines are git's at the
    -- same root, so what the filter is fed tells them apart.
    listing (.ofDeclared rootDeclared) "/w" ["src/fd-w"] [] ++
    listing (.ofDeclared projectDeclared) "/w" ["proj-w"] [] ++
    listing (.ofDeclared projectDeclared) "/r" ["proj-r"] []

/-- The location of the workspace the checks register, which cannot read
files. -/
def remote : Location :=
  .reachable "ssh" "host" "/srv/r"

/-- The jobs of the checks: the workspace driver's, and the finder's
source's job, `workspace-files`. -/
def jobs (name : String) : Option (List Argument → Work) :=
  if name == Workspace.FindFile.job then some (Completion.answering Workspace.FindFile.answer)
  else workspaceJobs name

/-- A job that does nothing, in place of the source's, for the checks that
show no step runs the lister or the filter. -/
def idle (name : String) : Option (List Argument → Work) :=
  if name == Workspace.FindFile.job then some fun _ => Work.of (fun _ => pure ()) fun _ => pure ()
  else workspaceJobs name

/-- The commands of the checks: the workspace driver's, the finder, the
minibuffer's next, the candidate checks' accept and self-insert, `register`,
which registers `remote` as a workspace of the project on `main`, and
`strand`, which registers it and gives it to the window's buffer. -/
def commands : List (String × Dispatched) :=
  let registers : EditorM Unit := discard <| Workspace.register remote workspaceOrigin (some "main")
  workspaceCommands ++
    [(Workspace.FindFile.name, fun call => do
        Workspace.FindFile.command call
        return none),
      (Minibuffer.nextName, fun call => do
        Minibuffer.nextCommand call
        return none),
      ("register", fun _ => do
        registers
        return none),
      ("strand", fun call => do
        registers
        Workspace.setBufferWorkspace call.target.window.buffer remote
        return none)] ++
    candidateCommands

/-- The bindings of the checks: the workspace driver's, `C-o f` the finder,
`C-o j` the next candidate, `C-o y` accept, `C-o r` and `C-o s` register
and strand, `C-o g` the finder rooted at `remote`, `C-o u` at a local
location the table does not know, and `C-o m` opens `/m/src/a.txt`. -/
def bindings : List (String × Invocation) :=
  workspaceBindings ++
    [("C-o f", invoke Workspace.FindFile.name), ("C-o j", invoke Minibuffer.nextName),
      ("C-o y", invoke "accept"), ("C-o r", invoke "register"), ("C-o s", invoke "strand"),
      ("C-o g", { command := Workspace.FindFile.name, arguments := remote.arguments }),
      ("C-o u",
        { command := Workspace.FindFile.name, arguments := (Location.local "/nowhere").arguments }),
      ("C-o m", opens "/m/src/a.txt")]

/-- The driver of the checks over `world`, its loop told of config's
`listers`, its jobs `registered` and its commands `commands`, with the
scripts and two more files, `/w/src/w.lean` and `/m/src/a.txt`; `none` if
making the state was refused. -/
def driver (listers : Array Workspace.DeclaredLister := #[])
    (world : Workspace.World := workspaceWorld)
    (registered : String → Option (List Argument → Work) := jobs)
    (commands : List (String × Dispatched) := commands) : Option TestDriver :=
  let keys := dispatchKeys bindings commands
  (workspaceDriver registered
        { keys with registered := { keys.registered with workspaceListers := listers } } (world :=
        world)).map
    fun driver =>
    { driver with
      jobs :=
        { driver.jobs with
          files :=
            (driver.jobs.files.withFile "/w/src/w.lean" "ww".toUTF8).withFile "/m/src/a.txt"
              "m".toUTF8
          processes :=
            { driver.jobs.processes with scripts := driver.jobs.processes.scripts ++ scripts } } }

/-- `driver` once every post it holds has arrived and every job it holds has
finished, and every job those start, oldest first. -/
def drained (driver : TestDriver) : TestDriver :=
  (List.range 12).foldl
    (fun driver _ =>
      match driver.posting[0]? with
      | some job => (driver.posted job.id).1
      | none =>
        match driver.pending[0]? with
        | some job => (driver.finish job.id).1
        | none => driver)
    driver

/-- `driver` once `keys` are pressed, and drained. -/
def drainedAfter (driver : TestDriver) (keys : String) : TestDriver :=
  drained (fedTo driver (presses keys)).1

/-- The texts the prompt open in `driver` lists. -/
def listedTexts (driver : TestDriver) : Option (Array String) :=
  (candidatesOf driver).map (·.listed.map (·.text))

/-- The label of the prompt open in `driver`. -/
def labelOf (driver : TestDriver) : Option String :=
  driver.loop.state.prompt.map (·.label)

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

end FindFileTest

open FindFileTest in
/-- The checks of `find-file-in-workspace` (`Editor/Workspace/FindFile.lean`),
on the loop's driver over the editor's models, the job model and the
workspace driver's world, its listers and filters scripted by their exact
command lines. -/
def findFileChecks : List Check :=
  [{  name :=
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
          let world := { workspaceWorld with markers := workspaceWorld.markers.push "/m/mise.toml" }
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
                some { command := Workspace.FindFile.name, arguments := [.bool true, .str "/w"] } &&
              accepted.loop.state.prompt.isNone &&
              accepted.pending.any (·.name == Files.loadJob) &&
              (heldFile settled).map (·.path) == some "/w/src/w.lean" },
    { name :=
        "criterion 4 on the models: the accepted file is opened through the name open-file, so a command registered in its place, as config's would be, is handed the path under the root"
      run :=
        pure <|
          let standIn : Dispatched := fun call => do
            message s!"stand-in {call.arguments.map argumentText}"
            return none
          match driver (commands := (Files.openName, standIn) :: commands) with
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
            | _ => false }]

end ModelTest
