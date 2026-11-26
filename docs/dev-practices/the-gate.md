# The gate

```sh
mise run ci
```

This is everything that must pass before review and before landing. It
builds the code, runs its tests, checks its formatting and runs the
structural tools, and each step passes or fails by its command's exit
status alone (`.agents/rules/gates.md`). `hk check` runs the same task, the
pre-commit hook runs it when a staged path is one the gate reads ("The
pre-commit hook", below), and CI runs it, unchanged, on `macos-26` and on
`ubuntu-24.04` for every push and pull request ([`ci.md`](ci.md)).

The gate opens no window, makes no surface on one, reads and writes no
clipboard, and needs neither a display nor Docker: every window it runs is
the window port's fake, the scripted platform, and every clipboard the
clipboard port's fake. What needs a display, a person or a container is a
task of its own ([`on-demand-checks.md`](on-demand-checks.md)), and a
change that touches the window, the surface or the clipboard is done when
`mise run linux-window` exits 0 too.

## What `ci` runs

`ci` is its `depends`, each a task of `mise.toml`, whose comments say the
details:

- **`fmt`**: `cargo fmt --all --check`.
- **`lint`**: clippy over every crate and target with warnings denied,
  under the root `clippy.toml`'s bans, and over `tests/wait-lints/`, whose
  calls of each banned wait must each be refused ("The wait lints", below).
- **`deny`**: cargo-deny's bans over the workspace's dependency graph
  (`deny.toml`), stale wrappers errors.
- **`doc`**: rustdoc over every crate, private items included, broken
  intra-doc links denied.
- **`test`**: `cargo test --workspace`: the Rust unit, integration and doc
  tests, and the unit tests of the examples declared `test = true`.
- **`lean-test`**: the Lean model tests (`lake test`), the linters' checks
  (`lake exe lint-test`) and each package's Lake test driver over the
  fixture set ("The package steps"), all with a `cargo` that fails first
  on the PATH, so none of them needs the Rust library.
- **`lean`**: `lake build` of the core and its test executables with every
  linter on and warnings errors, which runs Cargo for the Rust static
  library; the editor and fixture harness of the default set (`packages/`)
  and of the fixture set (`tests/packages/`), each package's targets and
  linked test ("The package steps"); and the editor of the set that holds
  no package (`tests/empty-set/`).
- **`lean-fmt`**: lean-fmt's format and lint checks over the core and each
  package of the fixture set ("Formatting").
- **`ffi-test`**: cargo-deny over each set's generated crate ("The Rust
  bans check"); `ffi-test`'s checks of the Lean/Rust boundary;
  `contract-test`, the ports' contracts against their real bindings;
  `config-test`, the config session against the real elaborator; the
  display, theme and excerpt pictures; the headless fixtures under
  `tests/headless` on the default set's fixture harness, stepped on the
  fakes ([`headless-mode.md`](headless-mode.md), "How the gate runs a
  fixture"); and each package's linked test and headless fixtures ("The
  package steps").
- **`window-scenarios`**: each window scenario of `ffi-test`
  (`FfiTest.windowScenarios`), the window mode's wiring on the scripted
  platform with a real editor loop thread, a line each
  ([`real-thread-checks.md`](real-thread-checks.md), "How the set runs").
- **`c-fmt`**: clang-format's check over the tracked C and C++ sources
  ("Formatting").
- **`workflow-lint`**: actionlint and zizmor over `.github/workflows`.
  What the workflows must do beyond that is a reviewer rule
  (`.agents/rules/workflows.md`).

Two checks of the repository rather than the editor are outside `ci`:
`mise run secrets-scan`, gitleaks over `main`'s history, which CI runs as
a job of its own, and `mise run infra-check`, the offline checks of the
repository's GitHub settings ([`publishing.md`](publishing.md)).

## The package steps

`tools/package-set.sh` runs one step of the gate over every package of a
set, in the order Lake names them (`lake -d <set> query
:editorPackages`), and passes each command's exit status through, stopping
at the first that fails:

- `test`, in `lean-test`: each package's Lake test driver.
- `build`, in `lean`: the set's editor and fixture harness, then each
  package's default targets and its linked test's executable.
- `fmt`, in `lean-fmt`: lean-fmt over each package.
- `run`, in `ffi-test`: each package's linked test, in its directory, then
  the set's fixture harness over its `tests/headless/`.

The gate runs them over the fixture set, which requires the default set,
so every default package is among them; `ffi-test` then runs the default
set's fixtures on the default set's own harness (`--no-linked run`), so no
linked test runs twice. The stress loop's `linked-wiring` suite is `run
--wiring`, each linked test's wiring groups alone.

## The Rust bans check

A package's crate depends on `editor-service` and on nothing else of the
editor's. The root `deny.toml` cannot hold that (its header says why), so
`ffi-test` runs cargo-deny's bans, offline, over the crate the package-set
build generates from the fixture set and from the default set (`lake -d
<set> query :editorRustCrate`), with the `deny.toml` the build writes
beside it (`rustDenyConfig` in `lean/lakefile.lean`), and passes by
cargo-deny's exit status.

## The wait lints

Every time bound in a test is a value that says which kind it is, and a
wait takes only that type (`docs/design/concurrency.md`, "What a test may
still wait on time for"; [`inferred-waits.md`](inferred-waits.md)). What
a type cannot say is held by lints, part of the build or of `mise run
lint`:

- **Lean** (`lean/Lint/`, loaded as a plugin by every library of the core
  and of each package in this repository, so part of every `lake build`):
  `linter.rawClock` refuses a raw sleep or clock read outside
  `Editor.Bound`; `linter.inferredWait` a count, idle or first-after wait
  outside its subject modules; and `linter.realHost` a real host or
  service outside the wiring set's modules
  ([`real-thread-checks.md`](real-thread-checks.md)). Their rules are
  `LintTest`'s checks, and the `#guard_msgs` fixtures under
  `ModelTest/Lint/`, `ConfigTest/Lint/`, `ContractTest/Lint/`,
  `FfiTest/Lint/` and greeting's `GreetingTest/Lint/` hold the errors.
  That every target loads the plugin is a reviewer rule
  (`.agents/rules/structure.md`, "Lint plugins").
- **Rust** (`mise run lint`): the root `clippy.toml` bans the raw timed
  primitives, the readout waits and the outside world a core reaches only
  through its ports; `editor-wait`'s types take their place. An opt-out is
  an `#[expect]` with a reason at its site (`.agents/rules/structure.md`,
  "Clippy's bans"), and clippy over `tests/wait-lints/` holds each wait
  ban to refusing its call.

## The pre-commit hook

```sh
hk run pre-commit
```

The pre-commit hook and `hk check` (`hk.pkl`) have one step, `mise_ci`,
which runs `mise run ci` when any staged path matches its glob, and passes
or fails by its exit status. The glob is every file the gate reads; a
commit that stages only other files (the rest of `docs/`, `README.md`,
`.agents/`, `infra/`) runs no step. Faster selection from the build graphs,
by a tool, is rdm task `build-graph-test-selection-tool`.

## Formatting

```sh
mise run lean-format   # Lean, with lean-fmt
mise run c-format      # C, with clang-format (.clang-format)
cargo fmt --all        # Rust
```

`mise run c-format` and its check, `mise run c-fmt`, look at tracked files
only, so `git add` a new C file before running them. They leave `vendor/`
out: vendored C is upstream's generated code (`vendor/README.md`).

`mise run lean-format` and its check, `mise run lean-fmt`, run lean-fmt
over the core and then over each package of the fixture set
(`tools/package-set.sh format`, `fmt`), its workers sized to the machine's
memory (`tools/lean-fmt-workers.sh`).

- **lean-fmt is required by a package of its own, its host**
  (`tools/lean-fmt/lakefile.toml`), not by the core: a package set that
  requires the core would fetch every git dependency of the core
  ([packages.md](../design/packages.md), "Manifests: a set's build fetches
  nothing"). The tasks run it as `lake -d ../tools/lean-fmt exe lean-fmt …
  --root <package>` in `lean/`, `.` for the core.
- **The clone stays under `lean/.lake/packages`** (the host's
  `packagesDir`). Its pin is the host's `lake-manifest.json`; to bump it,
  change `rev` in the host's lakefile with `lean/lean-toolchain` and run
  `lake -d ../tools/lean-fmt update --keep-toolchain` in `lean/`.
- **It writes a cache in the root it is given**, `.lean-fmt-cache`, which
  git ignores, and it refuses a root with no `lean-toolchain`, which is one
  reason every package holds a link to the pin.
- **A package's headless fixtures are excluded** by a `lean-fmt.toml` in
  the package (`exclude = ["tests/**"]`): a config file is a module of a
  config directory, another Lake package.

## On demand

What the gate does not run, and when to run it, is in
[`on-demand-checks.md`](on-demand-checks.md).
