import Editor.Api
import Editor.Columns
import Editor.Highlight
import Editor.Language
import Editor.Markdown.Doc
import Editor.Markdown.Parse

/-!
# A rendered Markdown view of a generated buffer

The core call a package renders a Markdown document into a buffer with
(`docs/design/text-and-display.md`, "Rendered markdown, as built"):

- **`BufferId.renderMarkdown id source options`** parses `source` once
  through the syntax tree port (`Markdown.parse`), renders every block
  (`Markdown.render`), measures each table into align-to stops, and writes
  the buffer: its whole text, then its spans, stops, links and foldable
  ranges, then the document itself (`Buffer.markdown`).
- **`BufferId.appendMarkdown id more`** extends the document the buffer
  holds with `more`: it parses only the document's tail (`Doc.tail`),
  renders only the tail's blocks (`Doc.extend`), measures only their
  tables, and rewrites only the text from where it first changes
  (`Doc.firstChanged`) to its end. It renders with the root and gap the
  document was first rendered with. Declaring the folds again keeps each
  range's toggled state by its key (`Fold.merge`).

Both read the language table (`languageCaptures`, the registry's): each
grammar's name is a pair the text is parsed with (`kindsOf`), so a fence of
that language is highlighted, and a fence's capture is drawn in the face
its language's captures and the shipped default give it
(`Highlight.faceOf`). The buffer is written inside `BufferId.writing`, so a
read-only buffer is written by its owner.

**Refusals** (`Refusal`) leave the buffer as it was: an absent buffer
(`buffer`), a parse the syntax tree port refused (`parse`), and an append
to a buffer that holds no document (`notRendered`).

**Tables are measured when they are applied**: each cell is measured with
the spans over it, through the display (`Columns.measureCells`), its
columns laid out past the widest cell of each column before and the wider
of the gap and a space (`Columns.starts`), and a stop put at each later
cell's first byte (`Columns.stopsAt`). The stops are kept on their block,
so a block kept by an append keeps its stops; a theme or font change
re-measures a table only when its block is rendered again.

## Where an addition goes

| Addition | Where |
|---|---|
| A part the view writes into the buffer | `apply`, from the description or the document |
| A part measured at apply time | `measure`, onto `Doc.Block` |
| A refusal | A constructor of `Refusal` |

Pinned by `ModelTest.markdownViewChecks`, `ModelTest.markdownTableViewChecks`
and `ModelTest.markdownAppendChecks` (`ModelTest/Editor/Markdown/View.lean`),
on the stepped loop over the models, the syntax tree model answering the
fixtures' canned layers.
-/

namespace Editor.Markdown

/-- Why a rendered view was refused. -/
inductive Refusal where
  /-- The buffer was refused: there is none of the id. -/
  | buffer (refusal : BufferRefusal)
  /-- The buffer holds no rendered document to append to. -/
  | notRendered
  /-- The syntax tree port refused the parse. -/
  | parse (refusal : SyntaxTreeError)

/-- The language table as the view reads it: each language's grammar and
its captures' face overrides, config's over the shipped ones; the shipped
table where no loop runs the command. -/
def languageTable : EditorM (List (String × List (String × Option FaceName))) := do
  match ← RegistryRequest.ask .languageCaptures with
  | some table =>
    return table
  | none =>
    return Language.shipped.toList.map fun language =>
        (language.syntaxTree.grammar, language.syntaxTree.captures)

/-- The face a capture named `name` of a layer of `grammar` is drawn in, by
`table`'s captures of that grammar over the shipped default. -/
def facesOf (table : List (String × List (String × Option FaceName))) (grammar name : String) :
    Option FaceName :=
  match table.find? (·.1 == grammar) with
  | some (_, captures) => Highlight.faceOf captures name
  | none => none

/-- `block`'s tables measured into align-to stops at offsets of its piece,
with `gap` between a column's widest cell and the next ("Tables are measured
when they are applied", in the module docs). -/
def measure (gap : Nat) (block : Doc.Block) : DisplayM Doc.Block := do
  if block.piece.tables.isEmpty then
    return block
  let piece := block.piece
  let cellQuery (start stop : Nat) : Display.MeasureQuery :=
    { text := slice piece.text start stop
      decorations :=
        piece.spans.filterMap fun span =>
          if span.start < stop && start < span.stop then
            some
              { span with
                start := max span.start start - start
                stop := min span.stop stop - start }
          else none }
  let gap := max gap (← Display.measure { text := " " })
  let stops ←
    piece.tables.foldlM
        (fun stops table => do
          let widths ←
            Columns.measureCells (table.rows.map (·.map fun (start, stop) => cellQuery start stop))
          return stops ++
              Columns.stopsAt (table.rows.map (·.map (·.1))) (Columns.starts widths gap))
        #[]
  return { block with stops }

/-- `doc` with the tables of each block from `first` on measured. -/
def measureFrom (doc : Doc) (first : Nat) : DisplayM Doc := do
  let blocks ←
    doc.blocks.zipIdx.mapM fun (block, index) =>
        if index < first then pure block else measure doc.gap block
  return { doc with blocks }

/-- Writes `doc` into the buffer `id`: its text from `start` to its end
replaced with the description's from `start`, then its spans, stops, links
and foldable ranges, then the document. -/
def apply (id : BufferId) (doc : Doc) (start : Nat) : EditorM (Except Refusal Unit) := do
  let description := doc.description
  id.writing do
      match ← id.text with
      | .error refusal =>
        return .error (.buffer refusal)
      | .ok text =>
        let length ← text.byteLength
        let start := min start length
        text.replaceRange start length (slice description.text start description.text.utf8ByteSize)
        discard <| id.setSpans description.spans
        discard <| id.setStops doc.stops
        discard <| id.setLinks description.links
        discard <| id.setFolds description.folds
        discard <| EditorState.ask (.setMarkdown id (some doc))
        return .ok ()

end Editor.Markdown

namespace Editor.BufferId

open Markdown

/-- Renders `source`, a Markdown document, into the buffer `id`, in place
of its text and its parts (the module docs): parsed once through the
syntax tree port, every block rendered with `options` and the language
table's faces, its tables measured, and the buffer written inside
`BufferId.writing`, the document kept for `appendMarkdown`. Refused, with the
buffer as it was, with `buffer` for an absent buffer and `parse` for a
parse the port refused. -/
def renderMarkdown (id : BufferId) (source : String) (options : Options := {}) :
    EditorM (Except Refusal Unit) := do
  let some _ := (← editorState).buffer? id | return .error (.buffer (.noSuchBuffer id))
  let table ← languageTable
  match ← SyntaxTree.lift (Markdown.parse (table.map (·.1)) source) with
  | .error refusal =>
    return .error (.parse refusal)
  | .ok layers =>
    let doc := Markdown.render { options with faces := facesOf table } source layers
    Markdown.apply id (← measureFrom doc 0) 0

/-- Appends `more` to the Markdown document the buffer `id` holds (the
module docs): only the document's tail parsed and its blocks rendered, with
the root and gap it was first rendered with, their tables measured, and the
buffer's text rewritten from where it first changes. Refused, with the
buffer as it was, with `buffer` for an absent buffer, `notRendered` for one
that holds no document, and `parse` for a parse the port refused. -/
def appendMarkdown (id : BufferId) (more : String) : EditorM (Except Refusal Unit) := do
  let some buffer := (← editorState).buffer? id | return .error (.buffer (.noSuchBuffer id))
  let some old := buffer.markdown | return .error .notRendered
  let table ← languageTable
  match ← SyntaxTree.lift (Markdown.parse (table.map (·.1)) (old.tail more)) with
  | .error refusal =>
    return .error (.parse refusal)
  | .ok layers =>
    let doc := old.extend more layers (facesOf table)
    let doc ← measureFrom doc (old.blocks.size - 1)
    Markdown.apply id doc (Doc.firstChanged old doc)

end Editor.BufferId
