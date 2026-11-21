import WorkingSetTest.Check
import WorkingSetTest.WorkingSet
import WorkingSetTest.WorkingSet.Compiled
import WorkingSetTest.WorkingSet.Disk
import WorkingSetTest.WorkingSet.Places
import WorkingSetTest.WorkingSet.Refind
import WorkingSetTest.WorkingSet.Run

/-!
# The test driver of the package `working-set`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of `WorkingSet.lean`
are in `WorkingSetTest/WorkingSet.lean`, and those of `WorkingSet/<X>.lean`
in `WorkingSetTest/WorkingSet/<X>.lean`. They run on the working sets'
driver (`WorkingSetTest/Support/WorkingSet.lean`) and the core's kit, with
evil's kit (`Editor.Evil.Kit`) for the keys, until evil moves out. Every
list but `workingSetPackageChecks` was the core's (`ModelTest.<name>`)
while the working sets were modules of the core, and moved here with its
sentences as they were, in the order the core ran them.

- `workingSetPackageChecks`: the `Package` value (`WorkingSet/Compiled.lean`)
  held to the contract of `working-set-api`
  (`WorkingSetApiTest.contractChecks`), with a check that it bites; and
  what it registers alone, its six commands, its mode and its four jobs
  (that check was `ConfigTest.shippedChecks`' over the core's hosts while
  the package was among the core's);

- `workingSetChecks`: the stored form, pure: the document's JSON round trip
  and the refusals of one it cannot read, a newer version first; a
  workspace's key; a range captured from a text and its points found
  again; the headers; and the excerpts' grouping by file and merging;
- `workingSetRefindChecks`: the re-find ladder
  (`WorkingSet/Refind.lean`), against the fuzzy model: exact, moved
  past lines inserted above, the copy whose context matches over the
  nearer one and the nearer of two alike, changed with one character
  edited, drifted when deleted and when a short quote was edited, a long
  quote found by its ends or drifted without its last lines, text that is
  not ASCII, and a stored point past the text's end;
- `workingSetPlaceChecks`: where a range is held while the editor runs
  (`WorkingSet/Places.lean`), on the loop's driver over the models
  with a workspace at `/r`: a held range follows edits through its
  markers, closing its buffer detaches it as edited, opening the file
  again holds it again, or leaves it drifted when another program removed
  its text, and nothing is attached while the workspace's sets are not
  read;
- `workingSetRunChecks`: `working-set-add` and `working-set-open`
  (`WorkingSet/Run.lean`) on that driver, the first acceptance
  criterion of navigation-and-windows phase 5: a linewise selection added
  and opened as the set's buffer, edited through it, visited and returned
  from; a row of project search's results pinned as its file's range; a
  selection across two files refused; a cursor's row; a range added twice;
  overlapping ranges in one excerpt; the prompt; a set there is none of;
  `working-set-remove`, `working-set-note` and `working-set-refresh` in the
  set's buffer; and, with no files implementation registered, a file open
  nowhere left unloaded and its range drifted, as for a refused load;
- `workingSetDiskChecks`: the sets on disk (`WorkingSet/Disk.lean`)
  on that driver with the state directory `/state` and the version-control
  interface's model at `/r`, the second acceptance criterion: three ranges
  written with `HEAD`'s commit; a fresh editor over the same files, one of
  them edited by another program, opening the set as a changed, a moved
  and a drifted range; the drifted form not moved by a later write; memory
  only with no state directory; a newer or unparsable store left alone; no
  repository; and the writes a save and a close make.
-/

/-- Every check of the test driver, in the order they run. -/
def WorkingSetTest.checks : List WorkingSetTest.Check :=
  WorkingSetTest.workingSetPackageChecks ++ WorkingSetTest.workingSetChecks ++
    WorkingSetTest.workingSetRefindChecks ++
    WorkingSetTest.workingSetPlaceChecks ++
    WorkingSetTest.workingSetRunChecks ++
    WorkingSetTest.workingSetDiskChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← WorkingSetTest.failures WorkingSetTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"working-set-test: {WorkingSetTest.checks.length} checks passed"
    return 0
  else
    return 1
