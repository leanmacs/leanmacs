import Editor.Bound
import Editor.Ffi.Snapshot
import Editor.Ffi.Words
import Editor.InferredWait

/-!
# Bindings: the syntax service

The bindings of `crates/editor-ffi/src/syntax.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("The syntax service").
-/

namespace Editor.Ffi

open Words

/-- The type behind `SyntaxQuery`. It is opaque, so the only way to get a
query is `SyntaxQuery.new`. -/
opaque SyntaxQueryPointed : NonemptyType

/-- A query of the library's syntax service (`crates/editor-ffi`,
`src/syntax.rs`), compiled for one grammar: a handle. -/
def SyntaxQuery : Type :=
  SyntaxQueryPointed.type

instance : Nonempty SyntaxQuery :=
  SyntaxQueryPointed.property

/-- A list of strings as the glue builds it in one call: words, the count
and then the byte length of each, and one string of all of them end to end.
Object fields only, so the order here is the layout the glue writes. -/
private structure RawStrings where
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- Every string end to end, copied from the library's buffer. -/
  text : String

/-- The strings `raw` holds, or `none` when its words do not spell a list of
them: a count and that many lengths, which add up to the text and end
between characters. -/
private def RawStrings.strings? (raw : RawStrings) : Option (Array String) := do
  let words ← wordsOf? raw.words
  let count := (← words[0]?).toNat
  guard (words.size == 1 + count)
  let bytes := raw.text.toUTF8
  let (strings, stop) ←
    (words.extract 1 words.size).foldlM
        (fun (strings, start) length => do
          let stop := start + length.toNat
          guard (stop ≤ bytes.size)
          let string ← String.fromUTF8? (bytes.extract start stop)
          return (strings.push string, stop))
        (#[], 0)
  guard (stop == bytes.size)
  return strings

/-- `syntaxGrammars` as it crosses. -/
@[extern "editor_glue_syntax_grammars"]
private opaque syntaxGrammarsRaw : IO RawStrings

/-- The grammars the library's syntax service has, by name. Words that do
not spell a list of strings mean the decoder here is wrong: an `IO`
error. -/
def syntaxGrammars : IO (Array String) := do
  let some names := (← syntaxGrammarsRaw).strings?
    | throw (IO.userError "the library's words do not spell a list of grammars")
  return names

/-- Why the syntax service did not attach a document. -/
inductive SyntaxAttachRefusal where
  /-- No grammar of that name. -/
  | unknownGrammar
  /-- The snapshot is of no document, or its document is gone. -/
  | noDocument
  /-- The library could not start its worker thread. -/
  | noWorker
  deriving DecidableEq, Repr

/-- `syntaxAttach` as it crosses: 0 attached, 1 unknown grammar, 2 no
document, 3 no worker. -/
@[extern "editor_glue_syntax_attach"]
private opaque syntaxAttachRaw (snapshot : @& Snapshot) (grammar : @& String) : IO UInt64

/-- Has the library's syntax service parse the document `snapshot` is of
with `grammar` from now on, off the editor thread, in place of any grammar
before. A status the library has no word for is an `IO` error. -/
def syntaxAttach (snapshot : Snapshot) (grammar : String) : IO (Except SyntaxAttachRefusal Unit) :=
  do
  match ← syntaxAttachRaw snapshot grammar with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .unknownGrammar
  | 2 =>
    return .error .noDocument
  | 3 =>
    return .error .noWorker
  | status =>
    throw (IO.userError s!"the library answered an attach with the status {status}")

/-- Stops the syntax service parsing the document `snapshot` is of, and
returns whether it was parsing it. -/
@[extern "editor_glue_syntax_detach"]
opaque syntaxDetach (snapshot : @& Snapshot) : IO Bool

/-- Why a query was not made. -/
inductive SyntaxQueryRefusal where
  /-- No grammar of that name. -/
  | unknownGrammar
  /-- The source is not a query: the library's tag of why (0 syntax, 1 node
  type, 2 field, 3 capture, 4 predicate, 5 structure, 6 language), and the
  byte offset into the source where it found it. -/
  | refused (kind offset : UInt64)
  deriving DecidableEq, Repr

/-- A query made, as the glue builds it in one call: the handle, if made,
first, then the status, the kind and the offset. -/
private structure RawSyntaxQuery where
  /-- The handle, when made. -/
  query : Option SyntaxQuery
  /-- 0 made, 1 unknown grammar, 2 refused. -/
  status : UInt64
  /-- For a refusal, the tag of why. -/
  kind : UInt64
  /-- For a refusal, the byte offset where it was found. -/
  offset : UInt64

/-- `SyntaxQuery.new` as it crosses. -/
@[extern "editor_glue_syntax_query_new"]
private opaque SyntaxQuery.newRaw (grammar : @& String) (source : @& String) : IO RawSyntaxQuery

/-- `source` compiled as a query of `grammar`, or why not. A record the
library could not have filled is an `IO` error. -/
def SyntaxQuery.new (grammar source : String) : IO (Except SyntaxQueryRefusal SyntaxQuery) := do
  let raw ← SyntaxQuery.newRaw grammar source
  match raw.status, raw.query with
  | 0, some query =>
    return .ok query
  | 1, none =>
    return .error .unknownGrammar
  | 2, none =>
    return .error (.refused raw.kind raw.offset)
  | status, _ =>
    throw (IO.userError s!"the library answered a query with the status {status}")

/-- `SyntaxQuery.captureNames` as it crosses. -/
@[extern "editor_glue_syntax_capture_names"]
private opaque SyntaxQuery.captureNamesRaw (query : @& SyntaxQuery) : IO RawStrings

/-- The names of the query's captures, in the order they first appear in its
source. -/
def SyntaxQuery.captureNames (query : SyntaxQuery) : IO (Array String) := do
  let some names := (← query.captureNamesRaw).strings?
    | throw (IO.userError "the library's words do not spell a list of capture names")
  return names

/-- How many queries the library holds that have not been freed. -/
@[extern "editor_glue_syntax_query_live"]
opaque SyntaxQuery.live : IO UInt64

/-- One capture, as the library answers it: its pattern, its capture's index
among the query's names, and the range of its node. -/
structure SyntaxCapture where
  /-- The index of the pattern that matched. -/
  pattern : UInt64
  /-- The index of the capture's name. -/
  capture : UInt64
  /-- The offset its node starts at. -/
  start : UInt64
  /-- The offset its node stops at. -/
  stop : UInt64
  deriving DecidableEq, Repr

/-- Why the syntax service did not answer a question of captures. -/
inductive SyntaxCapturesRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- No tree of the snapshot's revision has been delivered yet. -/
  | notParsed
  /-- The query is of another grammar than the document is parsed with. -/
  | wrongGrammar
  /-- The range is not two positions of the snapshot's text in order. -/
  | badRange
  deriving DecidableEq, Repr

/-- The captures `words` spell: the count, then four words each. `none`
unless the count is the count of captures there. -/
private def capturesOf? (words : Array UInt64) : Option (Array SyntaxCapture) := do
  let count := (← words[0]?).toNat
  guard (words.size == 1 + 4 * count)
  return (Array.range count).map fun index =>
      { pattern := words[1 + 4 * index]!, capture := words[2 + 4 * index]!,
        start := words[3 + 4 * index]!, stop := words[4 + 4 * index]! }

/-- `syntaxCaptures` as it crosses: the captures as words with the status
0, or no words and the status of the refusal (1 not attached, 2 not
parsed, 3 wrong grammar, 4 bad range). -/
@[extern "editor_glue_syntax_captures"]
private opaque syntaxCapturesRaw (snapshot : @& Snapshot) (query : @& SyntaxQuery)
    (start stop : USize) : IO RawWords

/-- The captures of `query` whose node is in the range from `start` to
`stop` of `snapshot`'s text, each once, by start, the longer first, then by
pattern and by capture: answered at once from the tree the library last
delivered of the snapshot's document, and refused as `notParsed` when that
tree is not of the snapshot's revision. It never waits for a parse. A status
or words the decoder here cannot read are an `IO` error. -/
def syntaxCaptures (snapshot : Snapshot) (query : SyntaxQuery) (start stop : USize) :
    IO (Except SyntaxCapturesRefusal (Array SyntaxCapture)) := do
  let raw ← syntaxCapturesRaw snapshot query start stop
  match raw.status with
  | 0 =>
    match (wordsOf? raw.words).bind capturesOf? with
    | some captures =>
      return .ok captures
    | none =>
      throw (IO.userError "the library's words do not spell captures")
  | 1 =>
    return .error .notAttached
  | 2 =>
    return .error .notParsed
  | 3 =>
    return .error .wrongGrammar
  | 4 =>
    return .error .badRange
  | status =>
    throw (IO.userError s!"the library answered captures with the status {status}")

/-- Why the library shipped no query. -/
inductive SyntaxShippedRefusal where
  /-- No grammar of that name. -/
  | unknownGrammar
  /-- The grammar is published with no query of that kind. -/
  | noShippedQuery
  deriving DecidableEq, Repr

/-- A shipped query as the glue builds it in one call: the source, empty
for a refusal, then the status. -/
private structure RawShipped where
  /-- The source, copied from the library's buffer. -/
  source : String
  /-- 0 shipped, 1 unknown grammar, 2 no such query. -/
  status : UInt64

/-- `syntaxShippedQuery` as it crosses. -/
@[extern "editor_glue_syntax_shipped_query"]
private opaque syntaxShippedQueryRaw (grammar : @& String) (kind : UInt8) : IO RawShipped

/-- The source of the query of the kind `kind` tags (0, highlights) that
`grammar` is published with, or why not. A status the library has no word
for is an `IO` error. -/
def syntaxShippedQuery (grammar : String) (kind : UInt8) :
    IO (Except SyntaxShippedRefusal String) := do
  let raw ← syntaxShippedQueryRaw grammar kind
  match raw.status with
  | 0 =>
    return .ok raw.source
  | 1 =>
    return .error .unknownGrammar
  | 2 =>
    return .error .noShippedQuery
  | status =>
    throw (IO.userError s!"the library answered a shipped query with the status {status}")

/-- Asks the library's syntax service to register the grammar `symbol`
hands out in the native library at `library`, with the policy the tag
`policy` names (0 none declared, 1 incremental, 2 whole), as the request
`id`, and returns whether it was accepted. It returns at once; the
registration is answered on the syntax worker's thread, and the completion
is a `completion` event on the completion queue, from the library source 6,
whose code is `id`. The answer is then taken with `grammarsTake`. `false`,
with nothing started, for an id in use, an unknown tag, or a worker that
could not start. -/
@[extern "editor_glue_grammars_start"]
opaque grammarsStart (id : UInt64) (library symbol : @& String) (policy : UInt8) : IO Bool

/-- Why the library registered no grammar under a take: its five refusals,
one for one, and two of the service's. -/
inductive GrammarTakeRefusal where
  /-- No file is at the library's path. -/
  | notFound
  /-- The file is not a library this platform can open. -/
  | notLoadable
  /-- The grammar is of an ABI the parsing library does not speak. -/
  | unsupportedAbi
  /-- The library exports no such symbol. -/
  | missingSymbol
  /-- The syntax service loads no grammar at run time. -/
  | unsupported
  /-- The service keeps no answer for the id. -/
  | noAnswer
  /-- The syntax worker ended before it answered. -/
  | dropped
  deriving DecidableEq, Repr

/-- A registration's answer as the glue builds it in one call: the name,
empty for a refusal, then the status. -/
private structure RawRegistered where
  /-- The registered name, copied from the library's buffer. -/
  name : String
  /-- 0 registered; 1 to 5 the refusals, in `GrammarTakeRefusal`'s order;
  6 no answer; 7 dropped. -/
  status : UInt64

/-- `grammarsTake` as it crosses. -/
@[extern "editor_glue_grammars_take"]
private opaque grammarsTakeRaw (id : UInt64) : IO RawRegistered

/-- The answer a take's `status` says, with `name` the name lent beside it:
the statuses of `GrammarStatus` in `crates/editor-ffi/src/grammars.rs`, 0
registered, 1 to 5 the refusals in `GrammarTakeRefusal`'s order, 6 no answer
and 7 dropped; `none` for a status the library has no word for. -/
def grammarTakeOf (status : UInt64) (name : String) : Option (Except GrammarTakeRefusal String) :=
  match status with
  | 0 => some (.ok name)
  | 1 => some (.error .notFound)
  | 2 => some (.error .notLoadable)
  | 3 => some (.error .unsupportedAbi)
  | 4 => some (.error .missingSymbol)
  | 5 => some (.error .unsupported)
  | 6 => some (.error .noAnswer)
  | 7 => some (.error .dropped)
  | _ => none

/-- Hands over the answer of the registration `id`, once: the registered
name, or why not (`grammarTakeOf`). A status the library has no word for is
an `IO` error. -/
def grammarsTake (id : UInt64) : IO (Except GrammarTakeRefusal String) := do
  let raw ← grammarsTakeRaw id
  match grammarTakeOf raw.status raw.name with
  | some answer =>
    return answer
  | none =>
    throw (IO.userError s!"the library answered a registration with the status {raw.status}")

/-- Withdraws the registration wait `id`, and returns whether there was
anything to withdraw: its answer is dropped and never completed, though a
registration already queued is still worked. Safe for an id that is
unknown. -/
@[extern "editor_glue_grammars_cancel"]
opaque grammarsCancel (id : UInt64) : IO Bool

/-- Asks for the request `id` to be completed once every registration started
before this call has been answered, and returns whether it was accepted. It
returns at once and keeps no answer. -/
@[extern "editor_glue_grammars_flush"]
opaque grammarsFlush (id : UInt64) : IO Bool

/-- `grammarsPending` is an inferred wait (`Editor/InferredWait.lean`): a
real service's count, allowed in the real grammar service's adapter and in
the job contracts that hold it. -/
def grammarsPending.inferredWait : InferredWait :=
  .count [`Editor.Job.Real, `Editor.Job.Contract, `Editor.Job.FlushContract]

/-- How many registration waits are not completed, and how many answers are
not taken, together. A readout for tests. -/
@[extern "editor_glue_grammars_pending"]
opaque grammarsPending : IO UInt64

/-- Why the library did not highlight a document. -/
inductive SyntaxHighlightRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- The query is of another grammar than the document is parsed with. -/
  | wrongGrammar
  /-- The faces are not one for each of the query's capture names. -/
  | badFaces
  deriving DecidableEq, Repr

/-- `syntaxHighlight` as it crosses: the faces as words and one string, and
the status (0 highlighted, 1 not attached, 2 wrong grammar, 3 bad faces). -/
@[extern "editor_glue_syntax_highlight"]
private opaque syntaxHighlightRaw (snapshot : @& Snapshot) (query : @& SyntaxQuery)
    (words : @& ByteArray) (strings : @& String) : IO UInt64

/-- Has the library draw the document `snapshot` is of with `query`'s
captures in `faces`, one for each capture name, from now on, the empty
string for a capture that draws nothing. A status the library has no word
for is an `IO` error. -/
def syntaxHighlight (snapshot : Snapshot) (query : SyntaxQuery) (faces : Array String) :
    IO (Except SyntaxHighlightRefusal Unit) := do
  match ← syntaxHighlightRaw snapshot query (lengthWords faces) (faces.foldl (· ++ ·) "") with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .notAttached
  | 2 =>
    return .error .wrongGrammar
  | 3 =>
    return .error .badFaces
  | status =>
    throw (IO.userError s!"the library answered a highlight with the status {status}")

/-- Why the library did not take an injections query. -/
inductive SyntaxInjectRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- The query is of another grammar than the document is parsed with. -/
  | wrongGrammar
  deriving DecidableEq, Repr

/-- `syntaxInject` as it crosses: the status (0 injected, 1 not attached, 2
wrong grammar). -/
@[extern "editor_glue_syntax_inject"]
private opaque syntaxInjectRaw (snapshot : @& Snapshot) (query : @& SyntaxQuery) : IO UInt64

/-- Has the library find the injections of the document `snapshot` is of
with `query` from its next round on. A status the library has no word for
is an `IO` error. -/
def syntaxInject (snapshot : Snapshot) (query : SyntaxQuery) :
    IO (Except SyntaxInjectRefusal Unit) := do
  match ← syntaxInjectRaw snapshot query with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .notAttached
  | 2 =>
    return .error .wrongGrammar
  | status =>
    throw (IO.userError s!"the library answered an injection with the status {status}")

/-- Why the library did not take a language for injections. -/
inductive SyntaxInjectLanguageRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- The injections query is of another grammar than the highlights
  query. -/
  | wrongGrammar
  /-- The faces are not one for each of the highlights query's capture
  names. -/
  | badFaces
  deriving DecidableEq, Repr

/-- `syntaxInjectLanguage` as it crosses: the name, the highlights query,
its faces as words and one string, and the injections query or none; the
status (0 injected, 1 not attached, 2 wrong grammar, 3 bad faces). -/
@[extern "editor_glue_syntax_inject_language"]
private opaque syntaxInjectLanguageRaw (snapshot : @& Snapshot) (name : @& String)
    (highlights : @& SyntaxQuery) (words : @& ByteArray) (strings : @& String)
    (injections : @& Option SyntaxQuery) : IO UInt64

/-- Has the library parse an injection of the language `name` in the
document `snapshot` is of with `highlights`' grammar, draw it with its
captures in `faces` (one for each capture name, the empty string for none),
and find injections of its own with `injections`, from its next round on. A
status the library has no word for is an `IO` error. -/
def syntaxInjectLanguage (snapshot : Snapshot) (name : String) (highlights : SyntaxQuery)
    (faces : Array String) (injections : Option SyntaxQuery) :
    IO (Except SyntaxInjectLanguageRefusal Unit) := do
  let faceWords := lengthWords faces
  let strings := faces.foldl (· ++ ·) ""
  match ← syntaxInjectLanguageRaw snapshot name highlights faceWords strings injections with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .notAttached
  | 2 =>
    return .error .wrongGrammar
  | 3 =>
    return .error .badFaces
  | status =>
    throw (IO.userError s!"the library answered a language with the status {status}")

/-- Why the library did not keep a query. -/
inductive SyntaxKeepRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- The query is of another grammar than the document is parsed with. -/
  | wrongGrammar
  deriving DecidableEq, Repr

/-- `syntaxKeep` as it crosses: the kind as its tag, and the status (0
kept, 1 not attached, 2 wrong grammar, 3 no such kind). -/
@[extern "editor_glue_syntax_keep"]
private opaque syntaxKeepRaw (snapshot : @& Snapshot) (kind : UInt8) (query : @& SyntaxQuery) :
    IO UInt64

/-- Has the document `snapshot` is of keep `query` as its query of the kind
`kind` tags (0 highlights, 1 injections, 2 text objects, 3 indents). A kind
the library has no tag for, or a status it has no word for, is an `IO`
error. -/
def syntaxKeep (snapshot : Snapshot) (kind : UInt8) (query : SyntaxQuery) :
    IO (Except SyntaxKeepRefusal Unit) := do
  match ← syntaxKeepRaw snapshot kind query with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .notAttached
  | 2 =>
    return .error .wrongGrammar
  | status =>
    throw (IO.userError s!"the library answered a keep with the status {status}")

/-- Why the library did not answer a question of a kept query. -/
inductive SyntaxKeptRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- The document keeps no query of that kind. -/
  | noQuery
  /-- The range is not two positions of the snapshot's text in order. -/
  | badRange
  /-- No tree of the snapshot's revision has been delivered yet. -/
  | notParsed
  deriving DecidableEq, Repr

/-- The refusal a kept query's status says, or `none` for a status the
library has no word for (1 not attached, 2 no query, 3 bad range, 4 not
parsed). -/
private def keptRefusal? : UInt64 → Option SyntaxKeptRefusal
  | 1 => some .notAttached
  | 2 => some .noQuery
  | 3 => some .badRange
  | 4 => some .notParsed
  | _ => none

/-- A kept query's names as the glue builds them in one call: the names,
none for a refusal, then the status. -/
private structure RawKeptNames where
  /-- The names. -/
  names : RawStrings
  /-- 0 answered, or the refusal's status. -/
  status : UInt64

/-- `syntaxKeptNames` as it crosses. -/
@[extern "editor_glue_syntax_kept_names"]
private opaque syntaxKeptNamesRaw (snapshot : @& Snapshot) (kind : UInt8) : IO RawKeptNames

/-- The capture names of the query the document `snapshot` is of keeps of
the kind `kind` tags, or why not. A status or words the decoder here cannot
read are an `IO` error. -/
def syntaxKeptNames (snapshot : Snapshot) (kind : UInt8) :
    IO (Except SyntaxKeptRefusal (Array String)) := do
  let raw ← syntaxKeptNamesRaw snapshot kind
  if raw.status == 0 then
    let some names := raw.names.strings?
      | throw (IO.userError "the library's words do not spell a list of capture names")
    return .ok names
  match keptRefusal? raw.status with
  | some refusal =>
    return .error refusal
  | none =>
    throw (IO.userError s!"the library answered kept names with the status {raw.status}")

/-- `syntaxKeptCaptures` as it crosses: the captures as words with the
status 0, or no words and the refusal's status. -/
@[extern "editor_glue_syntax_kept_captures"]
private opaque syntaxKeptCapturesRaw (snapshot : @& Snapshot) (kind : UInt8) (start stop : USize) :
    IO RawWords

/-- The captures of the query the document `snapshot` is of keeps of the
kind `kind` tags, in the range from `start` to `stop` of its text, in the
order `syntaxCaptures` answers: answered at once from the tree the library
last delivered, and refused as `notParsed` when that tree is not of the
snapshot's revision. It never waits for a parse. A status or words the
decoder here cannot read are an `IO` error. -/
def syntaxKeptCaptures (snapshot : Snapshot) (kind : UInt8) (start stop : USize) :
    IO (Except SyntaxKeptRefusal (Array SyntaxCapture)) := do
  let raw ← syntaxKeptCapturesRaw snapshot kind start stop
  if raw.status == 0 then
    match (wordsOf? raw.words).bind capturesOf? with
    | some captures =>
      return .ok captures
    | none =>
      throw (IO.userError "the library's words do not spell captures")
  match keptRefusal? raw.status with
  | some refusal =>
    return .error refusal
  | none =>
    throw (IO.userError s!"the library answered kept captures with the status {raw.status}")

/-- The guard of a snapshot's tree's delivery, for a test kit that waits on
it (`syntaxSettle`) before it forwards a question; only a hang reaches it,
and the question is then forwarded with the tree not yet delivered. -/
def treeGuard : HangGuard :=
  .on "the snapshot's tree" 5000

/-- `syntaxSettle` as it crosses: its guard in milliseconds. -/
@[extern "editor_glue_syntax_settle"]
private opaque syntaxSettleRaw (snapshot : @& Snapshot) (boundMs : UInt64) : IO Bool

/-- `syntaxSettle` is an inferred wait (`Editor/InferredWait.lean`): a real
service's readout whose fake exists (`FakeSyntaxService`), allowed only in
the real binding's adapter (`Editor.SyntaxTree.Real`), its delivery
contract (`Editor.SyntaxTree.DeliveryContract`), and the linked kit's
modules that hand it on, each under a mark of its own
(`Editor.Test.Linked.Shipped`, `Editor.Test.Linked.Syntax`). -/
def syntaxSettle.inferredWait : InferredWait :=
  .realEffect
    [`Editor.SyntaxTree.Real, `Editor.SyntaxTree.DeliveryContract, `Editor.Test.Linked.Shipped,
      `Editor.Test.Linked.Syntax]

/-- For tests: waits, within the hang guard `guard`, for the library to
deliver a tree of `snapshot`'s revision, or a newer one, with layers found
with the injections as they are now, and returns whether it did. It blocks
in the library and does not sleep; `false` at once for a document that is
not attached. -/
def syntaxSettle (snapshot : Snapshot) (guard : HangGuard) : IO Bool :=
  syntaxSettleRaw snapshot guard.ms.toUInt64

/-- Has the syntax service parse a text whole once it has gone
`milliseconds` unchanged after an edit, from now on, for every text: an
edit's tree is the incremental reparse, and the whole parse once the text
is quiet makes it exact. -/
@[extern "editor_glue_syntax_refresh_after"]
opaque syntaxRefreshAfter (milliseconds : UInt64) : IO Unit

end Editor.Ffi
