import Editor.SyntaxTree.Registration
import Editor.SyntaxTree.Registration.Model
import ModelTest.Check

/-!
# Model tests: `Editor/SyntaxTree/Registration/Model.lean`

The model tests of `Editor/SyntaxTree/Registration/Model.lean`:
`grammarRegistryChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The library of the checks' table that holds grammars. -/
def registryLibrary : String :=
  "/fake/grammars.so"

/-- The file of the checks' table that is no library. -/
def registryNotALibrary : String :=
  "/fake/not-a-library.txt"

/-- A registry over the checks' table: `registryLibrary` exports
`tree_sitter_python`, `tree_sitter_json` (which overrides the compiled-in
`json`) and `tree_sitter_future` (a grammar of another ABI);
`registryNotALibrary` is no library. -/
def registryTable : GrammarRegistry :=
  {
    libraries :=
      some
        #[(registryLibrary,
            .exports
              #[("tree_sitter_python", .grammar), ("tree_sitter_json", .grammar),
                ("tree_sitter_future", .otherAbi)]),
          (registryNotALibrary, .notALibrary)] }

/-- A source of `symbol` in `library`, declaring `policy`. -/
def registrySource (library symbol : String) (policy : Option ReparsePolicy := none) :
    GrammarSource :=
  { library, symbol, policy }

/-- The refusal `answer` is, if it is one. -/
def registrationRefusalOf : Except RegistrationRefusal String → Option RegistrationRefusal
  | .error refusal => some refusal
  | .ok _ => none

/-- The compiled-in names the checks list beside the registry's. -/
def registryCompiled : Array String :=
  #["json"]

/-- The checks of the grammar registry's model
(`Editor/SyntaxTree/Registration/Model.lean`): a registration, the override
of a compiled-in name, the default policy, each refusal given a table, and
the unsupported refusal given none. -/
def grammarRegistryChecks : List Check :=
  [{  name :=
        "given a table, a registration of a grammar not compiled in answers its name, which is listed after the compiled-in names, and records its source"
      run :=
        pure <|
          let python := registrySource registryLibrary "tree_sitter_python"
          let (answer, after) := registryTable.register python
          answer.toOption == some "python" &&
            after.grammars registryCompiled == #["json", "python"] &&
            after.sourceOf? "python" == some python },
    { name :=
        "given a table, registering json from a library replaces the compiled-in json: it is listed once, and recorded with its source"
      run :=
        pure <|
          let json := registrySource registryLibrary "tree_sitter_json"
          let (answer, after) := registryTable.register json
          answer.toOption == some "json" && after.grammars registryCompiled == #["json"] &&
            after.isRegistered "json" &&
            after.sourceOf? "json" == some json &&
            !registryTable.isRegistered "json" },
    { name :=
        "a registered grammar whose source declares no policy is recorded whole, and one that declares incremental keeps it"
      run :=
        pure <|
          let (_, undeclared) :=
            registryTable.register (registrySource registryLibrary "tree_sitter_python")
          let (_, declared) :=
            registryTable.register
              (registrySource registryLibrary "tree_sitter_python" (some .incremental))
          undeclared.policyOf? "python" == some .whole &&
            declared.policyOf? "python" == some .incremental },
    { name :=
        "given a table, a path not in it is refused not found, a file that is no library not loadable, a symbol the library lacks missing symbol, and a grammar of another ABI unsupported ABI, each leaving the registry unchanged"
      run :=
        pure <|
          let (_, held) :=
            registryTable.register (registrySource registryLibrary "tree_sitter_python")
          let refusedWith (source : GrammarSource) (refusal : RegistrationRefusal) : Bool :=
            let (answer, after) := held.register source
            registrationRefusalOf answer == some refusal && after == held
          refusedWith (registrySource "/fake/missing.so" "tree_sitter_python") .notFound &&
            refusedWith (registrySource registryNotALibrary "tree_sitter_python") .notLoadable &&
            refusedWith (registrySource registryLibrary "tree_sitter_absent") .missingSymbol &&
            refusedWith (registrySource registryLibrary "tree_sitter_future") .unsupportedAbi },
    { name :=
        "with no table, every registration is refused as unsupported and leaves the registry unchanged"
      run :=
        pure <|
          let none : GrammarRegistry := {}
          [registrySource registryLibrary "tree_sitter_python",
                registrySource registryLibrary "tree_sitter_json" (some .incremental),
                registrySource "/fake/missing.so" "tree_sitter_python"].all
            fun source =>
            let (answer, after) := none.register source
            registrationRefusalOf answer == some .unsupported && after == none &&
              after.grammars registryCompiled == registryCompiled },
    { name := "a source is named by its symbol without its tree_sitter_ prefix"
      run :=
        pure <|
          (registrySource registryLibrary "tree_sitter_python").name == "python" &&
            (registrySource registryLibrary "python").name == "python" &&
            (registrySource registryLibrary "tree_sitter_").name == "tree_sitter_" }]

end ModelTest
