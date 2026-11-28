import Editor.Markdown.Parse
import ModelTest.Check

/-!
# Model tests: `Editor/Markdown/Parse.lean`

The model tests of `Editor/Markdown/Parse.lean`: `markdownParseChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Markdown

/-- The checks of the languages a Markdown text is parsed once with
(`Markdown.languagesOf`). -/
def markdownParseChecks : List Check :=
  [{  name :=
        "a Markdown text is parsed once with markdown's rendered query and its injections then its rendered injections joined by a line, markdown_inline's rendered query and its injections, then each other grammar once, in order, with its highlights and injections; a tree with no query of the kind it needs is left out"
      run :=
        let markdown : Mode.SyntaxTree :=
          { grammar := "markdown", highlights := some "(document) @d"
            injections := some "(fenced_code_block) @injection.content"
            rendered := some "(section) @block"
            renderedInjections := some "(pipe_table_cell) @injection.content" }
        let inline : Mode.SyntaxTree :=
          { grammar := "markdown_inline", rendered := some "(emphasis) @emphasis"
            injections := some "(html_tag) @injection.content" }
        let rust : Mode.SyntaxTree :=
          { grammar := "rust", highlights := some "(identifier) @variable"
            injections := some "(macro_invocation) @injection.content" }
        let json : Mode.SyntaxTree := { grammar := "json", highlights := some "(number) @n" }
        let plain : Mode.SyntaxTree := { grammar := "toml" }
        pure
          (languagesOf
                [rust, markdown, plain, json, { rust with highlights := some "(later) @l" },
                  inline] ==
              #[{ grammar := "markdown", query := "(section) @block"
                  injections :=
                    some
                      "(fenced_code_block) @injection.content\n(pipe_table_cell) @injection.content" },
                { grammar := "markdown_inline", query := "(emphasis) @emphasis"
                  injections := some "(html_tag) @injection.content" },
                { grammar := "rust", query := "(identifier) @variable"
                  injections := some "(macro_invocation) @injection.content" },
                { grammar := "json", query := "(number) @n" }] &&
            languagesOf [{ markdown with renderedInjections := none }] ==
              #[{ grammar := "markdown", query := "(section) @block"
                  injections := some "(fenced_code_block) @injection.content" }] &&
            languagesOf [{ markdown with rendered := none }, { inline with rendered := none }] ==
              #[]) }]

end ModelTest
