import FilesTest.Check
import FilesTest.Files
import FilesTest.Files.Compiled
import FilesTest.Files.Paths

/-!
# The test driver of the package `files`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of `Files.lean`
are in `FilesTest/Files.lean`, those of `Files/Compiled.lean` in
`FilesTest/Files/Compiled.lean` and those of `Files/Paths.lean` in
`FilesTest/Files/Paths.lean`. They run on the files' test kit
(`FilesTest/Kit.lean`) and the core's. They were the core's
(`ModelTest.<name>`) while the file commands were modules of the core, and
moved here with their sentences as they were, in the order the core ran
them.

- `filesPackageChecks`: the `Package` value (`Files/Compiled.lean`) held
  to the contract of `files-api` (`FilesApiTest.contractChecks`), and the
  jobs it leaves to its owner to start again after a restart, `check-files`
  and `follow-file`;
- `pathsChecks`: the file source (`Files/Paths.lean`), held to the
  completion sources' contract;
- `fileNameChecks`: `open-file`'s prompt over file names, with the file
  source and the path style;
- `fileCommandChecks`: the file commands (`Files.lean`) on the loop's
  driver over the model of files: opening, saving, a file changed on disk,
  and what each command says when it starts nothing;
- `languageOpenChecks`: the language and the mode `code` a file opens in;
- `fileReloadChecks`, `stalenessChecks` and `autoReloadChecks`: reloading a
  buffer, the check job's staleness and the follow job's auto-reload,
  through the loop, which starts the jobs under the core's names.
-/

/-- Every check of the test driver, in the order they run. -/
def FilesTest.checks : List FilesTest.Check :=
  FilesTest.filesPackageChecks ++ FilesTest.pathsChecks ++ FilesTest.fileNameChecks ++
    FilesTest.fileCommandChecks ++
    FilesTest.languageOpenChecks ++
    FilesTest.fileReloadChecks ++
    FilesTest.stalenessChecks ++
    FilesTest.autoReloadChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← FilesTest.failures FilesTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"files-test: {FilesTest.checks.length} checks passed"
    return 0
  else
    return 1
