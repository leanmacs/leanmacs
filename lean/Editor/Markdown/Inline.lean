import Editor.Markdown.Description
import Editor.Markdown.Parsed
import Editor.Markdown.Target

/-!
# Inline Markdown, rendered

One paragraph's, heading's or table cell's text rendered from its inline
layer (`Inline.render`): the text with the markup left out, and its spans
and links at offsets of that text. Pure.

## The text

- **Left out**: every `hide` (the delimiters of an emphasis, a strong
  emphasis and a code span, and a link's and an image's brackets and
  parentheses); all of a link but its text, and of an image but its
  description, so a destination and a title are left out; an escape's
  backslash; an autolink's angles; and the bytes outside the layer's ranges
  (a block quote's `>` and a list item's indentation on a later line).
- **Kept as their source**: a strikethrough, an entity, an inline HTML tag
  and a reference link.
- **Breaks**: a soft break, a line feed with the blanks around it, is one
  space; a hard break (two spaces or a backslash before a line feed) is a
  line feed, the blanks after it left out.
- The blanks at either end are left out, as a table cell's are.

## Spans and links

- An emphasis, a strong emphasis and a code span are drawn in
  `text.emphasis`, `text.strong` and `text.code-span`, over their text.
- A link's text links to what its destination names (`targetOf`), an
  image's description to what its source names, an autolink's address to
  itself, and an email autolink's to `mailto:` and the address.
- A bare URL or `path:line` in the rendered text (`references`) is a link
  too, unless it overlaps one of the above.

Links are in order of start.

## Where an addition goes

| Addition | Where |
|---|---|
| Markup left out | A `hide` in the inline rendered query, or a case of `hidden` |
| An inline face | `faceOf` |
| A kind of inline link | `linksOf` |

Pinned by the rendered-markdown checks of `ModelTest/Editor/Markdown/Doc.lean`.
-/

namespace Editor.Markdown.Inline

open Parsed (Node)

/-- The face an inline capture named `name` is drawn in, if any. -/
def faceOf : String → Option String
  | "emphasis" => some "text.emphasis"
  | "strong" => some "text.strong"
  | "code-span" => some "text.code-span"
  | _ => none

/-- The node named `name` within `outer` among `nodes`. -/
private def inside (nodes : Array Node) (outer : Node) (name : String) : Option Node :=
  Parsed.first? nodes outer name

/-- The byte ranges `nodes` leave out of the text from `start` to `stop`
whose layer is over `ranges` ("The text", in the module docs). -/
def hidden (nodes : Array Node) (ranges : Array (Nat × Nat)) (start stop : Nat) :
    Array (Nat × Nat) :=
  let showing (outer : Node) (shown : Option Node) : Array (Nat × Nat) :=
    match shown with
    | some text => #[(outer.start, text.start), (text.stop, outer.stop)]
    | none => #[(outer.start, outer.stop)]
  let own :=
    nodes.foldl
      (fun hidden node =>
        match node.name with
        | "hide" => hidden.push (node.start, node.stop)
        | "link" => hidden ++ showing node (inside nodes node "link.text")
        | "image" => hidden ++ showing node (inside nodes node "image.description")
        | "escape" => hidden.push (node.start, node.start + 1)
        | "autolink" | "autolink.email" =>
          hidden.push (node.start, node.start + 1) |>.push (node.stop - 1, node.stop)
        | _ => hidden)
      #[]
  let (gaps, last) :=
    ranges.foldl (fun (gaps, cursor) (first, last) => (gaps.push (cursor, first), max cursor last))
      (#[], start)
  own ++ gaps.push (last, stop)

/-- The rendered text of the bytes `chars` (each with its offset), with
`hidden` left out and the breaks of the module docs: each kept character
with the offset it came from. -/
def kept (chars : Array (Nat × Char)) (hidden : Array (Nat × Nat)) (hard : Array Node) :
    Array (Nat × Char) :=
  let blank (c : Char) : Bool := c == ' ' || c == '\t'
  let trimmed (out : Array (Nat × Char)) : Array (Nat × Char) :=
    (out.toList.reverse.dropWhile fun (_, c) => blank c).reverse.toArray
  let isHidden (offset : Nat) : Bool :=
    hidden.any fun (first, last) => first ≤ offset && offset < last
  let (out, _, _) :=
    chars.foldl
      (fun (out, skip, past) (offset, c) =>
        if offset < past then (out, skip, past)
        else
          match hard.find? (·.start == offset) with
          | some node => ((trimmed out).push (offset, '\n'), true, node.stop)
          | none =>
            if isHidden offset then (out, skip, past)
            else
              if c == '\n' then ((trimmed out).push (offset, ' '), true, past)
              else
                if skip && blank c then (out, skip, past) else (out.push (offset, c), false, past))
      (#[], true, 0)
  (out.toList.reverse.dropWhile fun (_, c) => blank c || c == '\n').reverse.toArray

/-- The characters of `source` from `start` up to `stop`, each with its byte
offset. -/
def charsOf (source : String) (start stop : Nat) : Array (Nat × Char) :=
  ((slice source start stop).toList.foldl
      (fun (chars, offset) c => (chars.push (offset, c), offset + c.utf8Size)) (#[], start)).1

/-- The rendered text of `kept`, and the rendered offset of each source
offset: that of the first kept character from it on, or the text's end. -/
def mapOf (kept : Array (Nat × Char)) : String × (Nat → Nat) :=
  let text := String.ofList (kept.toList.map (·.2))
  let (starts, _) :=
    kept.foldl
      (fun (starts, renderedAt) (offset, c) =>
        (starts.push (offset, renderedAt), renderedAt + c.utf8Size))
      (#[], 0)
  (text, fun source => ((starts.find? (·.1 ≥ source)).map (·.2)).getD text.utf8ByteSize)

/-- The links of `nodes` ("Spans and links", in the module docs), their
destinations read from `source` and resolved against `root`, at rendered
offsets by `renderedAt`; then the bare references of `text` that overlap none of
them; in order of start. -/
def linksOf (root : Option System.FilePath) (source : String) (nodes : Array Node)
    (renderedAt : Nat → Nat) (text : String) : Array Link :=
  let destination (outer : Node) : Option LinkTarget := do
    let found ← inside nodes outer "link.destination"
    targetOf root (slice source found.start found.stop)
  let linked (outer : Node) (shown : String) : Option Link := do
    let text ← inside nodes outer shown
    let target ← destination outer
    if renderedAt text.start < renderedAt text.stop then
      some { start := renderedAt text.start, stop := renderedAt text.stop, target }
    else
      none
  let explicit :=
    nodes.filterMap fun node =>
      match node.name with
      | "link" => linked node "link.text"
      | "image" => linked node "image.description"
      | "autolink" =>
        some
          { start := renderedAt node.start, stop := renderedAt node.stop
            target := .url (slice source (node.start + 1) (node.stop - 1)) }
      | "autolink.email" =>
        some
          { start := renderedAt node.start, stop := renderedAt node.stop
            target := .url ("mailto:" ++ slice source (node.start + 1) (node.stop - 1)) }
      | _ => none
  let bare :=
    (references root text).filterMap fun (start, stop, target) =>
      if explicit.any fun link => link.start < stop && start < link.stop then none
      else some { start, stop, target : Link }
  (explicit ++ bare).insertionSort fun a b => a.start < b.start

/-- The text of `source` from `start` up to `stop` rendered from its inline
layer `layer`, if it has one (the module docs), with its spans and links;
a relative link resolved against `root`. With no layer the text is plain,
its breaks and its blanks at either end as the module docs say. -/
def render (root : Option System.FilePath) (source : String) (start stop : Nat)
    (layer : Option SyntaxTree.Layer) : Piece :=
  let nodes := (layer.map Parsed.nodesOf).getD #[]
  let ranges := (layer.map (·.ranges)).getD #[(start, stop)]
  let hard := nodes.filter (·.name == "hard-break")
  let rendered := kept (charsOf source start stop) (hidden nodes ranges start stop) hard
  let (text, renderedAt) := mapOf rendered
  let spans :=
    nodes.filterMap fun node => do
      let face ← faceOf node.name
      if renderedAt node.start < renderedAt node.stop then
        some (span (renderedAt node.start) (renderedAt node.stop) face)
      else
        none
  { text, spans, links := linksOf root source nodes renderedAt text }

end Editor.Markdown.Inline
