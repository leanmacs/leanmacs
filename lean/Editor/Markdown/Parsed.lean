import Editor.SyntaxTree

/-!
# A Markdown text's parse, as the renderer reads it

The layers of a Markdown text parsed once (`Editor/Markdown/Parse.lean`)
read as the renderer reads them (`Parsed.of`): the host's captures by name,
in the order the port answers them (by start, the longer first), the inline
layers and the code layers.

The capture names are those of the two rendered queries, which are the
`languages` package's (`packages/languages/grammars/queries/markdown/rendered.scm`
and `queries/markdown_inline/rendered.scm`), each named here once:

- of the block grammar: `block`, each kind of block (`paragraph`, `code`,
  `code.indented`, `table`, `list`, `quote`, `break`, `html`, `definition`
  and `heading.1` to `heading.6`), `heading.content`, `inline`,
  `code.language`, `code.content`, `table.header`, `table.delimiter`,
  `table.row`, `table.cell`, `list.item`, `list.bullet`, `list.number`,
  `task` and `hide`;
- of the inline grammar: `emphasis`, `strong`, `code-span`, `link`,
  `link.text`, `link.destination`, `link.title`, `autolink`,
  `autolink.email`, `image`, `image.description`, `escape`, `hard-break`,
  `html`, `reference`, `strike`, `entity` and `hide`.

## Where an addition goes

| Addition | Where |
|---|---|
| A capture the renderer reads | The rendered query that captures it, a name here, and the module that reads it |
| A lookup over the parse | A function here |

Pinned by the rendered-markdown checks of `ModelTest/Editor/Markdown/Doc.lean`,
over fixtures whose layers `ContractTest.markdownCaseChecks` holds to the
library's.
-/

namespace Editor.Markdown

/-- A capture of a layer, by its name: the node it captured, from `start` up
to `stop`. -/
structure Parsed.Node where
  /-- The capture's name. -/
  name : String
  /-- Where the node starts. -/
  start : Nat
  /-- Where it stops, not included. -/
  stop : Nat
  deriving DecidableEq, Repr, Inhabited

/-- A Markdown text's layers, as the renderer reads them. -/
structure Parsed where
  /-- The host's captures, in the port's order. -/
  nodes : Array Parsed.Node := #[]
  /-- The inline layers: a paragraph's, a heading's or a table cell's text. -/
  inlines : Array SyntaxTree.Layer := #[]
  /-- The code layers: each fence's content in its language, and any layer
  inside one. -/
  codes : Array SyntaxTree.Layer := #[]

namespace Parsed

/-- The block grammar's capture of a top-level block. -/
def block : String :=
  "block"

/-- The names of the kinds of block, each captured wherever it is a child of
a section, a list item or a block quote. -/
def blockKinds : List String :=
  ["paragraph", "code", "code.indented", "table", "list", "quote", "break", "html", "definition"] ++
    (List.range 6).map fun index => s!"heading.{index + 1}"

/-- The language of the inline layers. -/
def inlineLanguage : String :=
  "markdown_inline"

/-- The captures of `layer`, by name, in its order. -/
def nodesOf (layer : SyntaxTree.Layer) : Array Node :=
  layer.captures.map fun capture =>
    { name := layer.names[capture.capture]?.getD "", start := capture.start, stop := capture.stop }

/-- `layers` as the renderer reads them: the host's captures by name, the
inline layers and the code layers. -/
def «of» (layers : Array SyntaxTree.Layer) : Parsed :=
  let host := layers.find? (·.depth == 0)
  { nodes := (host.map nodesOf).getD #[]
    inlines := layers.filter fun layer => layer.depth > 0 && layer.language == inlineLanguage
    codes := layers.filter fun layer => layer.depth > 0 && layer.language != inlineLanguage }

/-- Where `layer`'s first range starts; 0 for a layer of no range. -/
def firstStart (layer : SyntaxTree.Layer) : Nat :=
  (layer.ranges[0]?.map (·.1)).getD 0

/-- The inline layer of the text from `start` to `stop`: the first whose
first range starts in it. -/
def inlineIn (parsed : Parsed) (start stop : Nat) : Option SyntaxTree.Layer :=
  parsed.inlines.find? fun layer =>
    start ≤ firstStart layer && firstStart layer < max stop (start + 1)

/-- The code layer of a fence's rows from `start` to `stop`: the shallowest
whose first range starts in them. -/
def codeIn (parsed : Parsed) (start stop : Nat) : Option SyntaxTree.Layer :=
  let inside := parsed.codes.filter fun layer => start ≤ firstStart layer && firstStart layer < stop
  inside.foldl
    (fun best layer =>
      match best with
      | some found => if layer.depth < found.depth then some layer else best
      | none => some layer)
    none

/-- Whether `node` lies within `outer`, its ends included. -/
def Node.within (node outer : Node) : Bool :=
  outer.start ≤ node.start && node.stop ≤ outer.stop

/-- The first of `nodes` named `name` within `outer`. -/
def first? (nodes : Array Node) (outer : Node) (name : String) : Option Node :=
  nodes.find? fun node => node.name == name && node.within outer

/-- The nodes of `nodes` named `name` within `outer`, in order. -/
def all (nodes : Array Node) (outer : Node) (name : String) : Array Node :=
  nodes.filter fun node => node.name == name && node.within outer

end Parsed

end Editor.Markdown
