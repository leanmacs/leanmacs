import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import Editor.Ffi.Syntax
import Editor.Scene
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Text
import Editor.Text.Real

/-!
# Contract tests: support: Syntax

The real syntax tree binding: a handler that settles after an attach, and the
binding over documents of texts. Shared by several test modules; it holds no
checks of its own.
-/

namespace ContractTest

open Editor

-- inferred-waits W90: stays (the syntax adapter's contract support: its subject is the real binding's deliveries)
set_option linter.inferredWait false in
/-- `handler`, a real syntax tree binding's over `table`, which after an
attach waits, with a bound, for the attached text's tree to be delivered:
so a highlighter set after the attach sees no delivery of that parse, and
no `parsed` event of it is left on the editor queue, which the watch checks
pull after these. A delivery a check makes after a highlight, by an edit,
leaves one, which the check pulls (`pulledParsed`). -/
def settlingAttach (table : Snapshots) (handler : SyntaxTreeHandler) : SyntaxTreeHandler :=
  fun request => do
  let reply ← handler request
  if let .attach snapshot _ := request then
    if let some found← table.find? snapshot then
      discard (Ffi.syntaxSettle found Ffi.treeGuard)
  return reply

-- inferred-waits W90: stays (the syntax adapter's contract support: its subject is the real binding's deliveries)
set_option linter.inferredWait false in
/-- `handler`, a real syntax tree binding's over `table`, which waits, with
a bound, for a snapshot's tree to be delivered before it forwards a question
of its captures or of a kept query's, and after an attach
(`settlingAttach`). -/
def settling (table : Snapshots) (handler : SyntaxTreeHandler) : SyntaxTreeHandler :=
  settlingAttach table fun request => do
    let asked :=
      match request with
      | .captures snapshot _ _ _ => some snapshot
      | .capturesOf snapshot _ _ _ => some snapshot
      | _ => none
    if let some snapshot := asked then
      if let some found← table.find? snapshot then
        discard (Ffi.syntaxSettle found Ffi.treeGuard)
    handler request

/-- Documents of `texts` in the library, a table of a snapshot of each, the
ids of those snapshots in the order of `texts`, and a real syntax tree
binding over the table whose handler waits, with a bound, for a snapshot's
tree to be delivered before it forwards a question of its captures or of a
kept query's, and after an attach (`settlingAttach`). The
documents are returned so that the caller keeps them alive: a document
freed detaches its text. -/
def syntaxTreeOver (texts : Array String) :
    IO (Array Ffi.Document × Snapshots × Array SnapshotId × SyntaxTreeHandler) := do
  let table ← Snapshots.new
  let documents ← texts.mapM Ffi.Document.new
  let ids ←
    documents.mapM fun document => do
        table.add (← document.snapshot)
  let real ← RealSyntaxTree.new table.reader
  return (documents, table, ids, settling table real.handle)

end ContractTest
