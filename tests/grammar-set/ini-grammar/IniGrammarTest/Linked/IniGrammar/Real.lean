import Editor.Config.Packages
import Editor.Face
import Editor.Language.Grammar
import Editor.ModuleLookup
import Editor.RealHost
import Editor.Test.Linked.Grammar
import Editor.Test.Linked.Services
import IniGrammar.EditorPackage
import IniGrammarTest.Check

/-!
# Linked tests: `IniGrammar.lean`, over the real library

The wiring checks of the test package's grammar (`realChecks`): what the
grammar set's build staged, read through the record beside the set's
editor, and the package's own declaration and language, resolved against a
copy of that staged directory, registered and drawn over the library's real
grammar, file and syntax services and its display. The root,
`IniGrammarTest/Linked.lean`, runs them over the services it starts.

The ordering the second check touches is pinned elsewhere: a package
registers before config, config's declaration of a name over a package's,
and a refusal on a platform the declaration does not list, on the models
(`ModelTest.packageChecks`, `ModelTest.grammarRegisterChecks`); the
registration job and its command on the job model. Here the subject is the
wiring alone: a package's grammar file reaches the real loader and the
highlighter.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.IniGrammarTest.Linked.IniGrammar.Real : Editor.WiringSet :=
  .wiring "the library's grammar, file and syntax services and its display"
    "a package's grammar file reaches the real loader and highlighter only through them"

namespace IniGrammarTest.Linked

open Editor
open Editor.Test.Linked

/-- What the root hands the checks: the real services it started, the
grammar set's editor, the fixture grammar library Cargo built, and the
directory of the syntax fixtures. -/
structure Context where
  /-- The real services, over the one completion pump. -/
  services : Services
  /-- The grammar set's editor, beside which its build wrote its records. -/
  editor : System.FilePath
  /-- The fixture grammar library (`crates/editor-syntax-fixture-ini`). -/
  library : System.FilePath
  /-- The syntax fixtures (`tests/syntax`). -/
  syntaxFixtures : System.FilePath

/-- A file's text, or none when it cannot be read: the edge's read of a
record. -/
def readFile? (path : System.FilePath) : IO (Option String) := do
  try
    return some (← IO.FS.readFile path)
  catch _ =>
    return none

/-- Copies the directory `source` into `copy`, each file's bytes. -/
partial def copyTree (source copy : System.FilePath) : IO Unit := do
  IO.FS.createDirAll copy
  for entry in ← source.readDir do
    if ← entry.path.isDir then
      copyTree entry.path (copy / entry.fileName)
    else
      IO.FS.writeBinFile (copy / entry.fileName) (← IO.FS.readBinFile entry.path)

/-- The directory the grammar set's build staged `ini-grammar`'s grammars
directory in, as the record beside its editor names it
(`ModuleLookup.grammarDirectories`); none when it names none. -/
def stagedDirectory (context : Context) : IO (Option System.FilePath) := do
  let directories ← ModuleLookup.grammarDirectories context.editor.toString readFile?
  return (directories.find? (·.1 == "ini-grammar")).map (·.2)

/-- The check of AC 3: the grammar set's build staged the package's
`grammars/` in the set's build directory. -/
def stagedCheck (context : Context) : Check :=
  { name :=
      "the grammar set's build staged ini-grammar's grammars directory in the set's build directory: the record beside the set's editor, read with ModuleLookup.grammarDirectories, names it for ini-grammar, and it holds queries/highlights.scm with the bytes of the package's own grammars/queries/highlights.scm"
    run := do
      let some staged ← stagedDirectory context | saw false "no record line for ini-grammar"
      let buildDir ← IO.FS.realPath ((context.editor.parent.bind (·.parent)).getD ".")
      let own ← IO.FS.readBinFile ("grammars" / "queries" / "highlights.scm")
      let copied ← IO.FS.readBinFile (staged / "queries" / "highlights.scm")
      saw ((← IO.FS.realPath staged) == buildDir / "grammars" / "ini-grammar" && copied == own)
          s!"staged={staged} buildDir={buildDir}" }

/-- The faces the drawn check gives distinct colours: the section name's,
the keys' and the values'. -/
def iniTheme : Theme :=
  #[{ name := ⟨"syntax.type"⟩, face := { foreground := some (Color.rgb 0xcc 0 0) } },
    { name := ⟨"syntax.property"⟩, face := { foreground := some (Color.rgb 0 0xcc 0) } },
    { name := ⟨"syntax.string"⟩, face := { foreground := some (Color.rgb 0 0 0xcc) } }]

-- inferred-waits W92: stays (a package's grammar over the real binding, its own text settled on its own snapshot, through `declaredDrawn`)
set_option linter.inferredWait false in
/-- The check of AC 4: the package's grammar, resolved against a copy of the
staged directory that holds the fixture library at this platform's path,
highlights the INI fixture through the real services and display. -/
def drawnCheck (context : Context) : Check :=
  { name :=
      "the package's per-platform grammar ini, resolved against a copy of that staged directory that holds the fixture library at this platform's path, registers through the library's grammar registrations, and the INI fixture, entered with the package's own language ini, is drawn by the real display with its section name in the type face's colour, its keys in the property face's colour and its values in the string face's colour"
    run := do
      let some staged ← stagedDirectory context | saw false "no record line for ini-grammar"
      let some declared := IniGrammar.package.grammars[0]? | saw false "the package declares none"
      let some relative := declared.libraryOn Language.Grammar.currentPlatform
        | saw false s!"no library for {Language.Grammar.currentPlatform}"
      let settings ← IO.FS.readFile (context.syntaxFixtures / "ini" / "settings.ini")
      withFiles context.services.jobs fun directory => do
          let copy := directory / "ini-grammar"
          copyTree staged copy
          let library := copy / relative
          if let some parent := library.parent then
            IO.FS.createDirAll parent
          IO.FS.writeBinFile library (← IO.FS.readBinFile context.library)
          let (state, refused) : Config.State Unit Unit × Array String :=
            Config.State.ofPackages
              (Package.shipping "ini-grammar" IniGrammar.EditorPackage.packages)
              [("ini-grammar", copy)]
          let grammars := state.registry.grammarTable.toArray
          let some language := state.registry.languageTable.find? (·.name == "ini")
            | saw false s!"no language ini; refused={refused}"
          -- The view starts at the section `[window]`, byte 101 of the fixture.
          let some frame ←
            declaredDrawn context.services Language.Grammar.currentPlatform grammars language
                settings iniTheme
                101 | saw false s!"nothing drawn; refused={refused} grammars={repr grammars}"
          -- `[window]`: the brackets in no face of these, the name red;
          -- `width = 1200`: the key green, ` = ` in no face of these, the
          -- value blue.
          let header :=
            "runs 0..1:000000ff/ffffffff 1..7:cc0000ff/ffffffff 7..8:000000ff/ffffffff\n"
          let pair := "runs 0..5:00cc00ff/ffffffff 5..8:000000ff/ffffffff 8..12:0000ccff/ffffffff\n"
          saw
              (refused.isEmpty && grammars.map (·.name) == #["ini"] &&
                (frame.splitOn header).length == 2 &&
                (frame.splitOn pair).length == 2)
              s!"refused={refused} frame={frame}" }

/-- The wiring checks of the package's grammar, in order: what the set's
build staged, then the grammar drawn. -/
def realChecks (context : Context) : List Check :=
  [stagedCheck context, drawnCheck context]

end IniGrammarTest.Linked
