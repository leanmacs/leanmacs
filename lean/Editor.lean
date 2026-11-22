import Editor.Api.Theorems
import Editor.Command.Append
import Editor.Completion.Filtering
import Editor.FrameCommands
import Editor.Indent
import Editor.Jumps.Go
import Editor.TabCommands
import Editor.Text.Word
import Editor.UndoTree.Theorems
import Editor.Vocabulary

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
commands are the default package `files`' since the features-as-packages
roadmap's phase 6 (`packages/files/Files.lean`): this base does not import
them, and a config of a set that holds the package reaches `Files.open` and
`Files.save` through the set's base, the package's entry module
(`Files.EditorPackage`). A command of config's asks for a string
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
component, are not here: they are the default package `completion`
(`packages/completion/`), which registers them, and config names them with
`import Completion.Styles`, a module of the set's base through the
package's entry module (`Editor/Main.lean`, "The base"); with none chosen
the default is the style registered first, and with none registered the
core's own (`Completion.Style.unregistered`). Config registers one with `defineStyle` (`.keeping name keep` for one
written as a predicate) and chooses the default with `useStyle` and a
category's with `useStyleFor`. Compiled code may give a category a style
of its own, which `useStyleFor` overrides and `useStyle` does not reach:
the file prompt's category, `file`, is matched with `path`. `open-file`'s
prompt asks the sources of the category `file`, the shipped `files` source
by default (`Editor/Completion/Paths.lean`), so config adds to what it
lists by registering a source in that category. How the listing is drawn is a completion display's
(`Editor/Completion/Display.lean`): the shipped one, `minibuffer`, which
lists them one a row above the input, is the `completion` package's too,
and config names it with `import Completion.Displays`; with none registered
the core draws its own (`Completion.Display.unregistered`). Config registers one with
`defineDisplay` (`defineDisplay (Completion.Displays.minibuffer (rows :=
15))` replaces the shipped one, which sets its rows) and chooses the
default with `useDisplay` and a category's with `useDisplayFor`. The
commands that accept and cancel a prompt, move through its candidates and
put one in the input (`minibuffer-insert`), and the minibuffer's mode, are
not here: they are the package `packages/minibuffer/`, and config names
them with `import Minibuffer`, a module of the set's base through the
package's entry module (`Editor/Main.lean`, "The base"), as it names the
command prompt's below; what they act through, the prompt operations of
`Editor/Api.lean` (`acceptPrompt`, `cancelPrompt`, `chooseCandidate`,
`insertCandidate`), is here. The
fuzzy matcher is a sub-port of the editor's port, so a command of
config's asks which candidates a pattern matches with `Fuzzy.rank`
(`Editor/Fuzzy.lean`), as it asks a text. The ex
command line is here too (`Editor/Ex.lean`, with an ex line as data in
`Editor/Ex/Line.lean`): a command of config's runs a line with `Ex.run`,
handed the target it was called with, and `setup` binds an ex name to a command with `exCommand`
(`Editor/Setup.lean`). The registrations of the ex line's commands and the
ex names that ship (`Editor/Ex/Compiled.lean`) are not imported. The ex line
reaches the file commands through `files-api` and the buffer commands
through `buffers-api`. The file commands and the buffer commands are not
here: they are the default packages `files` and `buffers` (`packages/files/`,
`packages/buffers/`, features-as-packages phase 6), and config reaches them
(`Files.open`, `Buffers.switchCommand` and the rest) through the set's base,
their entry modules `Files.EditorPackage` and `Buffers.EditorPackage` among
it. The frame's commands are here too
(`Editor/FrameCommands.lean`): `toggle-fullscreen` and `minimise-window`,
which ask the platform's window through the display; their registrations
and default bindings (`Editor/FrameCommands/Compiled.lean`) are not
imported. The window commands are here too (`Editor/WindowCommands.lean`):
`window-split`, `window-close`, `window-focus-left` and the rest, which
split, close, focus and arrange the frame's windows, so a config's command
can call them; their registrations (`Editor/WindowCommands/Compiled.lean`)
are not imported. So are the tab commands (`Editor/TabCommands.lean`):
`tab-new`, `tab-close`, `tab-next`, `tab-switch` and the rest; their
registrations (`Editor/TabCommands/Compiled.lean`) are not imported. The
command that switches the theme in force, `load-theme`, is not here: it
is the default package `themes` (`packages/themes/`) since the
features-as-packages roadmap's phase 7, with the theme `default` it
registers, and a command of config's calls it with
`Themes.loadThemeCommand` through the set's base, the package's entry
module (`Themes.EditorPackage`) among it. What it is written over is
here: `themeNames` and `loadTheme` (`Editor/Api.lean`), and `setup`
registers a theme with `defineTheme` and names
the one in force with `useTheme` (`Editor/Setup.lean`). The palettes that
ship are a package outside the core too
(`packages/shipped-themes/`), which config names by a theme's name alone.
The command prompt, `execute-command`, is not here: it is a package
outside the core (`packages/execute-command/`), and config reaches it with
`import ExecuteCommand`, a module of the set's base through the package's
entry module (`Editor/Main.lean`, "The base"); a command of config's then
calls it with `ExecuteCommand.executeCommand`, over `commandNames`, which
is here. Nor is the binding search, `search-bindings`: it is the package
`packages/binding-search/`, which config reaches with `import
BindingSearch` the same way, and a command of config's calls it with
`BindingSearch.searchBindings`, over `keyBindings`, which is here. Nor
is completion at point: its commands and the source that ships, `words`,
are the package `packages/at-point/`, and config tunes `words` with
`import AtPoint.Words` the same way, defining it again under its name
(`defineAtPoint (Completion.AtPoint.words (pause := 100))`). An at-point
source of config's own is a `Completion.AtPoint`
(`Editor/Completion/AtPoint.lean`), which is here, registered with
`defineAtPoint` and used with `useAtPoint`.

How a key becomes an invocation is here too, so config can come to write
bindings: input schemes (`Editor/InputScheme.lean`), with the keymaps they
walk (`Editor/Keymap.lean`) and the invocations they yield
(`Editor/Invocation.lean`), and key strings (`Editor/Key/Notation.lean`),
with which a binding's keys are written (`Key.parse "C-x C-s"`). They come
with `Editor/Setup.lean` and the editor API. Modes come with
`Editor/Setup.lean`, which defines
them (`defineMode`): the mode record (`Editor/Mode.lean`) and the roles a
mode fills (`Editor/Role.lean`). The test
scheme and the scheme contract (`Editor/InputScheme/Test.lean`,
`Editor/InputScheme/Contract.lean`) are for tests, and are not imported.

The Vim scheme and evil are not here: the scheme that ships, with its
default states and bindings, and evil, Vim's states, motions, operators,
text objects, registers, undo, dot repeat, scroll and clipboard commands
written on the editor API, are the default package `evil`
(`packages/evil/`) since the features-as-packages roadmap's phase 7, and
the core requires no package, so this module cannot import them. Until
then it imported nine of their modules. Config reaches them through the
set's base, the package's entry module (`Evil.EditorPackage`) among it,
which imports those nine: a command of config's hands evil's move command
the vocabulary that ships, or that vocabulary with motions of its own added
(`Evil.move (Evil.motions.push mine)`), runs the operate command over the
shipped tables (`Evil.operate Evil.operators Evil.motions Evil.objects`),
and will bind against the scheme's parts of speech (`Vim.Bound`), as it
did. What is proved of evil on the text model is that package's too
(`packages/evil/Evil/Theorems.lean`); what it needs of the undo tree is in
`Editor/UndoTree/Theorems.lean`, which is the core's. An editor built from
a set without that package elaborates config on a base that names none of
them, and has no input scheme unless another package supplies one. What
evil's modules brought of the core is imported here by name now, so the
base holds what it held but evil: the indent primitives
(`Editor/Indent.lean`), the jump list and going to a place
(`Editor/Jumps.lean`, `Editor/Jumps/Go.lean`), the word rule
(`Editor/Text/Word.lean`), the vocabularies a scheme's commands look names
up in (`Editor/Vocabulary.lean`) and the undo tree's theorems.
Pinned by `EvilTest.Linked.evilChecks`, on a config the real elaborator
loads on the base `Editor` and `Evil.EditorPackage`
(`packages/evil/EvilTest/Linked.lean`).

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
(`packages/evil/Evil/TreeObjects.lean`). Its model and contract are for tests, and
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
and what a search of a workspace's files covers (`Editor/SearchRoot.lean`).
The finder that answers a directory's workspace through config, git and
marker files, the attach at the files interface's hook `FilesApi.Opened`,
`workspace-current`, `find-file-in-workspace` and `find-file-in-project`
are not here: they are the default package `workspace`
(`packages/workspace/`), and another feature reaches a workspace through
the interface package `project-api` (`ProjectApi.Workspaces`). Project
search and the working sets are default packages too, `project-search` and
`working-set` (`packages/project-search/`, `packages/working-set/`). Config
reaches the three through the set's base, their entry modules
(`Workspace.EditorPackage`, `ProjectSearch.EditorPackage`,
`WorkingSet.EditorPackage`) among it.

`:!` is not here: the shell is a default package outside the core
(`packages/shell/`), and the ex line reaches it through the core's staged
interface library `shell-api` (`ShellApi.lean`), whose names and history
this base brings. Config reaches the shell's commands through the set's
base, the package's entry module `Shell.EditorPackage` among it.

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

Version control is not here: it is a default package outside the core
(`packages/version-control/`, git's implementation, the status, commit,
review, log and blame buffers and the gutter), and config reaches it
through the set's base, the package's entry module
`VersionControl.EditorPackage` among it, as the command prompt's
(features-as-packages phase 3). The interface a version-control system
answers, in the editor's own terms, is its own library (`VcApi.lean`), with
the backend a package registers (`VcApi.Backend`); its fake and its
contract (`VcApiTest/Fake.lean`, `VcApiTest/Contract.lean`) are for tests,
and are not imported.

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
