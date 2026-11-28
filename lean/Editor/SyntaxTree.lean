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
  `highlights.scm`; `injections`, `textObjects`, `indents`). Each
  implementation ships its own: the library the grammar crate's, pinned
  with it, or its own where the crate ships none, and the model its
  highlights alone, in its own query subset. A caller compares only that it
  compiles.
- **`highlight snapshot query faces`**: the text `snapshot` is of is drawn
  with `query`'s captures in `faces` from now on, one entry for each of its
  capture names, `none` for a capture that draws nothing, in place of any
  highlighter before. Highlights reach the display in the library, never
  through Lean; `detach`, and an attach with another grammar, drop them.
- **`inject snapshot query`**: the text finds its injections with `query`,
  a query of its grammar, from now on: text of another language held in a
  node of its own (a fenced block in Markdown), each parsed as a layer and
  drawn over the text's own highlights, in the library.
- **`injectLanguage snapshot name highlights faces injections`**: an
  injection of the language `name` is parsed with `highlights`' grammar,
  drawn with its captures in `faces`, as `highlight` draws, and finds
  injections of its own with `injections`, if given, a query of the same
  grammar.
- **`keep snapshot kind query`**: the text keeps `query`, a query of its
  grammar, as its query of `kind`, in place of any before. A text keeps one
  of each kind, so a question names a kind, not a query, and the query may
  be released.
- **`capturesOf snapshot kind start stop`** answers the capture names of the
  query the text keeps of `kind` and its captures in the range, as
  `captures` answers them (`Kept`).
- **`parseOnce source grammar kinds`** answers the layers of `source`,
  a text handed in, not one a snapshot is of, parsed once, whole, with
  `grammar`: the host first, at depth 0 over the whole text, then each
  layer its grammar's injections find, down to the library's bound, by
  depth and then by start. Each pair of `kinds` is a language known, by
  its grammar's name, answered with that grammar's shipped query of the
  kind; a layer is answered with its query's capture names and its
  captures over the hull of its ranges (`Layer`). A pair whose grammar
  the service lacks, or that ships no such query, is not a language
  known, and its layers are not found. A host asked with `rendered` finds
  its layers with the grammar's rendered injections, where it ships them
  (Markdown's: each table cell is an inline layer too). It keeps nothing
  and is answered on the asking thread: what a rendered view of a
  generated text asks (`Editor/Markdown/Parse.lean`). It is refused
  `unknownGrammar` for a host grammar the service lacks, and
  `noShippedQuery` when `kinds` does not name the host, or names it with a
  kind it does not ship.
- **`refreshAfter milliseconds`**: texts parsed incrementally are parsed
  whole once they have gone `milliseconds` unchanged after an edit, from
  now on, for every text. An edit's tree is the incremental reparse, which
  while the text has an error may differ from a fresh parse; the whole
  parse once the text is quiet makes it exact, and is delivered only when
  it differs. It changes no answer of the port: the model records it.

`detach`, and an attach with another grammar, drop the injections, the
languages and the kept queries with the highlighter.

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
- `noQuery`: the text keeps no query of that kind.

A structural question (`capturesOf`) before the reparse of its snapshot is
delivered is refused with `notParsed`, never answered from an older tree:
an indent level or a text object of a tree that lacks the latest edit would
be wrong, not stale.

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
  /-- Which nodes hold text of another language: `injections.scm`. -/
  | injections
  /-- Which nodes are a function, a class or an argument, around and
  inside: `textobjects.scm`. -/
  | textObjects
  /-- Which nodes indent the rows they hold: `indents.scm`. -/
  | indents
  /-- Which nodes a rendered view reads: its blocks, its spans and the
  markup it leaves out: `rendered.scm`. -/
  | rendered
  deriving DecidableEq, Repr

/-- The kind's name, as a user reads it: `highlights`, `injections`,
`textObjects`, `indents`, `rendered`. -/
def QueryKind.name : QueryKind → String
  | .highlights => "highlights"
  | .injections => "injections"
  | .textObjects => "textObjects"
  | .indents => "indents"
  | .rendered => "rendered"

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
  /-- The text keeps no query of that kind. -/
  | noQuery
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
  | .noQuery => "the text keeps no query of that kind"

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

/-- What a question of a kept query answers: the query's capture names,
which a capture names one of by its index, and its captures in the
range. -/
structure Kept where
  /-- The capture names, in the order they first appear in the source. -/
  names : Array String
  /-- The captures, each once, in the order `captures` answers. -/
  captures : Array Capture
  deriving DecidableEq, Repr

/-- A layer of a text parsed once (`parseOnce`), the host included: its
language, how deep it is, the ranges of the text it is of, and its
language's query's capture names and its captures over them. -/
structure Layer where
  /-- The language's name, as the pair that named it gave it. -/
  language : String
  /-- How deep it is: 0 for the host, 1 for an injection of the host's. -/
  depth : Nat
  /-- The ranges of the text it is of, each a start and a stop, sorted and
  apart. -/
  ranges : Array (Nat × Nat)
  /-- Its query's capture names, which a capture names one of by its
  index. -/
  names : Array String
  /-- Its query's captures over the hull of its ranges, each once, in the
  order `captures` answers. -/
  captures : Array Capture
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
  /-- Find the injections of the text `snapshot` is of with `query` from
  now on. -/
  | inject (snapshot : SnapshotId) (query : QueryId)
  /-- Parse an injection of the language `name` with `highlights`' grammar,
  draw it with its captures in `faces`, and find injections of its own with
  `injections`, from now on. -/
  |
  injectLanguage (snapshot : SnapshotId) (name : String) (highlights : QueryId)
    (faces : Array (Option FaceName)) (injections : Option QueryId)
  /-- Keep `query` as the text's query of `kind`. -/
  | keep (snapshot : SnapshotId) (kind : QueryKind) (query : QueryId)
  /-- The capture names of the query the text keeps of `kind`, and its
  captures in the range from `start` to `stop`. -/
  | capturesOf (snapshot : SnapshotId) (kind : QueryKind) (start stop : Nat)
  /-- Parse a text whole once it has gone `milliseconds` unchanged after an
  edit, from now on, for every text. -/
  | refreshAfter (milliseconds : Nat)
  /-- The layers of `source` parsed once with `grammar`, each language a
  pair of `kinds` names answered with its grammar's shipped query of the
  kind. -/
  | parseOnce (source grammar : String) (kinds : Array (String × QueryKind))
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
  | .inject _ _ => Except SyntaxTreeError Unit
  | .injectLanguage _ _ _ _ _ => Except SyntaxTreeError Unit
  | .keep _ _ _ => Except SyntaxTreeError Unit
  | .capturesOf _ _ _ _ => Except SyntaxTreeError SyntaxTree.Kept
  | .refreshAfter _ => Unit
  | .parseOnce _ _ _ => Except SyntaxTreeError (Array SyntaxTree.Layer)

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

/-- Find the injections of the text `snapshot` is of with `query`, a query of
its grammar, from now on. Refused, checked in this order, with
`noSuchSnapshot`, `noSuchQuery`, `notAttached` or `wrongGrammar`. -/
def inject (snapshot : SnapshotId) (query : QueryId) : SyntaxTreeM Unit :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.inject snapshot query))

/-- Parse an injection of the language `name` in the text `snapshot` is of
with `highlights`' grammar, draw it with its captures in `faces`, one entry
for each of its capture names, and find injections of its own with
`injections`, a query of the same grammar, from now on. Refused, checked in
this order, with `noSuchSnapshot`, `noSuchQuery`, `notAttached`,
`wrongGrammar` (the injections query is of another grammar than the
highlights query) or `badFaces`. -/
def injectLanguage (snapshot : SnapshotId) (name : String) (highlights : QueryId)
    (faces : Array (Option FaceName)) (injections : Option QueryId) : SyntaxTreeM Unit :=
  ExceptT.mk
    (Program.request (port := syntaxTreePort)
      (.injectLanguage snapshot name highlights faces injections))

/-- Keep `query`, a query of the text's grammar, as the text's query of
`kind`, in place of any before. Refused, checked in this order, with
`noSuchSnapshot`, `noSuchQuery`, `notAttached` or `wrongGrammar`. -/
def keep (snapshot : SnapshotId) (kind : QueryKind) (query : QueryId) : SyntaxTreeM Unit :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.keep snapshot kind query))

/-- The capture names of the query the text `snapshot` is of keeps of
`kind`, and its captures in the range from `start` to `stop`, in the order
`captures` answers. Refused, checked in this order, with `noSuchSnapshot`,
`notAttached`, `noQuery`, `badRange` or `notParsed`. -/
def capturesOf (snapshot : SnapshotId) (kind : QueryKind) (start stop : Nat) : SyntaxTreeM Kept :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.capturesOf snapshot kind start stop))

/-- Texts parsed incrementally are parsed whole once they have gone
`milliseconds` unchanged after an edit, from now on, for every text. Never
refused. -/
def refreshAfter (milliseconds : Nat) : SyntaxTreeM Unit :=
  ExceptT.lift (Program.request (port := syntaxTreePort) (.refreshAfter milliseconds))

/-- The layers of `source` parsed once, whole, with `grammar`: the host
first, then each layer by depth and start, each language a pair of `kinds`
names answered with its grammar's shipped query of the kind ("The
requests", in the module docs). It keeps nothing and is answered on the
asking thread. Refused with `unknownGrammar` for a host grammar the service
lacks, and `noShippedQuery` when `kinds` does not name the host, or names
it with a kind it does not ship. -/
def parseOnce (source grammar : String) (kinds : Array (String × QueryKind)) :
    SyntaxTreeM (Array Layer) :=
  ExceptT.mk (Program.request (port := syntaxTreePort) (.parseOnce source grammar kinds))

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
is a shipped query; it holds no query, so a question of one, an injection, a
language, a keep and a question of a kept query are refused with
`noSuchQuery`; a text parsed once is refused with `unknownGrammar`; and a
detach, a release and a refresh delay do nothing. What a command run
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
  | .inject _ _ => pure (.error .noSuchQuery)
  | .injectLanguage _ _ _ _ _ => pure (.error .noSuchQuery)
  | .keep _ _ _ => pure (.error .noSuchQuery)
  | .capturesOf _ _ _ _ => pure (.error .noSuchQuery)
  | .refreshAfter _ => pure ()
  | .parseOnce _ _ _ => pure (.error .unknownGrammar)

/-- Runs a syntax tree program against `handler`: its result, or the refusal
it failed with. -/
def SyntaxTreeM.runWith {α : Type} (program : SyntaxTreeM α) (handler : SyntaxTreeHandler) :
    IO (Except SyntaxTreeError α) :=
  Program.runM (port := syntaxTreePort) handler program.run

end Editor
