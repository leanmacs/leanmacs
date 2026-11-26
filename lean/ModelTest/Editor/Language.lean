import Editor.Command.Dispatch
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.DisplayRules
import Editor.Language
import Editor.Language.IndentUnit
import Editor.Mode
import Editor.Scene
import Editor.Workspace
import ModelTest.Check

/-!
# Model tests: `Editor/Language.lean`

The model tests of `Editor/Language.lean`: `languageMatchChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A language called `name`, chosen for `patterns`, whose text is parsed
with `grammar`. -/
def testLanguage (name : String) (patterns : List Language.Pattern) (grammar : String := "json") :
    Language :=
  { name, patterns, syntaxTree := { grammar } }

/-- The name of the language `table` chooses for `path` (`Language.forPath`),
if it chooses one. -/
def chosenIn (table : List Language) (path : System.FilePath) : Option String :=
  (Language.forPath table path).map (·.name)

/-- The checks of the matching rule (`Editor/Language.lean`), pure: which
language a table chooses for a path, how a later owner's entries are put
over an earlier owner's, and the shipped table. -/
def languageMatchChecks : List Check :=
  let shipped := Language.shipped.toList
  [{  name :=
        "the shipped table chooses rust for a .rs path, json for a .json path, markdown for a .md path, toml for a .toml path and lean for a .lean path, lakefile.lean included, by extension, and toml for a file named Cargo.lock, by name"
      run :=
        pure
          (chosenIn shipped "/p/src/main.rs" == some "rust" &&
            chosenIn shipped "/p/data.json" == some "json" &&
            chosenIn shipped "/p/notes.md" == some "markdown" &&
            chosenIn shipped "/p/Cargo.toml" == some "toml" &&
            chosenIn shipped "/p/mise.toml" == some "toml" &&
            chosenIn shipped "/p/Cargo.lock" == some "toml" &&
            chosenIn shipped "/p/Editor/Main.lean" == some "lean" &&
            chosenIn shipped "/p/lakefile.lean" == some "lean") },
    { name :=
        "an exact base-name pattern beats an extension pattern, even an earlier entry's, and the extension entry still has the paths the name does not"
      run :=
        let table :=
          [testLanguage "lock" [.extension "lock"], testLanguage "cargo-lock" [.name "Cargo.lock"]]
        pure
          (chosenIn table "/p/Cargo.lock" == some "cargo-lock" &&
            chosenIn table "/p/yarn.lock" == some "lock" &&
            chosenIn table "/p/sub/Cargo.lock.bak" == none) },
    { name :=
        "between entries of equal pattern the earlier one in the table wins, so an entry of a later owner, which Language.over puts first, beats the shipped one"
      run :=
        let rusty := testLanguage "rusty" [.extension "rs"] "rust"
        let twice := [rusty, testLanguage "rustier" [.extension "rs"] "rust"]
        pure
          (chosenIn (Language.over [rusty] shipped) "/p/main.rs" == some "rusty" &&
            chosenIn (Language.over twice shipped) "/p/main.rs" == some "rusty" &&
            chosenIn (Language.over [rusty] shipped) "/p/data.json" == some "json") },
    { name :=
        "Language.over replaces an earlier owner's entry of a name with the later owner's whole entry, the later owner's entries first and in their order"
      run :=
        let mine :=
          [{ Language.rust with patterns := [.extension "rlib"] },
            testLanguage "toml" [.extension "toml"]]
        let table := Language.over mine shipped
        pure
          (table.map (·.name) == ["rust", "toml", "json", "markdown", "lean"] &&
            chosenIn table "/p/main.rs" == none &&
            chosenIn table "/p/x.rlib" == some "rust" &&
            Language.over [] shipped == shipped) },
    { name :=
        "a path that matches no entry has no language: another extension, no extension, a base name that is only the extension with or without its dot, an extension in another case, a lock file not named Cargo.lock, Cargo.lock in another case or with more after it, Lean's toolchain file and build products, and a path with no base name"
      run :=
        pure
          (["/p/notes.txt", "/p/Makefile", "/p/rs", "/p/.rs", "/p/main.RS", "/p/yarn.lock",
                "/p/cargo.lock", "/p/Cargo.lock.bak", "/p/lean-toolchain", "/p/x.olean",
                "/p/x.ilean", "/p/Main.LEAN", "/"].all
            fun path => chosenIn shipped path == none) },
    { name :=
        "the registry's language table is each owner's entries over the earlier owners', the latest owner's first and in its order: config's entry of a shipped language's name replaces it whole, config's entry beats a shipped one of equal pattern, and the loop is told the table"
      run :=
        let compiled := ({} : Config.Registry).replaceLanguages .compiled Language.shipped
        let rusty := testLanguage "rusty" [.extension "rs"] "rust"
        let mine :=
          { Language.rust with syntaxTree := { grammar := "rust", highlights := some "q" } }
        let registry := compiled.replaceLanguages .config #[rusty, mine]
        let names (table : List Language) : List String := table.map (·.name)
        pure
          (names compiled.languageTable == ["rust", "json", "markdown", "toml", "lean"] &&
            names registry.languageTable == ["rusty", "rust", "json", "markdown", "toml", "lean"] &&
            registry.languageTable[1]? == some mine &&
            chosenIn registry.languageTable "/p/main.rs" == some "rusty" &&
            chosenIn (compiled.replaceLanguages .config #[mine]).languageTable "/p/main.rs" ==
              some "rust" &&
            registry.registered.languages == registry.languageTable &&
            (registry.replaceLanguages .config #[]).languageTable == compiled.languageTable) },
    { name :=
        "the shipped table is rust, json, markdown, toml and lean, each parsed with the grammar of its name and the grammar's own queries, toml's booleans drawn in the constant face, lean's booleans in the constant face, its characters in the string face, its namespaces in the module face and its plain identifiers (`variable`) in no face, and no other capture of any mapped; rust indented by four spaces and json, markdown, toml and lean by two; toml for *.toml and Cargo.lock, lean for *.lean"
      run :=
        pure
          (Language.shipped.map (·.name) == #["rust", "json", "markdown", "toml", "lean"] &&
            Language.shipped.all
              (fun language =>
                language.syntaxTree ==
                  { grammar := language.name, captures := language.syntaxTree.captures }) &&
            [Language.rust, Language.json, Language.markdown].all (·.syntaxTree.captures.isEmpty) &&
            Language.toml.syntaxTree.captures == [("boolean", some ⟨"syntax.constant"⟩)] &&
            Language.toml.patterns == [.extension "toml", .name "Cargo.lock"] &&
            Language.lean.syntaxTree.captures ==
              [("boolean", some ⟨"syntax.constant"⟩), ("character", some ⟨"syntax.string"⟩),
                ("namespace", some ⟨"syntax.module"⟩), ("variable", none)] &&
            Language.lean.patterns == [.extension "lean"] &&
            Language.rust.indentUnit == .spaces 4 &&
            Language.json.indentUnit == .spaces 2 &&
            Language.markdown.indentUnit == .spaces 2 &&
            Language.toml.indentUnit == .spaces 2 &&
            Language.lean.indentUnit == .spaces 2) },
    { name := "an entry that says no indent unit is indented by the default unit, four spaces"
      run :=
        pure
          (Language.IndentUnit.default == .spaces 4 &&
            (testLanguage "plain" [.extension "txt"]).indentUnit == Language.IndentUnit.default) }]

end ModelTest
