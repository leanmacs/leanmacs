# minibuffer

A default package: the minibuffer's commands and its mode. A command of
any package asks for a text with a prompt, and the core opens the
minibuffer's window and lists the prompt's candidates; this package's
commands answer it. They accept and cancel the open prompt, move a choice
through its candidates, put a candidate in the input, delete backward and
to the input's start, ask for the input scheme (Vim's `/`), and take a
source's batch of candidates as its job delivers them. The mode is the one
the minibuffer's buffer is made with, which fills the roles `activate`,
`quit`, `next-item` and `previous-item`; the Vim scheme binds the commands
by name in the minibuffer (`RET`, `<Escape>`, `C-n`, `C-p`, `TAB`,
`<Backspace>`, `C-u`).

It implements the interface package [`minibuffer-api`](../minibuffer-api/),
which declares the names of its nine commands and of its mode: the seven
the Vim scheme's minibuffer table binds, the one the Vim scheme yields to
ask, the one a source's job posts a batch as, and the mode the core makes
the minibuffer's buffer with. Its design record is in
[packages.md](../../docs/design/packages.md), "The default packages of
the features-as-packages roadmap's phase 4".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `minibuffer`. It
   requires the core, `editor-core`, by path (`../../lean`), and the
   interface package `minibuffer-api` (`../minibuffer-api`), declares the
   library `Minibuffer`, the test library `MinibufferTest` and the test
   driver `minibuffer-test`, and turns every Lean linter on with warnings
   as errors.
2. [`Minibuffer/EditorPackage.lean`](Minibuffer/EditorPackage.lean): the
   entry module. It imports `Minibuffer.Compiled`, and so the whole
   library, which is what config sees of the package.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Minibuffer.package]
   ```
3. [`Minibuffer/Compiled.lean`](Minibuffer/Compiled.lean): the `Package`
   value, `Editor.Minibuffer.package`, named `minibuffer`. Its `setup`
   registers the nine commands and the mode.
4. [`Minibuffer.lean`](Minibuffer.lean): the commands, each over the
   core's prompt API ("Prompts", `lean/Editor/Api.lean`), and the mode.
   Their names are `minibuffer-api`'s (`MinibufferApi.acceptName`, …,
   `MinibufferApi.modeName`).

Every declaration is in the namespace it had in the core,
`Editor.Minibuffer`, so config names them as `Minibuffer.acceptName` and
the rest under `open Editor`, with `import Minibuffer`. The library
imports the core's API, its prompt and completion interfaces
(`Editor.Command.Call`, `Editor.Completion.Later`, `Editor.Mode`,
`Editor.Role`) and the interface package.

## Its tests

- **The test driver**, [`MinibufferTest/Model.lean`](MinibufferTest/Model.lean),
  run by `lake test`: `promptModeChecks`
  ([`MinibufferTest/Minibuffer.lean`](MinibufferTest/Minibuffer.lean)),
  the commands and the mode on the loop's driver over the models and the
  test scheme, and `minibufferPackageChecks`
  ([`MinibufferTest/Minibuffer/Compiled.lean`](MinibufferTest/Minibuffer/Compiled.lean)),
  the interface's contract check over the `Package` value.
- **The headless fixtures**, [`tests/headless/prompt`](tests/headless/prompt/)
  (a prompt asked, typed, accepted and cancelled through the host) and
  [`tests/headless/candidates`](tests/headless/candidates/) (a prompt's
  candidates listed, chosen and put in the input). They were written on
  the editor with the minibuffer still in the core and moved here
  unchanged.

The gate runs both kinds over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove minibuffer` rebuilds your editor without it. Prompts
still open, but nothing answers them: `RET` in the minibuffer runs
`minibuffer-accept`, which nothing registers, so the prompt stays open,
and no source's candidates that answer later reach the prompt, since a
source's job posts each batch as `minibuffer-candidates`. Completion at
point's `words`, which answers later too, then lists nothing.
