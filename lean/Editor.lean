import Editor.Api.Theorems
import Editor.Command.Append
import Editor.Files
import Editor.InputScheme.Vim.Default
import Editor.Setup

/-!
# The editor

The root module user config imports: the editor's ports, the commands written
over them, the pure models that tests and theorems run them against, the
editor's composite port, of which a command is a program and whose
sub-ports' operations are lifted into it (`Editor/Command.lean`, which
comes with `Editor/Setup.lean` through the stores), the editor API a
command is written with (`Editor/Api.lean`: the editor state's buffers and
windows, undo, modes, messages and jobs, over the state requests of
`Editor/State/Request.lean`; it comes with `Editor/Api/Theorems.lean`,
which holds what is proved of it on the text model, so that the build
checks those proofs), the undo
tree over the text port (`Editor/UndoTree.lean`, which comes with the
editor state a buffer's history is part of), the events the editor queue
delivers, as plain data (`Editor/Event.lean`), the scene Lean publishes to
the display (`Editor/Scene.lean`) and the display interface it is published
through (`Editor/Display.lean`), and what config registers
with (`setup` and stores, `Editor/Setup.lean`). The job port
(`Editor/Job.lean`) comes with `Editor/Setup.lean`, which registers jobs,
and with the job port the file requests a job makes (`Editor/File.lean`):
config loads and saves files with `File.load` and `File.save`. The file
commands are here too (`Editor/Files.lean`): a command of config's opens a
file into a buffer with `Files.open`, which starts the job that loads it,
and saves a buffer to its file with `Files.save`, which starts the job that
writes it. Their registrations as compiled commands and jobs
(`Editor/Files/Compiled.lean`) name the registry, which is the config
session's, and are not imported.

How a key becomes an invocation is here too, so config can come to write
bindings: input schemes (`Editor/InputScheme.lean`), with the keymaps they
walk (`Editor/Keymap.lean`) and the invocations they yield
(`Editor/Invocation.lean`), and key strings (`Editor/Key/Notation.lean`),
with which a binding's keys are written (`Key.parse "C-x C-s"`). The Vim
scheme is the scheme that ships (`Editor/InputScheme/Vim.lean`, with its
default states and bindings in `Editor/InputScheme/Vim/Default.lean`), and
config will bind against its parts of speech (`Vim.Bound`). That module
is the one import here that brings all of these, the scheme interface and
key strings with it. Modes come with `Editor/Setup.lean`, which defines
them (`defineMode`): the mode record (`Editor/Mode.lean`) and the roles a
mode fills (`Editor/Role.lean`). The test
scheme and the scheme contract (`Editor/InputScheme/Test.lean`,
`Editor/InputScheme/Contract.lean`) are for tests, and are not imported.

It never imports `Editor.Ffi` or a port's real binding (`Editor/Text/Real.lean`).
Those reach the Rust library, and only an executable linked with it imports
them, to run a command for real. So config, which sees this module and what
it imports, cannot name a binding.

It does not import the config session either (`Editor/Config/`): that is the
editor's side of a reload, and config has no use for it.
-/
