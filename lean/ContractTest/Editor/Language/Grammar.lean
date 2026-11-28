import ContractTest.Check
import Editor.Face
import Editor.Job.Contract
import Editor.Language
import Editor.Language.Grammar
import Editor.Test.Linked.Grammar
import Editor.Test.Linked.Services

/-!
# Contract tests: `Editor/Language/Grammar.lean`

The tests of `Editor/Language/Grammar.lean` over the real library:
`grammarDeclarationChecks`, the wiring of a declared grammar from its
declaration to a drawn frame, written on the linked kit's
`Editor.Test.Linked.declaredDrawn`, which a package's check of the grammar
it ships uses too. The root module `ContractTest` runs them; its
module doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- The language the wiring check enters the INI fixture with: `*.ini`,
naming the grammar `ini`, with no query of its own. -/
def declaredIniLanguage : Language :=
  { name := "ini", patterns := [.extension "ini"], syntaxTree := { grammar := "ini" } }

-- inferred-waits W90: stays (the declared grammar's wiring over the real binding, settled on its own snapshot, through `declaredDrawn`)
set_option linter.inferredWait false in
/-- The check of `grammarDeclarationChecks`, a declaration of its own so that
the allow above it covers it alone. -/
def declaredGrammarDrawnCheck (completions : Job.Completions) (fixture : JobContract.GrammarFixture)
    (syntaxFixtures : System.FilePath) : Check :=
  { name :=
      "the fixture grammar library, declared by its name and path alone, registers through the library's grammar registrations, its highlights query is read from the queries directory beside it through the library's file service, and the INI fixture, entered with a language naming it, is drawn by the real display with its section name in the type face's colour, its keys in the property face's colour and its values in the string face's colour"
    run := do
      let ini := Language.Grammar.declare "ini" fixture.library
      let services ← Services.over completions
      let red := Color.rgb 0xcc 0 0
      let green := Color.rgb 0 0xcc 0
      let blue := Color.rgb 0 0 0xcc
      let settings ← IO.FS.readFile (syntaxFixtures / "ini" / "settings.ini")
      -- The view starts at the section `[window]`, byte 101 of the fixture.
      let some frame ←
        declaredDrawn services Language.Grammar.currentPlatform #[ini] declaredIniLanguage settings
            #[{ name := ⟨"syntax.type"⟩, face := { foreground := some red } },
              { name := ⟨"syntax.property"⟩, face := { foreground := some green } },
              { name := ⟨"syntax.string"⟩, face := { foreground := some blue } }]
            101 | return false
      -- `[window]`: the brackets in no face of these, the name red;
      -- `width = 1200`: the key green, ` = ` in no face of these, the value
      -- blue.
      let header := "runs 0..1:000000ff/ffffffff 1..7:cc0000ff/ffffffff 7..8:000000ff/ffffffff\n"
      let pair := "runs 0..5:00cc00ff/ffffffff 5..8:000000ff/ffffffff 8..12:0000ccff/ffffffff\n"
      return (frame.splitOn header).length == 2 && (frame.splitOn pair).length == 2 }

/-- The checks of a declared grammar over the real library
(`Editor/Language/Grammar.lean`, `Editor/Language/Grammar/Register.lean`):
the core's registration job on the library's grammar and file services,
the core's reading of its answers and resolution of a language's tree, and
the text entered with that tree on the real syntax tree binding and drawn on
the real display. It registers only the fixture's own name, `ini`, never one
the test grammars registered, so later checks see the same service. -/
def grammarDeclarationChecks (completions : Job.Completions) (fixture : JobContract.GrammarFixture)
    (syntaxFixtures : System.FilePath) : List Check :=
  [declaredGrammarDrawnCheck completions fixture syntaxFixtures]

end ContractTest
