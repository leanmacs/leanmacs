import ContractTest.Check
import ContractTest.Editor.Api.Cases
import ContractTest.Editor.Clipboard.Contract
import ContractTest.Editor.Clipboard.Real
import ContractTest.Editor.Completion.Filtering
import ContractTest.Editor.Completion.StyleContract
import ContractTest.Editor.Display.Contract
import ContractTest.Editor.Display.Recorder
import ContractTest.Editor.File.Cases
import ContractTest.Editor.Fuzzy.Contract
import ContractTest.Editor.Fuzzy.Real
import ContractTest.Editor.Headless.Journal.Contract
import ContractTest.Editor.Headless.Queue.Contract
import ContractTest.Editor.Headless.Queue.Real
import ContractTest.Editor.Job.Contract
import ContractTest.Editor.Job.FlushContract
import ContractTest.Editor.Job.HandleContract
import ContractTest.Editor.Job.ProtocolContract
import ContractTest.Editor.Job.PumpContract
import ContractTest.Editor.Job.Real
import ContractTest.Editor.Process.Environment
import ContractTest.Editor.Restore.Run
import ContractTest.Editor.SyntaxTree.Contract
import ContractTest.Editor.SyntaxTree.DeliveryContract
import ContractTest.Editor.SyntaxTree.Real
import ContractTest.Editor.Test.Linked.Services
import ContractTest.Editor.Text.Contract
import ContractTest.Editor.Watch.Contract
import ContractTest.Editor.Watch.Real
import ContractTest.Lint.Wait
import Editor.Api.Cases
import Editor.Clipboard.Contract
import Editor.Completion.StyleContract
import Editor.Display
import Editor.Display.Contract
import Editor.File.Cases
import Editor.Fuzzy.Contract
import Editor.Job.Contract
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Job.Runner
import Editor.SyntaxTree.Contract
import Editor.Test.Linked.Services
import Editor.Text.Contract
import Editor.UndoTree.Cases
import Editor.Watch.Contract

/-!
# The contract checks against the real bindings

The `contract-test` executable runs each port's contract against the port's
real binding, so against the Rust library: it is linked like `editor`, with
the glue object and the Rust archive. `model-test` runs the same lists
against the pure models. A property that holds of one and not of the other
fails one of the two, which is what keeps a model from drifting from the
library.

The runs and checks themselves live in test modules that mirror what they
test: a run of a port's contract is in the test module of that contract,
such as `displayFailures` in `ContractTest/Editor/Display/Contract.lean`, and
what only a real binding shows is in the mirror of that binding, such as
`clipboardChecks` in `ContractTest/Editor/Clipboard/Real.lean`. A test
module keeps the helpers only its checks use. Helpers that several test
modules use are in small support modules, each of one kind of fixture:
under `ContractTest/Support/`, and, for the ones a package's linked test is
also written on, under `Editor/Test/Linked/` (the core's linked test kit,
in the namespace `Editor.Test.Linked`, which the core publishes as a test
double: jobs on the real runner, temporary trees, the loop's rig over the
real services, and those services with their pump;
`docs/design/packages.md`, "What a package may import").
`ContractTest.Check` holds the `Check` type and `checkFailures`. Every list
is in the namespace `ContractTest`, so a list is
`ContractTest.<name>Checks` whichever module holds it. This module keeps
only `main`, which runs them in the order its doc gives.

- The text port's contract (`Editor/Text/Contract.lean`) against its real
  binding (`Editor/Text/Real.lean`), and the properties of taking a job's
  snapshot into the store, each in a run handed snapshots the library made
  (`runHanded`). Beside them, what only the real binding can show, since it
  is about the library's objects and the binding's own table: that the
  binding's table is the only holder of its documents and of its snapshots,
  that releasing one frees it at once, and that the read half of its
  published table of snapshots finds what a command took and nothing a
  command released (`failures`, `releaseFrees`, `readerFinds`).
- The binding's bracket walk against the text model's, at every position of
  texts with quotes and for every question the walk can be asked
  (`pairChecks`): the quote rule is ported to both, and the contract's tables
  pin it only at the cases they name.
- The cases of the undo tree (`Editor/UndoTree/Cases.lean`), which is plain
  Lean over the text port, through the same binding and in the same run, so
  the count of live documents covers the texts they make. `model-test` runs
  them against the text model.
- The job port's contract (`Editor/Job/Contract.lean`) against the runner
  over the library's timer service, with the completion pump
  (`Editor/Job/Real.lean`). `model-test` runs it against the model and
  against the runner over the fake clock. So it runs the post properties
  (`JobContract.postProperties`, `postFailures`), each job spawned with a
  host that records the posts it is handed, and the fuzzy properties
  (`JobContract.fuzzyProperties`, `fuzzyJobFailures`), with the library's
  matcher (`Fuzzy.real`) as the runner's fuzzy service, and the snapshot
  properties (`JobContract.snapshotProperties`, `snapshotJobFailures`), with
  a real table of snapshots read through `Job.realSnapshots`.
- The job port's file properties (`JobContract.fileProperties`) against the
  runner over the library's file service, on real files
  (`runFilesOnService`, `fileFailures`). Each property has a temporary
  directory of its own, made here, handed to its job as a path, read back
  when the job has ended and removed whatever happened; no file is touched
  anywhere else. `model-test` runs the same list against the model of files
  and against the runner over the fake of the file service.

- The job port's watch properties (`JobContract.fileWatchProperties`)
  against the runner over the library's watch and process services, on real
  files (`runWatchesOnService`, `fileWatchFailures`), each in a temporary
  directory of its own; the library's count of pending watches must be back
  where it was afterwards, so every watch ended with its job.
  `fileWatchChecks` then shows that a job's watch does not outlive it, and
  that a change whose path is not UTF-8 is delivered as missed of the
  watch's own path, on a volume that allows such a name.
- The job port's process properties (`JobContract.processProperties`)
  against the runner over the library's process service, on real processes
  (`runProcessesOnService`, `processFailures`), each in a temporary
  directory of its own, made here and removed whatever happened; the
  library's count of pending runs must be back where it was afterwards, so
  every child was reaped. `processChecks` then shows that cancelling a job
  whose child is running ends the job and has the child reaped, and that a
  run the library does not take, its id being in use there, is refused at
  once as `failed`, the job going on, with the refusal kept until it is
  taken and erased when its wait is withdrawn. It also shows that a run with
  a time limit, taken within the limit, cancelled before it or timed out,
  leaves no run in the adapter's table of armed limits and no alarm in the
  table of waits, and its child reaped.
  `model-test` runs the same list against the model of processes and
  against the runner over the fake of the process service.
- The services' flush contract (`Editor/Job/FlushContract.lean`,
  `flushContractChecks`) against the real ports: the file service held by
  its in-process hold (`ContractTest/Support/FileHold.lean`), the process
  service by a child only a cancel ends, and the clock, the watch service,
  the diff service and the grep service idle. `model-test` runs it against the fakes.
- The contract of a file request's handle (`Editor/Job/HandleContract.lean`,
  `handleContractChecks`) against the real file port, held by the same
  hold, in a temporary directory of its own: a held request's handle has
  not ended until the worker is let go, then ends with its reply, and a
  dropped handle's reply is still taken, so the service keeps nothing.
  `model-test` runs it against the fake file service.
- The completion pump's contract (`Editor/Job/PumpContract.lean`,
  `pumpContractChecks`) against the library's completion queue, each
  completion handed as a flush of the file service under the wait's id and
  each property waiting on its own wait. `model-test` runs it against the
  fake pump.
- The session journal's contract (`Editor/Headless/Journal/Contract.lean`,
  `journalContractChecks`) against the real journal (`Journal.real`) over
  the file service, held by the same hold, each property in a temporary
  directory of its own and waiting on the journal's own drain, a flush of
  the service. `model-test` runs it against the recording fake.
- The editor queue port's contract (`Editor/Headless/Queue/Contract.lean`,
  `queueContractChecks`) against its real binding, the library's editor
  queue (`Queue.library`, `Editor/Headless/Queue/Real.lean`), its posts
  taken back with pulls of the editor queue; `model-test` runs it against
  the in-memory queue. Beside it, what only the real binding shows
  (`queueRealChecks`): what the library hands back for a post is
  `Posted.toFfi` of it, which a stepped host's queue holds in its place.
- The bracket a check's temporary directory lives in
  (`Editor/Test/Linked/Services.lean`, `linkedServicesChecks`) over the
  real file service, held by the same hold: the directory is removed only
  once an append handed to the service under it has been worked, whether
  the body returned or threw, the bracket's guard saying the hang once and
  letting the hold go; and a refused flush is said, and the directory still
  goes.

`jobChecks` then pins what only the real service can show: that a job in a
real wait holds no thread, that cancelling a job takes its timer out of the
library's schedule, that a deadline no machine word holds is not cut down,
and that the pump is not one of the pool's tasks.
`protocolContractChecks` (`Editor/Job/ProtocolContract.lean`) runs jobs
that sleep on the timer service, load a real file and are cancelled in a
long sleep, on the pool's threads and the pump, and requires the trace the
runner records to replay on the protocol model whatever interleaving they
took.

The cases that cross the text port and the job port
(`Editor/File/Cases.lean`) are played on the real binding and the library's
file service, on real files (`playOnLibrary`, `caseFailures`): a command, a
job on the runner, the job's command run by `Job.finishWith`, as the loop
runs it, and a last command. `model-test` plays them on the two models.

`grepChecks` pins what only the grep service shows: that a job's search
does not outlive the job, and that an overlay of a snapshot a command took
is searched in place of its file. The search properties
(`JobContract.grepProperties`) run with the file properties, over the
library's file and grep services on real files.

`fileChecks` pins what only the file service and the real text binding
together can show: that a load writes nothing to the editor's table of
snapshots until the job's command adopts it, that what a job loaded is
freed when the job is settled, that cancelling a job leaves the file
service with nothing of it, and that a job saves a snapshot a command took
through the published table and is refused one the command has released.

The display interface's contract (`Editor/Display/Contract.lean`) is run
against its real binding (`Editor/Display/Real.lean`) over the library's
fake shaper, at the cell sizes `model-test` runs it against the model at
(`displayFailures`): each property's texts are made documents and
snapshots in the library, entered in a table of the text binding, and the
property runs against a new display over that table.

The same contract is run against the recorder a host with no window answers
it with (`Editor/Display/Recorder.lean`), over snapshots the library made,
at the same two cell sizes (`recorderFailures`). `recorderChecks` pins what
only the recorder shows: that it keeps and counts what is published, and
that it reads the table of snapshots as it is when asked.

The clipboard interface's contract (`Editor/Clipboard/Contract.lean`) is run
against the clipboard a host with no window keeps
(`Editor/Clipboard/InProcess.lean`), one clipboard for the whole list, so
each property finds what the one before it left (`clipboardFailures`), and
against the real binding (`Editor/Clipboard/Real.lean`) over the library's
memory clipboard, so that no run reads or writes the desktop's
(`realClipboardFailures`). `model-test` runs the same list against the
model. `clipboardChecks` pins
what the contract cannot: that a new one holds no text, and, with a command
run against the library, that the command's clipboard requests go to the
handler it was handed, and are each answered `unavailable` when it was
handed none; and, over the library's failing clipboard, a fake of one that
cannot be reached, that a failed read and a failed write cross the glue
with the library's reason whole and that the real binding answers each
`unavailable`.

The fuzzy matching interface's contract (`Editor/Fuzzy/Contract.lean`) is
run against its real binding (`Editor/Fuzzy/Real.lean`), so against the
library's matcher and searcher (`fuzzyFailures`): which candidates a
pattern matches, that a candidate that is the pattern is first, and where a
pattern is located. `model-test` runs the
same list against the model. Nothing more is asked of the two: after the
candidates that are the pattern, the binding's order is the library's
scores and the model's is the candidates' own. `fuzzyChecks` pins where a
command's fuzzy requests, a ranking and a located pattern, go when it is
run against the library: to that binding, with nothing handed in.

The completion styles' contract (`Editor/Completion/StyleContract.lean`) is
run against the core's own style over that binding (`styleFailures`), and
`model-test` runs it against the core's own style and the style model over
the model: which indices a style answers, its ranges, and that the empty
text lists every candidate. The shipped fuzzy and path styles are the
default package `completion`'s (`packages/completion/`), whose linked test
runs the contract against them over the same binding
(`CompletionTest.shippedStyleFailures`).

The watch port's contract (`Editor/Watch/Contract.lean`) is run against its
real binding (`Editor/Watch/Real.lean`), over the library's interrupt flag
and the library's timer service (`watchFailures`): the interrupt keys a
property needs arrive through the library's window input, as a window's
would. `model-test` runs the same list against the watch model.
`watchChecks` pins what only the real binding shows: that its clock is the
job port's, read from a fake clock here, and, with the command loop over
the real text binding, an interrupt key that arrives while a command runs.
That check is single-threaded, so where the key arrives is exact: the
display handler posts it during one of the command's own publishes.

The syntax tree interface's contract (`Editor/SyntaxTree/Contract.lean`) is
run against its real binding (`Editor/SyntaxTree/Real.lean`), so against the
library's syntax service, tree-sitter's JSON grammar over its worker thread
(`syntaxTreeFailures`): each property's texts are made documents and
snapshots in the library, entered in a table of the text binding, and the
property runs against a new binding over that table. The library parses off
the editor thread, so the runner's handler waits, with a bound, for the
snapshot's tree to be delivered before it forwards each question of
captures (`Ffi.syntaxSettle`): the one difference from `model-test`'s run of
the same list against the model. `syntaxTreeChecks` pins what only the real
binding shows: that the library has a Rust grammar, a Rust function's name
captured, a query of one grammar asked of a text parsed with another, and a
text edited through its document reparsed, its new function's name captured
once the tree of the edit is delivered. That the text of a file the file
service loaded is of no document is `ffi-test`'s (`FfiTest.syntaxChecks`).

A compile and the shipped modes over the real process service are not
checked here: the compile mode is a package outside the core
(`packages/compile/`), and its linked test runs them
(`CompileTest.compileRunChecks`, `CompileTest.projectRunChecks`, which were
`compileChecks` and `projectModeChecks` here), on the linked test kit this
executable's checks are written on too (`Editor/Test/Linked/`).

The workspace finder, its contract and the mode marker search's over the
real process and file services, and the listers a workspace's files are
listed with over real git and find, are not checked here either: the
workspaces are a package outside the core (`packages/workspace/`), and its
linked test runs them (`WorkspaceTest.Linked.workspaceFinderContractChecks`,
`modeMarkerContractChecks` and `workspaceListerChecks`, which were this
executable's, `workspaceChecks`' worlds now properties
of the finder's contract), with the fixtures under that package's
`tests/`. Nor are the working sets over the file service, the
fuzzy matcher and real git, through a restart: they are the `working-set`
package's (`packages/working-set/`), whose linked test runs them
(`WorkingSetTest.Linked.workingSetChecks`, which was this executable's).
Nor is project search over the grep and file services: it is the
`project-search` package's (`packages/project-search/`), whose linked test
runs it (`ProjectSearchTest.Linked.projectSearchChecks`, which was this
executable's). Nor is `:!`: it is the `shell` package's
(`packages/shell/`), whose linked test runs it
(`ShellTest.Linked.shellChecks`, which was this executable's), on a rig over
fakes since host-tests-on-fakes phase 4.
Nor is version control over real git: the version-control interface's
contract against the git implementation, in lanes of their own, the git
implementation's own checks, and the status, worktree, review, log and blame
buffers are the `version-control` package's (`packages/version-control/`),
whose linked test runs the git implementation's
(`VersionControlTest.Linked.inLanesChecks`, `versionControlContractChecks` and
`versionControlChecks`, which were this executable's), and whose model
checks run the buffers'. The contract's run against the model is the core's
(`VcApiTest.versionControlContractFailures`, in the interface package `vc-api`).

`filteringChecks` runs a source a command filters
(`Editor/Completion/Filtering.lean`) over the real process service, with
`/bin/cat` of a list the check writes as the lister and the fixture
`tests/completion/filter` standing in for fzf, each in a temporary
directory of its own: a text of shell metacharacters and quotes reaches the
filter as one literal argument, with line-separated and NUL-separated
records, and no command in it runs; the fixture fails a text split in two;
the empty text over 10,000 records with a small byte limit answers whole
records, a prefix of the list, the filter ended; a filter that is not there
fails naming it; and the fixture's exit 1 is no matches, or a failure when
no status is declared. Every child is reaped.

The cases of the editor API (`Editor/Api/Cases.lean`) are played on the
real text binding, with a recorder as the display and nothing watched
(`apiFailures`): each from a table of its own, dropped with the case.
`model-test` plays the same list on the editor's models, so every request
an operation of the API makes of the library is answered the same by both.

`main` starts the pump once, on a dedicated task. When the checks are done
it quits the queues, requires the pump to have ended, and exits explicitly:
that is the shutdown sequence, and returning from `main` while a dedicated
task is blocked in the library would hang.

A check waits for what the library does with a bound, so a broken service
fails a check within seconds. Deadlines are an hour away where a wait must
not complete, and 0 to 3 ms where it must: no check sleeps to let something
happen.

No check knows how many threads Lean's pool has. That number is Lean's, and
`LEAN_NUM_THREADS` in the environment changes it, so `main` learns the
pool's threads by warming it before the pump starts, and the check of the
pump is stated relative to them.

`mise run ffi-test` runs it, in the gate. It names what did not hold and
exits non-zero if anything did not.
-/

/-- Runs the text port's contract against its real binding, then the job
port's contract and the job checks against the runner over the library's
timer service, the display interface's against the recorder and the watch
port's against its real binding, then shuts down: exits 0 when everything
holds, and 1 after naming on stderr what does not.

Its three arguments are the directory of the fixtures a child's
environment is looked up with (`tests/process-environment`), the directory
of the syntax fixtures (`tests/syntax`), and the directory of the fixture
that stands in for fzf in the filtering checks (`tests/completion`), each
made absolute here;
any other command line is status 2, with the usage on stderr.

The pool's threads are learnt first, by warming it, before anything else
runs: the check that the pump is not one of the pool's tasks compares
against them. Then the completion pump runs on a dedicated task for the rest
of the run. Shutdown is quit, which must end the pump, then an explicit
exit: a task that failed a check may still be blocked in the library. -/
def main (arguments : List String) : IO UInt32 := do
  -- The fixtures of the environment checks, the syntax checks and the
  -- filtering checks, made absolute here, at the edge.
  let (fixtures, syntaxFixtures, completionFixtures) ←
    match arguments with
    | [directory, syntaxDirectory, completion] =>
      pure
          (← IO.FS.realPath directory, ← IO.FS.realPath syntaxDirectory,
            ← IO.FS.realPath completion)
    | _ =>
      IO.eprintln
          "usage: contract-test <the directory of the process-environment fixtures> <the directory of the syntax fixtures> <the directory of the completion fixtures>"
      return 2
  let some pool ← Editor.Job.Pool.holdAll (← Editor.Job.Pool.expected) ContractTest.warmPatience |
    IO.eprintln
        s!"contract-test: a hang: the pool's tasks had not all started within {ContractTest.warmPatience.ms} ms"
    return 1
  -- The real services, over a table of waits of their own, with the pump
  -- started (`Editor/Test/Linked/Services.lean`). No command of this run
  -- publishes a snapshot to them: the file properties save what their own
  -- jobs loaded.
  let running ← Editor.Test.Linked.Services.start
  let completions := running.completions
  let held := running.held
  let services := running.jobs
  let properties := Editor.TextContract.properties
  -- The undo tree's cases run through the same binding, so the count of
  -- live documents covers the texts they make too.
  let cases := Editor.UndoTreeCases.cases
  let adoptProperties := Editor.TextContract.adoptProperties
  let textFailed ← ContractTest.failures (properties ++ cases) adoptProperties
  let pairChecks := ContractTest.pairChecks
  let pairCheckFailed ← ContractTest.checkFailures pairChecks
  let jobFailed ← ContractTest.jobFailures services
  let postFailed ← ContractTest.postFailures services
  let fuzzyJobFailed ← ContractTest.fuzzyJobFailures services
  let snapshotJobFailed ← ContractTest.snapshotJobFailures services
  let fileFailed ← ContractTest.fileFailures services held
  let processFailed ← ContractTest.processFailures services
  let processChecks := ContractTest.processChecks services
  let processCheckFailed ← ContractTest.checkFailures processChecks
  let flushContractChecks := ContractTest.flushContractChecks services
  let flushContractFailed ← ContractTest.checkFailures flushContractChecks
  let handleContractChecks := ContractTest.handleContractChecks services
  let handleContractFailed ← ContractTest.checkFailures handleContractChecks
  let journalContractChecks := ContractTest.journalContractChecks services
  let pumpContractChecks := ContractTest.pumpContractChecks services
  let pumpContractFailed ← ContractTest.checkFailures pumpContractChecks
  let journalContractFailed ← ContractTest.checkFailures journalContractChecks
  let queueContractFailed ← ContractTest.checkFailures ContractTest.queueContractChecks
  let queueRealFailed ← ContractTest.checkFailures ContractTest.queueRealChecks
  let linkedServicesChecks := ContractTest.linkedServicesChecks services
  let linkedServicesFailed ← ContractTest.checkFailures linkedServicesChecks
  let environmentChecks := ContractTest.environmentChecks services fixtures
  let environmentFailed ← ContractTest.environmentFailures services fixtures
  let filteringChecks := ContractTest.filteringChecks services completionFixtures
  let filteringCheckFailed ← ContractTest.checkFailures filteringChecks
  let restoreRunChecks := ContractTest.restoreRunChecks services
  let restoreRunCheckFailed ← ContractTest.checkFailures restoreRunChecks
  let fileWatchFailed ← ContractTest.fileWatchFailures services
  let fileWatchChecks := ContractTest.fileWatchChecks services
  let fileWatchCheckFailed ← ContractTest.checkFailures fileWatchChecks
  -- The job checks first: the last of them measures the pool, which a later
  -- check must not have grown.
  let checks := ContractTest.jobChecks services pool
  let checkFailed ← ContractTest.checkFailures checks
  let protocolContractChecks := ContractTest.protocolContractChecks services
  let protocolContractFailed ← ContractTest.checkFailures protocolContractChecks
  let fileChecks := ContractTest.fileChecks completions
  let fileCheckFailed ← ContractTest.checkFailures fileChecks
  let grepChecks := ContractTest.grepChecks completions
  let grepCheckFailed ← ContractTest.checkFailures grepChecks
  let caseFailed ← ContractTest.caseFailures completions
  let displayFailed ← ContractTest.displayFailures
  let recorderContractFailed ← ContractTest.recorderFailures
  let recorderChecks := ContractTest.recorderChecks
  let recorderFailed ← ContractTest.checkFailures recorderChecks
  let clipboardFailed ← ContractTest.clipboardFailures
  let realClipboardFailed ← ContractTest.realClipboardFailures
  let clipboardChecks := ContractTest.clipboardChecks
  let clipboardCheckFailed ← ContractTest.checkFailures clipboardChecks
  let fuzzyFailed ← ContractTest.fuzzyFailures
  let styleFailed ← ContractTest.styleFailures
  let fuzzyChecks := ContractTest.fuzzyChecks
  let fuzzyCheckFailed ← ContractTest.checkFailures fuzzyChecks
  let syntaxTreeFailed ← ContractTest.syntaxTreeFailures
  let syntaxTreeChecks :=
    ContractTest.syntaxTreeChecks ++ ContractTest.syntaxFixtureChecks syntaxFixtures
  let syntaxTreeCheckFailed ← ContractTest.checkFailures syntaxTreeChecks
  let syntaxDeliveryChecks := ContractTest.syntaxDeliveryChecks
  let syntaxDeliveryFailed ← ContractTest.checkFailures syntaxDeliveryChecks
  let watchFailed ← ContractTest.watchFailures services.timers
  let watchChecks := ContractTest.watchChecks services.timers
  let watchCheckFailed ← ContractTest.checkFailures watchChecks
  let apiFailed ← ContractTest.apiFailures
  let pumpEnded ← running.stop
  let failed :=
    textFailed.map (s!"the real text binding: {·}") ++ pairCheckFailed ++ jobFailed ++ postFailed ++
      fuzzyJobFailed ++
      snapshotJobFailed ++
      fileFailed ++
      processFailed ++
      processCheckFailed ++
      flushContractFailed ++
      handleContractFailed ++
      journalContractFailed ++
      pumpContractFailed ++
      queueContractFailed ++
      queueRealFailed ++
      linkedServicesFailed ++
      environmentFailed ++
      filteringCheckFailed ++
      restoreRunCheckFailed ++
      fileWatchFailed ++
      fileWatchCheckFailed ++
      checkFailed ++
      protocolContractFailed ++
      fileCheckFailed ++
      grepCheckFailed ++
      caseFailed ++
      displayFailed ++
      recorderContractFailed ++
      recorderFailed ++
      clipboardFailed ++
      realClipboardFailed ++
      clipboardCheckFailed ++
      fuzzyFailed ++
      styleFailed ++
      fuzzyCheckFailed ++
      syntaxTreeFailed ++
      syntaxTreeCheckFailed ++
      syntaxDeliveryFailed ++
      watchFailed ++
      watchCheckFailed ++
      apiFailed ++
      if pumpEnded then [] else ["quit ends the completion pump"]
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    IO.Process.exit 1
  IO.println
      s!"contract-test: {properties.length + adoptProperties.length} properties hold of the real text binding, {cases.length} cases of the undo tree hold over it, {pairChecks.length} check of its bracket walk against the text model passed, and its documents and snapshots are freed when released and with its table; {Editor.JobContract.properties.length} properties hold of the job runner over the timer service, and {Editor.JobContract.postProperties.length} post properties, and {Editor.JobContract.fuzzyProperties.length} fuzzy properties over the library's matcher, and {Editor.JobContract.snapshotProperties.length} snapshot properties over a published table, and {Editor.JobContract.fileProperties.length} file properties over the file service, on real files, and {Editor.JobContract.grepProperties.length} search properties over the grep service, on real files, with {grepChecks.length} checks of the grep service's adapter, and {Editor.JobContract.processProperties.length} process properties over the process service, on real processes, with {processChecks.length} checks of the process service's adapter, {flushContractChecks.length} of the services' flushes, {handleContractChecks.length} of a file request's handle, {journalContractChecks.length} of the session journal over it, {pumpContractChecks.length} of the completion pump over the library's queue, {linkedServicesChecks.length} of a test directory's bracket over the file service, and {environmentChecks.length} of a child's environment over it, with mise standing in as a fixture, and {filteringChecks.length} of a source a command filters, with fzf standing in as a fixture, and {restoreRunChecks.length} of session restore over the file service, through a restart, and {Editor.JobContract.fileWatchProperties.length} watch properties over the watch service, on real files, with {fileWatchChecks.length} checks of the watch service's adapter; {checks.length} checks of the timer service passed, {protocolContractChecks.length} of the runner's protocol over the timer and file services, on real threads, {fileChecks.length} of the file service, {Editor.FileCases.cases.length} cases across the text port and the job port hold of the binding and the file service; {(Editor.DisplayContract.properties { advance := 1, lineHeight := 1 }).length} properties of the display interface hold of its real binding in cells of {ContractTest.displayCells.length} sizes, and of the recorder over real snapshots in cells of the same sizes, and {recorderChecks.length} checks of the recorder passed; {Editor.ClipboardContract.properties.length} properties of the clipboard interface hold of the in-process clipboard and of the real binding over the library's memory clipboard, and {clipboardChecks.length} checks of it passed; {Editor.FuzzyContract.properties.length} properties of the fuzzy matching interface hold of its real binding, {Editor.Completion.StyleContract.properties.length} properties of the completion styles hold of the core's own style over it, and {fuzzyChecks.length} checks of a command's ranking and locating passed; {Editor.SyntaxTreeContract.properties.length} properties of the syntax tree interface hold of its real binding over the library's syntax service, and {syntaxTreeChecks.length} checks of it passed, and {syntaxDeliveryChecks.length} of its deliveries; {Editor.WatchContract.properties.length} properties of the watch port hold of its real binding, and {watchChecks.length} checks of it passed; {Editor.ApiCases.cases.length} cases of the editor API hold of the real text binding; and quit ended the pump"
  (← IO.getStdout).flush
  IO.Process.exit 0
