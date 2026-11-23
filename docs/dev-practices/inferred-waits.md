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
Each such wait is a constant with a mark beside it, a declaration
`<constant>.inferredWait : InferredWait` whose value is the kind applied
to the subject modules (`.idle [`Editor.Headless.Wait]`;
`lean/Editor/InferredWait.lean`), and `lake build`'s `linter.inferredWait`
(`lean/Lint/Wait.lean`) refuses a reference to one anywhere but its own
module, the subject modules its mark names and the test modules that
mirror them (`ModelTest.Editor.Job.Activity` mirrors `Editor.Job.Activity`).
In the own or a subject module, when that is a test module, a public
declaration that references one must have a mark itself, written before
it, so a kit cannot hand a restricted wait on to everyone: the kit's waits
that are built on them (`Session.join`, `Session.ran`, `Rig.idle`,
`childrenReapedTo` and the others) have one. The rule holds through a
private declaration: one that references a restricted wait, directly or
through another private or auxiliary declaration of its module, is that
wait wherever it is referenced, so a public declaration that calls a
private wrapper unmarked is refused as one that calls the wait. In an own
or subject module that is no test module, a public declaration may hand a
restricted wait on unmarked: those are the hosts' and the runner's own
workings (`Round.judge`, `Wait.Kind.judge`, `Host.waitWhile`), whose
callers would all need marks in turn, and a test reaches them only through
the marked waits it names.

The mark is plain data and the linter a Lean plugin: the build loads the
library `Lint` into every module it elaborates of the core's libraries and
of every package (`lintPlugin`, `lean/lakefile.lean`; `plugins` in each
package's lakefile), and no module imports it. The linter imports `Lean`,
which the config base and the model tests may not reach
(`docs/design/overview.md`, "Config is elaborated behind a port, and two
adapters link Lean's frontend"), and the core imports check holds them to
that (`tools/core-imports-check.sh`, rule 4). So the list of restricted
waits is the marks, each beside its constant, and nothing else keeps it.
The marked constants:

| Constant | Kind | Allowed in, beside its own module and the mirrors |
|---|---|---|
| `Job.Activity.seen`, `.changedSince`, `Activity.Seen.idleSince` | count | the runner, the hosts (`Headless`, `Headless.Stepped`, `Headless.Wait`), the loop, the handle contract, the job kits (`Editor.Test.Jobs`, `Editor.Test.Linked.Jobs`) |
| `Test.changedAfter`, `Test.untilEpoch`, `HandleContract.changedAfter` | count | `Editor.Job.Runner`, `Editor.Job.Activity` |
| `Test.Rig.idle`, `Rig.spawn`, `Rig.stepToEnd`, `Test.Linked.untilIdle` | idle | `Editor.Job.Runner`, `Editor.Job.Activity` |
| `Test.runOnFake` | idle | none |
| `Headless.Host.join`, `Headless.Stepped.join` | idle | `Editor.Headless.Wait`, `Editor.Test.Linked.Host` |
| `Headless.Wait.Kind.join`, `.idle`, `.quiet`, `.indexed`, `Headless.awaitIndexed` | idle | `Editor.Headless.Stepped`, `Editor.Headless.Wait`, `Editor.Test.Linked.Host` |
| `Headless.Wait.Kind.advance` | firstAfter | `Editor.Headless.Stepped`, `Editor.Headless.Wait`, `Editor.Test.Linked.Host` |
| `Headless.Wait.Kind.mk`, `.busy`, `.still` | idle | `Editor.Headless.Stepped`, `Editor.Headless.Wait` |
| `Headless.Host.activitySeen`, `Headless.Stepped.activitySeen` | count | none |
| `Driven.join`, `Driven.idle`, `Driven.quiet`, `Driven.indexed`, `Session.join`, `Session.idle`, `Session.quiet`, `Session.ran` | idle | `Editor.Headless.Wait` |
| `Ffi.filesPending`, `diffsPending`, `grepPending`, `processesPending`, `watchesPending`, `timersPending` | count | the job port's real binding and contracts (`Editor.Job.Real`, `.Contract`, `.FlushContract`, `.HandleContract`), `Editor.Test.Linked.Services` |
| `Test.Linked.pendingChildren`, `childrenReapedTo` | count | none |
| `Ffi.awaitWaiting`, `Test.Linked.startsArrive`, `Test.Linked.clockReaches` | firstAfter | none |

The hosts' general wait, `Host.waitWhile` and `Stepped.waitWhile`, takes
a kind of wait (`Headless.Wait.Kind`), and what it infers "done" from is
the kind's: so the kinds that infer from the host's idle, its job counts or
the first wait on its fake clock are the marked ones, and a new kind cannot
be made outside the hosts' modules, since a kind's constructor and the two
fields that decide what it infers, `busy` and `still`, are marked too (the
linter sees a structure instance's fields as references to their
projections). A `settle` or a `handled` through `waitWhile` infers nothing
from the idle, and is refused nothing. `Driven`'s `waitWhile` is private: a
check drives a host through its named waits, the marked ones among them.

`realEffect`, the fourth kind the attribute takes, marks a real service's
readout whose fake exists; phase 3 marks each as its fake lands.

A site that a later phase removes, or that stays, keeps an explicit allow,
`set_option linter.inferredWait false in` on the declaration that holds it,
with its row beside it: `-- inferred-waits W<n>: removed by host-tests-on-fakes
phase <k>`, or `-- inferred-waits W<n>: stays (<why>)`. The phase that
removes a row deletes its allow. An allow covers the one declaration it is
on, never a check list: a check of a list that holds a listed wait is a
declaration of its own, under its allow, and the list names it, so the
list and its other checks are still linted and refuse a new inferred wait
(`ModelTest.LintFixture.listChecks` shows it). A row names those checks.
That `lake build` is green with the linter on is what makes the rows of
kinds a and b complete: every reference to a marked constant or field is in
an allowed module, where the wait is that module's subject, or under an
allow named here, and an idle wait cannot be put together from parts that
are not marked (above).

Kinds c and d are not lintable in this phase, and their rows come from
reading the brackets that remove a directory, the disk reads after a host
step, the service counts read outside the bindings, the headless fixtures'
directives and the Rust crates' readouts. The Rust readout waits are held
by clippy (`mise run lint`): they take an `editor_wait::HangGuard`, and
`disallowed-methods` refuses each outside its own tests, its adapter's
contract and the C exports the Lean checks call (`clippy.toml`). Those C
exports take their bound as a number, `bound_ms`, so they are refused in
Rust too: a Rust check of the C API calls one only at an
`#[expect(clippy::disallowed_methods, reason = "inferred-waits W<n>: …")]`
that names its row, with the number made from a typed guard
(`HangGuard::as_millis`). `tests/wait-lints/` calls each of them, and
every other banned readout, so the gate sees each ban bite.

## The rows

| Row | File and check | Kind | Collaborator | Real service | Removed by | Held by | Task |
|---|---|---|---|---|---|---|---|
| W1 | `lean/ConfigTest/Bench.lean`, `prompt`: `Editor.Headless.Host.join` | a | loop thread and every service (the host's idle) | real | Stays: an opt-in bench over real time, never part of `ci`; phase 6 places it | `linter.inferredWait`; allowed at `prompt` |  |
| W2 | `lean/ConfigTest/Editor/AtPoint.lean`, `atPointChecks` (its checks `keyPointNextTypingCheck`, `pausingTypingTwoCharactersCheck`, `typedKeyArmsPauseCheck`, `pauseEventQueuedClockCheck`): `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at each of those checks |  |
| W3 | `lean/ConfigTest/Editor/Completion/Keys.lean`, `keyHintChecks` (its checks `ac1SchemeLeaderDefaultCheck`, `configSetsDelayNeverCheck`, `reloadDefaultDelayPassedCheck`): `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at each of those checks |  |
| W4 | `lean/ConfigTest/Editor/Extension.lean`, `extensionChecks` (its check `compiledPackageJobExtensionCheck`): `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at that check |  |
| W5 | `lean/ConfigTest/Editor/Headless.lean`, `withdrawingHeld`: `Editor.Test.Linked.clockReaches` | b | clock | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at `withdrawingHeld` |  |
| W6 | `lean/ConfigTest/Editor/Headless.lean`, `jobChecks` (its checks `handlerReceivesJobResultCheck`, `reloadCancelsOldConfigCheck`, `rejectedReloadCancelsNothingCheck`, `jobThrowsReportedFailedCheck`, `jobCommandSetsModeCheck`, `parseHighlightedTextLibraryCheck`): `Editor.Test.Linked.Session.idle`, `Editor.Test.Linked.Session.join`, `Editor.Test.Linked.clockReaches` | a, b | loop thread and every service (the host's idle), clock | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at each of those checks |  |
| W7 | `lean/ConfigTest/Editor/Headless.lean`, `scriptChecks` (its check `scenePublishedAgainReloadCheck`): `Editor.Test.Linked.Session.idle`, `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at that check |  |
| W8 | `lean/ConfigTest/Editor/Headless.lean`, `hostLoopChecks` (its checks `hostKeepsClipboardOwnCheck`, `keyCommandStartsJobCheck`, `finishedJobCommandGuardedCheck`, `hostHandedCompiledJobsCheck`): `Editor.Test.Linked.Session.join`, `Editor.Test.Linked.clockReaches` | a, b | loop thread and every service (the host's idle), clock | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at each of those checks |  |
| W9 | `lean/ConfigTest/Editor/Headless.lean`, `watchReloadChecks` (its checks `reloadInstallsWatchesNewCheck`, `rejectedReloadLeavesOldCheck`): `Editor.Test.Linked.Session.idle`, `Editor.Test.Linked.Session.join`, `Editor.Test.Linked.Session.quiet` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at each of those checks |  |
| W10 | `lean/ConfigTest/Editor/Headless.lean`, `restoreOrderChecks` (its checks `handJournalOrderFailedCheck`, `restoreWhoseJobFailsCheck`): `Editor.Test.Linked.Driven.idle`, `Editor.Test.Linked.Driven.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at each of those checks |  |
| W11 | `lean/ConfigTest/Editor/Headless/Stepped.lean`, `steppedChecks` (its check `steppedHostPublishesScenesCheck`): `Editor.Headless.Host.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at that check |  |
| W12 | `lean/ConfigTest/Editor/Loop.lean`, `dispatchChecks` (its check `commandTakesLongerThresholdCheck`): `Editor.Test.Linked.clockReaches` | b | clock | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at that check |  |
| W13 | `lean/ConfigTest/Editor/Minibuffer.lean`, `promptChecks` (its checks `jobCompletesPromptOpenCheck`, `criterion1RecorderPromptCheck`, `sourceAnswersLaterJobCheck`, `criterion4HostPromptCheck`, `reloadInstallsMatchConfigCheck`): `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real loop thread and elaborator | phase 4 | `linter.inferredWait`; allowed at each of those checks |  |
| W14 | `lean/ContractTest/Editor/Completion/Filtering.lean`, `foundThrough`: `Editor.Ffi.processesPending`, `Editor.Test.Linked.childrenReapedTo` | a | processes | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `foundThrough` |  |
| W15 | `lean/ContractTest/Editor/File/Cases.lean`, `caseFailures`: `Editor.Ffi.filesPending` | a | files | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `caseFailures` |  |
| W16 | `lean/ContractTest/Editor/Job/Contract.lean`, `processFailures`: `Editor.Test.Linked.childrenReapedTo` | a | processes | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at `processFailures` |  |
| W17 | `lean/ContractTest/Editor/Job/FlushContract.lean`, `flushRealRigs` (its rig `libraryProcessServiceHeldRig`): `Editor.Test.Linked.pendingChildren` | a | processes | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at that rig |  |
| W18 | `lean/ContractTest/Editor/Job/Real.lean`, `processChecks` (its checks `jobWhoseChildSleepsCheck`, `runLibraryTakeIdCheck`, `runLibraryTakeCompletesCheck`, `runTimeLimitCancelledCheck`, `runTimeLimitOutlivesCheck`): `Editor.Test.Linked.childrenReapedTo`, `Editor.Test.Linked.startsArrive` | a, b | processes, the started service | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at each of those checks |  |
| W19 | `lean/ContractTest/Editor/Job/Real.lean`, `jobChecks` (its checks `jobsRealWaitsDelayCheck`, `cancellingJobWithdrawsTimerCheck`, `deadlineMachineWordHoldsCheck`, `pumpPoolTasksPumpCheck`): `Editor.Ffi.awaitWaiting`, `Editor.Test.Linked.startsArrive` | b | pump, the started service | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at each of those checks |  |
| W20 | `lean/ContractTest/Editor/Job/Real.lean`, `fileChecks` (its checks `loadWritesNothingEditorCheck`, `cancellingJobWhoseLoadCheck`): `Editor.Test.Linked.startsArrive`, `Editor.Test.Linked.untilIdle` | a, b | the started service, job runner (the rig's count) | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at each of those checks |  |
| W21 | `lean/ContractTest/Editor/Job/Real.lean`, `grepChecks` (its check `jobSearchOutliveJobCheck`): `Editor.Test.Linked.untilIdle` | a | job runner (the rig's count) | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at that check |  |
| W22 | `lean/ContractTest/Editor/Process/Environment.lean`, `environmentChecks` (its checks `miseStandingFixtureChildCheck`, `miseSleepsPastLimitCheck`): `Editor.Ffi.processesPending`, `Editor.Test.Linked.childrenReapedTo` | a | processes | real | Stays: an adapter's contract over the real service, whose count is its subject; phase 6 places it | `linter.inferredWait`; allowed at each of those checks |  |
| W23 | `lean/ModelTest/Editor/Job/Contract.lean`, `snapshotReadChecks` (its check `jobModelSnapshotReadCheck`): `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at that check |  |
| W24 | `lean/ModelTest/Editor/Job/Contract.lean`, `jobRunnerFailures`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `jobRunnerFailures` |  |
| W25 | `lean/ModelTest/Editor/Job/Contract.lean`, `postedOnFake`: `Editor.Test.Rig.stepToEnd` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `postedOnFake` |  |
| W26 | `lean/ModelTest/Editor/Job/Contract.lean`, `fuzzyJobFailures`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `fuzzyJobFailures` |  |
| W27 | `lean/ModelTest/Editor/Job/Contract.lean`, `runFilesOnFake`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `runFilesOnFake` |  |
| W28 | `lean/ModelTest/Editor/Job/Contract.lean`, `runProcessesOnFake`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `runProcessesOnFake` |  |
| W29 | `lean/ModelTest/Editor/Job/Contract.lean`, `runWatchesOnFake`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `runWatchesOnFake` |  |
| W30 | `lean/ModelTest/Editor/Job/Contract.lean`, `snapshotJobFailures`: `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at `snapshotJobFailures` |  |
| W31 | `lean/ModelTest/Editor/Job/Jobs.lean`, `ownerChecks` (its check `jobWhoseOwnerRemovedCheck`): `Editor.Test.Rig.idle` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at that check |  |
| W32 | `lean/ModelTest/Editor/Process/Model.lean`, `processChecks` (its checks `cancellingJobProcessWaitCheck`, `runnerGivenProcessServiceCheck`, `readDeliversLineChildCheck`, `childLastDeliveryRunnerCheck`, `jobEndsStreamingChildCheck`, `cancellingJobPendingReadCheck`): `Editor.Test.Rig.idle`, `Editor.Test.Rig.spawn`, `Editor.Test.runOnFake` | a | job runner (the rig's count) | fake (the rig's own count and fake clock) | Stays: the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle; phase 2 models the runner's protocol, and phase 6 places what stays | `linter.inferredWait`; allowed at each of those checks |  |
| W33 | `packages/compile/CompileTest/Linked/Compile.lean`, `compileRunChecks` (its check `criterion11RealProcessCheck`): `Editor.Test.Linked.childrenReapedTo`, `Editor.Test.Linked.pendingChildren` | a | processes | real (linked) | phase 4 | `linter.inferredWait`; allowed at that check |  |
| W34 | `packages/compile/CompileTest/Linked/Compile/Shipped.lean`, `withProjects`: `Editor.Test.Linked.childrenReapedTo`, `Editor.Test.Linked.pendingChildren` | a | processes | real (linked) | phase 4 | `linter.inferredWait`; allowed at `withProjects` | package-linked-real-thread-inventory |
| W35 | `packages/ex/ExTest/Linked/Ex.lean`, `exScriptChecks` (its checks `stepSaidStopHostCheck`, `waitHostWhoseLoopCheck`): `Editor.Headless.Host.join`, `Editor.Headless.Stepped.join` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at each of those checks |  |
| W36 | `packages/files/FilesTest/Linked/Files.lean`, `reportedAfter`: `Editor.Test.Linked.Session.ran` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at `reportedAfter` | package-linked-real-thread-inventory |
| W37 | `packages/files/FilesTest/Linked/Files.lean`, `fileChecks` (its checks `jobLoadsFileThroughCheck`, `openCommandFileTemporaryCheck`, `saveCommandModifiedBufferCheck`, `openingPathOpenStartsCheck`, `openSaveEditWritesCheck`, `saveBufferWhoseFileCheck`, `openCommandPathFileCheck`, `openCommandPathAsksCheck`): `Editor.Test.Linked.Driven.join`, `Editor.Test.Linked.Session.join`, `Editor.Test.Linked.Session.ran` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at each of those checks | package-linked-real-thread-inventory |
| W38 | `packages/files/FilesTest/Linked/Files.lean`, `reloadChecks` (its check `criterion1FileRewrittenCheck`): `Editor.Test.Linked.Session.ran` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at that check | package-linked-real-thread-inventory |
| W39 | `packages/files/FilesTest/Linked/Files.lean`, `atW`: `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at `atW` | package-linked-real-thread-inventory |
| W40 | `packages/files/FilesTest/Linked/Files.lean`, `filePromptChecks` (its checks `ac2RecorderWCheck`, `ac4RecorderRealCheck`, `hostHomeReachesEditorCheck`, `ac6RecorderCommittingCheck`): `Editor.Test.Linked.Session.join` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at each of those checks | package-linked-real-thread-inventory |
| W41 | `packages/files/FilesTest/Linked/Files.lean`, `autoReloadChecks` (its check `criteria910RealCheck`): `Editor.Test.Linked.Session.ran` | a | loop thread and every service (the host's idle) | real (linked) | phase 4 | `linter.inferredWait`; allowed at that check | package-linked-real-thread-inventory |
| W42 | `packages/files/FilesTest/Linked/Files/Bench.lean`, `autoReloadRow`: `Editor.Test.Linked.Session.ran` | a | loop thread and every service (the host's idle) | real | Stays: an opt-in bench over real time, never part of `ci`; phase 6 places it | `linter.inferredWait`; allowed at `autoReloadRow` | package-linked-real-thread-inventory |
| W43 | `packages/shell/ShellTest/Linked/Shell.lean`, `shellChecks` (its checks `criterion16RealProcessCheck`, `criterion17RealProcessCheck`): `Editor.Ffi.processesPending`, `Editor.Test.Linked.childrenReapedTo` | a | processes | real (linked) | phase 4 | `linter.inferredWait`; allowed at each of those checks |  |
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
| W56 | `lean/ConfigTest/Editor/Headless.lean`, `indexWritten`, and through it four checks of `restoreOrderChecks` ("a config's store kept across a restart…" reads the index on disk after it, `lastIndex`): `Editor.Test.Linked.Driven.indexed` | a, d | journal, files | real | phase 4 | `linter.inferredWait`; allowed at `indexWritten` |  |
| W57 | `lean/ConfigTest/Editor/Headless.lean`, `journalDrainChecks`: `pathExists` after the drain, the file service held and let go | d | journal, files | real | Stays: the journal's drain over the real file service is its subject; phase 6 places it | not lintable: kind c/d |  |
| W58 | `packages/ex/ExTest/Linked/Ex.lean`, `exScriptChecks` (criteria 1 and 2, the refused `q`): `readBinFile` after the script's `join` | a, d | files | real (`Stage.overFiles`) | phase 4 | headless script: not lintable in Lean | package-linked-real-thread-inventory |
| W59 | `packages/files/FilesTest/Linked/Files.lean`, the save checks (save on a modified buffer, open then save with no edit, a save of a file changed on disk) and `autoReloadChecks`: `readBinFile` after the save or at the host's end | d | files, watches, loop thread | real | phase 4 | not lintable: kind c/d | package-linked-real-thread-inventory |
| W60 | `packages/project-search/ProjectSearchTest/Linked/ProjectSearch/Run.lean`, `projectSearchChecks` (criteria 2 and 3): reads the file after `runSettledFrom` | d | files, grep | real | phase 4 | not lintable: kind c/d | package-linked-real-thread-inventory |
| W61 | `packages/version-control/VersionControlTest/Linked/VersionControl/Status.lean`, criterion 1 through vc-stage-hunk: reads the file and `git show` after `runSettled` | d | files, processes | real git | phase 4 | not lintable: kind c/d | package-linked-real-thread-inventory |
| W62 | `packages/working-set/WorkingSetTest/Linked/WorkingSet/Run.lean`, `workingSetChecks` (criteria 1 and 2): reads the store after `runHost` | d | files | real | phase 4 | not lintable: kind c/d | package-linked-real-thread-inventory |
| W63 | The service counts read outside the bindings: `FfiTest` (Files, Processes, Grep, Diffs, Timers, Document, Snapshot: `filesPending`, `processesPending`, `grepPending`, `diffsPending == 0`, `timersPending`, `Document.live`, `Snapshot.live`) and `ContractTest` (`caseFailures`, `apiFailures`, the text contract's `releaseFrees`, `fileFailures`, `processFailures`, `fileWatchFailures`, `handleRealRig`, the flush contract's process rig, `jobChecks`/`processChecks`/`fileChecks`/`grepChecks` of `Job/Real.lean`, `environmentChecks`): a process-wide count read before and after | d | files, diff, grep, processes, watches, clock, text | real | Stays: each is the binding's or the adapter's own contract, whose count is its subject (the counts are marked `count`, allowed in the bindings' mirrors and the job port's contracts); phase 6 places them | not lintable: kind c/d |  |
| W64 | `tests/headless/*/script`, `packages/*/tests/headless/*/script`, `tests/packages/*/tests/headless/*/script`, with one `settle` before their scenes: bundle, display-rules, edge-sidebar, finder-session, float-anchor, float-rule, generate, insert-window-keys, insert-word-delete, manual-splits, modules, monocle, needs-rebuild, no-input-scheme, not-linked, padding, tabs, two-windows, window-dividers; binding-search, compile's config, ex-names and shipped-formats, completion-choices, command-prompt, the minibuffer's candidates and prompt, mode-line, shipped-themes' load-theme, package-names and shipped-themes; greeting-loud's reply, greeting's hello | a | loop thread, the reload | real (the headless host) | phase 5 | headless script: not lintable in Lean |  |
| W65 | Headless fixtures that `join` before a scene: column, open-file, session, view, working-set-from-search, working-set-reopen, default-config, dispatch, files, at-point and at-point-tuned, ex (with `published`), milestone (with `agree` and `idle`), scene-script, ex's wq-script and save-quit-script, user-sets' elab-script | a | loop thread and every service (the host's idle) | real | phase 5 | headless script: not lintable in Lean |  |
| W66 | `packages/compile/tests/linked/run/script`: the `settle`/`join` before each `scene` (after `kill-compilation`, and after `next-error`, whose visit's load the `join` infers from every job having ended) | a | loop thread, the files-api fake | real loop thread | phase 5 | headless script: not lintable in Lean | compile-linked-next-error-settle-race |
| W67 | The restore and restart fixtures: `tests/headless/restart` (and its fallback-script and probe-script), `tests/headless/restore/*` (abort, stores-restore, layout-restore, stores, quit, newer, layout, changed, restore): `indexed`, `journalled` and `restarted` waits on the journal's drain and the hand-over | a, d | journal, files, loop thread | real | phase 5, but for `restarted`, whose real restart is its subject and stays (phase 6 places it) | headless script: not lintable in Lean |  |
| W68 | `tools/bundle-sets.sh:244`, the c-glue check's inline script: `restarted 300`, the loop's end with a hand-over after a real package install and build | d | processes, the package build | real | Stays: a real restart is its subject; phase 6 places it | not lintable: kind c/d | bundle-sets-restart-not-found-under-load |
| W69 | `tests/user-sets/bundle-script` and `install-script` (`restarted 300`), and `tools/user-sets-check.sh:113` (`restarted 600`) | d | processes, the package build | real | Stays: a real restart is its subject; phase 6 places it | not lintable: kind c/d |  |
| W70 | `crates/editor-service/src/queue.rs`, the queue's tests (`a_pull_parks_until_an_event_is_pushed`, `quit_wakes_every_parked_pull_with_a_quit_event`, the `await_waiting_*` tests): `Queue::await_waiting`, the count of parked pulls | b | pump | real queue | Stays: the readout is the queue's own subject | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W71 | `crates/editor-ffi/tests/c_api.rs`, `the_process_wide_queues_carry_events_until_they_are_quit` (through `wait_for_parked`): `editor_ffi_events_await_waiting(COMPLETION, 1)` on a process-wide queue | b | pump | real | Stays: the C API's own check; phase 6 places it | Rust: `clippy::disallowed_methods` on the C function, `#[expect]` (W71) at `wait_for_parked` and at the check |  |
| W72 | `crates/editor-platform/src/scripted.rs`, the scripted platform's tests: `wait_parked`, the run parked with nothing left to report | a | loop thread (the scripted window) | fake platform | Stays: the readout is the fake's own subject | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W73 | `crates/editor-ffi/src/window.rs`, `the_platform_is_run_with_the_options_it_was_given_and_a_close_ends_the_run`: `wait_parked` | a | loop thread | scripted platform | Stays: the binding's own check; phase 6 places it | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W74 | `crates/editor-process/src/service.rs` (the held-child tests, through `comes_to_be_held`) and `src/contract.rs` (`stream_coalesced`, `stream_held`, `stream_cancel`, `stream_shutdown`): `Service::wait_held(child)`, the child's own reader parked | b | processes | real and fake service | Stays: the service's own tests and its contract | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W75 | `crates/editor-platform-winit/src/handled.rs` and `src/lib.rs` tests, and the examples `settings`, `contract/menu`, `contract/terminate`: `wait_all` / `await_requests_handled`, the handled count against the sent count | a | loop thread (the event loop) | real winit | Stays: the readout's own tests and the platform's contract examples; phase 6 places them | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W76 | `crates/editor-service/src/service.rs`, the `RecordingCompleter::wait_for` tests: the count of reports since the last take | a | the completer | real | Stays: the readout's own subject | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W77 | `tests/packages/echo/rust/src/lib.rs`, the echo service's tests (through `reported(count)`): `RecordingCompleter::wait_for`, infers that its own requests completed from the total report count | a | the completer | real echo service | phase 3 (a recording fake hands each request its own completion) | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W78 | `crates/editor-render/src/render_loop.rs` tests and `crates/editor-ffi/tests/headless_render.rs`, `a_bound_displays_frame_is_drawn_…`: `RenderHandle::wait_resting`, the loop at rest, which infers that its own frame was drawn | a | the render loop | real | Stays: the render loop's own tests and the binding's check; phase 6 places them | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W79 | `crates/editor-grep/src/service/tests.rs`: `until_held_back(count)` and `Gate::until_entered(count)`, service-wide counts | a | grep | real | Stays: the service's own tests, whose counts are their subject | Rust: `clippy::disallowed_methods`, `#[expect]` at the readout's own tests |  |
| W80 | `crates/editor-ffi/tests/c_api.rs`, `a_counter_is_live_from_new_until_free` and `a_document_is_edited_and_read_through_c_and_is_live_from_new_until_free` (through `freed_on_another_thread`): `editor_ffi_live_await(kind, target)`, the process-wide live count of counters or documents come down to a target, which another check's free can bring about | a | the handles' finalisers (a free on another thread) | real | Stays: the C API's own check; phase 6 places it | Rust: `clippy::disallowed_methods` on the C function, `#[expect]` (W80) at `freed_on_another_thread` |  |
| W81 | `crates/editor-ffi/tests/snapshot.rs`, `a_snapshot_is_taken_and_read_through_c_and_is_live_from_the_call_that_made_it_until_its_free`: `editor_ffi_live_await(SNAPSHOTS, before)`, the process-wide live count of snapshots come down | a | the handles' finalisers (a free on another thread) | real | Stays: the C API's own check, alone in its process; phase 6 places it | Rust: `clippy::disallowed_methods` on the C function, `#[expect]` (W81) at the check |  |
| W82 | `crates/editor-ffi/tests/window.rs`, `the_process_wide_window_reports_on_the_editor_queue_until_it_is_closed`: `editor_ffi_window_await_parked`, the scripted run parked with nothing left to report | a | loop thread (the scripted window) | scripted platform | Stays: the window C API's own check; phase 6 places it | Rust: `clippy::disallowed_methods` on the C function, `#[expect]` (W82) at the check |  |
| W83 | `crates/editor-ffi/tests/common/open.rs`, `comes_to_be_held`, for `tests/processes_stream.rs` and `tests/processes_shutdown.rs`: `editor_ffi_processes_await_held(child)`, the child's own reader parked on its bound | b | processes | real | Stays: the process C API's wiring checks; phase 6 places them | Rust: `clippy::disallowed_methods` on the C function, `#[expect]` (W83) at `comes_to_be_held` |  |
| W84 | `crates/editor-ffi/tests/syntax.rs`, `a_query_is_answered_only_from_a_tree_of_the_snapshots_revision`: `editor_ffi_syntax_settle(snapshot)`, a delivery of the snapshot's revision or a newer one; only the check's own document's edits give one | b | the syntax worker (the document's session) | real | Stays: the syntax C API's own check; phase 6 places it | Rust: `clippy::disallowed_methods` on the C function, `#[expect]` (W84) at the check |  |

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
| Lean: `eventually`, a bare `within`, `Headless.within`, `Pool.within`, `Session.within`, a name holding `patience` or ending in `Guard` | the bound is a `HangGuard` parameter: `Job.awaitWithin`, the hosts' waits, the pool's, the brackets' guard and grace and the bindings' readouts take nothing else, so a number does not elaborate (`ModelTest/Editor/Bound.lean`, `ModelTest/Lint/Wait.lean`) |
| Rust: `sleep(`, `sleep_ms(` | clippy bans `std::thread::sleep` and `sleep_ms`; real time is `editor_wait::RealTime::sleep`, and a fake clock's `sleep` was never a wait |
| Rust: `recv_timeout`, `wait_timeout*`, `park_timeout`, `yield_now` | clippy bans each; a bounded wait is `editor_wait::recv` or `wait_while` |
| Rust: `Instant::now() +`, `.elapsed()` | clippy bans `Instant::now`, which both need; a deadline is `HangGuard::start`, a measurement `Stopwatch` |
| Rust: `is_finished()` or `try_wait()` in a `while` | clippy bans `JoinHandle::is_finished` and `Child::try_wait` |
| The comment forms (`hang guard:`, `hang guard, run out on purpose:`, `real time under test:`) | the three constructors, `HangGuard.on`, `HangGuard.held` and `RealTime.under` (`HangGuard::on`, `::held`, `RealTime::under` in Rust), each naming its event, what it holds or its timing |
| The files it scanned | the Lean linters are loaded, as a plugin, into every module of the core's libraries and of every package under `packages/` and `tests/packages/` (the library `Lint`, `lean/lakefile.lean`), and clippy runs over every target of every crate, under a config that holds the bans |

What each holds is pinned by a fixture that must fail: the `#guard_msgs`
fixtures of `ModelTest/Lint/Wait.lean`, `ContractTest/Lint/Wait.lean` and
`ConfigTest/Lint/Wait.lean` (and the rules they apply by
`LintTest.lintWaitChecks`, `lake exe lint-test`), the `fail_if_success` examples of
`ModelTest/Editor/Bound.lean`, `editor-wait`'s `compile_fail` doctests, and
`tests/wait-lints/` under every clippy config (`the-gate.md`, "The wait
lints").

