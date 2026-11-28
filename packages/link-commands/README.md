# link-commands

A default package: the link commands. `link-follow` follows the link at
the cursor in a buffer whose owner gave it links (a file location, a URL,
a scheme reference or a command), `link-next` and `link-previous` move
the cursor to the next and previous link, and the links mode puts them on
the roles `activate`, `next-link` and `previous-link`, whose keymaps go
first in a buffer with links. The job `url-open` hands a URL to the
system's opener. An editor without it still draws a buffer's links in the
link face, and a mode keeps its own `activate`, but nothing follows a
link.

Its design record is in [packages.md](../../docs/design/packages.md), and
what a link is and how each kind is followed in
[text-and-display.md](../../docs/design/text-and-display.md), "Followable
spans, as built".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `link-commands`. It
   requires the core, `editor-core`, alone, by path, declares the library
   `LinkCommands`, the test library `LinkCommandsTest` and the test
   driver `link-commands-test`, and turns every Lean linter on with
   warnings as errors.
2. [`LinkCommands/EditorPackage.lean`](LinkCommands/EditorPackage.lean):
   the entry module. It imports `LinkCommands.Compiled`, and through it
   `LinkCommands` and the core's `Editor.Links`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.LinkCommands.package]
   ```
3. [`LinkCommands.lean`](LinkCommands.lean): the package's `setup`, the
   core's `Links.setup` (`lean/Editor/Links.lean`), which holds every
   decision and declares every name.
4. [`LinkCommands/Compiled.lean`](LinkCommands/Compiled.lean): the
   `Package` value, `Editor.LinkCommands.package`, named `link-commands`.

## Its tests

- **The test driver**, [`LinkCommandsTest/Model.lean`](LinkCommandsTest/Model.lean),
  run by `lake test`: `linkCommandsChecks`, in
  [`LinkCommandsTest/LinkCommands.lean`](LinkCommandsTest/LinkCommands.lean),
  on the core's test kit: what the package registers, and that a link is
  followed on a host with the package.

The gate runs the driver over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove link-commands` rebuilds your editor without it; a
buffer's links are then drawn and followed by nothing
([installing-packages.md](../../docs/packages/installing-packages.md)).
