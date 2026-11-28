# languages

A default package: the languages that ship, `rust`, `json`, `markdown`,
`toml` and `lean`, and the `code` mode, the one major mode of a buffer
with a language, whose text is parsed and drawn as its language says;
`yaml`, `java`, `swift`, `ruby`, `python`, `javascript`, `typescript`,
`tsx`, `c`, `cpp` and `clojure`; and every grammar of these, which the
package ships from pinned source, compiled by the set's build. The editor's library compiles in no
grammar, so a file of a shipped language is highlighted in an editor that
holds this package once its grammars have registered, which the editor
does at startup, with config or without: a file opened before that is
drawn plain for that moment, then highlighted.

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
   value `languages-grammars`: the languages of the table below the
   grammars' (`yaml` and the popular ones), and the grammars `rust`,
   `json`, `markdown`, `markdown_inline`, `toml`, `lean`, `yaml`, `java`,
   `swift`, `ruby`, `python`, `javascript`, `typescript`, `tsx`, `c`,
   `cpp` and `clojure_orchard`, each declared per platform relative to the
   staged grammars directory, with its reparse policy. It is a package of
   its own so that a host with no staged grammars directory, the headless
   fixture harness, refuses it alone and keeps `languages` (its module
   docs).
5. [`rust/`](rust): the crate `languages-grammar-sources`, a member of the
   root workspace. Its build script compiles each grammar from its pinned
   source with `editor-grammar-build`, and its binary prints the report the
   set's build reads to stage the libraries. Its `Cargo.toml` says why each
   grammar and each pin. Its own `deny.toml` holds what it may depend on.
6. [`grammars/`](grammars): each grammar's queries, `queries/<name>/`, and
   each grammar's licence, `licenses/`. No library is checked in.

The data it registers is the core's (`Language.modes` and
`Language.shipped`, in `lean/Editor/Language.lean`): the core's file
commands choose a path's language by it, and the core's tests read it.
The package is what registers it. Its declaration keeps its name,
`Editor.Language.package`, from when it was a module of the core.

## Grammars and their licences

The grammars before `yaml` were compiled into the editor's library until
the shipped-grammars roadmap's phase 4. Their queries are the ones the
library shipped, byte for byte. The grammars after `yaml` are the popular
languages of the roadmap's phase 5, each from its crates.io crate as
published; a query of several parts is the files the grammar's own
`tree-sitter.json` names, joined in its order with nothing between, so
`cat` of the parts in that order makes it. No grammar after `yaml` ships
an indents or text-objects query in the editor's names (swift's
`indents.scm` and `textobjects.scm` are nvim's and Helix's), so none of
them indents by its tree or has text objects. Locals and tags are never
shipped: the editor reads neither.

| Grammar | Source, exact pin | Queries | Upstream | Licence | Notice |
|---|---|---|---|---|---|
| `rust` | crate `tree-sitter-rust` =0.24.2 | the crate's `highlights.scm` and `injections.scm`; the repository's own `textobjects.scm` and `indents.scm` | <https://github.com/tree-sitter/tree-sitter-rust> | MIT | [`grammars/licenses/tree-sitter-rust`](grammars/licenses/tree-sitter-rust), the crate's `LICENSE` |
| `json` | crate `tree-sitter-json` =0.24.8 | the crate's `highlights.scm` | <https://github.com/tree-sitter/tree-sitter-json> | MIT | [`grammars/licenses/tree-sitter-json`](grammars/licenses/tree-sitter-json), upstream's at `v0.24.8` |
| `markdown` | crate `tree-sitter-md` =0.5.4, `tree-sitter-markdown/` | the subdirectory's `highlights.scm` and `injections.scm` | <https://github.com/tree-sitter-grammars/tree-sitter-markdown> | MIT | [`grammars/licenses/tree-sitter-md`](grammars/licenses/tree-sitter-md), upstream's at `v0.5.4` |
| `markdown_inline` | crate `tree-sitter-md` =0.5.4, `tree-sitter-markdown-inline/` | the subdirectory's `highlights.scm` and `injections.scm` | as `markdown` | MIT | as `markdown` |
| `toml` | crate `tree-sitter-toml-ng` =0.7.0 | the crate's `highlights.scm` | <https://github.com/tree-sitter-grammars/tree-sitter-toml> | MIT | [`grammars/licenses/tree-sitter-toml-ng`](grammars/licenses/tree-sitter-toml-ng), upstream's at `v0.7.0` |
| `lean` | directory `vendor/tree-sitter-lean` (`tree-sitter-lean` 0.2.0, commit `0d28e5d6`) | the copy's `highlights.scm` alone | <https://github.com/Julian/tree-sitter-lean> | MIT | [`grammars/licenses/tree-sitter-lean`](grammars/licenses/tree-sitter-lean), the copy's `LICENSE` |
| `yaml` | crate `tree-sitter-yaml` =0.7.2 | the crate's `highlights.scm` | <https://github.com/tree-sitter-grammars/tree-sitter-yaml> | MIT | [`grammars/licenses/tree-sitter-yaml`](grammars/licenses/tree-sitter-yaml) |
| `java` | crate `tree-sitter-java` =0.23.5 | the crate's `highlights.scm` | <https://github.com/tree-sitter/tree-sitter-java> | MIT | [`grammars/licenses/tree-sitter-java`](grammars/licenses/tree-sitter-java), upstream's at `v0.23.5` |
| `swift` | crate `tree-sitter-swift` =0.7.4 | the crate's `highlights.scm` and `injections.scm` | <https://github.com/alex-pinkus/tree-sitter-swift> | MIT | [`grammars/licenses/tree-sitter-swift`](grammars/licenses/tree-sitter-swift), the crate's `LICENSE` |
| `ruby` | crate `tree-sitter-ruby` =0.23.1 | the crate's `highlights.scm` | <https://github.com/tree-sitter/tree-sitter-ruby> | MIT | [`grammars/licenses/tree-sitter-ruby`](grammars/licenses/tree-sitter-ruby), upstream's at `v0.23.1` |
| `python` | crate `tree-sitter-python` =0.25.0 | the crate's `highlights.scm` | <https://github.com/tree-sitter/tree-sitter-python> | MIT | [`grammars/licenses/tree-sitter-python`](grammars/licenses/tree-sitter-python), the crate's `LICENSE` |
| `javascript` | crate `tree-sitter-javascript` =0.25.0 | `highlights.scm` of the crate's `highlights.scm`, `highlights-jsx.scm` and `highlights-params.scm`, in that order; the crate's `injections.scm` | <https://github.com/tree-sitter/tree-sitter-javascript> | MIT | [`grammars/licenses/tree-sitter-javascript`](grammars/licenses/tree-sitter-javascript), the crate's `LICENSE` |
| `typescript` | crate `tree-sitter-typescript` =0.23.2, `typescript/` | `highlights.scm` of the crate's `queries/highlights.scm`, then `tree-sitter-javascript` 0.25.0's `highlights.scm`; JavaScript's `injections.scm` | <https://github.com/tree-sitter/tree-sitter-typescript> | MIT | [`grammars/licenses/tree-sitter-typescript`](grammars/licenses/tree-sitter-typescript), upstream's at `v0.23.2`; JavaScript's parts, as `javascript` |
| `tsx` | crate `tree-sitter-typescript` =0.23.2, `tsx/` | `highlights.scm` of the crate's `queries/highlights.scm`, then `tree-sitter-javascript` 0.25.0's `highlights-jsx.scm` and `highlights.scm`; JavaScript's `injections.scm` | as `typescript` | MIT | as `typescript` |
| `c` | crate `tree-sitter-c` =0.24.2 | the crate's `highlights.scm` | <https://github.com/tree-sitter/tree-sitter-c> | MIT | [`grammars/licenses/tree-sitter-c`](grammars/licenses/tree-sitter-c), the crate's `LICENSE` |
| `cpp` | crate `tree-sitter-cpp` =0.23.4 | `highlights.scm` of `tree-sitter-c` 0.24.2's `highlights.scm`, then the crate's; the crate's `injections.scm` | <https://github.com/tree-sitter/tree-sitter-cpp> | MIT | [`grammars/licenses/tree-sitter-cpp`](grammars/licenses/tree-sitter-cpp), upstream's at `v0.23.4`; C's part, as `c` |
| `clojure_orchard` | crate `tree-sitter-clojure-orchard` =0.2.9 | the crate's `highlights.scm` | <https://codeberg.org/grammar-orchard/tree-sitter-clojure-orchard> | CC0-1.0 (a public-domain dedication) | [`grammars/licenses/tree-sitter-clojure-orchard`](grammars/licenses/tree-sitter-clojure-orchard), the crate's `LICENSE` |

**Updating a grammar.** Bump its exact pin in `rust/Cargo.toml` (for
`lean`, update the vendored copy as [`vendor/README.md`](../../vendor/README.md)
says), copy its queries from the new version into `grammars/queries/<name>/`
over the old ones (`rust`'s `textobjects.scm` and `indents.scm` are the
repository's own: check them against the new node types), refresh its
notice in `grammars/licenses/`, and update the row above. Make a joined
`highlights.scm` again from its parts, in the order of the row, with `cat`
(`typescript`'s, `tsx`'s and `cpp`'s take parts of another grammar's crate:
take them at the pin of that grammar's row). Check whether the query still
starts with a catch-all `@variable`, and keep the entry's `variable`
mapping to none only while it does. The test grammars of the core's tests
(`crates/editor-syntax-fixture-grammars`) take the same pins as the six
former built-ins and copy their queries, so those pins move in the same
commit; it takes none of the popular languages.

## Languages

The languages `languages-grammars` defines, beyond the core's table
(`rust`, `json`, `markdown`, `toml` and `lean`), each with the grammar it
is parsed with. A path takes the first entry with its extension, so a
`.h` is C's; config can move it (`defineLanguage`).

| Language | Files | Grammar | Indent |
|---|---|---|---|
| `yaml` | `*.yaml`, `*.yml` | `yaml` | 4 spaces |
| `java` | `*.java` | `java` | 4 spaces |
| `swift` | `*.swift` | `swift` | 4 spaces |
| `ruby` | `*.rb`, `*.rake`, `*.gemspec`, `Gemfile`, `Rakefile` | `ruby` | 2 spaces |
| `python` | `*.py`, `*.pyi` | `python` | 4 spaces |
| `javascript` | `*.js`, `*.mjs`, `*.cjs`, `*.jsx` | `javascript` | 2 spaces |
| `typescript` | `*.ts`, `*.mts`, `*.cts` | `typescript` | 2 spaces |
| `tsx` | `*.tsx` | `tsx` | 2 spaces |
| `c` | `*.c`, `*.h` | `c` | 4 spaces |
| `cpp` | `*.cc`, `*.cpp`, `*.cxx`, `*.hpp`, `*.hxx`, `*.hh` | `cpp` | 4 spaces |
| `clojure` | `*.clj`, `*.cljs`, `*.cljc`, `*.edn` | `clojure_orchard` | 2 spaces |

Each maps the captures its query uses onto the face vocabulary as the
core's entries do ([`Languages/Grammars.lean`](Languages/Grammars.lean)'s
module docs): swift's `boolean` is drawn as a constant, C's and C++'s
`delimiter` as punctuation, and `variable` in no face wherever the query
starts with a catch-all identifier pattern, so the closer captures of an
identifier draw. Clojure's grammar is `clojure_orchard`, the name its
library exports, so a Markdown fence of `clojure` injects nothing.

## Its tests

- **The test driver**, [`LanguagesTest/Model.lean`](LanguagesTest/Model.lean),
  run by `lake test`: `languagePackageChecks`, in
  [`LanguagesTest/Languages/Compiled.lean`](LanguagesTest/Languages/Compiled.lean),
  which mirrors the library module: the package registers the shipped
  languages in order, the `code` mode, and no command; and
  `grammarPackageChecks`, in
  [`LanguagesTest/Languages/Grammars.lean`](LanguagesTest/Languages/Grammars.lean):
  what `languages-grammars` registers against a staged directory (its
  languages and its seventeen grammars, in order, with their policies),
  its refusal with none, the entry module's two packages, that a shipped
  language's tree waits for its grammar's answer, so its file is drawn
  plain until then, and which language a path of each popular language is
  in, and the faces its captures map to.
- **The linked test**, [`LanguagesTest/Linked.lean`](LanguagesTest/Linked.lean),
  which the package steps build and run (`tools/package-set.sh`): the
  default set's build staged every library it compiled, with the package's
  queries, a highlights query for each; every grammar registers on the
  platform the test runs on and each of its queries compiles against it
  (`registeredCheck`); the YAML fixture (`tests/syntax/yaml/settings.yaml`),
  a `.rs` file (`tests/syntax/rust/hello.rs`), a Markdown paragraph's
  inline markup (`tests/syntax/markdown/inline.md`), a `.py` file
  (`tests/syntax/python/hello.py`) and a Markdown fence of Python
  (`tests/syntax/markdown/python.md`) are drawn highlighted by the
  package's grammars over the real services; and a set whose package's
  grammar source does not compile fails its build naming the package and
  the grammar. The tests hold the mechanism, not each language: every
  grammar registers with queries that compile, and Python is drawn end to
  end.
- **The on-demand check**, [`rust/tests/default_install.rs`](rust/tests/default_install.rs)
  (`mise run languages-install-check`, never in the gate): the default set,
  installed, opens `tests/syntax/rust/hello.rs` highlighted by the
  package's `rust` grammar, over an empty config reloaded (`tests/install/script`,
  `tests/install/config/`) and with no config directory at all
  (`tests/install/without-config`), each against `tests/install/expected`
  ([on-demand-checks.md](../../docs/dev-practices/on-demand-checks.md),
  "The default set's grammars, installed, on demand").
- It has no headless fixture of its own.

## Dropping it

`:package-remove languages` rebuilds your editor without it; it then
registers no language and no mode `code`, unless your config defines them
(`defineMode`, `defineLanguage`)
([installing-packages.md](../../docs/packages/installing-packages.md)).
