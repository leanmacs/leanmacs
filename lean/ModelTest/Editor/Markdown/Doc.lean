import Editor.Markdown.Doc
import ModelTest.Check
import ModelTest.Support.Markdown

/-!
# Model tests: `Editor/Markdown/Doc.lean`

The model tests of the Markdown renderer (`Editor/Markdown/Doc.lean` and the
modules it imports): `markdownProseChecks`, `markdownHeadingChecks`,
`markdownTableChecks`, `markdownLinkChecks`, `markdownFoldChecks`,
`markdownListChecks` and `markdownStreamChecks`. Each renders a fixture of `tests/markdown/` from its
canned layers (`ModelTest.Support.Markdown`) and asserts the exact rendered
text and the span, link or fold over named substrings. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Markdown

/-- The faces the checks draw a fence's captures in: a keyword in
`syntax.keyword`, a function in `syntax.function`, and nothing else. -/
def markdownFaces (_ : String) (name : String) : Option FaceName :=
  if name == "keyword" || name == "function" then some ⟨s!"syntax.{name}"⟩ else none

/-- The root the checks resolve relative links against. -/
def markdownRoot : System.FilePath :=
  "/work"

/-- The options the checks render with. -/
def markdownOptions : Options :=
  { root := some markdownRoot, faces := markdownFaces }

/-- `fixture` rendered with `markdownOptions`, described. -/
def described (fixture : Cases.Fixture) : Description :=
  (Markdown.render markdownOptions fixture.source fixture.layers).description

/-- The range of the `nth` place, from 0, that `needle` is in `text`, in
bytes; `(0, 0)` when it is not there that many times. -/
def overNth (text needle : String) (nth : Nat) : Nat × Nat :=
  let parts : List String := text.splitOn needle
  if nth + 1 < parts.length then
    let start := ((parts.take (nth + 1)).map (·.utf8ByteSize)).sum + nth * needle.utf8ByteSize
    (start, start + needle.utf8ByteSize)
  else (0, 0)

/-- The range of the first place `needle` is in `text`. -/
def over (text needle : String) : Nat × Nat :=
  overNth text needle 0

/-- Whether a span of `description` in `face` covers every byte of the
range `range`. -/
def coveredBy (description : Description) (face : String) (range : Nat × Nat) : Bool :=
  range.1 < range.2 &&
    description.spans.any fun span =>
      span.face == ⟨face⟩ && span.start ≤ range.1 && range.2 ≤ span.stop

/-- Whether no span of `description` in `face` holds a byte of `range`. -/
def untouchedBy (description : Description) (face : String) (range : Nat × Nat) : Bool :=
  !description.spans.any fun span =>
      span.face == ⟨face⟩ && span.start < range.2 && range.1 < span.stop

/-- The checks that rendered prose is in the prose face, code in
`text.code-block` with its layer's captures in their faces, and the markup
characters left out (**criterion 2**). -/
def markdownProseChecks : List Check :=
  let prose := described Support.Markdown.prose
  let code := described Support.Markdown.code
  [{  name :=
        "prose.md renders its exact text: the delimiters, the escapes' backslashes and the breaks' markup gone, a soft break one space and a hard break a line feed"
      run :=
        pure <|
          prose.text ==
            "A paragraph with emphasis, strong text and code in it, running onto a second line.\n\nA hard break ends this line\nand a backslash one ends this\none. An escaped *star* and inline <b>HTML</b>." },
    { name :=
        "every byte of prose.md's rendered text but the blank line between its blocks is under text.prose"
      run :=
        pure <|
          coveredBy prose "text.prose" (over prose.text "A paragraph") &&
            coveredBy prose "text.prose" (0, (over prose.text "second line.").2) &&
            coveredBy prose "text.prose" ((over prose.text "A hard").1, prose.text.utf8ByteSize) },
    { name :=
        "code.md renders each fence's rows and each indented block's, with the fence lines, the info strings and the indent gone"
      run :=
        pure <|
          code.text ==
              "fn main() {\n    let x = 1;\n}\n\n{\"a\": 1}\n\nplain text\n\nindented code\nsecond row\n\n• an item\nfn f() {}" &&
            !code.text.any (· == '`') },
    { name :=
        "a fence's and an indented block's rows are under text.code-block and not under text.prose, and the prose around them is"
      run :=
        pure <|
          ["fn main() {\n    let x = 1;\n}", "{\"a\": 1}", "plain text",
                  "indented code\nsecond row", "fn f() {}"].all
              (fun rows =>
                coveredBy code "text.code-block" (over code.text rows) &&
                  untouchedBy code "text.prose" (over code.text rows)) &&
            coveredBy code "text.prose" (over code.text "• an item") },
    { name :=
        "the rust fence's captures are drawn in their faces, a fence in a language no grammar has in text.code-block alone, and a capture with no face in none"
      run :=
        pure <|
          coveredBy code "syntax.keyword" (over code.text "fn") &&
            coveredBy code "syntax.keyword" (over code.text "let") &&
            coveredBy code "syntax.function" (over code.text "main") &&
            untouchedBy code "syntax.keyword" (over code.text "plain text") &&
            code.spans.all fun span =>
              ["text.prose", "text.code-block", "text.list-marker", "syntax.keyword",
                    "syntax.function"].contains
                span.face.name },
    { name := "a fence inside a list item renders its code rows, with its captures"
      run :=
        pure <|
          coveredBy code "text.code-block" (over code.text "fn f() {}") &&
            coveredBy code "syntax.keyword" (overNth code.text "fn" 1) }]

/-- The checks that headings render in their heading faces, and emphasis,
strong and code spans in theirs, the markup gone (**criterion 3**, the
faces; the sizes are the heading faces' own, pinned by
`ModelTest.faceChecks`). -/
def markdownHeadingChecks : List Check :=
  let headings := described Support.Markdown.headings
  let prose := described Support.Markdown.prose
  [{  name := "headings.md renders each heading's text alone, its marker and underline gone"
      run :=
        pure <|
          headings.text ==
            "One\n\nTwo\n\nThree\n\nFour\n\nFive\n\nSix\n\nSetext one\n\nSetext two" },
    { name :=
        "each heading's text is under text.heading of its level, a setext heading's too, and under the prose face"
      run :=
        pure <|
          [("One", 1), ("Two", 2), ("Three", 3), ("Four", 4), ("Five", 5), ("Six", 6),
                ("Setext one", 1), ("Setext two", 2)].all
            fun (text, level) =>
            coveredBy headings s!"text.heading.{level}" (over headings.text text) &&
              coveredBy headings "text.prose" (over headings.text text) &&
              (List.range 6).all fun other =>
                other + 1 == level ||
                  untouchedBy headings s!"text.heading.{other + 1}" (over headings.text text) },
    { name :=
        "emphasis, strong and a code span are under text.emphasis, text.strong and text.code-span, over their text alone"
      run :=
        pure <|
          prose.spans.contains (span 17 25 "text.emphasis") &&
            prose.spans.contains (span 27 33 "text.strong") &&
            prose.spans.contains (span 43 47 "text.code-span") &&
            over prose.text "emphasis" == (17, 25) &&
            over prose.text "strong" == (27, 33) &&
            over prose.text "code" == (43, 47) },
    { name := "an escape shows its character, and inline HTML its source"
      run :=
        pure <|
          over prose.text "*star*" != (0, 0) && over prose.text "<b>HTML</b>" != (0, 0) &&
            untouchedBy prose "text.emphasis" (over prose.text "*star*") }]

/-- The checks of a table rendered into rows of cells (the pure half of
**criterion 4**; `markdownTableViewChecks` measures them into stops). -/
def markdownTableChecks : List Check :=
  let table := described Support.Markdown.table
  [{  name :=
        "table.md renders its header row and its body rows, a row a line, the delimiter row and the pipes gone, cells joined by one space"
      run := pure <| table.text == "Name Value\na 1\nbb two\nccc" },
    { name := "the table's cells are its description's table, row by row, the missing cell absent"
      run :=
        pure <|
          table.tables ==
              #[{
                  rows :=
                    #[#[(0, 4), (5, 10)], #[(11, 12), (13, 14)], #[(15, 17), (18, 21)],
                      #[(22, 25)]] }] &&
            over table.text "Name" == (0, 4) &&
            over table.text "two" == (18, 21) },
    { name := "the header's cells are under text.table-header, and no body cell is"
      run :=
        pure <|
          coveredBy table "text.table-header" (over table.text "Name") &&
            coveredBy table "text.table-header" (over table.text "Value") &&
            untouchedBy table "text.table-header" (11, 25) },
    { name :=
        "a cell holding a code span renders it from its inline layer, its backticks gone and its text under text.code-span"
      run :=
        pure <|
          coveredBy table "text.code-span" (over table.text "two") && !table.text.any (· == '`') }]

/-- The link `description` has over the first place `needle` is in its
text, if one is exactly over it. -/
def markdownLinkOver (description : Description) (needle : String) : Option LinkTarget :=
  let (start, stop) := over description.text needle
  (description.links.find? fun link => link.start == start && link.stop == stop).map (·.target)

/-- The checks of links and `path:line` references rendered as followable
spans with their targets (**criterion 5**). -/
def markdownLinkChecks : List Check :=
  let links := described Support.Markdown.links
  [{  name :=
        "links.md renders each link's text alone, an autolink's address without its angles, and a reference link as its source"
      run :=
        pure <|
          links.text ==
            "An inline link, a task, an absolute file and a relative one.\n\nAn autolink https://auto.example, an email me@example.com and a bare https://bare.example/path. too.\n\nSee src/a.rs:12 and src/b.rs:3 for more.\n\nAn image the logo and a [reference][ref] link.\n\nA badge CI links to its build.\n\n[ref]: https://ref.example" },
    { name := "an inline link to a URL links its text to the URL"
      run :=
        pure <| markdownLinkOver links "inline link" == some (.url "https://example.com/page") },
    { name := "an inline link to an rdm: reference links its text to the reference in its scheme"
      run := pure <| markdownLinkOver links "task" == some (.reference "rdm" "task/x") },
    { name := "an inline link to an absolute path:line links to its row"
      run := pure <| markdownLinkOver links "absolute file" == some (.location "/etc/hosts" 2 0) },
    { name :=
        "an inline link to a relative path:line:column links to its row and column under the root"
      run :=
        pure <|
          markdownLinkOver links "relative one" ==
            some (.location (markdownRoot / "src/main.rs") 11 4) },
    { name := "an autolink links its address, and an email autolink its address as mailto:"
      run :=
        pure <|
          markdownLinkOver links "https://auto.example" == some (.url "https://auto.example") &&
            markdownLinkOver links "me@example.com" == some (.url "mailto:me@example.com") },
    { name := "a bare URL in prose links to itself, its trailing full stop left out"
      run :=
        pure <|
          markdownLinkOver links "https://bare.example/path" ==
            some (.url "https://bare.example/path") },
    { name := "a path:line in prose and one in a code span each link to its row under the root"
      run :=
        pure <|
          markdownLinkOver links "src/a.rs:12" ==
              some (.location (markdownRoot / "src/a.rs") 11 0) &&
            markdownLinkOver links "src/b.rs:3" ==
              some (.location (markdownRoot / "src/b.rs") 2 0) &&
            coveredBy links "text.code-span" (over links.text "src/b.rs:3") },
    { name := "an image shows its description, linked to its source"
      run :=
        pure <|
          markdownLinkOver links "the logo" ==
            some (.location (markdownRoot / "images/logo.png") 0 0) },
    { name :=
        "an image in a link's text links its description to the link's destination alone, not to the image's source"
      run :=
        pure <|
          let (start, stop) := over links.text "CI"
          markdownLinkOver links "CI" == some (.url "https://ci.example.com") &&
            (links.links.filter fun link => link.start < stop && start < link.stop).size == 1 },
    { name := "a reference link is left as its source and not linked, nor is its definition"
      run :=
        pure <|
          let (start, stop) := over links.text "[reference][ref]"
          let (defined, _) := over links.text "[ref]: https://ref.example"
          start < stop &&
            links.links.all fun link =>
              link.stop ≤ start || stop ≤ link.start && link.stop ≤ defined },
    { name := "the links are exactly these eleven, in order of start"
      run :=
        pure <|
          links.links.size == 11 &&
            (links.links.map (·.start)) == (links.links.map (·.start)).qsort (· < ·) },
    { name :=
        "with no root a relative link and a relative path:line are not linked, and an absolute one and a badge's URL still are"
      run :=
        pure <|
          let rootless :=
            (Markdown.render {} Support.Markdown.links.source
                Support.Markdown.links.layers).description
          markdownLinkOver rootless "relative one" == none &&
            markdownLinkOver rootless "src/a.rs:12" == none &&
            markdownLinkOver rootless "the logo" == none &&
            markdownLinkOver rootless "CI" == some (.url "https://ci.example.com") &&
            markdownLinkOver rootless "absolute file" == some (.location "/etc/hosts" 2 0) }]

/-- The checks of the foldable ranges a rendered document declares
(**criterion 6**). -/
def markdownFoldChecks : List Check :=
  let folds := described Support.Markdown.folds
  let text := folds.text
  let heading (key name : String) (level : Nat) (stop : Nat) : Foldable :=
    { start := (over text name).1, stop, key, text := name ++ " …"
      decorations := #[span 0 name.utf8ByteSize s!"text.heading.{level}"] }
  let code (key rows placeholder : String) : Foldable :=
    { start := (over text rows).1, stop := (over text rows).2, key, text := placeholder
      decorations := #[span 0 placeholder.utf8ByteSize "text.code-block"] }
  -- The empty fence renders as the empty row between the json fence and B.
  let empty := (over text "{\"b\": 2}").2 + 2
  [{  name := "folds.md renders its headings and fences in order, an empty fence as an empty row"
      run :=
        pure <|
          text ==
              "A\n\nText a.\n\nA.1\n\nText a1.\n\nA.1.1\n\nfn one() {}\n\nA.2\n\n{\"b\": 2}\n\n\n\nB\n\nText b." &&
            slice text (empty - 2) (empty + 2) == "\n\n\n\n" },
    { name :=
        "each heading is a range from its text to the next heading of the same or a higher level, or the end, and each fence one over its rows, an empty one over its empty row, keyed by ordinal, with its placeholder, in order of start"
      run :=
        pure <|
          folds.folds ==
            #[heading "heading 1" "A" 1 (over text "B").1,
              heading "heading 2" "A.1" 2 (over text "A.2").1,
              heading "heading 3" "A.1.1" 3 (over text "A.2").1,
              code "code 1" "fn one() {}" "rust, 1 line",
              heading "heading 4" "A.2" 2 (over text "B").1,
              code "code 2" "{\"b\": 2}" "json, 1 line",
              { start := empty, stop := empty, key := "code 3", text := "text, 0 lines"
                decorations := #[span 0 "text, 0 lines".utf8ByteSize "text.code-block"] },
              heading "heading 5" "B" 1 text.utf8ByteSize] },
    { name := "every foldable range is declared unfolded"
      run := pure <| !folds.folds.isEmpty && folds.folds.all (!·.folded) },
    { name :=
        "a fence of several rows says how many, each fence keyed by its ordinal and an indented block declaring none"
      run :=
        pure <|
          let code := described Support.Markdown.code
          (code.folds.map (·.text)) ==
              #["rust, 3 lines", "json, 1 line", "nosuch, 1 line", "rust, 1 line"] &&
            (code.folds.map (·.key)) == #["code 1", "code 2", "code 3", "code 4"] }]

/-- The checks of lists, block quotes and a thematic break rendered with
their markup left out (**criterion 2**), over `lists.md`. -/
def markdownListChecks : List Check :=
  let lists := described Support.Markdown.lists
  let text := lists.text
  let markers :=
    (lists.spans.filter (·.face == ⟨"text.list-marker"⟩)).map fun span => (span.start, span.stop)
  [{  name :=
        "lists.md renders an item a line, two spaces a nesting level, a bullet as •, an ordered item's own number, a quote's blocks without their > and a thematic break as ———"
      run :=
        pure <|
          text ==
              "• one\n• two\n  • two point one\n  • two point two\n• three\n\n1. first\n2. second\n\nA quote\n\nnested quote\n\n———" &&
            !text.any (· == '>') &&
            !text.any (· == '-') },
    { name :=
        "text.list-marker is over each item's marker alone, a nested item's after its indent, and over nothing else"
      run :=
        pure <|
          let line (item : String) : Nat := (over text item).1
          markers ==
              #[overNth text "•" 0, overNth text "•" 1, overNth text "•" 2, overNth text "•" 3,
                overNth text "•" 4, over text "1.", over text "2."] &&
            (overNth text "•" 2).1 == line "  • two point one" + 2 &&
            (overNth text "•" 3).1 == line "  • two point two" + 2 &&
            (over text "1.").1 == line "1. first" },
    { name :=
        "text.quote is over the quote's blocks, the nested quote's too, and over nothing outside the quote"
      run :=
        pure <|
          let quote := over text "A quote\n\nnested quote"
          lists.spans.contains (span quote.1 quote.2 "text.quote") &&
            lists.spans.contains
              (span (over text "nested quote").1 (over text "nested quote").2 "text.quote") &&
            untouchedBy lists "text.quote" (0, quote.1) &&
            untouchedBy lists "text.quote" (over text "———") &&
            coveredBy lists "text.prose" (over text "———") }]

/-- How many top-level blocks `fixture`'s canned layers capture. -/
def blockCount (fixture : Cases.Fixture) : Nat :=
  ((Parsed.of fixture.layers).nodes.filter (·.name == Parsed.block)).size

/-- The stream's tails, as checked in: what each append after the first
chunk parses. -/
def streamTails : Array Cases.Fixture :=
  #[Support.Markdown.streamTail1, Support.Markdown.streamTail2, Support.Markdown.streamTail3]

/-- The stream rendered: `stream-head.md` from its canned layers, then each
later chunk appended with the canned layers of its tail; each document on
the way, the first included, and the tail each append asked to parse. -/
def streamed : Array Doc × Array String :=
  let head :=
    Markdown.render markdownOptions Support.Markdown.streamHead.source
      Support.Markdown.streamHead.layers
  ((Support.Markdown.streamChunks.extract 1 4).zip streamTails).foldl
    (fun (docs, asked) (chunk, tail) =>
      let doc := docs.back!
      (docs.push (doc.extend chunk tail.layers markdownFaces), asked.push (doc.tail chunk)))
    (#[head], #[])

/-- The reply's tails, as checked in: what each append after the empty
render parses, the whole source so far each time. -/
def replyTails : Array Cases.Fixture :=
  #[Support.Markdown.replyHead, Support.Markdown.reply]

/-- A reply streamed from nothing: `empty.md` rendered from its canned
layers, then each of the reply's chunks appended with the canned layers of
its tail; each document on the way, the first included, and the tail each
append asked to parse. -/
def replied : Array Doc × Array String :=
  let empty :=
    Markdown.render markdownOptions Support.Markdown.empty.source Support.Markdown.empty.layers
  (Support.Markdown.replyChunks.zip replyTails).foldl
    (fun (docs, asked) (chunk, tail) =>
      let doc := docs.back!
      (docs.push (doc.extend chunk tail.layers markdownFaces), asked.push (doc.tail chunk)))
    (#[empty], #[])

/-- The checks that an append re-renders only the changed tail
(**criterion 7**), and that the document it makes describes the whole
render. -/
def markdownStreamChecks : List Check :=
  let (docs, asked) := streamed
  let whole :=
    Markdown.render markdownOptions Support.Markdown.stream.source Support.Markdown.stream.layers
  [{  name := "the stream's chunks make stream.md"
      run :=
        pure <|
          String.join Support.Markdown.streamChunks.toList == Support.Markdown.stream.source &&
            docs.back!.source == Support.Markdown.stream.source },
    { name :=
        "each append asks to parse exactly the stream's tail checked in for it: the last block so far and the chunk"
      run := pure <| asked == streamTails.map (·.source) },
    { name :=
        "the head renders its two blocks, and each append renders only the two blocks of its tail, fewer than the whole document's five"
      run :=
        pure <|
          docs.map (·.rendered) == #[2, 4, 6, 8] &&
            -- The literals are each fixture's own block count, so a
            -- refreshed fixture that changes one fails here.
            blockCount Support.Markdown.streamHead == 2 &&
            streamTails.all (blockCount · == 2) &&
            blockCount Support.Markdown.stream == 5 &&
            whole.rendered == 5 },
    { name :=
        "the document the appends make describes what rendering stream.md whole does, its relative link in the last chunk resolved against the root"
      run :=
        pure <|
          docs.back!.description == whole.description &&
            docs.back!.description.links ==
              #[{ start := (over whole.description.text "the file").1
                  stop := (over whole.description.text "the file").2
                  target := .location (markdownRoot / "src/s.rs") 1 0 }] },
    { name :=
        "a heading in the kept prefix keeps its key, and its fold grows to cover the appended blocks"
      run :=
        pure <|
          let first := docs[0]!.description.folds
          let last := docs.back!.description.folds
          first.map (·.key) == #["heading 1"] &&
            (first[0]?.map (·.stop)) == some docs[0]!.description.text.utf8ByteSize &&
            (last.find? (·.key == "heading 1")).map (·.stop) ==
              some docs.back!.description.text.utf8ByteSize },
    { name :=
        "every byte of the text before the first changed offset is the same after an append, and the first changed offset is past the kept blocks"
      run :=
        pure <|
          (docs.zip (docs.extract 1 docs.size)).all fun (old, new) =>
            let changed := Doc.firstChanged old new
            let oldText := old.description.text
            let newText := new.description.text
            changed > 0 && slice oldText 0 changed == slice newText 0 changed &&
              changed ==
                (offsetsOf new.pieces)[old.blocks.size - 2]! +
                  new.pieces[old.blocks.size - 2]!.text.utf8ByteSize },
    { name :=
        "from an empty render of no block, each append asks to parse the whole source so far: reply-head.md, one unfinished paragraph, then reply.md"
      run :=
        pure <|
          let (docs, asked) := replied
          docs[0]!.blocks.isEmpty && docs[0]!.description.text == "" &&
            asked == replyTails.map (·.source) &&
            String.join Support.Markdown.replyChunks.toList == Support.Markdown.reply.source },
    { name :=
        "an append to a document of no block renders only its tail's one block, and one to a document of one block only the two of its tail"
      run :=
        pure <|
          let (docs, _) := replied
          docs.map (·.rendered) == #[0, 1, 3] && blockCount Support.Markdown.empty == 0 &&
            blockCount Support.Markdown.replyHead == 1 &&
            blockCount Support.Markdown.reply == 2 },
    { name :=
        "an append to a document of no block or of one block keeps none of it, so the first changed offset is 0"
      run :=
        pure <|
          let (docs, _) := replied
          docs.size == 3 && Doc.firstChanged docs[0]! docs[1]! == 0 &&
            Doc.firstChanged docs[1]! docs[2]! == 0 &&
            Doc.kept docs[1]! docs[2]! == 0 },
    { name :=
        "the document the appends make from an empty render describes what rendering reply.md whole does"
      run :=
        pure <|
          let (docs, _) := replied
          let whole :=
            Markdown.render markdownOptions Support.Markdown.reply.source
              Support.Markdown.reply.layers
          docs.back!.source == Support.Markdown.reply.source &&
            docs.back!.description == whole.description &&
            !whole.description.tables.isEmpty }]

end ModelTest
