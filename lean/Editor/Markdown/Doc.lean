import Editor.Markdown.Block
import Editor.RichText

/-!
# A rendered Markdown document

A Markdown document rendered block by block (`Markdown.render`): its
source, and each top-level block's source range with the piece it rendered
to and the align-to stops its tables were measured into. Its description
(`Doc.description`) is the pieces joined, with its foldable ranges. Pure.

- **Lowered to the core's rich-text description** (`Doc.richText`,
  `Editor/RichText.lean`): the description's text, spans, links, folds and
  wrap indents as they are, and the stops its blocks' tables were measured
  into, at offsets of the whole text (`Doc.stops`). The description stays
  layout-free, its tables cell ranges, since this module cannot reach the
  display; the rich-text description is layout-complete, which is why the
  lowering is the document's, after the view has measured it.

- **A block** is a top-level block: a child of a section that is not a
  section (`@block`). A list, a block quote and a table are each one.
- **The options' data parts are kept** (`root`, `gap`, `indent`), so a
  later render of the document's tail resolves its links, lays out its
  tables and indents its lists and quotes as the first did. The faces of a fence's captures are a function, which the
  caller hands each render again.
- **Rendered** (`Doc.rendered`) counts the block renders the document has
  had over its life.

## The tail

An append (`Doc.extend`) keeps every block but the last, parses the source
from the last block's start with the appended text alone (`Doc.tail`), and
renders only the blocks of that. Markdown's block structure before the
start of the last top-level block cannot change on an append: a setext
underline, a table's delimiter row, a lazy continuation, a list's next item
and an unclosed fence each extend or change the last block alone. The
document-wide parts (the heading folds, whose ranges an append can move,
and the fold keys) are made from the pieces on every update and render
nothing (`Description.ofPieces`). So the document an append makes
describes what rendering its whole source does. `Doc.firstChanged` is
where the two texts first differ: the rendered end of the last block they
share.

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
| A part measured when applied | A field of `Doc.Block`, filled by the view, and its arm in `Doc.richText` |
| A part the view writes into the buffer | A field of `RichText` (`Editor/RichText.lean`), filled by `Doc.richText` |

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
  /-- The indent step of its list items' and quotes' blocks, in points. -/
  indent : Nat := 16
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
  { source, root := options.root, gap := options.gap, indent := options.indent, blocks
    rendered := blocks.size }

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

/-- The core's rich-text description of `doc` (`Editor/RichText.lean`): its
description's text, spans, links, folds and wrap indents as they are, and its
blocks' stops at offsets of the whole text (`stops`), the tables measured
onto the blocks being the one part the layout-free description lacks. -/
def richText (doc : Doc) : RichText :=
  let description := doc.description
  { text := description.text, spans := description.spans, stops := doc.stops
    links := description.links, folds := description.folds, indents := description.indents }

/-- Where the document's tail starts: its last block's source start, or 0
for a document of no block. -/
def tailStart (doc : Doc) : Nat :=
  (doc.blocks.back?.map (·.start)).getD 0

/-- What an append of `more` parses: the document's source from its last
block's start on, and `more` ("The tail", in the module docs). -/
def tail (doc : Doc) (more : String) : String :=
  RichText.bytes doc.source doc.tailStart doc.source.utf8ByteSize ++ more

/-- `doc` with `more` appended ("The tail", in the module docs): every block
but the last kept as it is, and the blocks of the tail, parsed into
`tailLayers` (`tail`), rendered with the document's root, gap and indent
step, a fence's captures in `faces`. -/
def extend (doc : Doc) (more : String) (tailLayers : Array SyntaxTree.Layer)
    (faces : String → String → Option FaceName := fun _ _ => none) : Doc :=
  let options : Options := { root := doc.root, gap := doc.gap, indent := doc.indent, faces }
  let fresh := renderBlocks options (doc.tail more) tailLayers doc.tailStart
  { doc with
    source := doc.source ++ more
    blocks := doc.blocks.pop ++ fresh
    rendered := doc.rendered + fresh.size }

/-- How many blocks `old` and `new` begin with alike. -/
def kept (old new : Doc) : Nat :=
  ((old.blocks.zip new.blocks).toList.takeWhile fun (a, b) => a == b).length

/-- Where `new`'s rendered text first differs from `old`'s: the rendered
offset the last block both begin with ends at, or 0 when they begin with
none. Every byte of the two texts before it is the same. -/
def firstChanged (old new : Doc) : Nat :=
  match old.kept new with
  | 0 => 0
  | count =>
    let pieces := new.pieces
    ((offsetsOf pieces)[count - 1]?.getD 0) +
      ((pieces[count - 1]?.map (·.text.utf8ByteSize)).getD 0)

end Doc

end Editor.Markdown
