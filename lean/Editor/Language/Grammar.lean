import Editor.File
import Editor.Language
import Editor.Language.Grammar.Answer

/-!
# Grammars config declares

A grammar declaration is config data beside `defineLanguage`
(`defineGrammar`, `Editor/Setup.lean`): a name, a native library, the
symbol that hands out its language, an optional reparse policy, and the
directory its queries are read from (`Language.Grammar`). A language entry
still names its grammar by name (`Mode.SyntaxTree.grammar`,
`Editor/Language.lean`); a declaration is what makes a name known to the
syntax service, by a registration (`Editor/SyntaxTree/Registration.lean`)
the core's `register-grammars` job makes at each install
(`Editor/Language/Grammar/Register.lean`).

## The declaration and its defaults (`declare`)

- **`symbol`** defaults to `tree_sitter_<name>`, the symbol tree-sitter's
  generated parsers export.
- **`queries`** defaults to `queries/` in the library's own directory,
  holding the query files directly (`<library dir>/queries/highlights.scm`):
  the directory belongs to one grammar, so it has no language component.
- **`policy`**, when given, is the reparse policy the grammar is
  registered with; with none it is registered `whole` (phase 1's rule).

## The name rule (`problem?`)

A declaration's symbol must register its declared name
(`GrammarSource.name symbol == name`), or the `setup` is refused. In
practice another symbol is one without the `tree_sitter_` prefix, which is
its own name. So the declared name is the name the library registers, the
name languages name, the name an override replaces, the name the echo area
says and the name the registry lists: one name end to end, with no change
to the registration's port, the C ABI or the worker. The alternative, the
declaration's name winning, would let `name := "mine"` with the symbol
`tree_sitter_json` override `json` for every JSON buffer under another
name. The check is pure, made before anything loads.

The library and the query directory must be absolute paths, as a
workspace's root must be: a relative library would be refused `notFound`
by the library without touching the disk, but saying so when config loads
is clearer.

## Which tree a buffer's language resolves to (`treeOf`)

The dispatch applies `treeOf` to the tree of the buffer's language when
the `code` mode is set (`Editor/Command/Dispatch.lean`), with the answers
of the current config generation (`Editor/Language/Grammar/Answer.lean`):

1. A grammar the installed config does not declare: the entry's tree,
   unchanged.
2. Declared, with no answer of this generation yet (the job is still
   running): no tree. The buffer is drawn plain, nothing is attached and
   nothing is said; the job's command highlights it once answered.
3. Declared and registered: the entry's tree with the queries read from
   the directory filled in where the entry gives none
   (`Queries.over`). The entry's own source wins over a file.
4. Declared and refused, and the service still lists the name (compiled
   in, or registered earlier): the entry's tree, unchanged, so a `.lean`
   buffer keeps the compiled-in `lean`.
5. Declared and refused, and the service does not list the name: no tree.
   The buffer stays open as plain text.

It is applied to the language's tree, not a mode's: a mode with a tree of
its own naming a declared grammar gets the grammar but not the declared
queries.

## The query files (`queryFiles`)

`highlights.scm`, `injections.scm`, `indents.scm` and `textobjects.scm`,
the names nvim-treesitter and Helix use, filling `highlights`,
`injections`, `indents` and `textObjects`. A missing file ships no query of
its kind, as a compiled-in grammar that ships none does; any other refusal
of the load ships none too, and is said (`unread`). Each is read under
`queryLimit`.

## The messages (`said`, `unread`)

One sentence for each refusal, joined by `; ` into one echo text:
``grammar `<name>`: <GrammarError.describe>, so <consequence>``, the
consequence "the compiled-in grammar stays" when the service still lists
the name and this process never registered it, "the grammar registered
before stays" when it did, and "its languages have no syntax tree"
otherwise; and ``grammar `<name>`: <file>: <FileError.describe>`` for a
query file that could not be read.

## Where an addition goes

| Addition | Where |
|---|---|
| Something more a declaration says | A field of `Language.Grammar`, a parameter of `declare` and `defineGrammar` (`Editor/Setup.lean`), and its check in `problem?` |
| A new kind of query file | An entry of `queryFiles`, its field of `Queries` (`Editor/Language/Grammar/Answer.lean`) and its case in `Queries.over` |
| A new case of which tree a buffer gets | `treeOf`, pinned by `ModelTest.grammarDeclarationChecks` |
| A new consequence of a refusal | `said` |

Pinned by `ModelTest.grammarDeclarationChecks` (the rules, pure).
-/

namespace Editor

/-- A grammar config declares: its name, where it is loaded from, and the
directory its queries are read from. -/
structure Language.Grammar where
  /-- The name it is declared under, which languages name. -/
  name : String
  /-- The library, the symbol and the policy it is registered from. -/
  source : GrammarSource
  /-- The directory its query files are read from. -/
  queries : System.FilePath
  deriving DecidableEq, Repr

namespace Language.Grammar

/-- The declaration of the grammar `name` from `library`, with the
defaults of the module docs: the symbol `tree_sitter_<name>` and the query
directory `queries/` in the library's directory. -/
def declare (name : String) (library : System.FilePath) (symbol : Option String := none)
    (queries : Option System.FilePath := none) (policy : Option ReparsePolicy := none) :
    Language.Grammar :=
  { name
    source :=
      { library := library.toString, symbol := symbol.getD s!"{GrammarSource.prefix}{name}"
        policy }
    queries := queries.getD ((library.parent.getD ".") / "queries") }

/-- The sentence of a declaration whose symbol registers another name. -/
def otherName (grammar : Language.Grammar) : String :=
  s!"the grammar `{grammar.name}`'s symbol `{grammar.source.symbol}` registers the grammar `{grammar.source.name}`: a grammar is declared under the name its symbol registers"

/-- The sentence of a declaration whose library is not an absolute path. -/
def relativeLibrary (grammar : Language.Grammar) : String :=
  s!"the grammar `{grammar.name}`'s library `{grammar.source.library}` is not an absolute path"

/-- The sentence of a declaration whose query directory is not an absolute
path. -/
def relativeQueries (grammar : Language.Grammar) : String :=
  s!"the grammar `{grammar.name}`'s query directory `{grammar.queries}` is not an absolute path"

/-- What is wrong with `grammar`, as a sentence: a symbol that registers
another name, a relative library, or a relative query directory; `none`
when nothing is. -/
def problem? (grammar : Language.Grammar) : Option String :=
  if grammar.source.name != grammar.name then some grammar.otherName
  else
    if !(System.FilePath.mk grammar.source.library).isAbsolute then some grammar.relativeLibrary
    else if !grammar.queries.isAbsolute then some grammar.relativeQueries else none

/-- The table of `later`'s declarations over `earlier`'s: `later`'s, in
order, then `earlier`'s that no declaration of `later` names, in order. -/
def over (later earlier : List Language.Grammar) : List Language.Grammar :=
  later ++ earlier.filter fun grammar => !later.any (·.name == grammar.name)

/-- The query files read from a declared grammar's directory, each with the
kind it fills. -/
def queryFiles : List (String × QueryKind) :=
  [("highlights.scm", .highlights), ("injections.scm", .injections),
    ("indents.scm", .indents), ("textobjects.scm", .textObjects)]

/-- `queries` with the source of `kind` set to `source`. -/
def Queries.set (queries : Queries) (kind : QueryKind) (source : Option String) : Queries :=
  match kind with
  | .highlights => { queries with highlights := source }
  | .injections => { queries with injections := source }
  | .textObjects => { queries with textObjects := source }
  | .indents => { queries with indents := source }

/-- `tree` with the read queries filled in where it gives no source of its
own: the entry's own source wins over a file. -/
def Queries.over (queries : Queries) (tree : Mode.SyntaxTree) : Mode.SyntaxTree :=
  { tree with
    highlights := tree.highlights <|> queries.highlights
    injections := tree.injections <|> queries.injections
    textObjects := tree.textObjects <|> queries.textObjects
    indents := tree.indents <|> queries.indents }

/-- The tree a buffer whose language's tree is `tree` gets, given the
declarations `declared` of the installed config, the recorded `answers` and
the config generation `generation` (the module docs): `none` for a buffer
drawn plain. -/
def treeOf (declared : List Language.Grammar) (answers : Answers) (generation : Nat)
    (tree : Mode.SyntaxTree) : Option Mode.SyntaxTree :=
  if !declared.any (·.name == tree.grammar) then some tree
  else
    match answers.answerOf? generation tree.grammar with
    | none => none
    | some (.registered queries) => some (queries.over tree)
    | some (.refused _ kept) => if kept then some tree else none

/-- What a refusal leaves, when the service still lists the name and this
process never registered it. -/
def compiledStays : String :=
  "the compiled-in grammar stays"

/-- What a refusal leaves, when the service still lists the name and this
process registered it before. -/
def registeredStays : String :=
  "the grammar registered before stays"

/-- What a refusal leaves, when the service does not list the name. -/
def noTree : String :=
  "its languages have no syntax tree"

/-- The sentence that says the registration of `name` was refused with
`error`, and what stays: `kept` when the service still lists the name, and
`registeredBefore` when this process registered it before. -/
def said (name : String) (error : GrammarError) (kept registeredBefore : Bool) : String :=
  let consequence :=
    if kept then if registeredBefore then registeredStays else compiledStays else noTree
  s!"grammar `{name}`: {error.describe}, so {consequence}"

/-- The sentence that says `grammar`'s query file `file` could not be read,
with `error`. -/
def unread (grammar : Language.Grammar) (file : String) (error : FileError) : String :=
  s!"grammar `{grammar.name}`: {grammar.queries / file}: {error.describe}"

/-- The most bytes a query file is read with: 1 MiB, the editor's policy,
since a load has no default. -/
def queryLimit : Nat :=
  1024 * 1024

/-- The name of the core's job that registers config's grammars. -/
def jobName : String :=
  "register-grammars"

end Language.Grammar

end Editor
