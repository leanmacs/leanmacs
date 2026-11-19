import Compile.EditorPackage
import CompileTest.Check
import CompileTest.Linked.Compile
import CompileTest.Linked.Compile.Shipped
import Editor
import Editor.Headless
import Editor.Test.Linked.Services
import EditorCore.EditorPackage

/-!
# The linked test of the package `compile`

The root of an executable linked as the editor is linked, with the glue and
the Rust library (the core's `editorLinked` facet,
`lake build +CompileTest.Linked:editorLinked`): the tests of the package
that need the real library. The gate builds it in `mise run lean` and runs
it in `mise run ffi-test` (`tools/package-set.sh`), in the package's
directory, with the toolchain's directory and the core's `.olean` directory
as its arguments.

It runs the linked test modules, under `CompileTest/Linked/`, each of which
mirrors the module it tests, and a check of its own:

- `compileRunChecks` (`CompileTest/Linked/Compile.lean`): over the real
  process service, the fixture `tests/compile/three-lines` shows each of
  its lines in the compilation buffer before it ends, and its exit status
  in the last line; its child is reaped;
- `projectRunChecks` (`CompileTest/Linked/Compile/Shipped.lean`): the
  shipped modes over the real process service, with the programs of
  `tests/compile/bin` standing in for cargo, lake, mise and git first on
  each child's `PATH`, in copies of the trees of `tests/compile`: what
  `compile-command` runs fills the compilation buffer, `next-error` visits
  the tool's location, mise's tasks are offered, and two worktrees keep
  separate error lists;
- `hostCheck`, here: a compile in the headless host, handed the packages a
  set that holds this package hands its editor, in a temporary working
  directory. The script `tests/linked/run/script` starts a child that
  writes one error line and blocks, steps to its location, kills it and
  recompiles; the host's output holds that directory's path, so it is not
  compared with a file: each line of `tests/linked/run/holds` must be part
  of a line of it. The script and that list were written against the
  editor with the compile mode still in the core (`tests/headless/compile-run`
  then), and moved here byte for byte.

**The check of the host is here, in the root, and not in a module under
`CompileTest/Linked/`**: it names the headless host, the config base and
the core's entry module, which only the root of a linked test may import
(`docs/design/packages.md`, "What a package may import").

**One table of waits.** The host makes the process's table of waits and
starts its one completion pump (`Editor.Headless.shipped`), so it is
started first, and the services the other checks run over are made over
the host's table (`Editor.Test.Linked.Services.over`): a second pump would
take the first one's completions.

It imports the config base, `Editor`, for the link alone, as every root
that links the elaborator does: the elaborator imports the base's modules
from their `.olean` files at runtime, and each must already be linked into
the executable. The config the host loads registers nothing and names no
declaration of this package, so the host is told to elaborate it on
`Editor` alone, found in the core's `.olean` directory.
-/

/-- The packages a set that holds this Lake package hands its editor: the
core's, which this package requires, then its own, the order the
package-set build registers them in. -/
def setPackages : Array Editor.Package :=
  EditorCore.EditorPackage.packages ++ Compile.EditorPackage.packages

/-- The directory of the fixtures the checks over the real process service
run, from the package's directory, where the gate runs this executable. -/
def fixturesDirectory : System.FilePath :=
  "tests/compile"

/-- The config directory the host loads: the one of the package's headless
fixture `ex-names`, whose `setup` registers nothing. -/
def hostConfigDirectory : String :=
  "tests/headless/ex-names/config"

/-- The script `hostCheck` runs. -/
def hostScriptFile : System.FilePath :=
  "tests/linked/run/script"

/-- The file of what the host must print: each of its lines must be part of
a line the host printed. -/
def hostHoldsFile : System.FilePath :=
  "tests/linked/run/holds"

/-- A compile in the headless host `host`, whose output is collected in
`printed`: the script of `hostScriptFile` is run with a temporary directory
of the check's own as the editor's working directory, where the child runs
and where its location's file is looked for, and it must run to its end
with every line of `hostHoldsFile` part of a line the host printed. What is
missing is said on stderr. -/
def hostCheck {β σ : Type} {scheme : Editor.InputScheme}
    (host : Editor.Headless.Collaborators β σ scheme) (printed : IO.Ref (Array String)) :
    CompileTest.Check :=
  { name :=
      "a compile in the headless host over the core's packages and this package's, in a temporary working directory: the script tests/linked/run/script runs to its end, and what the host prints holds each line of tests/linked/run/holds: the run job started, the child's error line in the compilation buffer, a compilation.error decoration, the visit's echo of a file that is not there, no earlier location, Compilation killed in the echo area and in the buffer, and the run job started again by recompile"
    run := do
      let directives ←
        IO.ofExcept
            ((Editor.Headless.script (← IO.FS.readFile hostScriptFile)).mapError IO.userError)
      let required := ((← IO.FS.readFile hostHoldsFile).splitOn "\n").filter (!·.isEmpty)
      let directory ← IO.FS.createTempDir
      try
        let failure ←
          Editor.Headless.run
              { host with
                workingDirectory := ← IO.FS.realPath directory
                display := fun snapshots =>
                  Editor.Headless.Host.Display.recorder Editor.Headless.cells snapshots }
              directives Editor.Headless.settlePatience
        let lines ← printed.get
        let missing :=
          required.filter fun part => !lines.any fun line => (line.splitOn part).length > 1
        if let some failure := failure then
          IO.eprintln
              s!"compile linked test: the host's script did not run to its end: {failure.describe Editor.Headless.settlePatience}"
        for part in missing do
          IO.eprintln s!"compile linked test: the host printed no line holding: {part}"
        unless missing.isEmpty do
          IO.eprintln s!"compile linked test: the host printed {lines}"
        return failure.isNone && missing.isEmpty && !required.isEmpty
      finally
        IO.FS.removeDirAll directory }

/-- Runs the host's check, then the checks over the real process service,
and exits 0 when all hold, 1 after naming on stderr the ones that do not,
and 2 for a command line that is not the two directories. The exit is
explicit, after the library's services are shut down and its queues quit,
as the headless mode's is: a task may still be blocked in the library. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [sysroot, oleans] =>
    let fixtures ← IO.FS.realPath fixturesDirectory
    let printed ← IO.mkRef (#[] : Array String)
    -- The host first: it makes the process's one table of waits and starts
    -- its one pump, which the services of the other checks then share.
    let host ←
      Editor.Headless.shipped setPackages #[`Editor] sysroot [oleans] hostConfigDirectory
          (fun line => printed.modify (·.push line)) .headless (fakeClock := true)
    let services ← Editor.Test.Linked.Services.over host.services.completions
    let checks :=
      [hostCheck host printed] ++ CompileTest.compileRunChecks services.jobs fixtures ++
        CompileTest.projectRunChecks services.jobs fixtures (fixtures / "bin")
    let failed ← CompileTest.failures checks
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    if failed.isEmpty then
      IO.println s!"compile linked test: {checks.length} checks passed"
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  | _ =>
    IO.eprintln "usage: CompileTest-Linked <sysroot> <core olean dir>"
    return 2
