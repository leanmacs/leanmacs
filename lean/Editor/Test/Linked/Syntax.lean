import Editor.Command
import Editor.Command.Real
import Editor.Display.Recorder
import Editor.Ffi.Events
import Editor.Ffi.Snapshot
import Editor.Ffi.Syntax
import Editor.Highlight
import Editor.InferredWait
import Editor.Job
import Editor.Language.Grammar
import Editor.Mode
import Editor.Package
import Editor.RealHost
import Editor.Setup
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.SyntaxTree.Registration.Model
import Editor.Test.Linked.Jobs
import Editor.Text
import Editor.Text.Real

/-!
# The linked test kit: Syntax

The grammars the core's tests load (`TestGrammars`): the directory
`editor-syntax-fixture-grammars` builds, which a test program is handed as
an argument, laid out as a package's staged `grammars/` (each grammar's
library, and its queries under `queries/<name>/`). The library compiles in
no grammar, so a check that draws with a real
grammar registers it from here first: a host's check hands the host their
declarations (`TestGrammars.package`), which the core's `register-grammars`
job registers, and a check with no host registers them itself
(`registerTestGrammars`). Either way its trees come from the directory
(`TestGrammars.over`, `TestGrammars.injected`), never from a query the
library ships.

The real syntax tree binding as a check of a package's reads it, with no
host: the capture names of a query of the directory's
(`testQueryCaptureNames`), and a text of a source whose tree the binding
keeps, over which a check runs commands of the editor's API
(`SyntaxText`), each question of the tree waiting, with a bound, for the
tree of the text's last edit. And the syntax fixtures as the indent checks
read them: the rows of the Rust indent fixture the rule keeps
(`indentKept`) and a text with its indentation mangled (`mangledRust`).
And a real binding's handler that settles after an attach
(`settlingAttach`) and the editor queue drained of the library's reports of
parses (`drainedParsed`), which a check that draws a highlighted text on
the real display waits and drains with: the core's contract checks and a
package's grammar check (`Editor.Test.Linked.Grammar`). It holds no checks
of its own.

Published for a package's linked tests, in the namespace
`Editor.Test.Linked`, as the rest of the linked kit is. The core's own
checks of the binding (`contract-test`) are written on its support
(`ContractTest/Support/Syntax.lean`) and on the two helpers here.
-/

namespace Editor.Test.Linked

open Editor

/-- The directory of the grammars the core's tests load, built by cargo
(`crates/editor-syntax-fixture-grammars`), absolute: a test program is
handed it as an argument. -/
structure TestGrammars where
  /-- The directory: each grammar's library, `libtree-sitter-<name>.dylib`
  on macOS and `.so` elsewhere, and its queries under `queries/<name>/`. -/
  directory : System.FilePath

namespace TestGrammars

/-- The grammars the directory holds, each with its policy, in the
adapter's table's order (`GrammarRegistry.testGrammarNames`, which the
model kits register too). -/
def names : Array (String × ReparsePolicy) :=
  GrammarRegistry.testGrammarNames

/-- The library of the grammar `name` in the directory. -/
def library (grammars : TestGrammars) (name : String) : System.FilePath :=
  grammars.directory / s!"libtree-sitter-{name}.{if System.Platform.isOSX then "dylib" else "so"}"

/-- The query directory of the grammar `name`. -/
def queries (grammars : TestGrammars) (name : String) : System.FilePath :=
  grammars.directory / "queries" / name

/-- The policy the grammar `name` is registered with, if the directory
holds it. -/
def policy (name : String) : Option ReparsePolicy :=
  (names.find? (·.1 == name)).map (·.2)

/-- The declaration of each grammar of the directory, as a package's
grammar is declared: its library, its query directory and its policy. -/
def declarations (grammars : TestGrammars) : Array Language.Grammar :=
  names.map fun (name, policy) =>
    Language.Grammar.declare name (grammars.library name) (queries := grammars.queries name)
      (policy := some policy)

/-- A package that declares each grammar of the directory
(`declarations`): what a host's check hands its host, whose
`register-grammars` job then registers them at the first install. -/
def package (grammars : TestGrammars) : Package :=
  { name := "test-grammars"
    setup :=
      grammars.declarations.forM fun grammar =>
        defineGrammar grammar.name ((grammar.libraryOn "").getD "") (queries := grammar.queries)
          (policy := grammar.policy) }

/-- The source of each grammar of the directory, as a registration takes
it. -/
def sources (grammars : TestGrammars) : Array GrammarSource :=
  names.map fun (name, policy) =>
    { library := (grammars.library name).toString, symbol := s!"tree_sitter_{name}"
      policy := some policy }

/-- The queries of the grammar `name`, read from its query directory: a
source for each kind whose file is there. -/
def queriesOf (grammars : TestGrammars) (name : String) : IO Language.Grammar.Queries := do
  let mut read : Language.Grammar.Queries := {}
  for (file, kind) in Language.Grammar.queryFiles do
    let path := grammars.queries name / file
    if ← path.pathExists then
      read := read.set kind (some (← IO.FS.readFile path))
  return read

/-- `tree` with the queries of its grammar read from the directory filled in
where it gives no source of its own, as the core's command resolves a
declared grammar's tree (`Language.Grammar.treeOf`). -/
def over (grammars : TestGrammars) (tree : Mode.SyntaxTree) : IO Mode.SyntaxTree :=
  return (← grammars.queriesOf tree.grammar).over tree

/-- The bare tree of the grammar `name`, its queries read from the
directory. -/
def tree (grammars : TestGrammars) (name : String) : IO Mode.SyntaxTree :=
  grammars.over { grammar := name }

/-- What `Highlight.enter` is handed as its `injected`: the tree of each
grammar of the directory, its queries read from it, for the grammar of
that name; the bare tree of any other. -/
def injected (grammars : TestGrammars) : IO (String → Option Mode.SyntaxTree) := do
  let trees ← names.mapM fun (name, _) => grammars.tree name
  return fun name => some ((trees.find? (·.grammar == name)).getD { grammar := name })

/-- The Lean source of `tree`, its grammar and each query it holds, as a
config file names a mode's own tree: for a config of a check's that defines
a mode drawn with a test grammar, whose own tree no declaration fills in
(`Language.Grammar.treeOf` resolves a language's tree alone). Its captures
are left out. -/
def treeSource (tree : Mode.SyntaxTree) : String :=
  let field (name : String) : Option String → Option String
    | some source => some s!"{name} := some {source.quote}"
    | none => none
  let fields :=
    [some s!"grammar := {tree.grammar.quote}", field "highlights" tree.highlights,
          field "injections" tree.injections, field "textObjects" tree.textObjects,
          field "indents" tree.indents, field "rendered" tree.rendered,
          field "renderedInjections" tree.renderedInjections].filterMap
      id
  "{ " ++ ", ".intercalate fields ++ " }"

end TestGrammars

/-- The mark of `registerTestGrammars`: it runs a real background service
(`Editor/RealHost.lean`). -/
def registerTestGrammars.realHost : RealHost :=
  .service

/-- Registers each grammar of `grammars`' directory on the library's syntax
service, in turn, through the library's grammar registrations
(`Grammar.register`) in a job on `services`, and waits for the job's end,
by which every registration is answered and taken: for a check with no
host, which then draws with a grammar registered from there. `.ok`
once every one registered under its name. Otherwise why, for the first that
did not: its library, its symbol and the refusal, or the name it registered
under in place of its own; or why the job did not finish. -/
def registerTestGrammars (grammars : TestGrammars) (services : Job.Services) :
    IO (Except String Unit) := do
  let job : JobM String := do
    for source in grammars.sources do
      match ← Grammar.register source with
      | .ok name =>
        if name != source.name then
          return s!"{source.library} ({source.symbol}): registered as {name}, not {source.name}"
      | .error error =>
        return s!"{source.library} ({source.symbol}): {error.describe}"
    return ""
  let handle ← Job.spawn services (reporting fun _ => job) (pure ())
  if (← Job.awaitWithin patience handle.outcome.result?).isNone then
    handle.cancel
    return .error s!"a hang: the registration job had not ended within {patience.ms} ms"
  handle.settle
  match (← handle.outcome?).map texts with
  | some (.finished #[""]) =>
    return .ok ()
  | some (.finished said) =>
    return .error (" ".intercalate said.toList)
  | some (.failed message) =>
    return .error message
  | _ =>
    return .error "the registration job was cancelled"

/-- The mark of `testQueryCaptureNames`: it runs a real background service (`Editor/RealHost.lean`). -/
def testQueryCaptureNames.realHost : RealHost :=
  .service

/-- The capture names of the query of `kind` in the directory of `grammars`
for `grammar`, compiled by the library, on which `grammar` is registered;
none when the directory holds none or the query does not compile. -/
def testQueryCaptureNames (grammars : TestGrammars) (grammar : String) (kind : QueryKind) :
    IO (Option (Array String)) := do
  let queries ← grammars.queriesOf grammar
  let source? :=
    match kind with
    | .highlights => queries.highlights
    | .injections => queries.injections
    | .textObjects => queries.textObjects
    | .indents => queries.indents
    | .rendered => queries.rendered
    | .renderedInjections => queries.renderedInjections
  let some source := source? | return none
  let table ← Snapshots.new
  let real ← RealSyntaxTree.new table.reader
  let program : SyntaxTreeM (Array String) := do
    let query ← SyntaxTree.compile grammar source
    SyntaxTree.captureNames query
  return (← program.runWith real.handle).toOption

/-- A text over the real text binding whose tree the real syntax tree
binding keeps: the table of its snapshots, the texts made so far, and the
text. -/
structure SyntaxText where
  /-- The table of snapshots the bindings read. -/
  table : Snapshots
  /-- The texts made so far, as the last run left them. -/
  texts : IO.Ref RealTexts
  /-- The text. -/
  text : TextId

/-- `SyntaxText.run` is an inferred wait (`Editor/InferredWait.lean`): it
hands on `Ffi.syntaxSettle`, the real syntax service's readout, so a check
that runs a program over the real binding says why with an allow. -/
def SyntaxText.run.inferredWait : InferredWait :=
  .realEffect []

/-- The mark of `SyntaxText.run`: it runs a real background service (`Editor/RealHost.lean`). -/
def SyntaxText.run.realHost : RealHost :=
  .service

/-- Runs `program` over the texts of `held`, with a display recorder over
its table and the real syntax tree binding, which waits, with a bound, for
a snapshot's tree to be delivered before it forwards a question of its
captures or of a kept query's, and after an attach; keeps the texts the run
left. None when the run was refused. -/
def SyntaxText.run {α : Type} (held : SyntaxText) (program : TextId → EditorM α) : IO (Option α) :=
  do
  let real ← RealSyntaxTree.new held.table.reader
  let settling : SyntaxTreeHandler := fun request => do
    let asked :=
      match request with
      | .captures snapshot _ _ _ => some snapshot
      | .capturesOf snapshot _ _ _ => some snapshot
      | _ => none
    if let some snapshot := asked then
      if let some found← held.table.find? snapshot then
        discard (Ffi.syntaxSettle found Ffi.treeGuard)
    let reply ← real.handle request
    if let .attach snapshot _ := request then
      if let some found← held.table.find? snapshot then
        discard (Ffi.syntaxSettle found Ffi.treeGuard)
    return reply
  let recorder ← DisplayRecorder.new { advance := 1, lineHeight := 1 } held.table.reader
  let (answer, texts) ←
    (program held.text).runReal (← held.texts.get) recorder.handle (syntaxTree := settling)
  held.texts.set texts
  return answer.toOption

/-- `SyntaxText.over` is an inferred wait (`Editor/InferredWait.lean`): it
runs `SyntaxText.run`, over the real syntax service. -/
def SyntaxText.over.inferredWait : InferredWait :=
  .realEffect []

/-- The mark of `SyntaxText.over`: it runs a real background service (`Editor/RealHost.lean`). -/
def SyntaxText.over.realHost : RealHost :=
  .service

/-- A text of `source`, parsed with the grammar `grammar` of `grammars`'
directory, registered on the library, and drawn with its queries read from
there (`TestGrammars.tree`, `TestGrammars.injected`) by the shipped default
(`Highlight.enter`), over the real bindings; none when the text was not
made. -/
def SyntaxText.over (grammars : TestGrammars) (source grammar : String) : IO (Option SyntaxText) :=
  do
  let table ← Snapshots.new
  let texts ← IO.mkRef (RealTexts.over table)
  let made : SyntaxText := { table, texts, text := ⟨0⟩ }
  let tree ← grammars.tree grammar
  let injected ← grammars.injected
  let some text ←
    made.run fun _ => do
        let text ← createText source
        Highlight.enter grammar text tree injected
        return text | return none
  return some { made with text }

/-- `settlingAttach` is an inferred wait (`Editor/InferredWait.lean`): it
hands on `Ffi.syntaxSettle`, the real syntax service's readout. Allowed in
the real binding's adapter's contract checks (the mirror of
`Editor.SyntaxTree.Real`) and in the kit's grammar check
(`Editor.Test.Linked.Grammar`); anywhere else under an allow. -/
def settlingAttach.inferredWait : InferredWait :=
  .realEffect [`Editor.SyntaxTree.Real, `Editor.Test.Linked.Grammar]

/-- `handler`, a real syntax tree binding's over `table`, which after an
attach waits, with a bound, for the attached text's tree to be delivered:
so a highlighter set after the attach sees no delivery of that parse, and
no `parsed` event of it is left on the editor queue, which the watch checks
pull after these. A delivery a check makes after a highlight, by an edit,
leaves one, which the check pulls. -/
def settlingAttach (table : Snapshots) (handler : SyntaxTreeHandler) : SyntaxTreeHandler :=
  fun request => do
  let reply ← handler request
  if let .attach snapshot _ := request then
    if let some found← table.find? snapshot then
      discard (Ffi.syntaxSettle found Ffi.treeGuard)
  return reply

/-- The mark of `drainedParsed`: it reads the library's editor queue, a
real background service's (`Editor/RealHost.lean`). -/
def drainedParsed.realHost : RealHost :=
  .service

/-- How many events the editor queue held, each pulled: what a mode set over
a highlighted text leaves once its tree and its layers are delivered, the
library's reports of parses. It never parks a pull on an empty queue. -/
def drainedParsed : IO Nat := do
  let mut pulled := 0
  while (← Ffi.queued .editor) > 0 do
    discard (Ffi.takeQueued .editor)
    pulled := pulled + 1
  return pulled

/-- The rows of the Rust indent fixture (`tests/syntax/rust/indent.rs`) inside
its multi-line string and block comment, which the indent rule keeps: found
by their content, never by their number. -/
def indentKept : List String :=
  ["not indented by the rule\";", "       comment */"]

/-- `source` with the indentation of its rows mangled: a row of `kept`, and
the last, empty after the final line feed, stays as it is; a blank row
becomes three spaces; any other row loses its leading blanks and gains, by
its number, nothing, two spaces, a tab or six spaces. Made in code from the
fixture, so no second fixture can drift from it. -/
def mangledRust (source : String) (kept : List String) : String :=
  let lines := source.splitOn "\n"
  "\n".intercalate <|
    lines.zipIdx.map fun (line, row) =>
      if kept.contains line || row + 1 == lines.length then line
      else
        let content := (line.dropWhile fun char => char == ' ' || char == '\t').toString
        if content.isEmpty then "   " else ["", "  ", "\t", "      "].getD (row % 4) "" ++ content

end Editor.Test.Linked
