import Editor
import Editor.RealHost
import Editor.Test.AtPoint
import Editor.Test.Linked.Host
import Editor.Test.Linked.Services
import Editor.Test.Minibuffer
import Editor.Test.Shipped
import Files.EditorPackage
import FilesTest.Check
import FilesTest.Linked.Files
import FilesTest.Linked.Files.Bench
import FilesTest.Linked.Files.Real

/-!
# The linked test of the package `files`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory. It prints `files linked test: N checks passed`, and
exits 0 when all hold, 1 after naming on stderr the ones that do not, and 2
for a command line that is neither the two directories nor the benchmark's. The exit is explicit,
after the library's services are shut down and its queues quit: a task may
still be blocked in the library.

Its checks are the files' through the headless host over the real
elaborator, in `FilesTest/Linked/Files.lean`, which mirrors the module it
tests; they were the config test's (`ConfigTest.<name>`) while the file
commands were modules of the core. Most run on a stepped stage
(`Stage.stepped`), whose file fake the check steps on its own thread; the
save of a modified buffer is the file service's one end-to-end check, and
the auto-reload the watch service's:

- `languageChecks`: a file of a shipped language opens in the mode `code`
  with its grammar attached and highlighted over the real syntax binding;
- `fileChecks`: opening, saving and reopening files through the host, with
  line endings kept and a file changed behind the editor left alone;
- `reloadChecks`: reloading a buffer from its file;
- `filePromptChecks`: the open prompt's candidates over the file fake, with
  the files' source and the path style;
- `autoReloadChecks`: following a file over the library's watch service.
- `realLanguageChecks`, `fileServiceChecks` and `autoReloadChecks` are of
  the wiring set (`FilesTest/Linked/Files/Real.lean`): the library's syntax
  service with the grammars the model does not hold, the file service's
  write and the watch service, end to end.

They are handed the context of a harness of hosts over the real elaborator
(`Editor.Test.Linked.HostContext.run`), on the config base `Editor`, found
in the core's `.olean` directory, with the packages a set that holds this
Lake package hands its editor (`setPackages`). It imports the config base,
`Editor`, for the link alone, as every root that links the elaborator
does: the elaborator imports the base's modules from their `.olean` files
at runtime, and each must already be linked into the executable. The
config the hosts load names no declaration of this package.

With the opt-in argument `bench-auto-reload` it runs the auto-reload row of
`config-bench` instead (`FilesTest.Linked.Bench.autoReloadRow`,
`FilesTest/Linked/Files/Bench.lean`; `mise run config-bench`), which the
gate builds and never runs, over the same context.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.FilesTest.Linked : Editor.WiringSet :=
  .edge "its main runs the auto-reload bench and the wiring set's checks"

/-- The packages a set that holds this Lake package hands its editor, as
the config tests' hosts were handed them: its own (the core's Lake
package, which it requires, hands a set none), then the core's test kit's stand-ins for the
default packages `mode-line` and `languages` (`Editor.Test.Shipped.packages`,
whose segments the host's status lines print and whose languages a file
opens in), and its implementations of the default packages `at-point`'s and
`minibuffer`'s commands, which answer the open prompt. -/
def setPackages : Array Editor.Package :=
  Files.EditorPackage.packages ++ Editor.Test.Shipped.packages ++
    #[Editor.Test.AtPoint.package, Editor.Test.Minibuffer.package]

/-- Every check of the linked test, in the order they run, over `context`. -/
def FilesTest.Linked.checks (context : Editor.Test.Linked.HostContext) : List FilesTest.Check :=
  FilesTest.Linked.filePromptChecks context ++ FilesTest.Linked.fileChecks context ++
    FilesTest.Linked.fileServiceChecks context ++
    FilesTest.Linked.languageChecks context ++
    FilesTest.Linked.realLanguageChecks context ++
    FilesTest.Linked.reloadChecks context ++
    FilesTest.Linked.autoReloadChecks context

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [sysroot, oleans] =>
    let failed ←
      Editor.Test.Linked.HostContext.run sysroot oleans setPackages fun context => do
          let checks := FilesTest.Linked.checks context
          let failed ← FilesTest.failures checks
          for name in failed do
            IO.eprintln s!"FAILED: {name}"
          if failed.isEmpty then
            IO.println s!"files linked test: {checks.length} checks passed"
          return failed
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  | ["bench-auto-reload", sysroot, oleans, samples] =>
    match samples.toNat? with
    | some samples =>
      let failed ←
        Editor.Test.Linked.HostContext.run sysroot oleans setPackages fun context => do
            let failed ← FilesTest.failures [FilesTest.Linked.Bench.autoReloadRow context samples]
            for name in failed do
              IO.eprintln s!"FAILED: {name}"
            return failed
      (← IO.getStdout).flush
      Editor.Test.Linked.shutdown
      IO.Process.exit (if failed.isEmpty then 0 else 1)
    | none =>
      IO.eprintln "usage: FilesTest-Linked bench-auto-reload <sysroot> <core olean dir> <samples>"
      return 2
  | _ =>
    IO.eprintln
        "usage: FilesTest-Linked <sysroot> <core olean dir>, or FilesTest-Linked bench-auto-reload <sysroot> <core olean dir> <samples>"
    return 2
