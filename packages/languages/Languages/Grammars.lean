import Editor.Language.Grammar
import Editor.Package

/-!
# The `languages-grammars` package: the grammars `languages` ships from source

The languages whose grammar the editor does not compile in, each with the
grammar `languages` ships for it, built from pinned source by the set's
build (`docs/design/packages.md`, "A package's grammars"): the crate
`languages-grammar-sources` (`packages/languages/rust`) compiles each into
`libtree-sitter-<name>` for the platform it builds on, and the set's build
stages it under the Lake package's staged `grammars/<platform>/`, beside
the queries the package keeps in `grammars/queries/`. Each declaration is
per platform, its paths relative to that staged directory, the layout a
prebuilt package ships (`libraries`).

- **`yaml`**: the language of `.yaml` and `.yml` files, and its grammar
  (`tree-sitter-yaml` 0.7.2, MIT; its notice is at
  `grammars/licenses/tree-sitter-yaml`), highlighted with the query its
  crate ships, copied unmodified to `grammars/queries/yaml/`.

**Why a package of its own.** A package that declares grammars is refused
whole where no grammars directory of its Lake package is staged
(`Package.noGrammarsDirectory`), and the fixture harness stages none. Were
these declarations on `Editor.Language.package`, every headless fixture
would lose the `code` mode and every shipped language. As a second package
of the Lake package `languages`, only this one is refused there, silently,
and the rest register as before. A grammar added in a later phase goes
here, with its build-dependency and line in the crate's `build.rs`.

It imports the grammar declaration and the package type, the core's API,
and nothing else. Pinned by `LanguagesTest.grammarPackageChecks`
(`LanguagesTest/Languages/Grammars.lean`).
-/

namespace Languages.Grammars

open Editor

/-- The libraries of the grammar `name`, by platform, relative to the
staged grammars directory: `<platform>/libtree-sitter-<name>.<ext>`, a
`.dylib` on macOS and a `.so` on Linux, where the set's build stages what
the crate compiled. -/
def libraries (name : String) : List (String × System.FilePath) :=
  [("darwin-aarch64", s!"darwin-aarch64/libtree-sitter-{name}.dylib"),
    ("darwin-x86_64", s!"darwin-x86_64/libtree-sitter-{name}.dylib"),
    ("linux-aarch64", s!"linux-aarch64/libtree-sitter-{name}.so"),
    ("linux-x86_64", s!"linux-x86_64/libtree-sitter-{name}.so")]

/-- The language `yaml`: `.yaml` and `.yml` files, parsed with the grammar
`yaml`. -/
def yaml : Language :=
  { name := "yaml", patterns := [.extension "yaml", .extension "yml"]
    syntaxTree := { grammar := "yaml" } }

/-- The grammar `yaml`, per platform, its queries under `queries/yaml`. -/
def yamlGrammar : Language.Grammar :=
  Language.Grammar.declarePerPlatform "yaml" (libraries "yaml") "queries/yaml"

/-- The package: the language `yaml` and its grammar. -/
def package : Package :=
  { name := "languages-grammars", setup := defineLanguage yaml, grammars := #[yamlGrammar] }

end Languages.Grammars
