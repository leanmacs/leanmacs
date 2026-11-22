import ExTest.Check
import ExTest.Ex
import ExTest.Ex.Compiled

/-!
# The test driver of the package `ex`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of `Ex.lean` are
in `ExTest/Ex.lean` and those of `Ex/Compiled.lean` in
`ExTest/Ex/Compiled.lean`. They run on the core's test kit. They were the
core's (`ModelTest.exChecks`, `ModelTest.exPackageChecks`) while the ex
line was two modules of the core, and moved here with their sentences as
they were.

- `exChecks`: the ex command line (`Ex.lean`) on the loop's driver over
  the editor's models, the model of files and the test scheme, with the
  commands the package registers, `files-api`'s fake's and the kit's
  minibuffer's, keys of the test scheme bound to the ex command and to the
  accept and cancel commands, and ex bindings written in the test: the ex
  command opens a prompt, and the accepted line runs the command its name
  is bound to, as a step of its own, with the rest of the line as its
  argument; a name nobody bound, an argument a name does not take, an
  empty line, a bound command that is not registered or is refused, and a
  cancelled line; `e`, `w`, `q`, `wq` and `reload` over `files-api`'s
  fake, the quit that waits for a save and the one a refused save
  withdraws; `wq` with no files implementation; the prompt's candidates,
  the `:!` history then the bound names; a bang line, on `shell-api`'s
  fake: what it hands `shell-command` and `shell-filter`, a range that
  resolves to no lines, and `:!` with nothing after it; that the package
  binds none of Vim's ex names for marks; and the completion sources'
  contract over the ex line's two sources;
- `exPackageChecks`: the `Package` value (`Ex/Compiled.lean`): the ex
  names it binds, the files', its own and the buffers', in order, and no
  other; what it registers, its four commands, twelve ex names and two
  sources, and nothing else; and the package held to the contract of
  `ex-api` (`ExApiTest.contractChecks`), with a check that it bites.

The ex line through the headless host over the real elaborator is the
linked test's (`ExTest/Linked.lean`).
-/

/-- Every check of the test driver, in the order they run. -/
def ExTest.checks : List ExTest.Check :=
  ExTest.exChecks ++ ExTest.exPackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← ExTest.failures ExTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"ex-test: {ExTest.checks.length} checks passed"
    return 0
  else
    return 1
