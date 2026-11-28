import Editor.Markdown.Inline

/-!
# A Markdown block, rendered

One top-level block of a Markdown text rendered into a piece
(`Block.render`): its text, with the markup left out, and its spans, links,
tables, headings and fenced code blocks. Pure.

## What renders how

| Block | Rendered text | Spans |
|---|---|---|
| prose (all text outside code) | — | `text.prose` |
| heading | its text, without `#` or the underline | `text.heading.<level>` over it |
| paragraph | its inline text (`Editor/Markdown/Inline.lean`) | — |
| fenced code block | its content rows, the fence lines left out | `text.code-block` over them; its layer's captures in their faces |
| indented code block | its content rows | `text.code-block`; not foldable |
| table | the header row, then the body rows; the delimiter row and the pipes left out; cells joined by one space | `text.table-header` over the header cells |
| list | an item a line: two spaces a nesting level, then `•` (or the item's own number and `.` or `)`), a space and its blocks, one a line | `text.list-marker` over the marker |
| block quote | its blocks, the `>` markers left out | `text.quote` over them |
| thematic break | `———` | — |
| HTML block | its source | `text.code-block` |
| link reference definition | its source | — |

A task-list marker is kept as its source, before the item's text.

## The tree of a block

A block's captures are read as a tree by their ranges: a block's parent is
the smallest list item or block quote that holds it, and a list item's the
smallest list that holds it (a list of one item has the item's range).
The block grammar's rendered query captures a block of each kind only as a
child of a section, a list item or a block quote, so a setext heading's
paragraph is never one.

## Where an addition goes

| Addition | Where |
|---|---|
| A kind of block | A capture in the block rendered query, its name in `Parsed.blockKinds`, and its case in `node` |

Pinned by the rendered-markdown checks of `ModelTest/Editor/Markdown/Doc.lean`.
-/

namespace Editor.Markdown.Block

open Parsed (Node)

/-- What rendering one block reads: the options, the parse, the source, the
captures within the block, and the parent of each. -/
structure Context where
  /-- What the render takes beyond the document. -/
  options : Options
  /-- The parse. -/
  parsed : Parsed
  /-- The text parsed. -/
  source : String
  /-- The host's captures within the block, in the port's order. -/
  nodes : Array Node
  /-- The parent of each capture ("The tree of a block"), by its index. -/
  parents : Array (Option Nat)

/-- Whether `node` is a block of some kind. -/
def isBlock (node : Node) : Bool :=
  Parsed.blockKinds.contains node.name

/-- The index of the smallest of `nodes` that `fits` and holds the node at
`index`, the node itself left out. -/
def smallestHolding (nodes : Array Node) (index : Nat) (fits : Node → Bool) : Option Nat :=
  let node := nodes[index]!
  (nodes.zipIdx.foldl
        (fun (best : Option (Nat × Nat)) (other, position) =>
          if position != index && fits other && node.within other then
            let size := other.stop - other.start
            match best with
            | some (_, smallest) => if size < smallest then some (position, size) else best
            | none => some (position, size)
          else best)
        none).map
    (·.1)

/-- The parent of each of `nodes` ("The tree of a block", in the module
docs). -/
def parentsOf (nodes : Array Node) : Array (Option Nat) :=
  (Array.range nodes.size).map fun index =>
    if nodes[index]!.name == "list.item" then smallestHolding nodes index (·.name == "list")
    else
      -- A list item or a quote is never as long as a block it holds, which
      -- comes after its marker; a list of one item is.
      let node := nodes[index]!
      smallestHolding nodes index fun other =>
        (other.name == "list.item" || other.name == "quote") &&
          (other.start, other.stop) != (node.start, node.stop)

/-- The indices of the children of the node at `index` that `keep`, in
order. -/
def childrenOf (context : Context) (index : Nat) (keep : Node → Bool) : Array Nat :=
  (Array.range context.nodes.size).filter fun position =>
    context.parents[position]! == some index && keep context.nodes[position]!

/-- The inline text from `start` to `stop` rendered from its inline layer. -/
def inline (context : Context) (start stop : Nat) : Piece :=
  Inline.render context.options.root context.source start stop (context.parsed.inlineIn start stop)

/-- `text` with its blanks at the end left out. -/
def trimEnd (text : String) : String :=
  String.ofList (text.toList.reverse.dropWhile Char.isWhitespace).reverse

/-- A heading of `level` over `node`: its content's inline text, drawn in
its heading's face. -/
def heading (context : Context) (node : Node) (level : Nat) : Piece :=
  match Parsed.first? context.nodes node "heading.content" with
  | none => {}
  | some content =>
    let rendered := inline context content.start content.stop
    let size := rendered.text.utf8ByteSize
    { (rendered.under #[span 0 size s!"text.heading.{level}"]) with
      headings := #[(level, 0, size)] }

/-- The rows of a fence's content `content`, its `hide`s left out and its
last line feed dropped, with its layer's captures in their faces. -/
def fenceRows (context : Context) (content : Node) : Piece :=
  let hidden := (Parsed.all context.nodes content "hide").map fun node => (node.start, node.stop)
  let chars :=
    (Inline.charsOf context.source content.start content.stop).filter fun (offset, _) =>
      !hidden.any fun (first, last) => first ≤ offset && offset < last
  let chars := if chars.back?.map (·.2) == some '\n' then chars.pop else chars
  let (text, position) := Inline.mapOf chars
  let captured :=
    match context.parsed.codeIn content.start content.stop with
    | none => #[]
    | some layer =>
      (Parsed.nodesOf layer).filterMap fun node => do
        let face ← context.options.faces layer.language node.name
        let start := position node.start
        let stop := position node.stop
        if start < stop then
          some { start, stop, face }
        else
          none
  { text, spans := captured }

/-- A fenced code block over `node`. -/
def fence (context : Context) (node : Node) : Piece :=
  let language :=
    ((Parsed.first? context.nodes node "code.language").map fun found =>
          slice context.source found.start found.stop).getD
      ""
  let rows := ((Parsed.first? context.nodes node "code.content").map (fenceRows context)).getD {}
  let size := rows.text.utf8ByteSize
  { (rows.under #[span 0 size "text.code-block"]) with codes := #[(0, size, language)] }

/-- An indented code block over `node`: its rows, each with up to four
spaces of its indent left out, its empty rows at the end dropped. -/
def indented (context : Context) (node : Node) : Piece :=
  let rows :=
    (slice context.source node.start node.stop).splitOn "\n" |>.map fun row =>
      let spaces := (row.toList.takeWhile (· == ' ')).length
      (row.drop (min 4 spaces)).toString
  let rows := (rows.reverse.dropWhile (·.all Char.isWhitespace)).reverse
  let text := "\n".intercalate rows
  { text, spans := #[span 0 text.utf8ByteSize "text.code-block"] }

/-- `node`'s source, its blanks at the end left out. -/
def source (context : Context) (node : Node) : String :=
  trimEnd (slice context.source node.start node.stop)

mutual
/-- The node at `index` rendered, a list `depth` levels deep (the module
docs). -/
partial def node (context : Context) (index : Nat) (depth : Nat) : Piece :=
  let found := context.nodes[index]!
  match found.name with
  | "paragraph" =>
    match Parsed.first? context.nodes found "inline" with
    | some text => inline context text.start text.stop
    | none => { text := (source context found).trimAscii.toString }
  | "code" => fence context found
  | "code.indented" => indented context found
  | "list" =>
    let items := childrenOf context index (·.name == "list.item")
    Piece.join (items.map fun item => listItem context item depth) "\n"
  | "quote" =>
    let blocks := childrenOf context index isBlock
    let joined := Piece.join (blocks.map fun child => node context child depth) blockSeparator
    joined.under #[span 0 joined.text.utf8ByteSize "text.quote"]
  | "break" => { text := "———" }
  | "html" =>
    let text := source context found
    { text, spans := #[span 0 text.utf8ByteSize "text.code-block"] }
  | name =>
    match name.dropPrefix? "heading." with
    | some level => heading context found (level.toString.toNat?.getD 1)
    | none => { text := source context found }
/-- The list item at `index`, a list `depth` levels deep: its indent, its
marker, its task marker as its source, and its blocks one a line. -/
partial def listItem (context : Context) (index : Nat) (depth : Nat) : Piece :=
  let found := context.nodes[index]!
  let own (name : String) : Option Node :=
    (childrenOf context index (·.name == name))[0]?.map (context.nodes[·]!)
  let marker :=
    match own "list.number" with
    | some number => (slice context.source number.start number.stop).trimAscii.toString
    | none => "•"
  let task :=
    match own "task" with
    | some found => slice context.source found.start found.stop ++ " "
    | none => ""
  let indent := String.ofList (List.replicate (2 * depth) ' ')
  let blocks :=
    (childrenOf context index isBlock).map fun child =>
      if context.nodes[child]!.name == "list" then node context child (depth + 1)
      else node context child depth
  let body := Piece.join blocks "\n"
  let head := indent ++ marker ++ " " ++ task
  let _ := found
  (Piece.after head body).under
    #[span indent.utf8ByteSize (indent.utf8ByteSize + marker.utf8ByteSize) "text.list-marker"]
end

/-- The ranges of `[0, size)` that no span of `code` covers, in order. -/
def outside (code : Array (Nat × Nat)) (size : Nat) : Array (Nat × Nat) :=
  let sorted := code.insertionSort fun a b => a.1 < b.1
  let (gaps, last) :=
    sorted.foldl
      (fun (gaps, cursor) (start, stop) =>
        (if cursor < start then gaps.push (cursor, start) else gaps, max cursor stop))
      (#[], 0)
  if last < size then gaps.push (last, size) else gaps

/-- The top-level block of `source` from `start` to `stop`, of the parse
`parsed`, rendered (the module docs): its text outside code drawn in
`text.prose`, under every other span. -/
def render (options : Options) (parsed : Parsed) (source : String) (start stop : Nat) : Piece :=
  let nodes := parsed.nodes.filter fun node => start ≤ node.start && node.stop ≤ stop
  let context : Context := { options, parsed, source, nodes, parents := parentsOf nodes }
  let top :=
    (Array.range nodes.size).find? fun index =>
      let found := nodes[index]!
      isBlock found && found.start == start && found.stop == stop
  match top with
  | none => {}
  | some index =>
    let piece := node context index 0
    let code :=
      (piece.spans.filter (·.face == ⟨"text.code-block"⟩)).map fun span => (span.start, span.stop)
    let prose :=
      (outside code piece.text.utf8ByteSize).map fun (first, last) => span first last "text.prose"
    piece.under prose

end Editor.Markdown.Block
