import Compile
import Compile.Compiled
import Compile.Contribution
import Compile.Shipped
import CompileApi.Listing
import CompileApiTest.Listing
import CompileTest.Check
import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Config.Packages
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Package
import Editor.Program
import Editor.State
import Editor.SyntaxTree
import Editor.Test.Linked.Rig
import Editor.Test.Linked.Services
import Editor.Test.Linked.Trees
import Editor.Test.Workspace
import Editor.Text
import Editor.Watch
import Editor.Workspace
import FilesApiTest.Fake

/-!
# Linked tests: `Compile/Shipped.lean`

The tests of `Compile/Shipped.lean` that need the Rust library:
`projectRunChecks`, the shipped modes on a stepped rig, over the process and
file fakes. The
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
`projectFiles` holds (the core kit's `checkoutFound`): `cargo`,
`lake` and `mise`, each a main checkout on `main`, and `cargo-wt`, a
worktree of `cargo`'s repository on `feature`; none elsewhere. -/
def projectFound (base directory : System.FilePath) : Option Workspace.Found :=
  [Test.checkoutFound (base / "cargo"), Test.checkoutFound (base / "lake"),
        Test.checkoutFound (base / "mise"),
        Test.checkoutFound (base / "cargo-wt") "feature" (base / "cargo" / ".git")].findSome?
    (· directory)

/-- The marker files of the trees `projectFiles` holds under `base`,
as the fixtures under `compile` (`tests/compile`) hold them. -/
def projectMarkers (base : System.FilePath) : Array System.FilePath :=
  #[base / "cargo" / "Cargo.toml", base / "lake" / "lakefile.lean", base / "mise" / "mise.toml",
    base / "mise" / "crate" / "Cargo.toml", base / "cargo-wt" / "Cargo.toml"]

/-- The packages of the project mode checks under `base`: the stand-ins for
the workspace's attach and its modes on markers (the core kit's
`attachByPackage` and `markersByPackage`, over `projectFound` and
`projectMarkers`), in the order a host registers the workspace's hooks, and
`files-api`'s fake, which opens files over the rig's file service and runs
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
        -- installs them: the stand-ins for the workspace's. And the shipped
        -- contributions, which the compile package registers at their
        -- extension point.
        extensions :=
          (rigKeys ((projectPackages base).push Compile.package)).registered.extensions } }

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

/-- `model` with the tree `source` read into it at `target`: every
directory, and every file with its bytes. -/
partial def treeInto (source target : System.FilePath) (model : FileModel) : IO FileModel := do
  let mut model := model.withDirectory target
  for entry in ← source.readDir do
    if ← entry.path.isDir then
      model ← treeInto entry.path (target / entry.fileName) model
    else
      model := model.withFile (target / entry.fileName) (← IO.FS.readBinFile entry.path)
  return model

/-- The base of the project mode checks' trees: a made-up path, which only
the rig's file fake holds. -/
def projectBase : System.FilePath :=
  "/p"

/-- The files of the project mode checks under `base`, read into a model
from the fixtures under `compile` (`tests/compile`): `cargo`, `lake` and
`mise`, and `cargo-wt`, a copy of `cargo`, which `projectFound` answers as
`cargo`'s worktree on `feature`. -/
def projectFiles (base compile : System.FilePath) : IO FileModel := do
  let mut model := ({} : FileModel).withDirectory "/"
  model := model.withDirectory base
  for tree in ["cargo", "lake", "mise"] do
    model ← treeInto (compile / tree) (base / tree) model
  treeInto (compile / "cargo") (base / "cargo-wt") model

/-- The command a shipped mode's run of `line` starts in `directory`, as the
compile mode starts it (`Compile.Order.command`). -/
def shellOf (line : String) (directory : System.FilePath) : Process.Command :=
  { program := "/bin/sh", arguments := #["-c", line], directory }

/-- A streaming child of the rig's process fake: `line` in `directory`,
which writes the file `canned` to `stream`, as the stand-in of `compile/bin`
writes it, and exits with `code`. -/
def cannedChild (line : String) (directory : System.FilePath) (canned : System.FilePath)
    (stream : Process.Stream) (code : Nat) : IO Process.StreamScript := do
  return {
      command := shellOf line directory, steps := #[.write stream (← IO.FS.readBinFile canned)]
      exit := .code code }

/-- What the rig's process fake runs for the project mode checks under
`base`, from the stand-ins of `compile/bin` and their canned output, which
`tests/compile/bin`'s scripts write for the same commands: `cargo build` in
each cargo tree, its errors on standard error and exit 101; `lake build`,
on standard output and exit 1; `mise run test` in the mise tree, its errors
on standard error and exit 1; and `mise tasks ls --json` there, which lists
the tasks `build` and `test` in that directory. -/
def projectProcesses (base compile : System.FilePath) : IO ProcessModel := do
  let canned (name : String) : System.FilePath := compile / "bin" / name
  let mise := base / "mise"
  let tasks :=
    s!"[\n  \{\"name\": \"build\", \"dir\": \"{mise}\", \"hide\": false, \"depends\": [], \"run\": [\"cargo build\"]},\n  \{\"name\": \"test\", \"dir\": \"{mise}\", \"hide\": false, \"depends\": [\"build\"], \"run\": [\"cargo test\"]}\n]\n"
  return {
      streams :=
        #[← cannedChild "cargo build" (base / "cargo") (canned "cargo-build.txt") .err 101,
          ← cannedChild "cargo build" (base / "cargo-wt") (canned "cargo-build.txt") .err 101,
          ← cannedChild "lake build" (base / "lake") (canned "lake-build.txt") .out 1,
          ← cannedChild "mise run test" mise (canned "mise-run-test.txt") .err 1]
      scripts :=
        #[{ command :=
              { program := "mise", arguments := #["tasks", "ls", "--json"], directory := mise }
            reply := .ok { exit := .code 0, stdout := tasks.toUTF8, stderr := .empty } }] }

/-- Runs `check` on a stepped rig (`ProjectRig.stepped`) whose file fake
holds the project trees under `projectBase` (`projectFiles`) and whose
process fake runs the stand-ins' replies (`projectProcesses`): every job is
run to its end on the check's thread, and nothing is read from or written
to disk but the fixtures the models are read from. -/
def withProjects (compile : System.FilePath) (check : ProjectRig → System.FilePath → IO Bool) :
    IO Bool := do
  let base := projectBase
  let (rig, _) ← ProjectRig.stepped (← projectFiles base compile) (← projectProcesses base compile)
  check rig base

/-- The shipped modes run through the loop on a stepped rig, with the
process fake answering what the fixture programs standing in for cargo,
lake and mise write (`compile`, `tests/compile`; `projectProcesses`): each
check opens files of the trees `projectFiles` holds, over `files-api`'s
fake, with a file's workspace and its modes on markers given by the
stand-ins (`projectPackages`), runs a named command and steps to its
locations. -/
def projectRunChecks (compile : System.FilePath) : List Check :=
  let canned (name : String) : System.FilePath := compile / "bin" / name
  [{  name :=
        "modes criterion 8: with the fixture cargo's reply, compile-command build in the Cargo fixture fills cargo@main's compilation buffer with the fixture's output, ends exited abnormally with code 101, and next-error visits the rustc location in the fixture tree"
      run :=
        withProjects compile fun rig base => do
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
        "modes criterion 9: with the fixture lake's reply, compile-command build in the Lean fixture fills lake@main's compilation buffer with the fixture's output and ends exited abnormally with code 1"
      run :=
        withProjects compile fun rig base => do
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
        withProjects compile fun rig base => do
          let bar := base / "lake" / "Foo" / "Bar.lean"
          let some (stepped, texts) ←
            runSettled rig base [openFile bar, compileCommandOf "build", nextError] | return false
          return locationsAt stepped (base / "lake") ==
                #[("lean", bar.toString, 12, some 4, some "unknown identifier 'x'")] &&
              (← focusedAt rig texts stepped) == some (bar.toString, 11, 4) },
    { name :=
        "modes criterion 11: with the fixture mise's replies, mise-mode offers the fixture's tasks in the mise tree, after cargo-mode's in the nested crate, and running test, whose output is rustc's errors, finds them through cargo-mode's format in the nested crate"
      run :=
        withProjects compile fun rig base => do
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
        withProjects compile fun rig base => do
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
