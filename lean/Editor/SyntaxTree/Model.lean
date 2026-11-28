import Editor.SyntaxTree.Model.Query
import Editor.SyntaxTree.Registration.Model

/-!
# The syntax tree interface's model

A pure model of the syntax tree interface (`Editor/SyntaxTree.lean`). It
knows one grammar of its own, `json` (`Editor/SyntaxTree/Model/Json.lean`),
under each name registered at run time (`registry`), and compiles in
none, as the library compiles in none; and the
subset of the query language that `Editor/SyntaxTree/Model/Query.lean`
states, and it parses at once: a question of captures is answered of the
snapshot's own text, so the model answers `notParsed` only when a test
says its trees are not delivered (`delivered`).

Its state has three parts:

- `texts`: the snapshots it knows and the text of each, which a runner
  fills, as `DisplayModel.texts` is. Every one is of a document, so the
  model never answers `noDocument`.
- `attached`: the snapshots whose text is parsed, each with its grammar.
  The library parses the document behind a snapshot, so every snapshot of
  one document shares its parse. Here two snapshots are of one text when
  `documents`, which a runner fills, says so (`sameText`); a snapshot it
  says nothing of is a text of its own, as in the contract's runs.
- `queries`: the queries compiled, by id, each with its grammar; `none`
  once released.
- `highlighted`: the highlighter of each snapshot that has one, its query
  and its faces, as `highlight` set it: a later one replaces it, and
  `detach` drops it. It is what the editor's checks read
  (`ModelTest.highlightEnterChecks`); the model draws nothing.
- `injected` and `languages`: the injections query of each snapshot that
  has one, and each language `injectLanguage` gave it, by name, as they were
  set; `detach` drops them. The model parses no layer and draws nothing:
  they are what the editor's checks read.
- `kept`: the query each snapshot keeps of each kind, compiled, so it
  outlives its id's release; `detach` drops them. `capturesOf` answers its
  captures as `captures` answers a query's, of the snapshot's own text.
- `refreshAfter`: the refresh delay it was handed last. It parses at once,
  so every tree is exact and the delay changes no answer; it is what the
  editor's checks read.
- `registry`: the grammars registered at run time
  (`Editor/SyntaxTree/Registration/Model.lean`), empty by default. The model
  kits (`withTestGrammars`) hold `GrammarRegistry.testGrammars`, the six
  names the core's tests register from the cargo-built directory. The model
  lists the registered names alone, attaches and compiles for each, and
  parses its texts as JSON, the one grammar it has; it ships no query for
  any (`shippedQuery` answers `noShippedQuery` for a listed name and
  `unknownGrammar` otherwise), as the library ships none: every grammar it
  lists was registered from a library. A test sets it; in a
  driven run, the registry the job model's registrations end with is
  handed to it (the job's model answers a registration,
  `JobModel.grammars`).
- `once`: canned answers of `parseOnce`, by host grammar and source, for
  a grammar the model cannot parse (Markdown): each is answered as stored,
  whatever the languages hold. A test of a rendered view sets them from the
  checked-in fixtures (`tests/markdown/`), which the contract holds to the
  library's answers (`ContractTest.markdownCaseChecks`). For a grammar it
  lists the model computes `parseOnce`: the host layer alone, answered with
  the query of the first language handed in that names the host, compiled
  in its subset. It parses JSON only and follows no injections, so a
  language's injections are never read and no layer below the host is
  found.
- `delivered`: whether the tree of each text's last edit is delivered. It
  starts `true`. A test sets it `false` to see what a command does when
  keys come faster than a reparse: `captures` and `capturesOf` are then
  refused with `notParsed`, after every check the real binding makes
  before it, as the clipboard model is taken away
  (`ClipboardModel.available`).

Its highlights query (`highlights`) is a query of JSON in its own subset:
the library's JSON one uses an alternation, which the model refuses as
unsupported. It ships it for no grammar; a check of a registered `json`
that draws hands its language this query as the tree's `highlights`, as a
grammar's own query would be handed.

A request is checked in the order the real binding checks it: the
snapshot and the query ids first, then whether the text is attached, the
query's grammar, and the range.

Pinned by the contract (`Editor/SyntaxTree/Contract.lean`), which
`model-test` runs against it, and by `ModelTest.syntaxTreeChecks` for what
only the model shows.
-/

namespace Editor

/-- The model's state. -/
structure SyntaxTreeModel where
  /-- The snapshots it knows, each with its text. -/
  texts : Array (SnapshotId × String) := #[]
  /-- The text each snapshot is of, by a number of the runner's, for the
  snapshots the runner knows that of; a snapshot not here is a text of its
  own. -/
  documents : Array (SnapshotId × Nat) := #[]
  /-- The snapshots whose text is parsed, each with its grammar. -/
  attached : Array (SnapshotId × String) := #[]
  /-- The queries compiled, by id, each with its grammar; `none` once
  released. -/
  queries : Array (Option (String × SyntaxTreeModel.Query)) := #[]
  /-- The highlighter of each snapshot that has one: its query and its
  faces. -/
  highlighted : Array (SnapshotId × QueryId × Array (Option FaceName)) := #[]
  /-- The injections query of each snapshot that has one. -/
  injected : Array (SnapshotId × QueryId) := #[]
  /-- The languages each snapshot's injections may name, as
  `injectLanguage` gave them: the name, the highlights query, its faces and
  the injections query, if any. -/
  languages : Array (SnapshotId × String × QueryId × Array (Option FaceName) × Option QueryId) :=
    #[]
  /-- The query each snapshot keeps of each kind, compiled. -/
  kept : Array (SnapshotId × QueryKind × SyntaxTreeModel.Query) := #[]
  /-- The refresh delay `refreshAfter` handed it last, if any. The model
  parses at once, so it changes nothing it answers. -/
  refreshAfter : Option Nat := none
  /-- The grammars registered at run time: listed, attached and compiled
  for, parsed as JSON, and shipping no query. -/
  registry : GrammarRegistry := {}
  /-- Whether the tree of each text's last edit is delivered: when `false`,
  a question of captures is refused with `notParsed` after its other
  checks. -/
  delivered : Bool := true
  /-- The canned answers of `parseOnce`, by host grammar and source, each
  answered as stored. -/
  once : Array (String × String × Array SyntaxTree.Layer) := #[]

namespace SyntaxTreeModel

/-- The one grammar the model knows. -/
def grammar : String :=
  "json"

/-- The model the kits hold by default: the test grammars registered
(`GrammarRegistry.testGrammars`). -/
def withTestGrammars : SyntaxTreeModel :=
  { registry := GrammarRegistry.testGrammars }

/-- A highlights query of JSON in the model's own query subset, which a
check hands a tree as its own; the model ships it for no grammar. -/
def highlights : String :=
  "(pair key: (_) @string.special.key)\n(string) @string\n(number) @number\n(null) @constant.builtin\n(true) @constant.builtin\n(false) @constant.builtin\n"

/-- The grammars the model lists: each registered name, as it compiles in
none. -/
def grammars (model : SyntaxTreeModel) : Array String :=
  model.registry.grammars #[]

/-- Whether the model lists `named`. -/
def knows (model : SyntaxTreeModel) (named : String) : Bool :=
  model.grammars.contains named

/-- The text of `snapshot`, if the model knows it. -/
def text? (model : SyntaxTreeModel) (snapshot : SnapshotId) : Option String :=
  (model.texts.find? (·.1 == snapshot)).map (·.2)

/-- Whether the snapshots `a` and `b` are of one text: they are the same
snapshot, or `documents` names one text for both. -/
def sameText (model : SyntaxTreeModel) (a b : SnapshotId) : Bool :=
  let document (snapshot : SnapshotId) := (model.documents.find? (·.1 == snapshot)).map (·.2)
  a == b || (document a).isSome && document a == document b

/-- The grammar `snapshot`'s text is parsed with, if it is attached. -/
def attachedTo? (model : SyntaxTreeModel) (snapshot : SnapshotId) : Option String :=
  (model.attached.find? (model.sameText ·.1 snapshot)).map (·.2)

/-- The query `query` names, with its grammar, if it is compiled and not
released. -/
def query? (model : SyntaxTreeModel) (query : QueryId) : Option (String × Query) :=
  (model.queries[query.index]?).join

/-- Whether `offset` is a position of `text`: a character boundary within
it, its end included. -/
def isPosition (text : String) (offset : Nat) : Bool :=
  offset == text.utf8ByteSize ||
    (text.toList.foldl (fun (here, found) char => (here + char.utf8Size, found || here == offset))
        (0, false)).2

/-- `attach`. -/
def attach (model : SyntaxTreeModel) (snapshot : SnapshotId) (named : String) :
    Except SyntaxTreeError Unit × SyntaxTreeModel :=
  if (model.text? snapshot).isNone then (.error .noSuchSnapshot, model)
  else
    if !model.knows named then (.error .unknownGrammar, model)
    else
      let others := model.attached.filter (!model.sameText ·.1 snapshot)
      (.ok (), { model with attached := others.push (snapshot, named) })

/-- `detach`: the highlighter goes with the parse. -/
def detach (model : SyntaxTreeModel) (snapshot : SnapshotId) :
    Except SyntaxTreeError Unit × SyntaxTreeModel :=
  if (model.text? snapshot).isNone then (.error .noSuchSnapshot, model)
  else
    (.ok (),
      { model with
        attached := model.attached.filter (!model.sameText ·.1 snapshot)
        highlighted := model.highlighted.filter (!model.sameText ·.1 snapshot)
        injected := model.injected.filter (!model.sameText ·.1 snapshot)
        languages := model.languages.filter (!model.sameText ·.1 snapshot)
        kept := model.kept.filter (!model.sameText ·.1 snapshot) })

/-- `shippedQuery`: no query of any kind for a listed name, every one of
which is registered, and `unknownGrammar` for any other. -/
def shippedQuery (model : SyntaxTreeModel) (named : String) (_kind : QueryKind) :
    Except SyntaxTreeError String :=
  if model.knows named then .error .noShippedQuery else .error .unknownGrammar

/-- The query `query` names, of the grammar `snapshot`'s text is parsed
with: checked in the order the real binding checks it, the snapshot and
the query ids first, then whether the text is attached and the query's
grammar. -/
def queryOfText (model : SyntaxTreeModel) (snapshot : SnapshotId) (query : QueryId) :
    Except SyntaxTreeError Query := do
  if (model.text? snapshot).isNone then
    throw .noSuchSnapshot
  let some (queryGrammar, compiled) := model.query? query | throw .noSuchQuery
  let some textGrammar := model.attachedTo? snapshot | throw .notAttached
  if queryGrammar != textGrammar then
    throw .wrongGrammar
  return compiled

/-- `inject`. -/
def inject (model : SyntaxTreeModel) (snapshot : SnapshotId) (query : QueryId) :
    Except SyntaxTreeError Unit × SyntaxTreeModel :=
  match model.queryOfText snapshot query with
  | .error refusal => (.error refusal, model)
  | .ok _ =>
    (.ok (),
      { model with
        injected := (model.injected.filter (!model.sameText ·.1 snapshot)).push (snapshot, query) })

/-- `injectLanguage`, checked in the order the real binding checks it. -/
def injectLanguage (model : SyntaxTreeModel) (snapshot : SnapshotId) (name : String)
    (highlights : QueryId) (faces : Array (Option FaceName)) (injections : Option QueryId) :
    Except SyntaxTreeError Unit × SyntaxTreeModel :=
  let checked : Except SyntaxTreeError Unit := do
    if (model.text? snapshot).isNone then
      throw .noSuchSnapshot
    let some (highlightsGrammar, compiled) := model.query? highlights | throw .noSuchQuery
    let injectionsGrammar ←
      match injections with
      | none =>
        pure none
      | some query =>
        match model.query? query with
        | some (queryGrammar, _) =>
          pure (some queryGrammar)
        | none =>
          throw .noSuchQuery
    if (model.attachedTo? snapshot).isNone then
      throw .notAttached
    if injectionsGrammar.any (· != highlightsGrammar) then
      throw .wrongGrammar
    if faces.size != compiled.names.size then
      throw .badFaces
  match checked with
  | .error refusal => (.error refusal, model)
  | .ok () =>
    let others :=
      model.languages.filter fun (other, named, _) =>
        !(model.sameText other snapshot && named == name)
    (.ok (),
      { model with languages := others.push (snapshot, name, highlights, faces, injections) })

/-- `keep`. -/
def keep (model : SyntaxTreeModel) (snapshot : SnapshotId) (kind : QueryKind) (query : QueryId) :
    Except SyntaxTreeError Unit × SyntaxTreeModel :=
  match model.queryOfText snapshot query with
  | .error refusal => (.error refusal, model)
  | .ok compiled =>
    let others :=
      model.kept.filter fun (other, held, _) => !(model.sameText other snapshot && held == kind)
    (.ok (), { model with kept := others.push (snapshot, kind, compiled) })

/-- `capturesOf`, checked in the order the real binding checks it. -/
def capturesOf (model : SyntaxTreeModel) (snapshot : SnapshotId) (kind : QueryKind)
    (first last : Nat) : Except SyntaxTreeError SyntaxTree.Kept := do
  let some text := model.text? snapshot | throw .noSuchSnapshot
  if (model.attachedTo? snapshot).isNone then
    throw .notAttached
  let some (_, _, compiled) :=
    model.kept.find? fun (other, held, _) => model.sameText other snapshot && held == kind
    | throw .noQuery
  unless first ≤ last && isPosition text first && isPosition text last do
    throw .badRange
  unless model.delivered do
    throw .notParsed
  return { names := compiled.names, captures := compiled.captures (Json.parse text) first last }

/-- `highlight`, checked in the order the real binding checks it. -/
def highlight (model : SyntaxTreeModel) (snapshot : SnapshotId) (query : QueryId)
    (faces : Array (Option FaceName)) : Except SyntaxTreeError Unit × SyntaxTreeModel :=
  let checked : Except SyntaxTreeError Unit := do
    if (model.text? snapshot).isNone then
      throw .noSuchSnapshot
    let some (queryGrammar, compiled) := model.query? query | throw .noSuchQuery
    let some textGrammar := model.attachedTo? snapshot | throw .notAttached
    if queryGrammar != textGrammar then
      throw .wrongGrammar
    if faces.size != compiled.names.size then
      throw .badFaces
  match checked with
  | .error refusal => (.error refusal, model)
  | .ok () =>
    (.ok (),
      { model with
        highlighted :=
          (model.highlighted.filter (!model.sameText ·.1 snapshot)).push (snapshot, query, faces) })

/-- `compile`. -/
def compile (model : SyntaxTreeModel) (named source : String) :
    Except SyntaxTreeError QueryId × SyntaxTreeModel :=
  if !model.knows named then (.error .unknownGrammar, model)
  else
    match Query.compile source with
    | .error (kind, offset) => (.error (.query kind offset), model)
    | .ok query =>
      (.ok ⟨model.queries.size⟩, { model with queries := model.queries.push (some (named, query)) })

/-- `captures`. -/
def captures (model : SyntaxTreeModel) (snapshot : SnapshotId) (query : QueryId)
    (first last : Nat) : Except SyntaxTreeError (Array SyntaxTree.Capture) := do
  let some text := model.text? snapshot | throw .noSuchSnapshot
  let some (queryGrammar, compiled) := model.query? query | throw .noSuchQuery
  let some textGrammar := model.attachedTo? snapshot | throw .notAttached
  if queryGrammar != textGrammar then
    throw .wrongGrammar
  unless first ≤ last && isPosition text first && isPosition text last do
    throw .badRange
  unless model.delivered do
    throw .notParsed
  return compiled.captures (Json.parse text) first last

/-- `parseOnce`: a canned answer as stored; else, for a grammar the model
lists, the host layer over the whole text answered with the query of the
first of `languages` that names the host, compiled in the model's subset,
checked in the order the real binding checks: the host grammar first
(`unknownGrammar`), then its language and its query (`noQuery`). The model
follows no injections, so the host layer is the answer. -/
def parseOnce (model : SyntaxTreeModel) (source named : String)
    (languages : Array SyntaxTree.OnceLanguage) :
    Except SyntaxTreeError (Array SyntaxTree.Layer) := do
  if let some (_, _, layers) :=
      model.once.find? fun (grammar, text, _) => grammar == named && text == source then
    return layers
  if !model.knows named then
    throw .unknownGrammar
  let some language := languages.find? (·.grammar == named) | throw .noQuery
  match Query.compile language.query with
  | .error _ =>
    throw .noQuery
  | .ok compiled =>
    let stop := source.utf8ByteSize
    return #[{
          language := named, depth := 0, ranges := #[(0, stop)], names := compiled.names
          captures := compiled.captures (Json.parse source) 0 stop }]

/-- Answers `request` from the model as it is. -/
def handle : (request : SyntaxTreeRequest) → SyntaxTreeModel → request.Reply × SyntaxTreeModel
  | .grammars, model => (model.grammars, model)
  | .attach snapshot named, model => model.attach snapshot named
  | .detach snapshot, model => model.detach snapshot
  | .compile named source, model => model.compile named source
  | .captureNames query, model =>
    (match model.query? query with
      | some (_, compiled) => .ok compiled.names
      | none => .error .noSuchQuery,
      model)
  | .captures snapshot query first last, model => (model.captures snapshot query first last, model)
  | .release query, model =>
    ((), { model with queries := model.queries.modify query.index fun _ => none })
  | .shippedQuery named kind, model => (model.shippedQuery named kind, model)
  | .highlight snapshot query faces, model => model.highlight snapshot query faces
  | .inject snapshot query, model => model.inject snapshot query
  | .injectLanguage snapshot name highlights faces injections, model =>
    model.injectLanguage snapshot name highlights faces injections
  | .keep snapshot kind query, model => model.keep snapshot kind query
  | .capturesOf snapshot kind first last, model =>
    (model.capturesOf snapshot kind first last, model)
  | .refreshAfter milliseconds, model => ((), { model with refreshAfter := some milliseconds })
  | .parseOnce source named languages, model =>
    (model.parseOnce source named languages, model)

end SyntaxTreeModel

/-- Runs a syntax tree program against the model `model`: its result, or the
refusal it failed with, and the model after its last request. -/
def SyntaxTreeM.runModel {α : Type} (program : SyntaxTreeM α) (model : SyntaxTreeModel) :
    Except SyntaxTreeError α × SyntaxTreeModel :=
  Program.run (port := syntaxTreePort) SyntaxTreeModel.handle program.run model

end Editor
