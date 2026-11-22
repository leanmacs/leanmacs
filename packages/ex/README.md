# ex

A default package: the ex command line. The command `ex` asks for a line
with a prompt labelled `:` and runs it as the command its name is bound
to, with the rest of the line as its argument; a line that begins with `!`
goes to the shell. The package also registers `quit`, `save-and-quit` and
`reload-config`, binds the ex names that ship for the files, the buffers
and its own commands (`w`, `w!`, `e`, `e!`, `autoread`, `noautoread`, `q`,
`wq`, `reload`, `b`, `ls` and `bd`), and registers the ex line's two
completion sources, the `:!` history and the bound names. An editor
without it has no ex line: `:` runs nothing, the ex names other packages
bind are bound to no line that could run them, and `quit` is no command,
so Command-Q, the system's quit and `window-quit` on the last window say
there is no such command. The window's close button still quits, by the
rule the core runs itself
([installing-packages.md](../../docs/packages/installing-packages.md)).

Its design record is in [packages.md](../../docs/design/packages.md), and
the ex line's rules in
[keymaps-and-modes.md](../../docs/design/keymaps-and-modes.md), "The ex
command line".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `ex`. It requires
   the core, `editor-core`, and its interface package, `ex-api`, by path,
   declares the library `Ex`, the test library `ExTest` and the test
   driver `ex-test`, and turns every Lean linter on with warnings as
   errors.
2. [`Ex/EditorPackage.lean`](Ex/EditorPackage.lean): the entry module. It
   imports `Ex.Compiled`, and through it `Ex`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Ex.package]
   ```
3. [`Ex.lean`](Ex.lean): the commands, each over the core's editor API,
   and the two sources.
4. [`Ex/Compiled.lean`](Ex/Compiled.lean): the `Package` value,
   `Editor.Ex.package`, named `ex`: the four commands, the twelve ex names
   and the two sources.

What an ex line is made of is the core's: its parts, its ranges and a
name's binding (`lean/Editor/Ex/Line.lean`), which the registry holds for
every package that binds an ex name. The quit rule and the name `quit`
are the core's too (`lean/Editor/Quit.lean`): the loop runs the rule for a
window's close request and the command named `quit` for the system's
quit. The names `ex` and `quit` are the interface package `ex-api`'s
(`ExApi.name`, `ExApi.quitName`, [`../ex-api/`](../ex-api/)), which the
Vim scheme's `:` names. The ex names run commands of other packages by the
constants of the interfaces that declare them: `files-api`'s,
`buffers-api`'s and `shell-api`'s. The declarations keep their names,
`Editor.Ex.…`, from when they were modules of the core.

## Its tests

- **The test driver**, [`ExTest/Model.lean`](ExTest/Model.lean), run by
  `lake test`: the model checks in [`ExTest/Ex.lean`](ExTest/Ex.lean) and
  [`ExTest/Ex/Compiled.lean`](ExTest/Ex/Compiled.lean), on the core's test
  kit, the package held to `ex-api`'s contract among them.
- **The linked test**, [`ExTest/Linked.lean`](ExTest/Linked.lean), run by
  the package steps in `mise run ffi-test`: the ex line through the
  headless host over the real elaborator and the library's file service,
  in [`ExTest/Linked/Ex.lean`](ExTest/Linked/Ex.lean).
- It has no headless fixture of its own. The core's fixtures that type an
  ex line (`tests/headless/ex` and others) run on the default set's
  editor, through it.

## Dropping it

`:package-remove ex` rebuilds your editor without it. It then has no ex
line, so that is the last ex line it runs: put the package back by editing
your set's lakefile and restarting, or with a command of your own bound to
`package-install`
([installing-packages.md](../../docs/packages/installing-packages.md)).
