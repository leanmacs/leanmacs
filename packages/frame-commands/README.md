# frame-commands

A default package: the frame commands. `toggle-fullscreen` asks the
platform's window to enter or leave the system's fullscreen, and
`minimise-window` asks it to minimise; the package binds `C-s-f` and
`s-m` to them, and `s-q` (Command-Q) to `quit`. An editor without it has
neither command and none of the three bindings, so the Window menu's
Minimise and Enter Full Screen, which name the two commands, run nothing
and show no key equivalent; the window's own buttons still minimise it
and put it in fullscreen, and the application menu's Quit still quits
([installing-packages.md](../../docs/packages/installing-packages.md)).

Its design record is in [packages.md](../../docs/design/packages.md).

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `frame-commands`.
   It requires the core, `editor-core`, and its interface package,
   `frame-commands-api`, by path, declares the library `FrameCommands`,
   the test library `FrameCommandsTest` and the test driver
   `frame-commands-test`, and turns every Lean linter on with warnings as
   errors.
2. [`FrameCommands/EditorPackage.lean`](FrameCommands/EditorPackage.lean):
   the entry module. It imports `FrameCommands.Compiled`, and through it
   `FrameCommands`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.FrameCommands.package]
   ```
3. [`FrameCommands.lean`](FrameCommands.lean): the two commands, each
   over the display interface's request to the window
   (`Display.askFrame`). Their names are the interface package's
   (`FrameCommandsApi`, [`../frame-commands-api`](../frame-commands-api/)).
4. [`FrameCommands/Compiled.lean`](FrameCommands/Compiled.lean): the
   `Package` value, `Editor.FrameCommands.package`, named
   `frame-commands`, with the three bindings.

The frame itself is the core's: its state and what the window reports
(`lean/Editor/State.lean`, `lean/Editor/Display.lean`). `s-q` runs the
command named `quit`, a name the core declares (`lean/Editor/Quit.lean`)
and the package `ex` registers. The declarations keep their names
(`Editor.FrameCommands.…`) from when they were modules of the core.

## Its tests

- **The test driver**, [`FrameCommandsTest/Model.lean`](FrameCommandsTest/Model.lean),
  run by `lake test`: `frameCommandChecks`, in
  [`FrameCommandsTest/FrameCommands.lean`](FrameCommandsTest/FrameCommands.lean),
  on the core's test kit: the commands by key, and the package held to
  `frame-commands-api`'s contract.

The gate runs the driver over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove frame-commands` rebuilds your editor without it; the
keys that ran its commands then run nothing
([installing-packages.md](../../docs/packages/installing-packages.md)).
