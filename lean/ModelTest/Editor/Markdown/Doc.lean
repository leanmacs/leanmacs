import Editor.Markdown.Doc
import ModelTest.Check
import ModelTest.Support.Markdown

/-!
# Model tests: `Editor/Markdown/Doc.lean`

The model tests of the Markdown renderer (`Editor/Markdown/Doc.lean` and the
modules it imports): `markdownProseChecks`, `markdownHeadingChecks`,
`markdownTableChecks`, `markdownLinkChecks`, `markdownFoldChecks` and
`markdownStreamChecks`. Each renders a fixture of `tests/markdown/` from its
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

end ModelTest
