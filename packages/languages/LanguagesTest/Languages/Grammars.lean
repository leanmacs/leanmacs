import Editor.Config.Packages
import Editor.Highlight
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
        "registered against /staged, the languages-grammars package registers exactly the languages yaml (*.yaml, *.yml), java (*.java), swift (*.swift), ruby (*.rb, *.rake, *.gemspec, Gemfile, Rakefile), python (*.py, *.pyi), javascript (*.js, *.mjs, *.cjs, *.jsx), typescript (*.ts, *.mts, *.cts), tsx (*.tsx), c (*.c, *.h), cpp (*.cc, *.cpp, *.cxx, *.hpp, *.hxx, *.hh) and clojure (*.clj, *.cljs, *.cljc, *.edn), in that order, each naming the grammar of its name but clojure, which names clojure_orchard, with an indent of two spaces for ruby, javascript, typescript, tsx and clojure and the default four for the rest, and exactly the grammars rust, json, markdown, markdown_inline, toml, lean, yaml, java, swift, ruby, python, javascript, typescript, tsx, c, cpp and clojure_orchard, in that order, each per platform at /staged/<platform>/libtree-sitter-<name>.<ext> for darwin-aarch64, darwin-x86_64, linux-aarch64 and linux-x86_64, with symbol tree_sitter_<name> and its queries at /staged/queries/<name>, markdown_inline reparsed whole, yaml and the popular ten with no policy and the rest incrementally"
      run :=
        let names :=
          #["rust", "json", "markdown", "markdown_inline", "toml", "lean", "yaml", "java", "swift",
            "ruby", "python", "javascript", "typescript", "tsx", "c", "cpp", "clojure_orchard"]
        let two : Language.IndentUnit := .spaces 2
        let four := Language.IndentUnit.default
        let languages : Array (String × List Language.Pattern × String × Language.IndentUnit) :=
          #[("yaml", [.extension "yaml", .extension "yml"], "yaml", four),
            ("java", [.extension "java"], "java", four),
            ("swift", [.extension "swift"], "swift", four),
            ("ruby",
              [.extension "rb", .extension "rake", .extension "gemspec", .name "Gemfile",
                .name "Rakefile"],
              "ruby", two),
            ("python", [.extension "py", .extension "pyi"], "python", four),
            ("javascript", [.extension "js", .extension "mjs", .extension "cjs", .extension "jsx"],
              "javascript", two),
            ("typescript", [.extension "ts", .extension "mts", .extension "cts"], "typescript",
              two),
            ("tsx", [.extension "tsx"], "tsx", two),
            ("c", [.extension "c", .extension "h"], "c", four),
            ("cpp",
              [.extension "cc", .extension "cpp", .extension "cxx", .extension "hpp",
                .extension "hxx", .extension "hh"],
              "cpp", four),
            ("clojure", [.extension "clj", .extension "cljs", .extension "cljc", .extension "edn"],
              "clojure_orchard", two)]
        pure
          (registered.languages.map
                (fun language =>
                  (language.name, language.patterns, language.syntaxTree.grammar,
                    language.indentUnit)) ==
              languages &&
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
                  some .incremental, some .incremental, none] ++
                Array.replicate 10 none &&
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
              some { Language.rust.syntaxTree with highlights := queries.highlights }) },
    { name :=
        "with the entry module's packages registered against /staged, a path's language is java for Main.java, swift for App.swift, ruby for app.rb and Gemfile, python for hello.py, javascript for a.mjs, typescript for a.ts, tsx for a.tsx, c for a.h, cpp for a.hpp and clojure for core.clj, whose tree names clojure_orchard; and by the core's capture rule over each entry's mapping, variable and variable.parameter draw nothing in java, swift, ruby, python, javascript, typescript, tsx, c and cpp, function.method draws syntax.function, swift's boolean draws syntax.constant, and c's and cpp's delimiter draw syntax.punctuation"
      run :=
        let (state, refused) : Config.State Unit Unit × Array String :=
          Config.State.ofPackages (Package.shipping "languages" Languages.EditorPackage.packages)
            [("languages", staged)]
        let table := state.registry.languageTable
        let chosen (path : System.FilePath) : Option String :=
          (Language.forPath table path).map (·.name)
        let captures (name : String) : List (String × Option FaceName) :=
          ((table.find? (·.name == name)).map (·.syntaxTree.captures)).getD []
        let faceIn (name capture : String) : Option FaceName :=
          Highlight.faceOf (captures name) capture
        let mapping :=
          ["java", "swift", "ruby", "python", "javascript", "typescript", "tsx", "c", "cpp"]
        pure
          (refused.isEmpty &&
            [("Main.java", "java"), ("App.swift", "swift"), ("app.rb", "ruby"), ("Gemfile", "ruby"),
                  ("hello.py", "python"), ("a.mjs", "javascript"), ("a.ts", "typescript"),
                  ("a.tsx", "tsx"), ("a.h", "c"), ("a.hpp", "cpp"), ("core.clj", "clojure")].all
              (fun (path, name) => chosen path == some name) &&
            ((Language.forPath table "core.clj").map (·.syntaxTree.grammar)) ==
              some "clojure_orchard" &&
            mapping.all
              (fun name =>
                faceIn name "variable" == none && faceIn name "variable.parameter" == none &&
                  faceIn name "function.method" == some ⟨"syntax.function"⟩) &&
            faceIn "swift" "boolean" == some ⟨"syntax.constant"⟩ &&
            faceIn "c" "delimiter" == some ⟨"syntax.punctuation"⟩ &&
            faceIn "cpp" "delimiter" == some ⟨"syntax.punctuation"⟩) }]

end LanguagesTest
