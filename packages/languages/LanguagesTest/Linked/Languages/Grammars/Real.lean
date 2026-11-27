import Editor.Config.Packages
import Editor.Face
import Editor.Language.Grammar
import Editor.Package
import Editor.RealHost
import Editor.Test.Linked.Grammar
import Editor.Test.Linked.Services
import Languages.EditorPackage
import Languages.Grammars
import LanguagesTest.Check

/-!
# Linked tests: `Languages/Grammars.lean`, over the real library

The wiring checks of the grammars `languages` ships from source
(`realChecks`): what the default set's build compiled and staged, read
through the record beside the set's editor, and the package's own
declaration and language, resolved against that staged directory as it
is, registered and drawn over the library's real grammar, file and syntax
services and its display. The root, `LanguagesTest/Linked.lean`, runs them
over the services it starts.

- **The staged check.** The default set's editor is `../.lake/build/bin/editor`
  from the package's directory, where the linked test runs. Its record,
  read with the kit's `Editor.Test.Linked.stagedGrammarsDirectory`, names
  `languages` at `<set build dir>/grammars/languages`, which holds the
  package's `queries/yaml/highlights.scm`, byte for byte, and a library at
  exactly the path the declaration names for this platform, which the
  package's own `grammars/` does not hold: the set's build compiled it.
- **The drawn check.** The entry module's packages, tagged with the Lake
  package and resolved against that staged directory with nothing copied
  and no library handed in (`Config.State.ofPackages`), register `yaml`
  with no refusal, and the YAML fixture (`tests/syntax/yaml/settings.yaml`)
  is drawn by the real display through the kit's `declaredDrawn`, its
  comment, its keys and string, and its number each in the colour of the
  faces the query's captures map to.

What these rest on is pinned elsewhere: where a staged grammars directory is
read from, `ModelTest.moduleLookupChecks`; a package's grammars resolved,
refused and registered, `ModelTest.packageChecks` and the package's own
`grammarPackageChecks`; the forms of a set's build, the `#guard`s of
`grammarSourceForm` in `lean/lakefile.lean`. Here the subject is the wiring
alone: a grammar the set's build compiled reaches the real loader and the
highlighter.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.LanguagesTest.Linked.Languages.Grammars.Real : Editor.WiringSet :=
  .wiring "the library's grammar, file and syntax services and its display"
    "a grammar the set's build compiled reaches the real loader and highlighter only through them"

namespace LanguagesTest.Linked

open Editor
open Editor.Test.Linked

/-- What the root hands the checks: the real services it started, and the
toolchain's directory, whose `lake` builds a set. -/
structure Context where
  /-- The real services, over the one completion pump. -/
  services : Services
  /-- The toolchain's directory (`lean --print-prefix`). -/
  sysroot : System.FilePath

/-- The default set's editor, from the package's directory: beside it, its
build wrote the record of where it staged each grammars directory. -/
def defaultSetEditor : IO System.FilePath :=
  IO.FS.realPath (".." / ".lake" / "build" / "bin" / "editor")

/-- The YAML syntax fixture, from the package's directory. -/
def yamlFixture : System.FilePath :=
  ".." / ".." / "tests" / "syntax" / "yaml" / "settings.yaml"

/-- The check of AC 1: the default set's build compiled the grammar `yaml`
and staged it, with the package's queries, in the set's build directory. -/
def stagedCheck : Check :=
  { name :=
      "the default set's build staged languages' grammars directory in the set's build directory, as the record beside its editor names it, holding queries/yaml/highlights.scm with the bytes of the package's own copy and a library at the path the yaml declaration names for this platform, which the package's own grammars directory does not hold: the set's build compiled it"
    run := do
      let editor ← defaultSetEditor
      let some staged ←
        stagedGrammarsDirectory editor
            "languages" | saw false s!"no record line for languages beside {editor}"
      let buildDir ← IO.FS.realPath ((editor.parent.bind (·.parent)).getD ".")
      let some relative := Languages.Grammars.yamlGrammar.libraryOn Language.Grammar.currentPlatform
        | saw false s!"the yaml declaration names no library for {Language.Grammar.currentPlatform}"
      let own ← IO.FS.readBinFile ("grammars" / "queries" / "yaml" / "highlights.scm")
      let copied ← IO.FS.readBinFile (staged / "queries" / "yaml" / "highlights.scm")
      let compiled ← (staged / relative).pathExists
      let shipped ← ("grammars" / relative).pathExists
      saw
          ((← IO.FS.realPath staged) == buildDir / "grammars" / "languages" && copied == own &&
            compiled &&
            !shipped)
          s!"staged={staged} buildDir={buildDir} library {relative}: compiled={compiled} in the package's own grammars={shipped}" }

/-- The faces the drawn check colours: the comment's, the number's, and one
colour for both the property's and the string's. A key is a plain scalar,
which the query captures both as `@string` and, in a mapping's key, as
`@property`; which capture a highlighter draws is the highlighter's rule,
pinned by its own tests, so the check gives both faces one colour and
holds whichever wins. -/
def yamlTheme : Theme :=
  #[{ name := ⟨"syntax.comment"⟩, face := { foreground := some (Color.rgb 0xcc 0xcc 0) } },
    { name := ⟨"syntax.property"⟩, face := { foreground := some (Color.rgb 0 0xcc 0) } },
    { name := ⟨"syntax.string"⟩, face := { foreground := some (Color.rgb 0 0xcc 0) } },
    { name := ⟨"syntax.number"⟩, face := { foreground := some (Color.rgb 0 0 0xcc) } }]

-- inferred-waits W95: stays (a grammar the set's build compiled, over the real binding, its own text settled on its own snapshot, through `declaredDrawn`)
set_option linter.inferredWait false in
/-- The check of AC 3: the package's grammar `yaml`, resolved against the
staged directory as the set's build left it, highlights the YAML fixture
through the real services and display. -/
def drawnCheck (context : Context) : Check :=
  { name :=
      "the package's grammar yaml, resolved against the directory the default set's build staged with nothing copied, registers through the library's grammar registrations with no refusal, and the YAML fixture, entered with the package's own language yaml, is drawn by the real display with its comment in the comment face's colour, its keys and its string in the colour of the property and string faces, the separators in neither, and its number in the number face's colour"
    run := do
      let some staged ←
        stagedGrammarsDirectory (← defaultSetEditor)
            "languages" | saw false "no record line for languages"
      let settings ← IO.FS.readFile yamlFixture
      let (state, refused) : Config.State Unit Unit × Array String :=
        Config.State.ofPackages (Package.shipping "languages" Languages.EditorPackage.packages)
          [("languages", staged)]
      let grammars := state.registry.grammarTable.toArray
      let some language := state.registry.languageTable.find? (·.name == "yaml")
        | saw false s!"no language yaml; refused={refused}"
      let some frame ←
        declaredDrawn context.services Language.Grammar.currentPlatform grammars language settings
            yamlTheme 0 | saw false s!"nothing drawn; refused={refused} grammars={repr grammars}"
      -- `# Settings, YAML`: the comment, yellow; `name: "editor"`: the key
      -- green, `: ` in no face of these, the string green; `width: 1200`:
      -- the key green, `: ` in no face of these, the number blue.
      let comment := "runs 0..16:cccc00ff/ffffffff\n"
      let named := "runs 0..4:00cc00ff/ffffffff 4..6:000000ff/ffffffff 6..14:00cc00ff/ffffffff\n"
      let width := "runs 0..5:00cc00ff/ffffffff 5..7:000000ff/ffffffff 7..11:0000ccff/ffffffff\n"
      saw
          (refused.isEmpty && grammars.map (·.name) == #["yaml"] &&
            (frame.splitOn comment).length == 2 &&
            (frame.splitOn named).length == 2 &&
            (frame.splitOn width).length == 2)
          s!"refused={refused} frame={frame}" }

/-- The wiring checks of the grammars the package ships from source, in
order: what the set's build staged, then the grammar drawn. -/
def realChecks (context : Context) : List Check :=
  [stagedCheck, drawnCheck context]

end LanguagesTest.Linked
