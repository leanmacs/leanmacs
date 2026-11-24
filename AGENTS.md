# AGENTS.md

How to work in this repository: the development practices every change
follows. What is being built, how it is structured and why is in
`docs/design/` (start at `docs/design/README.md`); read the documents for
the area you are changing before you change it, and record a new fact
about the system there, not here. How to build, run and check the code, and
what must pass before a change lands, is in `docs/dev-practices/`.

## Test-driven development

Write all code test-first:

1. **Red**: write a failing test for the next small piece of behaviour. Run it
   and confirm it fails for the reason you expect.
2. **Green**: write the minimum code that makes the test pass.
3. **Refactor**: clean up the test and the implementation while the suite stays green.

- Write production code only in response to a failing test.
- Start every bug fix with a test that reproduces the bug.
- Keep tests fast and deterministic. Build test inputs from small fixture data
  checked into the repo, or construct them in code.

## Architecture: ports and adapters

Structure the code as ports and adapters (hexagonal architecture):

The pattern applies in both languages. In Rust, ports are traits. In Lean,
ports are interfaces, each with its real implementation and a pure model.
The rules in this section are written for Rust and hold for Lean with
"trait" read as "interface". Which components exist, where each boundary
falls and what may cross it are in `docs/design/overview.md`.

- **Core logic** is plain code that talks to the outside world only through
  ports.
- **Ports** are traits that the core defines. Each one describes a capability
  the core needs, in the core's own terms (e.g. "read the bytes of a file",
  "shape this run of text", "run this command"), not in terms of a specific
  technology.
- **Adapters** are concrete implementations of ports that touch real things:
  the filesystem, the clock, processes, fonts, the GPU, the window system.
  Keep adapters thin; put decisions in the core.

When building a component:

1. Define the port traits for the collaborators it needs.
2. Take those collaborators as generics (`impl Trait`, `T: Trait`) or
   `&dyn Trait`, supplied by the caller.
3. Wire real adapters together at the edge of the program (`main`, or a
   top-level constructor).

When a UI drives core logic, it reaches it through a port the UI defines,
small enough to fake by hand:

- Grow the port with data, not methods: a new readout is a field of the frame
  the port fills, a new action a command variant, a new one-shot output an
  event variant, and a question a view asks a variant of the view's query.
  Don't add a method per question.
- Keep each adapter forward to one call into the core. The decisions live in
  the core and are pinned by the core's tests.
- Test the UI's components on the hand-written fake. Run the few integration
  tests over the real core only where the port's module docs say.
- The port's module docs say where each kind of addition goes and where it is
  pinned.

### Prefer an existing library, behind a port

Where a library exists for a job, use it, even if it is young or still
changing, and keep it behind a port so no type of it appears outside its
adapter crate. Pin its exact version. Write our own implementation only
when no library fits or a measured problem requires it, and record why.

## Testing with hand-written mocks

- Test core logic through its ports. In each test module, write small mocks or
  fakes that implement the port traits. Mocks return canned data and, when the
  interaction matters, record the calls they receive so the test can assert on them.
- Test each component on its own, with mocks standing in for its collaborators.
  When a component is hard to test this way, add a port at that boundary.
- Test each real adapter on its own against the behaviour that the port's mocks
  assume. The crate that owns a port publishes its fake and a contract check,
  and every real adapter runs that check; don't write another crate's fake.
- Cover wiring with a small number of integration tests under `tests/`.
- A port with a pure model gets one contract check: the same properties run
  against the model and against the real implementation, so the model cannot
  drift. Test the logic above the port against the model alone.
- Keep a module's tests beside it. In Rust, put them in the module's
  `#[cfg(test)] mod tests`, or in `<module>/tests.rs` once that outgrows the
  file. In Lean, which has no test-only code, put a module's tests in a test
  module that mirrors its path under the test executable's root (the tests of
  `Editor/State.lean` in `ModelTest/Editor/State.lean`), and have that root
  only import its test modules and run their checks.
- Add a new Lean check to the test module that mirrors the module it tests,
  never to a test executable's root (`ModelTest.lean`, `FfiTest.lean`,
  `ConfigTest.lean`, `ContractTest.lean`). If that test module does not exist
  yet, create it, import it from the root and add its check list to the root's
  aggregator, keeping any order the root documents. A helper a second test
  module needs goes in `<Root>/Support/`; one with a single user stays in its
  module. When you move a check list, keep its `<Root>.<name>Checks` name, since
  docs cite tests by it.
- Split a Rust example or test program that collects several concerns the same
  way: a directory example (`examples/<name>/main.rs` holding the wiring, plus a
  module per concern with its own `#[cfg(test)] mod tests`), as
  `editor-platform-winit`'s `contract` and `editor-ffi`'s `window` examples do.

## Crate coupling

Keep crates loose enough that a change to one breaks no other crate's tests.

- A test asserts only its own crate's rules. Don't pin a rule, constant,
  default or timing an upstream crate owns; that crate's tests pin it.
- Reach upstream state through the builders and fakes the upstream crate
  publishes for tests, not by driving its real behaviour until it gets there.
- Don't match exhaustively on an upstream enum that grows. Have the owning
  crate supply what each variant needs, as data on the enum. Keep an
  exhaustive match only where the downstream crate must act on every
  variant, and say so in its doc comment.
- A test that runs a real upstream crate covers wiring only. It lives in the
  crate that wires the program together, or where a port's module docs place
  it.

## Test behaviour, never text

Don't write tests that scan source files or built binaries for particular
strings, such as a test that greps `src/` for a call or checks a binary for a
symbol name. They break on changes that don't matter, and what they show is
weak.

- Test what the code does, through its ports.
- Check dependency rules (which crates a build may pull in) with
  `cargo-deny`'s `bans` in `deny.toml`, which reads Cargo's resolved graph.

## Gates pass by exit status, never by their output

A gate step (anything `mise run ci`, a CI workflow or a hook runs) passes when
its command exits 0 and fails when it exits non-zero. It never decides by
reading what a command printed.

- Don't grep, diff, count or match a command's output to decide pass or fail:
  no `grep -q` for an expected line, no pinned count line ("ran 12 linked
  tests"), no ledger of printed lines checked afterwards. Output is for
  people reading a log.
- A program that checks something exits non-zero when the check fails. If a
  property is worth gating, the program that knows it asserts it and sets its
  exit status.
- Make "it ran" a matter of structure, not of a report: one driver runs a set
  it reads from code, so an item can't be skipped or run twice, instead of
  each runner printing that it ran and a script counting the lines.
- Comparing a program's output with a checked-in expected file is a test of
  that program, and the comparison runs inside a test that exits non-zero on
  a difference, not as a shell pipeline in the gate.
- Prefer a gap in coverage to a fragile gate. Remove a text-matching gate
  step rather than keep it, and cover what it checked with a real test later.

## Hermetic tests

Every test runs anywhere with only `cargo` (or `lake` for Lean tests), in any
order, in parallel, and leaves the developer's machine exactly as it found it.

- Reach the filesystem, environment variables, the clock and other processes
  through ports, so unit tests use mocks instead of the real thing.
- When an adapter test needs real files, create them in a fresh temporary
  directory owned by that test, and pass the path in explicitly. Keep the
  working directory, `$HOME`, environment variables, and the project's own git
  repository untouched.
- Set up any state a test needs inside the test itself, so it passes on a clean
  checkout.

## Deterministic concurrency in tests

A test's result never depends on how threads are scheduled or how fast the
machine is. A test that passes on an idle laptop and fails on a loaded CI
runner is a bug in the test or in the code, and it is fixed, never retried
or given a longer timeout. Threads, queues and the clock are described in
`docs/design/concurrency.md`.

- Test logic that runs across threads through a port, with a fake that
  runs the work on the test's own thread, or that the test steps. Do this for
  the editor loop, jobs and timers (the fake clock), and for the file, process
  and watch services. Use real threads only in an adapter's contract check
  or in a check of the wiring set (below).
- Run a real editor loop thread or a real background service only in a
  check of a module of the wiring set: one that declares
  `def wiringSet.<module> : WiringSet`, naming the real adapter its checks
  cover and why a fake or the stepped host cannot stand in.
  `docs/dev-practices/real-thread-checks.md` says where such a module goes.
  `lake build`'s linter refuses a call of a marked real host or service
  (`<name>.realHost`) anywhere else, and a public helper that hands one on
  unmarked.
- Wait for an event, never for time. Wait on what signals that the work is
  done: a task or promise to `IO.wait` on, a channel, a joined thread, or a
  barrier that a service's queue reaches only after all the work queued before
  it. Never use `IO.sleep`, `thread::sleep` or a poll with a deadline to let
  work finish.
- Give an API that starts background work something to wait on: a task, a
  promise or a flush. The caller may drop it on purpose; a test does not.
- Tie each thread, loop and queued piece of work to a scope, such as a bracket
  or an owner whose `Drop` joins it, that ends only once the work has ended.
  Something a test creates does not outlive the test: its loop has stopped,
  its queues have drained, and nothing still writes into the directory being
  removed.
- Check that something does not happen once the system is idle, meaning its
  queues are empty and nothing can run. A deadline does not show it. Where no
  idle signal exists yet, add one.
- A timeout is only a guard against a hang. When it runs out, the test reports
  a hang. It is not a result, and the test does not pass or fail on time.
- A time bound in a test is a value that says which kind it is:
  `HangGuard.on <event> <ms>`, `HangGuard.held <what is held for good> <ms>`
  or `RealTime.under <timing> <ms>` in Lean, and `HangGuard::on`,
  `HangGuard::held` or `RealTime::under` of `editor-wait` in Rust. A wait
  takes only those, so a bare number does not compile; a raw sleep or clock
  read is refused by `lake build`'s `linter.rawClock` and by `mise run lint`.
- A count or idle wait, or a "first X after Y" wait (marked with a
  `<constant>.inferredWait`), is callable only from its subject modules;
  `lake build` refuses one elsewhere (`docs/dev-practices/inferred-waits.md`).
- Pin results that do not depend on scheduling. Check the final state, or
  what was published last, and not how many times something happened when
  that count changes with timing.
- To show a race is fixed, write a test that forces the bad interleaving
  every time (a gate, a held call or a fake clock), so it fails on the old
  code. A stress loop under load backs that test up but cannot replace it.

## Iterate and dogfood

Automated tests are the evidence that work is done, and every phase and
task finishes on them. Beyond that, the owner uses the editor day to day
and reports what breaks; each report becomes a failing test, then a fix.
When something new is ready to try, make it one command to install and
say in a line what changed.

## Toolchains

- Rust: stable, edition 2024.
- Lean: pinned in `lean/lean-toolchain`. Lean's C ABI, Lake's build API and
  the `.olean` format change between releases, so bump it deliberately, in
  its own commit, and fix the bindings and the build in the same commit.

## Conventional commits

Format every commit message as a [Conventional Commit](https://www.conventionalcommits.org/en/v1.0.0/):
`<type>(<optional scope>): <imperative summary>`, with types `feat`, `fix`,
`refactor`, `test`, `docs`, `chore`, `build`, `ci`, `perf`, `style`. The scope
is usually the crate name, or `lean` for the Lean package.

## Landing work on `main`

Linear history on `main` is not required. This is a standing rule and
overrides the `rdm:land` skill's rebase-and-fast-forward default.

- `rdm:land` may land a reviewed branch with a merge commit when a rebase
  would be more work, for example a long-lived roadmap branch that has
  already merged `main` into itself.
- A roadmap branch may merge `main` into itself to pick up landed work.
- Everything else about landing still holds: only reviewed work lands, the
  worktree is clean, and the checks in `docs/dev-practices/` pass on the
  merged result before `main` moves. Never force-push `main`.
