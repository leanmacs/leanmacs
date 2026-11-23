# Inferred waits

Every wait in a test that works out "done" from something shared rather
than from a signal for its own work, one row per check or fixture, with the
collaborator it depends on and the phase of the roadmap
`host-tests-on-fakes` that removes it, or why it stays. The list is the work
queue of phases 3 to 5; phase 6 places the rows that stay into its
wiring-set modules.

## The kinds

- **a**: a wait on the activity count or idle as a stand-in for one piece
  of work: a `join`, `idle` or `quiet` of a host, a rig's idle, a service's
  pending count read before and after.
- **b**: a "first X after Y" wait that another thread's X can satisfy: the
  first pull parked on a queue (`Ffi.awaitWaiting`), the count-th start a
  real port is handed (`startsArrive`), the first wait on the host's fake
  clock (`clockReaches`).
- **c**: teardown that races real background work, such as removing a
  directory while a write, a remove, a child or a watch may be in flight.
- **d**: a real background effect asserted on disk or in a service rather
  than at the port.

## How the list is held

Kinds a and b cannot be written outside the modules they are allowed in.
Each such wait is a constant marked `@[inferred_wait <kind> <subject
module>*]`, and `lake build`'s `linter.inferredWait`
(`lean/Editor/Lint/Wait.lean`) refuses a reference to one anywhere but its
own module, the subject modules it names and the test modules that mirror
them (`ModelTest.Editor.Job.Activity` mirrors `Editor.Job.Activity`). In the
own or a subject module, when that is a test module, a public declaration
that references one must carry the attribute itself, so a kit cannot hand a
restricted wait on to everyone: the kit's waits that are built on them
(`Session.join`, `Session.ran`, `Rig.idle`, `childrenReapedTo` and the
others) carry it. The marked constants:

| Constant | Kind | Allowed in, beside its own module and the mirrors |
|---|---|---|
| `Job.Activity.seen`, `.changedSince`, `Activity.Seen.idleSince` | count | the runner, the hosts (`Headless`, `Headless.Stepped`, `Headless.Wait`), the loop, the handle contract, the job kits (`Editor.Test.Jobs`, `Editor.Test.Linked.Jobs`) |
| `Test.changedAfter`, `Test.untilEpoch`, `HandleContract.changedAfter` | count | `Editor.Job.Runner`, `Editor.Job.Activity` |
| `Test.Rig.idle`, `Rig.spawn`, `Rig.stepToEnd`, `Test.Linked.untilIdle` | idle | `Editor.Job.Runner`, `Editor.Job.Activity` |
| `Test.runOnFake` | idle | none |
| `Headless.Host.join`, `Headless.Stepped.join` | idle | `Editor.Headless.Wait`, `Editor.Test.Linked.Host` |
| `Driven.join`, `Driven.idle`, `Driven.quiet`, `Session.join`, `Session.idle`, `Session.quiet`, `Session.ran` | idle | `Editor.Headless.Wait` |
| `Ffi.filesPending`, `diffsPending`, `grepPending`, `processesPending`, `watchesPending`, `timersPending` | count | the job port's real binding and contracts (`Editor.Job.Real`, `.Contract`, `.FlushContract`, `.HandleContract`), `Editor.Test.Linked.Services` |
| `Test.Linked.pendingChildren`, `childrenReapedTo` | count | none |
| `Ffi.awaitWaiting`, `Test.Linked.startsArrive`, `Test.Linked.clockReaches` | firstAfter | none |

`realEffect`, the fourth kind the attribute takes, marks a real service's
readout whose fake exists; phase 3 marks each as its fake lands.

A site that a later phase removes, or that stays, keeps an explicit allow,
`set_option linter.inferredWait false in` on the declaration that holds it,
with its row beside it: `-- inferred-waits W<n>: removed by host-tests-on-fakes
phase <k>`, or `-- inferred-waits W<n>: stays (<why>)`. The phase that
removes a row deletes its allow. An allow is on the check list that holds
the wait, not on each check: a list's other checks are not refused a new
one while the allow is there, which the phases that delete the allows end.
That `lake build` is green with the linter on is what makes the rows of
kinds a and b complete: every reference left is in an allowed module or
under an allow named here.

Kinds c and d are not lintable in this phase, and their rows come from
reading the brackets that remove a directory, the disk reads after a host
step, the service counts read outside the bindings, the headless fixtures'
directives and the Rust crates' readouts. The Rust readout waits are held
by clippy (`mise run lint`): they take an `editor_wait::HangGuard`, and
`disallowed-methods` refuses each outside its own tests, its adapter's
contract and the C exports the Lean checks call (`clippy.toml`).

## The rows

| Row | File and check | Kind | Collaborator | Real service | Removed by | Held by | Task |
|---|---|---|---|---|---|---|---|
| W1 | `lean/ConfigTest/Bench.lean`, `prompt`: `Editor.Headless.Host.join` | a | loop thread and every service (the host's idle) | real | Stays: an opt-in bench over real time, never part of `ci`; phase 6 places it | `linter.inferredWait`; allowed at `prompt` |  |
| W2 | `lean/ConfigTest/Editor/AtPoint.lean`, `atPointChecks`: `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `atPointChecks` |  |
| W3 | `lean/ConfigTest/Editor/Completion/Keys.lean`, `keyHintChecks`: `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `keyHintChecks` |  |
| W4 | `lean/ConfigTest/Editor/Extension.lean`, `extensionChecks`: `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `extensionChecks` |  |
| W5 | `lean/ConfigTest/Editor/Headless.lean`, `withdrawingHeld`: `Editor.Test.Linked.clockReaches` | b | clock | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `withdrawingHeld` |  |
| W6 | `lean/ConfigTest/Editor/Headless.lean`, `jobChecks`: `Editor.Test.Linked.Session.idle`, `Editor.Test.Linked.Session.join`, `Editor.Test.Linked.clockReaches` | a, b | loop thread and every service (the host's idle), clock | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `jobChecks` |  |
| W7 | `lean/ConfigTest/Editor/Headless.lean`, `scriptChecks`: `Editor.Test.Linked.Session.idle`, `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `scriptChecks` |  |
| W8 | `lean/ConfigTest/Editor/Headless.lean`, `hostLoopChecks`: `Editor.Test.Linked.Session.join`, `Editor.Test.Linked.clockReaches` | a, b | loop thread and every service (the host's idle), clock | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `hostLoopChecks` |  |
| W9 | `lean/ConfigTest/Editor/Headless.lean`, `watchReloadChecks`: `Editor.Test.Linked.Session.idle`, `Editor.Test.Linked.Session.join`, `Editor.Test.Linked.Session.quiet` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `watchReloadChecks` |  |
| W10 | `lean/ConfigTest/Editor/Headless.lean`, `restoreOrderChecks`: `Editor.Test.Linked.Driven.idle`, `Editor.Test.Linked.Driven.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `restoreOrderChecks` |  |
| W11 | `lean/ConfigTest/Editor/Headless/Stepped.lean`, `steppedChecks`: `Editor.Headless.Host.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `steppedChecks` |  |
| W12 | `lean/ConfigTest/Editor/Loop.lean`, `dispatchChecks`: `Editor.Test.Linked.clockReaches` | b | clock | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `dispatchChecks` |  |
| W13 | `lean/ConfigTest/Editor/Minibuffer.lean`, `promptChecks`: `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `promptChecks` |  |
| W14 | `lean/ContractTest/Editor/Completion/Filtering.lean`, `foundThrough`: `Editor.Ffi.processesPending`, `Editor.Test.Linked.childrenReapedTo` | a | processes | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `foundThrough` |  |
| W15 | `lean/ContractTest/Editor/File/Cases.lean`, `caseFailures`: `Editor.Ffi.filesPending` | a | files | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `caseFailures` |  |
| W16 | `lean/ContractTest/Editor/Job/Contract.lean`, `processFailures`: `Editor.Test.Linked.childrenReapedTo` | a | processes | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `processFailures` |  |
| W17 | `lean/ContractTest/Editor/Job/FlushContract.lean`, `flushRealRigs`: `Editor.Test.Linked.pendingChildren` | a | processes | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `flushRealRigs` |  |
| W18 | `lean/ContractTest/Editor/Job/Real.lean`, `processChecks`: `Editor.Test.Linked.childrenReapedTo`, `Editor.Test.Linked.startsArrive` | a, b | processes, the started service | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `processChecks` |  |
| W19 | `lean/ContractTest/Editor/Job/Real.lean`, `jobChecks`: `Editor.Ffi.awaitWaiting`, `Editor.Test.Linked.startsArrive` | b | pump, the started service | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `jobChecks` |  |
| W20 | `lean/ContractTest/Editor/Job/Real.lean`, `fileChecks`: `Editor.Test.Linked.startsArrive`, `Editor.Test.Linked.untilIdle` | a, b | the started service, job runner (the rig's count) | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `fileChecks` |  |
| W21 | `lean/ContractTest/Editor/Job/Real.lean`, `grepChecks`: `Editor.Test.Linked.untilIdle` | a | job runner (the rig's count) | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `grepChecks` |  |
| W22 | `lean/ContractTest/Editor/Process/Environment.lean`, `environmentChecks`: `Editor.Ffi.processesPending`, `Editor.Test.Linked.childrenReapedTo` | a | processes | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `environmentChecks` |  |
| W23 | `lean/ModelTest/Editor/Job/Contract.lean`, `snapshotReadChecks`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `snapshotReadChecks` |  |
| W24 | `lean/ModelTest/Editor/Job/Contract.lean`, `jobRunnerFailures`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `jobRunnerFailures` |  |
| W25 | `lean/ModelTest/Editor/Job/Contract.lean`, `postedOnFake`: `Editor.Test.Rig.stepToEnd` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `postedOnFake` |  |
| W26 | `lean/ModelTest/Editor/Job/Contract.lean`, `fuzzyJobFailures`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `fuzzyJobFailures` |  |
| W27 | `lean/ModelTest/Editor/Job/Contract.lean`, `runFilesOnFake`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `runFilesOnFake` |  |
| W28 | `lean/ModelTest/Editor/Job/Contract.lean`, `runProcessesOnFake`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `runProcessesOnFake` |  |
| W29 | `lean/ModelTest/Editor/Job/Contract.lean`, `runWatchesOnFake`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `runWatchesOnFake` |  |
| W30 | `lean/ModelTest/Editor/Job/Contract.lean`, `snapshotJobFailures`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `snapshotJobFailures` |  |
| W31 | `lean/ModelTest/Editor/Job/Jobs.lean`, `ownerChecks`: `Editor.Test.Rig.idle` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `ownerChecks` |  |
| W32 | `lean/ModelTest/Editor/Process/Model.lean`, `processChecks`: `Editor.Test.Rig.idle`, `Editor.Test.Rig.spawn`, `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `processChecks` |  |
| W33 | `packages/compile/CompileTest/Linked/Compile.lean`, `compileRunChecks`: `Editor.Test.Linked.childrenReapedTo`, `Editor.Test.Linked.pendingChildren` | a | processes | real (linked) | phase 4 | `linter.inferredWait`; allowed at `compileRunChecks` |  |
| W34 | `packages/compile/CompileTest/Linked/Compile/Shipped.lean`, `withProjects`: `Editor.Test.Linked.childrenReapedTo`, `Editor.Test.Linked.pendingChildren` | a | processes | real (linked) | phase 4 | `linter.inferredWait`; allowed at `withProjects` | package-linked-real-thread-inventory |
| W35 | `packages/ex/ExTest/Linked/Ex.lean`, `exScriptChecks`: `Editor.Headless.Host.join`, `Editor.Headless.Stepped.join` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at `exScriptChecks` |  |
| W36 | `packages/files/FilesTest/Linked/Files.lean`, `reportedAfter`: `Editor.Test.Linked.Session.ran` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at `reportedAfter` | package-linked-real-thread-inventory |
| W37 | `packages/files/FilesTest/Linked/Files.lean`, `fileChecks`: `Editor.Test.Linked.Driven.join`, `Editor.Test.Linked.Session.join`, `Editor.Test.Linked.Session.ran` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at `fileChecks` | package-linked-real-thread-inventory |
| W38 | `packages/files/FilesTest/Linked/Files.lean`, `reloadChecks`: `Editor.Test.Linked.Session.ran` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at `reloadChecks` | package-linked-real-thread-inventory |
| W39 | `packages/files/FilesTest/Linked/Files.lean`, `atW`: `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at `atW` | package-linked-real-thread-inventory |
| W40 | `packages/files/FilesTest/Linked/Files.lean`, `filePromptChecks`: `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at `filePromptChecks` | package-linked-real-thread-inventory |
| W41 | `packages/files/FilesTest/Linked/Files.lean`, `autoReloadChecks`: `Editor.Test.Linked.Session.ran` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at `autoReloadChecks` | package-linked-real-thread-inventory |
| W42 | `packages/files/FilesTest/Linked/Files/Bench.lean`, `autoReloadRow`: `Editor.Test.Linked.Session.ran` | a | loop thread and every service (the host's idle) | real | Stays: an opt-in bench over real time, never part of `ci`; phase 6 places it | `linter.inferredWait`; allowed at `autoReloadRow` | package-linked-real-thread-inventory |
| W43 | `packages/shell/ShellTest/Linked/Shell.lean`, `shellChecks`: `Editor.Ffi.processesPending`, `Editor.Test.Linked.childrenReapedTo` | a | processes | real (linked) | phase 4 | `linter.inferredWait`; allowed at `shellChecks` |  |
| W44 | `packages/version-control/VersionControlTest/Linked/VersionControl/Git.lean`, `versionControlFailures`: `Editor.Ffi.processesPending`, `Editor.Test.Linked.childrenReapedTo` | a | processes | real (linked) | phase 4 | `linter.inferredWait`; allowed at `versionControlFailures` |  |
| W45 | `packages/workspace/WorkspaceTest/Linked/Workspace/Bench.lean`, `workspaceFiles`: `Editor.Headless.Host.join` | a | loop thread and every service (the host's idle) | real | Stays: an opt-in bench over real time, never part of `ci`; phase 6 places it | `linter.inferredWait`; allowed at `workspaceFiles` |  |
| W46 | `packages/workspace/WorkspaceTest/Linked/Workspace/Contract.lean`, `workspaceFailures`: `Editor.Test.Linked.childrenReapedTo`, `Editor.Test.Linked.pendingChildren` | a | processes | real (linked) | phase 4 | `linter.inferredWait`; allowed at `workspaceFailures` |  |
| W47 | `packages/workspace/WorkspaceTest/Linked/Workspace/Finder.lean`, `findsThrough`: `Editor.Test.Linked.childrenReapedTo`, `Editor.Test.Linked.pendingChildren` | a | processes | real (linked) | phase 4 | `linter.inferredWait`; allowed at `findsThrough` |  |
| W48 | `packages/workspace/WorkspaceTest/Linked/Workspace/Lister.lean`, `listsAt`: `Editor.Test.Linked.childrenReapedTo`, `Editor.Test.Linked.pendingChildren` | a | processes | real (linked) | phase 4 | `linter.inferredWait`; allowed at `listsAt` |  |
| W49 | `lean/ContractTest/Editor/Restore/Run.lean`, `withJournalledDirectory` and its six checks (two tabs restored on the real text binding and file service among them): the directory is removed once `filesDrained`, one flush of the process-wide file service, has completed; and `runRestoring` drops each journal order's task, so the drain before the second loop infers the first loop's writes from the shared FIFO | a, c | journal, files | real file service (and the held fake journal) | phase 3 | not lintable: kind c/d | restore-contract-tabs-enoent-under-load |
| W50 | `lean/FfiTest/Support/Files.lean`, `inOwnDirectory` (Files ×10, Diffs, Syntax, Theme/Picture: files only; Processes ×7, Watches ×3, Grep ×3: their service too): flushes the named services, then removes the directory; the diff and syntax services are not flushed | c | files, diff, syntax, processes, watches, grep | real | Stays: the bindings' own checks over the library's services; phase 6 places it | not lintable: kind c/d |  |
| W51 | `lean/FfiTest/Editor/Window/Real.lean`, `windowHostRestartScenario`: the directory goes after the shutdown's journal drain, one flush of the file service with no deadline | c | journal, files | real | Stays: the real window host's restart is its subject; phase 6 places it | not lintable: kind c/d |  |
| W52 | `lean/Editor/Test/Linked/Trees.lean`, `withBase`, and through it `ContractTest.filteringChecks`, `VcApiTest.Linked.withRepository` (`versionControlChecks`, `historyBufferChecks`, `reviewBufferChecks`, `statusBufferChecks`, `workingSetChecks`, `workspaceListerChecks`) and `WorkspaceTest.Linked.workspaceChecks`: `removeDirAll` with no flush, while real git children or unobserved file writes may still run | c | files, processes | real | phase 4 (the package linked tests); `filteringChecks` stays, an adapter's contract | not lintable: kind c/d | package-linked-real-thread-inventory |
| W53 | `lean/Editor/Test/Linked/Services.lean`, `withFiles` (`workedBefore`): flushes only the named `targets`, then removes the directory; `VersionControlTest.Linked.gutterChecks` names files and diffs while its host runs real git and a real repository watch, and `FilesTest.Linked.languageChecks` names files while a real syntax service runs | c | files, diff, processes, watches, syntax | real | phase 4 | not lintable: kind c/d | package-linked-real-thread-inventory |
| W54 | `packages/compile/CompileTest/Linked.lean`, the host check over `tests/linked/run/script` (`Headless.run`): `finally removeDirAll directory` with no process or file flush, after the script killed a child and joined | c | processes, files | real | phase 5 | not lintable: kind c/d | compile-linked-next-error-settle-race |
| W55 | The `withReal*` hosts: `Test.Linked.withRealHostOver`/`withRealHost` (fake services), `withRealShippedHost`, `ConfigTest.withRealTestHost`, `EvilTest.withRealVimHost` (real syntax), `FilesTest.withRealFileHost`/`withRealLanguageHost` (real files, diffs, grep, watches, syntax), `ConfigTest.withRealRecordedSyntaxTree`, `withRealRestoreFiles`: each removes its config directory once the loop has ended, with no flush of a service | c | loop thread, syntax, files, diff, grep, watches | real | phase 4 | not lintable: kind c/d | package-linked-real-thread-inventory |
| W56 | `lean/ConfigTest/Editor/Headless.lean`, "a config's store kept across a restart…" (`lastIndex`): reads the index on disk after `indexWritten`, an idle wait | a, d | journal, files | real | phase 4 | not lintable: kind c/d |  |
| W57 | `lean/ConfigTest/Editor/Headless.lean`, `journalDrainChecks`: `pathExists` after the drain, the file service held and let go | d | journal, files | real | Stays: the journal's drain over the real file service is its subject; phase 6 places it | not lintable: kind c/d |  |
| W58 | `packages/ex/ExTest/Linked/Ex.lean`, `exScriptChecks` (criteria 1 and 2, the refused `q`): `readBinFile` after the script's `join` | a, d | files | real (`Stage.overFiles`) | phase 4 | headless script: not lintable in Lean | package-linked-real-thread-inventory |
| W59 | `packages/files/FilesTest/Linked/Files.lean`, the save checks (save on a modified buffer, open then save with no edit, a save of a file changed on disk) and `autoReloadChecks`: `readBinFile` after the save or at the host's end | d | files, watches, loop thread | real | phase 4 | not lintable: kind c/d | package-linked-real-thread-inventory |
| W60 | `packages/project-search/ProjectSearchTest/Linked/ProjectSearch/Run.lean`, `projectSearchChecks` (criteria 2 and 3): reads the file after `runSettledFrom` | d | files, grep | real | phase 4 | not lintable: kind c/d | package-linked-real-thread-inventory |
| W61 | `packages/version-control/VersionControlTest/Linked/VersionControl/Status.lean`, criterion 1 through vc-stage-hunk: reads the file and `git show` after `runSettled` | d | files, processes | real git | phase 4 | not lintable: kind c/d | package-linked-real-thread-inventory |
| W62 | `packages/working-set/WorkingSetTest/Linked/WorkingSet/Run.lean`, `workingSetChecks` (criteria 1 and 2): reads the store after `runHost` | d | files | real | phase 4 | not lintable: kind c/d | package-linked-real-thread-inventory |
| W63 | The service counts read outside the bindings: `FfiTest` (Files, Processes, Grep, Diffs, Timers, Document, Snapshot: `filesPending`, `processesPending`, `grepPending`, `diffsPending == 0`, `timersPending`, `Document.live`, `Snapshot.live`) and `ContractTest` (`caseFailures`, `apiFailures`, the text contract's `releaseFrees`, `fileFailures`, `processFailures`, `fileWatchFailures`, `handleRealRig`, the flush contract's process rig, `jobChecks`/`processChecks`/`fileChecks`/`grepChecks` of `Job/Real.lean`, `environmentChecks`): a process-wide count read before and after | d | files, diff, grep, processes, watches, clock, text | real | Stays: each is the binding's or the adapter's own contract, whose count is its subject (the counts are `@[inferred_wait count]`, allowed in the bindings' mirrors and the job port's contracts); phase 6 places them | not lintable: kind c/d |  |
| W64 | `tests/headless/*/script`, `packages/*/tests/headless/*/script`, `tests/packages/*/tests/headless/*/script`, with one `settle` before their scenes: bundle, display-rules, edge-sidebar, finder-session, float-anchor, float-rule, generate, insert-window-keys, insert-word-delete, manual-splits, modules, monocle, needs-rebuild, no-input-scheme, not-linked, padding, tabs, two-windows, window-dividers; binding-search, compile's config, ex-names and shipped-formats, completion-choices, command-prompt, the minibuffer's candidates and prompt, mode-line, shipped-themes' load-theme, package-names and shipped-themes; greeting-loud's reply, greeting's hello | a | loop thread, the reload | real (the headless host) | phase 5 | headless script: not lintable in Lean |  |
| W65 | Headless fixtures that `join` before a scene: column, open-file, session, view, working-set-from-search, working-set-reopen, default-config, dispatch, files, at-point and at-point-tuned, ex (with `published`), milestone (with `agree` and `idle`), scene-script, ex's wq-script and save-quit-script, user-sets' elab-script | a | loop thread and every service (the host's idle) | real | phase 5 | headless script: not lintable in Lean |  |
| W66 | `packages/compile/tests/linked/run/script`: the `settle`/`join` before each `scene` (after `kill-compilation`, and after `next-error`, whose visit's load the `join` infers from every job having ended) | a | loop thread, the files-api fake | real loop thread | phase 5 | headless script: not lintable in Lean | compile-linked-next-error-settle-race |
| W67 | The restore and restart fixtures: `tests/headless/restart` (and its fallback-script and probe-script), `tests/headless/restore/*` (abort, stores-restore, layout-restore, stores, quit, newer, layout, changed, restore): `indexed`, `journalled` and `restarted` waits on the journal's drain and the hand-over | a, d | journal, files, loop thread | real | phase 5, but for `restarted`, whose real restart is its subject and stays (phase 6 places it) | headless script: not lintable in Lean |  |
| W68 | `tools/bundle-sets.sh:244`, the c-glue check's inline script: `restarted 300`, the loop's end with a hand-over after a real package install and build | d | processes, the package build | real | Stays: a real restart is its subject; phase 6 places it | not lintable: kind c/d | bundle-sets-restart-not-found-under-load |
| W69 | `tests/user-sets/bundle-script` and `install-script` (`restarted 300`), and `tools/user-sets-check.sh:113` (`restarted 600`) | d | processes, the package build | real | Stays: a real restart is its subject; phase 6 places it | not lintable: kind c/d |  |
| W70 | `crates/editor-service/src/queue.rs`, the queue's tests (`a_pull_parks_until_an_event_is_pushed`, `quit_wakes_every_parked_pull_with_a_quit_event`, the `await_waiting_*` tests): `Queue::await_waiting`, the count of parked pulls | b | pump | real queue | Stays: the readout is the queue's own subject | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W71 | `crates/editor-ffi/tests/c_api.rs`, `the_process_wide_queues_carry_events_until_they_are_quit`: `editor_ffi_events_await_waiting(COMPLETION, 1)` on a process-wide queue | b | pump | real | Stays: the C API's own check; phase 6 places it | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W72 | `crates/editor-platform/src/scripted.rs`, the scripted platform's tests: `wait_parked`, the run parked with nothing left to report | a | loop thread (the scripted window) | fake platform | Stays: the readout is the fake's own subject | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W73 | `crates/editor-ffi/src/window.rs`, `the_platform_is_run_with_the_options_it_was_given_and_a_close_ends_the_run`: `wait_parked` | a | loop thread | scripted platform | Stays: the binding's own check; phase 6 places it | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W74 | `crates/editor-process/src/service.rs` (the held-child tests, through `comes_to_be_held`) and `src/contract.rs` (`stream_coalesced`, `stream_held`, `stream_cancel`, `stream_shutdown`): `Service::wait_held(child)`, the child's own reader parked | b | processes | real and fake service | Stays: the service's own tests and its contract | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W75 | `crates/editor-platform-winit/src/handled.rs` and `src/lib.rs` tests, and the examples `settings`, `contract/menu`, `contract/terminate`: `wait_all` / `await_requests_handled`, the handled count against the sent count | a | loop thread (the event loop) | real winit | Stays: the readout's own tests and the platform's contract examples; phase 6 places them | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W76 | `crates/editor-service/src/service.rs`, the `RecordingCompleter::wait_for` tests: the count of reports since the last take | a | the completer | real | Stays: the readout's own subject | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W77 | `tests/packages/echo/rust/src/lib.rs`, the echo service's tests (through `reported(count)`): `RecordingCompleter::wait_for`, infers that its own requests completed from the total report count | a | the completer | real echo service | phase 3 (a recording fake hands each request its own completion) | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W78 | `crates/editor-render/src/render_loop.rs` tests and `crates/editor-ffi/tests/headless_render.rs`, `a_bound_displays_frame_is_drawn_…`: `RenderHandle::wait_resting`, the loop at rest, which infers that its own frame was drawn | a | the render loop | real | Stays: the render loop's own tests and the binding's check; phase 6 places them | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W79 | `crates/editor-grep/src/service/tests.rs`: `until_held_back(count)` and `Gate::until_entered(count)`, service-wide counts | a | grep | real | Stays: the service's own tests, whose counts are their subject | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |

## The flaky tasks

Each open flaky task, with the rows it is matched to (the `Task` column):

- `restore-contract-tabs-enoent-under-load`: W49, `withJournalledDirectory`
  and the drain before the second loop.
- `compile-linked-next-error-settle-race`: W54, the compile run's host
  check's teardown, and W66, the `settle`/`join` before its scenes.
- `bundle-sets-restart-not-found-under-load`: W68, `restarted 300` in
  `tools/bundle-sets.sh`.
- `package-linked-real-thread-inventory`: W34, W36 to W42, W52, W53, W55
  and W58 to W62, the package linked tests over a real host or real
  services; phase 6 supersedes the task.

## What replaced the wait inventory

The wait inventory, a script under `tools/`, was a review aid that read source text and listed
each bound whose comment did not say which kind it was. It is retired, and
each of its rules is now a type, a Lean linter or a clippy lint:

| The script's rule | What holds it now |
|---|---|
| Lean: `IO.sleep` | `linter.rawClock`, in every module but `Editor.Bound`; real time is `RealTime.sleep` |
| Lean: `monoMsNow` (and `monoNanosNow`) | `linter.rawClock`; a deadline is `HangGuard.deadline` |
| Lean: `eventually`, a bare `within`, `Headless.within`, `Pool.within`, `Session.within`, a name holding `patience` or ending in `Guard` | the bound is a `HangGuard` parameter: `Job.awaitWithin`, the hosts' waits, the pool's, the brackets' guard and grace and the bindings' readouts take nothing else, so a number does not elaborate (`ModelTest/Editor/Bound.lean`, `ModelTest/Editor/Lint/Wait.lean`) |
| Rust: `sleep(`, `sleep_ms(` | clippy bans `std::thread::sleep` and `sleep_ms`; real time is `editor_wait::RealTime::sleep`, and a fake clock's `sleep` was never a wait |
| Rust: `recv_timeout`, `wait_timeout*`, `park_timeout`, `yield_now` | clippy bans each; a bounded wait is `editor_wait::recv` or `wait_while` |
| Rust: `Instant::now() +`, `.elapsed()` | clippy bans `Instant::now`, which both need; a deadline is `HangGuard::start`, a measurement `Stopwatch` |
| Rust: `is_finished()` or `try_wait()` in a `while` | clippy bans `JoinHandle::is_finished` and `Child::try_wait` |
| The comment forms (`hang guard:`, `hang guard, run out on purpose:`, `real time under test:`) | the three constructors, `HangGuard.on`, `HangGuard.held` and `RealTime.under` (`HangGuard::on`, `::held`, `RealTime::under` in Rust), each naming its event, what it holds or its timing |
| The files it scanned | the Lean linters are active in every module that imports `Editor.Lint.Wait` (`Editor.Bound`, `Editor.Job.Activity` and the test roots' and packages' `Check` modules, which reach every test module that writes a check), and clippy runs over every target of every crate, under a config that holds the bans |

What each holds is pinned by a fixture that must fail: the `#guard_msgs`
fixtures of `ModelTest/Editor/Lint/Wait.lean` and
`ContractTest/Editor/Lint/Wait.lean`, the `fail_if_success` examples of
`ModelTest/Editor/Bound.lean`, `editor-wait`'s `compile_fail` doctests, and
`tests/wait-lints/` under every clippy config (`the-gate.md`, "The wait
lints").

