# tab-commands

A default package: the tab commands. `tab-new`, `tab-close`, `tab-next`,
`tab-previous`, `tab-select-1` to `tab-select-9`, `tab-switch`,
`tab-rename`, `tab-move-right` and `tab-move-left` open, close, select,
rename and move the frame's tabs, and the completion source `tabs` lists
them for `tab-switch`'s prompt. An editor without it has none of those
commands, so the Vim scheme's tab keys under `C-w` and the default
config's under `SPC TAB` run nothing; the frame still holds
tabs, the tab bar still draws them, and a restored session still restores
them ([installing-packages.md](../../docs/packages/installing-packages.md)).

Its design record is in [packages.md](../../docs/design/packages.md).

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `tab-commands`. It
   requires the core, `editor-core`, and its interface package,
   `tab-commands-api`, by path, declares the library `TabCommands`, the
   test library `TabCommandsTest` and the test driver `tab-commands-test`,
   and turns every Lean linter on with warnings as errors.
2. [`TabCommands/EditorPackage.lean`](TabCommands/EditorPackage.lean): the
   entry module. It imports `TabCommands.Compiled`, and through it
   `TabCommands`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.TabCommands.package]
   ```
3. [`TabCommands.lean`](TabCommands.lean): the commands, each over the tab
   operations of the editor API, and the completion source. Their names
   are the interface package's (`TabCommandsApi`,
   [`../tab-commands-api`](../tab-commands-api/)).
4. [`TabCommands/Compiled.lean`](TabCommands/Compiled.lean): the `Package`
   value, `Editor.TabCommands.package`, named `tab-commands`.

The tabs themselves are the core's: the frame's tabs and the operations on
them (`lean/Editor/State.lean`, `lean/Editor/Api.lean`) and the tab bar
(`lean/Editor/TabBar.lean`). The declarations keep their names
(`Editor.TabCommands.…`) from when they were modules of the core.

## Its tests

- **The test driver**, [`TabCommandsTest/Model.lean`](TabCommandsTest/Model.lean),
  run by `lake test`: `tabCommandChecks`, in
  [`TabCommandsTest/TabCommands.lean`](TabCommandsTest/TabCommands.lean),
  on the core's test kit: the commands by key, the source held to the
  completion sources' contract, and the package held to `tab-commands-api`'s
  contract.
- **End to end**: the core's headless fixture `tests/headless/tabs` runs on
  the default set's editor.

The gate runs the driver over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove tab-commands` rebuilds your editor without it; the keys
that ran its commands then run nothing
([installing-packages.md](../../docs/packages/installing-packages.md)).
