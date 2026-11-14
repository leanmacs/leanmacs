import Editor.Command
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
dispatched it is never interrupted. This module adds no decision: each
request is passed to its sub-port's handler as it is.
-/

namespace Editor

/-- Answers `request` with its sub-port's handler: the text binding over the
table of texts, `display`, or `watch`. -/
def EditorRequest.handleReal (display : DisplayHandler) (watch : WatchHandler := Watch.idle) :
    (request : EditorRequest) → StateT RealTexts IO request.Reply
  | .text request => RealTexts.handle request
  | .display request => StateT.lift (display request)
  | .watch request => StateT.lift (watch request)

/-- Runs a command against the Rust library, with `texts` as the texts made
so far, `display` answering its display requests and `watch` its watch
requests: its result, or the refusal it failed with, and the table after
its last request.

`arrived` is what the run is handed, as `TextM.runReal` has it: the
snapshots a job held when it ended, for the run of that job's command, and
nothing for any other command. The table that comes back holds none of it
but what the command adopted. -/
def EditorM.runReal {α : Type} (command : EditorM α) (texts : RealTexts) (display : DisplayHandler)
    (arrived : Array (JobSnapshotId × Ffi.Snapshot) := #[]) (watch : WatchHandler := Watch.idle) :
    IO (Except TextError α × RealTexts) := do
  let (result, texts) ←
    (Program.runM (port := editorPort) (EditorRequest.handleReal display watch) command.run).run
        { texts with arrived }
  return (result, { texts with arrived := #[] })

end Editor
