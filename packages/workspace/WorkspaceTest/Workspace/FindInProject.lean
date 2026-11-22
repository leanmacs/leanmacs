import Editor.Config.Packages
import Editor.InputScheme.Test
import Editor.Setup
import Editor.Test.Driver
import Editor.Test.Minibuffer
import Editor.Test.Sources
import Editor.Test.Workspace
import VcApi
import VcApiTest.Contract
import VcApiTest.Fake
import Workspace.Compiled
import Workspace.FindInProject
import WorkspaceTest.Check
import WorkspaceTest.Support.FindFile

/-!
# Model tests: `Workspace/FindInProject.lean`

The model tests of `Workspace/FindInProject.lean`: `findInProjectChecks`.
The test driver's root, `WorkspaceTest/Model.lean`, runs them; its module
doc says what each shows.
-/

namespace WorkspaceTest

open Editor
open Editor.Test

namespace FindInProjectTest

/-- The world of the checks: the workspace driver's, with `/u`, a worktree of
`/r`'s repository on `fix`. -/
def projectWorld : Workspace.World :=
  { workspaceWorld with
    repositories :=
      workspaceWorld.repositories.push
        { toplevel := "/u", commonDir := "/r/.git", branch := some "fix"
          origin := some workspaceOrigin }
    markers := workspaceWorld.markers.push "/u/.git" }

/-- The repository of `/r`, whose linked worktrees are `linked`. -/
def repository (linked : Array VersionControl.Model.Linked) : VersionControl.Model.Repository :=
  { VersionControlContract.clean #[("a.txt", "a\n")] with linked }

/-- `/r`'s three worktrees: `/r` on `main`, `/u` on `fix` and `/w` on
`feature`. -/
def threeLinked : Array VersionControl.Model.Linked :=
  #[{ path := "/u", branch := some "fix" }, { path := "/w", branch := some "feature" }]

/-- What the recording backend runs, through the job port, before it answers
a worktree list: a command the job model records when it starts
(`ProcessModel.started`), so a check counts how often the backend was asked
for the list, as it counted git's runs. It runs nothing real. -/
def listRun : Process.Command :=
  { program := "vc-api-fake", arguments := #["worktrees"], directory := "/r" }

/-- `vc-api`'s fake backend over `repository` (`VcApiTest.backend`) that
records each worktree list it is asked for (`listRun`), then answers it
from the model; named `git`, as the backend a consumer chooses. -/
def recordingBackend (repository : VersionControl.Model.Repository) : VcApi.Backend :=
  { name := VcApi.gitBackendName
    connect := fun git root request => do
      if request matches .worktrees then
        discard <| Process.runWithin listRun 1024 1000
      (VcApiTest.backend repository).connect git root request }

/-- A backend whose worktree list is refused, as git's that exits 128 is,
and that answers every other request from `repository`; named `git`, as the
backend a consumer chooses. -/
def refusingBackend (repository : VersionControl.Model.Repository) : VcApi.Backend :=
  { name := VcApi.gitBackendName
    connect := fun git root request =>
      match request with
      | .worktrees => pure (.error (.failed (.code 128) "fatal: not a git repository"))
      | other => (VcApiTest.backend repository).connect git root other }

/-- The jobs of the checks with `backends` registered at the version-control
backend point: the finder checks', and the picker's three, the source's job
and the accept's made as a host makes them, over the point
(`JobRegistration.workWith`) from the workspace package's registrations. -/
def projectJobsOver (backends : Array VcApi.Backend) (name : String) :
    Option (List Argument → Work) :=
  if name == Workspace.FindInProject.job || name == Workspace.FindInProject.chooseJob then
    (Workspace.package.registered.jobs.find? (·.name == name)).map
      (·.workWith (VcApiTest.backendValues backends))
  else
    if name == Workspace.FindInProject.findJob then some Workspace.FindInProject.findWork
    else FindFileTest.jobs name

/-- The jobs of the checks, with the recording backend over `repository
threeLinked` registered. -/
def projectJobs (name : String) : Option (List Argument → Work) :=
  projectJobsOver #[recordingBackend (repository threeLinked)] name

/-- The commands of the checks: the finder checks', the picker,
`register-agent`, which registers `FindFileTest.remote` as a workspace of
the project on `agent`, and the minibuffer's cancel. -/
def projectCommands : List (String × Dispatched) :=
  FindFileTest.commands ++
    [(Workspace.FindInProject.name, fun call => do
        Workspace.FindInProject.command call
        return none),
      ("register-agent", fun _ => do
        discard <| Workspace.register FindFileTest.remote workspaceOrigin (some "agent")
        return none),
      (Test.Minibuffer.cancelName, fun call => do
        Test.Minibuffer.cancel call
        return none)]

/-- The keys of the checks: the finder checks', `C-o p` the picker, `C-o k`
registers the remote workspace on `agent` (`C-o r`, the finder checks',
registers it on `main`), and `C-o q` cancels the prompt. -/
def projectBindings : List (String × Invocation) :=
  FindFileTest.bindings ++
    [("C-o p", invoke Workspace.FindInProject.name), ("C-o k", invoke "register-agent"),
      ("C-o q", invoke Test.Minibuffer.cancelName)]

/-- A job that does nothing, in place of the source's, for the check that
shows the picker's key runs no process. -/
def idle (name : String) : Option (List Argument → Work) :=
  if name == Workspace.FindInProject.job then
    some fun _ => Work.of (fun _ => pure ()) fun _ => pure ()
  else projectJobs name

/-- The driver of the checks: the finder checks' over the world `over`,
`projectWorld` by default, with the jobs `registered`, whose version-control
backend is `vc-api`'s fake of `repository linked` recording each worktree
list (`recordingBackend`), and the finder scripted for `found`, the
worktrees' directories. -/
def projectDriver (linked : Array VersionControl.Model.Linked := threeLinked)
    (found : Array System.FilePath := #["/u", "/w"]) (over : Workspace.World := projectWorld)
    (registered : String → Option (List Argument → Work) :=
      projectJobsOver #[recordingBackend (repository linked)])
    (commands : List (String × Dispatched) := projectCommands)
    (bindings : List (String × Invocation) := projectBindings) : Option TestDriver :=
  (FindFileTest.driver (world := over) (registered := registered) (commands := commands)
        (bindings := bindings)).map
    fun driver =>
    let extra :=
      #[{ command := listRun,
          reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty } }] ++
        (over.jobModel "git" found).processes.scripts
    { driver with
      jobs :=
        { driver.jobs with
          processes :=
            { driver.jobs.processes with scripts := driver.jobs.processes.scripts ++ extra } } }

/-- `driver` with its version-control backend one whose worktree list is
refused (`refusingBackend`), in place of the backend over `/r`'s three
worktrees. -/
def unlisted (driver : TestDriver) : TestDriver :=
  { driver with registered := projectJobsOver #[refusingBackend (repository threeLinked)] }

/-- How many times `driver` started `command`. -/
def runs (driver : TestDriver) (command : Process.Command) : Nat :=
  (driver.jobs.processes.started.filter (· == command)).size

/-- The annotations the prompt open in `driver` lists. -/
def listedAnnotations (driver : TestDriver) : Option (Array (Option String)) :=
  (candidatesOf driver).map (·.listed.map (·.candidate.annotation))

/-- `driver` in `/r/src/a.lean`, its workspace settled, with the picker asked
and drained. -/
def askedInR (driver : TestDriver) : TestDriver :=
  FindFileTest.drainedAfter (settledAfter driver "C-o a") "C-o p"

/-- What `driver` says once `keys` are pressed: the echo area, whether a
prompt is open, how many jobs it holds, and whether it started no
process. -/
def refused (driver : TestDriver) (keys : String) : String × Bool × Nat × Bool :=
  let before := driver.jobs.processes.started.size
  let after := FindFileTest.drainedAfter driver keys
  (after.loop.state.echo, after.loop.state.prompt.isSome, after.pending.size + after.posting.size,
    after.jobs.processes.started.size == before)

/-- The label of the prompts the escape checks ask that are not the
workspace's. -/
def escapePickLabel : String :=
  "Pick: "

/-- The commands of the escape checks: the picker checks', the escape, and
two that ask a prompt labelled `escapePickLabel` of their own, as the
candidate checks' do: `ask-plain`, with no source, and `ask-category`, for
the category `pick`, with a source of it, `pick`, as its default. -/
def escapeCommands : List (String × Dispatched) :=
  let asks (sources : List Completion.SourceRef) : Dispatched := fun _ => do
    discard <| prompt escapePickLabel { command := "picked" } "" sources
    return none
  projectCommands ++
    [(Workspace.FindInProject.escapeName, fun call => do
        Workspace.FindInProject.escapeCommand call
        return none),
      ("ask-plain", asks []),
      ("ask-category", asks [.category "pick" [.ofTexts "pick" "pick" #["wq", "w"]]])]

/-- The keys of the escape checks: the picker checks', `C-o 1` asks a prompt
with no source, `C-o 2` one of the category `pick`, and `C-o 3` runs the
escape by name, from any prompt or none. -/
def escapeBindings : List (String × Invocation) :=
  projectBindings ++
    [("C-o 1", invoke "ask-plain"), ("C-o 2", invoke "ask-category"),
      ("C-o 3", invoke Workspace.FindInProject.escapeName)]

/-- The driver of the escape checks: the picker checks', with the escape among
its commands, the active keymaps `registry` makes from the loop's state
ahead of its own, as a host's are, and fzf in `/r` scripted to match
nothing for `b`. -/
def escapeDriver (registry : Config.Registry) : Option TestDriver :=
  (projectDriver (commands := escapeCommands) (bindings := escapeBindings)).map fun driver =>
    let filter : Process.Script :=
      { command := (Workspace.FindFile.filtering FindFileTest.git "/r").filterFor "b"
        reply := FindFileTest.ran [] }
    { driver with
      keys :=
        { driver.keys with
          maps := fun state view =>
            registry.activeMaps TestScheme.scheme state view ++ driver.keys.maps state view }
      jobs :=
        { driver.jobs with
          processes :=
            { driver.jobs.processes with scripts := driver.jobs.processes.scripts.push filter } } }

/-- The registry of compiled code's bindings, the escape's key among them. -/
def shipped : Config.Registry :=
  ({} : Config.Registry).replaceBindings .compiled Workspace.package.registered.bindings

/-- A registry with no bindings. -/
def bare : Config.Registry :=
  {}

/-- The bindings a config collects that binds `C-o e` to the escape in the
workspace finder's category. -/
def configBindings : Array Config.KeyBinding :=
  match
    Config.Registrations.ofSetup
      (bindKey "C-o e" Workspace.FindInProject.escapeName (category :=
        some Workspace.FindFile.category)) with
  | .ok collected => collected.bindings
  | .error _ => #[]

/-- `driver` in `/r/src/a.lean`, its workspace settled, with the workspace's
finder asked, `b` typed, and drained. -/
def findingB (driver : TestDriver) : TestDriver :=
  FindFileTest.drainedAfter (FindFileTest.drainedAfter (settledAfter driver "C-o a") "C-o f") "b"

/-- What `driver` shows once `keys` are pressed: the open prompt's label,
the minibuffer's text, the echo area and whether a prompt is open. -/
def shown (driver : TestDriver) (keys : String) : Option String × Option String × String × Bool :=
  let after := FindFileTest.drainedAfter driver keys
  (FindFileTest.labelOf after, minibufferText after, after.loop.state.echo,
    after.loop.state.prompt.isSome)

end FindInProjectTest

open FindInProjectTest FindFileTest in
/-- The checks of `find-file-in-project`
(`Workspace/FindInProject.lean`), on the loop's driver over the
editor's models, the job model, the finder's world and the model of `/r`'s
repository, every process scripted by its exact command line. -/
def findInProjectChecks : List Check :=
  [{    name :=
          "criterion 1 on the models: in a buffer of /r, find-file-in-project lists r@fix, r@feature and r@main, annotated /u, /w and /r, the two no file was opened in among them and the current one last; the version-control backend is asked for the worktree list once, and the table still holds /r alone"
        run :=
          pure <|
            match projectDriver with
            | none => false
            | some driver =>
              let asked := askedInR driver
              labelOf asked == some "Find file in a workspace of r: " &&
                listedTexts asked == some #["r@fix", "r@feature", "r@main"] &&
                listedAnnotations asked == some #[some "/u", some "/w", some "/r"] &&
                runs asked listRun == 1 &&
                asked.loop.state.workspaces.workspaces.map (·.1.location) == #[.local "/r"] },
      { name :=
          "no key's handling waits on git: the step of the picker's key returns with the prompt open and no process run, handing back a start of the source's job; only that job lists the worktrees"
        run :=
          pure <|
            match projectDriver (registered := idle) with
            | none => false
            | some driver =>
              let opened := settledAfter driver "C-o a"
              let (asking, steps) := fedTo opened (presses "C-o p")
              let starts := (steps.back?.join).map fun stepped => stepped.starts.map (·.name)
              asking.jobs.processes.started == opened.jobs.processes.started &&
                labelOf asking == some "Find file in a workspace of r: " &&
                starts == some #[Workspace.FindInProject.job] },
      { name :=
          "criterion 2 on the models: choosing r@feature and accepting opens find-file-in-workspace rooted at /w, listing what git lists there, its lister run in /w"
        run :=
          pure <|
            match projectDriver with
            | none => false
            | some driver =>
              let chosen := drainedAfter (askedInR driver) "C-o j C-o j C-o y"
              labelOf chosen == some "Find file in r@feature: " &&
                listedTexts chosen == some #["src/w.lean", "src/b.lean", "only-w"] &&
                runs chosen (git.command "/w") == 1 },
      { name :=
          "criterion 2 on the models: the typed text feat, accepted with nothing chosen, is resolved by the category's style to r@feature and reaches the same finder"
        run :=
          pure <|
            match projectDriver with
            | none => false
            | some driver =>
              let chosen := drainedAfter (askedInR driver) "f e a t C-o y"
              labelOf chosen == some "Find file in r@feature: " &&
                listedTexts chosen == some #["src/w.lean", "src/b.lean", "only-w"] },
      { name :=
          "choosing r@main, which the table has, runs find-file-in-workspace there with no find; a text no workspace matches is said and opens nothing; a blank answer runs nothing"
        run :=
          pure <|
            match projectDriver with
            | none => false
            | some driver =>
              let asked := askedInR driver
              let finds (driver : TestDriver) :=
                runs driver (Workspace.Git.revParseCommand "git" "/r")
              let main := drainedAfter asked "C-o j C-o j C-o j C-o y"
              let unmatched := drainedAfter asked "z z z C-o y"
              let blank := drainedAfter asked "C-o y"
              labelOf main == some "Find file in r@main: " && finds main == finds asked &&
                unmatched.loop.state.echo ==
                  s!"{Workspace.FindInProject.name}: no workspace of r matches zzz" &&
                unmatched.loop.state.prompt.isNone &&
                blank.loop.state.prompt.isNone &&
                runs blank listRun == 1 },
      { name :=
          "criterion 3 on the models: a worktree first reached through the picker is added to the table with the finder's identity and branch, its answer cached, the finder run there once; choosing it again finds it in the table and runs no second find"
        run :=
          pure <|
            match projectDriver with
            | none => false
            | some driver =>
              let chosen := drainedAfter (askedInR driver) "C-o j C-o j C-o y"
              let again :=
                drainedAfter (drainedAfter (settledAfter chosen "C-o q") "C-o p")
                  "C-o j C-o j C-o y"
              let table := chosen.loop.state.workspaces
              let finds (driver : TestDriver) :=
                runs driver (Workspace.Git.revParseCommand "git" "/w")
              (table.workspace? (.local "/w")).map
                    (fun workspace => (workspace.branch, workspace.project.identity)) ==
                  some (some (.named "feature"), .remote "github.com/o/r") &&
                table.cached? "/w" 0 == some (some (.local "/w")) &&
                finds chosen == 1 &&
                labelOf again == some "Find file in r@feature: " &&
                finds again == 1 },
      { name :=
          "a worktree whose directory is gone is listed, r@old among the four; choosing it says it is not a repository any more, opens no prompt and caches the miss"
        run :=
          pure <|
            match
              projectDriver (threeLinked.push { path := "/d", branch := some "old" })
                #["/u", "/w", "/d"] with
            | none => false
            | some driver =>
              let asked := askedInR driver
              let chosen := drainedAfter asked "C-o j C-o y"
              listedTexts asked == some #["r@old", "r@fix", "r@feature", "r@main"] &&
                chosen.loop.state.echo ==
                  s!"{Workspace.FindInProject.name}: /d is not a repository any more" &&
                chosen.loop.state.prompt.isNone &&
                chosen.loop.state.workspaces.cached? "/d" 0 == some none },
      { name :=
          "criterion 4 on the models: a registered workspace of the project on another machine is listed, r@agent annotated /srv/r, and choosing it gives find-file-in-workspace's refusal, with no prompt open and no lister run"
        run :=
          pure <|
            match projectDriver with
            | none => false
            | some driver =>
              let asked := drainedAfter (settledAfter (settledAfter driver "C-o a") "C-o k") "C-o p"
              let chosen := drainedAfter asked "C-o j C-o j C-o j C-o y"
              listedTexts asked == some #["r@fix", "r@feature", "r@agent", "r@main"] &&
                listedAnnotations asked == some #[some "/u", some "/w", some "/srv/r", some "/r"] &&
                chosen.loop.state.echo ==
                  s!"{Workspace.FindFile.name}: r@agent is reachable through ssh host at /srv/r, where files cannot be listed" &&
                chosen.loop.state.prompt.isNone &&
                chosen.jobs.processes.started == asked.jobs.processes.started.push listRun },
      { name :=
          "criterion 4 on the models: a registered workspace on main beside the local r@main is told apart by its annotation, and choosing it gives the refusal"
        run :=
          pure <|
            match projectDriver with
            | none => false
            | some driver =>
              let asked := drainedAfter (settledAfter (settledAfter driver "C-o a") "C-o r") "C-o p"
              let chosen := drainedAfter asked "C-o j C-o j C-o j C-o y"
              listedTexts asked == some #["r@fix", "r@feature", "r@main (/srv/r)", "r@main (/r)"] &&
                chosen.loop.state.echo ==
                  s!"{Workspace.FindFile.name}: r@main is reachable through ssh host at /srv/r, where files cannot be listed" &&
                chosen.loop.state.prompt.isNone },
      { name :=
          "criterion 5 on the models: in a buffer with no workspace, and in *scratch*, find-file-in-project says there is no project, opens no prompt, starts no job and runs no process"
        run :=
          pure <|
            match projectDriver with
            | none => false
            | some driver =>
              refused (settledAfter driver "C-o x") "C-o p" ==
                  (Workspace.FindInProject.noProject "a.txt", false, 0, true) &&
                refused driver "C-o p" ==
                  (Workspace.FindInProject.noProject EditorState.scratchName, false, 0, true) },
      { name :=
          "a project with no git, found by its marker /m/mise.toml, lists its one workspace, m@m, and runs no process"
        run :=
          pure <|
            match
              projectDriver (over :=
                { projectWorld with markers := projectWorld.markers.push "/m/mise.toml" }) with
            | none => false
            | some driver =>
              let opened := settledAfter driver "C-o m"
              let asked := drainedAfter opened "C-o p"
              listedTexts asked == some #["m@m"] &&
                labelOf asked == some "Find file in a workspace of m: " &&
                asked.jobs.processes.started == opened.jobs.processes.started },
      { name := "a worktree list the backend refuses is said in the echo area, named by the source"
        run :=
          pure <|
            match projectDriver with
            | none => false
            | some driver =>
              -- The backend refuses the worktree list, as git does outside a
              -- repository.
              let asked := drainedAfter (settledAfter (unlisted driver) "C-o w") "C-o p"
              asked.loop.state.echo.startsWith s!"{Workspace.FindInProject.sourceName}: " &&
                listedTexts asked == some #[] },
      { name :=
          "a worktree list that succeeds for the source but that the backend refuses when the accept lists again is said as find-file-in-project: <why>, with no prompt open and no find started"
        run :=
          pure <|
            match projectDriver with
            | none => false
            | some driver =>
              let asked := askedInR driver
              -- The accept's list runs with a backend that refuses the
              -- worktree list; the source asked so says why under its own
              -- name.
              let chosen := drainedAfter (unlisted asked) "C-o j C-o j C-o y"
              let why :=
                (askedInR (unlisted driver)).loop.state.echo.drop
                    (Workspace.FindInProject.sourceName.length + 2) |>.toString
              let finds (driver : TestDriver) :=
                runs driver (Workspace.Git.revParseCommand "git" "/w")
              listedTexts asked == some #["r@fix", "r@feature", "r@main"] && !why.isEmpty &&
                chosen.loop.state.echo == s!"{Workspace.FindInProject.name}: {why}" &&
                chosen.loop.state.prompt.isNone &&
                finds chosen == finds asked &&
                chosen.pending.size + chosen.posting.size == 0 },
      { name :=
          "the source's job asked with nothing in its query's context fails, saying so; the choose order survives its arguments' round trip"
        run :=
          pure <|
            let failed :=
              match
                ((Workspace.FindInProject.answer none { text := "", view := ⟨0⟩ } fun _ =>
                        pure ()).runModel
                    {}).1 with
              | .failed said => some said
              | _ => none
            let asked : Workspace.Projects.Asked :=
              { git := "git", repository := some "/r", name := "r", current := .local "/r"
                known := #[{ location := .local "/r", label := "r@main" }] }
            let choose : Workspace.FindInProject.ChooseOrder :=
              { answer := "r@fix", view := ⟨2⟩, asked }
            failed == some Workspace.FindInProject.noProjectAsked &&
              Workspace.FindInProject.ChooseOrder.ofArguments? choose.arguments == some choose &&
              Workspace.FindInProject.ChooseOrder.ofArguments?
                  { choose with typed := "b" }.arguments ==
                some { choose with typed := "b" } },
      { name :=
          "phase 4 criterion 1 on the models: the escape key in the workspace finder closes it and opens the project's workspace picker, its input empty, listing r@fix, r@feature and r@main; the backend is asked for the worktree list once"
        run :=
          pure <|
            match escapeDriver shipped with
            | none => false
            | some driver =>
              let finding := findingB driver
              let escaped := drainedAfter finding "C-x C-d"
              labelOf finding == some "Find file in r@main: " &&
                minibufferText finding == some "b" &&
                labelOf escaped == some "Find file in a workspace of r: " &&
                minibufferText escaped == some "" &&
                listedTexts escaped == some #["r@fix", "r@feature", "r@main"] &&
                (escaped.loop.state.prompt.map (·.candidates.category)) ==
                  some (some Workspace.FindInProject.category) &&
                runs escaped listRun == 1 },
      { name :=
          "the escape from the finder in a buffer with no project closes the finder and says there is no project; run with no prompt open it says so and opens nothing; run in a prompt of another category it says so and leaves that prompt open; cancelling the picker after the escape leaves no prompt and starts no finder"
        run :=
          pure <|
            match escapeDriver shipped with
            | none => false
            | some driver =>
              let noProject :=
                drainedAfter (drainedAfter (settledAfter driver "C-o x") "C-o f") "C-x C-d"
              let unopened := drainedAfter (settledAfter driver "C-o a") "C-o 3"
              let other := drainedAfter (drainedAfter (settledAfter driver "C-o a") "C-o 2") "C-o 3"
              let escaped := drainedAfter (findingB driver) "C-x C-d"
              let cancelled := drainedAfter escaped "C-o q"
              noProject.loop.state.echo == Workspace.FindInProject.noProject "a.txt" &&
                noProject.loop.state.prompt.isNone &&
                unopened.loop.state.echo ==
                  s!"{Workspace.FindInProject.escapeName}: {PromptRefusal.notOpen.describe}" &&
                unopened.loop.state.prompt.isNone &&
                other.loop.state.echo == Workspace.FindInProject.notFinder &&
                labelOf other == some escapePickLabel &&
                cancelled.loop.state.prompt.isNone &&
                cancelled.pending.size + cancelled.posting.size == 0 &&
                cancelled.jobs.processes.started == escaped.jobs.processes.started },
      { name :=
          "phase 4 criterion 2 on the models: after the escape, choosing r@feature, which the table does not have, opens its finder with b typed and the list matched against it; choosing r@main, which it has, does the same there"
        run :=
          pure <|
            match escapeDriver shipped with
            | none => false
            | some driver =>
              let escaped := drainedAfter (findingB driver) "C-x C-d"
              let feature := drainedAfter escaped "C-o j C-o j C-o y"
              let main := drainedAfter escaped "C-o j C-o j C-o j C-o y"
              let filtered (driver : TestDriver) (root : System.FilePath) : Bool :=
                driver.jobs.processes.started.contains
                  ((Workspace.FindFile.filtering git root).filterFor "b")
              labelOf feature == some "Find file in r@feature: " &&
                minibufferText feature == some "b" &&
                listedTexts feature == some #["src/b.lean"] &&
                runs feature (Workspace.Git.revParseCommand "git" "/w") == 1 &&
                filtered feature "/w" &&
                labelOf main == some "Find file in r@main: " &&
                minibufferText main == some "b" &&
                listedTexts main == some #[] },
      { name :=
          "phase 4 criterion 3 on the models: the escape key in the picker, in a prompt with no category, in a prompt of another category and with no prompt open does what it does with no binding of it"
        run :=
          pure <|
            match escapeDriver shipped, escapeDriver bare with
            | some withKey, some without =>
              [("C-o a C-o p", "C-x C-d"), ("C-o 1", "C-x C-d"), ("C-o 2", "C-x C-d"),
                    ("C-o a", "C-x C-d")].all
                fun (before, keys) =>
                shown (drainedAfter (settledAfter withKey "C-o a") before) keys ==
                  shown (drainedAfter (settledAfter without "C-o a") before) keys
            | _, _ => false },
      { name :=
          "phase 4 criterion 3 under the test scheme: C-x C-d in a minibuffer's view yields the escape with the workspace finder's keymap active, and with another category's what it yields with no keymap"
        run :=
          let scheme := TestScheme.scheme
          let opened : TestScheme.State := scheme.openMinibuffer ⟨5⟩ scheme.init
          let fed (maps : List (Keymap TestScheme.Binding)) : List (Option String) :=
            ((scheme.feed (fun _ => maps) ⟨5⟩ opened (keys "C-x C-d")).2).map (·.map (·.command))
          pure
            (fed [shipped.categoryKeymap scheme Workspace.FindFile.category] ==
                [none, some Workspace.FindInProject.escapeName] &&
              fed [shipped.categoryKeymap scheme Workspace.FindInProject.category] == fed []) },
      { name :=
          "phase 4 criterion 4 on the models: config's binding of C-o e in the workspace finder's keymap steps out as the compiled key does, with no compiled binding, and beside it both keys step out"
        run :=
          pure <|
            let configured := bare.replaceBindings .config configBindings
            let both := shipped.replaceBindings .config configBindings
            let stepsOut (registry : Config.Registry) (key : String) : Bool :=
              match escapeDriver registry with
              | none => false
              | some driver =>
                let escaped := drainedAfter (findingB driver) key
                let feature := drainedAfter escaped "C-o j C-o j C-o y"
                labelOf escaped == some "Find file in a workspace of r: " &&
                  labelOf feature == some "Find file in r@feature: " &&
                  minibufferText feature == some "b"
            !configBindings.isEmpty && stepsOut configured "C-o e" && stepsOut both "C-o e" &&
              stepsOut both "C-x C-d" },
      { name :=
          "with no version-control backend registered the picker takes the case no repository: in a buffer of /r it lists r@main alone, asks no backend, and runs no process for the list"
        run :=
          pure <|
            match projectDriver (registered := projectJobsOver #[]) with
            | none => false
            | some driver =>
              let asked := askedInR driver
              listedTexts asked == some #["r@main"] && runs asked listRun == 0 }] ++
    -- The completion sources' contract over the workspace's find-in-project source,
    -- the workspace feature's shipped value; the core's
    -- `sourceContractChecks` run it over the model and the core's sources.
    (sourceContract Workspace.FindInProject.source).map fun (name, held) =>
      { name, run := pure held }

end WorkspaceTest
