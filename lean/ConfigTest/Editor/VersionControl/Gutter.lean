import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Hosts
import Editor.Completion
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Ex.Line
import Editor.Face
import Editor.Files.Compiled
import Editor.Headless
import Editor.InputScheme.Test
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Language
import Editor.Loop
import Editor.Minibuffer.Compiled
import Editor.Process
import Editor.VersionControl.Compiled
import Editor.Workspace.Compiled

/-!
# Config tests: `Editor/VersionControl/Gutter.lean`

The tests of `Editor/VersionControl/Gutter.lean`: `gutterChecks`, through the
headless host over real git. The root module `ConfigTest` runs them; its module
doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- The variables every git a gutter check runs is given: git kept from the
system's config and from the user's, whose home is `home`, and a fixed
author, so a commit needs nothing of the machine's. -/
def isolatedGit (home : System.FilePath) : Array (String × String) :=
  #[("GIT_CONFIG_NOSYSTEM", "1"), ("GIT_CONFIG_GLOBAL", "/dev/null"), ("HOME", home.toString),
    ("XDG_CONFIG_HOME", home.toString), ("GIT_AUTHOR_NAME", "a"),
    ("GIT_AUTHOR_EMAIL", "a@example.com"), ("GIT_COMMITTER_NAME", "a"),
    ("GIT_COMMITTER_EMAIL", "a@example.com")]

/-- Runs git with `arguments` in `directory`, as another program would, with
`isolatedGit home` and none of `GIT_DIR`, `GIT_WORK_TREE` and
`GIT_INDEX_FILE`: what it printed, or a throw when it did not exit 0. The
test process's own environment is never touched. -/
def gitOutside (home directory : System.FilePath) (arguments : Array String) : IO String :=
  IO.Process.run
    { cmd := "git", args := arguments, cwd := directory
      env :=
        (isolatedGit home).map (fun (name, value) => (name, some value)) ++
          #[("GIT_DIR", none), ("GIT_WORK_TREE", none), ("GIT_INDEX_FILE", none)] }

/-- The library's process service, each child it starts given
`isolatedGit home` over the variables its command sets; each request that
starts a child is matched constructor by constructor, so the replies' types
line up. -/
def isolatedProcesses (processes : Job.Processes) (home : System.FilePath) : Job.Processes :=
  let change (command : Process.Command) : Process.Command :=
    let names := (isolatedGit home).map (·.1)
    { command with
      environment :=
        { command.environment with
          set := (command.environment.set.filter (!names.contains ·.1)) ++ isolatedGit home } }
  let changed : ProcessRequest → ProcessRequest
    | .run command limit => .run (change command) limit
    | .runWithin command limit time => .runWithin (change command) limit time
    | .runInput command input limit time => .runInput (change command) input limit time
    | .runHead command input limit time => .runHead (change command) input limit time
    | .start command streaming => .start (change command) streaming
    | other => other
  { processes with
    start := fun id request => processes.start id (changed request)
    take := fun id request =>
      match request with
      | .run command limit => processes.take id (.run (change command) limit)
      | .runWithin command limit time => processes.take id (.runWithin (change command) limit time)
      | .runInput command input limit time =>
        processes.take id (.runInput (change command) input limit time)
      | .runHead command input limit time =>
        processes.take id (.runHead (change command) input limit time)
      | .start command streaming => processes.take id (.start (change command) streaming)
      | other => processes.take id other }

/-- The checks of the version-control gutter through the headless host
(`Editor/VersionControl/Gutter.lean`), wiring only: real git over the
library's process service, the library's watch service and its diff
engine, in a repository the check writes in a temporary directory of its
own, every git kept from the user's and the system's config. Every wait is
polled, never a fixed sleep. -/
def gutterChecks (context : Context) : List Check :=
  [{  name :=
        "criterion 6 through the host over real git: a tracked file with a line changed shows a changed mark, and after git commit -a run by another process its gutter has no mark"
      run :=
        withFiles context (targets := [.files, .diffs]) fun base => do
          let base ← IO.FS.realPath base
          let (home, repo, configDir) := (base / "home", base / "repo", base / "config")
          for directory in [home, repo, configDir] do
            IO.FS.createDirAll directory
          let file := repo / "a.txt"
          discard <| gitOutside home repo #["-c", "init.defaultBranch=main", "init", "-q"]
          IO.FS.writeFile file "a\nb\nc\n"
          discard <| gitOutside home repo #["add", "a.txt"]
          discard <|
              gitOutside home repo #["-c", "commit.gpgsign=false", "commit", "-q", "-m", "one"]
          IO.FS.writeFile file "a\nB\nc\n"
          let stage ←
            Stage.overFiles context (Config.Directory.source configDir)
                { commands :=
                    Files.package.registered.commands ++ Minibuffer.package.registered.commands ++
                      Workspace.package.registered.commands ++
                      VersionControl.gutterPackage.registered.commands ++
                      #[opening "open-a" file]
                  jobs :=
                    Files.package.registered.jobs ++ Workspace.package.registered.jobs ++
                      VersionControl.gutterPackage.registered.jobs
                  modes := Minibuffer.package.registered.modes }
          let collaborators := stage.collaborators
          let services := collaborators.services
          let processes :=
            Job.realProcesses services.completions (← Job.RefusedRuns.new) services.timers
              (← Job.TimedRuns.new)
          let stage :=
            { stage with
              collaborators :=
                { collaborators with
                  services := { services with processes := isolatedProcesses processes home } } }
          onStage stage fun host stage => do
              let session : Session :=
                { host, directory := configDir, output := stage.output, threads := stage.threads
                  clock := stage.clock, watches := stage.watches, log := stage.log }
              -- The watch job never ends, so the host's jobs never settle: the
              -- open is asked for, and its outcome polled.
              session.ask [.run "open-a"]
              let changed := "marks 0: ~ diff.changed 2..4"
              let (marked, saw) ← session.within 5000 (·.contains changed)
              unless marked.isSome do
                throw (IO.userError s!"the changed mark was not shown: {saw}")
              discard <|
                  gitOutside home repo
                    #["-c", "commit.gpgsign=false", "commit", "-q", "-a", "-m", "two"]
              let (cleared, last) ←
                session.within 5000 fun lines =>
                    !lines.any (·.startsWith "marks 0:") &&
                      lines.any fun line => line.startsWith "view 0" && line.endsWith " gutter 12"
              unless cleared.isSome do
                throw (IO.userError s!"the mark was not cleared after the commit: {last}")
              return true }]

end ConfigTest
