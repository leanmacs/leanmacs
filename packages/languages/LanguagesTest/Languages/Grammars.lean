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
what it registers against a staged directory, its refusal with none, and
its place in the entry module's list. -/
def grammarPackageChecks : List Check :=
  let staged : System.FilePath := "/staged"
  let registered := Languages.Grammars.package.registered (some staged)
  [{  name :=
        "registered against /staged, the languages-grammars package registers exactly the language yaml, of *.yaml and *.yml, naming the grammar yaml, and the grammar yaml per platform at /staged/<platform>/libtree-sitter-yaml.<ext> for darwin-aarch64, darwin-x86_64, linux-aarch64 and linux-x86_64, with its queries at /staged/queries/yaml"
      run :=
        pure
          (registered.languages.map
                (fun language => (language.name, language.patterns, language.syntaxTree.grammar)) ==
              #[("yaml", [.extension "yaml", .extension "yml"], "yaml")] &&
            registered.grammars.map (·.name) == #["yaml"] &&
            registered.grammars.map (·.library) ==
              #[.perPlatform
                  [("darwin-aarch64", staged / "darwin-aarch64" / "libtree-sitter-yaml.dylib"),
                    ("darwin-x86_64", staged / "darwin-x86_64" / "libtree-sitter-yaml.dylib"),
                    ("linux-aarch64", staged / "linux-aarch64" / "libtree-sitter-yaml.so"),
                    ("linux-x86_64", staged / "linux-x86_64" / "libtree-sitter-yaml.so")]] &&
            registered.grammars.map (·.queries) == #[staged / "queries" / "yaml"] &&
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
          (Languages.EditorPackage.packages.map (·.name) == #["languages", "languages-grammars"]) }]

end LanguagesTest
