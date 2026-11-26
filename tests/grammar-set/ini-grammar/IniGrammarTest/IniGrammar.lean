import Editor.Config.Packages
import IniGrammar.EditorPackage

/-!
# Model tests: `IniGrammar.lean`

The tests of the test package that need no Rust library, on what it
declares and on the state a host handed its packages and a staged grammars
directory starts from (`Config.State.ofPackages`, the test double). The
test driver's root, `IniGrammarTest/Model.lean`, runs them.
-/

namespace IniGrammarTest

open Editor

/-- The checks of the package `ini-grammar`, each with what must hold as a
sentence. -/
def packageChecks : List (String × Bool) :=
  let staged : System.FilePath := "/s/.lake/build/grammars/ini-grammar"
  let (state, refused) : Config.State Unit Unit × Array String :=
    Config.State.ofPackages (Package.shipping "ini-grammar" IniGrammar.EditorPackage.packages)
      [("ini-grammar", staged)]
  let ini := state.registry.grammarTable.head?
  [("the package registers the language ini of *.ini naming the grammar ini, and declares ini per platform for darwin-aarch64, darwin-x86_64, linux-aarch64 and linux-x86_64 with the query directory queries",
      (IniGrammar.package.registered (some staged)).languages.map
            (fun language => (language.name, language.patterns, language.syntaxTree.grammar)) ==
          #[("ini", [.extension "ini"], "ini")] &&
        IniGrammar.package.grammars.map (·.name) == #["ini"] &&
        IniGrammar.package.grammars.map (·.library) ==
          #[.perPlatform
              [("darwin-aarch64", "darwin-aarch64/libtree-sitter-ini.dylib"),
                ("darwin-x86_64", "darwin-x86_64/libtree-sitter-ini.dylib"),
                ("linux-aarch64", "linux-aarch64/libtree-sitter-ini.so"),
                ("linux-x86_64", "linux-x86_64/libtree-sitter-ini.so")]] &&
        IniGrammar.package.grammars.map (·.queries) == #[("queries" : System.FilePath)]),
    ("handed a staged directory, it is not refused and its ini resolves under it",
      refused == #[] && state.packages == #["ini-grammar"] &&
        ini.map (·.queries) == some (staged / "queries") &&
        (ini.bind (·.libraryOn "linux-x86_64")) ==
          some (staged / "linux-x86_64" / "libtree-sitter-ini.so"))]

end IniGrammarTest
