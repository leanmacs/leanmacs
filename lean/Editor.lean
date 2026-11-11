import Editor.Command.Append
import Editor.Text.Model

/-!
# The editor

The root module user config imports: the editor's ports, the commands written
over them, and the pure models that tests and theorems run them against.

It never imports `Editor.Ffi` or a port's real binding (`Editor/Text/Real.lean`).
Those reach the Rust library, and only an executable linked with it imports
them, to run a command for real.
-/
