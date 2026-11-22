# shell

A default package: the shell. `:!<command>` runs a command through
`/bin/sh -c` in the buffer's workspace root and shows its output, one line
in the echo area and more in an output buffer per workspace;
`:<range>!<command>` filters a range of the buffer through the command;
`keyboard-quit` (`C-g`) interrupts the run in flight. Each workspace keeps
the history of the lines run in it, which the ex prompt offers first, and
which is kept across a restart. Ex hands its `:!` lines to it by the names
of the interface package `shell-api`. An editor without it
runs no `:!` line, and `C-g` in normal state names nothing.

Its design record is in [packages.md](../../docs/design/packages.md),
"The default packages of the features-as-packages roadmap's phase 6".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `shell`. It requires
   the core, `editor-core`, by path (`../../lean`), declares the library
   `Shell`, the test library `ShellTest` and the test driver `shell-test`,
   and turns every Lean linter on with warnings as errors.
2. [`Shell/EditorPackage.lean`](Shell/EditorPackage.lean): the entry
   module. It imports `Shell.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Shell.package]
   ```
3. [`Shell/Compiled.lean`](Shell/Compiled.lean): the `Package` value,
   `Editor.Shell.package`, named `shell`: the three commands under
   `shell-api`'s names, the run's job and the history's store.
4. [`Shell.lean`](Shell.lean): the commands and the job, written over the
   core's editor API and its process port.

The names and the history are the interface package `shell-api`'s
(`ShellApi`, [`../shell-api/`](../shell-api/)). The
declarations keep their names, `Editor.Shell.…`, from when they were
modules of the core.

## Its tests

- **The test driver**, [`ShellTest/Model.lean`](ShellTest/Model.lean), run
  by `lake test`: the shell's model checks, in
  [`ShellTest/Shell.lean`](ShellTest/Shell.lean), on the shell's test kit,
  [`ShellTest/Kit.lean`](ShellTest/Kit.lean).
- **The linked test**, [`ShellTest/Linked.lean`](ShellTest/Linked.lean),
  run by the package steps in `mise run ffi-test`: the shell over the
  library's process service, in
  [`ShellTest/Linked/Shell.lean`](ShellTest/Linked/Shell.lean), with the
  fixture [`tests/shell/hello`](tests/shell).
- It has no headless fixture of its own.

## Dropping it

`:package-remove shell` rebuilds your editor without it; ex then says no
`:!` line can run, unless your config registers commands under
`shell-api`'s names
([installing-packages.md](../../docs/packages/installing-packages.md)).
