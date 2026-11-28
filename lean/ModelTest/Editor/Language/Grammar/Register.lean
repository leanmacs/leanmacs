import Editor.Api
import Editor.Command.Model
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.InputScheme.Test
import Editor.Job.Model
import Editor.Language
import Editor.Language.Grammar
import Editor.Language.Grammar.Answer
import Editor.Language.Grammar.Register
import Editor.Loop
import Editor.Loop.Driver
import Editor.Package
import Editor.Setup
import Editor.SyntaxTree
import Editor.SyntaxTree.Model
import Editor.SyntaxTree.Registration
import Editor.SyntaxTree.Registration.Model
import Editor.Test.Driver
import Editor.Test.Modes
import ModelTest.Check
import ModelTest.Support.Elaborator
import ModelTest.Support.Grammars

/-!
# Model tests: `Editor/Language/Grammar/Register.lean`

The model tests of `Editor/Language/Grammar/Register.lean`:
`grammarRegisterChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The grammars the driver's syntax tree model has attached texts with, in
order. -/
def attachedGrammars (driver : TestDriver) : Array String :=
  driver.model.syntaxTree.attached.map (·.2)

/-- The faces of each highlighter of the driver's syntax tree model, by
name, in order. -/
def highlighters (driver : TestDriver) : Array (Array String) :=
  driver.model.syntaxTree.highlighted.map fun (_, _, faces) => faceNames faces

/-- The faces of each language injected into the driver's syntax tree
model's texts, by grammar name, in order. -/
def injectedLanguages (driver : TestDriver) : Array (String × Array String) :=
  driver.model.syntaxTree.languages.map fun (_, name, _, faces, _) => (name, faceNames faces)

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
        "a config that declares the grammars markdown and lean, the shipped languages' grammars, as languages-grammars does: a .md buffer with a lean fence opened before the job's command is attached with nothing and highlighted with nothing, and after it is attached with markdown, highlighted with its declared query, and its injected lean drawn in the faces of lean's declared query"
      run :=
        pure <|
          let markdown := "/g/markdown/libtree-sitter-markdown.so"
          let lean := "/g/lean/libtree-sitter-lean.so"
          let setup : SetupM Unit := do
            defineGrammar "markdown" markdown
            defineGrammar "lean" lean
          match
            installedWith setup
              #[(markdown, .exports #[("tree_sitter_markdown", .grammar)]),
                (lean, .exports #[("tree_sitter_lean", .grammar)])]
              #[("/g/markdown/queries/highlights.scm", "(string) @string"),
                ("/g/markdown/queries/injections.scm", "(pair value: (string) @injection.content)"),
                ("/g/lean/queries/highlights.scm", declaredHighlights)] with
          | none => false
          | some driver =>
            let before := openedIn driver "/w/a.md"
            let (answered, delivered) := before.finish 1
            attachedGrammars before == #[] && highlighters before == #[] &&
              injectedLanguages before == #[] &&
              delivered.isSome &&
              attachedGrammars answered == #["markdown"] &&
              highlighters answered == #[#["syntax.string"]] &&
              (injectedLanguages answered).filter (·.1 == "lean") ==
                #[("lean", #["syntax.number"])] &&
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
                Language.Grammar.said "ini" (.refused .notFound) (kept := false) &&
              answered.loop.state.echo ==
                "grammar `ini`: the grammar was refused: no file is at the grammar's path, so its languages have no syntax tree" &&
              attachedGrammars answered == #[] &&
              highlighters answered == #[] &&
              attachedGrammars after == #[] &&
              highlighters after == #[] &&
              buffers after == #["scratch", "/w/a.ini", "/w/b.ini"] },
    { name :=
        "a declared grammar named lean registers: a .lean buffer opened after the job's command is attached with the registered lean and highlighted with the declared query"
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
            attachedGrammars after == #["lean"] && highlighters after == #[#["syntax.number"]] &&
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
              answered.loop.state.grammars.registered ==
                #[("ini", { highlights := some declaredHighlights, indents := none })] },
    { name :=
        "the command of a job of an older config generation than the recorded answers' records nothing, highlights nothing again and says nothing: a .ini buffer opened before it stays plain and the newer answers stay"
      run :=
        pure <|
          let libraries :=
            #[("/g/libtree-sitter-ini.so", .exports #[("tree_sitter_ini", .grammar)])]
          match
            installedWith declaresIni libraries
              #[("/g/queries/highlights.scm", declaredHighlights)] with
          | none => false
          | some driver =>
            let newer : Language.Grammar.Answers :=
              { generation := 2, answers := #[("ini", .refused (.refused .notFound) true)] }
            let recorded :=
              (driver.stepped
                  (driver.loop.deliver driver.handed "newer answers" (setGrammarAnswers newer))).1
            let before := openedIn recorded "/w/a.ini"
            let (answered, delivered) := before.finish 1
            delivered.isSome && answered.loop.state.grammars == newer &&
              attachedGrammars answered == #[] &&
              highlighters answered == #[] &&
              answered.loop.state.echo == "" },
    { name :=
        "a grammar registered by one install and refused by the next is said to stay as registered before, and a .ini buffer highlighted again by the second job's command keeps the highlights read at the first registration"
      run :=
        pure <|
          let libraries :=
            #[("/g/libtree-sitter-ini.so", .exports #[("tree_sitter_ini", .grammar)])]
          match
            installedWith declaresIni libraries
              #[("/g/queries/highlights.scm", declaredHighlights)],
            installOver shippedState declaresIni with
          | some driver, some (first, _) =>
            let (answered, _) := driver.finish 1
            let opened := openedIn answered "/w/a.ini"
            match installOver first (declaresIniFrom "/h/libtree-sitter-ini.so") with
            | none => false
            | some (second, generation, grammars) =>
              let reinstalled :=
                { opened with
                  keys := { opened.keys with registered := second.registry.registered } }
              let started :=
                reinstalled.startWork Language.Grammar.jobName
                  (Language.Grammar.work checkedPlatform generation grammars)
              let (refused, delivered) := started.finish 2
              generation == 2 && delivered.isSome && attachedGrammars opened == #["ini"] &&
                highlighters opened == #[#["syntax.number"]] &&
                refused.loop.state.echo ==
                  "grammar `ini`: the grammar was refused: no file is at the grammar's path, so the grammar registered before stays" &&
                attachedGrammars refused == #["ini"] &&
                highlighters refused == #[#["syntax.number"]]
          | _, _ => false },
    { name :=
        "a package's per-platform grammar ini, registered on a platform its declaration does not list, is answered with a refusal naming that platform, said in the echo area"
      run :=
        pure <|
          match
            installedWith (pure ())
              #[("/s/grammars/ini-grammar/darwin-aarch64/libtree-sitter-ini.so",
                  .exports #[("tree_sitter_ini", .grammar)])]
              #[("/s/grammars/ini-grammar/queries/highlights.scm", packageHighlights)] (platform :=
              "linux-x86_64") (packages := #[iniPackage]) (grammarDirectories := iniStagedAt) with
          | none => false
          | some driver =>
            let (answered, delivered) := driver.finish 1
            delivered.isSome &&
              answered.loop.state.echo ==
                "grammar `ini`: the grammar's registration failed: it declares no library for the platform `linux-x86_64`, so its languages have no syntax tree" &&
              answered.jobs.grammars.registered == GrammarRegistry.testGrammars.registered },
    { name :=
        "and an .ini buffer opened before or after the job's command opens with no syntax tree"
      run :=
        pure <|
          match
            installedWith (pure ())
              #[("/s/grammars/ini-grammar/darwin-aarch64/libtree-sitter-ini.so",
                  .exports #[("tree_sitter_ini", .grammar)])]
              #[("/s/grammars/ini-grammar/queries/highlights.scm", packageHighlights)] (platform :=
              "linux-x86_64") (packages := #[iniPackage]) (grammarDirectories := iniStagedAt) with
          | none => false
          | some driver =>
            let before := openedIn driver "/w/a.ini"
            let (answered, _) := before.finish 1
            let after := openedIn answered "/w/b.ini"
            let buffers (driver : TestDriver) : Array String :=
              driver.loop.state.buffers.filterMap (·.map (·.name))
            attachedGrammars before == #[] && attachedGrammars answered == #[] &&
              highlighters answered == #[] &&
              attachedGrammars after == #[] &&
              highlighters after == #[] &&
              buffers after == #["scratch", "/w/a.ini", "/w/b.ini"] },
    { name :=
        "a config declaring ini over the package's ini registers config's library, and an .ini buffer is attached with ini and highlighted with config's queries, not the package's"
      run :=
        pure <|
          let packageLibrary := "/s/grammars/ini-grammar/darwin-aarch64/libtree-sitter-ini.so"
          let configLibrary := "/g/libtree-sitter-ini.so"
          match
            installedWith (defineGrammar "ini" configLibrary)
              #[(packageLibrary, .exports #[("tree_sitter_ini", .grammar)]),
                (configLibrary, .exports #[("tree_sitter_ini", .grammar)])]
              #[("/s/grammars/ini-grammar/queries/highlights.scm", packageHighlights),
                ("/g/queries/highlights.scm", declaredHighlights)]
              (packages := #[iniPackage]) (grammarDirectories := iniStagedAt) with
          | none => false
          | some driver =>
            let (answered, _) := driver.finish 1
            let opened := openedIn answered "/w/a.ini"
            (answered.jobs.grammars.sourceOf? "ini").map (·.library) == some configLibrary &&
              attachedGrammars opened == #["ini"] &&
              highlighters opened == #[#["syntax.number"]] &&
              answered.loop.state.echo == "" },
    { name :=
        "registering a per-platform grammar on a platform it does not list answers a refusal naming that platform, asks the grammar service nothing, and says it in the echo with no syntax tree for its languages"
      run :=
        pure <|
          let library := "/g/darwin-aarch64/libtree-sitter-ini.so"
          let setup : SetupM Unit := do
            defineGrammarPerPlatform "ini" [("darwin-aarch64", library)] "/g/queries"
            defineLanguage
                { name := "ini", patterns := [.extension "ini"],
                  syntaxTree := { grammar := "ini" } }
          match
            installedWith setup #[(library, .exports #[("tree_sitter_ini", .grammar)])]
              #[("/g/queries/highlights.scm", declaredHighlights)] (platform :=
              "linux-riscv64") with
          | none => false
          | some driver =>
            let (answered, delivered) := driver.finish 1
            let opened := openedIn answered "/w/a.ini"
            delivered.isSome &&
              answered.loop.state.echo ==
                "grammar `ini`: the grammar's registration failed: it declares no library for the platform `linux-riscv64`, so its languages have no syntax tree" &&
              answered.loop.state.grammars.answerOf? 1 "ini" ==
                some
                  (.refused (.failed "it declares no library for the platform `linux-riscv64`")
                    false) &&
              answered.jobs.grammars.registered == GrammarRegistry.testGrammars.registered &&
              attachedGrammars opened == #[] &&
              highlighters opened == #[] }]

end ModelTest
