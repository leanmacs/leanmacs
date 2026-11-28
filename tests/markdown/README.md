# Markdown fixtures

Each fixture is a pair: a Markdown text, `<case>.md`, and the layers the
library answers of it parsed once for a rendered view,
`<case>.layers.json` (`lean/Editor/Markdown/Cases.lean`). The Lean model of
the syntax tree port answers each text its canned layers, so the renderer's
and the rendered view's tests (`lean/ModelTest/Editor/Markdown/`) run on
the library's real parses with no Rust; `contract-test`
(`ContractTest.markdownCaseChecks`) holds the library to answer each text
exactly the layers checked in beside it.

| Fixture | What it holds |
|---|---|
| `prose.md` | paragraphs, a soft break, a hard break of two spaces and one of a backslash, emphasis, strong, a code span, two escapes and inline HTML |
| `headings.md` | ATX headings of levels 1 to 6 and a setext heading of each level |
| `code.md` | a `rust` fence, a `json` fence, a fence in a language no grammar has, an indented block, and a fence inside a list item |
| `table.md` | a header, three body rows, one of them with a missing cell, and a code span in a cell |
| `links.md` | inline links to a URL, an `rdm:` reference, an absolute `path:line` and a relative `path:line:column`; an autolink, an email autolink, a bare URL, a `path:line` in prose and in a code span, an image, an image inside a link (a badge), and a reference link with its definition |
| `folds.md` | headings of levels 1, 2, 3, 2 and 1, and three fences, the last of them empty |
| `lists.md` | a bullet list with a nested list, an ordered list, a block quote with a nested quote, and a thematic break |
| `view.md` | a heading, a paragraph with emphasis, a link and a `path:line`, and a fence: what the rendered view's checks write into a buffer |
| `stream.md` | a whole streamed document: a heading, a paragraph, a fence, a table and a paragraph with a relative link |
| `stream-head.md` | its first chunk, cut mid-paragraph: what the first render parses |
| `stream-tail-1.md` ... `stream-tail-3.md` | the tails each later chunk has parsed: the last block so far and the chunk, cut inside an open fence the next chunk closes and in a table that gains a row |

The stream's chunks are `ModelTest.Support.Markdown.streamChunks`; the tails
are what `Markdown.Doc.tail` asks after each.

## Refreshing a layers file

When the library's answer changes (a grammar, a rendered query or the
injection rule), `contract-test` fails the fixture's check and prints the
library's answer as a layers file, between `contract-test: the library's
layers of tests/markdown/<case>.md:` and `contract-test: end of <case>`.
Read it before checking it in: each capture should name the node it says.

Lake does not track a file read with `include_str`: a build after a fixture
changes keeps the modules that read it as they were. Remove their traces,
`lean/.lake/build/lib/lean/ContractTest/Editor/Markdown/Cases.trace` and
`lean/.lake/build/lib/lean/ModelTest/Support/Markdown.trace`, so the next
build reads the fixtures again. A clean checkout, as the gate's, always
reads them.
