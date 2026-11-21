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

A check that says `Real` in its helper (`withRealHost`, `withRealVimHost`,
`withRealFileHost`, `withRealHostOver`, `onRealStage`, `stagedReal`,
`hostedReal`, `withRealRestoreHost`, `withRealRestoreFiles`,
`withRealJournalHost`, `withRealEnvironments`, `withRealLanguageHost`,
`withRealRecordedSyntaxTree`), or calls `Headless.withHost`,
`Headless.run` or `Headless.runAndDispose` itself, runs a loop thread; the
plain names are the stepped helpers (`lean/ConfigTest/Support/Hosts.lean`).

| Code | Adapter the check covers | Why it needs the loop thread |
|---|---|---|
| A1 | The host's bracket and the loop's lifetime: `Headless.withHost`, `withHostEnding`, guard, grace, `abandoned`, `endWaits`, `loopStarted` | The subject is the thread and its join |
| A2 | The driver's waits over the loop thread: `Host.waitWhile` markers and rounds, the idle signal read across the thread, an editor thread held inside an event | The subject is the cross-thread wait |
| A3 | The headless mode's script runner: `Headless.run`, `runAndDispose`, `runFrom`, the CLI's driver, also used by the headless fixtures and the package linked tests | The runner is defined over `Host` |
| A4 | The library's editor queue: a Rust poster (`Ffi.feedScript`), the interrupt key's mark, and the flag raised as a key arrives while a command runs | Needs the library queue and a command running concurrently |
| A5 | The library's syntax service, whose parses come back over the library's editor queue (`Event.parsed`) and are waited for with `Ffi.syntaxSettle` | A stepped host never pulls the library queue, and a stray `parsed` would reach the next real host |
| A6 | The window mode's wiring (`Editor.Window.host` and its start-up wait) | It is the window mode's edge |
| A7 | The library's watch service on real files and real time (`Session.within`) | Background deliveries on the library's clock |

## config-test: 70 checks

By adapter: A1 8, A2 11, A3 26, A4 5, A5 17, A6 1, A7 2. Each name is a
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

### A2: 11 checks

The driver's waits over the loop thread (`Host.waitWhile`: markers and rounds, the idle signal read across the thread, an editor thread held inside an event), and the scene-count parity check that compares a stepped host with a real one.

Lists: `exScriptChecks`, `idleChecks`, `moduleHostChecks`, `scriptChecks`, `steppedChecks`.

```checks
a wait on a host whose loop a command ended answers that the loop has ended, a settle and a join alike, which is no failure of a script, and halting the host then answers that it stopped
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

### A3: 26 checks

The headless mode's script runner (`Headless.run`, `runAndDispose`, `runFrom`): the CLI's driver, defined over `Host`, which the headless fixtures share.

Lists: `exScriptChecks`, `jobChecks`, `scriptChecks`.

```checks
a script whose q is refused, for a file's buffer that was edited, runs its later lines: the show line prints the commands, the script has no failure, and the file is as it was
criterion 1 through the host: a script that runs e on a file, joins, commits text, runs w, joins, runs q, and then has a show line: the script has no failure, the file holds the committed text before what it held, and the show line was not run
criterion 2 through the host: the same script with wq in place of w, the join and q, and a join after it: the script has no failure, the file holds the buffer's text, and the show line was not run
a join that cannot finish fails at idle, it does not hang: the failure names the join's line, nothing is said as a hang, and the loop cancels its jobs when it ends
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

### A5: 17 checks

The library's syntax service, whose parses come back over the library's editor queue (`Event.parsed`) and are waited for with `Ffi.syntaxSettle`: a stepped host never pulls that queue, and a stray `parsed` would reach the next real host.

Lists: `indentChecks`, `jobChecks`, `languageChecks`, `treeObjectChecks`.

```checks
= keeps the leading whitespace of a row inside a multi-line string and inside a block comment, and re-indents the rows around them
in a Rust buffer whose indentation was mangled, g g = G gives text equal to the rustfmt-formatted fixture it came from, with the cursor on the first row's first non-blank, through the host's loop and the library's syntax tree; the rows inside its multi-line string and block comment, which the rule would indent by four spaces, keep theirs
in a Rust buffer, = a f inside the second of two mangled functions re-indents exactly that function's rows: the first function and the struct above keep their mangled indentation byte for byte
in a Rust buffer, A RET after an opening brace starts the new line one indent unit deeper than the brace's line: above a closing brace, at the text's end with none, and two deep in a method of an impl at the text's end
in a Rust buffer, one = a f is undone by one u, which gives back the whole mangled text, and . then re-indents the other function, leaving the first as u left it
in a Rust function body, o opens a row at the body's level, and typing if a { and RET there starts the next row a level deeper, though the if is not closed
in a Rust method's body, o and O on a statement start the new row at the body's level, and O on the method's closing brace does too
in a buffer with no language = = leaves the text and says the buffer has no syntax tree, and A RET, o and O insert bare line breaks as before; in a JSON buffer, whose language has no indents query, = = says so and A RET inserts a bare line break
a parse of a highlighted text the library delivers makes the real host publish a scene, with no key pressed
a major mode with no syntax tree set over the code mode of an opened .rs file detaches its text
config's language rust, over the shipped one, with its own highlights query, is the one an opened .rs file is highlighted with: its query is compiled in place of the shipped one, and its one capture drawn in its default face
opening a .json file and a .md file gives each buffer that language and the major mode code, and highlights its text with that grammar's shipped query; Markdown's inline grammar is injected
opening a .lean file and a file named lakefile.lean gives each buffer the language lean and the major mode code, and asks the syntax tree port to highlight its text with Lean's shipped query and the lean entry's captures, the faces asked for including the keyword, string, comment, constant and module faces, with no refusal said
opening a .rs file gives its buffer the language rust and the major mode code, and its text is attached with rust and highlighted with Rust's shipped query in the default faces, with no refusal said
opening a .toml file and a file named Cargo.lock gives each buffer the language toml and the major mode code, and highlights its text with TOML's shipped query, keys and table headers in the type face, strings in the string face, brackets in the punctuation face and booleans in the constant face, with no refusal said
in a Rust buffer v a f selects the enclosing function, from its fn through its closing brace, through the host's loop and the library's syntax tree; and <Escape> d a f then deletes it, its lines whole
in a Rust buffer v i f from a method's fn line, in the function and outside its body, selects inside the body's braces, its lines whole, through the host's loop and the library's syntax tree
```

### A6: 1 checks

The window mode's wiring (`Editor.Window.host` and its start-up wait).

Lists: `scriptChecks`.

```checks
the window mode's wait for its start-up config, past its patience with the reload still running, says nothing on stderr: its patience is a bound of the window's, not a hang
```

### A7: 2 checks

The library's watch service on real files and real time (`Session.within`).

Lists: `autoReloadChecks`, `gutterChecks`.

```checks
criteria 9 and 10 on real files: with auto-reload on, another process's rewrite of an unmodified buffer's file is shown within a second; once the buffer is edited, another rewrite leaves its text and marks its status line within a second
criterion 6 through the host over real git: a tracked file with a line changed shows a changed mark, and after git commit -a run by another process its gutter has no mark
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
`ContractTest/Editor/WorkingSet/Run.lean`, `ContractTest/Editor/Shell.lean`,
`ContractTest/Editor/Watch/Real.lean`), and the editor queue port's real
binding is run there as a contract (`ContractTest.queueContractChecks`), on
the check's thread.

## The package linked tests

Both run `Headless.run` (A3): `tests/packages/greeting/GreetingTest/Linked.lean`
and `packages/compile/CompileTest/Linked.lean`.

## How the list is checked

A real loop calls its collaborators' `loopStarted` on its own thread before
its first event, and a stage's host counts itself there
(`Context.realLoops`); a stepped host never calls it. `config-test ...
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
