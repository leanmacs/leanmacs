# mode-line

A default package: the segments of the mode line that ship. The Vim
state's badge, the buffer's name, the modified and changed marks, the
directory, the pending keys, the major mode, line:col and the position
are segments it registers, which the default listing and config's
`modeLine` find by name. An editor without it draws a mode line of the
segments other packages and config register.

Its design record is in [packages.md](../../docs/design/packages.md),
"The default package `mode-line`".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `mode-line`. It
   requires the core, `editor-core`, by path (`../../lean`), declares the
   library `ModeLine`, the test library `ModeLineTest` and the test driver
   `mode-line-test`, and turns every Lean linter on with warnings as
   errors.
2. [`ModeLine/EditorPackage.lean`](ModeLine/EditorPackage.lean): the
   entry module. It imports `ModeLine.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.ModeLine.package]
   ```
3. [`ModeLine/Compiled.lean`](ModeLine/Compiled.lean): the `Package`
   value, `Editor.ModeLine.package`, named `mode-line`. Its `setup`
   registers each shipped segment with `defineSegment`, in order.

The segments it registers are the core's data (`ModeLine.shipped`, in
`lean/Editor/ModeLine.lean`), with the default listing
(`ModeLine.Order.standard`): the core's loop lists the mode line by that
listing and its picture draws it. The package is what registers the
segments. Its declaration keeps its name, `Editor.ModeLine.package`, from
when it was a module of the core.

## Its tests

- **The test driver**, [`ModeLineTest/Model.lean`](ModeLineTest/Model.lean),
  run by `lake test`: `modeLinePackageChecks`, in
  [`ModeLineTest/ModeLine/Compiled.lean`](ModeLineTest/ModeLine/Compiled.lean),
  which mirrors the library module: the package registers the shipped
  segments, in order, with their fields, and the default listing resolves
  over them to the shipped mode line.
- **The headless fixture**, [`tests/headless/mode-line`](tests/headless/mode-line/):
  a config that defines a segment and lists the mode line for each side,
  one name nobody registered among them. It was the core's
  (`tests/headless/mode-line`) and moved here byte for byte.

The gate runs both over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove mode-line` rebuilds your editor without it; the mode
line then holds only the segments other packages and your config
register, version control's `review` among them
([installing-packages.md](../../docs/packages/installing-packages.md)).
