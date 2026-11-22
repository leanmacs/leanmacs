import Editor
import Editor.Test.Linked.Host
import Editor.Test.Linked.Services
import Ex.EditorPackage
import ExTest.Check
import ExTest.Linked.Ex

/-!
# The linked test of the package `ex`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory. It prints `ex linked test: N checks passed`, and exits
0 when all hold, 1 after naming on stderr the ones that do not, and 2 for a
command line that is not the two directories. The exit is explicit, after
the library's services are shut down and its queues quit: a task may still
be blocked in the library.

Its checks are the ex line's through the headless host over the real
elaborator, the real queue, the real text binding and the library's file
service, in `ExTest/Linked/Ex.lean`, which mirrors the module it tests;
they were the config test's (`ConfigTest.exChecks`,
`ConfigTest.exScriptChecks`) while the ex line was two modules of the
core:

- `exChecks`: the ex command line through the host, with the test scheme
  and the ex line's commands and the `ex` package's ex names as compiled
  code hands them: the ex line `reload` reloads the config with no
  restart, so a key config rebound runs the other command; an ex name
  config binds runs config's command, and is unknown after a reload
  without it; config's binding of a shipped name runs in its place until
  a reload drops it; and a name nobody bound is said in the scene's echo,
  with the editor going on;
- `exScriptChecks`: scripts that a command ends, with `Headless.run` on
  scripts built in the test, over the library's file service: `e` on a
  file in a temporary directory, a commit, `w`, a join and `q`, and the
  same with `wq` and a join after it, each leave the file holding the
  buffer's text and end the script with no failure and the `show` line
  after the quit not run; a `q` that is refused leaves the script running;
  once a step said stop the host runs no further invocation; and a wait on
  a host whose loop a command ended answers `ended`.

They are handed the context of a harness of hosts over the real elaborator
(`Editor.Test.Linked.HostContext.run`), on the base a set that holds this
Lake package elaborates config on, the config base `Editor` and this
package's entry module, `Ex.EditorPackage`, found in the core's `.olean`
directory, this package's and those of the interface packages it requires
(`oleanDirectories`), with the packages this Lake package hands a set's
editor (`setPackages`). Each check hands its host what it registers
itself: the ex package's commands and ex names, `files-api`'s fake and
the kit's minibuffer. It imports the config base, `Editor`, for the link
alone, as every root that links the elaborator does: the elaborator
imports the base's modules from their `.olean` files at runtime, and each
must already be linked into the executable.
-/

/-- The packages this Lake package hands a set's editor: its own. The
core's Lake package, which it requires, hands a set none. -/
def setPackages : Array Editor.Package :=
  Ex.EditorPackage.packages

/-- The directories of the `.olean` files the base's second module,
`Ex.EditorPackage`, and what it imports are found in, from the package's
directory, where the gate runs this executable: this package's own, and
those of the interface packages it requires, `ex-api`, `shell-api` and
`buffers-api`, at the paths its lakefile requires them by. A set's editor is handed each package's directory
the same way (`editor.oleans`). -/
def oleanDirectories : List String :=
  [".lake/build/lib/lean", "../ex-api/.lake/build/lib/lean", "../shell-api/.lake/build/lib/lean",
    "../buffers-api/.lake/build/lib/lean"]

/-- Every check of the linked test, in the order they run, over `context`. -/
def ExTest.Linked.checks (context : Editor.Test.Linked.HostContext) : List ExTest.Check :=
  ExTest.Linked.exChecks context ++ ExTest.Linked.exScriptChecks context

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [sysroot, oleans] =>
    let failed ←
      Editor.Test.Linked.HostContext.run sysroot (":".intercalate (oleans :: oleanDirectories))
          setPackages
          (fun context => do
            let checks := ExTest.Linked.checks context
            let failed ← ExTest.failures checks
            for name in failed do
              IO.eprintln s!"FAILED: {name}"
            if failed.isEmpty then
              IO.println s!"ex linked test: {checks.length} checks passed"
            return failed)
          (imports := #[`Editor, `Ex.EditorPackage])
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  | _ =>
    IO.eprintln "usage: ExTest-Linked <sysroot> <core olean dir>"
    return 2
