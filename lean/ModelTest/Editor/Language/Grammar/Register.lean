import Editor.Api
import Editor.Command.Model
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.File.Model
import Editor.InputScheme.Test
import Editor.Job.Model
import Editor.Language
import Editor.Language.Grammar
import Editor.Language.Grammar.Answer
import Editor.Language.Grammar.Register
import Editor.Loop
import Editor.Loop.Driver
import Editor.Setup
import Editor.SyntaxTree
import Editor.SyntaxTree.Model
import Editor.SyntaxTree.Registration
import Editor.SyntaxTree.Registration.Model
import Editor.Test.Driver
import Editor.Test.Models
import Editor.Test.Modes
import ModelTest.Check
import ModelTest.Support.Elaborator

/-!
# Model tests: `Editor/Language/Grammar/Register.lean`

The model tests of `Editor/Language/Grammar/Register.lean`:
`grammarRegisterChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The highlights query the checks' declared grammars read from their
query directory. -/
def declaredHighlights : String :=
  "(number) @number"

/-- The loop's driver once a config whose `setup` is `setup` has been
installed over a registry holding the shipped languages and modes, and
the work of the registration its install asked for has been started
(`Loop.Driver.startWork`): the driver runs on the editor's models with
`json` and `lean` compiled into the syntax tree model, its keys told the
installed registry, and its jobs given `libraries` as the table grammars
load from and the files `files`, each a path and its text, and the
directories `directories`. `none` when the install asked for no
registration. -/
def installedWith (setup : SetupM Unit) (libraries : Array (String × GrammarRegistry.Library))
    (files : Array (String × String)) (directories : Array String := #[]) : Option TestDriver := do
  let start : ModelState :=
    {
      registry :=
        (({} : Config.Registry).replaceLanguages .compiled Language.shipped).replaceModes .compiled
          Language.modes }
  let (state, _) := Config.step start .requested
  let (state, effects) := Config.step state (.finished (accepted ["a"] setup))
  let (generation, grammars) ←
    effects.findSome? fun
        | .registerGrammars generation grammars => some (generation, grammars)
        | _ => none
  let keys : Loop.Keys TestScheme.scheme := { registered := state.registry.registered }
  let model := { editorModel with syntaxTree := { compiled := #["json", "lean"] } }
  let fileModel :=
    files.foldl (fun model (path, text) => model.withFile path text.toUTF8)
      (directories.foldl (fun model (path : String) => model.withDirectory path) ({} : FileModel))
  let driver ←
    (Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) model).toOption
  let driver :=
    { driver with jobs := { grammars := { libraries := some libraries }, files := fileModel } }
  return driver.startWork Language.Grammar.jobName (Language.Grammar.work generation grammars)

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

/-- The grammars the driver's syntax tree model has attached texts with, in
order. -/
def attachedGrammars (driver : TestDriver) : Array String :=
  driver.model.syntaxTree.attached.map (·.2)

/-- The faces of each highlighter of the driver's syntax tree model, by
name, in order. -/
def highlighters (driver : TestDriver) : Array (Array String) :=
  driver.model.syntaxTree.highlighted.map fun (_, _, faces) => faceNames faces

/-- The faces the model's shipped highlights query is drawn in under the
`lean` language's capture mapping. -/
def shippedLeanFaces : Array String :=
  #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"]

/-- The `setup` that declares the grammar `ini` from `/g/libtree-sitter-ini.so`
and the language `ini` of `*.ini` that names it. -/
def declaresIni : SetupM Unit := do
  defineGrammar "ini" "/g/libtree-sitter-ini.so"
  defineLanguage
      { name := "ini", patterns := [.extension "ini"], syntaxTree := { grammar := "ini" } }

/-- The checks of the core's `register-grammars` job and its command
(`Editor/Language/Grammar/Register.lean`), driven from the reducer's effect
through the loop's driver on the job model and the editor's models. -/
def grammarRegisterChecks : List Check :=
  [{  name :=
        "after a config that declares the grammar ini and a language of *.ini installs, its job registers ini and reads its highlights from queries/ beside the library: a .ini buffer opened before the job's command is plain until it and is then attached with ini and highlighted with that query, as is a .ini buffer opened after it"
      run :=
        pure <|
          let libraries :=
            #[("/g/libtree-sitter-ini.so", .exports #[("tree_sitter_ini", .grammar)])]
          match
            installedWith declaresIni libraries
              #[("/g/queries/highlights.scm", declaredHighlights)] with
          | none => false
          | some driver =>
            let before := openedIn driver "/w/a.ini"
            let (answered, delivered) := before.finish 1
            let after := openedIn answered "/w/b.ini"
            attachedGrammars before == #[] && highlighters before == #[] && delivered.isSome &&
              answered.loop.state.grammars.answerOf? 1 "ini" ==
                some (.registered { highlights := some declaredHighlights, injections := none }) &&
              attachedGrammars answered == #["ini"] &&
              highlighters answered == #[#["syntax.number"]] &&
              attachedGrammars after == #["ini", "ini"] &&
              highlighters after == #[#["syntax.number"], #["syntax.number"]] &&
              answered.loop.state.echo == "" },
    { name :=
        "a refused registration of the new grammar ini, its library not in the table, says in the echo area its name and the refusal, and a .ini buffer opened before or after the job's command stays open with no syntax tree"
      run :=
        pure <|
          match
            installedWith declaresIni #[] #[("/g/queries/highlights.scm", declaredHighlights)] with
          | none => false
          | some driver =>
            let before := openedIn driver "/w/a.ini"
            let (answered, _) := before.finish 1
            let after := openedIn answered "/w/b.ini"
            let buffers (driver : TestDriver) : Array String :=
              driver.loop.state.buffers.filterMap (·.map (·.name))
            answered.loop.state.echo ==
                Language.Grammar.said "ini" (.refused .notFound) (kept := false)
                  (registeredBefore := false) &&
              answered.loop.state.echo ==
                "grammar `ini`: the grammar was refused: no file is at the grammar's path, so its languages have no syntax tree" &&
              attachedGrammars answered == #[] &&
              highlighters answered == #[] &&
              attachedGrammars after == #[] &&
              highlighters after == #[] &&
              buffers after == #["scratch", "/w/a.ini", "/w/b.ini"] },
    { name :=
        "a refused registration of a declaration named lean says the compiled-in grammar stays, and a .lean buffer opened before or after the job's command keeps the compiled-in lean grammar and its shipped highlights"
      run :=
        pure <|
          match installedWith (defineGrammar "lean" "/g/libtree-sitter-lean.so") #[] #[] with
          | none => false
          | some driver =>
            let before := openedIn driver "/w/A.lean"
            let (answered, _) := before.finish 1
            let after := openedIn answered "/w/B.lean"
            answered.loop.state.echo ==
                "grammar `lean`: the grammar was refused: no file is at the grammar's path, so the compiled-in grammar stays" &&
              attachedGrammars answered == #["lean"] &&
              highlighters answered == #[shippedLeanFaces] &&
              attachedGrammars after == #["lean", "lean"] &&
              highlighters after == #[shippedLeanFaces, shippedLeanFaces] },
    { name :=
        "a declared grammar named lean that registers replaces the compiled-in lean: a .lean buffer opened after the reload is attached with the registered lean and highlighted with the declared query, the shipped one no longer offered"
      run :=
        pure <|
          let library := "/g/libtree-sitter-lean.so"
          match
            installedWith (defineGrammar "lean" library)
              #[(library, .exports #[("tree_sitter_lean", .grammar)])]
              #[("/g/queries/highlights.scm", declaredHighlights)] with
          | none => false
          | some driver =>
            let (answered, _) := driver.finish 1
            let after := openedIn answered "/w/A.lean"
            let shipped :=
              (SyntaxTreeM.runModel (SyntaxTree.shippedQuery "lean" .highlights)
                  after.model.syntaxTree).1
            attachedGrammars after == #["lean"] && highlighters after == #[#["syntax.number"]] &&
              shipped matches .error .noShippedQuery &&
              (after.model.syntaxTree.registry.sourceOf? "lean").map (·.library) == some library },
    { name :=
        "a query file that cannot be read ships no query of its kind and is said in the echo area with the grammar and the file; the grammar is still registered"
      run :=
        pure <|
          let libraries :=
            #[("/g/libtree-sitter-ini.so", .exports #[("tree_sitter_ini", .grammar)])]
          match
            installedWith declaresIni libraries #[("/g/queries/highlights.scm", declaredHighlights)]
              #["/g/queries/indents.scm"] with
          | none => false
          | some driver =>
            let (answered, _) := driver.finish 1
            answered.loop.state.echo ==
                s!"grammar `ini`: /g/queries/indents.scm: {FileError.notAFile.describe}" &&
              answered.loop.state.grammars.answerOf? 1 "ini" ==
                some (.registered { highlights := some declaredHighlights, indents := none }) &&
              answered.loop.state.grammars.registered == #["ini"] }]

end ModelTest
