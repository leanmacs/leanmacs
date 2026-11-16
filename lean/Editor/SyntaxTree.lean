import Editor.Program
import Editor.Scene
import Editor.Text

/-!
# The syntax tree interface

What the editor asks of the library's syntax service: which grammars it has,
which text to parse with which grammar, and what a query captures in a range
of a text. It is a port like the others (`Editor/Program.lean`): a request,
a pure model (`Editor/SyntaxTree/Model.lean`), and a contract every
implementation is held to (`Editor/SyntaxTree/Contract.lean`).

It is named `SyntaxTree`, not `Syntax`, which every module that opens `Lean`
already has (`Lean.Syntax`), nor `Grammar`, which already names an input
scheme's key grammar (`Editor/InputScheme.lean`).

## The requests

- **`grammars`** answers the grammars the library has, by name.
- **`attach snapshot grammar`**: the text `snapshot` is of is parsed with
  `grammar` from now on, in the library and off the editor thread, in place
  of any grammar before. A text, not a snapshot: every later snapshot of the
  same document is answered from the same parse.
- **`detach snapshot`**: the text is not parsed any more.
- **`compile grammar source`** answers a query of `grammar`, by a
  `QueryId`, or why the source is not one.
- **`captureNames query`** answers its captures' names, in the order they
  first appear in its source; a `Capture` names one by its index here.
- **`captures snapshot query start stop`** answers the captures of `query`
  whose node is in the range from `start` to `stop` of the snapshot's text:
  each once, by start, the longer first, then by pattern and by capture. A
  node is in a range when it shares a byte with it, or, when the node or the
  range is empty, when the node starts within it, its ends included. Offsets
  are bytes, as everywhere at the boundary.
- **`release query`**: the query is not needed any more.
- **`shippedQuery grammar kind`** answers the source of the query of `kind`
  that `grammar` is published with (`QueryKind.highlights`: its
  `highlights.scm`). Each implementation ships its own: the library the
  grammar crate's, pinned with it, and the model one in its own query
  subset. A caller compares only that it compiles.
- **`highlight snapshot query faces`**: the text `snapshot` is of is drawn
  with `query`'s captures in `faces` from now on, one entry for each of its
  capture names, `none` for a capture that draws nothing, in place of any
  highlighter before. Highlights reach the display in the library, never
  through Lean; `detach`, and an attach with another grammar, drop them.

## Refusals

A refusal is a value: each reply is an `Except SyntaxTreeError`.

- `unknownGrammar`: no grammar of that name.
- `noSuchSnapshot`, `noSuchQuery`: the id names nothing.
- `noDocument`: the snapshot is of no document, so there is no text to keep
  parsing (a file's text as it was loaded).
- `notAttached`: the snapshot's text is not parsed.
- `notParsed`: the library has not yet delivered the tree of that
  snapshot's revision. The model never answers it: it parses at once. A
  caller treats it as "ask again after the next scene", never as an error.
- `wrongGrammar`: the query is of another grammar than the text is parsed
  with.
- `badRange`: the range is not two positions of the text in order.
- `query kind offset`: the source is not a query, for `kind`, found at the
  byte `offset` of the source. Offsets are each implementation's own; the
  kind is what a caller compares.
- `noShippedQuery`: the grammar is published with no query of that kind.
- `badFaces`: the faces are not one for each of the query's capture
  names.

## Scope

The port has a program type of its own, `SyntaxTreeM`, and is a sub-port
of the editor's port (`Editor/Command.lean`): a command and a major mode ask
it through `SyntaxTree.lift`, which hands a refusal back as a value. What
setting a major mode with a syntax asks of it is `Editor/Highlight.lean`'s.

## Where an addition goes

| Addition | Where |
|---|---|
| Something else asked of the syntax service | A constructor of `SyntaxTreeRequest`, its case in `SyntaxTreeRequest.Reply`, an operation here, its case in the model and in the real binding, and a property of the contract |
| A rule of what a range answers, or of the order | The model and a property of the contract, in one commit with the Rust core's rule (`crates/editor-syntax`, `query`) |
| A grammar the model knows | `Editor/SyntaxTree/Model.lean`; the library's grammars are its own (`crates/editor-syntax-treesitter`) |

Pinned by the contract, which `model-test` runs against the model and
`contract-test` against the real binding (`Editor/SyntaxTree/Real.lean`),
and by `ModelTest.syntaxTreeChecks` and `ContractTest.syntaxTreeChecks` for
what only one of them shows.
-/

namespace Editor

/-- Which of a grammar's own queries: the queries a grammar is published
with, each for one job. -/
inductive QueryKind where
  /-- What to draw in which face: `highlights.scm`. -/
  | highlights
  deriving DecidableEq, Repr

/-- The name of a compiled query the syntax service holds. It is plain data,
so a request can carry it. -/
structure QueryId where
  /-- Which query: the implementation's index for it. -/
  index : Nat
  deriving DecidableEq, Repr

/-- Why a query's source was refused. -/
inductive QueryErrorKind where
  /-- The source is not a query: a paren unclosed, a stray character. -/
  | syntax
  /-- It names a node kind the grammar does not have. -/
  | nodeType
  /-- It names a field the grammar does not have. -/
  | field
  /-- A predicate names a capture the pattern does not have. -/
  | capture
  /-- A predicate is malformed. -/
  | predicate
  /-- A pattern no tree of the grammar could match (the library's
  `Structure`). -/
  | shape
  /-- The grammar itself was refused. -/
  | language
  /-- Something the model does not implement (a quantifier, an alternation,
  an anchor, a negated field, a predicate), which the library would
  accept. Only the model answers it. -/
  | unsupported
  deriving DecidableEq, Repr

/-- Why the syntax service refused a request. -/
inductive SyntaxTreeError where
  /-- No grammar of that name. -/
  | unknownGrammar
  /-- The snapshot id names no snapshot. -/
  | noSuchSnapshot
  /-- The query id names no query, or one released. -/
  | noSuchQuery
  /-- The snapshot is of no document. -/
  | noDocument
  /-- The snapshot's text is not parsed. -/
  | notAttached
  /-- The tree of the snapshot's revision has not been delivered yet. -/
  | notParsed
  /-- The query is of another grammar than the text is parsed with. -/
  | wrongGrammar
  /-- The range is not two positions of the text in order. -/
  | badRange
  /-- The source is not a query, for `kind`, found at the byte `offset`. -/
  | query (kind : QueryErrorKind) (offset : Nat)
  /-- The grammar is published with no query of that kind. -/
  | noShippedQuery
  /-- The faces are not one for each of the query's capture names. -/
  | badFaces
  deriving DecidableEq, Repr

/-- The refusal, as words a user reads in the echo area. -/
def SyntaxTreeError.describe : SyntaxTreeError → String
  | .unknownGrammar => "no grammar of that name"
  | .noSuchSnapshot => "no such snapshot"
  | .noSuchQuery => "no such query"
  | .noDocument => "the text is of no document"
  | .notAttached => "the text is not parsed"
  | .notParsed => "the text is not parsed yet"
  | .wrongGrammar => "the query is of another grammar"
  | .badRange => "the range is not two positions in order"
  | .query kind offset => s!"the query is not one: {repr kind} at byte {offset}"
  | .noShippedQuery => "the grammar ships no such query"
  | .badFaces => "the faces are not one for each capture name"

namespace SyntaxTree

/-- One capture of a query's answer: which pattern matched, which of the
query's capture names it is, and the range of the node it captured. -/
structure Capture where
  /-- The index of the pattern that matched, in the query's source. -/
  pattern : Nat
  /-- The index of the capture's name among `captureNames`. -/
  capture : Nat
  /-- The offset the node starts at. -/
  start : Nat
  /-- The offset the node stops at, not included. -/
  stop : Nat
  deriving DecidableEq, Repr

end SyntaxTree

/-- What may be asked of the syntax service. -/
inductive SyntaxTreeRequest where
  /-- The grammars the service has. -/
  | grammars
  /-- Parse the text `snapshot` is of with `grammar` from now on. -/
  | attach (snapshot : SnapshotId) (grammar : String)
  /-- Stop parsing the text `snapshot` is of. -/
  | detach (snapshot : SnapshotId)
  /-- Compile `source` as a query of `grammar`. -/
  | compile (grammar source : String)
  /-- The names of `query`'s captures. -/
  | captureNames (query : QueryId)
  /-- The captures of `query` in the range from `start` to `stop` of
  `snapshot`'s text. -/
  | captures (snapshot : SnapshotId) (query : QueryId) (start stop : Nat)
  /-- `query` is not needed any more. -/
  | release (query : QueryId)
  /-- The source of the query of `kind` that `grammar` is published with. -/
  | shippedQuery (grammar : String) (kind : QueryKind)
  /-- Draw the text `snapshot` is of with `query`'s captures in `faces`,
  one for each capture name, from now on. -/
  | highlight (snapshot : SnapshotId) (query : QueryId) (faces : Array (Option FaceName))
  deriving DecidableEq, Repr

/-- The type of the reply to each request. -/
def SyntaxTreeRequest.Reply : SyntaxTreeRequest → Type
  | .grammars => Array String
  | .attach _ _ => Except SyntaxTreeError Unit
  | .detach _ => Except SyntaxTreeError Unit
  | .compile _ _ => Except SyntaxTreeError QueryId
  | .captureNames _ => Except SyntaxTreeError (Array String)
  | .captures _ _ _ _ => Except SyntaxTreeError (Array SyntaxTree.Capture)
  | .release _ => Unit
  | .shippedQuery _ _ => Except SyntaxTreeError String
  | .highlight _ _ _ => Except SyntaxTreeError Unit

/-- The syntax tree port: `SyntaxTreeRequest` and the reply to each request. -/
abbrev syntaxTreePort : Port :=
  { Request := SyntaxTreeRequest, Reply := SyntaxTreeRequest.Reply }

/-- A program over the syntax tree port that may be refused with a
`SyntaxTreeError`. -/
abbrev SyntaxTreeM :=
  ExceptT SyntaxTreeError (Program syntaxTreePort)

/-- An answerer of the syntax tree port's requests in `IO`: the real
binding. -/
abbrev SyntaxTreeHandler :=
  (request : SyntaxTreeRequest) → IO request.Reply

namespace SyntaxTree

/-- The grammars the service has, by name. -/
def grammars : SyntaxTreeM (Array String) :=
  ExceptT.lift (Program.request (port := syntaxTreePort) .grammars)

/-- Parse the text `snapshot` is of with `grammar` from now on, in place of
any grammar before. Refused with `unknownGrammar`, `noSuchSnapshot` or
`noDocument`. -/
def attach (snapshot : SnapshotId) (grammar : String) : SyntaxTreeM Unit :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.attach snapshot grammar))

/-- Stop parsing the text `snapshot` is of. Refused with `noSuchSnapshot`. -/
def detach (snapshot : SnapshotId) : SyntaxTreeM Unit :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.detach snapshot))

/-- `source` compiled as a query of `grammar`. Refused with `unknownGrammar`,
or with `query kind offset` for a source that is not a query. -/
def compile (grammar source : String) : SyntaxTreeM QueryId :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.compile grammar source))

/-- The names of `query`'s captures, in the order they first appear in its
source. Refused with `noSuchQuery`. -/
def captureNames (query : QueryId) : SyntaxTreeM (Array String) :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.captureNames query))

/-- The captures of `query` whose node is in the range from `start` to `stop`
of `snapshot`'s text, each once, by start, the longer first, then by pattern
and by capture. -/
def captures (snapshot : SnapshotId) (query : QueryId) (start stop : Nat) :
    SyntaxTreeM (Array Capture) :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.captures snapshot query start stop))

/-- `query` is not needed any more. -/
def release (query : QueryId) : SyntaxTreeM Unit :=
  ExceptT.lift (Program.request (port := syntaxTreePort) (.release query))

/-- The source of the query of `kind` that `grammar` is published with.
Refused with `unknownGrammar`, or `noShippedQuery` for a grammar published
with none of that kind. -/
def shippedQuery (grammar : String) (kind : QueryKind) : SyntaxTreeM String :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.shippedQuery grammar kind))

/-- Draw the text `snapshot` is of with `query`'s captures in `faces`, one
entry for each of its capture names (`none` draws nothing), from now on, in
place of any highlighter before. Refused, checked in this order, with
`noSuchSnapshot`, `noSuchQuery`, `notAttached`, `wrongGrammar` or
`badFaces`. -/
def highlight (snapshot : SnapshotId) (query : QueryId) (faces : Array (Option FaceName)) :
    SyntaxTreeM Unit :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.highlight snapshot query faces))

/-- Whether a node over `start`..`stop` is in the range `first`..`last`: it
shares a byte with it, or, when the node or the range is empty, it starts
within it, its ends included. The Rust core's `query::overlaps`. -/
def overlaps (start stop first last : Nat) : Bool :=
  if start == stop || first == last then first ≤ start && start ≤ last
  else start < last && first < stop

/-- Whether `a` comes before `b` in the core's order: by start, then the
longer first, then by pattern, then by capture. -/
def Capture.before (a b : Capture) : Bool :=
  if a.start != b.start then a.start < b.start
  else
    if a.stop != b.stop then a.stop > b.stop
    else if a.pattern != b.pattern then a.pattern < b.pattern else a.capture < b.capture

/-- `captures` in the core's order, each once. -/
def sorted (captures : Array Capture) : Array Capture :=
  (captures.qsort Capture.before).foldl
    (fun kept capture => if kept.back? == some capture then kept else kept.push capture) #[]

end SyntaxTree

/-- The handler of a run with no syntax service handed in: it has no
grammars, so an attach and a compile are refused with `unknownGrammar`, as
is a shipped query; it holds no query, so a question of one is refused with
`noSuchQuery`; and a detach and a release do nothing. What a command run
where no host handed one in reaches (`EditorM.runReal`,
`Editor/Command/Real.lean`). -/
def SyntaxTree.none : SyntaxTreeHandler
  | .grammars => pure #[]
  | .attach _ _ => pure (.error .unknownGrammar)
  | .detach _ => pure (.ok ())
  | .compile _ _ => pure (.error .unknownGrammar)
  | .captureNames _ => pure (.error .noSuchQuery)
  | .captures _ _ _ _ => pure (.error .noSuchQuery)
  | .release _ => pure ()
  | .shippedQuery _ _ => pure (.error .unknownGrammar)
  | .highlight _ _ _ => pure (.error .noSuchQuery)

/-- Runs a syntax tree program against `handler`: its result, or the refusal
it failed with. -/
def SyntaxTreeM.runWith {α : Type} (program : SyntaxTreeM α) (handler : SyntaxTreeHandler) :
    IO (Except SyntaxTreeError α) :=
  Program.runM (port := syntaxTreePort) handler program.run

end Editor
