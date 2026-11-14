import Editor.Clipboard.Model

/-!
# The clipboard where there is no window

A host with no window has no window system, and so no system clipboard. It
keeps a clipboard of its own: a cell of the process that holds a text, or
none, and answers each request with the clipboard model's rule
(`Editor/Clipboard/Model.lean`), in `IO` (`Clipboard.InProcess.handle`, a
`ClipboardHandler`). So what one command writes the next one reads, in the
same process and nowhere else: no other program sees it, and it is gone
with the process.

It is the display recorder's twin (`Editor/Display/Recorder.lean`): the one
place the model's rule runs outside a test. An editor with a window is
handed the binding to the system's clipboard, which is the display
pipeline's.

It is always there: the model's switch that takes a clipboard away
(`ClipboardModel.available`) is a test's, and nothing here turns it.

`contract-test` holds it to the clipboard interface's contract
(`Editor/Clipboard/Contract.lean`), and `ContractTest.clipboardChecks` pins
what the contract cannot.
-/

namespace Editor.Clipboard

/-- The clipboard of a host with no window: a cell of the process that
holds what the clipboard model holds. -/
structure InProcess where
  /-- The model, as it is after the last request. -/
  cell : IO.Ref ClipboardModel

namespace InProcess

/-- A clipboard that holds no text. -/
def new : BaseIO InProcess :=
  return { cell := ← IO.mkRef {} }

/-- Answers `request` with the model's rule: a read answers what is held,
and a write replaces it. -/
def handle (clipboard : InProcess) : ClipboardHandler := fun request =>
  clipboard.cell.modifyGet (ClipboardModel.handle request)

/-- The text the clipboard holds, if it holds one. -/
def held? (clipboard : InProcess) : BaseIO (Option String) :=
  return (← clipboard.cell.get).held

end InProcess

end Editor.Clipboard
