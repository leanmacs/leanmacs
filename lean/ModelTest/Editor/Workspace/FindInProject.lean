import Editor.Completion.Later
import Editor.Minibuffer
import Editor.VersionControl.Contract
import Editor.VersionControl.Git
import Editor.VersionControl.Model
import Editor.Workspace.FindInProject
import ModelTest.Check
import ModelTest.Support.FindFile

/-!
# Model tests: `Editor/Workspace/FindInProject.lean`

The model tests of `Editor/Workspace/FindInProject.lean`:
`findInProjectChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor

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

/-- The jobs of the checks: the finder checks', and the picker's three. -/
def projectJobs (name : String) : Option (List Argument → Work) :=
  if name == Workspace.FindInProject.job then
    some (Completion.answering Workspace.FindInProject.answer)
  else
    if name == Workspace.FindInProject.chooseJob then some Workspace.FindInProject.chooseWork
    else
      if name == Workspace.FindInProject.findJob then some Workspace.FindInProject.findWork
      else FindFileTest.jobs name

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
      (Minibuffer.cancelName, fun call => do
        Minibuffer.cancelCommand call
        return none)]

/-- The keys of the checks: the finder checks', `C-o p` the picker, `C-o k`
registers the remote workspace on `agent` (`C-o r`, the finder checks',
registers it on `main`), and `C-o q` cancels the prompt. -/
def projectBindings : List (String × Invocation) :=
  FindFileTest.bindings ++
    [("C-o p", invoke Workspace.FindInProject.name), ("C-o k", invoke "register-agent"),
      ("C-o q", invoke Minibuffer.cancelName)]

/-- A job that does nothing, in place of the source's, for the check that
shows the picker's key runs no process. -/
def idle (name : String) : Option (List Argument → Work) :=
  if name == Workspace.FindInProject.job then
    some fun _ => Work.of (fun _ => pure ()) fun _ => pure ()
  else projectJobs name

/-- The driver of the checks: the finder checks' over the world `over`,
`projectWorld` by default, with the jobs `registered`, git's worktree list in
`/r` meeting `repository linked`, and the finder scripted for `found`, the
worktrees' directories. -/
def projectDriver (linked : Array VersionControl.Model.Linked := threeLinked)
    (found : Array System.FilePath := #["/u", "/w"]) (over : Workspace.World := projectWorld)
    (registered : String → Option (List Argument → Work) := projectJobs) : Option TestDriver :=
  (FindFileTest.driver (world := over) (registered := registered) (commands := projectCommands)
        (bindings := projectBindings)).map
    fun driver =>
    let extra :=
      ((repository linked).jobModel "git" "/r").processes.scripts ++
        (over.jobModel "git" found).processes.scripts
    { driver with
      jobs :=
        { driver.jobs with
          processes :=
            { driver.jobs.processes with scripts := driver.jobs.processes.scripts ++ extra } } }

/-- Git's worktree list, run in `/r`. -/
def listRun : Process.Command :=
  VersionControl.Git.command "git" "/r" VersionControl.Git.worktreeListArguments

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

end FindInProjectTest

open FindInProjectTest FindFileTest in
/-- The checks of `find-file-in-project`
(`Editor/Workspace/FindInProject.lean`), on the loop's driver over the
editor's models, the job model, the finder's world and the model of `/r`'s
repository, every process scripted by its exact command line. -/
def findInProjectChecks : List Check :=
  [{  name :=
        "criterion 1 on the models: in a buffer of /r, find-file-in-project lists r@fix, r@feature and r@main, annotated /u, /w and /r, the two no file was opened in among them and the current one last; git worktree list runs once in /r, and the table still holds /r alone"
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
              drainedAfter (drainedAfter (settledAfter chosen "C-o q") "C-o p") "C-o j C-o j C-o y"
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
    { name := "a git worktree list that fails is said in the echo area, named by the source"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            -- No worktree list is scripted in /w, so the process model
            -- refuses it, as a program that is not there is.
            let asked := drainedAfter (settledAfter driver "C-o w") "C-o p"
            asked.loop.state.echo.startsWith s!"{Workspace.FindInProject.sourceName}: " &&
              listedTexts asked == some #[] },
    { name :=
        "the source's job asked with nothing in its query's context fails, saying so; the choose order survives its arguments' round trip"
      run :=
        pure <|
          let failed :=
            match
              ((Workspace.FindInProject.answer { text := "", view := ⟨0⟩ } fun _ =>
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
            Workspace.FindInProject.ChooseOrder.ofArguments? choose.arguments == some choose }]

end ModelTest
