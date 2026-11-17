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
  The grammar is named as the library's syntax service knows it; a grammar
  loaded from a path at run time would be a registration that makes a name
  known to the service, and an entry would still name it.
- **`indentUnit`** is one level of indentation: a number of spaces, or a
  tab.

## The shipped table

`Language.shipped` is `rust` (`*.rs`, four spaces), `json` (`*.json`, two
spaces) and `markdown` (`*.md`, two spaces), each parsed with the grammar of
its name and that grammar's shipped queries. Each is a named definition, so
config can write `{ Language.rust with … }`.

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

## What an entry cannot mean

`problems` names the patterns no file name can be meant by: an empty one,
and one that holds `/`, which a base name never does.

## Where an addition goes

| Addition | Where |
|---|---|
| A shipped language | A named definition here, and in `shipped` |
| Something more a language says of how its text is parsed or drawn | A field of `Mode.SyntaxTree` (`Editor/Mode.lean`), which a language holds |
| Something more a language says of how it is edited | A field of `Language`, read by its consumer |
| A new kind of pattern | A variant of `Language.Pattern`, its pass in `forPath`, and its case in `problems` |

Pinned by `ModelTest.languageMatchChecks`.
-/

namespace Editor

/-- A pattern of file names a language is chosen for. -/
inductive Language.Pattern where
  /-- A file's exact base name: `Cargo.lock`. -/
  | name (fileName : String)
  /-- An extension, without its dot: `rs` for `*.rs`. -/
  | extension (extension : String)
  deriving DecidableEq, Repr

/-- One level of a language's indentation. -/
inductive Language.IndentUnit where
  /-- This many spaces. -/
  | spaces (count : Nat)
  /-- One tab. -/
  | tab
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
  /-- One level of its indentation. -/
  indentUnit : Language.IndentUnit := .spaces 4
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

/-- The languages that ship, in their order. -/
def shipped : Array Language :=
  #[rust, json, markdown]

/-- The table of `later`'s entries over `earlier`'s: `later`'s, in order,
then `earlier`'s that no entry of `later` names, in order. A later owner's
entry of a name replaces an earlier owner's whole entry. -/
def over (later earlier : List Language) : List Language :=
  later ++ earlier.filter fun language => !later.any (·.name == language.name)

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
