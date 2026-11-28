import Editor.Markdown.Cases
import Editor.SyntaxTree
import Editor.SyntaxTree.Model

/-!
# Model tests: support: Markdown

The Markdown fixtures under `tests/markdown/`, each read with `include_str`
at build time into a `Cases.Fixture` (`fixtures`), and the canned answers
of the syntax tree model they make (`canned`), so a check of the renderer
and of the rendered view runs on the library's real parses with no Rust
(`Editor/Markdown/Cases.lean`). Shared by the rendered-markdown test modules
(`ModelTest/Editor/Markdown/`); it holds no checks of its own. Lake does
not track a file `include_str` reads: `tests/markdown/README.md` says how a
changed fixture is rebuilt.
-/

namespace ModelTest.Support.Markdown

open Editor
open Editor.Markdown

/-- The fixture `name`, of the text `source` and the layers file
`layersFile`; its layers are none when the file does not decode, which
`ModelTest.markdownCaseChecks` reports. -/
def fixture (name source layersFile : String) : Cases.Fixture :=
  { name, source, layers := (Cases.decode layersFile).toOption.getD #[] }

/-- The layers file of `tests/markdown/prose.md`, as checked in. -/
def proseLayers : String :=
  include_str "../../../tests/markdown/prose.layers.json"

/-- `tests/markdown/prose.md` and its layers. -/
def prose : Cases.Fixture :=
  fixture "prose" (include_str "../../../tests/markdown/prose.md") proseLayers

/-- The layers file of `tests/markdown/headings.md`, as checked in. -/
def headingsLayers : String :=
  include_str "../../../tests/markdown/headings.layers.json"

/-- `tests/markdown/headings.md` and its layers. -/
def headings : Cases.Fixture :=
  fixture "headings" (include_str "../../../tests/markdown/headings.md") headingsLayers

/-- The layers file of `tests/markdown/code.md`, as checked in. -/
def codeLayers : String :=
  include_str "../../../tests/markdown/code.layers.json"

/-- `tests/markdown/code.md` and its layers. -/
def code : Cases.Fixture :=
  fixture "code" (include_str "../../../tests/markdown/code.md") codeLayers

/-- The layers file of `tests/markdown/table.md`, as checked in. -/
def tableLayers : String :=
  include_str "../../../tests/markdown/table.layers.json"

/-- `tests/markdown/table.md` and its layers. -/
def table : Cases.Fixture :=
  fixture "table" (include_str "../../../tests/markdown/table.md") tableLayers

/-- The layers file of `tests/markdown/links.md`, as checked in. -/
def linksLayers : String :=
  include_str "../../../tests/markdown/links.layers.json"

/-- `tests/markdown/links.md` and its layers. -/
def links : Cases.Fixture :=
  fixture "links" (include_str "../../../tests/markdown/links.md") linksLayers

/-- The layers file of `tests/markdown/folds.md`, as checked in. -/
def foldsLayers : String :=
  include_str "../../../tests/markdown/folds.layers.json"

/-- `tests/markdown/folds.md` and its layers. -/
def folds : Cases.Fixture :=
  fixture "folds" (include_str "../../../tests/markdown/folds.md") foldsLayers

/-- The layers file of `tests/markdown/lists.md`, as checked in. -/
def listsLayers : String :=
  include_str "../../../tests/markdown/lists.layers.json"

/-- `tests/markdown/lists.md` and its layers. -/
def lists : Cases.Fixture :=
  fixture "lists" (include_str "../../../tests/markdown/lists.md") listsLayers

/-- The layers file of `tests/markdown/view.md`, as checked in. -/
def viewLayers : String :=
  include_str "../../../tests/markdown/view.layers.json"

/-- `tests/markdown/view.md` and its layers. -/
def view : Cases.Fixture :=
  fixture "view" (include_str "../../../tests/markdown/view.md") viewLayers

/-- The layers file of `tests/markdown/stream.md`, as checked in. -/
def streamLayers : String :=
  include_str "../../../tests/markdown/stream.layers.json"

/-- `tests/markdown/stream.md` and its layers. -/
def stream : Cases.Fixture :=
  fixture "stream" (include_str "../../../tests/markdown/stream.md") streamLayers

/-- The layers file of `tests/markdown/stream-head.md`, as checked in. -/
def streamHeadLayers : String :=
  include_str "../../../tests/markdown/stream-head.layers.json"

/-- `tests/markdown/stream-head.md` and its layers. -/
def streamHead : Cases.Fixture :=
  fixture "stream-head" (include_str "../../../tests/markdown/stream-head.md") streamHeadLayers

/-- The layers file of `tests/markdown/stream-tail-1.md`, as checked in. -/
def streamTail1Layers : String :=
  include_str "../../../tests/markdown/stream-tail-1.layers.json"

/-- `tests/markdown/stream-tail-1.md` and its layers. -/
def streamTail1 : Cases.Fixture :=
  fixture "stream-tail-1" (include_str "../../../tests/markdown/stream-tail-1.md") streamTail1Layers

/-- The layers file of `tests/markdown/stream-tail-2.md`, as checked in. -/
def streamTail2Layers : String :=
  include_str "../../../tests/markdown/stream-tail-2.layers.json"

/-- `tests/markdown/stream-tail-2.md` and its layers. -/
def streamTail2 : Cases.Fixture :=
  fixture "stream-tail-2" (include_str "../../../tests/markdown/stream-tail-2.md") streamTail2Layers

/-- The layers file of `tests/markdown/stream-tail-3.md`, as checked in. -/
def streamTail3Layers : String :=
  include_str "../../../tests/markdown/stream-tail-3.layers.json"

/-- `tests/markdown/stream-tail-3.md` and its layers. -/
def streamTail3 : Cases.Fixture :=
  fixture "stream-tail-3" (include_str "../../../tests/markdown/stream-tail-3.md") streamTail3Layers

/-- The chunks `tests/markdown/stream.md` arrives in, in order: the first
is `stream-head.md`; each later one, cut mid-paragraph, inside an open
fence the next closes and in a table that gains a row, is appended. -/
def streamChunks : Array String :=
  #[streamHead.source, "ives in two chunks.\n\n```rust\nfn str",
    "eamed() {}\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n",
    "| 3 | 4 |\n\nSee [the file](src/s.rs:2).\n"]

/-- The layers file of `tests/markdown/empty.md`, as checked in. -/
def emptyLayers : String :=
  include_str "../../../tests/markdown/empty.layers.json"

/-- `tests/markdown/empty.md`, the empty document, and its layers. -/
def empty : Cases.Fixture :=
  fixture "empty" (include_str "../../../tests/markdown/empty.md") emptyLayers

/-- The layers file of `tests/markdown/reply-head.md`, as checked in. -/
def replyHeadLayers : String :=
  include_str "../../../tests/markdown/reply-head.layers.json"

/-- `tests/markdown/reply-head.md` and its layers. -/
def replyHead : Cases.Fixture :=
  fixture "reply-head" (include_str "../../../tests/markdown/reply-head.md") replyHeadLayers

/-- The layers file of `tests/markdown/reply.md`, as checked in. -/
def replyLayers : String :=
  include_str "../../../tests/markdown/reply.layers.json"

/-- `tests/markdown/reply.md` and its layers. -/
def reply : Cases.Fixture :=
  fixture "reply" (include_str "../../../tests/markdown/reply.md") replyLayers

/-- The chunks `tests/markdown/reply.md` arrives in after an empty render,
in order: the first is `reply-head.md`, one unfinished paragraph; the
second finishes it and adds a table. Each append's tail is the whole
source so far, so the first asks `reply-head.md` and the second
`reply.md`. -/
def replyChunks : Array String :=
  #[replyHead.source, "graph.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"]

/-- Every fixture, with its layers file as checked in. -/
def files : Array (Cases.Fixture × String) :=
  #[(prose, proseLayers), (headings, headingsLayers), (code, codeLayers), (table, tableLayers),
    (links, linksLayers), (folds, foldsLayers), (lists, listsLayers), (view, viewLayers),
    (stream, streamLayers), (streamHead, streamHeadLayers), (streamTail1, streamTail1Layers),
    (streamTail2, streamTail2Layers), (streamTail3, streamTail3Layers), (empty, emptyLayers),
    (replyHead, replyHeadLayers), (reply, replyLayers)]

/-- Every fixture. -/
def fixtures : Array Cases.Fixture :=
  files.map (·.1)

/-- The canned answers of the syntax tree model (`SyntaxTreeModel.once`):
each fixture's layers, by the host grammar `markdown` and its text. -/
def canned : Array (String × String × Array SyntaxTree.Layer) :=
  fixtures.map fun fixture => ("markdown", fixture.source, fixture.layers)

end ModelTest.Support.Markdown
