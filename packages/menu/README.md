# menu

A default package: the menu bar that ships. It defines the standard menu
(the application's menu, File, Edit and Window) and binds the keys of its
File and Edit items: `s-o`, `s-s`, `s-z`, `s-Z`, `s-x`, `s-c`, `s-v` and
`s-a`. An editor without it publishes no menu bar unless your config
defines one (`defineMenu`), and those eight chords are unbound
([installing-packages.md](../../docs/packages/installing-packages.md)).

Its design record is in [packages.md](../../docs/design/packages.md).

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `menu`. It requires
   the core, `editor-core`, and the interface packages `evil-api` and
   `frame-commands-api`, by path, declares the library `Menu`, the test library `MenuTest` and the test
   driver `menu-test`, and turns every Lean linter on with warnings as
   errors.
2. [`Menu/EditorPackage.lean`](Menu/EditorPackage.lean): the entry module.
   It imports `Menu.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Menu.package]
   ```
3. [`Menu/Compiled.lean`](Menu/Compiled.lean): the standard menu,
   `Editor.Menu.standard`, and the `Package` value, `Editor.Menu.package`,
   named `menu`.

The menu's types, the key equivalents a registry gives a menu's items and
the way a chosen item runs its command are the core's
(`lean/Editor/Menu.lean`, `lean/Editor/Config/Registry.lean`,
`lean/Editor/Loop.lean`). The items name commands of other packages by
constants: `files-api`'s `open-file` and `save-buffer` and the clipboard
names, which the core holds, `evil-api`'s `undo` and `redo`, and
`frame-commands-api`'s `minimise-window` and `toggle-fullscreen`. The declarations keep
their names (`Editor.Menu.…`) from when the package was a module of the
core.

## Its tests

- **The test driver**, [`MenuTest/Model.lean`](MenuTest/Model.lean), run by
  `lake test`: `standardMenuChecks`, in
  [`MenuTest/Menu/Compiled.lean`](MenuTest/Menu/Compiled.lean), which
  mirrors the library module, on the core's test kit.

The gate runs the driver over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove menu` rebuilds your editor without it: no menu bar is
published, and the eight chords run nothing
([installing-packages.md](../../docs/packages/installing-packages.md)).
