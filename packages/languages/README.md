# languages

A default package: the languages that ship, `rust`, `json`, `markdown`,
`toml` and `lean`, and the `code` mode, the one major mode of a buffer
with a language, whose text is parsed and drawn as its language says; and
`yaml`, whose grammar the package ships from pinned source, compiled by
the set's build. A file of a shipped language opens highlighted in an
editor that holds this package.

Its design record is in [packages.md](../../docs/design/packages.md),
"The default packages of the features-as-packages roadmap's phase 3", and
"A package's grammars" for the grammars it ships.

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `languages`. It
   requires the core, `editor-core`, by path (`../../lean`), declares the
   library `Languages`, the test library `LanguagesTest` and the test
   driver `languages-test`, and turns every Lean linter on with warnings
   as errors. It carries the keyword `editor-grammars`, and declares the
   input file `editorGrammarSources`, `rust/Cargo.toml`.
2. [`Languages/EditorPackage.lean`](Languages/EditorPackage.lean): the
   entry module. It imports `Languages.Compiled` and `Languages.Grammars`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Language.package, Languages.Grammars.package]
   ```
3. [`Languages/Compiled.lean`](Languages/Compiled.lean): the `Package`
   value, `Editor.Language.package`, named `languages`. Its `setup`
   defines the mode `code` with `defineMode`, then each shipped language
   with `defineLanguage`, in order.
4. [`Languages/Grammars.lean`](Languages/Grammars.lean): the `Package`
   value `languages-grammars`: the language `yaml`, of `.yaml` and `.yml`
   files, and its grammar `yaml`, declared per platform relative to the
   staged grammars directory. It is a package of its own so that a host
   with no staged grammars directory, the headless fixture harness, refuses
   it alone and keeps `languages` (its module docs).
5. [`rust/`](rust): the crate `languages-grammar-sources`, a member of the
   root workspace. Its build script compiles each grammar from its pinned
   crate with `editor-grammar-build`, and its binary prints the report the
   set's build reads to stage the libraries. Its own `deny.toml` holds what
   it may depend on.
6. [`grammars/`](grammars): the grammars' queries, `queries/yaml/`, copied
   unmodified from the grammar's crate, and each grammar's licence,
   `licenses/`. No library is checked in.

The data it registers is the core's (`Language.modes` and
`Language.shipped`, in `lean/Editor/Language.lean`): the core's file
commands choose a path's language by it, and the core's tests read it.
The package is what registers it. Its declaration keeps its name,
`Editor.Language.package`, from when it was a module of the core.

## Grammars and their licences

| Grammar | Crate | Upstream | Licence | Notice |
|---|---|---|---|---|
| `yaml` | `tree-sitter-yaml` 0.7.2 | <https://github.com/tree-sitter-grammars/tree-sitter-yaml> | MIT | [`grammars/licenses/tree-sitter-yaml`](grammars/licenses/tree-sitter-yaml) |

## Its tests

- **The test driver**, [`LanguagesTest/Model.lean`](LanguagesTest/Model.lean),
  run by `lake test`: `languagePackageChecks`, in
  [`LanguagesTest/Languages/Compiled.lean`](LanguagesTest/Languages/Compiled.lean),
  which mirrors the library module: the package registers the shipped
  languages in order, the `code` mode, and no command; and
  `grammarPackageChecks`, in
  [`LanguagesTest/Languages/Grammars.lean`](LanguagesTest/Languages/Grammars.lean):
  what `languages-grammars` registers against a staged directory, its
  refusal with none, and the entry module's two packages.
- **The linked test**, [`LanguagesTest/Linked.lean`](LanguagesTest/Linked.lean),
  which the package steps build and run (`tools/package-set.sh`): the
  default set's build staged the `yaml` library it compiled, the YAML
  fixture (`tests/syntax/yaml/settings.yaml`) is drawn highlighted by it
  over the real services, and a set whose package's grammar source does
  not compile fails its build naming the package and the grammar.
- It has no headless fixture of its own.

## Dropping it

`:package-remove languages` rebuilds your editor without it; it then
registers no language and no mode `code`, unless your config defines them
(`defineMode`, `defineLanguage`)
([installing-packages.md](../../docs/packages/installing-packages.md)).
