# window-commands

A default package: the window commands. `window-split`, `window-close`,
`window-only`, `window-focus-left` and the rest (thirty-three in all)
split, close, focus and arrange the frame's windows, with Vim 9.1's
behaviour. An editor without it has none of those commands, so the Vim
scheme's window keys under `C-w` and the default config's under `SPC w`
run nothing; the frame still lays its windows out, files and buffers still
open in the window they are asked for in, and a restored session still
restores its windows
([installing-packages.md](../../docs/packages/installing-packages.md)).

Its design record is in [packages.md](../../docs/design/packages.md).

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `window-commands`.
   It requires the core, `editor-core`, and its interface package,
   `window-commands-api`, by path, declares the library `WindowCommands`,
   the test library `WindowCommandsTest` and the test driver
   `window-commands-test`, and turns every Lean linter on with warnings as
   errors.
2. [`WindowCommands/EditorPackage.lean`](WindowCommands/EditorPackage.lean):
   the entry module. It imports `WindowCommands.Compiled`, and through it
   `WindowCommands`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.WindowCommands.package]
   ```
3. [`WindowCommands.lean`](WindowCommands.lean): the commands, each over
   the window operations of the editor API. Their names are the interface
   package's (`WindowCommandsApi`,
   [`../window-commands-api`](../window-commands-api/)).
4. [`WindowCommands/Compiled.lean`](WindowCommands/Compiled.lean): the
   `Package` value, `Editor.WindowCommands.package`, named
   `window-commands`.

The windows themselves are the core's: the frame, its layouts and the
operations on them (`lean/Editor/State.lean`, `lean/Editor/Layout.lean`,
`lean/Editor/Api.lean`). `window-quit` on the last window runs the command
named `quit`, a name the core declares (`lean/Editor/Quit.lean`) and the
package `ex` registers. The declarations keep their names
(`Editor.WindowCommands.…`) from when they were modules of the core.

## Its tests

- **The test driver**, [`WindowCommandsTest/Model.lean`](WindowCommandsTest/Model.lean),
  run by `lake test`: `windowCommandChecks`, in
  [`WindowCommandsTest/WindowCommands.lean`](WindowCommandsTest/WindowCommands.lean),
  on the core's test kit: the commands by key, and the package held to
  `window-commands-api`'s contract.
- **End to end**: the core's headless fixtures that split and arrange
  windows run on the default set's editor.

The gate runs the driver over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove window-commands` rebuilds your editor without it; the
keys that ran its commands then run nothing
([installing-packages.md](../../docs/packages/installing-packages.md)).
