# The wiring set: checks that run a real loop thread or a real service

Most host checks run on a host stepped on the check's own thread
(`Headless.withStepped`, `lean/Editor/Headless/Stepped.lean`) over the
stage's fakes, which answer only on the check's step
([concurrency.md](../design/concurrency.md), "Stepped hosts in tests" and
"Recording fakes for the host's background collaborators"). The checks that
still run a real editor loop thread or a real background service are the
wiring set: each lives in a module that declares itself one, and
`lake build` refuses one anywhere else.

## The rule

A check runs a real editor loop thread, or a real background service (the
completion pump, the library's timer, file, process, watch, diff, grep or
syntax service, or the session journal over them), only in a module of the
wiring set. Such a check asserts the wiring alone: that the real adapter is
reached and answers. Every ordering property it touches is pinned by a
theorem (`lean/Editor/Job/Protocol/Theorems.lean`) or by a forced test on a
fake or the stepped host, cited beside it in the module's doc
(`AGENTS.md`, "Deterministic concurrency in tests").

## The marks and the declaration

Both are plain data, in the editor's own modules (`lean/Editor/RealHost.lean`),
read by name, as the inferred waits' marks are
([inferred-waits.md](inferred-waits.md)):

- **The mark.** An entry point that starts a real host or service has a
  declaration `<constant>.realHost : RealHost` before it, `.loop` (a real
  editor loop thread, which may reach real services too) or `.service` (a
  real background service and no loop thread). The production entry points
  are marked by hand (`Headless.withHost`, `withHostEnding`, `Hosting.real`,
  `run`, `runFrom`, `runAndDispose`, `main`, `shipped`; `Window.host`;
  `Main.run`; `Job.realTimers` and the other real services, `Job.pump`;
  `Headless.Journal.real`; `RealSyntaxTree.new`), and so are the test kits'
  real helpers (`withRealHost`, `onRealStage`, `Stage.overFiles`,
  `Services.start`, `withRealSyntaxHost`, ...).
- **The declaration.** A module of the wiring set declares
  `def wiringSet.<module> : Editor.WiringSet`: `.wiring "<adapter>" "<why>"`
  for wiring checks, `.contract "<port>"` for a port's contract against its
  real adapter (services, never a loop), `.edge "<why>"` for an
  executable's root, whose `main` alone starts services or runs scenarios.
  The declaration is under the root namespace `wiringSet`, so it makes no
  namespace of the module's own name.

`linter.realHost` (`lean/Lint/RealHost.lean`), loaded with the wait linters
as the build's plugin, reads the info trees of each command: a reference to
a marked constant in a test module (one whose root ends in `Test`, or the
core's kits under `Editor.Test`) is refused unless the module declares
`.wiring`, or `.contract` for a service, or `.edge` inside `main`, or the
reference is inside a declaration that has a mark itself. A private wrapper
launders nothing, and a public helper of a wiring module that hands a mark
on must be marked, `main` or a check. Its fixtures are
`ConfigTest/Lint/RealHost.lean`, the greeting package's
`GreetingTest/Linked/Lint/RealHost.lean` and model-test's `ModelTest/Lint/RealHost.lean`
and `ModelTest/Lint/RealHost/`.

## Where a module of the wiring set goes

1. **The real adapter has a module of its own:** its wiring checks go in the
   test module that mirrors it, as AGENTS.md's mirror rule says.
2. **A mirror module whose every remaining check is a wiring check**
   declares itself in place.
3. **The real adapter has no module of its own** (the real loop lives in
   `Editor/Headless.lean` beside everything the stepped checks test, and a
   package's checks run the core's adapters through its commands): the
   wiring checks go beside the mirror of the module they test, in
   `<mirror>/Real.lean`, or `<mirror>/Real/<Subject>.lean` when the subjects
   are several. The mirror itself keeps the stepped checks. The wait
   linter counts such a module as the mirror only when it declares
   `.wiring` (`Lint.wiresBeside`, over the declaration `declaredHere?`
   reads, `lean/Lint/Marks.lean`, as this linter does): a module of that
   name that declares nothing, a `.contract` or an `.edge` is no mirror, so
   its name alone grants no inferred wait.

## The wiring set, by module and reason

| Module | Declares | The real adapter, and why |
|---|---|---|
| `lean/ConfigTest/Editor/Headless/Real/Bracket.lean` | `.wiring` | The editor loop thread and its join (`Headless.withHost`, `withHostEnding`): the thread and its join are the subject, and a stepped host has no thread to join. |
| `lean/ConfigTest/Editor/Headless/Real/Waits.lean` | `.wiring` | The driver's waits across the loop thread: the idle signal read from another thread and an unanswering editor thread exist only on a real one; and the parity of a stepped host's scenes with a real one's. |
| `lean/ConfigTest/Editor/Headless/Real/Runner.lean` | `.wiring` | The headless CLI's runner over a real loop (`Headless.run`, `runAndDispose`, `Hosting.real`): its logic is pinned stepped, its real hosting and dispose after the join are what the CLI runs. |
| `lean/ConfigTest/Editor/Headless/Queue/Real.lean` | `.wiring` | The library's editor queue and its interrupt flag: a stepped host never pulls it. |
| `lean/ConfigTest/Editor/SyntaxTree/Real.lean` | `.wiring` | The library's syntax service, whose parses come back over the library's queue. |
| `lean/ConfigTest/Editor/Indent.lean` | `.wiring` | The shipped Rust `indents` query over the real syntax service: the syntax model holds JSON alone. |
| `lean/ConfigTest/Editor/Window/Real.lean` | `.wiring` | The window mode's start-up wait on a real host: its edge. |
| `lean/ConfigTest/Editor/Job/Real.lean` | `.wiring` | The library's diff and grep services, each end to end, reached by a host's job. |
| `lean/FfiTest/Editor/Window/Real.lean` | `.wiring` | `Editor.Window.host` on the scripted platform: the window mode's wiring, its restart's exec and real timers. |
| `lean/Editor/Test/Fixture/RealThread.lean` | `.wiring` | The headless CLI over a real loop thread, whose runs happen in gate steps a Lean linter cannot see. |
| `packages/evil/EvilTest/Linked/Evil/Operators.lean`, `.../Evil/TreeObjects.lean` | `.wiring` | The shipped Rust `indents` and `textObjects` queries through the Vim scheme's keys, which the syntax model does not hold. |
| `packages/files/FilesTest/Linked/Files/Real.lean` | `.wiring` | The library's file, watch and syntax services through the files package's commands, each end to end. |
| `packages/compile/CompileTest/Linked/Compile/Real.lean` | `.wiring` | The library's process service through the compile mode: a child's streamed lines and its exit status. |
| `packages/version-control/VersionControlTest/Linked/VersionControl/Git.lean`, `packages/workspace/WorkspaceTest/Linked/Workspace/Contract.lean`, `.../Workspace/Lister.lean`, `tests/packages/echo/EchoTest/Linked/Echo/Real.lean` | `.contract` | A port's contract against its real adapter, which the module's root hands it. |
| The roots `lean/ConfigTest.lean`, `lean/FfiTest.lean` and the linked roots of compile, version-control, workspace, files and echo | `.edge` | Their `main` starts the process's services and pump, or runs the benches or scenarios, and hands them to the modules above. |

The modules a root hands real services by value (`services.jobs`) are
declared `.wiring` or `.contract`, so the value's flow is visible at both
ends: the linter confines construction and reference, not values.

## Outside the rule

- `contract-test` (`lean/ContractTest/`): every module under `ContractTest`
  is a contract root, which may reach a real service and never a real loop.
- The `.contract` modules above, for the same reason.
- The Rust crates' tests, which exercise the real adapters by design.
- FfiTest's binding checks, which reach the raw `Editor.Ffi` bindings, the
  adapters' own surface, and start no loop or service through a mark.

## The CLI's runs in the gate

The headless fixtures run stepped by default (`fixture-test`;
[headless-mode.md](headless-mode.md), "How the gate runs a fixture"). Those
that keep running the CLI over a real loop thread are declared once, each
with what it covers and the gate step that runs it, in
`Editor.Test.Fixture.RealThread`, a module of the wiring set: the runner's
are compared both ways (`tools/fixture-compare.sh`), and the others' subject
is a real effect, the journal's write, abort, restart and recovery among
them (`restore/abort-script` then `restore-script`). The user-sets and
bundle-sets restarts (W68, W69) run the real editor in their gate steps too.

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
