import ContractTest.Check
import ContractTest.Editor.Api.Cases
import ContractTest.Editor.Clipboard.Contract
import ContractTest.Editor.Clipboard.Real
import ContractTest.Editor.Compile
import ContractTest.Editor.Compile.Shipped
import ContractTest.Editor.Completion.Filtering
import ContractTest.Editor.Completion.StyleContract
import ContractTest.Editor.Display.Contract
import ContractTest.Editor.Display.Recorder
import ContractTest.Editor.File.Cases
import ContractTest.Editor.Fuzzy.Contract
import ContractTest.Editor.Fuzzy.Real
import ContractTest.Editor.Job.Contract
import ContractTest.Editor.Job.Real
import ContractTest.Editor.Process.Environment
import ContractTest.Editor.Shell
import ContractTest.Editor.SyntaxTree.Contract
import ContractTest.Editor.SyntaxTree.Real
import ContractTest.Editor.Text.Contract
import ContractTest.Editor.VersionControl.Contract
import ContractTest.Editor.VersionControl.Git
import ContractTest.Editor.VersionControl.Log
import ContractTest.Editor.VersionControl.Review
import ContractTest.Editor.VersionControl.Status
import ContractTest.Editor.Watch.Contract
import ContractTest.Editor.Watch.Real
import ContractTest.Editor.Workspace
import ContractTest.Editor.Workspace.Contract
import ContractTest.Editor.Workspace.Lister
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
import Editor.VersionControl.Contract
import Editor.Watch.Contract
import Editor.Workspace.Contract

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

`jobChecks` then pins what only the real service can show: that a job in a
real wait holds no thread, that cancelling a job takes its timer out of the
library's schedule, that a deadline no machine word holds is not cut down,
and that the pump is not one of the pool's tasks.

The cases that cross the text port and the job port
(`Editor/File/Cases.lean`) are played on the real binding and the library's
file service, on real files (`playOnLibrary`, `caseFailures`): a command, a
job on the runner, the job's command run by `Job.finishWith`, as the loop
runs it, and a last command. `model-test` plays them on the two models.

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
library's matcher (`fuzzyFailures`): which candidates a pattern matches,
and that a candidate that is the pattern is first. `model-test` runs the
same list against the model. Nothing more is asked of the two: after the
candidates that are the pattern, the binding's order is the library's
scores and the model's is the candidates' own. `fuzzyChecks` pins where a
command's fuzzy requests go when it is run against the library: to that
binding, with nothing handed in.

The completion styles' contract (`Editor/Completion/StyleContract.lean`) is
run against the fuzzy style over that binding (`styleFailures`), and
`model-test` runs it against the fuzzy style over the model, the orderless
style and the style model: which indices a style answers, its ranges, and
that the empty text lists every candidate.

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

`shellChecks` runs `:!` and a filter (`Editor/Shell.lean`) over the real
process service, with the command loop over the real text binding: the ex
line's commands and the shell's are registered, the editor's working
directory is the fixtures' (`tests/shell`), and each line is run as a host
runs it, its invocations as steps of their own, each job it starts spawned
on the runner over the library's services and its command delivered once
the job has ended (`settle`). `:!` of the fixture `hello` leaves `hello` in
the echo area, and `%!/usr/bin/sort` over `b`, `c`, `a` leaves `a`, `b`,
`c`; every child is reaped.

`compileChecks` runs `compile` (`Editor/Compile.lean`) over the real process
service, with the command loop over the real text binding, in a temporary
directory of its own as the editor's working directory: its job is spawned
on the runner over the library's services with a host that records its
posts, and each post is delivered as it arrives. The fixture
`tests/compile/three-lines` waits for a file before each of its last two
lines, which the check makes only once it has seen the line before in the
compilation buffer: so each line is shown before the child ends, the last
line says its exit status, 2, and the child is reaped.

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

`workspaceListerChecks` runs the listers a workspace's files are listed
with (`Editor/Workspace/Lister.lean`) through the finder's source
(`FindFile.found`) over the real process service, with real git and find,
the fixture `tests/completion/filter` standing in for fzf with the empty
text, each in a temporary directory of its own and git isolated from the
user's config: git's lister lists a repository's tracked and untracked
files and none that `.gitignore`, `info/exclude` or the global excludes
file ignore; it lists a linked worktree's own files at its root and not at
the main checkout's; the fallback lists a directory's files without
`./` and none under a `.git` directory; and, past a directory of mode 000,
which makes `find` exit 1, it still lists the files it could read (all of
them when run as root). Every child is reaped.

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

Its six arguments are the directory of the fixtures a child's
environment is looked up with (`tests/process-environment`), the directory
of the fixture that stands in for git in the workspace finder's checks
(`tests/workspaces`), the directory of the fixture `:!` runs, which is also
the editor's working directory in those checks (`tests/shell`), the
directory of the fixtures `compile` runs, with the programs that stand for
cargo, lake and mise and the trees the shipped modes are checked in
(`tests/compile`), the directory of the syntax fixtures (`tests/syntax`),
and the directory of the fixture that stands in for fzf in the filtering
checks (`tests/completion`), each made absolute here;
any other command line is status 2, with the usage on stderr.

The pool's threads are learnt first, by warming it, before anything else
runs: the check that the pump is not one of the pool's tasks compares
against them. Then the completion pump runs on a dedicated task for the rest
of the run. Shutdown is quit, which must end the pump, then an explicit
exit: a task that failed a check may still be blocked in the library. -/
def main (arguments : List String) : IO UInt32 := do
  -- The fixtures of the environment checks, the workspace checks, the shell
  -- checks, the compile checks and the syntax checks, made absolute here, at
  -- the edge.
  let
    (fixtures, workspaceFixtures, shellFixtures, compileFixtures, syntaxFixtures,
      completionFixtures)
    ←
    match arguments with
    | [directory, workspaces, shell, compile, syntaxDirectory, completion] =>
      pure
          (← IO.FS.realPath directory, ← IO.FS.realPath workspaces, ← IO.FS.realPath shell,
            ← IO.FS.realPath compile, ← IO.FS.realPath syntaxDirectory, ← IO.FS.realPath completion)
    | _ =>
      IO.eprintln
          "usage: contract-test <the directory of the process-environment fixtures> <the directory of the workspace fixtures> <the directory of the shell fixtures> <the directory of the compile fixtures> <the directory of the syntax fixtures> <the directory of the completion fixtures>"
      return 2
  let pool ← Editor.Job.Pool.whole ContractTest.warmPatience
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
  let environmentChecks := ContractTest.environmentChecks services fixtures
  let environmentFailed ← ContractTest.environmentFailures services fixtures
  let workspaceFailed ← ContractTest.workspaceFailures services workspaceFixtures
  let modeMarkerFailed ← ContractTest.modeMarkerFailures services
  let workspaceChecks := ContractTest.workspaceChecks services workspaceFixtures
  let workspaceCheckFailed ← ContractTest.checkFailures workspaceChecks
  let shellChecks := ContractTest.shellChecks services shellFixtures
  let shellCheckFailed ← ContractTest.checkFailures shellChecks
  let compileChecks := ContractTest.compileChecks services compileFixtures
  let compileCheckFailed ← ContractTest.checkFailures compileChecks
  let filteringChecks := ContractTest.filteringChecks services completionFixtures
  let filteringCheckFailed ← ContractTest.checkFailures filteringChecks
  let workspaceListerChecks := ContractTest.workspaceListerChecks services completionFixtures
  let workspaceListerCheckFailed ← ContractTest.checkFailures workspaceListerChecks
  let projectModeChecks := ContractTest.projectModeChecks services compileFixtures workspaceFixtures
  let projectModeCheckFailed ← ContractTest.checkFailures projectModeChecks
  let versionControlFailed ← ContractTest.versionControlFailures services
  let versionControlChecks := ContractTest.versionControlChecks services
  let versionControlCheckFailed ← ContractTest.checkFailures versionControlChecks
  let statusBufferChecks := ContractTest.statusBufferChecks services
  let statusBufferCheckFailed ← ContractTest.checkFailures statusBufferChecks
  let reviewBufferChecks := ContractTest.reviewBufferChecks services
  let reviewBufferCheckFailed ← ContractTest.checkFailures reviewBufferChecks
  let historyBufferChecks := ContractTest.historyBufferChecks services
  let historyBufferCheckFailed ← ContractTest.checkFailures historyBufferChecks
  let fileWatchFailed ← ContractTest.fileWatchFailures services
  let fileWatchChecks := ContractTest.fileWatchChecks services
  let fileWatchCheckFailed ← ContractTest.checkFailures fileWatchChecks
  -- The job checks first: the last of them measures the pool, which a later
  -- check must not have grown.
  let checks := ContractTest.jobChecks services pool
  let checkFailed ← ContractTest.checkFailures checks
  let fileChecks := ContractTest.fileChecks completions
  let fileCheckFailed ← ContractTest.checkFailures fileChecks
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
      environmentFailed ++
      workspaceFailed ++
      modeMarkerFailed ++
      workspaceCheckFailed ++
      shellCheckFailed ++
      compileCheckFailed ++
      filteringCheckFailed ++
      workspaceListerCheckFailed ++
      projectModeCheckFailed ++
      versionControlFailed ++
      versionControlCheckFailed ++
      statusBufferCheckFailed ++
      reviewBufferCheckFailed ++
      historyBufferCheckFailed ++
      fileWatchFailed ++
      fileWatchCheckFailed ++
      checkFailed ++
      fileCheckFailed ++
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
      watchFailed ++
      watchCheckFailed ++
      apiFailed ++
      if pumpEnded then [] else ["quit ends the completion pump"]
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    IO.Process.exit 1
  IO.println
      s!"contract-test: {properties.length + adoptProperties.length} properties hold of the real text binding, {cases.length} cases of the undo tree hold over it, {pairChecks.length} check of its bracket walk against the text model passed, and its documents and snapshots are freed when released and with its table; {Editor.JobContract.properties.length} properties hold of the job runner over the timer service, and {Editor.JobContract.postProperties.length} post properties, and {Editor.JobContract.fuzzyProperties.length} fuzzy properties over the library's matcher, and {Editor.JobContract.snapshotProperties.length} snapshot properties over a published table, and {Editor.JobContract.fileProperties.length} file properties over the file service, on real files, and {Editor.JobContract.processProperties.length} process properties over the process service, on real processes, with {processChecks.length} checks of the process service's adapter and {environmentChecks.length} of a child's environment over it, with mise standing in as a fixture, and {(Editor.Workspace.FinderContract.properties "/").length} properties of the workspace finder over the process and file services, with {workspaceChecks.length} checks of it, with git standing in as a fixture, and {(Editor.Workspace.MarkerContract.properties "/").length} properties of the mode marker search over the file service, and {shellChecks.length} checks of `:!` over the process service, and {compileChecks.length} of a compile, and {filteringChecks.length} of a source a command filters, with fzf standing in as a fixture, and {workspaceListerChecks.length} of git's lister and the fallback, over real git and find, and {projectModeChecks.length} of the shipped modes with fixture programs, and {Editor.VersionControlContract.properties.length} properties of the version-control interface over real git, in temporary repositories, under a user config asking for what its command line pins away, with {versionControlChecks.length} checks of what only git makes (a branch's change asked from two worktrees, a status read of files added with intent to add, what to watch in a linked worktree, and a commit's message under a config that strips one) and {statusBufferChecks.length} checks of the status buffer, of the worktree list, of vc-show, of staging a hunk and of the message buffer over it, and {reviewBufferChecks.length} of the review buffer, and {historyBufferChecks.length} of the log, the blame and the change since the last review, and {Editor.JobContract.fileWatchProperties.length} watch properties over the watch service, on real files, with {fileWatchChecks.length} checks of the watch service's adapter; {checks.length} checks of the timer service passed, {fileChecks.length} of the file service, {Editor.FileCases.cases.length} cases across the text port and the job port hold of the binding and the file service; {(Editor.DisplayContract.properties { advance := 1, lineHeight := 1 }).length} properties of the display interface hold of its real binding in cells of {ContractTest.displayCells.length} sizes, and of the recorder over real snapshots in cells of the same sizes, and {recorderChecks.length} checks of the recorder passed; {Editor.ClipboardContract.properties.length} properties of the clipboard interface hold of the in-process clipboard and of the real binding over the library's memory clipboard, and {clipboardChecks.length} checks of it passed; {Editor.FuzzyContract.properties.length} properties of the fuzzy matching interface hold of its real binding, {Editor.Completion.StyleContract.properties.length} properties of the completion styles hold of the fuzzy style and of the path style over it, and {fuzzyChecks.length} check of a command's ranking passed; {Editor.SyntaxTreeContract.properties.length} properties of the syntax tree interface hold of its real binding over the library's syntax service, and {syntaxTreeChecks.length} checks of it passed; {Editor.WatchContract.properties.length} properties of the watch port hold of its real binding, and {watchChecks.length} checks of it passed; {Editor.ApiCases.cases.length} cases of the editor API hold of the real text binding; and quit ended the pump"
  (← IO.getStdout).flush
  IO.Process.exit 0
