# login-shell

A default package: the login shell as the base of a child's environment.
In the window mode, every child the editor starts gets the variables your
login shell sets (its `PATH` first among them), so a tool installed outside
mise, such as Homebrew's, is found even when the editor was started from
Finder, whose own `PATH` is launchd's `/usr/bin:/bin:/usr/sbin:/sbin`. A
directory source (mise) is layered over it, and a child's own variables
over both.

- **Which shell**: `SHELL` from the editor's environment, else your login
  shell from the system's user record (`id -P`), else `/bin/zsh`.
- **How**: `<shell> -l -c '…'` in your home directory, a login shell that
  is not interactive (an interactive shell expects a terminal). The command
  prints the environment NUL-separated between two markers, so whatever
  your rc files print around it is ignored. Every variable is kept but the
  shell's own `PWD`, `OLDPWD`, `SHLVL` and `_`.
- **When**: once per run, the first time a child is started, and again
  after a reload of config.
- **If it fails** (no shell, a status other than 0, no markers in what it
  printed, more than 5 s): children get the editor's own environment, and
  the echo area says why, once per run.
- **The headless mode** looks nothing up, so the headless fixtures and the
  tests never run your shell.

Its design record is in
[packages.md](../../docs/design/packages.md), "The core interface library
`environment-api`", and the layers it joins in
[concurrency.md](../../docs/design/concurrency.md), "A child's environment,
as built".

## Its setting

```lean
def setup : SetupM Unit := do
  LoginShell.timeLimit 10000
```

lets the login shell run for 10 s, in place of 5 s. `0` is refused, and so
is calling it twice.

## Opting out

```lean
def setup : SetupM Unit := do
  environmentBase "inherited"
```

chooses the core's base, the editor's own environment, over this package's
default. `:package-remove login-shell` does the same by leaving the package
out ([installing-packages.md](../../docs/packages/installing-packages.md)).

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `login-shell`. It
   requires the core, `editor-core`, by path (`../../lean`), whose Lake
   package holds the interface library it implements, `EnvironmentApi`;
   declares the library `LoginShell`, the test library `LoginShellTest` and
   the test driver `login-shell-test`; and turns every Lean linter on with
   warnings as errors.
2. [`LoginShell/EditorPackage.lean`](LoginShell/EditorPackage.lean): the
   entry module. It imports `LoginShell.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[LoginShell.package]
   ```
3. [`LoginShell/Compiled.lean`](LoginShell/Compiled.lean): the `Package`
   value, `LoginShell.package`, named `login-shell`: it registers
   `LoginShell.baseSource` at `EnvironmentApi.BaseSource` and chooses it as
   the default base with `environmentBase "login-shell"`.
4. [`LoginShell.lean`](LoginShell.lean): the source as data (the probes
   that find the shell, the lookup's command, the parser of what it
   prints), the value the package registers, and the setting,
   `LoginShell.timeLimit`.

## Its tests

- **The test driver**, [`LoginShellTest/Model.lean`](LoginShellTest/Model.lean),
  run by `lake test`: the registration, the setting, the command, the
  probes and the parser, `environment-api`'s base contract on the model
  rig, and a child's environment over the login shell on the job model,
  failures among it, in [`LoginShellTest/LoginShell.lean`](LoginShellTest/LoginShell.lean).
- **The linked test**, [`LoginShellTest/Linked.lean`](LoginShellTest/Linked.lean),
  run by the package steps in `mise run ffi-test`: `environment-api`'s base
  contract over the library's process service, in
  [`LoginShellTest/Linked/LoginShell/Contract.lean`](LoginShellTest/Linked/LoginShell/Contract.lean),
  and the one wiring check of a real child under the login shell and a
  directory source, in
  [`LoginShellTest/Linked/LoginShell/Real.lean`](LoginShellTest/Linked/LoginShell/Real.lean),
  with the fixtures under [`tests/login-shell`](tests/login-shell) standing
  in for a login shell and for mise. No test runs your own shell.
- It has no headless fixture of its own: the default set's standing fixture
  `tests/headless/environment-sources` says the base it chooses.
