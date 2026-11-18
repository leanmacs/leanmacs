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
