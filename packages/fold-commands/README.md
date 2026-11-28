# fold-commands

A default package: the fold commands. `fold-toggle` folds or unfolds the
section under the cursor in a buffer whose owner declared foldable ranges
(a section drawn as one placeholder row while folded), and the folds mode
puts it on the role `toggle`, whose keymaps go after the links mode's in a
buffer with foldable ranges. Off every range, `toggle` runs the buffer's
own. An editor without it still draws a buffer's folded ranges as their
placeholders, and motion, jumps and search still honour them, but nothing
toggles one from the keyboard.

Its design record is in [packages.md](../../docs/design/packages.md), and
what a fold is and how motion, selection, jumps and search treat one in
[text-and-display.md](../../docs/design/text-and-display.md), "Folds, as
built".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `fold-commands`. It
   requires the core, `editor-core`, alone, by path, declares the library
   `FoldCommands`, the test library `FoldCommandsTest` and the test
   driver `fold-commands-test`, and turns every Lean linter on with
   warnings as errors.
2. [`FoldCommands/EditorPackage.lean`](FoldCommands/EditorPackage.lean):
   the entry module. It imports `FoldCommands.Compiled`, and through it
   `FoldCommands` and the core's `Editor.Folds`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.FoldCommands.package]
   ```
3. [`FoldCommands.lean`](FoldCommands.lean): the package's `setup`, the
   core's `Folds.setup` (`lean/Editor/Folds.lean`), which holds every
   decision and declares every name.
4. [`FoldCommands/Compiled.lean`](FoldCommands/Compiled.lean): the
   `Package` value, `Editor.FoldCommands.package`, named `fold-commands`.

## Its tests

- **The test driver**, [`FoldCommandsTest/Model.lean`](FoldCommandsTest/Model.lean),
  run by `lake test`: `foldCommandsChecks`, in
  [`FoldCommandsTest/FoldCommands.lean`](FoldCommandsTest/FoldCommands.lean),
  on the core's test kit: what the package registers, and that a declared
  fold is toggled on a host with the package.

The gate runs the driver over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove fold-commands` rebuilds your editor without it; a
buffer's folded ranges are then drawn but toggled by nothing
([installing-packages.md](../../docs/packages/installing-packages.md)).
