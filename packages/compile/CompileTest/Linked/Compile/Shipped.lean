import Compile
import Compile.Compiled
import Compile.Contribution
import Compile.Shipped
import CompileTest.Check
import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Config.Packages
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Package
import Editor.Program
import Editor.ProjectMode.Listing
import Editor.State
import Editor.SyntaxTree
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Rig
import Editor.Test.Linked.Services
import Editor.Test.Linked.Trees
import Editor.Test.Listing
import Editor.Test.Workspace
import Editor.Text
import Editor.Watch
import Editor.Workspace
import FilesApiTest.Fake

/-!
# Linked tests: `Compile/Shipped.lean`

The tests of `Compile/Shipped.lean` that need the Rust library:
`projectRunChecks`, the shipped modes over the real process service. The
linked test's root, `CompileTest/Linked.lean`, runs them; its module doc
says what each shows. They were `ContractTest.projectModeChecks` while the
compile mode was a module of the core, and are written on the core's linked
test kit (`Editor.Test.Linked`): its rig, with the compile mode's keys and
jobs passed in (`projectKeys`, `projectJobs`).
-/

namespace CompileTest

open Editor
open Editor.Test.Linked

/-- The workspace a directory of the project mode checks under `base` is in,
standing in for the workspace finder's answer over the trees
`materializeProjects` writes (the core kit's `checkoutFound`): `cargo`,
`lake` and `mise`, each a main checkout on `main`, and `cargo-wt`, a
worktree of `cargo`'s repository on `feature`; none elsewhere. -/
def projectFound (base directory : System.FilePath) : Option Workspace.Found :=
  [Test.checkoutFound (base / "cargo"), Test.checkoutFound (base / "lake"),
        Test.checkoutFound (base / "mise"),
        Test.checkoutFound (base / "cargo-wt") "feature" (base / "cargo" / ".git")].findSome?
    (· directory)

/-- The marker files of the trees `materializeProjects` writes under `base`,
as the fixtures under `compile` (`tests/compile`) hold them. -/
def projectMarkers (base : System.FilePath) : Array System.FilePath :=
  #[base / "cargo" / "Cargo.toml", base / "lake" / "lakefile.lean", base / "mise" / "mise.toml",
    base / "mise" / "crate" / "Cargo.toml", base / "cargo-wt" / "Cargo.toml"]

/-- The packages of the project mode checks under `base`: the stand-ins for
the workspace's attach and its modes on markers (the core kit's
`attachByPackage` and `markersByPackage`, over `projectFound` and
`projectMarkers`), in the order a host registers the workspace's hooks, and
`files-api`'s fake, which opens files over the real file service and runs
their hooks. -/
def projectPackages (base : System.FilePath) : Array Package :=
  #[Test.attachByPackage (projectFound base),
    Test.markersByPackage (projectFound base) (projectMarkers base), FilesApiTest.fake]

/-- The jobs of the project mode checks under `base`: the rig's (`rigJobs`)
of `projectPackages`, `files-api`'s fake's among them, the core's listing
job (`Compile.listJob`, which the workspace package registers in a host),
and the compile mode's, as a host registers them. -/
def projectJobs (base : System.FilePath) : Array Config.JobRegistration :=
  rigJobs (projectPackages base) ++ #[{ name := Compile.listJob, work := Compile.listWork }] ++
    Compile.package.registered.jobs

/-- The keys of the project mode checks under `base`: none bound; the rig's
commands (`rigCommands`) of `projectPackages` and the compile mode's, by
name; their jobs registered; the hooks of `projectPackages` installed; and
the loop told the shipped contributions. -/
def projectKeys (base : System.FilePath) : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ((rigCommands (projectPackages base) ++ Compile.package.registered.commands).find?
            (·.name == name)).bind
        fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered :=
      { jobs := fun name => (projectJobs base).any (·.name == name)
        -- The hooks the fake runs once a buffer holds a file, as a host
        -- installs them: the stand-ins for the workspace's.
        extensions := (rigKeys (projectPackages base)).registered.extensions
        compile := { contributions := Compile.shipped } } }

/-- The loop, with its working directory `base`, once each of `invocations`
has run and settled, in order: the rig's `runSettled`
(`Editor/Test/Linked/Rig.lean`) with the project mode checks' keys and jobs
(`projectKeys`, `projectJobs`), which the rig, naming no feature outside the
core, does not default to. -/
def runSettled (rig : ProjectRig) (base : System.FilePath) (invocations : List Invocation) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) :=
  Editor.Test.Linked.runSettled rig base invocations (projectKeys base) (projectJobs base)

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

/-- The trees of the project mode checks under `base`, from the fixtures
under `compile` (`tests/compile`): `cargo`, `lake` and `mise`, and
`cargo-wt`, a copy of `cargo`, which `projectFound` answers as `cargo`'s
worktree on `feature`. -/
def materializeProjects (base compile : System.FilePath) : IO Unit := do
  for tree in ["cargo", "lake", "mise"] do
    copyTree (compile / tree) (base / tree)
  copyTree (compile / "cargo") (base / "cargo-wt")

/-- Runs `check` in a base of its own holding the project trees
(`materializeProjects`), on a rig whose children find the fixture programs
of `compile` first on their `PATH`; then whether every child it started was
reaped. -/
def withProjects (services : Job.Services) (compile : System.FilePath)
    (check : ProjectRig → System.FilePath → IO Bool) : IO Bool :=
  withBase fun base => do
    materializeProjects base compile
    let rig ← ProjectRig.new services s!"{compile / "bin"}:/usr/bin:/bin"
    let before ← pendingChildren
    let held ← check rig base
    let reaped ← eventually (return (← pendingChildren) == before)
    return held && reaped

/-- What only the real process and file services show of the shipped
modes, with fixture programs standing in for cargo, lake and mise
(`compile`, `tests/compile`), first on each child's `PATH`: each check
opens files of the trees `materializeProjects` writes, over `files-api`'s
fake, with a file's workspace and its modes on markers given by the
stand-ins (`projectPackages`), runs a named command and steps to its
locations. -/
def projectRunChecks (services : Job.Services) (compile : System.FilePath) : List Check :=
  let canned (name : String) : System.FilePath := compile / "bin" / name
  [{  name :=
        "modes criterion 8: over the real process service with the fixture cargo, compile-command build in the Cargo fixture fills cargo@main's compilation buffer with the fixture's output, ends exited abnormally with code 101, and next-error visits the rustc location in the fixture tree"
      run :=
        withProjects services compile fun rig base => do
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
        withProjects services compile fun rig base => do
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
        withProjects services compile fun rig base => do
          let bar := base / "lake" / "Foo" / "Bar.lean"
          let some (stepped, texts) ←
            runSettled rig base [openFile bar, compileCommandOf "build", nextError] | return false
          return locationsAt stepped (base / "lake") ==
                #[("lean", bar.toString, 12, some 4, some "unknown identifier 'x'")] &&
              (← focusedAt rig texts stepped) == some (bar.toString, 11, 4) },
    { name :=
        "modes criterion 11: with the fixture mise, mise-mode offers the fixture's tasks in the mise tree, after cargo-mode's in the nested crate, and running test, whose output is rustc's errors, finds them through cargo-mode's format in the nested crate"
      run :=
        withProjects services compile fun rig base => do
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
        withProjects services compile fun rig base => do
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

end CompileTest
