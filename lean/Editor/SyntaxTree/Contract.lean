import Editor.SyntaxTree

/-!
# The contract of the syntax tree interface

What every implementation of the syntax tree interface
(`Editor/SyntaxTree.lean`) answers, as one list of properties. The model
(`Editor/SyntaxTree/Model.lean`) is held to it by `model-test`, and the real
binding (`Editor/SyntaxTree/Real.lean`) by `contract-test`, so neither can
drift from the other. This module imports only the port, so the contract
never depends on an implementation.

## How a runner runs a property

A property names the texts it needs (`Property.texts`) and is handed the
snapshots of them, in that order:

- the model is made with those texts as its `texts`, with the snapshots
  `0`, `1`, `2` and so on;
- the real binding makes a document and a snapshot of each text in the text
  binding's table. The library parses off the editor thread, so its runner
  waits, with a bound, for the snapshot's tree to be delivered before it
  forwards each `captures`: that is the one difference between the two
  runners, and it is the runner's, not a property's.

## What it asks

Every property is over the grammar `json`, which the model reproduces and
the library has. Each runner hands an implementation on which `json` is
registered, as the core's tests register it from the directory of grammars
cargo builds for them (`editor-syntax-fixture-grammars`): the library hides
its compiled-in grammars from every test, and the model runs with the test
grammars registered (`SyntaxTreeModel.withTestGrammars`).

- the grammars listed, and a grammar that is not listed refused;
- a question of a text that is not attached, or no longer, refused;
- a detach answered whether or not the text is attached, and one after a
  refused attach leaving the text with neither its parse nor its
  highlighter (what `Highlight.enter` does on a refusal);
- a query refused by its kind (offsets are each implementation's own, and
  are not compared), its capture names, and a released query refused;
- a table of exact cases: a text, a query, and the rows it answers of the
  whole text, as (pattern, capture, start, stop). The cases are written so
  that no node has two sibling child patterns that could match the same
  child: how those align is an implementation's own;
- the range rule: of each case's text, several ranges, each answering the
  whole text's rows that are in it;
- a range that is not two positions in order refused;
- a registered grammar's shipped queries refused, of every kind, as
  neither ships one for a registered name, and an unlisted grammar's
  refused as unknown;
- a highlighter set, and refused for a text not attached, a face table of
  the wrong size, and a released query;
- an injection and a keep refused for a text not attached, and a language
  with faces of the wrong size;
- a refresh delay accepted, and no answer changed by it;
- a question of a kept query refused with nothing kept, with a bad range,
  and after a detach; and, after a keep and its query's release, answering
  what `captures` answers of the same source newly compiled.

A runner waits for a snapshot's tree before it forwards a `captures` or a
`capturesOf`.

The cases are the library's own answers, read from the library when the
cases were written; the model is written to the rule, and the contract
holds the two together.
-/

namespace Editor.SyntaxTreeContract

/-- One property of the syntax tree interface. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- The texts the property needs, made into snapshots before it runs. -/
  texts : Array String
  /-- Observes the property, given the snapshots of `texts` in order;
  `true` when it holds. A program that is refused has not held. -/
  holds : Array SnapshotId → SyntaxTreeM Bool

/-- The grammar every property is over. -/
def json : String :=
  "json"

/-- Runs `program` and returns whether it was refused as `refused` says. -/
def refusedAs {α : Type} (refused : SyntaxTreeError → Bool) (program : SyntaxTreeM α) :
    SyntaxTreeM Bool :=
  try
    discard program
    return false
  catch refusal =>
    return refused refusal

/-- Runs `program` and returns whether it was refused with `error`. -/
def refusedWith {α : Type} (error : SyntaxTreeError) (program : SyntaxTreeM α) : SyntaxTreeM Bool :=
  refusedAs (· == error) program

/-- Whether `source` is refused as a query of `json` for `kind`, wherever. -/
def refusedFor (kind : QueryErrorKind) (source : String) : SyntaxTreeM Bool :=
  refusedAs
    (fun
      | .query found _ => found == kind
      | _ => false)
    (SyntaxTree.compile json source)

/-- The snapshot at `index` of those a property was handed, or one past them
when it was not handed that many. -/
def nth (snapshots : Array SnapshotId) (index : Nat) : SnapshotId :=
  snapshots[index]?.getD ⟨snapshots.size⟩

/-- The rows `query` answers of the range from `first` to `last` of the text
of `snapshot`, which is attached to `json`, as (pattern, capture, start,
stop). -/
def rows (snapshot : SnapshotId) (query : String) (first last : Nat) :
    SyntaxTreeM (Array (Nat × Nat × Nat × Nat)) := do
  let compiled ← SyntaxTree.compile json query
  let found ← SyntaxTree.captures snapshot compiled first last
  SyntaxTree.release compiled
  return found.map fun capture => (capture.pattern, capture.capture, capture.start, capture.stop)

/-- The exact cases: what each is, a text with no character but ASCII, a
query, and the rows it answers of the whole text. -/
def cases : List (String × String × String × Array (Nat × Nat × Nat × Nat)) :=
  [("each pair's key", "{\"a\": 1, \"bc\": [2, 3]}", "(pair key: (string) @key)",
      #[(0, 0, 1, 4), (0, 0, 9, 13)]),
    ("each item of an array, nested ones too", "[1, \"x\", true, null, [2]]", "(array (_) @item)",
      #[(0, 0, 1, 2), (0, 0, 4, 7), (0, 0, 9, 13), (0, 0, 15, 19), (0, 0, 21, 24), (0, 0, 22, 23)]),
    ("each comma, an anonymous node", "[1, 2, {\"a\": 3, \"b\": 4}]", "\",\" @comma",
      #[(0, 0, 2, 3), (0, 0, 5, 6), (0, 0, 14, 15)]),
    ("a key inside nested objects", "{\"o\": {\"p\": {\"q\": 1}}}",
      "(pair value: (object (pair key: (string) @inner)))", #[(0, 0, 7, 10), (0, 0, 13, 16)]),
    ("every named node, the root among them, outer first", "{\"a\": [1, \"s\"]}", "(_) @n",
      #[(0, 0, 0, 15), (0, 0, 1, 14), (0, 0, 1, 4), (0, 0, 2, 3), (0, 0, 6, 14), (0, 0, 7, 8),
        (0, 0, 10, 13), (0, 0, 11, 12)]),
    ("two patterns that capture one node, by pattern", "[7, 8]", "(number) @a\n(number) @b",
      #[(0, 0, 1, 2), (1, 1, 1, 2), (0, 0, 4, 5), (1, 1, 4, 5)]),
    ("an empty object and an empty array", "{\"e\": {}, \"f\": []}", "(object) @o\n(array) @a",
      #[(0, 0, 0, 18), (0, 0, 6, 8), (1, 1, 15, 17)]),
    ("a pair's key and value, two captures of one pattern", "{\"k\": \"v\", \"n\": null}",
      "(pair key: (string) @key value: (_) @value)",
      #[(0, 0, 1, 4), (0, 1, 6, 9), (0, 0, 11, 14), (0, 1, 16, 20)]),
    ("every child of a pair, anonymous ones too, by the wildcard", "{\"a\": 1}", "(pair _ @part)",
      #[(0, 0, 1, 4), (0, 0, 4, 5), (0, 0, 6, 7)]),
    ("a string's content, and an empty string with none", "[\"ab\", \"\"]",
      "(string (string_content) @content) @string", #[(0, 1, 1, 5), (0, 0, 2, 4)]),
    ("the root, which starts after the blanks that lead the text", "  [true, false]  ",
      "(document) @doc\n(false) @f", #[(0, 0, 2, 17), (1, 1, 9, 14)]),
    ("a comment in the query", "[1]", "; a comment\n(number) @n", #[(0, 0, 1, 2)]),
    ("a node captured by itself and as a child, outer first", "{\"a\": {\"b\": 2}}",
      "(object (pair) @p) @o", #[(0, 1, 0, 15), (0, 0, 1, 14), (0, 1, 6, 14), (0, 0, 7, 13)])]

/-- The ranges of a text `length` bytes long that the range rule is asked
of: empty at each end and in the middle, the whole text, its first and last
byte, and each third. -/
def ranges (length : Nat) : List (Nat × Nat) :=
  let third := length / 3
  [(0, 0), (length, length), (length / 2, length / 2), (0, length), (0, min 1 length),
    (length - min 1 length, length), (0, third), (third, 2 * third), (2 * third, length),
    (1, length - min 1 length)]

/-- The properties of the syntax tree interface. -/
def properties : List Property :=
  [{    name := "the grammars listed include json"
        texts := #[]
        holds := fun _ => return (← SyntaxTree.grammars).contains json },
      { name := "attaching and compiling for a grammar that is not listed are refused"
        texts := #["[1]"]
        holds := fun snapshots => do
          return (← refusedWith .unknownGrammar (SyntaxTree.attach (nth snapshots 0) "no-such")) &&
              (← refusedWith .unknownGrammar (SyntaxTree.compile "no-such" "(x) @x")) },
      { name := "a question of a text that is not attached, or no longer, is refused"
        texts := #["[1]"]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          let query ← SyntaxTree.compile json "(number) @n"
          let before ← refusedWith .notAttached (SyntaxTree.captures snapshot query 0 3)
          SyntaxTree.attach snapshot json
          let attached := (← SyntaxTree.captures snapshot query 0 3).size == 1
          SyntaxTree.detach snapshot
          let after ← refusedWith .notAttached (SyntaxTree.captures snapshot query 0 3)
          return before && attached && after },
      { name :=
          "a detach is answered whether or not the text is attached, and a text attached and highlighted, then refused an attach of an unlisted grammar and detached, is not attached and takes no highlighter"
        texts := #["[1]", "[2]"]
        holds := fun snapshots => do
          let highlighted := nth snapshots 0
          let never := nth snapshots 1
          let query ← SyntaxTree.compile json "(number) @number"
          SyntaxTree.attach highlighted json
          SyntaxTree.highlight highlighted query #[some ⟨"syntax.number"⟩]
          let refused ← refusedWith .unknownGrammar (SyntaxTree.attach highlighted "no-such")
          SyntaxTree.detach highlighted
          SyntaxTree.detach never
          return refused &&
              (← refusedWith .notAttached (SyntaxTree.captures highlighted query 0 3)) &&
              (←
                refusedWith .notAttached
                    (SyntaxTree.highlight highlighted query #[some ⟨"syntax.number"⟩])) &&
              (← refusedWith .notAttached (SyntaxTree.captures never query 0 3)) },
      { name :=
          "a query that is not one is refused as syntax, an unknown kind as a node type and an unknown field as a field"
        texts := #[]
        holds := fun _ => do
          return (← refusedFor .syntax "((") && (← refusedFor .nodeType "(no_such_kind) @x") &&
              (← refusedFor .field "(pair nope: (string)) @x") },
      { name := "a query's capture names are in the order they first appear"
        texts := #[]
        holds := fun _ => do
          let query ← SyntaxTree.compile json "(pair key: (string) @key value: (_) @value)"
          return (← SyntaxTree.captureNames query) == #["key", "value"] },
      { name := "a released query is refused"
        texts := #["[1]"]
        holds := fun snapshots => do
          let query ← SyntaxTree.compile json "(number) @n"
          SyntaxTree.attach (nth snapshots 0) json
          SyntaxTree.release query
          return (← refusedWith .noSuchQuery (SyntaxTree.captureNames query)) &&
              (← refusedWith .noSuchQuery (SyntaxTree.captures (nth snapshots 0) query 0 3)) },
      { name := "a range that is not two positions of the text in order is refused"
        texts := #["[1, 2]"]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          SyntaxTree.attach snapshot json
          let query ← SyntaxTree.compile json "(number) @n"
          return (← refusedWith .badRange (SyntaxTree.captures snapshot query 0 7)) &&
              (← refusedWith .badRange (SyntaxTree.captures snapshot query 4 2)) },
      { name :=
          "json, registered, ships no query of any kind, and an unlisted grammar's shipped query is refused as unknown"
        texts := #[]
        holds := fun _ => do
          let shipsNone ←
            [QueryKind.highlights, .injections, .textObjects, .indents].allM fun kind =>
                refusedWith .noShippedQuery (SyntaxTree.shippedQuery json kind)
          return shipsNone &&
              (← refusedWith .unknownGrammar (SyntaxTree.shippedQuery "no-such" .highlights)) },
      { name := "a well-formed highlight is answered, and one of a text not attached is refused"
        texts := #["{\"a\": [1, true]}"]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          let query ← SyntaxTree.compile json "(number) @number\n(true) @constant.builtin"
          let faces := #[some ⟨"syntax.number"⟩, none]
          let before ← refusedWith .notAttached (SyntaxTree.highlight snapshot query faces)
          SyntaxTree.attach snapshot json
          SyntaxTree.highlight snapshot query faces
          SyntaxTree.highlight snapshot query #[none, some ⟨""⟩]
          return before },
      { name := "a face table not one for each capture name is refused as bad faces"
        texts := #["[1]"]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          SyntaxTree.attach snapshot json
          let query ← SyntaxTree.compile json "(number) @number\n(array) @punctuation"
          return (← refusedWith .badFaces (SyntaxTree.highlight snapshot query #[none])) &&
              (←
                refusedWith .badFaces
                    (SyntaxTree.highlight snapshot query #[none, none, some ⟨"x"⟩])) },
      { name :=
          "an injection and a keep of a text not attached are refused, and a language with faces not one for each capture name"
        texts := #["[1]"]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          let query ← SyntaxTree.compile json "(number) @number"
          let inject ← refusedWith .notAttached (SyntaxTree.inject snapshot query)
          let keep ← refusedWith .notAttached (SyntaxTree.keep snapshot .indents query)
          SyntaxTree.attach snapshot json
          let faces ← refusedWith .badFaces (SyntaxTree.injectLanguage snapshot json query #[] none)
          SyntaxTree.injectLanguage snapshot json query #[some ⟨"syntax.number"⟩] (some query)
          SyntaxTree.inject snapshot query
          SyntaxTree.keep snapshot .indents query
          return inject && keep && faces },
      { name :=
          "a question of a kept query is refused with nothing kept of its kind and with a range not two positions in order"
        texts := #["[1, 2]"]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          SyntaxTree.attach snapshot json
          let nothing ← refusedWith .noQuery (SyntaxTree.capturesOf snapshot .textObjects 0 6)
          let query ← SyntaxTree.compile json "(number) @n"
          SyntaxTree.keep snapshot .textObjects query
          let other ← refusedWith .noQuery (SyntaxTree.capturesOf snapshot .indents 0 6)
          let bad ← refusedWith .badRange (SyntaxTree.capturesOf snapshot .textObjects 4 2)
          return nothing && other && bad },
      { name :=
          "a range of a kept query answers its names and what captures answers of the same source newly compiled, after the keep and its query's release"
        texts := #["{\"a\": [1, {\"b\": 2}]}"]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          let source := "(pair key: (string) @key)\n(array) @array"
          SyntaxTree.attach snapshot json
          let kept ← SyntaxTree.compile json source
          SyntaxTree.keep snapshot .textObjects kept
          SyntaxTree.release kept
          let fresh ← SyntaxTree.compile json source
          (ranges 20).allM fun (first, last) => do
              let answer ← SyntaxTree.capturesOf snapshot .textObjects first last
              return answer.names == #["key", "array"] &&
                  answer.captures == (← SyntaxTree.captures snapshot fresh first last) },
      { name := "after a detach a question of a kept query is refused as not attached"
        texts := #["[1]"]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          SyntaxTree.attach snapshot json
          let query ← SyntaxTree.compile json "(number) @n"
          SyntaxTree.keep snapshot .indents query
          let before := (← SyntaxTree.capturesOf snapshot .indents 0 3).captures.size == 1
          SyntaxTree.detach snapshot
          return before &&
              (← refusedWith .notAttached (SyntaxTree.capturesOf snapshot .indents 0 3)) },
      { name := "a refresh delay handed to the service changes no answer"
        texts := #["[1, 2]"]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          SyntaxTree.attach snapshot json
          let before ← rows snapshot "(number) @n" 0 6
          SyntaxTree.refreshAfter 500
          return before == #[(0, 0, 1, 2), (0, 0, 4, 5)] &&
              (← rows snapshot "(number) @n" 0 6) == before },
      { name := "a highlight with a released query is refused"
        texts := #["[1]"]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          SyntaxTree.attach snapshot json
          let query ← SyntaxTree.compile json "(number) @number"
          SyntaxTree.release query
          refusedWith .noSuchQuery (SyntaxTree.highlight snapshot query #[none]) }] ++
    (cases.map fun (what, text, query, expected) =>
      { name := s!"a query answers the library's rows: {what}"
        texts := #[text]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          SyntaxTree.attach snapshot json
          return (← rows snapshot query 0 text.utf8ByteSize) == expected }) ++
    cases.map fun (what, text, query, expected) =>
      { name := s!"a range answers the whole text's rows that are in it: {what}"
        texts := #[text]
        holds := fun snapshots => do
          let snapshot := nth snapshots 0
          SyntaxTree.attach snapshot json
          (ranges text.utf8ByteSize).allM fun (first, last) => do
              let inRange :=
                expected.filter fun (_, _, start, stop) => SyntaxTree.overlaps start stop first last
              return (← rows snapshot query first last) == inRange }

/-- The names of `properties` that do not hold. `run` runs one property
against an implementation. -/
def failures (run : Property → IO Bool) (properties : List Property) : IO (List String) :=
  properties.filterMapM fun property => do
    return if ← run property then none else some property.name

end Editor.SyntaxTreeContract
