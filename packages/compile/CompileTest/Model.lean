import CompileTest.Check
import CompileTest.Compile
import CompileTest.Compile.Compiled
import CompileTest.Compile.Contribution
import CompileTest.Compile.Errors
import CompileTest.Compile.Shipped

/-!
# The test driver of the package `compile`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of `Compile.lean`
are in `CompileTest/Compile.lean`, and those of `Compile/Errors.lean` in
`CompileTest/Compile/Errors.lean`. What several of them share is in
`CompileTest/Support/Compile.lean`. The checks that need the Rust library
are the linked test's (`CompileTest/Linked.lean`), in test modules under
`CompileTest/Linked/`, which mirror the same paths.

The checks run on the core's test kit (`Editor.Test.…`, a test double the
core publishes; `docs/design/packages.md`, "What a package may import"):
the loop's driver over the editor's models, the job model and the process
model, with the worlds of files, workspaces and the shell the core's own
tests use. They were the core's (`ModelTest.<name>`) while the compile
mode was a module of the core, and moved here with their sentences as they
were.

- `compileChecks`: the compile commands (`Compile.lean`), on the loop's
  driver over the editor's models, the job model and the process model;
- `compileErrorChecks`: error formats, the matcher, sites and `resolve`
  (`Compile/Errors.lean`), pure, with no driver;
- `compileLocationChecks`: the locations the compile mode finds in its
  output and the steps over them (`Compile.lean`, "Locations"), on that
  driver;
- `compileHookChecks`: the compile hook (`Editor/Workspace/Modes.lean`,
  `Compile.lean`, "The hook"), on that driver, with contributions
  registered as config registers them; and what the hook makes of a
  `setup` written as compiled code: a shipped contribution with one field
  overridden, and a contribution with a format of its own and project
  commands;
- `compileOfferChecks`: the commands the compile mode offers
  (`Compile.offers`, `Compile/Contribution.lean`), pure;
- `compileListedChecks`: what the compile mode makes of a contribution's
  computed commands, which `compile-command` offers and runs
  (`Compile.lean`), on that driver over the core's listing;
- `projectFormatChecks`: the shipped error formats (`Compile/Shipped.lean`,
  "The formats"), pure;
- `miseTaskChecks`: the reader of mise's task list (`Compile.miseTasks`,
  `Compile/Shipped.lean`), pure;
- `projectModeChecks`: the shipped modes (`Compile/Shipped.lean`), on that
  driver, with only the shipped contributions registered;
- `compilePackageChecks`: the `Package` value (`Compile/Compiled.lean`):
  the ex names it binds, each to a command it registers, and what the
  package registers on its own, each entry for the owner `compile`.
-/

/-- Every check of the test driver, in the order they run. -/
def CompileTest.checks : List CompileTest.Check :=
  CompileTest.compileChecks ++ CompileTest.compileErrorChecks ++
    CompileTest.compileLocationChecks ++
    CompileTest.compileHookChecks ++
    CompileTest.compileOfferChecks ++
    CompileTest.compileListedChecks ++
    CompileTest.projectFormatChecks ++
    CompileTest.miseTaskChecks ++
    CompileTest.projectModeChecks ++
    CompileTest.compilePackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← CompileTest.failures CompileTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"compile-test: {CompileTest.checks.length} checks passed"
    return 0
  else
    return 1
