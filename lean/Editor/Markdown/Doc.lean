import Editor.Markdown.Block

/-!
# A rendered Markdown document

A Markdown document rendered block by block (`Markdown.render`): its
source, and each top-level block's source range with the piece it rendered
to and the align-to stops its tables were measured into. Its description
(`Doc.description`) is the pieces joined, with its foldable ranges. Pure.

- **A block** is a top-level block: a child of a section that is not a
  section (`@block`). A list, a block quote and a table are each one.
- **The options' data parts are kept** (`root`, `gap`), so a later render
  of the document's tail resolves its links and lays out its tables as the
  first did. The faces of a fence's captures are a function, which the
  caller hands each render again.
- **Rendered** (`Doc.rendered`) counts the block renders the document has
  had over its life.

## Which modules it may reach

The editor's state keeps a buffer's document (`Buffer.markdown`,
`Editor/State.lean`), so this module, and the renderer's modules it
imports, sit below the state: they import the scene's types, links, folds
and the syntax tree port's data, and nothing that reaches the state, the
registry, the highlighter, a language or the display. What needs those is
`Editor/Markdown/View.lean`'s, above the state. `lake build` refuses a
cycle, so the build holds this.

## Where an addition goes

| Addition | Where |
|---|---|
| A part of a document kept across renders | A field of `Doc` |
| A part measured when applied | A field of `Doc.Block`, filled by the view |

Pinned by the rendered-markdown checks of `ModelTest/Editor/Markdown/Doc.lean`.
-/

namespace Editor.Markdown

/-- A top-level block of a rendered document: its source range, its piece,
and the align-to stops its tables were measured into, at offsets of its
piece. -/
structure Doc.Block where
  /-- Where its source starts. -/
  start : Nat
  /-- Where its source stops, not included. -/
  stop : Nat
  /-- What it rendered to. -/
  piece : Piece
  /-- Its tables' stops, at offsets of its piece's text; none until
  measured. -/
  stops : Array AlignStop := #[]
  deriving DecidableEq, Repr, Inhabited

/-- A rendered Markdown document. -/
structure Doc where
  /-- Its Markdown source. -/
  source : String := ""
  /-- The root its relative links were resolved against. -/
  root : Option System.FilePath := none
  /-- The gap between its tables' columns, in points. -/
  gap : Nat := 16
  /-- Its top-level blocks, in order. -/
  blocks : Array Doc.Block := #[]
  /-- How many block renders it has had over its life. -/
  rendered : Nat := 0
  deriving DecidableEq, Repr, Inhabited

/-- The top-level blocks of `source` parsed into `layers`, each rendered
with `options`, their source ranges moved `offset` bytes on. -/
def renderBlocks (options : Options) (source : String) (layers : Array SyntaxTree.Layer)
    (offset : Nat := 0) : Array Doc.Block :=
  let parsed := Parsed.of layers
  (parsed.nodes.filter (·.name == Parsed.block)).map fun block =>
    { start := block.start + offset, stop := block.stop + offset
      piece := Block.render options parsed source block.start block.stop }

/-- `source`, a Markdown document parsed into `layers`, rendered with
`options`, every block once. -/
def render (options : Options) (source : String) (layers : Array SyntaxTree.Layer) : Doc :=
  let blocks := renderBlocks options source layers
  { source, root := options.root, gap := options.gap, blocks, rendered := blocks.size }

namespace Doc

/-- The document's pieces, in order. -/
def pieces (doc : Doc) : Array Piece :=
  doc.blocks.map (·.piece)

/-- What `doc` renders to. -/
def description (doc : Doc) : Description :=
  Description.ofPieces doc.pieces

/-- Every block's stops, at offsets of the description's text. -/
def stops (doc : Doc) : Array AlignStop :=
  (doc.blocks.zip (offsetsOf doc.pieces)).foldl
    (fun stops (block, offset) =>
      stops ++ block.stops.map fun stop => { stop with offset := stop.offset + offset })
    #[]

end Doc

end Editor.Markdown
