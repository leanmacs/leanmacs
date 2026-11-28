import Editor.RealHost
import Editor.SyntaxTree
import Editor.Text.Real

/-!
# The real binding of the syntax tree interface

The syntax tree interface (`Editor/SyntaxTree.lean`) answered by the Rust
library's syntax service (`crates/editor-ffi`, `src/syntax.rs`): tree-sitter,
with the grammars registered on it at run time and none compiled in
(`crates/editor-syntax-treesitter`), parsing
each attached document on a worker thread of its own and reparsing it from
its edit log after each edit.

It needs the read half of the text binding's table of snapshots
(`SnapshotReader`): a request names its text by a `SnapshotId`, which the
table turns into the library's snapshot, and the library reaches the
document behind it through the snapshot itself. It keeps a table of its own,
of the queries it has compiled, by `QueryId`: a slot is `none` once its
query is released, so an id is never used again, and the library frees the
query when the last reference to its handle goes.

- A snapshot the table does not hold is refused here with
  `noSuchSnapshot`, and a query id this binding did not give out, or one
  released, with `noSuchQuery`; everything else is the library's to refuse.
- Each request is one call of the library's (`Ffi.syntax*`,
  `Ffi.SyntaxQuery.*`). A status the library answers is turned into the
  port's refusal one for one, and a refusal's kind crosses as the library's
  tag. A worker thread the library could not start is an `IO` error: no
  refusal of the port says it.
- Offsets are `Nat` here and machine words in the library: one no word
  holds is sent as the largest word, past the end of every text, so it is
  refused and never cut down. A refresh delay no `UInt64` holds is sent as
  the largest one.
- A face crosses as its name, and `none` as the empty string, which is no
  face's name: `some ⟨""⟩` crosses as `none` does. A kind crosses as its
  tag (`kindTag`).
- **`parseOnce` is answered in the call**, on the asking thread: the
  library parses the text handed in, which no snapshot is of, and keeps
  nothing but the queries it compiled from the sources handed in, each by
  its grammar, the source the grammar was registered from and its own
  source (`Syntaxes::once_query`, `crates/editor-ffi/src/syntax.rs`), so a
  grammar registered again never meets a query compiled for the old one.
- **`captures` and `capturesOf` never wait for a parse.** Each is answered
  from the tree the library last delivered, and refused with `notParsed`
  when that tree is not of the snapshot's revision. A caller asks again
  later; `contract-test`'s runner waits for the delivery first
  (`Ffi.syntaxSettle`). `capturesOf` is two calls, the kept query's
  captures and then its names, both answered on the editor thread, where
  nothing keeps another query between them.

This module adds no decision: each request is one call. It imports
`Editor.Ffi`, so only an executable linked with the library imports it.
`contract-test` holds it to the syntax tree interface's contract
(`Editor/SyntaxTree/Contract.lean`), the list `model-test` holds the model
to.
-/

namespace Editor

/-- The real binding: the read half of the text binding's table of
snapshots, and the queries it has compiled. -/
structure RealSyntaxTree where
  /-- The table a request's snapshot is found in. -/
  snapshots : SnapshotReader
  /-- The library's handle of each query compiled, in the order they were,
  each with its grammar; `none` once released. -/
  queries : IO.Ref (Array (Option Ffi.SyntaxQuery))

namespace RealSyntaxTree

/-- The mark of `new`: it runs a real background service (`Editor/RealHost.lean`). -/
def new.realHost : RealHost :=
  .service

/-- A binding over `snapshots`, with no query compiled. -/
def new (snapshots : SnapshotReader) : BaseIO RealSyntaxTree :=
  return { snapshots, queries := ← IO.mkRef #[] }

/-- The library's machine word for an offset of the port: one no word holds
is the largest, past the end of every text. -/
def offset (number : Nat) : USize :=
  if number < USize.size then number.toUSize else (USize.size - 1).toUSize

/-- The kind of a refusal the library tags `tag`. -/
def kindOf (tag : UInt64) : QueryErrorKind :=
  match tag with
  | 0 => .syntax
  | 1 => .nodeType
  | 2 => .field
  | 3 => .capture
  | 4 => .predicate
  | 5 => .shape
  | _ => .language

/-- The library's tag of a kind of query. -/
def kindTag : QueryKind → UInt8
  | .highlights => 0
  | .injections => 1
  | .textObjects => 2
  | .indents => 3
  | .rendered => 4
  | .renderedInjections => 5

/-- The port's refusal of a question of a kept query, from the library's. -/
def keptRefusal : Ffi.SyntaxKeptRefusal → SyntaxTreeError
  | .notAttached => .notAttached
  | .noQuery => .noQuery
  | .badRange => .badRange
  | .notParsed => .notParsed

/-- The library's handle of the query `query`, if this binding gave it out
and it is not released. -/
def query? (real : RealSyntaxTree) (query : QueryId) : BaseIO (Option Ffi.SyntaxQuery) :=
  return ((← real.queries.get)[query.index]?).join

/-- Answers `request` with one call of the library's. -/
def handle (real : RealSyntaxTree) : SyntaxTreeHandler
  | .grammars => Ffi.syntaxGrammars
  | .attach snapshot grammar => do
    let some found ← real.snapshots.find? snapshot | return .error .noSuchSnapshot
    match ← Ffi.syntaxAttach found grammar with
    | .ok () =>
      return .ok ()
    | .error .unknownGrammar =>
      return .error .unknownGrammar
    | .error .noDocument =>
      return .error .noDocument
    | .error .noWorker =>
      throw (IO.userError "the library could not start its syntax worker")
  | .detach snapshot => do
    let some found ← real.snapshots.find? snapshot | return .error .noSuchSnapshot
    discard (Ffi.syntaxDetach found)
    return .ok ()
  | .compile grammar source => do
    match ← Ffi.SyntaxQuery.new grammar source with
    | .ok made =>
      let id ← real.queries.modifyGet fun queries => (⟨queries.size⟩, queries.push (some made))
      return .ok id
    | .error .unknownGrammar =>
      return .error .unknownGrammar
    | .error (.refused kind offset) =>
      return .error (.query (kindOf kind) offset.toNat)
  | .captureNames query => do
    let some found ← real.query? query | return .error .noSuchQuery
    return .ok (← found.captureNames)
  | .captures snapshot query start stop => do
    let some text ← real.snapshots.find? snapshot | return .error .noSuchSnapshot
    let some found ← real.query? query | return .error .noSuchQuery
    return match ← Ffi.syntaxCaptures text found (offset start) (offset stop) with
      | .ok captures =>
        .ok <|
          captures.map fun capture =>
            { pattern := capture.pattern.toNat, capture := capture.capture.toNat,
              start := capture.start.toNat, stop := capture.stop.toNat }
      | .error .notAttached => .error .notAttached
      | .error .notParsed => .error .notParsed
      | .error .wrongGrammar => .error .wrongGrammar
      | .error .badRange => .error .badRange
  | .release query => real.queries.modify fun queries => queries.setIfInBounds query.index none
  | .shippedQuery grammar kind => do
    return match ← Ffi.syntaxShippedQuery grammar (kindTag kind) with
      | .ok source => .ok source
      | .error .unknownGrammar => .error .unknownGrammar
      | .error .noShippedQuery => .error .noShippedQuery
  | .highlight snapshot query faces => do
    let some text ← real.snapshots.find? snapshot | return .error .noSuchSnapshot
    let some found ← real.query? query | return .error .noSuchQuery
    let names := faces.map fun face => (face.map (·.name)).getD ""
    return match ← Ffi.syntaxHighlight text found names with
      | .ok () => .ok ()
      | .error .notAttached => .error .notAttached
      | .error .wrongGrammar => .error .wrongGrammar
      | .error .badFaces => .error .badFaces
  | .inject snapshot query => do
    let some text ← real.snapshots.find? snapshot | return .error .noSuchSnapshot
    let some found ← real.query? query | return .error .noSuchQuery
    return match ← Ffi.syntaxInject text found with
      | .ok () => .ok ()
      | .error .notAttached => .error .notAttached
      | .error .wrongGrammar => .error .wrongGrammar
  | .injectLanguage snapshot name highlights faces injections => do
    let some text ← real.snapshots.find? snapshot | return .error .noSuchSnapshot
    let some found ← real.query? highlights | return .error .noSuchQuery
    let own ←
      match injections with
      | none =>
        pure none
      | some query =>
        match ← real.query? query with
        | some own =>
          pure (some own)
        | none =>
          return .error .noSuchQuery
    let names := faces.map fun face => (face.map (·.name)).getD ""
    return match ← Ffi.syntaxInjectLanguage text name found names own with
      | .ok () => .ok ()
      | .error .notAttached => .error .notAttached
      | .error .wrongGrammar => .error .wrongGrammar
      | .error .badFaces => .error .badFaces
  | .keep snapshot kind query => do
    let some text ← real.snapshots.find? snapshot | return .error .noSuchSnapshot
    let some found ← real.query? query | return .error .noSuchQuery
    return match ← Ffi.syntaxKeep text (kindTag kind) found with
      | .ok () => .ok ()
      | .error .notAttached => .error .notAttached
      | .error .wrongGrammar => .error .wrongGrammar
  | .refreshAfter milliseconds =>
    Ffi.syntaxRefreshAfter
      (if milliseconds < UInt64.size then milliseconds.toUInt64 else UInt64.ofNat (UInt64.size - 1))
  | .parseOnce source grammar languages => do
    return match
        ←
          Ffi.syntaxParseOnce source grammar
              (languages.map fun language =>
                (language.grammar, language.query, language.injections.getD "")) with
      | .ok layers =>
        .ok <|
          layers.map fun layer =>
            { language := layer.language, depth := layer.depth.toNat
              ranges := layer.ranges.map fun (start, stop) => (start.toNat, stop.toNat)
              names := layer.names
              captures :=
                layer.captures.map fun capture =>
                  { pattern := capture.pattern.toNat, capture := capture.capture.toNat,
                    start := capture.start.toNat, stop := capture.stop.toNat } }
      | .error .unknownGrammar => .error .unknownGrammar
      | .error .noHostQuery => .error .noQuery
  | .capturesOf snapshot kind start stop => do
    let some text ← real.snapshots.find? snapshot | return .error .noSuchSnapshot
    match ← Ffi.syntaxKeptCaptures text (kindTag kind) (offset start) (offset stop) with
    | .error refusal =>
      return .error (keptRefusal refusal)
    | .ok captures =>
      match ← Ffi.syntaxKeptNames text (kindTag kind) with
      | .error refusal =>
        return .error (keptRefusal refusal)
      | .ok names =>
        return .ok
            { names
              captures :=
                captures.map fun capture =>
                  { pattern := capture.pattern.toNat, capture := capture.capture.toNat,
                    start := capture.start.toNat, stop := capture.stop.toNat } }

end RealSyntaxTree

end Editor
