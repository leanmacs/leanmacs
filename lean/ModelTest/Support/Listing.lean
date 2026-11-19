import Editor.Config.Registry
import Editor.File.Model
import Editor.Job.Model
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Model
import Editor.ProjectMode
import Editor.Setup
import Editor.Workspace
import Editor.Workspace.Model
import Editor.Workspace.Modes
import ModelTest.Support.Driver
import ModelTest.Support.Keys
import ModelTest.Support.Shell

/-!
# Model tests: support: Listing

A contribution with a listing, `t-mode`, and its world: the repositories it
is found in, what its listing prints in each, and what a driver is asked
about it. It names core modules only, so the checks of the listing
(`ModelTest/Editor/ProjectMode/Listing.lean`) build their host from it with
no package outside the core, and the compile mode's checks of what it makes
of a listing (`ModelTest/Editor/Compile.lean`,
`ModelTest/Editor/Compile/Contribution.lean`) use the same world. It holds no
checks of its own.
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

/-- The registry of the listing checks: `t-mode` registered by config. -/
def listingRegistry : Config.Registry :=
  match Config.Registrations.ofSetup (compileContribution tContribution) with
  | .ok registrations =>
    ({} : Config.Registry).replaceContributions .config registrations.contributions
  | .error _ => {}

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

/-- The files the listing checks open, by the key that opens each: `C-p 1`
and `C-p 2` two files of `/t`, `C-p 3` and `C-p 5` two of `/t2`, and `C-p 4`
one of `/u`. -/
def listingFiles : List (String × System.FilePath) :=
  [("C-p 1", "/t/a.txt"), ("C-p 2", "/t/b.txt"), ("C-p 3", "/t2/a.txt"), ("C-p 4", "/u/a.txt"),
    ("C-p 5", "/t2/b.txt")]

/-- The job model of the listing checks: `listingWorld`'s, with the files
of `listingFiles`, the listings' runs (`listingScripts`) and the streaming
children `streams`. -/
def listingJobModel (streams : Array Process.StreamScript := #[]) : JobModel :=
  let model := listingWorld.jobModel "git" #["/t", "/t2", "/u"]
  let files :=
    listingFiles.foldl (fun (files : FileModel) (_, path) => files.withFile path "a".toUTF8)
      model.files
  { model with
    files
    processes :=
      { model.processes with
        scripts := model.processes.scripts ++ listingScripts, streams } }

/-- The on-modes of the buffer the view 0 of `driver` shows. -/
def shownOnModes (driver : TestDriver) : Option (Array Workspace.OnMode) := do
  return Workspace.onModesOf driver.loop.state (← showing driver).id

/-- `driver` once `keys` are pressed and every job they start, and every job
those jobs' commands start, is finished, oldest first; with the names of the
jobs finished, in order. -/
def settledNames (driver : TestDriver) (keys : String) : TestDriver × Array String :=
  (List.range 8).foldl
    (fun (driver, names) _ =>
      match driver.pending[0]? with
      | some job => ((driver.finish job.id).1, names.push job.name)
      | none => (driver, names))
    ((fedTo driver (presses keys)).1, #[])

/-- How many times `driver` has started `command`. -/
def startedCount (driver : TestDriver) (command : Process.Command) : Nat :=
  (driver.jobs.processes.started.filter (· == command)).size

end ModelTest
