import Editor.Language.IndentUnit
import Editor.Mode

/-!
# Languages

A language is data: a name, the file names it is chosen for, how its text is
parsed and drawn, and one level of its indentation (`Language`;
`docs/design/keymaps-and-modes.md`, "Languages and the code mode"). Which
language a file is in is decided here, by a pure rule over a table of
entries (`Language.forPath`); config only supplies entries.

## The entry

- **`name`** is how a buffer records its language and how config overrides
  a shipped entry: `rust`.
- **`patterns`** are typed, not glob strings, so there is nothing to parse:
  `.name "Cargo.lock"` is a file's exact base name, and `.extension "rs"`
  is `*.rs`, a base name that ends in `.rs` with something before the dot
  (so neither `rs` nor `.rs` alone is a Rust file). Both are
  case-sensitive.
- **`syntaxTree`** is a `Mode.SyntaxTree` (`Editor/Mode.lean`): the grammar
  name and the same optional query and capture overrides a mode takes, so
  setting a buffer's mode hands it to `Editor/Highlight.lean` unchanged.
  The grammar is named as the library's syntax service knows it. A grammar
  config declares (`defineGrammar`, `Editor/Language/Grammar.lean`) is
  loaded from a native library at run time, by a registration that makes
  its name known to the service, and an entry names it like any other;
  once it registered, the queries read from its directory fill the
  entry's empty sources, and until its registration has answered, a
  buffer of the entry is drawn plain (`Language.Grammar.treeOf`, which the
  loop applies to the language's tree). A mode with its own tree naming a
  declared grammar gets the grammar but not the declared queries: the
  resolution is applied to the language's tree only.
- **`indentUnit`** is one level of indentation: a number of spaces, or a
  tab (`Editor/Language/IndentUnit.lean`, its own module so the state
  requests can name it). An entry that says none has four spaces
  (`Language.IndentUnit.default`). `=` and the commands that open a line
  read it (`Editor/Indent.lean`), through `Target.indentUnit`, which asks
  the loop (`indentUnitOf`, `Editor/Api.lean`).

## The shipped table

`Language.shipped` is `rust` (`*.rs`, four spaces), `json` (`*.json`, two
spaces), `markdown` (`*.md`, two spaces), `toml` (`*.toml` and
`Cargo.lock`, two spaces) and `lean` (`*.lean`, `lakefile.lean` included, two
spaces), each parsed with the grammar of its name and that grammar's shipped
queries. Each is a named definition, so config can write
`{ Language.rust with … }`.

`toml` maps one capture: its grammar's highlights capture booleans as
`boolean`, which the face vocabulary has no face for, so the entry draws them
in `syntax.constant`, as Rust's `true` and `false` are drawn. Other TOML
files with no `.toml` extension (`uv.lock`, `poetry.lock`, `Pipfile`) are
not in the shipped table; config adds one in a line:
`defineLanguage { Language.toml with patterns := Language.toml.patterns ++ [.name "uv.lock"] }`.

`lean` maps three captures its grammar's highlights query draws and the face
vocabulary has no face for: `boolean` (`true`, `false`, `True`, `False`) in
`syntax.constant`, as TOML's and Rust's are drawn; `character` (`'c'`) in
`syntax.string`, the face of a string or character literal; and `namespace`
(the names after `namespace`, `section` and `end`) in `syntax.module`, the
face of a module or namespace's name. It maps a fourth, `variable`, to
nothing. The query's `(identifier) @variable` comes before every pattern
that names an identifier more closely, and of one node's captures the first
that draws is kept (`editor_syntax::highlight::spans`), so with `variable`
drawn no identifier would show any later capture. Drawn as nothing, it
gives way: namespace, section and `end` names draw in `syntax.module`;
`import`, `open` and `export` names in `syntax.module` (their `only` names
in `syntax.function`); the names `def`, `theorem`, `abbrev`, `opaque`,
`constant`, `axiom` and `instance` define, and a called bare name, in
`syntax.function`; `structure` and `inductive` names and universe names in
`syntax.type`; constructor names in `syntax.constructor`; field names and
projected fields in `syntax.property`; attribute names in
`syntax.attribute`. Every other identifier, and the holes and named
argument labels (`variable.builtin`, `variable.parameter`, which fall back
to `variable`), draws in no face, in the default face's ink: the same as
`syntax.variable` in the built-in theme, but no longer the blue the
Solarized themes give it. `lean-toolchain`, `*.olean`
and `*.ilean` are not `*.lean`, so they have no language.

## The matching rule (`forPath`)

The table handed in is in precedence order: config's entries first, in the
order config defined them, then the shipped entries config did not override
by name, in their order (`over`, which the registry folds its owners'
entries with). Given the path's base name, the rule answers:

1. the first entry, in table order, with a `.name` pattern equal to it;
2. otherwise the first entry with an `.extension` pattern it matches;
3. otherwise none.

So an exact base name beats an extension, and between patterns of one kind
config's entry beats a shipped one and the earlier beats the later: both are
table order. A path with no base name has no language.

## The code mode

One generic major mode, `code` (`codeMode`), is the mode of every buffer
with a language. It has no tree of its own: its text is parsed and drawn as
its buffer's language says (`Mode.syntaxTreeOfLanguage`, `Editor/Mode.lean`),
so highlighting, injections, indentation and text objects come from the
language entry. It fills no role and has no local command; a user's minor
mode for a language is an ordinary minor mode. Config may define a mode
called `code`, which is then the one found, as for any compiled mode.

## What an entry cannot mean

`problems` names the patterns no file name can be meant by: an empty one,
and one that holds `/`, which a base name never does.

## Where an addition goes

| Addition | Where |
|---|---|
| A shipped language | A named definition here, and in `shipped` |
| Something more a language says of how its text is parsed or drawn | A field of `Mode.SyntaxTree` (`Editor/Mode.lean`), which a language holds |
| Something more a language says of how it is edited | A field of `Language`, read by its consumer |
| Something the `code` mode does for every language | `codeMode`, reading what it needs from the buffer's language |
| A new kind of pattern | A variant of `Language.Pattern`, its pass in `forPath`, and its case in `problems` |
| A grammar loaded at run time | A declaration in config (`defineGrammar`, `Editor/Language/Grammar.lean`), named by an entry's `syntaxTree.grammar`; nothing here |

Pinned by `ModelTest.languageMatchChecks` (the rule, pure) and
`ModelTest.modeRecordChecks` (the `code` mode's tree).
-/

namespace Editor

/-- A pattern of file names a language is chosen for. -/
inductive Language.Pattern where
  /-- A file's exact base name: `Cargo.lock`. -/
  | name (fileName : String)
  /-- An extension, without its dot: `rs` for `*.rs`. -/
  | extension (extension : String)
  deriving DecidableEq, Repr

/-- A language: what it is called, the file names it is chosen for, how its
text is parsed and drawn, and one level of its indentation. -/
structure Language where
  /-- Its name, by which a buffer records it and config overrides it. -/
  name : String
  /-- The file names it is chosen for. -/
  patterns : List Language.Pattern
  /-- How its text is parsed and drawn: a grammar, and the same optional
  query and capture overrides a mode takes. -/
  syntaxTree : Mode.SyntaxTree
  /-- One level of its indentation (`Editor/Language/IndentUnit.lean`). -/
  indentUnit : Language.IndentUnit := Language.IndentUnit.default
  deriving DecidableEq, Repr

namespace Language

/-- Rust: `*.rs`, the grammar `rust`, four spaces. -/
def rust : Language :=
  { name := "rust", patterns := [.extension "rs"], syntaxTree := { grammar := "rust" } }

/-- JSON: `*.json`, the grammar `json`, two spaces. -/
def json : Language :=
  { name := "json", patterns := [.extension "json"], syntaxTree := { grammar := "json" }
    indentUnit := .spaces 2 }

/-- Markdown: `*.md`, the grammar `markdown`, two spaces. -/
def markdown : Language :=
  { name := "markdown", patterns := [.extension "md"], syntaxTree := { grammar := "markdown" }
    indentUnit := .spaces 2 }

/-- TOML: `*.toml` and `Cargo.lock`, the grammar `toml`, two spaces; its
booleans drawn as constants. -/
def toml : Language :=
  { name := "toml", patterns := [.extension "toml", .name "Cargo.lock"]
    syntaxTree := { grammar := "toml", captures := [("boolean", some ⟨"syntax.constant"⟩)] }
    indentUnit := .spaces 2 }

/-- Lean: `*.lean` (`lakefile.lean` included), the grammar `lean`, two
spaces; its booleans drawn as constants, its characters as strings, its
namespaces as modules and its plain identifiers in no face, so the
query's closer captures of an identifier draw (the module docs). -/
def lean : Language :=
  { name := "lean", patterns := [.extension "lean"]
    syntaxTree :=
      { grammar := "lean"
        captures :=
          [("boolean", some ⟨"syntax.constant"⟩), ("character", some ⟨"syntax.string"⟩),
            ("namespace", some ⟨"syntax.module"⟩), ("variable", none)] }
    indentUnit := .spaces 2 }

/-- The languages that ship, in their order. -/
def shipped : Array Language :=
  #[rust, json, markdown, toml, lean]

/-- The name of the one major mode a buffer with a language is put in. -/
def codeName : String :=
  "code"

/-- The `code` mode: its text is parsed and drawn as its buffer's language
says (`Mode.syntaxTreeOfLanguage`). It fills no role and has no local
command. -/
def codeMode : Mode :=
  { name := codeName, syntaxTreeOfLanguage := true }

/-- The modes that ship with the languages, which the `languages` package
registers (the default package `languages`, `packages/languages/`):
`code`. -/
def modes : Array Mode :=
  #[codeMode]

/-- The table of `later`'s items over `earlier`'s, each named by `name`:
`later`'s, in order, then `earlier`'s that no item of `later` names, in
order. A later owner's item of a name replaces an earlier owner's whole
item. The rule of the language table (`over`) and of the grammar table
(`Language.Grammar.over`). -/
def overBy {α : Type} (name : α → String) (later earlier : List α) : List α :=
  later ++ earlier.filter fun item => !later.any (name · == name item)

/-- The table of `later`'s entries over `earlier`'s, by name (`overBy`): a
later owner's entry of a name replaces an earlier owner's whole entry. -/
def over (later earlier : List Language) : List Language :=
  overBy (·.name) later earlier

/-- Whether `pattern` is a `.name` pattern equal to `base`. -/
def Pattern.namesFile (pattern : Pattern) (base : String) : Bool :=
  match pattern with
  | .name fileName => fileName == base
  | .extension _ => false

/-- Whether `pattern` is an `.extension` pattern `base` ends in, after its
dot, with something before the dot. -/
def Pattern.extends (pattern : Pattern) (base : String) : Bool :=
  match pattern with
  | .name _ => false
  | .extension wanted =>
    let suffix := "." ++ wanted
    base.endsWith suffix && base.length > suffix.length

/-- The language `table`, in precedence order, chooses for `path` ("The
matching rule", in the module docs): the first entry with a base-name
pattern of the path's base name, else the first with an extension pattern
it matches; `none` when none matches, or the path has no base name. -/
def forPath (table : List Language) (path : System.FilePath) : Option Language := do
  let base ← path.fileName
  (table.find? fun language => language.patterns.any (·.namesFile base)) <|>
      table.find? fun language => language.patterns.any (·.extends base)

/-- What is wrong with `language`'s patterns, each as a sentence: an empty
one, and one that holds `/`, which no base name does. -/
def problems (language : Language) : List String :=
  language.patterns.filterMap fun pattern =>
    let (kind, text) :=
      match pattern with
      | .name fileName => ("file name", fileName)
      | .extension wanted => ("extension", wanted)
    if text.isEmpty then some s!"its {kind} pattern is empty"
    else if text.contains '/' then some s!"its {kind} pattern `{text}` holds `/`" else none

end Language

end Editor
