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
- `attached`: the snapshots whose text is parsed, each with its grammar. A
  snapshot is its own text here; the library parses the document behind
  it, so every snapshot of one document shares its parse.
- `queries`: the queries compiled, by id, each with its grammar; `none`
  once released.

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
  /-- The snapshots whose text is parsed, each with its grammar. -/
  attached : Array (SnapshotId × String) := #[]
  /-- The queries compiled, by id, each with its grammar; `none` once
  released. -/
  queries : Array (Option (String × SyntaxTreeModel.Query)) := #[]

namespace SyntaxTreeModel

/-- The one grammar the model knows. -/
def grammar : String :=
  "json"

/-- The text of `snapshot`, if the model knows it. -/
def text? (model : SyntaxTreeModel) (snapshot : SnapshotId) : Option String :=
  (model.texts.find? (·.1 == snapshot)).map (·.2)

/-- The grammar `snapshot`'s text is parsed with, if it is attached. -/
def attachedTo? (model : SyntaxTreeModel) (snapshot : SnapshotId) : Option String :=
  (model.attached.find? (·.1 == snapshot)).map (·.2)

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
      let others := model.attached.filter (·.1 != snapshot)
      (.ok (), { model with attached := others.push (snapshot, named) })

/-- `detach`. -/
def detach (model : SyntaxTreeModel) (snapshot : SnapshotId) :
    Except SyntaxTreeError Unit × SyntaxTreeModel :=
  if (model.text? snapshot).isNone then (.error .noSuchSnapshot, model)
  else (.ok (), { model with attached := model.attached.filter (·.1 != snapshot) })

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

end SyntaxTreeModel

/-- Runs a syntax tree program against the model `model`: its result, or the
refusal it failed with, and the model after its last request. -/
def SyntaxTreeM.runModel {α : Type} (program : SyntaxTreeM α) (model : SyntaxTreeModel) :
    Except SyntaxTreeError α × SyntaxTreeModel :=
  Program.run (port := syntaxTreePort) SyntaxTreeModel.handle program.run model

end Editor
