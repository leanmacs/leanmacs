import Editor.Command
import Editor.Fuzzy.Real
import Editor.Text.Real

/-!
# Running a command for real

A command (`Editor/Command.lean`) against the Rust library: its text
requests go to the text port's real binding (`RealTexts.handle`), and its
display requests to the display handler the caller hands in, which is the
recorder in a host with no window (`Editor/Display/Recorder.lean`) and the
display pipeline's binding in one with a window. Its watch requests go to
the watch handler the caller hands in: the real binding
(`Editor/Watch/Real.lean`) where a loop dispatches commands, and by default
the one that watches nothing (`Watch.idle`), so a command run where no loop
dispatched it is never interrupted. Its clipboard requests go to the
clipboard handler the caller hands in, and by default to the one that
answers `unavailable` (`Clipboard.unavailable`): a host that was handed no
clipboard has none, and a command is told so, as a value. Its fuzzy requests
go to the fuzzy port's real binding (`Fuzzy.real`,
`Editor/Fuzzy/Real.lean`), as its text requests go to the text's: the
matcher keeps nothing and needs nothing a host could hand in, so no caller
passes a handler for it. Its syntax tree requests go to the syntax tree
handler the caller hands in, and by default to the one with no grammars
(`SyntaxTree.none`): a host hands in its binding over the library's syntax
service (`Editor/SyntaxTree/Real.lean`), made once over the table of
snapshots its loop's commands take theirs in. This module adds
no decision: each request is passed to its sub-port's handler as it is.

A state request is the loop's to answer (`Editor/Command.lean`, "The state
requests are the loop's to answer"), and a command the loop runs has none
left when it reaches this runner. One that does reach it is answered as the
models answer it: as an editor with no buffer and no window would
(`EditorState.none`), with nothing kept and no call into the library.
-/

namespace Editor

/-- Answers `request` with its sub-port's handler: the text binding over the
table of texts, `display`, `watch`, `clipboard`, the fuzzy port's real
binding, or `syntaxTree`. A state request is answered from an editor with nothing in it, and
changes nothing. -/
def EditorRequest.handleReal (display : DisplayHandler) (watch : WatchHandler := Watch.idle)
    (clipboard : ClipboardHandler := Clipboard.unavailable)
    (syntaxTree : SyntaxTreeHandler := SyntaxTree.none) :
    (request : EditorRequest) → StateT RealTexts IO request.Reply
  | .text request => RealTexts.handle request
  | .display request => StateT.lift (display request)
  | .watch request => StateT.lift (watch request)
  | .clipboard request => StateT.lift (clipboard request)
  | .fuzzy request => StateT.lift (Fuzzy.real request)
  | .syntaxTree request => StateT.lift (syntaxTree request)
  | .state request => pure (EditorState.none.handle request).1
  | .registry request => pure request.bare

/-- Runs a command against the Rust library, with `texts` as the texts made
so far, `display` answering its display requests, `watch` its watch
requests and `clipboard` its clipboard requests: its result, or the refusal
it failed with, and the table after its last request.

`arrived` is what the run is handed, as `TextM.runReal` has it: the
snapshots a job held when it ended, for the run of that job's command, and
nothing for any other command. The table that comes back holds none of it
but what the command adopted. -/
def EditorM.runReal {α : Type} (command : EditorM α) (texts : RealTexts) (display : DisplayHandler)
    (arrived : Array (JobSnapshotId × Ffi.Snapshot) := #[]) (watch : WatchHandler := Watch.idle)
    (clipboard : ClipboardHandler := Clipboard.unavailable)
    (syntaxTree : SyntaxTreeHandler := SyntaxTree.none) : IO (Except TextError α × RealTexts) := do
  let (result, texts) ←
    (Program.runM (port := editorPort) (EditorRequest.handleReal display watch clipboard syntaxTree)
            command.run).run
        { texts with arrived }
  return (result, { texts with arrived := #[] })

end Editor
