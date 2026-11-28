import Editor.Language.Grammar
import Editor.Package

/-!
# The test package `ini-grammar`

A package outside the core that ships a grammar, used by tests alone
(`docs/design/packages.md`, "A package's grammars"). It registers the
language `ini`, of `*.ini` files, which names the grammar `ini`, a grammar
no default package ships; and it declares that grammar per platform,
each library and the query directory relative to its Lake package's
`grammars/` directory, where the package keeps their files. The set's
build stages that directory beside the editor, and the editor resolves the
declaration against the staged copy.

It imports the grammar declaration and the package type, which brings the
editor API, and nothing else.
-/

namespace IniGrammar

open Editor

/-- The libraries of the grammar `ini`, by platform, relative to the
package's `grammars/` directory: one directory per platform, each holding
the library `tree-sitter build` makes there. -/
def libraries : List (String × System.FilePath) :=
  [("darwin-aarch64", "darwin-aarch64/libtree-sitter-ini.dylib"),
    ("darwin-x86_64", "darwin-x86_64/libtree-sitter-ini.dylib"),
    ("linux-aarch64", "linux-aarch64/libtree-sitter-ini.so"),
    ("linux-x86_64", "linux-x86_64/libtree-sitter-ini.so")]

/-- The language `ini`: `*.ini` files, parsed with the grammar `ini` and
highlighted with the queries its declaration's directory holds. -/
def language : Language :=
  { name := "ini", patterns := [.extension "ini"], syntaxTree := { grammar := "ini" } }

/-- The package: the language `ini`, and the grammar `ini` per platform,
its queries under `queries/`. -/
def package : Package :=
  { name := "ini-grammar"
    setup := defineLanguage language
    grammars := #[Language.Grammar.declarePerPlatform "ini" libraries "queries"] }

end IniGrammar
