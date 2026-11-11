# editor

An Emacs-style editor written in Lean 4. Lean owns the process and is the
editor: its state, the command loop, commands, modes, keymaps and config. A
Rust library, linked into the Lean executable, provides text storage, layout,
rendering, the window, and process and terminal management.

- [`docs/design/`](docs/design/README.md) says what is being built and why.
- [`AGENTS.md`](AGENTS.md) holds the working rules: test-first, ports and
  adapters, hand-written fakes, hermetic tests.

The editor does nothing useful yet. The executable shows that the build
works: Lean calls the Rust library and prints what comes back.

## Building

The build runs on macOS only for now.

### Prerequisites

- [mise](https://mise.jdx.dev), which installs the tools `mise.toml` pins
  (Rust, cargo-deny, hk, pkl, clang-format) and runs every task below. Run
  `mise install` once in the checkout.
- `uv` or `pipx`. mise uses one of them to install clang-format, and
  `mise.toml` does not pin either.
- Lean, at exactly the version in `lean/lean-toolchain`, with `lean` and
  `lake` on the `PATH`. `mise install` does not provide it.
  [elan](https://github.com/leanprover/elan) reads that file and does.
- The Xcode command line tools, for `/usr/bin/cc`.
- Network access for the first build, when Lake fetches lean-fmt.

### Build and run

```sh
mise run lean
```

This one command builds everything. Lake compiles the Lean package, runs
`cargo build` for the Rust static library (`crates/editor-ffi`), compiles the
C glue (`lean/ffi/glue.c`) and links the executables. Every Lean linter is
on, and a warning fails the build.

The editor is `lean/.lake/build/bin/editor`:

```console
$ lean/.lake/build/bin/editor
Rust says 2 + 3 = 5
Lean's main is on the process's main thread: false
The main-thread service is on the process's main thread: true
```

Lake relinks the executables only when the Rust archive's contents change,
so a second `mise run lean` does nothing.

Use `mise run lean`, not a bare `lake build`. On macOS the executables have
to be compiled and linked by the system compiler, and the task sets
`LEAN_CC=/usr/bin/cc` to say so: the clang bundled with Lean has no
`pthread.h` for the glue, and its linker cannot link the system frameworks a
window needs. Do not export `LEAN_CC` in your shell. lean-fmt has to build
with Lean's bundled compiler, and under `/usr/bin/cc` its link fails with
`library 'gmp' not found`.

The executables also do not start at Lean's `main`. Lean runs `main` on a
thread it creates, never on the process's main thread, and macOS only lets a
window event loop run there. So the link names `editor_entry` in the glue as
the entry point. It keeps the real main thread for the Rust library and runs
Lean's `main` on a second thread with a large stack.

### The gate

```sh
mise run ci
```

This is everything that must pass before review and before landing: Rust
formatting, clippy, cargo-deny, rustdoc and the Rust tests; the Lean build,
lean-fmt's format and lint checks; the checks of the Lean/Rust boundary
(`mise run ffi-test`); and the C format check. `hk check` runs the same task.

The Rust half needs no Lean toolchain: `mise run test` (`cargo test
--workspace`) builds and tests every crate with Cargo alone.

`mise run ffi-test` runs `lean/.lake/build/bin/ffi-test`, the test executable
linked against the real library, and then the editor. With no arguments
`ffi-test` runs its checks of handles, plain data and the event queues. Four
scenarios need a process each:

| Command | Shows |
|---|---|
| `ffi-test exit 7` | The entry point passes arguments to Lean's `main` and its result is the exit status. |
| `ffi-test shutdown` | Quitting the queues wakes every task blocked in a pull, and the process then exits. |
| `ffi-test exit-while-blocked` | An explicit exit ends the process although a task is still blocked in the library. |
| `ffi-test overflow <sysroot> <olean dir>` | A stack overflow in interpreted code is not caught: the process aborts. |

The last one is meant to crash. The task requires it to die of SIGABRT after
it has printed the line that says it is entering the recursion, and no core
file is written. On macOS the system still writes a crash report for
`ffi-test` under `~/Library/Logs/DiagnosticReports` on every run; that
report is this scenario, not a failure.

The conventions every binding follows, and the test that pins each, are in
the crate docs of `crates/editor-ffi/src/lib.rs` and the module docs of
`lean/Editor/Ffi.lean`.

### Formatting

```sh
mise run lean-format   # Lean, with lean-fmt
mise run c-format      # C, with clang-format (.clang-format)
cargo fmt --all        # Rust
```

`mise run c-format` and its check, `mise run c-fmt`, look at tracked files
only, so `git add` a new C file before running them.

## Licence

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
