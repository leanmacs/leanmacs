import Editor.Api.Theorems
import Editor.Command.Append
import Editor.Evil.Operators
import Editor.Evil.Theorems
import Editor.Evil.Undo
import Editor.Ex
import Editor.InputScheme.Vim.Default
import Editor.Minibuffer
import Editor.Setup

/-!
# The editor

The root module user config imports: the editor's ports, the commands written
over them, the pure models that tests and theorems run them against, the
editor's composite port, of which a command is a program and whose
sub-ports' operations are lifted into it (`Editor/Command.lean`, which
comes with `Editor/Setup.lean` through the stores), the editor API a
command is written with (`Editor/Api.lean`: the editor state's buffers and
windows, undo, modes, messages, jobs and prompts, over the state requests of
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
session's, and are not imported. A command of config's asks for a string
with `prompt` (`Editor/Api.lean`), and the commands that accept and cancel
a prompt and the minibuffer's mode are here as well
(`Editor/Minibuffer.lean`); their registrations
(`Editor/Minibuffer/Compiled.lean`) are not, for the same reason. The ex
command line is here too (`Editor/Ex.lean`, with an ex line as data in
`Editor/Ex/Line.lean`): a command of config's runs a line with `Ex.run`,
and `setup` binds an ex name to a command with `exCommand`
(`Editor/Setup.lean`). The registrations of the ex line's commands and the
ex names that ship (`Editor/Ex/Compiled.lean`) are not imported. The file
commands come with `Editor/Ex.lean`, whose save-and-quit command calls
`Files.save`.

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

What the Vim scheme's invocations run is here as well: evil, Vim's states,
motions and commands written on the editor API, so a command of config's
can call them. The commands are in `Editor/Evil.lean`, and the motions and
their table, `Evil.motions`, in `Editor/Evil/Motions.lean`: the move
command is a function of the table it looks a name up in, so a command of
config's hands it the vocabulary that ships, or that vocabulary with
motions of its own added (`Evil.move (Evil.motions.push mine)`). The
operators are here too (`Editor/Evil/Operators.lean`, with the registers
they set in `Editor/Evil/Registers.lean`): the operate command is a
function of the operators and the motions it looks names up in
(`Evil.operate Evil.operators Evil.motions`). That module brings the
commands and the motions with it. Undo and redo, which place the cursor a
step of the history hands back, are in `Editor/Evil/Undo.lean`. What is
proved of evil on the text model is in `Editor/Evil/Theorems.lean`, with
what it needs of the undo tree in `Editor/UndoTree/Theorems.lean`; they
are imported so that the build checks the proofs.
The
commands' registrations (`Editor/Evil/Compiled.lean`) name the registry
and are not imported, as the file commands' and the minibuffer's are not.
Pinned by `ConfigTest.evilChecks`, on a config the real elaborator loads.

It never imports `Editor.Ffi` or a port's real binding (`Editor/Text/Real.lean`).
Those reach the Rust library, and only an executable linked with it imports
them, to run a command for real. So config, which sees this module and what
it imports, cannot name a binding.

It does not import the config session either (`Editor/Config/`): that is the
editor's side of a reload, and config has no use for it.
-/
