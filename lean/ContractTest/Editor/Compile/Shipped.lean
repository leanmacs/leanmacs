import ContractTest.Check
import ContractTest.Support.Jobs
import ContractTest.Support.Projects
import ContractTest.Support.Trees
import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Command.Real
import Editor.Compile
import Editor.Compile.Contribution
import Editor.Compile.Shipped
import Editor.Ffi.Processes
import Editor.Ffi.Snapshot
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job.Runner
import Editor.Loop
import Editor.Program
import Editor.ProjectMode.Listing
import Editor.State
import Editor.SyntaxTree
import Editor.Text
import Editor.Text.Real
import Editor.Watch
import Editor.Workspace
import Editor.Workspace.Modes

/-!
# Contract tests: `Editor/Compile/Shipped.lean`

The tests of `Editor/Compile/Shipped.lean`: `projectModeChecks`, the shipped
modes over the real process service. The root module `ContractTest` runs them;
its module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- The invocation of `compile-command` with the answer `answer`. -/
def compileCommandOf (answer : String) : Invocation :=
  { command := Compile.commandName, arguments := [.str answer] }

/-- The invocation of `next-error`. -/
def nextError : Invocation :=
  { command := Compile.nextName }

/-- The file of the focused view's buffer in `loop`, and the row and column
of its cursor. -/
def focusedAt (rig : ProjectRig) (texts : RealTexts) (loop : Loop TestScheme.scheme) :
    IO (Option (String × Nat × Nat)) := do
  let read : EditorM (Option (String × Nat × Nat)) := do
    let some target := loop.state.focusedTarget? | return none
    let some file := target.buffer.file | return none
    let selection ← target.selection
    let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
    let point ← target.buffer.text.pointOf head
    return some (file.path.toString, point.row, point.column)
  let (at_, _) ← read.runReal texts rig.display
  return at_.toOption.join

/-- The locations of the workspace at `root` in `loop`, as each one's
format, file, line, column and message. -/
def locationsAt (loop : Loop TestScheme.scheme) (root : System.FilePath) :
    Array (String × String × Nat × Option Nat × Option String) :=
  (Compile.recordOf loop.state (.workspace (.local root))).locations.map fun site =>
    (site.format, site.file.toString, site.line, site.column, site.message)

/-- The lines of the file `path`, without the empty one after its last line
feed. -/
def fileLines (path : System.FilePath) : IO (List String) := do
  let lines := (← IO.FS.readFile path).splitOn "\n"
  return if lines.getLast? == some "" then lines.dropLast else lines

/-- Whether `text` is `header`, then the lines of the file `canned`, then a
last line that starts `last`. -/
def compiledAs (text : Option String) (header : String) (canned : System.FilePath) (last : String) :
    IO Bool := do
  let lines ← fileLines canned
  return text.any fun text =>
      match (text.splitOn "\n").filter (· != "") |>.reverse with
      | final :: rest => final.startsWith last && rest.reverse == header :: lines.filter (· != "")
      | [] => false

/-- Copies the tree `source` to `target`, every file with its bytes. -/
partial def copyTree (source target : System.FilePath) : IO Unit := do
  IO.FS.createDirAll target
  for entry in ← source.readDir do
    if ← entry.path.isDir then
      copyTree entry.path (target / entry.fileName)
    else
      IO.FS.writeBinFile (target / entry.fileName) (← IO.FS.readBinFile entry.path)

/-- Writes the git fixture's file in `root`: the three lines rev-parse
prints there, its top level `root`, the common directory `common` and the
branch `branch`. -/
def writeFixtureGit (root common : System.FilePath) (branch : String) : IO Unit :=
  writeMaking (root / "fixture-git") s!"{root}\n{common}\n{branch}\n"

/-- The trees of the project mode checks under `base`, from the fixtures
under `compile` (`tests/compile`): `cargo`, `lake` and `mise`, each a
repository of its own on `main`, and `cargo-wt`, a copy of `cargo` shaped as
its worktree on `feature`, whose `.git` names an absolute path. -/
def materializeProjects (base compile : System.FilePath) : IO Unit := do
  for tree in ["cargo", "lake", "mise"] do
    copyTree (compile / tree) (base / tree)
  copyTree (compile / "cargo") (base / "cargo-wt")
  for tree in ["cargo", "lake", "mise"] do
    IO.FS.createDirAll (base / tree / ".git")
    writeFixtureGit (base / tree) (base / tree / ".git") "main"
  writeMaking (base / "cargo-wt" / ".git")
      s!"gitdir: {base / "cargo" / ".git" / "worktrees" / "cargo-wt"}\n"
  writeFixtureGit (base / "cargo-wt") (base / "cargo" / ".git") "feature"

/-- Runs `check` in a base of its own holding the project trees
(`materializeProjects`), on a rig whose children find the fixture programs
of `compile` and the git fixture of `workspaces` first on their `PATH`;
then whether every child it started was reaped. -/
def withProjects (services : Job.Services) (compile workspaces : System.FilePath)
    (check : ProjectRig → System.FilePath → IO Bool) : IO Bool :=
  withBase fun base => do
    materializeProjects base compile
    let rig ← ProjectRig.new services s!"{compile / "bin"}:{workspaces}:/usr/bin:/bin"
    let before ← Ffi.processesPending
    let held ← check rig base
    let reaped ← eventually (return (← Ffi.processesPending) == before)
    return held && reaped

/-- What only the real process service shows of the shipped modes, with
fixture programs standing in for cargo, lake, mise and git (`compile`,
`tests/compile`, and `workspaces`, `tests/workspaces`), first on each
child's `PATH`: each check opens files of the trees `materializeProjects`
writes, runs a named command and steps to its locations. -/
def projectModeChecks (services : Job.Services) (compile workspaces : System.FilePath) :
    List Check :=
  let canned (name : String) : System.FilePath := compile / "bin" / name
  [{  name :=
        "modes criterion 8: over the real process service with the fixture cargo, compile-command build in the Cargo fixture fills cargo@main's compilation buffer with the fixture's output, ends exited abnormally with code 101, and next-error visits the rustc location in the fixture tree"
      run :=
        withProjects services compile workspaces fun rig base => do
          let main := base / "cargo" / "src" / "main.rs"
          let some (stepped, texts) ←
            runSettled rig base [openFile main, compileCommandOf "build", nextError] | return false
          let text ← bufferText rig texts stepped "*compilation: cargo@main*"
          let shown ←
            compiledAs text s!"cargo@main in {base / "cargo"}: cargo build"
                (canned "cargo-build.txt") "Compilation exited abnormally with code 101 after "
          return shown &&
              locationsAt stepped (base / "cargo") ==
                #[("rustc", main.toString, 4, some 18, some "mismatched types")] &&
              (← focusedAt rig texts stepped) == some (main.toString, 3, 17) },
    { name :=
        "modes criterion 9: over the real process service with the fixture lake, compile-command build in the Lean fixture fills lake@main's compilation buffer with the fixture's output and ends exited abnormally with code 1"
      run :=
        withProjects services compile workspaces fun rig base => do
          let some (built, texts) ←
            runSettled rig base
                [openFile (base / "lake" / "Foo" / "Bar.lean"),
                  compileCommandOf "build"] | return false
          let text ← bufferText rig texts built "*compilation: lake@main*"
          compiledAs text s!"lake@main in {base / "lake"}: lake build" (canned "lake-build.txt")
              "Compilation exited abnormally with code 1 after " },
    { name :=
        "modes criterion 10: after that build, next-error visits Foo/Bar.lean line 12 column 4 in the Lean fixture tree: row 11, character 4, the x of its last line"
      run :=
        withProjects services compile workspaces fun rig base => do
          let bar := base / "lake" / "Foo" / "Bar.lean"
          let some (stepped, texts) ←
            runSettled rig base [openFile bar, compileCommandOf "build", nextError] | return false
          return locationsAt stepped (base / "lake") ==
                #[("lean", bar.toString, 12, some 4, some "unknown identifier 'x'")] &&
              (← focusedAt rig texts stepped) == some (bar.toString, 11, 4) },
    { name :=
        "modes criterion 11: with the fixture mise, mise-mode offers the fixture's tasks in the mise tree, after cargo-mode's in the nested crate, and running test, whose output is rustc's errors, finds them through cargo-mode's format in the nested crate"
      run :=
        withProjects services compile workspaces fun rig base => do
          let crateMain := base / "mise" / "crate" / "src" / "main.rs"
          let some (opened, _) ← runSettled rig base [openFile crateMain] | return false
          let some (tested, _) ←
            runSettled rig base
                [openFile crateMain, compileCommandOf "test (mise-mode)"] | return false
          let state := opened.state
          let modes :=
            match state.focusedTarget? with
            | some target => Workspace.onModesOf state target.window.buffer
            | none => #[]
          let offered :=
            Compile.offers Compile.shipped #[] modes
              (Compile.listedCommands state (some (.local (base / "mise"))))
          let crate := base / "mise" / "crate"
          let mise := base / "mise"
          return modes ==
                #[{ mode := "cargo-mode", root := crate }, { mode := "mise-mode", root := mise }] &&
              offered.map (fun offer => (offer.candidate, offer.line, offer.root)) ==
                #[("build (cargo-mode)", "cargo build", crate),
                  ("test (cargo-mode)", "cargo test", crate),
                  ("clippy (cargo-mode)", "cargo clippy", crate),
                  ("build (mise-mode)", "mise run build", mise),
                  ("test (mise-mode)", "mise run test", mise)] &&
              locationsAt tested mise ==
                #[("rustc", crateMain.toString, 4, some 18, some "mismatched types")] },
    { name :=
        "modes criterion 12: build run in the Cargo fixture and in its worktree-shaped copy fills two compilation buffers with separate error lists, next-error in each visits its own tree's file, and both workspaces read one project history holding cargo build once"
      run :=
        withProjects services compile workspaces fun rig base => do
          let main := base / "cargo" / "src" / "main.rs"
          let wtMain := base / "cargo-wt" / "src" / "main.rs"
          let some (built, texts) ←
            runSettled rig base
                [openFile main, compileCommandOf "build", openFile wtMain,
                  compileCommandOf "build"] | return false
          let some (inWt, wtTexts) ←
            runSettled rig base
                [openFile main, compileCommandOf "build", openFile wtMain, compileCommandOf "build",
                  nextError] | return false
          let some (inMain, mainTexts) ←
            runSettled rig base
                [openFile main, compileCommandOf "build", openFile wtMain, compileCommandOf "build",
                  openFile main, nextError] | return false
          let history :=
            match
              built.state.focusedTarget?.bind fun target =>
                built.state.workspaceOf? target.window.buffer with
            | some (_, project) =>
              built.state.workspaces.getOfProject Compile.historyStore project.identity
            | none => #[]
          let mainText ← bufferText rig texts built "*compilation: cargo@main*"
          let wtText ← bufferText rig texts built "*compilation: cargo@feature*"
          return mainText.isSome && wtText.isSome &&
              (locationsAt built (base / "cargo")).map (·.2.1) == #[main.toString] &&
              (locationsAt built (base / "cargo-wt")).map (·.2.1) == #[wtMain.toString] &&
              (← focusedAt rig wtTexts inWt) == some (wtMain.toString, 3, 17) &&
              (← focusedAt rig mainTexts inMain) == some (main.toString, 3, 17) &&
              history == #["cargo build"] }]

end ContractTest
