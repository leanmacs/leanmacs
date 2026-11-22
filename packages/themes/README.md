# themes

A default package: the command that loads a theme. `load-theme` switches
the theme in force, with no reload: given a name it loads the theme
registered under it, and given none it asks for one with a prompt over the
registered themes' names. It also registers the theme `default`, the
built-in one, which is in force when no config names a theme, and the
completion source `themes` of the category `theme`, which the prompt
lists. An editor without it has no `load-theme`; its theme in force is
still named `default`, and config still defines themes (`defineTheme`) and
names the one in force (`useTheme`).

The palettes that ship, Solarized and Fairy Floss, are another package,
[`shipped-themes`](../shipped-themes/), which registers after this one.

Its design record is in [packages.md](../../docs/design/packages.md).

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `themes`. It requires
   the core, `editor-core`, and its interface package, `themes-api`, by
   path, declares the library `Themes`, the test library `ThemesTest` and
   the test driver `themes-test`, and turns every Lean linter on with
   warnings as errors.
2. [`Themes/EditorPackage.lean`](Themes/EditorPackage.lean): the entry
   module. It imports `Themes.Compiled`, and through it `Themes`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Themes.package]
   ```
3. [`Themes/Compiled.lean`](Themes/Compiled.lean): the `Package` value,
   `Editor.Themes.package`, named `themes`: the command, the theme
   `default` and the source.
4. [`Themes.lean`](Themes.lean): the command and its source, written over
   the core's editor API.

The command's name is the interface package `themes-api`'s
(`ThemesApi.loadName`, [`../themes-api/`](../themes-api/)). The
declarations keep their names, `Editor.Themes.…`, from when they were
modules of the core.

## Its tests

- **The test driver**, [`ThemesTest/Model.lean`](ThemesTest/Model.lean),
  run by `lake test`: the model checks in
  [`ThemesTest/Themes.lean`](ThemesTest/Themes.lean), on the core's test
  kit.
- **The linked test**, [`ThemesTest/Linked.lean`](ThemesTest/Linked.lean),
  run by the package steps in `mise run ffi-test`: the command through the
  headless host over the real elaborator and the display's real binding,
  in [`ThemesTest/Linked/Themes.lean`](ThemesTest/Linked/Themes.lean).
- It has no headless fixture of its own. The fixtures of
  [`shipped-themes`](../shipped-themes/tests/headless/), run on the default
  set's editor, load themes through it.

## Dropping it

`:package-remove themes` rebuilds your editor without it; it then has no
`load-theme`, and the default config's `SPC h t` names no command, unless
your config registers a command under `themes-api`'s name
([installing-packages.md](../../docs/packages/installing-packages.md)).
