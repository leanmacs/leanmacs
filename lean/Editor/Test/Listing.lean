import Editor.Config.Registry
import Editor.Extension
import Editor.Job.Model
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Model
import Editor.ProjectMode
import Editor.ProjectMode.Listing
import Editor.Setup
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Shell
import Editor.Workspace
import FilesApi

/-!
# The test kit: Listing

A contribution with a listing, `t-mode`, and its world: the repositories it
is found in, what its listing prints in each, and what a driver is asked
about it. The world it is found in (`listingWorld`, `listingJobModel`)
names the workspace finder's model and is the workspace feature's kit's
(`Editor/Workspace/Kit.lean`). It names core modules only, with the stand-in for modes on markers
(`markedPackage`), so the checks of the listing
(`ModelTest/Editor/ProjectMode/Listing.lean`) build their host from it with
no package outside the core, and the compile mode's checks of what it makes
of a listing, in its package (`packages/compile/CompileTest/Compile.lean`,
`packages/compile/CompileTest/Compile/Contribution.lean`), use the same
world. It holds no
checks of its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

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

/-- A package, standing in for the workspace's modes on markers, that
registers at `files-api`'s hook `FilesApi.Opened` a value turning the
on-modes `on`, nearest first, on in every buffer that takes in a file
(`Workspace.turnOnModes`, the core's): what a check of a listing, the core's
or the compile mode's, registers in place of the workspace package's marker
search. -/
def markedPackage (on : Array Workspace.OnMode) : Package :=
  { name := "test-marked"
    setup :=
      Extension.add
        ({ name := "marker-modes", opened := fun id _ => Workspace.turnOnModes id on } :
          FilesApi.Opened) }

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

end Editor.Test
