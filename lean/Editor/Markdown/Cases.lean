import Editor.Json
import Editor.Language
import Editor.Markdown.Parse

/-!
# The Markdown cases: fixtures and their parses

A Markdown fixture checked in under `tests/markdown/` is a pair: a text,
`<case>.md`, and the layers the library answers of it parsed once,
`<case>.layers.json` (`Fixture`). The model of the syntax tree port answers
each fixture its canned layers (`SyntaxTreeModel.once`), so the renderer's
tests run on the library's real parses with no Rust; and the contract holds
the library to answer each fixture exactly its canned layers (`holds`), so
the canned answers cannot drift from tree-sitter-md, the shipped queries or
the injection rule. `tests/markdown/README.md` says what each fixture holds
and how its layers are refreshed.

- **The layers file** is a JSON array of layers, one a line (`encode`),
  each an object of its `language`, its `depth`, its `ranges` as pairs, its
  capture `names` and its `captures` as (pattern, capture, start, stop).
  `decode` reads it back, and refuses anything else with why.
- **The kinds** a fixture is parsed with are those of the shipped
  languages' grammars (`grammars`, `Markdown.kindsOf`), as a rendered view
  with no config parses.

This module is a test double: a package's tests may import it, its code
never.

## Where an addition goes

| Addition | Where |
|---|---|
| A fixture | `tests/markdown/<case>.md` and its `.layers.json`, listed in both test modules' fixture lists (`ModelTest.Support.Markdown`, `ContractTest.Editor.Markdown.Cases`) |

Pinned by `ModelTest.markdownCaseChecks` (every fixture decodes, round-trips,
and the model answers it) and `ContractTest.markdownCaseChecks` (the library
answers it).
-/

namespace Editor.Markdown.Cases

/-- A Markdown fixture: its name, its text, and the layers the library
answers of it parsed once. -/
structure Fixture where
  /-- Its name: the file's, without `.md`. -/
  name : String
  /-- Its text, `<name>.md`. -/
  source : String
  /-- Its layers, `<name>.layers.json`. -/
  layers : Array SyntaxTree.Layer
  deriving Repr

/-- The grammar names a fixture is parsed with: those of the shipped
languages. -/
def grammars : List String :=
  Language.shipped.toList.map (·.syntaxTree.grammar)

/-- A number as JSON. -/
private def number (value : Nat) : Json.Value :=
  .number (toString value)

/-- `layer` as a JSON object. -/
def encodeLayer (layer : SyntaxTree.Layer) : Json.Value :=
  .object
    #[("language", .string layer.language), ("depth", number layer.depth),
      ("ranges",
        .array (layer.ranges.map fun (start, stop) => .array #[number start, number stop])),
      ("names", .array (layer.names.map .string)),
      ("captures",
        .array
          (layer.captures.map fun capture =>
            .array
              #[number capture.pattern, number capture.capture, number capture.start,
                number capture.stop]))]

/-- `layers` as a layers file: a JSON array, one layer a line. -/
def encode (layers : Array SyntaxTree.Layer) : String :=
  "[\n" ++ ",\n".intercalate (layers.toList.map fun layer => Json.render (encodeLayer layer)) ++
    "\n]\n"

/-- The number `value` holds, or why not. -/
private def natOf (value : Json.Value) : Except String Nat :=
  match value with
  | .number text =>
    match text.toNat? with
    | some found => .ok found
    | none => .error s!"{text} is not a whole number"
  | _ => .error "a number is missing"

/-- The items of the array `value`, or why not. -/
private def itemsOf (value : Json.Value) : Except String (Array Json.Value) :=
  match value with
  | .array items => .ok items
  | _ => .error "an array is missing"

/-- The field `name` of `value`, or why not. -/
private def fieldOf (value : Json.Value) (name : String) : Except String Json.Value :=
  match value.field? name with
  | some found => .ok found
  | none => .error s!"a layer has no {name}"

/-- The layer the JSON object `value` spells, or why not. -/
def decodeLayer (value : Json.Value) : Except String SyntaxTree.Layer := do
  let language ←
    match ← fieldOf value "language" with
    | .string text =>
      pure text
    | _ =>
      throw "a layer's language is not a string"
  let depth ← natOf (← fieldOf value "depth")
  let ranges : Array (Nat × Nat) ←
    (← itemsOf (← fieldOf value "ranges")).mapM fun range => do
        let ends ← itemsOf range
        let #[start, stop] := ends | throw "a range is not two numbers"
        return (← natOf start, ← natOf stop)
  let names : Array String ←
    (← itemsOf (← fieldOf value "names")).mapM fun
        | .string text => pure text
        | _ => throw "a capture name is not a string"
  let captures : Array SyntaxTree.Capture ←
    (← itemsOf (← fieldOf value "captures")).mapM fun capture => do
        let fields ← itemsOf capture
        let #[pattern, index, start, stop] := fields | throw "a capture is not four numbers"
        let found : SyntaxTree.Capture :=
          { pattern := ← natOf pattern, capture := ← natOf index, start := ← natOf start
            stop := ← natOf stop }
        return found
  let layer : SyntaxTree.Layer := { language, depth, ranges, names, captures }
  return layer

/-- The layers a layers file spells (`encode`), or why not. -/
def decode (text : String) : Except String (Array SyntaxTree.Layer) := do
  let value ← Json.parse text.toUTF8
  (← itemsOf value).mapM decodeLayer

/-- Whether the syntax tree port answers `fixture`'s text parsed once
(`Markdown.parse`, with the shipped languages' grammars) exactly its
canned layers. -/
def holds (fixture : Fixture) : SyntaxTreeM Bool := do
  return (← Markdown.parse grammars fixture.source) == fixture.layers

end Editor.Markdown.Cases
