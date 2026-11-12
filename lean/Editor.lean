import Editor.Command.Append
import Editor.Setup

/-!
# The editor

The root module user config imports: the editor's ports, the commands written
over them, the pure models that tests and theorems run them against, and what
config registers with (`setup` and stores, `Editor/Setup.lean`). The job port
(`Editor/Job.lean`) comes with `Editor/Setup.lean`, which registers jobs.

It never imports `Editor.Ffi` or a port's real binding (`Editor/Text/Real.lean`).
Those reach the Rust library, and only an executable linked with it imports
them, to run a command for real. So config, which sees this module and what
it imports, cannot name a binding.

It does not import the config session either (`Editor/Config/`): that is the
editor's side of a reload, and config has no use for it.
-/
