# execute-command

A default package: the command prompt. `execute-command` asks
`Command: ` for the name of a registered command, each candidate shown
with the keys that reach it, and runs the one accepted as a step of its
own, as Emacs's `M-x` does. The default config binds it to `SPC :`.

It implements the interface package
[`execute-command-api`](../execute-command-api/), which declares the name
it is registered under. Its design record is in
[packages.md](../../docs/design/packages.md), "The default packages of
the features-as-packages roadmap's phase 3".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `execute-command`.
   It requires the core, `editor-core`, by path (`../../lean`), and the
   interface package `execute-command-api` (`../execute-command-api`),
   declares the library `ExecuteCommand`, the test library
   `ExecuteCommandTest` and the test driver `execute-command-test`, and
   turns every Lean linter on with warnings as errors.
2. [`ExecuteCommand/EditorPackage.lean`](ExecuteCommand/EditorPackage.lean):
   the entry module. It imports `ExecuteCommand.Compiled`, and so the
   whole library, which is what config sees of the package.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.ExecuteCommand.package]
   ```
3. [`ExecuteCommand/Compiled.lean`](ExecuteCommand/Compiled.lean): the
   `Package` value, `Editor.ExecuteCommand.package`, named
   `execute-command`. Its `setup` registers the command with
   `commandWith` and its completion source, `commands`, with
   `defineSource`.
4. [`ExecuteCommand.lean`](ExecuteCommand.lean): the command
   (`executeCommand`), its source of the registered commands' names
   annotated with their keys (`source`, `annotation`), and how an answer is
   resolved (`resolve`). The name it registers under, `name`, is
   `ExecuteCommandApi.executeCommandName`.

Every declaration is in the namespace `Editor.ExecuteCommand`, where it was
in the core, so config names them as `ExecuteCommand.executeCommand` under
`open Editor`, with `import ExecuteCommand`. The library imports the
core's API alone, and the interface package.

## Its tests

- **The test driver**, [`ExecuteCommandTest/Model.lean`](ExecuteCommandTest/Model.lean),
  run by `lake test`: `executeCommandChecks`, in
  [`ExecuteCommandTest/ExecuteCommand.lean`](ExecuteCommandTest/ExecuteCommand.lean),
  on the core's test kit, and `executeCommandPackageChecks`, in
  [`ExecuteCommandTest/ExecuteCommand/Compiled.lean`](ExecuteCommandTest/ExecuteCommand/Compiled.lean),
  the interface's contract check over the `Package` value.
- **The headless fixture**, [`tests/headless/command-prompt`](tests/headless/command-prompt/):
  config's commands listed under its own style with their keys,
  `load-theme` run through the prompt, and a config command that names
  `ExecuteCommand.label`. It was written on the editor with the command
  prompt still in the core and moved here with one line changed, its
  config's import.

The gate runs both over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove execute-command` rebuilds your editor without it;
`SPC :` then runs a name no package registers
([installing-packages.md](../../docs/packages/installing-packages.md)).
