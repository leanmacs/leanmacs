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
declarations and languages, resolved against that staged directory as it
is, registered and drawn over the library's real grammar, file and syntax
services and its display. The library compiles in no grammar, so what is
drawn is the package's grammars alone. The root,
`LanguagesTest/Linked.lean`, runs them over the services it starts.

- **The staged check.** The default set's editor is `../.lake/build/bin/editor`
  from the package's directory, where the linked test runs. Its record,
  read with the kit's `Editor.Test.Linked.stagedGrammarsDirectory`, names
  `languages` at `<set build dir>/grammars/languages`, which holds, for
  every grammar of `languages-grammars`, a library at exactly the path its
  declaration names for this platform, which the package's own `grammars/`
  does not hold, so the set's build compiled it, and each file of the
  package's `grammars/queries/<name>/`, byte for byte, a `highlights.scm`
  among them.
- **The registered check** (`registeredCheck`). The entry module's
  packages, tagged with the Lake package and resolved against that staged
  directory with nothing copied and no library handed in
  (`Config.State.ofPackages`), give every grammar of the package; each
  registers on this platform through the library's grammar registrations
  with a highlights query read, and each query it read compiles against it
  on the real syntax tree (the kit's `declaredRegistered`). The other
  checks draw a few of them; this one holds all seventeen.
- **The drawn checks.** The same packages, resolved the same way, register
  the package's grammars with no refusal, and a fixture is drawn by the
  real display through the kit's `declaredDrawn`, each capture in the
  colour of the face it maps to:
  - `drawnCheck`: the YAML fixture (`tests/syntax/yaml/settings.yaml`),
    entered with the package's language `yaml`: its comment, its keys and
    string, and its number.
  - `rustDrawnCheck`: the Rust fixture (`tests/syntax/rust/hello.rs`),
    entered with the shipped language `rust`: its comment, the keywords
    `fn` and `let`, and its number.
  - `markdownInlineDrawnCheck`: the Markdown fixture
    (`tests/syntax/markdown/inline.md`), one plain paragraph, entered with
    the shipped language `markdown` and every registered language handed
    to the kit for its injected languages. The block grammar captures
    nothing on a plain paragraph, and the inline grammar's `@text.*`
    captures map to no face (`Language.markdown` sets no capture mapping),
    so the check holds the captures that do map: each emphasis and
    code-span delimiter in the punctuation face's colour and the
    backslash escape in the string face's. They are drawn only if the
    block grammar's injection reached `markdown_inline` and the injected
    language took its declared queries.
  - `pythonDrawnCheck`: the Python fixture (`tests/syntax/python/hello.py`),
    entered with the package's language `python`: its comment, `def` and
    `return`, the defined function's name and its number. The name is
    drawn as a function only because the entry maps `variable` to no face:
    the query's catch-all `(identifier) @variable` is its first pattern,
    and the earliest pattern wins (`Languages/Grammars.lean`).
  - `pythonFenceDrawnCheck`: a Markdown fence of `python`
    (`tests/syntax/markdown/python.md`), entered with `markdown` and every
    registered language: the fences' backticks in the punctuation face's
    colour, from the block grammar, and the number in the fence in the
    number face's, which only the injected `python` captures, with its
    declared highlights.

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

/-- What is wrong with the grammar `grammar` as the set's build staged it in
`staged`: no library at the path its declaration names for this platform,
one in the package's own `grammars/` (so the build did not compile it), no
`highlights.scm` in the package's `grammars/queries/<name>/`, or a query
file not copied byte for byte; none when nothing is. -/
def stagedProblem (staged : System.FilePath) (grammar : Language.Grammar) : IO (Option String) := do
  let some relative := grammar.libraryOn Language.Grammar.currentPlatform
    | return some s!"{grammar.name}: no library for {Language.Grammar.currentPlatform}"
  unless ← (staged / relative).pathExists do
    return some s!"{grammar.name}: no library at {staged / relative}"
  if ← ("grammars" / relative).pathExists then
    return some s!"{grammar.name}: a library in the package's own grammars at {relative}"
  let queries : System.FilePath := "grammars" / "queries" / grammar.name
  let files ← queries.readDir
  unless files.any (·.fileName == "highlights.scm") do
    return some s!"{grammar.name}: no highlights.scm in {queries}"
  for file in files do
    let copied := staged / "queries" / grammar.name / file.fileName
    unless ← copied.pathExists do
      return some s!"{grammar.name}: {copied} not staged"
    unless (← IO.FS.readBinFile file.path) == (← IO.FS.readBinFile copied) do
      return some s!"{grammar.name}: {copied} differs from {file.path}"
  return none

/-- The check of AC 1: the default set's build compiled every grammar of
the package and staged it, with the package's queries, a highlights query
among them, in the set's build directory (that each registers is
`registeredCheck`'s). -/
def stagedCheck : Check :=
  { name :=
      "the default set's build staged languages' grammars directory in the set's build directory, as the record beside its editor names it, holding for every grammar of languages-grammars a library at the path its declaration names for this platform, which the package's own grammars directory does not hold, so the set's build compiled it, and each query file of the package's grammars/queries/<name>/, with a highlights query, with the bytes of the package's own copy"
    run := do
      let editor ← defaultSetEditor
      let some staged ←
        stagedGrammarsDirectory editor
            "languages" | saw false s!"no record line for languages beside {editor}"
      let buildDir ← IO.FS.realPath ((editor.parent.bind (·.parent)).getD ".")
      let problems ← Languages.Grammars.package.grammars.filterMapM (stagedProblem staged)
      saw ((← IO.FS.realPath staged) == buildDir / "grammars" / "languages" && problems.isEmpty)
          s!"staged={staged} buildDir={buildDir} problems={problems}" }

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
          (refused.isEmpty &&
            grammars.map (·.name) == Languages.Grammars.package.grammars.map (·.name) &&
            (frame.splitOn comment).length == 2 &&
            (frame.splitOn named).length == 2 &&
            (frame.splitOn width).length == 2)
          s!"refused={refused} frame={frame}" }

/-- The Rust syntax fixture, from the package's directory. -/
def rustFixture : System.FilePath :=
  ".." / ".." / "tests" / "syntax" / "rust" / "hello.rs"

/-- The Markdown inline fixture, from the package's directory. -/
def markdownInlineFixture : System.FilePath :=
  ".." / ".." / "tests" / "syntax" / "markdown" / "inline.md"

/-- The faces the Rust check colours: the comment's, the keyword's and the
constant's, each its own colour. -/
def rustTheme : Theme :=
  #[{ name := ⟨"syntax.comment"⟩, face := { foreground := some (Color.rgb 0xcc 0xcc 0) } },
    { name := ⟨"syntax.keyword"⟩, face := { foreground := some (Color.rgb 0 0xcc 0) } },
    { name := ⟨"syntax.constant"⟩, face := { foreground := some (Color.rgb 0 0 0xcc) } }]

/-- The faces the Markdown inline check colours: the punctuation's and the
string's, each its own colour. -/
def markdownInlineTheme : Theme :=
  #[{ name := ⟨"syntax.punctuation"⟩, face := { foreground := some (Color.rgb 0 0xcc 0) } },
    { name := ⟨"syntax.string"⟩, face := { foreground := some (Color.rgb 0 0 0xcc) } }]

/-- The entry module's packages, tagged with the Lake package and resolved
against the directory the default set's build staged, with nothing copied:
the registered grammars, the registered languages in precedence order, and
each refused package's message; none when no record names the directory. -/
def registeredFromStaged : IO (Option (Array Language.Grammar × List Language × Array String)) := do
  let some staged ← stagedGrammarsDirectory (← defaultSetEditor) "languages" | return none
  let (state, refused) : Config.State Unit Unit × Array String :=
    Config.State.ofPackages (Package.shipping "languages" Languages.EditorPackage.packages)
      [("languages", staged)]
  return some (state.registry.grammarTable.toArray, state.registry.languageTable, refused)

-- inferred-waits W95: stays (a grammar the set's build compiled, over the real binding, its own text settled on its own snapshot, through `declaredDrawn`)
set_option linter.inferredWait false in
/-- The check of AC 3 for a `.rs` file: the package's grammar `rust`,
resolved against the staged directory as the set's build left it,
highlights the Rust fixture through the real services and display. -/
def rustDrawnCheck (context : Context) : Check :=
  { name :=
      "the package's grammar rust, resolved against the directory the default set's build staged with nothing copied, registers with no refusal, and the Rust fixture tests/syntax/rust/hello.rs, entered with the shipped language rust as registered, is drawn by the real display with its comment in the comment face's colour, fn and let in the keyword face's colour, its number in the constant face's colour, and the rest in the default ink"
    run := do
      let some (grammars, languages, refused) ←
        registeredFromStaged | saw false "no record line for languages"
      let source ← IO.FS.readFile rustFixture
      let some language := languages.find? (·.name == "rust")
        | saw false s!"no language rust; refused={refused}"
      let some frame ←
        declaredDrawn context.services Language.Grammar.currentPlatform grammars language source
            rustTheme 0 | saw false s!"nothing drawn; refused={refused}"
      -- `// Hello`: the comment, yellow; `fn main() {`: `fn` green, the rest
      -- in the ink; `    let n = 42;`: `let` green, `42` blue, the rest in
      -- the ink; `}`: in the ink.
      let comment := "runs 0..8:cccc00ff/ffffffff\n"
      let function := "runs 0..2:00cc00ff/ffffffff 2..11:000000ff/ffffffff\n"
      let binding :=
        "runs 0..4:000000ff/ffffffff 4..7:00cc00ff/ffffffff 7..12:000000ff/ffffffff 12..14:0000ccff/ffffffff 14..15:000000ff/ffffffff\n"
      let closing := "runs 0..1:000000ff/ffffffff\n"
      saw
          (refused.isEmpty && (frame.splitOn comment).length == 2 &&
            (frame.splitOn function).length == 2 &&
            (frame.splitOn binding).length == 2 &&
            (frame.splitOn closing).length == 2)
          s!"refused={refused} frame={frame}" }

-- inferred-waits W95: stays (a grammar the set's build compiled, over the real binding, its own text settled on its own snapshot, through `declaredDrawn`)
set_option linter.inferredWait false in
/-- The check of AC 3 for a Markdown file's inline markup: the package's
grammars `markdown` and `markdown_inline`, resolved against the staged
directory as the set's build left it, highlight the inline fixture, its
inline markup drawn by the injected `markdown_inline` with its declared
queries, through the real services and display. -/
def markdownInlineDrawnCheck (context : Context) : Check :=
  { name :=
      "the package's grammars markdown and markdown_inline, resolved against the directory the default set's build staged with nothing copied, register with no refusal, and the Markdown fixture tests/syntax/markdown/inline.md, a plain paragraph entered with the shipped language markdown as registered and every registered language for its injections, is drawn by the real display with each emphasis and code-span delimiter in the punctuation face's colour and the backslash escape in the string face's colour, which only the injected markdown_inline's declared highlights capture, and its words in the default ink"
    run := do
      let some (grammars, languages, refused) ←
        registeredFromStaged | saw false "no record line for languages"
      let source ← IO.FS.readFile markdownInlineFixture
      let some language := languages.find? (·.name == "markdown")
        | saw false s!"no language markdown; refused={refused}"
      let some frame ←
        declaredDrawn context.services Language.Grammar.currentPlatform grammars language source
            markdownInlineTheme 0 languages | saw false s!"nothing drawn; refused={refused}"
      -- `Say *em* and`: each `*` green, the words in the ink; `` `code` and
      -- \*. ``: each backtick green, `\*` blue, the words and `.` in the ink.
      let emphasis :=
        "runs 0..4:000000ff/ffffffff 4..5:00cc00ff/ffffffff 5..7:000000ff/ffffffff 7..8:00cc00ff/ffffffff 8..12:000000ff/ffffffff\n"
      let code :=
        "runs 0..1:00cc00ff/ffffffff 1..5:000000ff/ffffffff 5..6:00cc00ff/ffffffff 6..11:000000ff/ffffffff 11..13:0000ccff/ffffffff 13..14:000000ff/ffffffff\n"
      saw
          (refused.isEmpty && (frame.splitOn emphasis).length == 2 &&
            (frame.splitOn code).length == 2)
          s!"refused={refused} frame={frame}" }

/-- The check of AC 2: every grammar of the package, resolved against the
staged directory as the set's build left it, registers on this platform
through the library's grammar registrations with a highlights query read,
and each query it read compiles against it on the real syntax tree. -/
def registeredCheck (context : Context) : Check :=
  { name :=
      "every grammar of languages-grammars, resolved against the directory the default set's build staged with nothing copied, registers through the library's grammar registrations on this platform with no refusal and a highlights query read, and each query it read compiles against it on the real syntax tree"
    run := do
      let some (grammars, _, refused) ←
        registeredFromStaged | saw false "no record line for languages"
      let some report ←
        declaredRegistered context.services Language.Grammar.currentPlatform
            grammars | saw false s!"no report; refused={refused}"
      let problems := report.filterMap fun (name, problem) => problem.map (s!"{name}: {·}")
      saw
          (refused.isEmpty &&
            report.map (·.1) == Languages.Grammars.package.grammars.map (·.name) &&
            problems.isEmpty)
          s!"refused={refused} names={report.map (·.1)} problems={problems}" }

/-- The Python syntax fixture, from the package's directory. -/
def pythonFixture : System.FilePath :=
  ".." / ".." / "tests" / "syntax" / "python" / "hello.py"

/-- The Markdown fixture with a Python fence, from the package's
directory. -/
def pythonFenceFixture : System.FilePath :=
  ".." / ".." / "tests" / "syntax" / "markdown" / "python.md"

/-- The faces the Python check colours: the comment's, the keyword's, the
function's and the number's, each its own colour, and none for the
variable's, so an identifier the query captures as `@variable` alone is
drawn in the ink. -/
def pythonTheme : Theme :=
  #[{ name := ⟨"syntax.comment"⟩, face := { foreground := some (Color.rgb 0xcc 0xcc 0) } },
    { name := ⟨"syntax.keyword"⟩, face := { foreground := some (Color.rgb 0 0xcc 0) } },
    { name := ⟨"syntax.function"⟩, face := { foreground := some (Color.rgb 0xcc 0 0xcc) } },
    { name := ⟨"syntax.number"⟩, face := { foreground := some (Color.rgb 0 0 0xcc) } }]

/-- The faces the Python fence check colours: the punctuation's and the
number's, each its own colour. -/
def pythonFenceTheme : Theme :=
  #[{ name := ⟨"syntax.punctuation"⟩, face := { foreground := some (Color.rgb 0 0xcc 0) } },
    { name := ⟨"syntax.number"⟩, face := { foreground := some (Color.rgb 0 0 0xcc) } }]

-- inferred-waits W95: stays (a grammar the set's build compiled, over the real binding, its own text settled on its own snapshot, through `declaredDrawn`)
set_option linter.inferredWait false in
/-- The check of AC 3: the package's grammar `python`, resolved against the
staged directory as the set's build left it, highlights the Python fixture
through the real services and display, with the package's language
`python`, whose `variable` maps to no face, so the query's `@function` of
a definition's name draws over its earlier `@variable`. -/
def pythonDrawnCheck (context : Context) : Check :=
  { name :=
      "the package's grammar python, resolved against the directory the default set's build staged with nothing copied, registers with no refusal, and the Python fixture tests/syntax/python/hello.py, entered with the package's language python as registered, is drawn by the real display with its comment in the comment face's colour, def and return in the keyword face's colour, the function's name in the function face's colour, its number in the number face's colour, and the rest in the default ink"
    run := do
      let some (grammars, languages, refused) ←
        registeredFromStaged | saw false "no record line for languages"
      let source ← IO.FS.readFile pythonFixture
      let some language := languages.find? (·.name == "python")
        | saw false s!"no language python; refused={refused}"
      let some frame ←
        declaredDrawn context.services Language.Grammar.currentPlatform grammars language source
            pythonTheme 0 | saw false s!"nothing drawn; refused={refused}"
      -- `# Hi`: the comment, yellow; `def f(x):`: `def` green, `f` magenta,
      -- the rest in the ink; `    return 42`: `return` green, `42` blue,
      -- the rest in the ink.
      let comment := "runs 0..4:cccc00ff/ffffffff\n"
      let definition :=
        "runs 0..3:00cc00ff/ffffffff 3..4:000000ff/ffffffff 4..5:cc00ccff/ffffffff 5..9:000000ff/ffffffff\n"
      let returned :=
        "runs 0..4:000000ff/ffffffff 4..10:00cc00ff/ffffffff 10..11:000000ff/ffffffff 11..13:0000ccff/ffffffff\n"
      saw
          (refused.isEmpty && (frame.splitOn comment).length == 2 &&
            (frame.splitOn definition).length == 2 &&
            (frame.splitOn returned).length == 2)
          s!"refused={refused} frame={frame}" }

-- inferred-waits W95: stays (a grammar the set's build compiled, over the real binding, its own text settled on its own snapshot, through `declaredDrawn`)
set_option linter.inferredWait false in
/-- The check of AC 3 for a Markdown fence of Python: the package's grammar
`python`, injected into a fence by the `markdown` grammar's injections,
takes its declared highlights. -/
def pythonFenceDrawnCheck (context : Context) : Check :=
  { name :=
      "the package's grammars markdown and python, resolved against the directory the default set's build staged with nothing copied, register with no refusal, and the Markdown fixture tests/syntax/markdown/python.md, a fence of python entered with the shipped language markdown as registered and every registered language for its injections, is drawn by the real display with each fence's backticks in the punctuation face's colour and the number in the fence in the number face's colour, which only the injected python's declared highlights capture, and the rest in the default ink"
    run := do
      let some (grammars, languages, refused) ←
        registeredFromStaged | saw false "no record line for languages"
      let source ← IO.FS.readFile pythonFenceFixture
      let some language := languages.find? (·.name == "markdown")
        | saw false s!"no language markdown; refused={refused}"
      let some frame ←
        declaredDrawn context.services Language.Grammar.currentPlatform grammars language source
            pythonFenceTheme 0 languages | saw false s!"nothing drawn; refused={refused}"
      -- ```` ```python ````: the backticks green, `python` in the ink;
      -- `x = 42`: `x = ` in the ink, `42` blue; ```` ``` ````: green.
      let opening := "runs 0..3:00cc00ff/ffffffff 3..9:000000ff/ffffffff\n"
      let assignment := "runs 0..4:000000ff/ffffffff 4..6:0000ccff/ffffffff\n"
      let closing := "runs 0..3:00cc00ff/ffffffff\n"
      saw
          (refused.isEmpty && (frame.splitOn opening).length == 2 &&
            (frame.splitOn assignment).length == 2 &&
            (frame.splitOn closing).length == 2)
          s!"refused={refused} frame={frame}" }

/-- The wiring checks of the grammars the package ships from source, in
order: what the set's build staged, that every grammar registers and its
queries compile, then the grammars drawn: yaml, rust, markdown with
markdown_inline injected, python, and markdown with python injected. -/
def realChecks (context : Context) : List Check :=
  [stagedCheck, registeredCheck context, drawnCheck context, rustDrawnCheck context,
    markdownInlineDrawnCheck context, pythonDrawnCheck context, pythonFenceDrawnCheck context]

end LanguagesTest.Linked
