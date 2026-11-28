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
  and the repository's `textobjects.scm` and `indents.scm` for `rust` and
  `highlights.scm` for `markdown` and `markdown_inline` (a heading by its
  level, a link's title as a link). `markdown` and `markdown_inline` also
  ship the repository's `rendered.scm`, and `markdown` its
  `rendered-injections.scm`, which a rendered Markdown view parses with
  (`Editor/Markdown/Parse.lean`).
- **`yaml`**: the language of `.yaml` and `.yml` files, defined here, and
  its grammar (`tree-sitter-yaml` 0.7.2), highlighted with the query its
  crate ships, copied unmodified to `grammars/queries/yaml/`. It declares
  no policy, so it is reparsed whole.
- **The popular languages**: `java`, `swift`, `ruby`, `python`,
  `javascript`, `typescript`, `tsx`, `c`, `cpp` and `clojure`, defined
  here, and their grammars, each from its crates.io crate at an exact pin
  (`rust/Cargo.toml`), with its highlights query and, for `swift`,
  `javascript`, `typescript`, `tsx` and `cpp`, its injections. Each query
  is the crate's own, byte for byte, or the files its grammar's
  `tree-sitter.json` names, joined in its order (the README names the
  parts). None ships indents or text objects in the editor's names, so
  none has either. Each declares no policy, so each is reparsed whole until
  a sweep of its incremental reparses earns it `incremental` (the rdm task
  `languages-reparse-policies`).

  Each entry maps the captures its query uses as the core's entries do
  (`Language.lean`), by the core's rule (`Highlight.faceOf`): a capture
  outside the face vocabulary with an evident face is mapped to it (swift's
  `boolean` to `syntax.constant`, C's and C++'s `delimiter` to
  `syntax.punctuation`); one with no evident face (`escape`, `label`,
  swift's `spell` and `character.special`) stays unmapped and draws
  nothing. And `variable` draws nothing in every entry whose query starts
  with a catch-all `(identifier) @variable` (swift's
  `(simple_identifier) @variable`): the queries are written for a
  highlighter where the later pattern of a node wins, while the editor's
  earliest pattern wins (`crates/editor-syntax/src/highlight.rs`, "The
  highlight rule"), so mapped, `variable` would win every identifier and no
  function, constant or property capture on one would draw. Mapped to
  none, it gives way, as in `Language.lean`'s `lean`, and its dotted
  captures fall back to that none.

  The language `clojure`'s grammar is `clojure_orchard`: its library
  exports `tree_sitter_clojure_orchard`, and a declaration's symbol must
  register its declared name (`Language.Grammar`), so a Markdown fence of
  `clojure` injects nothing, since a fence's name is a grammar's.

A file of a shipped language opened before the core's `register-grammars`
job has answered is drawn plain, then highlighted once the job's command
runs. The job runs at every editor's start: its first install's, or, with
no config to load or a first reload that is rejected, that of the
packages' grammars alone (`Config.Event.withoutConfig`) (`Language.Grammar.treeOf`; `docs/design/keymaps-and-modes.md`,
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
list, and a language of its own, if the core's table has none, as an entry
of `languages`, with the captures its query needs mapped (above); its source is a build-dependency in `rust/Cargo.toml` (or a vendored
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

/-- The language `java`: `.java` files, the grammar `java`, four spaces;
its plain identifiers in no face, so the query's closer captures of an
identifier draw (the module docs). -/
def java : Language :=
  { name := "java", patterns := [.extension "java"]
    syntaxTree := { grammar := "java", captures := [("variable", none)] } }

/-- The language `swift`: `.swift` files, the grammar `swift`, four spaces;
its booleans drawn as constants, as TOML's and Lean's are, and its plain
identifiers in no face (the module docs). -/
def swift : Language :=
  { name := "swift", patterns := [.extension "swift"]
    syntaxTree :=
      { grammar := "swift"
        captures := [("boolean", some ⟨"syntax.constant"⟩), ("variable", none)] } }

/-- The language `ruby`: `.rb`, `.rake` and `.gemspec` files, `Gemfile` and
`Rakefile`, the grammar `ruby`, two spaces; its plain identifiers in no
face (the module docs). -/
def ruby : Language :=
  { name := "ruby"
    patterns :=
      [.extension "rb", .extension "rake", .extension "gemspec", .name "Gemfile", .name "Rakefile"]
    syntaxTree := { grammar := "ruby", captures := [("variable", none)] }
    indentUnit := .spaces 2 }

/-- The language `python`: `.py` and `.pyi` files, the grammar `python`,
four spaces; its plain identifiers in no face (the module docs). -/
def python : Language :=
  { name := "python", patterns := [.extension "py", .extension "pyi"]
    syntaxTree := { grammar := "python", captures := [("variable", none)] } }

/-- The language `javascript`: `.js`, `.mjs`, `.cjs` and `.jsx` files, the
grammar `javascript`, two spaces; its plain identifiers in no face (the
module docs). -/
def javascript : Language :=
  { name := "javascript"
    patterns := [.extension "js", .extension "mjs", .extension "cjs", .extension "jsx"]
    syntaxTree := { grammar := "javascript", captures := [("variable", none)] }
    indentUnit := .spaces 2 }

/-- The language `typescript`: `.ts`, `.mts` and `.cts` files, the grammar
`typescript`, two spaces; its plain identifiers in no face (the module
docs). -/
def typescript : Language :=
  { name := "typescript", patterns := [.extension "ts", .extension "mts", .extension "cts"]
    syntaxTree := { grammar := "typescript", captures := [("variable", none)] }
    indentUnit := .spaces 2 }

/-- The language `tsx`: `.tsx` files, the grammar `tsx`, two spaces; its
plain identifiers in no face (the module docs). -/
def tsx : Language :=
  { name := "tsx", patterns := [.extension "tsx"]
    syntaxTree := { grammar := "tsx", captures := [("variable", none)] }
    indentUnit := .spaces 2 }

/-- The language `c`: `.c` and `.h` files, the grammar `c`, four spaces; its
delimiters (`;`, `.`, `,`) drawn as punctuation and its plain identifiers
in no face (the module docs). A `.h` is C's alone: a path takes the first
entry with its extension, and config can move it. -/
def c : Language :=
  { name := "c", patterns := [.extension "c", .extension "h"]
    syntaxTree :=
      { grammar := "c"
        captures := [("delimiter", some ⟨"syntax.punctuation"⟩), ("variable", none)] } }

/-- The language `cpp`: `.cc`, `.cpp`, `.cxx`, `.hpp`, `.hxx` and `.hh`
files, the grammar `cpp`, four spaces; as `c`, since its query includes
C's: its delimiters drawn as punctuation and its plain identifiers in no
face (the module docs). -/
def cpp : Language :=
  { name := "cpp"
    patterns :=
      [.extension "cc", .extension "cpp", .extension "cxx", .extension "hpp", .extension "hxx",
        .extension "hh"]
    syntaxTree :=
      { grammar := "cpp"
        captures := [("delimiter", some ⟨"syntax.punctuation"⟩), ("variable", none)] } }

/-- The language `clojure`: `.clj`, `.cljs`, `.cljc` and `.edn` files, the
grammar `clojure_orchard` (the module docs say why that name), two spaces.
Its query captures no `variable`, so it maps nothing. -/
def clojure : Language :=
  { name := "clojure"
    patterns := [.extension "clj", .extension "cljs", .extension "cljc", .extension "edn"]
    syntaxTree := { grammar := "clojure_orchard" }
    indentUnit := .spaces 2 }

/-- The languages defined here, in order: `yaml`, then the popular ones. -/
def languages : Array Language :=
  #[yaml, java, swift, ruby, python, javascript, typescript, tsx, c, cpp, clojure]

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

/-- The grammar `java`, declaring no policy. -/
def javaGrammar : Language.Grammar :=
  grammar "java" none

/-- The grammar `swift`, declaring no policy. -/
def swiftGrammar : Language.Grammar :=
  grammar "swift" none

/-- The grammar `ruby`, declaring no policy. -/
def rubyGrammar : Language.Grammar :=
  grammar "ruby" none

/-- The grammar `python`, declaring no policy. -/
def pythonGrammar : Language.Grammar :=
  grammar "python" none

/-- The grammar `javascript`, declaring no policy. -/
def javascriptGrammar : Language.Grammar :=
  grammar "javascript" none

/-- The grammar `typescript`, declaring no policy. -/
def typescriptGrammar : Language.Grammar :=
  grammar "typescript" none

/-- The grammar `tsx`, TypeScript with JSX, declaring no policy. -/
def tsxGrammar : Language.Grammar :=
  grammar "tsx" none

/-- The grammar `c`, declaring no policy. -/
def cGrammar : Language.Grammar :=
  grammar "c" none

/-- The grammar `cpp`, declaring no policy. -/
def cppGrammar : Language.Grammar :=
  grammar "cpp" none

/-- The grammar `clojure_orchard`, the language `clojure`'s, declaring no
policy. -/
def clojureOrchardGrammar : Language.Grammar :=
  grammar "clojure_orchard" none

/-- The grammars of the popular languages, in order: java, swift, ruby,
python, javascript, typescript, tsx, c, cpp and clojure_orchard, the order
of `rust/build.rs`. -/
def popularGrammars : Array Language.Grammar :=
  #[javaGrammar, swiftGrammar, rubyGrammar, pythonGrammar, javascriptGrammar, typescriptGrammar,
    tsxGrammar, cGrammar, cppGrammar, clojureOrchardGrammar]

/-- The package: the languages defined here (`languages`), and every grammar
`languages` ships, in the order rust, json, markdown, markdown_inline, toml,
lean, yaml, then the popular ones (`popularGrammars`). -/
def package : Package :=
  { name := "languages-grammars"
    setup := do
      for language in languages do
        defineLanguage language
    grammars :=
      #[rustGrammar, jsonGrammar, markdownGrammar, markdownInlineGrammar, tomlGrammar, leanGrammar,
          yamlGrammar] ++
        popularGrammars }

end Languages.Grammars
