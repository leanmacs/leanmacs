import CompileApiTest.Check
import CompileApiTest.CompileApi
import CompileApiTest.CompileApi.Format
import CompileApiTest.CompileApi.Listing

/-!
# The test driver of the package `compile-api`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive. It only
imports the test modules and runs their checks, which were the core's
(`ModelTest.<name>`) while the vocabulary was the core's, with their
sentences as they were:

- `contributionChecks`: a contribution as data (`CompileApi.lean`), pure:
  its defaults, its marker mode, and a hook's project commands and settings
  by a project's identity; and the two extension points and the hook that
  reads them, on the core kit's hosted registry: config's contributions
  before the packages', each mode once as its latest, what a reload
  replaces, the three refusals, the later of two of one mode or of one
  project and mode in one `setup`, a package's project commands after
  config's, and the later of two packages' contributions of one mode;
- `compileApiChecks`: the interface's fake (`CompileApiTest.fake`) keeps its
  contract; the contract fails a package that registers, past the
  operations, a contribution with no marker, one that names a command
  twice, or project commands that do; and the two points' keys are the
  types' full names;
- `formatDataChecks`: an error format as data (`CompileApi/Format.lean`),
  pure, with no matcher: the severities' names, a step and an optional
  step, a format's defaults, the general format's parts, and the two tree
  helpers;
- `listingChecks`: a contribution's computed commands
  (`CompileApi/Listing.lean`), on the loop's driver over the core kit's
  opener, with stand-ins over the core's API for a file's workspace and its
  modes on markers: a mode that turns on runs its listing once in its root,
  a failed listing keeps why and says it once, what is kept where, no
  listing where commands cannot run, each end of a run's words, and an
  order's and an entry's round trip;
- `turnOnModesChecks`: turning a buffer's on-modes on
  (`Workspace.turnOnModes`, `Workspace.onModesOf`, `CompileApi/Listing.lean`),
  on the same driver: the on-modes kept nearest first and read back, each a
  minor mode with the nearest first, the listing checked of one that has
  one, and none turned on leaving the buffer as it was; and the marker
  settings (`Workspace.markerSettings`), the loop's workspace settings with
  the marker modes of the hook's contributions.
-/

/-- Every check of the test driver, in the order they run. -/
def CompileApiTest.checks : List CompileApiTest.Check :=
  CompileApiTest.contributionChecks ++ CompileApiTest.compileApiChecks ++
    CompileApiTest.formatDataChecks ++
    CompileApiTest.listingChecks ++
    CompileApiTest.turnOnModesChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← CompileApiTest.failures CompileApiTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"compile-api-test: {CompileApiTest.checks.length} checks passed"
    return 0
  else
    return 1
