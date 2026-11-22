import ProjectSearchTest.Check
import ProjectSearchTest.ProjectSearch
import ProjectSearchTest.ProjectSearch.Compiled
import ProjectSearchTest.ProjectSearch.Run

/-!
# The test driver of the package `project-search`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`ProjectSearch.lean` are in `ProjectSearchTest/ProjectSearch.lean`, and
those of `ProjectSearch/<X>.lean` in `ProjectSearchTest/ProjectSearch/<X>.lean`.
They run on the core's kit, under the test scheme, and import no module of
evil (the phase's acceptance criterion 3). Every list but
`projectSearchPackageChecks` was the core's (`ModelTest.<name>`) while
project search was modules of the core, and moved here with its sentences
as they were, in the order the core ran them.

- `projectSearchPackageChecks`: the `Package` value
  (`ProjectSearch/Compiled.lean`) held to the contract of
  `project-search-api` (`ProjectSearchApiTest.contractChecks`), with a check
  that it bites; what it registers alone, its four commands, its mode and
  its two jobs (that check was `ConfigTest.shippedChecks`' over the core's
  hosts while the package was among the core's); and that its search job is
  the one it registers reported, and none restarted (which
  `ModelTest.packageSetChecks` held over the core's list);
- `projectSearchChecks`: project search's pure core (`ProjectSearch.lean`):
  the rows an excerpt shows, merged and clipped; where a file's excerpts go
  when they arrive out of order; the record's round trip; and each
  sentence;
- `projectSearchRunChecks`: `project-search` and its results buffer
  (`ProjectSearch/Run.lean`) on the loop's driver over the editor's models
  and the job model, under the test scheme.
-/

/-- Every check of the test driver, in the order they run. -/
def ProjectSearchTest.checks : List ProjectSearchTest.Check :=
  ProjectSearchTest.projectSearchPackageChecks ++ ProjectSearchTest.projectSearchChecks ++
    ProjectSearchTest.projectSearchRunChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← ProjectSearchTest.failures ProjectSearchTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"project-search-test: {ProjectSearchTest.checks.length} checks passed"
    return 0
  else
    return 1
