import Editor.File
import Editor.Language
import Editor.Language.Grammar.Answer

/-!
# Grammars config and packages declare

A grammar declaration is config data beside `defineLanguage`
(`defineGrammar`, `defineGrammarPerPlatform`, `Editor/Setup.lean`), or a
package's (`Package.grammars`, `Editor/Package.lean`): a name, a native
library, on every platform or per platform, the
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

## The per-platform form (`declarePerPlatform`, `Library`)

A native library is built for one platform, so a declaration may give one
library per platform it supports (`Library.perPlatform`), each under the
platform's name, all sharing one query directory, which then has no default
(the libraries' directories differ). A per-platform declaration that lists
no platform, lists one twice, or gives a relative path has a problem
(`noPlatform`, `platformTwice`, `relativePlatformLibrary`). The library is
picked when the core's job registers the grammar (`sourceOn`), not when
config or a package declares it: a `setup` is pure and knows no platform.
On a platform the declaration does not list, the registration is refused
in the job's reply before the service is asked (`noLibraryFor`,
`Editor/Language/Grammar/Register.lean`), said as any refusal is, and its
languages have no syntax tree; no build breaks.

## The platform (`platformOf`, `currentPlatform`)

`<os>-<arch>`, from Lean's target triple (`System.Platform.target`):
`darwin-aarch64`, `darwin-x86_64`, `linux-aarch64` and `linux-x86_64`; any
other triple is its own name, so a declaration can still list it. The
headless host's reducer registers on `currentPlatform`; the model tests
pass a platform of their own.

## A package's declarations (`within?`, `under`)

A package declares its grammars on `Editor.Package` (`Editor/Package.lean`)
with paths relative to its Lake package's `grammars/` directory, and
`Package.collected` (`Editor/Config/Packages.lean`) resolves them against
the directory where that directory is staged beside the running editor
(`under`). A path that is absolute, or whose `..` climbs out of the
directory once taken back lexically (`within?`), is refused with the path,
and the package with it. The resolved declarations are absolute, so
`problem?` holds of them as of config's.

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
4. Declared and refused, and the service still lists the name: compiled
   in and never registered by this process, the entry's tree, unchanged,
   so a `.lean` buffer keeps the compiled-in `lean`; registered earlier,
   the entry's tree with the queries read at the name's last registration
   filled in as in case 3 (`Answers.registeredQueries?`), since the
   library still parses with that registration's grammar, which ships no
   query of its own.
5. Declared and refused, and the service does not list the name: no tree.
   The buffer stays open as plain text.

It is applied to the language's tree, not a mode's: a mode with a tree of
its own naming a declared grammar gets the grammar but not the declared
queries. The same rule gives each injected language its tree, by grammar
name (`injectedTreeOf`, below).

## An injected language's tree (`injectedTreeOf`)

The highlighting of a buffer with injections gives each grammar the
library lists an injected language (`Editor/Highlight.lean`, step 7). The
dispatch hands it `injectedTreeOf`, which resolves the grammar's tree by
`treeOf` above: the tree is that of the first entry of the language table,
in precedence order (config's, then the compiled-in ones it did not
replace), whose tree names the grammar, or the bare tree of the grammar
when no entry names it, so a package grammar with no language entry still
gets its declared queries. So an undeclared grammar keeps the entry's tree
and the grammar's shipped queries under it; a declared, registered one
takes the queries read from its directory, the entry's own source winning;
and one with no answer yet, or refused and no longer listed, gives no
injected language. A buffer whose fences go plain while an answer is
pending gets them back when the job's command highlights again: the
dispatch then injects again into every other highlighted buffer too
(`Editor/Command/Dispatch.lean`, "Highlighting again").

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
before stays" when it did (and its buffers keep the queries read then:
case 4 above), and "its languages have no syntax tree"
otherwise; and ``grammar `<name>`: <file>: <FileError.describe>`` for a
query file that could not be read.

## Where an addition goes

| Addition | Where |
|---|---|
| Something more a declaration says | A field of `Language.Grammar`, a parameter of `declare`, `declarePerPlatform`, `defineGrammar` and `defineGrammarPerPlatform` (`Editor/Setup.lean`), and its check in `problem?` |
| A new platform name | A case of `platformOf`, pinned by `ModelTest.grammarDeclarationChecks` |
| A new form of where the library is | A constructor of `Library`, its case in `libraryOn`, `libraryProblem?` and `under` |
| A new rule for a package's relative path | `within?`, pinned by `ModelTest.grammarDeclarationChecks` |
| A new kind of query file | An entry of `queryFiles`, its field of `Queries` (`Editor/Language/Grammar/Answer.lean`) and its case in `Queries.over` |
| A new case of which tree a buffer gets | `treeOf`, pinned by `ModelTest.grammarDeclarationChecks` |
| A new case of which tree an injected language gets | `injectedTreeOf`, pinned by `ModelTest.grammarDeclarationChecks` |
| A new consequence of a refusal | `said` |

Pinned by `ModelTest.grammarDeclarationChecks` (the rules, pure).
-/

namespace Editor

/-- Where a declared grammar's native library is: one path on every
platform, or one path for each platform it supports, by the platform's name
(`Language.Grammar.platformOf`). -/
inductive Language.Grammar.Library where
  /-- One library, on every platform. -/
  | single (path : System.FilePath)
  /-- One library for each platform listed, by its name
  (`darwin-aarch64`); none on a platform not listed. -/
  | perPlatform (paths : List (String × System.FilePath))
  deriving DecidableEq, Repr

/-- A grammar config or a package declares: its name, where its library is
loaded from, the symbol and the policy it is registered with, and the
directory its queries are read from. -/
structure Language.Grammar where
  /-- The name it is declared under, which languages name. -/
  name : String
  /-- Its native library, on every platform or per platform. -/
  library : Language.Grammar.Library
  /-- The symbol the library exports its language under. -/
  symbol : String
  /-- The reparse policy it is registered with; `none` is `whole`. -/
  policy : Option ReparsePolicy := none
  /-- The directory its query files are read from. -/
  queries : System.FilePath
  deriving DecidableEq, Repr

namespace Language.Grammar

/-- The platform a Lean target triple names, `<os>-<arch>`:
`darwin-aarch64`, `darwin-x86_64`, `linux-aarch64` or `linux-x86_64`, the
names a per-platform declaration lists its libraries under; any other
triple is its own name. -/
def platformOf (target : String) : String :=
  let parts := target.splitOn "-"
  let arch : Option String :=
    match parts.head? with
    | some "arm64" | some "aarch64" => some "aarch64"
    | some "x86_64" => some "x86_64"
    | _ => none
  let os : Option String :=
    if parts.any (·.startsWith "darwin") then some "darwin"
    else if parts.contains "linux" then some "linux" else none
  match os, arch with
  | some os, some arch => s!"{os}-{arch}"
  | _, _ => target

/-- The platform this editor was built for (`platformOf` of Lean's
target triple): the one a registration picks a per-platform library for. -/
def currentPlatform : String :=
  platformOf System.Platform.target

/-- The symbol `tree_sitter_<name>`, the default of a declaration. -/
def defaultSymbol (name : String) : String :=
  s!"{GrammarSource.prefix}{name}"

/-- The declaration of the grammar `name` from `library`, with the
defaults of the module docs: the symbol `tree_sitter_<name>` and the query
directory `queries/` in the library's directory. -/
def declare (name : String) (library : System.FilePath) (symbol : Option String := none)
    (queries : Option System.FilePath := none) (policy : Option ReparsePolicy := none) :
    Language.Grammar :=
  { name, library := .single library, symbol := symbol.getD (defaultSymbol name), policy
    queries := queries.getD ((library.parent.getD ".") / "queries") }

/-- The declaration of the grammar `name` from one library for each
platform of `libraries`, each a platform's name and its library's path,
its queries read from `queries`, which has no default; the symbol defaults
to `tree_sitter_<name>`. -/
def declarePerPlatform (name : String) (libraries : List (String × System.FilePath))
    (queries : System.FilePath) (symbol : Option String := none)
    (policy : Option ReparsePolicy := none) : Language.Grammar :=
  { name, library := .perPlatform libraries, symbol := symbol.getD (defaultSymbol name), policy
    queries }

/-- The library `grammar` loads from on `platform`: its one library, or the
one it lists for `platform`; none when it lists none for it. -/
def libraryOn (grammar : Language.Grammar) (platform : String) : Option System.FilePath :=
  match grammar.library with
  | .single path => some path
  | .perPlatform paths => (paths.find? (·.1 == platform)).map (·.2)

/-- What `grammar` is registered from on `platform`: the library it loads
from there, its symbol and its policy; none when it declares no library for
`platform`. -/
def sourceOn (grammar : Language.Grammar) (platform : String) : Option GrammarSource :=
  (grammar.libraryOn platform).map fun library =>
    { library := library.toString, symbol := grammar.symbol, policy := grammar.policy }

/-- The name `grammar`'s symbol registers (`GrammarSource.name`). -/
def registers (grammar : Language.Grammar) : String :=
  ({ library := "", symbol := grammar.symbol } : GrammarSource).name

/-- Why a registration of `grammar` on `platform` is refused before the
service is asked: it declares no library for `platform`. -/
def noLibraryFor (platform : String) : String :=
  s!"it declares no library for the platform `{platform}`"

/-- The sentence of a declaration whose symbol registers another name. -/
def otherName (grammar : Language.Grammar) : String :=
  s!"the grammar `{grammar.name}`'s symbol `{grammar.symbol}` registers the grammar `{grammar.registers}`: a grammar is declared under the name its symbol registers"

/-- The sentence of a declaration whose library, `library`, is not an
absolute path. -/
def relativeLibrary (grammar : Language.Grammar) (library : System.FilePath) : String :=
  s!"the grammar `{grammar.name}`'s library `{library}` is not an absolute path"

/-- The sentence of a declaration whose query directory is not an absolute
path. -/
def relativeQueries (grammar : Language.Grammar) : String :=
  s!"the grammar `{grammar.name}`'s query directory `{grammar.queries}` is not an absolute path"

/-- The sentence of a per-platform declaration that lists no platform. -/
def noPlatform (grammar : Language.Grammar) : String :=
  s!"the grammar `{grammar.name}` declares a library for no platform"

/-- The sentence of a per-platform declaration that lists `platform` more
than once. -/
def platformTwice (grammar : Language.Grammar) (platform : String) : String :=
  s!"the grammar `{grammar.name}` declares a library for the platform `{platform}` twice"

/-- The sentence of a per-platform declaration whose library `library` for
`platform` is not an absolute path. -/
def relativePlatformLibrary (grammar : Language.Grammar) (platform : String)
    (library : System.FilePath) : String :=
  s!"the grammar `{grammar.name}`'s library `{library}` for the platform `{platform}` is not an absolute path"

/-- What is wrong with `grammar`'s library, as a sentence: a relative path;
for a per-platform one, no platform, a platform listed twice, or a relative
path; `none` when nothing is. -/
def libraryProblem? (grammar : Language.Grammar) : Option String :=
  match grammar.library with
  | .single path => if path.isAbsolute then none else some (grammar.relativeLibrary path)
  | .perPlatform [] => some grammar.noPlatform
  | .perPlatform paths =>
    let platforms := paths.map (·.1)
    match platforms.find? (fun platform => platforms.count platform > 1) with
    | some platform => some (grammar.platformTwice platform)
    | none =>
      (paths.find? (!·.2.isAbsolute)).map fun (platform, library) =>
        grammar.relativePlatformLibrary platform library

/-- What is wrong with `grammar`, as a sentence: a symbol that registers
another name, a problem of its library (`libraryProblem?`), or a relative
query directory; `none` when nothing is. -/
def problem? (grammar : Language.Grammar) : Option String :=
  if grammar.registers != grammar.name then some grammar.otherName
  else
    match grammar.libraryProblem? with
    | some problem => some problem
    | none => if !grammar.queries.isAbsolute then some grammar.relativeQueries else none

/-- `path` with its `.` and empty components dropped and each `..` taken
back, when it is relative and no `..` climbs out of the directory it is
relative to; `.` for a path that names that directory itself; none for an
absolute path or one that climbs out. -/
def within? (path : System.FilePath) : Option System.FilePath := do
  if path.isAbsolute then
    none
  let kept ←
    path.components.foldlM (init := ([] : List String)) fun kept component =>
        match component with
        | "" | "." => some kept
        | ".." => if kept.isEmpty then none else some kept.dropLast
        | other => some (kept ++ [other])
  return if kept.isEmpty then "." else System.FilePath.mk ("/".intercalate kept)

/-- `path` resolved against `directory`: `directory` itself for `.`. -/
def joinedUnder (directory path : System.FilePath) : System.FilePath :=
  if path.toString == "." then directory else directory / path

/-- `grammar`, whose library paths and query directory are relative to
`directory`, with each resolved against it; the offending path when one is
absolute or climbs out of `directory` (`within?`). -/
def under (directory : System.FilePath) (grammar : Language.Grammar) :
    Except System.FilePath Language.Grammar := do
  let resolve (path : System.FilePath) : Except System.FilePath System.FilePath :=
    match within? path with
    | some inside => .ok (joinedUnder directory inside)
    | none => .error path
  let library : Library ←
    match grammar.library with
    | .single path =>
      Library.single <$> resolve path
    | .perPlatform paths =>
      Library.perPlatform <$>
          paths.mapM fun (platform, path) => do
            pure (platform, ← resolve path)
  return { grammar with
      library, queries := ← resolve grammar.queries }

/-- The table of `later`'s declarations over `earlier`'s, by name
(`Language.overBy`): `later`'s, in order, then `earlier`'s that no
declaration of `later` names, in order. -/
def over (later earlier : List Language.Grammar) : List Language.Grammar :=
  Language.overBy (·.name) later earlier

/-- The query files read from a declared grammar's directory, each with the
kind it fills. -/
def queryFiles : List (String × QueryKind) :=
  [("highlights.scm", .highlights), ("injections.scm", .injections), ("indents.scm", .indents),
    ("textobjects.scm", .textObjects)]

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
    | some (.refused _ kept) =>
      if kept then
        some <|
          match answers.registeredQueries? tree.grammar with
          | some queries => queries.over tree
          | none => tree
      else none

/-- The tree an injected language of the grammar named `grammar` gets
(the module docs): `treeOf` over the tree of the first of `languages`, in
precedence order, whose tree names `grammar`, or the bare tree of `grammar`
when none does; `none` for a grammar that gives no injected language. -/
def injectedTreeOf (declared : List Language.Grammar) (answers : Answers) (generation : Nat)
    (languages : List Language) (grammar : String) : Option Mode.SyntaxTree :=
  treeOf declared answers generation
    (((languages.find? (·.syntaxTree.grammar == grammar)).map (·.syntaxTree)).getD { grammar })

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
