import Editor.Language.Grammar
import Editor.Package

/-!
# The `languages-grammars` package: the grammars `languages` ships from source

Every grammar `languages` ships, built from pinned source by the set's
build (`docs/design/packages.md`, "A package's grammars"): the library
compiles in no grammar, so these are the grammars of the shipped languages
too. The crate `languages-grammar-sources` (`packages/languages/rust`)
compiles each into `libtree-sitter-<name>` for the platform it builds on,
and the set's build stages it under the Lake package's staged
`grammars/<platform>/`, beside the queries the package keeps in
`grammars/queries/<name>/`. Each declaration is per platform, its paths
relative to that staged directory, the layout a prebuilt package ships
(`libraries`). The package's README lists each grammar's crate, exact pin,
upstream and licence notice.

- **`rust`, `json`, `markdown`, `markdown_inline`, `toml` and `lean`**:
  the grammars of the core's shipped languages (`Language.shipped`, which
  `languages` registers), compiled into the library until the
  shipped-grammars roadmap's phase 4. Each is reparsed incrementally but
  `markdown_inline`, whose incremental reparses were seen to differ from a
  fresh parse, and which is reparsed whole (`rust/Cargo.toml` says how each
  policy was found). `markdown_inline` has no language of its own: it is
  the grammar the `markdown` grammar's injections query hands each inline
  node. Their queries are the ones the library shipped, byte for byte: the
  grammar crates' own, the vendored `tree-sitter-lean`'s highlights alone,
  and the repository's `textobjects.scm` and `indents.scm` for `rust`.
- **`yaml`**: the language of `.yaml` and `.yml` files, defined here, and
  its grammar (`tree-sitter-yaml` 0.7.2), highlighted with the query its
  crate ships, copied unmodified to `grammars/queries/yaml/`. It declares
  no policy, so it is reparsed whole.

A file of a shipped language opened before the core's `register-grammars`
job has answered is drawn plain, then highlighted once the job's command
runs (`Language.Grammar.treeOf`; `docs/design/keymaps-and-modes.md`,
"Declared grammars").

**Why a package of its own.** A package that declares grammars is refused
whole where no grammars directory of its Lake package is staged
(`Package.noGrammarsDirectory`), and the fixture harness stages none. Were
these declarations on `Editor.Language.package`, every headless fixture
would lose the `code` mode and every shipped language. As a second package
of the Lake package `languages`, only this one is refused there, silently,
and the rest register as before. The harness loses nothing it could show
by that: a fixture runs on the stepped host's fakes, whose syntax model
holds the core's test grammars registered, and a fixture cannot ask for
highlights.

**Adding a grammar.** A grammar goes here, as a declaration in `package`'s
list; its source is a build-dependency in `rust/Cargo.toml` (or a vendored
directory) and a line in the crate's `build.rs`; its queries go in
`grammars/queries/<name>/`, its notice in `grammars/licenses/`, and its row
in the README's table.

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

/-- The grammar `name`, per platform (`libraries`), its queries under
`queries/<name>`, reparsed as `policy` says. -/
def grammar (name : String) (policy : Option ReparsePolicy) : Language.Grammar :=
  Language.Grammar.declarePerPlatform name (libraries name) s!"queries/{name}" (policy := policy)

/-- The grammar `rust`, reparsed incrementally. -/
def rustGrammar : Language.Grammar :=
  grammar "rust" (some .incremental)

/-- The grammar `json`, reparsed incrementally. -/
def jsonGrammar : Language.Grammar :=
  grammar "json" (some .incremental)

/-- The grammar `markdown`, Markdown's block structure, reparsed
incrementally. -/
def markdownGrammar : Language.Grammar :=
  grammar "markdown" (some .incremental)

/-- The grammar `markdown_inline`, Markdown's inline markup, reparsed
whole. -/
def markdownInlineGrammar : Language.Grammar :=
  grammar "markdown_inline" (some .whole)

/-- The grammar `toml`, reparsed incrementally. -/
def tomlGrammar : Language.Grammar :=
  grammar "toml" (some .incremental)

/-- The grammar `lean`, reparsed incrementally. -/
def leanGrammar : Language.Grammar :=
  grammar "lean" (some .incremental)

/-- The grammar `yaml`, declaring no policy. -/
def yamlGrammar : Language.Grammar :=
  grammar "yaml" none

/-- The package: the language `yaml`, and every grammar `languages` ships,
in the order rust, json, markdown, markdown_inline, toml, lean, yaml. -/
def package : Package :=
  { name := "languages-grammars", setup := defineLanguage yaml
    grammars :=
      #[rustGrammar, jsonGrammar, markdownGrammar, markdownInlineGrammar, tomlGrammar, leanGrammar,
        yamlGrammar] }

end Languages.Grammars
