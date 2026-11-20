# languages

A default package: the languages that ship, `rust`, `json`, `markdown`,
`toml` and `lean`, and the `code` mode, the one major mode of a buffer
with a language, whose text is parsed and drawn as its language says. A
file of a shipped language opens highlighted in an editor that holds this
package.

Its design record is in [packages.md](../../docs/design/packages.md),
"The default package `languages`".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `languages`. It
   requires the core, `editor-core`, by path (`../../lean`), declares the
   library `Languages`, the test library `LanguagesTest` and the test
   driver `languages-test`, and turns every Lean linter on with warnings
   as errors.
2. [`Languages/EditorPackage.lean`](Languages/EditorPackage.lean): the
   entry module. It imports `Languages.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Language.package]
   ```
3. [`Languages/Compiled.lean`](Languages/Compiled.lean): the `Package`
   value, `Editor.Language.package`, named `languages`. Its `setup`
   defines the mode `code` with `defineMode`, then each shipped language
   with `defineLanguage`, in order.

The data it registers is the core's (`Language.modes` and
`Language.shipped`, in `lean/Editor/Language.lean`): the core's file
commands choose a path's language by it, and the core's tests read it.
The package is what registers it. Its declaration keeps its name,
`Editor.Language.package`, from when it was a module of the core.

## Its tests

- **The test driver**, [`LanguagesTest/Model.lean`](LanguagesTest/Model.lean),
  run by `lake test`: `languagePackageChecks`, in
  [`LanguagesTest/Languages/Compiled.lean`](LanguagesTest/Languages/Compiled.lean),
  which mirrors the library module: the package registers the shipped
  languages in order, the `code` mode, and no command.
- It has no headless fixture of its own. The core's
  `tests/headless/open-file`, run on the default set's editor, opens files
  in the mode `code`.

## Dropping it

`:package-remove languages` rebuilds your editor without it; it then
registers no language and no mode `code`, unless your config defines them
(`defineMode`, `defineLanguage`)
([installing-packages.md](../../docs/packages/installing-packages.md)).
