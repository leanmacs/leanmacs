import Editor.SyntaxTree.Model.Query

/-!
# The syntax tree interface's model

A pure model of the syntax tree interface (`Editor/SyntaxTree.lean`). It
knows one grammar, `json` (`Editor/SyntaxTree/Model/Json.lean`), and the
subset of the query language that `Editor/SyntaxTree/Model/Query.lean`
states, and it parses at once: a question of captures is answered of the
snapshot's own text, so the model never answers `notParsed`.

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

Its shipped highlights query (`highlights`) is its own, in its query subset:
the library's JSON one uses an alternation, which the model refuses as
unsupported. Each implementation's source is its own, and the contract
compares only that it compiles. It ships no query of another kind, as the
library ships none for `json`.

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

namespace SyntaxTreeModel

/-- The one grammar the model knows. -/
def grammar : String :=
  "json"

/-- The highlights query the model ships for `json`, in its own query
subset. -/
def highlights : String :=
  "(pair key: (_) @string.special.key)\n(string) @string\n(number) @number\n(null) @constant.builtin\n(true) @constant.builtin\n(false) @constant.builtin\n"

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
    if named != grammar then (.error .unknownGrammar, model)
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

/-- `shippedQuery`: highlights alone. -/
def shippedQuery (named : String) (kind : QueryKind) : Except SyntaxTreeError String :=
  if named != grammar then .error .unknownGrammar
  else if kind == .highlights then .ok highlights else .error .noShippedQuery

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
  if named != grammar then (.error .unknownGrammar, model)
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
  return compiled.captures (Json.parse text) first last

/-- Answers `request` from the model as it is. -/
def handle : (request : SyntaxTreeRequest) → SyntaxTreeModel → request.Reply × SyntaxTreeModel
  | .grammars, model => (#[grammar], model)
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
  | .shippedQuery named kind, model => (shippedQuery named kind, model)
  | .highlight snapshot query faces, model => model.highlight snapshot query faces
  | .inject snapshot query, model => model.inject snapshot query
  | .injectLanguage snapshot name highlights faces injections, model =>
    model.injectLanguage snapshot name highlights faces injections
  | .keep snapshot kind query, model => model.keep snapshot kind query
  | .capturesOf snapshot kind first last, model =>
    (model.capturesOf snapshot kind first last, model)

end SyntaxTreeModel

/-- Runs a syntax tree program against the model `model`: its result, or the
refusal it failed with, and the model after its last request. -/
def SyntaxTreeM.runModel {α : Type} (program : SyntaxTreeM α) (model : SyntaxTreeModel) :
    Except SyntaxTreeError α × SyntaxTreeModel :=
  Program.run (port := syntaxTreePort) SyntaxTreeModel.handle program.run model

end Editor
