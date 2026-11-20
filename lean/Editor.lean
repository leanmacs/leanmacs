import Editor.Api.Theorems
import Editor.AtPoint
import Editor.BindingSearch
import Editor.Command.Append
import Editor.Completion.Filtering
import Editor.Completion.Words
import Editor.Evil.Clipboard
import Editor.Evil.Jumps
import Editor.Evil.Operators
import Editor.Evil.Repeat
import Editor.Evil.Scroll
import Editor.Evil.Theorems
import Editor.Evil.TreeObjects
import Editor.Evil.Undo
import Editor.ExecuteCommand
import Editor.Extension
import Editor.FrameCommands
import Editor.InputScheme.Vim.Default
import Editor.Minibuffer
import Editor.TabCommands
import Editor.Themes
import Editor.VersionControl.Commit
import Editor.VersionControl.Stage

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
with (`setup` and stores, `Editor/Setup.lean`). The display rules
(`Editor/DisplayRules.lean`) come with `Editor/Setup.lean`, which adds one
with `displayRule`, and with the editor state: a command of config's shows
a buffer it made where they say with `BufferId.display`. The job port
(`Editor/Job.lean`) comes with `Editor/Setup.lean`, which registers jobs,
and with the job port the file requests a job makes (`Editor/File.lean`):
config loads and saves files with `File.load` and `File.save`, and the
process requests (`Editor/Process.lean`): a job of config's runs a program
with `Process.run`. Faces come
with `Editor/Setup.lean` too (`Editor/Face.lean`): config sets one with
`face`. The file
commands are here too (`Editor/Files.lean`): a command of config's opens a
file into a buffer with `Files.open`, which starts the job that loads it,
and saves a buffer to its file with `Files.save`, which starts the job that
writes it. Their registrations as compiled commands and jobs
(`Editor/Files/Compiled.lean`) name the registry, which is the config
session's, and are not imported. A command of config's asks for a string
with `prompt` (`Editor/Api.lean`), with candidates the answer may be
chosen from when it gives completion sources that answer them
(`prompt … (sources := [.given source, .named "name"])`,
`Editor/Completion.lean`), or every source of a category
(`.category "buffer" defaults`); a source is registered by name with
`defineSource` (`Editor/Setup.lean`). A source that answers later, from a
job, is `.answeringLater name category job` (`Editor/Completion/Later.lean`),
and its job is registered with `sourceJob name answer`, which delivers
candidates in batches as they come. A source a command filters, a lister's
output fed to a filter such as fzf with the typed text as an argument, is
`Completion.Filtering.source`, its job's answer `Completion.Filtering.answer`
(`Editor/Completion/Filtering.lean`). Which candidates the typed text
matches is a completion style's (`Editor/Completion/Style.lean`): the
shipped ones, `fuzzy`, `orderless` and `path`, which matches a path's last
component, come with `Editor/Setup.lean` (`Editor/Completion/Styles.lean`),
and config registers one with `defineStyle` (`.keeping name keep` for one
written as a predicate) and chooses the default with `useStyle` and a
category's with `useStyleFor`. Compiled code may give a category a style
of its own, which `useStyleFor` overrides and `useStyle` does not reach:
the file prompt's category, `file`, is matched with `path`. `open-file`'s
prompt asks the sources of the category `file`, the shipped `files` source
by default (`Editor/Completion/Paths.lean`), so config adds to what it
lists by registering a source in that category. How the listing is drawn is a completion display's
(`Editor/Completion/Display.lean`): the shipped one, `minibuffer`, which
lists them one a row above the input, comes with `Editor/Setup.lean`
(`Editor/Completion/Displays.lean`), and config registers one with
`defineDisplay` (`defineDisplay (Completion.Displays.minibuffer (rows :=
15))` replaces the shipped one, which sets its rows) and chooses the
default with `useDisplay` and a category's with `useDisplayFor`. The
commands that accept and
cancel a prompt, move through its candidates and put one in the input
(`minibuffer-insert`), and the minibuffer's mode
are here as well
(`Editor/Minibuffer.lean`); their registrations
(`Editor/Minibuffer/Compiled.lean`) are not, for the same reason. The
fuzzy matcher is a sub-port of the editor's port, so a command of
config's asks which candidates a pattern matches with `Fuzzy.rank`
(`Editor/Fuzzy.lean`), as it asks a text. The ex
command line is here too (`Editor/Ex.lean`, with an ex line as data in
`Editor/Ex/Line.lean`): a command of config's runs a line with `Ex.run`,
handed the target it was called with, and `setup` binds an ex name to a command with `exCommand`
(`Editor/Setup.lean`). The registrations of the ex line's commands and the
ex names that ship (`Editor/Ex/Compiled.lean`) are not imported. The file
commands come with `Editor/Ex.lean`, whose save-and-quit command calls
`Files.save`. The buffer commands are here too (`Editor/Buffers.lean`):
`Buffers.switchCommand`, `Buffers.listCommand` and `Buffers.closeCommand`,
which switch a window to another buffer, list the open buffers and close
one; their registrations (`Editor/Buffers/Compiled.lean`) are not
imported. The frame's commands are here too
(`Editor/FrameCommands.lean`): `toggle-fullscreen` and `minimise-window`,
which ask the platform's window through the display; their registrations
and default bindings (`Editor/FrameCommands/Compiled.lean`) are not
imported. The window commands are here too (`Editor/WindowCommands.lean`):
`window-split`, `window-close`, `window-focus-left` and the rest, which
split, close, focus and arrange the frame's windows, so a config's command
can call them; their registrations (`Editor/WindowCommands/Compiled.lean`)
are not imported. So are the tab commands (`Editor/TabCommands.lean`):
`tab-new`, `tab-close`, `tab-next`, `tab-switch` and the rest; their
registrations (`Editor/TabCommands/Compiled.lean`) are not imported. The command that switches the theme in force is here too
(`Editor/Themes.lean`): `load-theme`, which a command of config's calls
with `Themes.loadThemeCommand`, over `themeNames` and `loadTheme`
(`Editor/Api.lean`); `setup` registers a theme with `defineTheme` and names
the one in force with `useTheme` (`Editor/Setup.lean`). Its registration
with the theme `default` (`Editor/Themes/Compiled.lean`) is not imported,
and the palettes that ship are a package outside the core
(`packages/shipped-themes/`), which config names by a theme's name alone. So is
the command prompt (`Editor/ExecuteCommand.lean`): `execute-command`, which
a command of config's calls with `ExecuteCommand.executeCommand`, over
`commandNames`; its registration (`Editor/ExecuteCommand/Compiled.lean`) is
not imported. So is the binding search (`Editor/BindingSearch.lean`):
`search-bindings`, which a command of config's calls with
`BindingSearch.searchBindings`, over `keyBindings`; its registration
(`Editor/BindingSearch/Compiled.lean`) is not imported.

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
function of the operators, the motions and the text objects it looks names
up in (`Evil.operate Evil.operators Evil.motions Evil.objects`), and the
text objects and their select command are in `Editor/Evil/Objects.lean`.
That module brings the commands, the motions and the text objects with
it. Undo and redo, which place the cursor a
step of the history hands back, are in `Editor/Evil/Undo.lean`, and dot
repeat, which replays the change the Vim scheme hands it with the command
the registry holds for the change's name, in `Editor/Evil/Repeat.lean`:
config's command of a name evil registers, such as `operate` registered
again over a vocabulary with an operator of config's own, is what `.`
replays. The commands that scroll a view are in `Editor/Evil/Scroll.lean`
(`Evil.scroll`), over the policy by which a view follows its cursor and a
scroll places its anchor (`Editor/Scroll.lean`, which comes with the
editor API): a command of config's reads and places its window's scroll
anchor with `Target.anchor` and `Target.scrollTo`, asks the display about
its view with `Target.onArea`, and sets the scroll margin with
`setScrollMargin` (`Editor/Api.lean`, "Scrolling"). The Edit menu's
clipboard commands, Cut, Copy, Paste and Select All, are in
`Editor/Evil/Clipboard.lean`. What is
proved of evil on the text model is in `Editor/Evil/Theorems.lean`, with
what it needs of the undo tree in `Editor/UndoTree/Theorems.lean`; they
are imported so that the build checks the proofs.
The
commands' registrations (`Editor/Evil/Compiled.lean`) name the registry
and are not imported, as the file commands' and the minibuffer's are not.
Pinned by `ConfigTest.evilChecks`, on a config the real elaborator loads.

The window layouts are here too, with the editor state that holds the
frame's (`Editor/Layout.lean`): master-and-stack and monocle, as values a
pure function lays a list of windows out by.

The syntax tree interface comes with the editor's port, of which it is a
sub-port (`Editor/SyntaxTree.lean`): which grammars the library has, which
text it parses with which grammar, off the editor thread, what a query
captures in a range of a text, and drawing a text with a query's captures
in faces. A major mode says how its text is parsed and drawn
(`Mode.SyntaxTree`), and setting it asks the port
(`Editor/Highlight.lean`, which comes with the loop's dispatch). Setting it
also keeps the mode's indents and text objects queries for its text: the
indent level of each row is `TextId.indentLevels` (`Editor/Indent.lean`),
the level of a line opened at a position `TextId.openingLevel`, and the
edits that re-indent rows `TextId.reindentEdits`: primitives config's and
evil's indent commands (`=`, `RET`, `o`, `O`) call, in a buffer's indent
unit (`Target.indentUnit`, `Editor/Language/IndentUnit.lean`); and the syntax tree's
text objects are entries of evil's vocabulary
(`Editor/Evil/TreeObjects.lean`). Its model and contract are for tests, and
are not imported.

Languages are here too (`Editor/Language.lean`, which comes with the file
commands and `Editor/Setup.lean`): a language as data, the languages that
ship (`Language.rust`, `Language.json`, `Language.markdown`), the rule that chooses a path's language, and the
`code` mode, whose text is parsed and drawn as its buffer's language
says. Opening a file records its language and puts the buffer in `code`;
`setup` adds a language, or overrides a shipped one by name, with
`defineLanguage` (`Editor/Setup.lean`).

Projects, workspaces and locations are here too (`Editor/Workspace.lean`):
which codebase and which checkout a buffer belongs to, as plain values,
and the finder that answers a directory's workspace through config, git
and marker files (`Editor/Workspace/Finder.lean`, `Workspace.find`), a job
like any other. A buffer's workspace is attached when its file opens
(`Editor/Workspace/Attach.lean`, which comes with the file commands and
brings the data and the finder with it), and
`workspace-current` says it; their registrations
(`Editor/Workspace/Compiled.lean`) name the registry and are not
imported. A buffer is given the minor modes its markers turn on when its
file opens (`Editor/Workspace/Modes.lean`, which comes with the attach).
Its model and its contract
(`Editor/Workspace/Model.lean`, `Editor/Workspace/Contract.lean`) are for
tests, and are not imported.

`:!` is here too (`Editor/Shell.lean`, which comes with the ex line): a
shell command run in the buffer's workspace as a job, and what comes of it
said in the echo area or shown in the workspace's output buffer. Its
registrations (`Editor/Shell/Compiled.lean`) name the registry and are not
imported.

`compile` is not here: the compile mode is a package outside the core
(`packages/compile/`), and the core requires no package, so this module
cannot import it. What a minor mode gives the compile mode, its markers,
named commands and error formats (`Editor/ProjectMode.lean`, with the
formats of `Editor/ProjectMode/Format.lean`), is the core's and comes with
`Editor/Setup.lean`, which registers it (`compileContribution`,
`projectCommands`). Config reaches the package's own declarations, the
shipped modes (`Compile.cargoMode`) and the matcher among them, because
an editor elaborates config on its package set's base, which is this
module and then the entry module of each package of the set
(`Editor/Main.lean`, "The base"); an editor built from a set without that
package elaborates config on this module alone.

Version control is here too (`Editor/VersionControl.lean`): the interface
a version-control system answers, in the editor's own terms, with its git
implementation (`Editor/VersionControl/Git.lean`), which runs git as jobs,
and the status buffer, `vc-status`, which shows a workspace's changed files
and stages and unstages them (`Editor/VersionControl/Status.lean`, which
brings the interface and git with it); staging and unstaging the hunk on
the cursor's line (`Editor/VersionControl/Stage.lean`); and the message
buffer, `vc-commit`, which commits (`Editor/VersionControl/Commit.lean`). Its registrations
(`Editor/VersionControl/Compiled.lean`) name the registry and are not
imported. Its model and its contract (`Editor/VersionControl/Model.lean`,
`Editor/VersionControl/Contract.lean`) are for tests, and are not
imported.

Extension points are here too (`Editor/Extension.lean`): config registers
a value at a package's extension point with `Extension.add`, as a package
does, and a command of config's reads the values at one with
`Extension.values` and `Extension.named`.

It never imports `Editor.Ffi` or a port's real binding (`Editor/Text/Real.lean`).
Those reach the Rust library, and only an executable linked with it imports
them, to run a command for real. So config, which sees this module and what
it imports, cannot name a binding.

It does not import the config session either (`Editor/Config/`): that is the
editor's side of a reload, and config has no use for it.
-/
