# buffers

A default package: the buffer commands. `switch-buffer` shows another
open buffer in the window, by name, exactly or by fuzzy match, or asks for
one with a prompt; `list-buffers` shows the buffer list; `close-buffer`
closes a buffer unless it has unsaved changes. It also registers the
buffer completion source, `buffers`, and the value of the interface
library `buffers-api` (`BuffersApi.Buffers`), whose `close` version
control's commit closes its message buffer with. An editor without it has
none of the three commands; ex's `:b`, `:ls` and `:bd` are still bound to
their names, with no command registered under them.

Its design record is in [packages.md](../../docs/design/packages.md),
"The default packages of the features-as-packages roadmap's phase 6".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `buffers`. It
   requires the core, `editor-core`, by path (`../../lean`), declares the
   library `Buffers`, the test library `BuffersTest` and the test driver
   `buffers-test`, and turns every Lean linter on with warnings as errors.
2. [`Buffers/EditorPackage.lean`](Buffers/EditorPackage.lean): the entry
   module. It imports `Buffers.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Buffers.package]
   ```
3. [`Buffers/Compiled.lean`](Buffers/Compiled.lean): the `Package` value,
   `Editor.Buffers.package`, named `buffers`. Its `setup` registers the
   three commands under `buffers-api`'s names, the buffer source, and the
   `BuffersApi.Buffers` value.
4. [`Buffers.lean`](Buffers.lean): the commands themselves, written over
   the core's editor API: the order buffers were last used in is the
   core's state's, and the messages are functions here.

The names are the interface package `buffers-api`'s
(`BuffersApi`, [`../buffers-api/`](../buffers-api/)), which the ex line
binds `b`, `ls` and `bd` to. The declarations keep their names, `Editor.Buffers.…`, from
when they were modules of the core.

## Its tests

- **The test driver**, [`BuffersTest/Model.lean`](BuffersTest/Model.lean),
  run by `lake test`: `bufferCommandChecks`, in
  [`BuffersTest/Buffers.lean`](BuffersTest/Buffers.lean), the commands on
  the loop's driver over the editor's models, with the support
  [`BuffersTest/Support/Buffers.lean`](BuffersTest/Support/Buffers.lean);
  and `buffersPackageChecks`, in
  [`BuffersTest/Buffers/Compiled.lean`](BuffersTest/Buffers/Compiled.lean),
  `buffers-api`'s contract over the package.
- It has no linked test and no headless fixture of its own. The core's
  `tests/headless/default-config`, run on the default set's editor, opens
  the buffer prompt from the default config's keys.

## Dropping it

`:package-remove buffers` rebuilds your editor without it; it then has no
`switch-buffer`, `list-buffers` or `close-buffer`, unless your config
registers commands under those names
([installing-packages.md](../../docs/packages/installing-packages.md)).
