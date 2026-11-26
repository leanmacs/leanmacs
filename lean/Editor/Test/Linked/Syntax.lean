import Editor.Command
import Editor.Command.Real
import Editor.Display.Recorder
import Editor.Ffi.Events
import Editor.Ffi.Snapshot
import Editor.Ffi.Syntax
import Editor.Highlight
import Editor.InferredWait
import Editor.RealHost
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Text
import Editor.Text.Real

/-!
# The linked test kit: Syntax

The real syntax tree binding as a check of a package's reads it, with no
host: the capture names of a query the library ships
(`shippedCaptureNames`), and a text of a source whose tree the binding
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

/-- The mark of `shippedCaptureNames`: it runs a real background service (`Editor/RealHost.lean`). -/
def shippedCaptureNames.realHost : RealHost :=
  .service

/-- The capture names of the query of `kind` the library ships for
`grammar`; none when it ships none or the query does not compile. -/
def shippedCaptureNames (grammar : String) (kind : QueryKind) : IO (Option (Array String)) := do
  let table ← Snapshots.new
  let real ← RealSyntaxTree.new table.reader
  let program : SyntaxTreeM (Array String) := do
    let query ← SyntaxTree.compile grammar (← SyntaxTree.shippedQuery grammar kind)
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

/-- A text of `source`, parsed with the grammar `grammar` and drawn by the
shipped default (`Highlight.enter`), over the real bindings; none when the
text was not made. -/
def SyntaxText.over (source grammar : String) : IO (Option SyntaxText) := do
  let table ← Snapshots.new
  let texts ← IO.mkRef (RealTexts.over table)
  let made : SyntaxText := { table, texts, text := ⟨0⟩ }
  let some text ←
    made.run fun _ => do
        let text ← createText source
        Highlight.enter grammar text { grammar }
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
