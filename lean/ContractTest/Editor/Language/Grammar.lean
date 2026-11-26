import ContractTest.Check
import ContractTest.Support.Files
import ContractTest.Support.Syntax
import Editor.Command
import Editor.Display
import Editor.Display.Real
import Editor.Ffi.Display
import Editor.Ffi.Syntax
import Editor.Highlight
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Language
import Editor.Language.Grammar
import Editor.Language.Grammar.Answer
import Editor.Language.Grammar.Register
import Editor.Scene
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Test.Linked.Jobs
import Editor.Text
import Editor.Text.Real

/-!
# Contract tests: `Editor/Language/Grammar.lean`

The tests of `Editor/Language/Grammar.lean` over the real library:
`grammarDeclarationChecks`, the wiring of a declared grammar from its
declaration to a drawn frame. The root module `ContractTest` runs them; its
module doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- The language the wiring check enters the INI fixture with: `*.ini`,
naming the grammar `ini`, with no query of its own. -/
def declaredIniLanguage : Language :=
  { name := "ini", patterns := [.extension "ini"], syntaxTree := { grammar := "ini" } }

/-- The command the wiring check's job finishes with, given what the job
brought back: the answers read as the core's command reads them
(`Language.Grammar.answersOf`), the language's tree resolved against them
(`Language.Grammar.treeOf`), and `text` entered with it as the `code` mode
enters it. -/
def enteredWith (ini : Language.Grammar) (text : TextId) (replies : Array Language.Grammar.Reply) :
    EditorM Unit := do
  let (answers, sentences) ← Language.Grammar.answersOf {} 1 replies
  unless sentences.isEmpty do
    throw .noSuchText
  let some tree := Language.Grammar.treeOf [ini] answers 1 declaredIniLanguage.syntaxTree |
    throw .noSuchText
  Highlight.enter Language.codeName text tree

-- inferred-waits W90: stays (the declared grammar's wiring over the real binding, settled on its own snapshot)
set_option linter.inferredWait false in
/-- The check of `grammarDeclarationChecks`, a declaration of its own so that
the allow above it covers it alone. -/
def declaredGrammarDrawnCheck (completions : Job.Completions) (fixture : JobContract.GrammarFixture)
    (syntaxFixtures : System.FilePath) : Check :=
  { name :=
      "the fixture grammar library, declared by its name and path alone, registers through the library's grammar registrations, its highlights query is read from the queries directory beside it through the library's file service, and the INI fixture, entered with a language naming it, is drawn by the real display with its section name in the type face's colour, its keys in the property face's colour and its values in the string face's colour"
    run := do
      let ini := Language.Grammar.declare "ini" fixture.library
      let rig ← FileRig.new completions
      let services :=
        { rig.services with grammars := Job.realGrammars completions (← Job.RefusedGrammars.new) }
      let red := Color.rgb 0xcc 0 0
      let green := Color.rgb 0 0xcc 0
      let blue := Color.rgb 0 0 0xcc
      let display ← Ffi.Display.newCells 8 16
      let shown ←
        RealDisplay.over display rig.published.reader
            #[{ name := ⟨"syntax.type"⟩, face := { foreground := some red } },
              { name := ⟨"syntax.property"⟩, face := { foreground := some green } },
              { name := ⟨"syntax.string"⟩, face := { foreground := some blue } }]
      let settings ← IO.FS.readFile (syntaxFixtures / "ini" / "settings.ini")
      let made : EditorM TextId := createText settings
      let (.ok text, texts) ← made.runReal (.over rig.published) shown.handle | return false
      let handle ←
        Job.spawn services (Work.of (fun _ => Language.Grammar.register #[ini]) (enteredWith ini text))
          (pure ())
      discard <| hangGuarded "the registration job's end" handle.outcome.result?
      let some (.finished command) ← handle.outcome? | return false
      let real ← RealSyntaxTree.new rig.published.reader
      let syntaxTree := settlingAttach rig.published real.handle
      let (entered, texts) ←
        Job.finishWith rig.held handle command texts shown.handle (syntaxTree := syntaxTree)
      -- The view starts at the section `[window]`, byte 101 of the fixture.
      let viewed : EditorM (SnapshotId × MarkerId) := do
        return (← text.snapshot, ← text.mark (.anchor { offset := 101, bias := .before }))
      let (.ok (snapshot, scroll), texts) ← viewed.runReal texts shown.handle | return false
      let some found ← rig.published.find? snapshot | return false
      unless ← Ffi.syntaxSettle found Ffi.treeGuard do
        return false
      discard drainedParsed
      let scene : Scene :=
        { size := { width := 160, height := 64 }
          views :=
            #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 64 }, snapshot
                scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                decorations := #[], status := #[] }]
          focused := none, echo := "", pending := "", preedit := none }
      let publish : EditorM Unit := Display.publish scene
      let (published, _) ← publish.runReal texts shown.handle
      let frame ← display.frameText
      -- `[window]`: the brackets in no face of these, the name red;
      -- `width = 1200`: the key green, ` = ` in no face of these, the value
      -- blue.
      let header := "runs 0..1:000000ff/ffffffff 1..7:cc0000ff/ffffffff 7..8:000000ff/ffffffff\n"
      let pair := "runs 0..5:00cc00ff/ffffffff 5..8:000000ff/ffffffff 8..12:0000ccff/ffffffff\n"
      return entered.isOk && published.isOk && (frame.splitOn header).length == 2 &&
          (frame.splitOn pair).length == 2 }

/-- The checks of a declared grammar over the real library
(`Editor/Language/Grammar.lean`, `Editor/Language/Grammar/Register.lean`):
the core's registration job on the library's grammar and file services,
the core's reading of its answers and resolution of a language's tree, and
the text entered with that tree on the real syntax tree binding and drawn on
the real display. It registers only the fixture's own name, `ini`, never a
compiled-in one, so later checks see the same service. -/
def grammarDeclarationChecks (completions : Job.Completions)
    (fixture : JobContract.GrammarFixture) (syntaxFixtures : System.FilePath) : List Check :=
  [declaredGrammarDrawnCheck completions fixture syntaxFixtures]

end ContractTest
