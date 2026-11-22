# evil

A default package: evil and the Vim scheme. The scheme turns keys into
invocations, by Vim's grammar over states (normal, insert, visual,
visual-line, operator-pending and the minibuffer's) and their keymaps;
evil is what those invocations run, written on the editor API: the
motions, the operators, the text objects (Vim's and the syntax tree's), the
registers, the marks, the jumps, undo and redo, dot repeat, the scroll
commands and the Edit menu's clipboard commands.

It supplies the editor's input scheme. Its lakefile declares the keyword
`editor-input-scheme`, so the package-set build hands
`Evil.EditorPackage.scheme` to the editor's hosts beside the packages. An
editor built from a set without it, and with no other package that
supplies a scheme, refuses to start: it prints `editor: no input scheme is
installed: no package of this editor's package set supplies one` and exits
1.

Its design record is in [packages.md](../../docs/design/packages.md),
"Input schemes", and in
[keymaps-and-modes.md](../../docs/design/keymaps-and-modes.md).

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `evil`. It requires
   the core, `editor-core`, by path (`../../lean`), declares the keyword
   `editor-input-scheme`, the library `Evil`, the test library `EvilTest`
   and the test driver `evil-test`, and turns every Lean linter on with
   warnings as errors.
2. [`Evil/EditorPackage.lean`](Evil/EditorPackage.lean): the entry module.
   It imports `Evil.Compiled` and the modules config names evil through.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Evil.package]

   def scheme : Editor.SchemePackage :=
     Editor.Evil.scheme
   ```
3. [`Evil/Compiled.lean`](Evil/Compiled.lean): the `Package` value,
   `Editor.Evil.package`, named `evil`, which registers the commands the
   scheme's invocations name, and `Editor.Evil.scheme`, the scheme the
   package supplies, named `vim`.
4. [`Evil/Vim.lean`](Evil/Vim.lean): the Vim scheme: states, the grammar
   that parses a key sequence, what an edit compiles to, the last change,
   and what the scheme reports of a view.
5. [`Evil/Vim/Default.lean`](Evil/Vim/Default.lean): the default states and
   their bindings, and `Vim.Default.scheme`.
6. [`Evil.lean`](Evil.lean): the states' commands, insert state's editing
   keys and where a cursor rests.
7. The modules under [`Evil/`](Evil/): `Motions`, `Operators`, `Objects`
   and `TreeObjects`, `Registers`, `Marks`, `Jumps`, `Undo`, `Repeat`,
   `Scroll`, `Clipboard`, and `Theorems`, what is proved of evil on the
   text model.

The declarations keep their names, `Editor.Evil.…`, `Editor.Vim.…` and
`Editor.Vim.Default.…`, from when they were modules of the core
(`Editor.Evil`, `Editor.InputScheme.Vim`), so config under `open Editor`
names them as it did.

## Its tests

- **The test driver**, [`EvilTest/Model.lean`](EvilTest/Model.lean), run by
  `lake test`: the scheme's checks in
  [`EvilTest/Vim.lean`](EvilTest/Vim.lean),
  [`EvilTest/Vim/Default.lean`](EvilTest/Vim/Default.lean) and
  [`EvilTest/Vim/Contract.lean`](EvilTest/Vim/Contract.lean), and evil's in
  [`EvilTest/Evil.lean`](EvilTest/Evil.lean) and the modules under
  [`EvilTest/Evil/`](EvilTest/Evil/), on evil's test kit,
  [`EvilTest/Kit.lean`](EvilTest/Kit.lean), and the drivers of
  [`EvilTest/Support/`](EvilTest/Support/).
- **The linked test**, [`EvilTest/Linked.lean`](EvilTest/Linked.lean), run
  by the package steps in `mise run ffi-test`: evil through the headless
  host of the Vim scheme over the real elaborator and the library's syntax
  service, in the modules under [`EvilTest/Linked/`](EvilTest/Linked/). It
  reads the repository's syntax fixtures, `tests/syntax`.
- It has no headless fixture of its own. The core's fixtures under
  `tests/headless`, run on the default set's editor, press its keys.

## Dropping it

`:package-remove evil` rebuilds your editor without it. Unless your set
holds another package that supplies an input scheme, that editor would
refuse to start, so the restart is given up before the session is handed
over, saying why, and the editor you are in keeps running
([installing-packages.md](../../docs/packages/installing-packages.md)).
