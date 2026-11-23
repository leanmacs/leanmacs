# The checks that run a real editor loop thread

Most of `config-test`'s host checks run on a host stepped on the check's own
thread (`Headless.withStepped`, `lean/Editor/Headless/Stepped.lean`): the
host's own turn of the loop (`Running.turn`) over an in-memory editor queue,
with the stage's fakes and the real elaborator, and no loop thread. The
design is in `docs/design/concurrency.md`, "Stepped hosts in tests". This
page lists the checks that still start a real editor loop thread, each
with the adapter it covers, and says how the list is kept true.

## The rule

A host check runs on a real editor loop thread only when the adapter it
covers is the loop thread itself or the library's editor queue that thread
pulls. Every other host check runs on a stepped host. The other real
adapters a stepped check uses stay real and keep their own threads: the
elaborator, the library's file, diff and grep services and the completion
pump, and the display binding. Only the editor loop thread goes.

The elaborator and the display binding stay real: they do no background
work a host check waits on. The session journal, the file, diff and grep
services, the syntax service, process spawns, file watches and the
completion pump each have a recording fake that answers only on the
check's step, held to its real adapter by one contract
([concurrency.md](../design/concurrency.md), "Recording fakes for the
host's background collaborators"), and the host checks move onto them
(host-tests-on-fakes phase 4); until a check has moved it uses the real
adapter, as above.

A check that says `Real` in its helper, or calls `Headless.withHost`,
`Headless.run` or `Headless.runAndDispose` itself, runs a loop thread; the
plain names are the stepped helpers. The helpers are the linked test kit's
(`withRealHost`, `withRealHostOver`, `onRealStage`, `stagedReal`,
`hostingReal`, `lean/Editor/Test/Linked/Host.lean`; `withRealShippedHost`,
`lean/Editor/Test/Linked/Shipped.lean`), the config tests' own
(`withRealTestHost`, `lean/ConfigTest/Support/Shipped.lean`;
`withRealRestoreHost`, `withRealRestoreFiles`, `withRealJournalHost`,
`withRealEnvironments`, `withRealRecordedSyntaxTree`, `hostedReal`,
`lean/ConfigTest/Editor/Headless.lean`), and a package's linked test's
(`withRealVimHost`, evil's; `withRealFileHost` and `withRealLanguageHost`,
the files package's).

| Code | Adapter the check covers | Why it needs the loop thread |
|---|---|---|
| A1 | The host's bracket and the loop's lifetime: `Headless.withHost`, `withHostEnding`, guard, grace, `abandoned`, `endWaits`, `loopStarted` | The subject is the thread and its join |
| A2 | The driver's waits over the loop thread: `Host.waitWhile` markers and rounds, the idle signal read across the thread, an editor thread held inside an event | The subject is the cross-thread wait |
| A3 | The headless mode's script runner: `Headless.run`, `runAndDispose`, `runFrom`, the CLI's driver, also used by the headless fixtures and the package linked tests | The runner is defined over `Host` |
| A4 | The library's editor queue: a Rust poster (`Ffi.feedScript`), the interrupt key's mark, and the flag raised as a key arrives while a command runs | Needs the library queue and a command running concurrently |
| A5 | The library's syntax service, whose parses come back over the library's editor queue (`Event.parsed`) and are waited for with `Ffi.syntaxSettle` | A stepped host never pulls the library queue, and a stray `parsed` would reach the next real host |
| A6 | The window mode's wiring (`Editor.Window.host` and its start-up wait) | It is the window mode's edge |
| A7 | The library's watch service on real files (`Session.shownOn`, the scene asked at each job line); no check of `config-test` since the features that watch files moved into packages, whose linked tests cover it (below) | Background deliveries on the library's clock |

## config-test: 52 checks

By adapter: A1 8, A2 10, A3 25, A4 5, A5 3, A6 1. Each name is a
check's name exactly, one a line, inside a `checks` block, which is what
the gate reads (below).

### A1: 8 checks

The host's bracket and the loop's lifetime (`Headless.withHost`, `withHostEnding`, its guard, its grace, `endWaits`, `loopStarted`, the refusal of a stepper's queue): the subject is the thread and its join.

Lists: `bracketChecks`.

```checks
a check's bracket whose loop is held past its guard and its grace fails as a hang, saying the loop's hang once, and hands the loop it left to `abandoned`
a check's settle on a host whose loop ended before the requests settled says the loop ended, with the error it ended with, and not a hang
a host's bracket returns only once its loop has ended: a loop held inside an event when the bracket asks it to stop is waited for past the bracket's guard, which says a hang once
a host's bracket returns only once its reload job has ended: a reload held at the gate inside elaboration when the body returns is waited for by the loop's end, which says so once (`endWaits`), and the gate is let go only then
a host's bracket stops and waits for its loop when its body throws, and the body's error is the one thrown
a host's bracket that hands back its loop's end gives the error its loop ended with, and throws nothing, when its body returned
a host's bracket throws the error its loop ended with when its body returned
a stage's real host calls its loopStarted once, on its loop's own thread, not the check's, and a check's own run of the loop's handler never calls it
```

### A2: 10 checks

The driver's waits over the loop thread (`Host.waitWhile`: markers and rounds, the idle signal read across the thread, an editor thread held inside an event), and the scene-count parity check that compares a stepped host with a real one.

Lists: `idleChecks`, `moduleHostChecks`, `scriptChecks`, `steppedChecks`.

```checks
a join does not answer working while a job is about to start its sleep: with the job's start held, the join blocks on it, and answers working once the job is in its sleep
a join does not answer working while a job's result is on its way: with the job's reading of the clock held after its sleep, the join blocks on it, and answers settled once the job's line is printed
a pause of completion at point armed on the fake clock holds no unit, and its event holds one from the clock's move until the editor thread has handled it
a wait's later rounds publish nothing: the scene count after a join that took two rounds, its job's sleep held until the join blocked on it, is the count after the same join that took one
on a stage host, a job asleep on the fake clock holds no unit: after spawn count the count reaches 0 with the sleep in the clock, and a marker answered after it leaves it there
on a stage host, a job the clock lets go holds a unit until its result has been handled: after advance 10 the count is 1 while the editor thread is held before printing the job's line, and 0 once a marker is answered
a settle after a reload whose root first imports Lean waits for the reload's end: the reload is held at the gate until the settle is waiting on it, and the settle answers once it has installed
a join and an advance on a job held for good in a wait that ends by itself reach their guard: each says its hang once, and fails as busy with its line
a wait that runs out says why: a reload is still running, or the editor thread has not answered
a stepped host publishes the scenes a real host does: a settle one, and a join's later rounds none
```

### A3: 25 checks

The headless mode's script runner (`Headless.run`, `runAndDispose`, `runFrom`): the CLI's driver, defined over `Host`, which the headless fixtures share.

Lists: `jobChecks`, `scriptChecks`.

```checks
an idle answers only once the render loop is at rest: with a frame in flight as it begins, it waits for the frame's end, on the loop's rest and never for a time, and counts from that rest, so a loop then left alone has drawn and been handed nothing
a join that cannot finish fails at idle, it does not hang: the failure names the join's line, nothing is said as a hang, and the loop cancels its jobs when it ends
an indexed that cannot finish, a background job asleep on the fake clock no advance moves, fails at idle, it does not hang: the failure names the indexed's line as the editor idle with a job still running, and nothing is said as a hang
an editor thread held inside an event when a join asks for its answer still makes the join answer working, at idle: the hold is let go when the join blocks on the answer, and nothing is said as a hang
a headless run whose loop is held past its guard and its grace says the hang once and fails as hung, which exits 1, and hands the loop it left to `abandoned`
a headless run whose loop is slow but ends within its grace succeeds, after saying the hang once
a host made by a stage and handed straight to Headless.run still gets its reload's wake-up: reload, settle and show end with no failure, the reload installed and its command shown
a join with its own seconds has them as its guard, and its failure names them
a real config that defines a segment and lists the mode line installs: the reload prints a line for the segment nobody registered, the echo area says it, and each status line is the listing's, in its order and on its sides
a restarted with its own seconds waits that long for a hand-over, not the run's patience, and its failure says how long it waited
a run that fails disposes of its collaborators too, once, when its loop has ended
a run that reaches its script's end disposes only after its loop has ended, when the loop is slow to end
a run whose advance stalls while the editor thread is inside an event disposes only after its loop has ended
a run whose join runs out while the editor thread is inside an event disposes only after its loop has ended
a run's settle waits for the reload's end: the reload is held at the gate until the settle has blocked on it, and the run goes on once it has installed, saying no hang
a script that commits text and asks for the scene prints the scene: its frame, and a view whose snapshot holds the text, read from the library, with the cursor after it
a script that ends while a reload cannot finish fails at its end, with a reload still running and no line
a script that resizes the frame and asks for the scene prints the scene in a frame of that size, with its one view in the whole of it above the bottom row, one 16-pixel cell of the recorder; a second resize is the next scene's size
a script that runs to its end has no failure, and what it asked for was printed before the loop stopped
a script that sends a key with modifiers prints that the key arrived with those modifiers, in order with what it asked for
a script whose settle cannot be satisfied fails, it does not hang, and the failure names the settle's line and says a reload was still running
a settle with its own milliseconds waits that long, not the run's patience, and its failure says how long it waited
on a stage host, spawn count, advance by its sleep and join end with the job's line, ok; an advance with nothing due stalls at idle, with its line and its milliseconds, saying no hang, and an advance on a host with no fake clock fails with its sentence
the headless mode's run disposes of its collaborators once its loop has ended: dispose is called once, after every line the script had the host print
the scene prints each view's status line after the view's line, with the fields the loop gives the view: the buffer's name alone before anything is typed, and the modified field after it once text is committed
```

### A4: 5 checks

The library's editor queue: a Rust poster (`Ffi.feedScript`), the interrupt key's mark, and the flag raised as a key arrives while a command runs.

Lists: `dispatchChecks`, `hostLoopChecks`, `threadChecks`.

```checks
the interrupt key arrives while a command loops over requests: the command stops, the scene's echo says so, the view's text is that before the command, and the next key runs its command
the interrupt key arrives while no command is running: the flag is down once the loop has taken it, and the next key's command runs to its end
a finished job's command is guarded as a key's is: the interrupt key that arrives as it is delivered stops the command that loops over requests, the output says the job was interrupted, the view's text is that before the delivery, and the flag is down once the loop has taken the key
the driver's run of a command is guarded: with the interrupt key arrived the command that loops over requests is stopped, the output says it was interrupted, and the flag is down once the loop has taken the key
the editor answers events while a slow file elaborates: 100 events from a Rust thread and a command of the old config
```

### A5: 3 checks

The library's syntax service, whose parses come back over the library's editor queue (`Event.parsed`) and are waited for with `Ffi.syntaxSettle`: a stepped host never pulls that queue, and a stray `parsed` would reach the next real host.

Lists: `indentChecks`, `jobChecks`.

```checks
a parse of a highlighted text the library delivers makes the real host publish a scene, with no key pressed
in a Rust buffer whose indentation was mangled, a command of config's that applies the edits TextId.reindentEdits answers of every row gives text equal to the rustfmt-formatted fixture it came from, through the host's loop and the library's syntax tree, the rows inside its multi-line string and block comment kept; in a buffer with no language it is refused as a text with no syntax tree and the text is left, and in a JSON buffer, whose language has no indents query, as one with no query
in a Rust buffer, TextId.openingLevel asked by a command of config's answers one level after an opening brace, above a closing brace and at the text's end with none, and two in a method of an impl at the text's end; in a buffer with no language it is refused as a text with no syntax tree, and in a JSON buffer as one with no indents query
```

### A6: 1 checks

The window mode's wiring (`Editor.Window.host` and its start-up wait).

Lists: `scriptChecks`.

```checks
the window mode's wait for its start-up config, past its patience with the reload still running, says nothing on stderr: its patience is a bound of the window's, not a hang
```

## FfiTest

No check in `FfiTest.checks` runs an editor loop. Seven scenarios that
`mise run ffi-test` runs start a real editor loop, all A6, through
`Editor.Window.host` in `lean/FfiTest/Editor/Window/Real.lean`:
`windowHostScenario`, `windowHostConfigScenario`, `windowHostBaseScenario`,
`windowHostGenerateScenario`, `windowHostDirectScenario`,
`windowHostUndrawnScenario` and `windowHostRestartScenario`.

Its other threads are adapter contract checks of the window platform and
the queues, not editor loops: `windowChecks` and `renderChecks` run
`Ffi.windowRun` on a dedicated task (`FfiTest/Support/Windows.lean`,
`FfiTest/Editor/Ffi/Window.lean`, `FfiTest/Editor/Ffi/Render.lean`),
`WindowCheck.check`'s loop runs in `FfiTest/Editor/Ffi/Window.lean`, and
parked pulls run in `queueChecks` and `shutdownChecks`
(`FfiTest/Editor/Ffi/Events.lean`).

## ContractTest

None. Its loop checks step `Loop.start` and `Loop.step` on the check's
thread (`ContractTest/Editor/Restore/Run.lean`,
`ContractTest/Editor/Watch/Real.lean`), and the editor queue port's real
binding is run there as a contract (`ContractTest.queueContractChecks`), on
the check's thread.

## The package linked tests

The checks that were `config-test`'s while their features were modules of
the core moved into those packages' linked tests with the features-as-packages
roadmap, and the ones that ran a real loop thread still do, by the same
rule. No gate lists them by name: a package's linked test keeps no
inventory, and each says `Real` in its helper or calls the runner itself.

| Linked test | Checks | Adapter |
|---|---|---|
| `tests/packages/greeting/GreetingTest/Linked.lean` | its one script | A3: `Headless.run` |
| `packages/compile/CompileTest/Linked.lean` | its one script | A3: `Headless.run` |
| `packages/ex/ExTest/Linked/Ex.lean` | `exScriptChecks`: the three scripts of ex lines (`ranScript`) | A3: `Headless.run` |
| `packages/ex/ExTest/Linked/Ex.lean` | `exScriptChecks`: a wait on a host whose loop a command ended | A2: `Headless.withHost` |
| `packages/evil/EvilTest/Linked/Evil/Operators.lean` | the eight indent checks through the Vim scheme's keys (`withEvilIndentHost`) | A5: `withRealVimHost` |
| `packages/evil/EvilTest/Linked/Evil/TreeObjects.lean` | `treeObjectChecks`, both | A5: `withRealVimHost` |
| `packages/files/FilesTest/Linked/Files.lean` | `languageChecks`, all but the buffer with no language | A5: `withRealLanguageHost` |
| `packages/files/FilesTest/Linked/Files.lean` | `autoReloadChecks`, and the auto-reload row of `config-bench` (`FilesTest/Linked/Files/Bench.lean`) | A7: `withRealFileHost` |
| `packages/version-control/VersionControlTest/Linked/VersionControl/Gutter.lean` | `gutterChecks`: criterion 6 over real git | A7: `onRealStage` |

Every other host check of a package's linked test runs on a stepped host,
through the kit's plain helpers, and fails if it grew the library's editor
queue, as a check of `config-test` does.

## How the list is checked

A real loop calls its collaborators' `loopStarted` on its own thread before
its first event, and a stage's host counts itself there
(`HostContext.realLoops`); a stepped host never calls it. `config-test ...
--real-threads <file>` writes the sorted names of the checks during which a
loop thread started (`ConfigTest.inventory`). `mise run ffi-test` runs
config-test so, extracts the `checks` blocks of this page with `awk`, sorts
them bytewise and fails when the two lists differ: a check that starts
running a loop thread, or stops, changes this page in the same commit. It
is behaviour, not text: a name is listed because a loop thread started
while that check ran.

A stepped check is also guarded the other way: each stepped helper fails a
check that grew the library's editor queue (`leavingLibraryQueue`), where
the next real host would take what it left, and a real host refuses
collaborators whose queue a stepper drains (`Headless.start`).

## config-test's wall time

Measured with the method of the phase's plan: an idle machine (an 18-core
Mac, no `yes` processes, nothing else from mise running), `lake build`
done first so no build is timed, and from `lean/` five sequential runs of
`/usr/bin/time -p .lake/build/bin/config-test "$(lean --print-prefix)"
.lake/build/lib/lean ../tests/syntax ../config/default`.

| | Commit | Checks | Runs, `real` s | Median |
|---|---|---|---|---|
| Before, 2026-11-21 04:38 | `9439623d` | 326 | 13.34, 13.42, 13.35, 13.54, 13.49 | 13.42 |
| After, 2026-11-21 07:07 | `1a8ed1dc` | 340 | 14.79, 14.61, 14.66, 14.46, 14.42 | 14.61 |

The two sets were taken hours apart, and the second while another
checkout's gate had just loaded the machine (its 5-minute load average
was 8, against 2.5 for the first). So both binaries were also run
interleaved, before then after, five times each, minutes apart, the
1-minute load between 2.7 and 3.6:

| | Commit | Checks | Runs, `real` s | Median |
|---|---|---|---|---|
| Before | `9439623d` | 326 | 13.80, 13.55, 13.73, 13.80, 13.57 | 13.73 |
| After | `1a8ed1dc` | 340 | 13.53, 13.46, 13.74, 13.88, 13.45 | 13.53 |

Interleaved, the after median is below the before median and below the
largest before run: config-test's wall time did not grow, with 14 checks
more. Per check, timed in a run of each, the checks summed to 13.27 s
before and 13.18 s after; the 142 moved checks to 4.53 s before and 4.46 s
after. Most of a check's time is the real elaborator's, which the stepped
hosts keep.
