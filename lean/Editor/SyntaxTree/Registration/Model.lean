import Editor.SyntaxTree.Registration

/-!
# The grammar registry's model

A pure model of the grammars registered at run time
(`Editor/SyntaxTree/Registration.lean`): the rules of the library's core
registry (`crates/editor-syntax/src/registry.rs`) over a table of libraries,
as the library's fake with a table "loads" from one
(`crates/editor-syntax/src/fake/libraries.rs`).

- **`libraries`** is the table: each path with the file at it, no library
  (`Library.notALibrary`) or one that exports symbols (`Library.exports`),
  each a grammar (`Export.grammar`) or one of an ABI the parsing library does
  not speak (`Export.otherAbi`): what the library's real adapter finds on
  disk when it loads native libraries. `none`, the default, is a syntax
  service that loads no grammar at run time: every registration is then
  refused `unsupported`.
- **`registered`** is each name registered, in the order it was first
  registered, with the source it came from (its provenance, where its
  queries are found) and the policy it was registered with.

A registration (`register`) given a table is refused as the table says: a
path not in it `notFound`, a file that is no library `notLoadable`, a symbol
the library does not export `missingSymbol`, and a grammar of another ABI
`unsupportedAbi`. A grammar it exports is registered under the source's
name (`GrammarSource.name`), with the source's policy or `whole`, in place
of any entry of that name before. A refusal leaves the registry unchanged.
The names listed (`grammars`) are the compiled-in names, then each
registered name that is not among them.

The job model answers a job's registration from one
(`JobModel.grammars`, `Editor/Job/Model.lean`), and the syntax tree model
lists, attaches and compiles for the grammars one holds
(`SyntaxTreeModel.registry`, `Editor/SyntaxTree/Model.lean`).

`testGrammars` is the registry the model kits hold by default: the six
grammars `editor-syntax-fixture-grammars` builds for the core's tests,
registered as a test registers them from the library's directory, each with
its policy. The library hides its compiled-in grammars from every test, so
a fake-backed check attaches and compiles for these names as the real
checks do, from a registration. Pinned by
`ModelTest.grammarRegistryChecks`, the answer with no table among them; and,
given the table that describes the fixture grammar library
(`JobContract.GrammarFixture.registry`), held to the real service's answers
on the built library by `JobContract.grammarProperties`.
-/

namespace Editor

/-- What a symbol of a library in the model's table hands out. -/
inductive GrammarRegistry.Export where
  /-- A grammar. -/
  | grammar
  /-- A grammar of an ABI the parsing library does not speak. -/
  | otherAbi
  deriving DecidableEq, Repr

/-- A file at a path of the model's table. -/
inductive GrammarRegistry.Library where
  /-- A file that is not a library this platform can open. -/
  | notALibrary
  /-- A library, and the symbols it exports. -/
  | exports (symbols : Array (String × GrammarRegistry.Export))
  deriving DecidableEq, Repr

/-- The grammars registered at run time, and the table they are registered
from. -/
structure GrammarRegistry where
  /-- The libraries, by path, as the real adapter would find them on disk;
  `none` for a service that loads no grammar at run time. -/
  libraries : Option (Array (String × GrammarRegistry.Library)) := none
  /-- Each name registered, in the order it was first registered, with its
  source and its policy. -/
  registered : Array (String × GrammarSource × ReparsePolicy) := #[]
  deriving DecidableEq, Repr

namespace GrammarRegistry

/-- Whether a grammar is registered under `name`. -/
def isRegistered (registry : GrammarRegistry) (name : String) : Bool :=
  registry.registered.any (·.1 == name)

/-- The source the grammar registered under `name` came from, if one is. -/
def sourceOf? (registry : GrammarRegistry) (name : String) : Option GrammarSource :=
  (registry.registered.find? (·.1 == name)).map (·.2.1)

/-- The policy the grammar registered under `name` was registered with, if
one is. -/
def policyOf? (registry : GrammarRegistry) (name : String) : Option ReparsePolicy :=
  (registry.registered.find? (·.1 == name)).map (·.2.2)

/-- Whether `source` loads from `table`, or why not. -/
def load (table : Array (String × Library)) (source : GrammarSource) :
    Except RegistrationRefusal Unit :=
  match table.find? (·.1 == source.library) with
  | none => .error .notFound
  | some (_, .notALibrary) => .error .notLoadable
  | some (_, .exports symbols) =>
    match symbols.find? (·.1 == source.symbol) with
    | none => .error .missingSymbol
    | some (_, .otherAbi) => .error .unsupportedAbi
    | some (_, .grammar) => .ok ()

/-- Registers the grammar `source` names, and answers the name it is
registered under, or why not; a refusal leaves the registry unchanged. With
no table, every registration is refused `unsupported`. -/
def register (registry : GrammarRegistry) (source : GrammarSource) :
    Except RegistrationRefusal String × GrammarRegistry :=
  match registry.libraries with
  | none => (.error .unsupported, registry)
  | some table =>
    match load table source with
    | .error refusal => (.error refusal, registry)
    | .ok () =>
      let name := source.name
      let entry := (name, source, source.policy.getD .whole)
      let registered :=
        if registry.isRegistered name then
          registry.registered.map fun held => if held.1 == name then entry else held
        else registry.registered.push entry
      (.ok name, { registry with registered })

/-- The grammars `editor-syntax-fixture-grammars` builds for the core's
tests, in the adapter's table's order, each with its policy: every one is
reparsed incrementally but `markdown_inline`. -/
def testGrammarNames : Array (String × ReparsePolicy) :=
  #[("json", .incremental), ("rust", .incremental), ("markdown", .incremental),
    ("markdown_inline", .whole), ("toml", .incremental), ("lean", .incremental)]

/-- The registry with the test grammars registered (`testGrammarNames`),
each from a library of the test grammars' directory, as the real tests
register them, with its policy; and no table, so any other registration is
refused `unsupported`, as the default is. -/
def testGrammars : GrammarRegistry :=
  { registered :=
      testGrammarNames.map fun (name, policy) =>
        (name,
          { library := s!"/test-grammars/libtree-sitter-{name}.so", symbol := s!"tree_sitter_{name}"
            policy := some policy },
          policy) }

/-- The names to list: `compiled` in its order, then each registered name
that is not among them, in the order it was first registered. -/
def grammars (registry : GrammarRegistry) (compiled : Array String) : Array String :=
  registry.registered.foldl (init := compiled) fun names (name, _) =>
    if names.contains name then names else names.push name

end GrammarRegistry

end Editor
