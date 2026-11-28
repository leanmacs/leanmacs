import Editor.Api
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.File.Model
import Editor.InputScheme.Test
import Editor.Job.Model
import Editor.Language
import Editor.Language.Grammar
import Editor.Language.Grammar.Register
import Editor.Loop
import Editor.Loop.Driver
import Editor.Package
import Editor.Setup
import Editor.SyntaxTree.Model
import Editor.SyntaxTree.Registration.Model
import Editor.Test.Driver
import Editor.Test.Models
import ModelTest.Support.Elaborator

/-!
# Model tests: support: Grammars

Declared grammars as the model tests drive them: a config installed over
the shipped languages and modes, with the work of the `register-grammars`
registration its install asked for started on the loop's driver
(`installedWith`, `installOver`); a package that ships a grammar
(`iniPackage`); the setups that declare one (`declaresIni`); the queries
they read; and a buffer opened through a delivered command (`openedIn`).
Its two users are the model tests of the job and its command
(`ModelTest/Editor/Language/Grammar/Register.lean`,
`grammarRegisterChecks`) and those of an injected language's highlights
(`ModelTest/Editor/Highlight.lean`, `highlightInjectedChecks`).
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The highlights query the checks' declared grammars read from their
query directory. -/
def declaredHighlights : String :=
  "(number) @number"

/-- The platform the checks' jobs register on, given explicitly so that no
check depends on the platform the tests run on. -/
def checkedPlatform : String :=
  "darwin-aarch64"

/-- The reload reducer's state with a registry holding the shipped languages
and modes, and nothing installed. -/
def shippedState : ModelState :=
  {
    registry :=
      (({} : Config.Registry).replaceLanguages .compiled Language.shipped).replaceModes .compiled
        Language.modes }

/-- `state` with each of `packages` registered, in order, before any config
(`Config.State.register`), its grammars resolved against the directory
`grammarDirectories` names for its Lake package; a refused package is
skipped. -/
def withPackages (state : ModelState) (packages : Array Package)
    (grammarDirectories : List (String × System.FilePath)) : ModelState :=
  packages.foldl
    (fun state package => (state.register package grammarDirectories).toOption.getD state) state

/-- The package `ini-grammar`, of the Lake package of that name, that
declares the grammar `ini` for macOS on Apple silicon alone, relative to its
grammars directory, and the language `ini` of `*.ini` naming it. -/
def iniPackage : Package :=
  { name := "ini-grammar"
    setup :=
      defineLanguage
        { name := "ini", patterns := [.extension "ini"], syntaxTree := { grammar := "ini" } }
    grammars :=
      #[Language.Grammar.declarePerPlatform "ini"
          [("darwin-aarch64", "darwin-aarch64/libtree-sitter-ini.so")] "queries"]
    lakePackage := some "ini-grammar" }

/-- Where the checks stage `ini-grammar`'s grammars directory. -/
def iniStagedAt : List (String × System.FilePath) :=
  [("ini-grammar", "/s/grammars/ini-grammar")]

/-- The highlights query `ini-grammar` ships, other than config's. -/
def packageHighlights : String :=
  "(string) @string"

/-- The reducer's state once a reload from `state` has installed a config
whose `setup` is `setup`, with the generation and the grammars of the
registration the install asked for; `none` when it asked for none. -/
def installOver (state : ModelState) (setup : SetupM Unit) :
    Option (ModelState × Nat × Array Language.Grammar) := do
  let (state, _) := Config.step state .requested
  let (state, effects) := Config.step state (.finished (accepted ["a"] setup))
  let (generation, grammars) ←
    effects.findSome? fun
        | .registerGrammars generation grammars => some (generation, grammars)
        | _ => none
  return (state, generation, grammars)

/-- The loop's driver once a config whose `setup` is `setup` has been
installed over a registry holding the shipped languages and modes, and
the work of the registration its install asked for has been started
(`Loop.Driver.startWork`): the driver runs on the editor's models with
the test grammars registered (`GrammarRegistry.testGrammars`), its keys
told the installed registry, and its jobs given `libraries` as the table
grammars load from, over the same test grammars, and the files `files`,
each a path and its text, and the directories `directories`. `none` when
the install asked for no registration.

`compiled` names grammars compiled into the syntax tree model instead of
registered, none by default: only the check of a refused registration over
a compiled-in name (`Language.Grammar.compiledStays`) passes it. Phase 4 of
the roadmap `shipped-grammars-package` removes it with that rule. -/
def installedWith (setup : SetupM Unit) (libraries : Array (String × GrammarRegistry.Library))
    (files : Array (String × String)) (directories : Array String := #[])
    (platform : String := checkedPlatform) (packages : Array Package := #[])
    (grammarDirectories : List (String × System.FilePath) := []) (compiled : Array String := #[]) :
    Option TestDriver := do
  let (state, generation, grammars) ←
    installOver (withPackages shippedState packages grammarDirectories) setup
  let keys : Loop.Keys TestScheme.scheme := { registered := state.registry.registered }
  let registered : GrammarRegistry :=
    { registered := GrammarRegistry.testGrammars.registered.filter (!compiled.contains ·.1) }
  let model := { editorModel with syntaxTree := { compiled, registry := registered } }
  let fileModel :=
    files.foldl (fun model (path, text) => model.withFile path text.toUTF8)
      (directories.foldl (fun model (path : String) => model.withDirectory path) ({} : FileModel))
  let driver ←
    (Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) model).toOption
  let driver :=
    { driver with
      jobs := { grammars := { registered with libraries := some libraries }, files := fileModel } }
  return driver.startWork Language.Grammar.jobName
      (Language.Grammar.work platform generation grammars)

/-- The driver once a delivered command has opened a buffer called `path`
over a JSON text, recorded the language the registry's table chooses for
the path, and set the `code` mode on it. -/
def openedIn (driver : TestDriver) (path : String) : TestDriver :=
  let opens : EditorM Unit := do
    let text ← createText "[1]"
    let .ok buffer ← addBuffer path text | return
    discard <| buffer.setLanguage (← languageOf path)
    discard <| buffer.setMajorMode Language.codeName
  (driver.stepped (driver.loop.deliver driver.handed s!"open {path}" opens)).1

/-- The `setup` that declares the grammar `ini` from `library` and the
language `ini` of `*.ini` that names it. -/
def declaresIniFrom (library : System.FilePath) : SetupM Unit := do
  defineGrammar "ini" library
  defineLanguage
      { name := "ini", patterns := [.extension "ini"], syntaxTree := { grammar := "ini" } }

/-- The `setup` that declares the grammar `ini` from `/g/libtree-sitter-ini.so`
and the language `ini` of `*.ini` that names it. -/
def declaresIni : SetupM Unit :=
  declaresIniFrom "/g/libtree-sitter-ini.so"

end ModelTest
