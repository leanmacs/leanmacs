import Editor.Api
import Editor.Command
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.Store
import Editor.Test.Driver
import Editor.Test.Opener
import Editor.Test.Workspace
import Editor.Text.Model
import Editor.Value
import Editor.Workspace
import Editor.Workspace.Attach
import Editor.Workspace.Kit
import ModelTest.Check

/-!
# Model tests: `Editor/Workspace/Attach.lean`

The model tests of `Editor/Workspace/Attach.lean`: `workspaceChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

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
          match workspaceDriver (Opener.jobsWith Workspace.attach) with
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

end ModelTest
