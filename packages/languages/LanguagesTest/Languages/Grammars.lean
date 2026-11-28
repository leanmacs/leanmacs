import Editor.Config.Packages
import Editor.Language.Grammar
import Editor.Package
import Languages.EditorPackage
import Languages.Grammars
import LanguagesTest.Check

/-!
# Model tests: `Languages/Grammars.lean`

The model tests of `Languages/Grammars.lean`: `grammarPackageChecks`, on
what the package registers handed a staged grammars directory, and handed
none, and on the entry module's list of packages. The test driver's root,
`LanguagesTest/Model.lean`, runs them.
-/

namespace LanguagesTest

open Editor

/-- The checks of the `languages-grammars` package (`Languages/Grammars.lean`):
what it registers against a staged directory, its refusal with none, its
place in the entry module's list, and that a shipped language's tree waits
for its grammar's answer. -/
def grammarPackageChecks : List Check :=
  let staged : System.FilePath := "/staged"
  let registered := Languages.Grammars.package.registered (some staged)
  [{  name :=
        "registered against /staged, the languages-grammars package registers exactly the language yaml, of *.yaml and *.yml, naming the grammar yaml, and exactly the grammars rust, json, markdown, markdown_inline, toml, lean and yaml, in that order, each per platform at /staged/<platform>/libtree-sitter-<name>.<ext> for darwin-aarch64, darwin-x86_64, linux-aarch64 and linux-x86_64, with its queries at /staged/queries/<name>, markdown_inline reparsed whole, yaml with no policy and the rest incrementally"
      run :=
        let names := #["rust", "json", "markdown", "markdown_inline", "toml", "lean", "yaml"]
        pure
          (registered.languages.map
                (fun language => (language.name, language.patterns, language.syntaxTree.grammar)) ==
              #[("yaml", [.extension "yaml", .extension "yml"], "yaml")] &&
            registered.grammars.map (·.name) == names &&
            registered.grammars.map (·.library) ==
              names.map
                (fun name =>
                  .perPlatform
                    [("darwin-aarch64",
                        staged / "darwin-aarch64" / s!"libtree-sitter-{name}.dylib"),
                      ("darwin-x86_64", staged / "darwin-x86_64" / s!"libtree-sitter-{name}.dylib"),
                      ("linux-aarch64", staged / "linux-aarch64" / s!"libtree-sitter-{name}.so"),
                      ("linux-x86_64", staged / "linux-x86_64" / s!"libtree-sitter-{name}.so")]) &&
            registered.grammars.map (·.symbol) == names.map (s!"tree_sitter_{·}") &&
            registered.grammars.map (·.queries) ==
              names.map (fun (name : String) => staged / "queries" / name) &&
            registered.grammars.map (·.policy) ==
              #[some .incremental, some .incremental, some .incremental, some .whole,
                some .incremental, some .incremental, none] &&
            registered.modes.isEmpty &&
            registered.commands.isEmpty) },
    { name :=
        "with no staged grammars directory, the languages-grammars package is refused for having none, and registers nothing"
      run :=
        let refusal :=
          match Languages.Grammars.package.collected none with
          | .error message => some message
          | .ok _ => none
        pure
          (refusal == some (Package.refused "languages-grammars" Package.noGrammarsDirectory) &&
            (Languages.Grammars.package.registered none).languages.isEmpty &&
            (Languages.Grammars.package.registered none).grammars.isEmpty) },
    { name := "the entry module's packages are named languages, then languages-grammars"
      run :=
        pure
          (Languages.EditorPackage.packages.map (·.name) == #["languages", "languages-grammars"]) },
    { name :=
        "with the entry module's packages registered against /staged, the shipped language rust's tree is none, drawn plain, while no answer of its grammar is recorded, and carries the queries of a recorded registered answer"
      run :=
        let (state, refused) : Config.State Unit Unit × Array String :=
          Config.State.ofPackages (Package.shipping "languages" Languages.EditorPackage.packages)
            [("languages", staged)]
        let declared := state.registry.grammarTable
        let queries : Language.Grammar.Queries := { highlights := some "(identifier) @variable" }
        let answers : Language.Grammar.Answers :=
          { generation := 1, answers := #[("rust", .registered queries)] }
        pure
          (refused.isEmpty &&
            Language.Grammar.treeOf declared {} 1 Language.rust.syntaxTree == none &&
            Language.Grammar.treeOf declared answers 1 Language.rust.syntaxTree ==
              some { Language.rust.syntaxTree with highlights := queries.highlights }) }]

end LanguagesTest
