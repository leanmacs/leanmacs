# Building: what the build does and why

The prerequisites and the one command are in the top-level
[`README.md`](../../README.md). This is what that command does.

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
A command appended to a text held by Rust: héllo wörld
```

The last line is a command, `Editor.append`, run against the Rust library.
The model tests run the same source against a pure Lean model.

The executable is about 180 MB on macOS and 265 MB on Linux: it can
elaborate config, so Lean's elaborator is linked into it.

### The headless mode

Lake relinks the executables only when the Rust archive's contents change,
so a second `mise run lean` rebuilds nothing.

`mise run lean` runs the model tests first (`mise run lean-test`;
[`the-gate.md`](the-gate.md)).
That is only so that two Lake builds never run in `lean/` at once: the tasks
that run Lake form one chain.

Use `mise run lean`, not a bare `lake build`. On both platforms the
executables have to be compiled and linked by the system compiler, and the
task sets `LEAN_CC=/usr/bin/cc` to say so: the clang bundled with Lean has no
`pthread.h` for the glue, on macOS or on Linux, and on macOS its linker
cannot link the system frameworks the window needs. Do not export `LEAN_CC`
in your shell. lean-fmt has to build with Lean's bundled compiler, and on
macOS under `/usr/bin/cc` its link fails with `library 'gmp' not found`.

The executables also do not start at Lean's `main`. Lean runs `main` on a
thread it creates, never on the process's main thread, and macOS only lets a
window event loop run there. So `editor_entry` in the glue runs in its place.
It keeps the real main thread for the Rust library and runs Lean's `main` on
a second thread with a large stack. On macOS the link names it as the entry
point (`-Wl,-e,_editor_entry`). On Linux that would skip the C library's
start-up, so the link renames instead (`-Wl,--wrap=main`): the start-up code
calls the glue's `__wrap_main`, and Lean's `main` is reached as
`__real_main`.
