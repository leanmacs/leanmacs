import Editor.Command.Append
import Editor.Event
import Editor.Setup
import Editor.UndoTree

/-!
# The editor

The root module user config imports: the editor's ports, the commands written
over them, the pure models that tests and theorems run them against, the undo
tree over the text port (`Editor/UndoTree.lean`), the events the editor queue
delivers, as plain data (`Editor/Event.lean`), and what config registers
with (`setup` and stores, `Editor/Setup.lean`). The job port
(`Editor/Job.lean`) comes with `Editor/Setup.lean`, which registers jobs,
and with the job port the file requests a job makes (`Editor/File.lean`):
config loads and saves files with `File.load` and `File.save`.

It never imports `Editor.Ffi` or a port's real binding (`Editor/Text/Real.lean`).
Those reach the Rust library, and only an executable linked with it imports
them, to run a command for real. So config, which sees this module and what
it imports, cannot name a binding.

It does not import the config session either (`Editor/Config/`): that is the
editor's side of a reload, and config has no use for it.
-/
