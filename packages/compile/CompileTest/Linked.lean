import Compile.EditorPackage
import CompileTest.Check
import CompileTest.Linked.Compile
import CompileTest.Linked.Compile.Real
import CompileTest.Linked.Compile.Shipped
import Editor
import Editor.RealHost
import Editor.Test.AtPoint
import Editor.Test.Ex
import Editor.Test.Linked.Host
import Editor.Test.Linked.Services
import Editor.Test.Shipped
import FilesApiTest.Fake
import MinibufferApiTest.Fake

/-!
# The linked test of the package `compile`

The root of an executable linked as the editor is linked, with the glue and
the Rust library (the core's `editorLinked` facet,
`lake build +CompileTest.Linked:editorLinked`): the tests of the package
that need the real library. The gate builds it in `mise run lean` and runs
it in `mise run ffi-test` (`tools/package-set.sh`), in the package's
directory, with the toolchain's directory and the core's `.olean` directory
as its arguments.

It makes the context of a harness of hosts over the real elaborator
(`Editor.Test.Linked.HostContext.run`, on the config base `Editor`, with
the packages `setPackages`), as the other linked roots make theirs, starts
the library's real services for the check over them
(`Editor.Test.Linked.Services.start`), and runs the linked test modules,
under `CompileTest/Linked/`, each of which mirrors the module it tests:

- `compileHostChecks` (`CompileTest/Linked/Compile.lean`): a compile
  through a host on a stepped stage, handed `setPackages`: its child, the
  stage's process fake, writes one error line and keeps running; the check
  steps to its location, kills it and recompiles; and the visit of
  `next-error` is asked of the scene with its load held in the fake
  scheduler, then once the load has ended (task
  `compile-linked-next-error-settle-race`). It was the script
  `tests/linked/run/script` until host-tests-on-fakes phase 4;
- `compileRunChecks` (`CompileTest/Linked/Compile/Real.lean`, of the wiring set): over the real process service, the
  fixture `tests/compile/three-lines` shows each of its lines in the
  compilation buffer before it ends, and its exit status in the last line;
- `projectRunChecks` (`CompileTest/Linked/Compile/Shipped.lean`): the
  shipped modes on a stepped rig (`ProjectRig.stepped`), its process fake
  answering the canned output of cargo, lake and mise in
  `tests/compile/bin` and its file fake holding the trees of
  `tests/compile`, a file's workspace and its modes on markers given by
  stand-ins: what `compile-command` runs fills the compilation buffer,
  `next-error` visits the tool's location, mise's tasks are offered, and
  two worktrees keep separate error lists.

**The root makes the hosts' context, and the checks are in
`CompileTest/Linked/`**: only the root of a linked test may import the
config base and the headless host's entry points
(`docs/design/packages.md`, "What a package may import"); a module under
`CompileTest/Linked/` runs host checks on the core's linked test kit
(`Editor.Test.Linked.Host`), a stage over the context the root hands it.

**One pump a process.** The real services are started here, with the
process's one completion pump (`Services.start`); the stepped stages and
the stepped rig have tables of waits of their own and no pump.

It imports the config base, `Editor`, for the link alone, as every root
that links the elaborator does: the elaborator imports the base's modules
from their `.olean` files at runtime, and each must already be linked into
the executable. The hosts load no config, so the elaborator is told to
import `Editor` alone, found in the core's `.olean` directory.

Its checks are a check set (`CompileTest.Linked.checks`, `Editor.CheckGroup`,
`docs/dev-practices/real-thread-checks.md`, "How the set runs"):
the lists of its modules of the wiring set in groups of their module, which
the build's `linter.wiringSet` holds true and complete. With `--wiring`
after the two directories it
runs those groups alone, the stress loop's `linked-wiring` suite
(`tools/package-set.sh run --wiring`), and `wiring-modules` prints their
modules, one a line, building nothing.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.CompileTest.Linked : Editor.WiringSet :=
  .edge "its main starts the library's services and pump and hands them to the wiring set's checks"

/-- The packages the hosts of `compileHostChecks` are handed, in place of a
set's (`HostContext.packages`):
the core's test kit's ex line (`Editor.Test.exLinePackage`,
`lean/Editor/Test/Ex.lean`), whose command `ex` the script runs by name
to type each of this package's ex names, in place of the default package
`ex` (the core's own list, which held that package and came first here,
holds no package this check needs: the features-as-packages roadmap's
phase 8), `files-api`'s fake
(`FilesApiTest.fake`), whose `Files` value the visit of a location opens a
file with, in place of the default package `files`, the core's test kit's
stand-in for
the default package `mode-line` (`Editor.Test.Shipped.modeLine`), whose
segments the host's status lines print, as the default editor's do, and
its implementation of the default package `at-point`'s commands
(`Editor.Test.AtPoint.package`), which insert state's `RET`, `TAB` and
`C-g` run, then the fake of the interface package `minibuffer-api`
(`MinibufferApiTest.fake`), whose commands answer the compile prompt,
then its own, the order the package-set build registers them in. -/
def setPackages : Array Editor.Package :=
  #[Editor.Test.exLinePackage, FilesApiTest.fake, Editor.Test.Shipped.modeLine,
      Editor.Test.AtPoint.package, MinibufferApiTest.fake] ++
    Compile.EditorPackage.packages

/-- The directory of the fixtures the checks over the real process service
run, from the package's directory, where the gate runs this executable. -/
def fixturesDirectory : System.FilePath :=
  "tests/compile"

/-- What every check is handed: the harness's context, the job services
started for the run (`Services.start`), and the directory of the fixtures. -/
abbrev CompileTest.Linked.Context :=
  Editor.Test.Linked.HostContext × Editor.Job.Services × System.FilePath

/-- Every check of the linked test, in the order they run: its check set
(`Editor.CheckGroup`), the checks through the host, then those over the
real process service, of the wiring set
(`CompileTest/Linked/Compile/Real.lean`), then the shipped project runs. -/
def CompileTest.Linked.checks :
    List (Editor.CheckGroup CompileTest.Linked.Context CompileTest.Check) :=
  [.plain fun (context, _, _) => CompileTest.compileHostChecks context,
    .wired "CompileTest.Linked.Compile.Real" wiringSet.CompileTest.Linked.Compile.Real
      fun (_, jobs, fixtures) => CompileTest.compileRunChecks jobs fixtures,
    .plain fun (_, _, fixtures) => CompileTest.projectRunChecks fixtures]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`) and says which failed, or how many passed.
The context of the
hosts is made with `HostContext.run`, as the other linked roots make
theirs, and the real services the other checks run over are started here
(`Services.start`), since no host makes the process's table of waits any
more. The exit is explicit, after the library's services are shut down and
its queues quit: a task may still be blocked in the library. -/
private def CompileTest.Linked.runSelected (sysroot oleans : String)
    (mode : Editor.CheckGroup.Mode) : IO UInt32 := do
  let fixtures ← IO.FS.realPath fixturesDirectory
  let failed ←
    Editor.Test.Linked.HostContext.run sysroot oleans setPackages fun context => do
        let services ← Editor.Test.Linked.Services.start
        let checks :=
          Editor.CheckGroup.select mode CompileTest.Linked.checks (context, services.jobs, fixtures)
        let failed ← CompileTest.failures checks
        for name in failed do
          IO.eprintln s!"FAILED: {name}"
        if failed.isEmpty then
          IO.println s!"compile linked test: {checks.length} {mode.what} passed"
        return failed
  (← IO.getStdout).flush
  Editor.Test.Linked.shutdown
  IO.Process.exit (if failed.isEmpty then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def CompileTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: CompileTest-Linked <sysroot> <core olean dir> [--wiring], or CompileTest-Linked wiring-modules"
  return 2

/-- Runs the checks, all or with `--wiring` the wiring set's alone, and
exits 0 when they hold, 1 after naming on stderr the ones that do not;
`wiring-modules` prints the wiring set's modules; and 2 for a command line
it does not take. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules CompileTest.Linked.checks do
      IO.println module
    return 0
  | sysroot :: oleans :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      CompileTest.Linked.runSelected sysroot oleans mode
    | none =>
      CompileTest.Linked.usage
  | _ =>
    CompileTest.Linked.usage
