import Editor.Api.Cases
import Editor.Clipboard.Contract
import Editor.Display
import Editor.Display.Contract
import Editor.File.Cases
import Editor.Fuzzy.Contract
import Editor.Job.Contract
import Editor.SyntaxTree.Contract
import Editor.Text.Contract
import Editor.UndoTree.Cases
import Editor.VersionControl.Contract
import Editor.Watch.Contract
import Editor.Workspace.Contract
import ModelTest.Check
import ModelTest.Editor.Api
import ModelTest.Editor.Api.Cases
import ModelTest.Editor.Appearance
import ModelTest.Editor.AtPoint
import ModelTest.Editor.BindingSearch
import ModelTest.Editor.Buffers
import ModelTest.Editor.Clipboard.Contract
import ModelTest.Editor.Clipboard.Model
import ModelTest.Editor.Command
import ModelTest.Editor.Command.Append
import ModelTest.Editor.Command.Dispatch
import ModelTest.Editor.Compile
import ModelTest.Editor.Compile.Errors
import ModelTest.Editor.Compile.Listing
import ModelTest.Editor.Compile.Shipped
import ModelTest.Editor.Completion.AtPointContract
import ModelTest.Editor.Completion.Contract
import ModelTest.Editor.Completion.DisplayContract
import ModelTest.Editor.Completion.Displays
import ModelTest.Editor.Completion.Keys
import ModelTest.Editor.Completion.Later
import ModelTest.Editor.Completion.Paths
import ModelTest.Editor.Completion.Style
import ModelTest.Editor.Completion.StyleContract
import ModelTest.Editor.Completion.Words
import ModelTest.Editor.Config.Registry
import ModelTest.Editor.Config.Reload
import ModelTest.Editor.Config.Session
import ModelTest.Editor.Config.Stores
import ModelTest.Editor.Display.Contract
import ModelTest.Editor.Display.Model
import ModelTest.Editor.DisplayRules
import ModelTest.Editor.Evil
import ModelTest.Editor.Evil.Clipboard
import ModelTest.Editor.Evil.Motions
import ModelTest.Editor.Evil.Objects
import ModelTest.Editor.Evil.Operators
import ModelTest.Editor.Evil.Registers
import ModelTest.Editor.Evil.Repeat
import ModelTest.Editor.Evil.TreeObjects
import ModelTest.Editor.Evil.Undo
import ModelTest.Editor.Ex
import ModelTest.Editor.Ex.Line
import ModelTest.Editor.ExcerptView
import ModelTest.Editor.Executable
import ModelTest.Editor.ExecuteCommand
import ModelTest.Editor.Face
import ModelTest.Editor.Face.Vocabulary
import ModelTest.Editor.File.Cases
import ModelTest.Editor.File.Model
import ModelTest.Editor.FileWatch.Model
import ModelTest.Editor.Files
import ModelTest.Editor.Floating
import ModelTest.Editor.FrameCommands
import ModelTest.Editor.Fuzzy.Contract
import ModelTest.Editor.Fuzzy.Model
import ModelTest.Editor.Gutter
import ModelTest.Editor.Headless.CommandLine
import ModelTest.Editor.Highlight
import ModelTest.Editor.Indent
import ModelTest.Editor.InputScheme
import ModelTest.Editor.InputScheme.Contract
import ModelTest.Editor.InputScheme.Vim
import ModelTest.Editor.InputScheme.Vim.Default
import ModelTest.Editor.Invocation
import ModelTest.Editor.Job.Contract
import ModelTest.Editor.Job.Jobs
import ModelTest.Editor.Job.Model
import ModelTest.Editor.Job.Pool
import ModelTest.Editor.Job.Runner
import ModelTest.Editor.Job.Table
import ModelTest.Editor.Json
import ModelTest.Editor.Key.Notation
import ModelTest.Editor.Keymap
import ModelTest.Editor.Language
import ModelTest.Editor.Layout
import ModelTest.Editor.Loop
import ModelTest.Editor.Loop.Driver
import ModelTest.Editor.Menu
import ModelTest.Editor.Mode
import ModelTest.Editor.ModeLine
import ModelTest.Editor.ModuleLookup
import ModelTest.Editor.Process.Environment
import ModelTest.Editor.Process.Model
import ModelTest.Editor.Program
import ModelTest.Editor.Scene
import ModelTest.Editor.Scroll
import ModelTest.Editor.Setup
import ModelTest.Editor.Shell
import ModelTest.Editor.State
import ModelTest.Editor.State.Request
import ModelTest.Editor.SyntaxTree.Contract
import ModelTest.Editor.SyntaxTree.Model
import ModelTest.Editor.TabBar
import ModelTest.Editor.TabCommands
import ModelTest.Editor.Text
import ModelTest.Editor.Text.Contract
import ModelTest.Editor.Text.Model
import ModelTest.Editor.Themes
import ModelTest.Editor.Themes.FairyFloss
import ModelTest.Editor.Themes.Solarized
import ModelTest.Editor.TypedPath
import ModelTest.Editor.UndoTree
import ModelTest.Editor.Version
import ModelTest.Editor.VersionControl.Commit
import ModelTest.Editor.VersionControl.Contract
import ModelTest.Editor.VersionControl.Git
import ModelTest.Editor.VersionControl.Gutter
import ModelTest.Editor.VersionControl.Hunk
import ModelTest.Editor.VersionControl.Model
import ModelTest.Editor.VersionControl.Plumbing
import ModelTest.Editor.VersionControl.Porcelain
import ModelTest.Editor.VersionControl.Show
import ModelTest.Editor.VersionControl.Stage
import ModelTest.Editor.VersionControl.Status
import ModelTest.Editor.VersionControl.Worktrees
import ModelTest.Editor.Watch.Contract
import ModelTest.Editor.Watch.Model
import ModelTest.Editor.Window
import ModelTest.Editor.WindowCheck
import ModelTest.Editor.WindowCommands
import ModelTest.Editor.Workspace
import ModelTest.Editor.Workspace.Attach
import ModelTest.Editor.Workspace.Contract

/-!
# The model tests

`lake test` builds and runs this executable (`mise run lean-test`). It links
no C glue and no Rust archive: everything here runs in Lean alone, against
hand-written fakes and the pure models of the editor's ports. With no
arguments it runs every check in `checks`, names the ones that failed, and
exits non-zero if any did.

The checks themselves live in test modules that mirror the module they
test: the checks of `Editor/State.lean` are in `ModelTest/Editor/State.lean`
(`ModelTest.Editor.State`), and a run of a port's contract against its model
is in the test module of that contract, such as `displayFailures` in
`ModelTest/Editor/Display/Contract.lean`. A test module keeps the helpers
only its checks use. Helpers and fakes that several test modules use are in
small support modules under `ModelTest/Support/`, each of one kind of
fixture, and `ModelTest.Check` holds the `Check` type and `failures`. Each
module imports the editor's modules and the model test modules it uses, and
no others. Everything is in the namespace `ModelTest`, so a list is
`ModelTest.<name>Checks` whichever module holds it. This module keeps only
`checks`, which runs them in order, and `main`.

The checks of the program type run programs over a small port of their own
(`Ask`) against a fake that records the requests it receives.

The text port's contract (`Editor/Text/Contract.lean`) is run against its pure
model here. `contract-test` runs the same list against the real binding.

The display interface's contract (`Editor/Display/Contract.lean`) is run
against its model here, in cells of two sizes (`displayFailures`). The real
binding's run of it is the display pipeline's. `sceneChecks` and
`displayChecks` are what only the model shows: the scenes published to it,
and its exact layout rule. `faceChecks` are the checks of faces as data and
of the built-in theme (`Editor/Face.lean`).

The policy by which a view follows its cursor (`Editor/Scroll.lean`) is
programs over the display port, and is checked on the display model alone
(`scrollChecks`), with a view's scroll anchor and its cursor as offsets:
which anchors are kept, how far one moves, the margin, what the policy
costs in requests, and the anchors a scroll by rows and a scroll to the
cursor's row place. Each row a check names is one the model answered, so no
check says where a text wraps.

A command is tested the same way: as a property, a command that returns
whether it held, run against the model (`commandProperties`). The `editor`
executable runs the same command source against the real binding.

A command is a program over the editor's composite port
(`Editor/Command.lean`), run here against the text model, the display model
and the watch model side by side (`EditorModel`). `commandPortChecks` pin
what that runner does with each sub-port's requests: a text program lifted
into a command does what it does alone, the display answers from the text
model's snapshots, a display refusal is the text port's of the same name,
and a watch request goes to the watch model.

The watch port's contract (`Editor/Watch/Contract.lean`: the interrupt flag
and a clock) is run against its model here (`watchFailures`), and
`contract-test` runs the same list against the real binding. `watchChecks`
are what only the model shows: an interrupt key that arrives at a request a
test names, and a clock that moves with a command's requests. `guardChecks`
run commands on those models as the loop runs one
(`Editor/Command/Dispatch.lean`, "The guard"): a command stops at its next
request once the flag is up, and cannot catch it.

The clipboard interface's contract (`Editor/Clipboard/Contract.lean`) is
run against its model here (`clipboardFailures`). `clipboardChecks` are
what only the model shows: a clipboard that is not available refuses and
keeps what it held, and one that holds nothing answers no text. They also
show the contract biting: a clipboard written here that drops every write
is reported.

The fuzzy matching interface's contract (`Editor/Fuzzy/Contract.lean`) is
run against its model here (`fuzzyFailures`), and `contract-test` runs the
same list against the real binding. `fuzzyChecks` are what only the model
shows: its rule of what matches, and that after the candidates that are
the pattern its order is the candidates'. They also show the contract
biting on each of the two things it asks: a matcher written here that
ignores case, and one that does not put an exact match first.

The completion style interface (`Editor/Completion/Style.lean`) is checked
over the fuzzy model (`styleChecks`): the fuzzy style answers the model's
order with its in-order spans, the orderless style matches exactly the
candidates that hold every component of the text, as a property over every
short text and candidate of a small alphabet, the model keeps what its
predicate says, and a category picks its style. Its contract
(`Editor/Completion/StyleContract.lean`) is run against the shipped styles
and the model (`styleContractChecks`), and seen to bite on a style that
answers an index twice and on one with a range past its candidate's end;
`contract-test` runs it against the fuzzy style over the real binding.

The completion display interface (`Editor/Completion/Display.lean`) has
its contract (`Editor/Completion/DisplayContract.lean`) run against the
model, `Display.plain`, and the shipped minibuffer display at 0, 1, 3 and
10 rows (`displayContractChecks`), and seen to bite on a display with a
decoration past its row's end. The minibuffer display's rule
(`Editor/Completion/Displays.lean`) is checked pure
(`completionDisplayChecks`): the row cap, the faces of the chosen row and
the others, the matched ranges and their offsets in the sheet, a label in
place of the text, the annotation column, the group headers, the window
round the choice, and a category's display chosen.

The layouts (`Editor/Layout.lean`) are pure functions, checked by
enumeration (`layoutChecks`): master-and-stack's rectangles tile the area
for one to eight windows at every sample size, share, side and count of
main's, with its geometry pinned; monocle gives the whole area to the
selected window; and the manual split layout's tiles the area for every
tree its operations reach, with its geometry and its operations (insert,
remove and its inheritor, balance, resize, fit) pinned; and an edge
layout's strip is pinned at 25 percent, reserves nothing with no window
docked, tiles the area under compositions of up to two edges round each
layout, and passes the list's operations through to the layout inside
it. The carve (`Layout.carve`) is pinned by examples and, over the same
layouts, by its rule: the carved tiles and the dividers tile the area, and
a tile along the area's edge keeps that edge.

The placement of a float (`Editor/Floating.lean`) is checked by
`floatChecks`: beside a position, as a property over the sample areas,
the rectangles master-and-stack gives one to three windows in each, spots
at the left, middle and last pixel and at the top, middle and last row of
each, rows of 1, 16 and the window's height, and every share of a sweep on
each axis, that the float is inside the area, against the row and clear of
it, at the position or shifted left just enough, the share wide, and the
share tall below when it fits there and above when it fits there; and by
examples of each case, centred, and a share resized.

The syntax tree interface's contract (`Editor/SyntaxTree/Contract.lean`)
is run against its model here (`syntaxTreeFailures`), with each property's
texts as the snapshots `0`, `1` and so on, and `contract-test` runs the
same list against the real binding. `syntaxTreeChecks` are what only the
model shows: the JSON tree of a small text node by node, the root of a text
of blanks, the `ERROR` answer outside the subset, what the query subset
refuses as unsupported, the contract biting on a model written here
that answers a range with the whole text's captures, and a model whose
trees a test says are not delivered refusing questions of captures with
`notParsed`.

The editor state (`Editor/State.lean`) is checked on the text model
(`stateChecks`): the initial state, that the rectangles of its views are
the layout's above the minibuffer's strip, and the layout operations, each refused with the state as it
was when it would break an invariant. The invariants themselves are checked
to refuse: states built in code that each break one (`spoilings`) are not
well formed, so `EditorState.wellFormed` is seen to answer false for every
one of its clauses. The operations the window commands are made of
(`windowOperationChecks`, part of `stateChecks`) are checked there too: a
split's placement, a removal's inheritor, zoom, the last window focused,
each change of `EditorState.arrange`, focus by direction against a property
over sample states of the three layouts, with and without docked windows,
and focus in list order; and a docked window focused, closed, split,
promoted, moved between an edge and the tiles, a layout chosen without its
edge, and a window opened at a spot. The floating windows
(`floatingWindowChecks`, part of `stateChecks`): the focus rule, a float
moved into the tiles and out of them, each operation's rule for a float,
what happens when an anchor goes, a float opened at each anchor and its
refusals, the floats' rectangles, and the spots a publish sets; the
direction property runs over states with none to two floats. The loop's
placing of floats (`floatViewChecks`) is checked on its driver.

Display rules (`Editor/DisplayRules.lean`) are checked by
`displayRuleChecks`: which rule a buffer's facts choose, which targets a
layout lacks, where `EditorState.displaying` puts a buffer, and, on the
loop's driver over the editor's models, `ls` and a command's buffer going
to the stack while main keeps the file, a mode's buffer docked at the
left edge by a rule, and a command's buffer opened in a float centred in
the tiled area by a float rule.

The window commands (`Editor/WindowCommands.lean`) are checked by key on
the loop's driver over the editor's models, under the Vim scheme that ships
(`windowCommandChecks`): Vim 9.1's `C-w` behaviours under the manual split
layout, resizes among them, the reorders, zoom and resizes under
master-and-stack, focus by direction under the three layouts, the refusals
in the echo area, and a config's `C-w` keys reached in insert state while
one that binds none keeps the word delete.

Tabs (`Editor/State.lean`, "Tabs") are checked on the state's model
(`tabChecks`): a new tab, selecting, closing, renaming and moving one, the
refusals, a tab left closing its transient floats, focusing and showing a
buffer in a hidden tab's window, and config's layout rearranging the tab in
view alone. The tab commands (`Editor/TabCommands.lean`) are checked by
key under the Vim scheme that ships (`tabCommandChecks`): tmux's keys under
`C-w`, the prompts of `tab-switch` and `tab-rename`, each command acting on
the tab of its call's window, and a publish's layout reaching the tab in
view alone. The tab bar (`Editor/TabBar.lean`) is checked by `tabBarChecks`:
its line, its strip, and the view a publish draws it in.

The command loop (`Editor/Loop.lean`) is checked on the editor's models
(`loopChecks`): events fed to `Loop.step` one by one, the state each leaves
and the scenes the display model records. Among them is what the loop does
when publishing is refused, with a text or a snapshot released behind it:
the scene is published all the same, with the refusal in its echo.

What a key does in the loop is checked the same way (`dispatchChecks`), on
the editor's models and the test scheme, with keymaps and commands written
in the test, so that none of them names a shipped scheme's keys or a
registered command:

- `dispatchKeyChecks`: which keys are stepped through the scheme, the
  pending keys the scene shows, and the command a completed sequence runs,
  with its arguments and its keys;
- `dispatchRollbackChecks`: a command that fails leaves the texts, the
  windows' markers, the history and the scheme's state as they were, what
  cannot be rolled back is said, a move in the history is not taken back,
  and a mark of the saved state is;
- `dispatchInterruptChecks`: on the watch model, an interrupt key that
  arrives while a command runs, before one and between two;
- `pressedChecks`: the reserved invocation that presses keys
  (`InputScheme.keysName`, `Loop.pressed`): its keys are fed from rest,
  even with a prefix pending, and what they complete runs with those keys
  as pressing them does, under the test scheme and, over evil's driver,
  under the Vim scheme (`i` enters insert, `x` deletes); a sequence they do
  not complete is said (`Loop.notBound`) and runs nothing. They are
  registered after `dispatchChecks`;
- `dispatchSlowChecks`: on the watch model's clock, which a command's
  requests move, a command slower than the threshold is logged once;
- `dispatchGiveUpChecks`: what the loop gives up once a command has run to
  its end, and not before: a closed window's markers, a removed buffer's
  text, the snapshot of a save that is no longer in flight, and the
  minibuffer of a prompt that was accepted or cancelled;
- `dispatchMinibufferNoticeChecks`: the loop tells its scheme when a
  command that ran to its end opened the minibuffer's view, in both states
  of the scheme it keeps, after the views the command closed, and tells it
  nothing after a later command, a key's or a job's, that ran with the
  prompt open;
- `dispatchUndoChecks`: undo from a command, and that what is edited while
  a view is in an insert session is one step of the history;
- `dispatchReportChecks`: a command is called with what the scheme reports
  of its view, in the scheme's state after its key;
- `dispatchCommandGivesUpChecks`: a command that gives up (`giveUp`,
  `Editor/Api.lean`) is rolled back, its reason is in the echo area with
  no `refused:`, and the scheme is back at rest. It is another thing than
  `dispatchGiveUpChecks`, which is what the loop gives up after a command;
- `dispatchCommandBreaksOffChecks`: a command that breaks off (`breakOff`,
  `Editor/Api.lean`) keeps what it did, its reason is in the echo area with
  no `refused:`, and the scheme is back at rest;
- `dispatchRunCommandChecks`: a command that has another run inside it
  (`runCommand`, `Editor/Api.lean`) runs the one a key's invocation of the
  name runs, as part of itself;
- `dispatchHintChecks`: what the key hints list after a prefix, a
  binding's description and a prefix's name and count, shown at once with
  a delay of 0;
- `keyHintLoopChecks`: when and where the key hints are shown: the
  reconciler `Loop.armedHints` opening, keeping and closing them and
  arming and withdrawing their delay, the hints drawn as the candidate
  list's view and following the walk, the delay handed to the host, a
  fake display chosen for `key` drawing them, the pending keys drawn
  in the selected window's status line, and the publish with no step
  (`Loop.publishHinted`) closing the hints and withdrawing their delay
  under `.never`, and opening them and arming it under a delay.

What the loop does with a scheme's report of a view is checked with a
scheme written here, `switching`: the test scheme, with a report of each
view that an invocation it yields switches. So the checks of the scene's
cursor and status field (`loopChecks`), of the report a command is told,
of insert sessions and of where a committed text is inserted
(`commitChecks`) name no Vim state and no Vim key.

Jobs started from commands are checked on the loop's driver over the
editor's models and the job model (`Editor/Loop/Driver.lean`):

- `driverChecks`: a command starts a job by its name, the job's result
  comes back as a command, events fed meanwhile are handled first, a job
  reads a snapshot its command took, and a job's command is handed what its
  own job loaded; and the key hint delay on the driver's time: hints shown
  once it has passed and not before, none after a sequence completed
  before it, and a delay of another generation that changes nothing;
- `promptChecks`: prompts on that driver. `promptLoopChecks`, with commands
  written here under keys of the global keymap: an accepted prompt's
  answer is handed back with the step, and the answer's command runs
  before the next event, with the asking view as its target; a
  continuation with no command, one that is refused and one that asks
  again; and rollback and the interrupt around an open prompt.
  `echoPromptChecks`: a command that says something and then asks leaves
  no echo, and what a job's command says while the prompt is open is kept.
  `promptModeChecks`, with the minibuffer's commands and its mode
  (`Editor/Minibuffer/Compiled.lean`) in a registry whose active keymaps
  the loop is handed: the phase's acceptance criteria, with the accept key
  and the cancel key read from the test scheme's role table;
- `candidateChecks`: a prompt's candidates on that driver, with commands
  written here: the listing the loop makes before each scene, for the
  initial text and for the text typed so far, what a command that fails
  is rolled back to, what the listing costs in requests, and that a
  refusal of the listing's read refuses no step, leaves the listing and
  the choice and is in the scene's echo; and the candidate list the scene
  draws, in a view of its own directly above the minibuffer's, its window
  scrolled round the choice, its strip kept as tall as it has been while
  the prompt is open and given back when it closes. What is
  listed is compared with what the fuzzy model answers
  (`FuzzyModel.rank`), never with an order written out;
- `displayStateChecks`: the candidate list in the state, pure: the sheet
  the display answered kept on the prompt, the window round the choice,
  the minibuffer's place that grows and never shrinks while the prompt is
  open, the strip cut into the list's part and the minibuffer view's, a
  frame too short for it, and the list's view's rectangle, padding and
  well-formedness;
- `keyHintStateChecks`: the key hints in the state, pure: a candidate
  list with no typed text that takes the list's place above the bottom
  row once due, with no input row, gives way to an open prompt, grows and
  never shrinks while open, and a delay of another generation that
  changes nothing;
- `laterChecks`, `completionJobChecks` and `laterLoopChecks`: sources that
  answer later (`Editor/Completion/Later.lean`), their orders and batches
  as arguments and their jobs on the job model; the reconciler of a
  prompt's jobs (`Loop.completionJobs`), pure over the state; and, through
  the loop on that driver, completion phase 3's four criteria on the
  models, with a job held at each post and a match job delivered at
  `finish`, and a match that fails;
- `sourceContractChecks`: the completion sources' contract
  (`Editor/Completion/Contract.lean`) on the model, the fake, each
  shipped source and the key hints' source, run on `twoBuffers` over the
  editor's models, and seen to report a source that writes and one that is
  refused;
- `keyHintSourceChecks`: the key hints' source
  (`Editor/Completion/Keys.lean`): a candidate of each kind of hint, its
  annotation and kind, a source of the category `key` that has filtered
  and answers the same for any text, and the delay's notation and its
  longest;
- `fileCommandChecks`: the file commands (`Editor/Files.lean`) on that
  driver, over the model of files (`Editor/File/Model.lean`), with keys
  bound to the commands and jobs registered as the test says: opening a
  file into a buffer, a path that is open, a file that is not there, what
  is typed while a load is in flight, and a file that would be shown in
  the minibuffer's view; several paths opened one after another, with a
  refused start, an asking view closed while a load runs and an interrupted
  delivery among them; saving a buffer, a file that
  changed on disk, a save that reports late, a forced save, and what each
  command says when it starts nothing; and the commands and jobs as
  compiled code registers them (`Editor/Files/Compiled.lean`). They touch
  no file;
- `openFilesChecks`: the loop's handling of the files a window asks to open
  (`Event.openFiles`, `Editor/Loop.lean`) on that driver: it runs
  `open-file` with the paths, so two paths leave two buffers and the last
  path's is shown, whichever order its loads would finish in, and config's
  command of that name runs in its place. They touch no file;
- `dispatchQuitChecks`: quitting in the loop (`Editor/Loop.lean`, "Quit")
  on that driver and the model of files, with commands written here that
  ask the editor to quit: the step says stop once the editor can leave,
  after its scene; a quit waits for a save in flight and stops at the
  delivery of its result; and a quit that cannot go ahead is withdrawn,
  when the save is refused and when the buffer is edited meanwhile. They
  name no ex name. They are apart from `dispatchChecks`, which are
  defined before the driver;
- `systemQuitChecks`: the system's quit (`Event.quitRequested`,
  `Editor/Loop.lean`, "Quit") on that driver, with the compiled `quit`
  registered: with nothing unsaved the step says stop; with unsaved
  changes the editor goes on, says why, and asks the frame `keepRunning`
  once; with a save in flight it waits, and a refused save withdraws the
  quit and asks `keepRunning`; config's `quit` runs in its place; and a
  quit the system did not ask asks the frame nothing;
- `exChecks`: the ex command line (`Editor/Ex.lean`) on that driver, with
  the commands compiled code registers for it, for the minibuffer and for
  files, keys of the test scheme bound to the ex command and to the accept
  and cancel commands, and ex bindings written here: the ex command opens
  a prompt, and the accepted line runs the command its name is bound to,
  as a step of its own, with the rest of the line as its argument; a name
  nobody bound, an argument a name does not take, an empty line, a bound
  command that is not registered or is refused, and a cancelled line.
  Each message is read from the function that makes it;
- `themeChecks`: the command that loads a theme (`Editor/Themes.lean`) on
  that driver, told of two registered themes: with no name it asks among
  them, with a registered name the step hands the name back, and a name
  nobody registered, or a prompt already open, is said in the echo area;
- `executeCommandChecks`: the command prompt (`Editor/ExecuteCommand.lean`)
  on that driver, from keys that bind neither it nor `load-theme`: it lists
  the registered commands' names in order; accepting `load-theme` runs it
  as a step of its own, which asks in turn, and accepting a theme there
  loads it; a typed fragment runs the first command the style lists for it,
  a text nothing matches is said and an empty one runs nothing; a prompt
  already open is said; and a fake style chosen for the category `command`
  reverses the listing and decides which command a fragment runs, while a
  theme prompt keeps its own order; opened by a key bound to it or from the
  menu, it annotates its candidates with their keys as when called by name;
- `bindingSearchChecks`: the binding search (`Editor/BindingSearch.lean`)
  on that driver: it lists each binding the scheme reaches as its keys and
  command, annotated with its description; accepting one runs its command
  as pressing its keys at rest does, with those keys; a typed fragment runs
  the style's first, a text nothing matches is said and an empty one runs
  nothing; a prompt already open is said; a fake style chosen for the
  category `binding` reverses the listing; and opened by a key bound to it,
  from the menu, or as the command a fake scheme's answer completes, it
  lists the same bindings as when called by name;
- `faceVocabularyChecks`: the face vocabulary (`Editor/Face/Vocabulary.lean`)
  names each face once with its meaning, and lists every face the shipped
  Vim scheme and the loop draw, layout's four and the faces declared
  ahead; the completeness check (`Editor/Themes/Check.lean`) finds each
  problem in a theme spoiled from the built-in one, a cursor colour that
  falls through to the default face's among them; one palette mapping over
  two palettes gives two complete themes; and every shipped theme is
  complete;
- `solarizedChecks`: the Solarized themes (`Editor/Themes/Solarized.lean`):
  each of the sixteen colours is its published value, the light colours
  swap the four base pairs, each variant's faces are the choices the
  module's table records, and both variants are shipped.
- `fairyFlossChecks`: the Fairy Floss theme (`Editor/Themes/FairyFloss.lean`):
  each of the nineteen colours is its published value, the source's commit
  is recorded, its faces are the choices the module's table records, and it
  is shipped.

The undo tree (`Editor/UndoTree.lean`) is plain Lean over the text port, so
its cases (`Editor/UndoTree/Cases.lean`) are properties of the same kind and
run against the model in the same list; `contract-test` runs them against
the real binding. `undoTreeChecks` are the checks of its pure operations,
which ask nothing of a text. `textModelStepChecks` hold a premise of the
theorems about undo (`TextModel.InStep`, `Editor/Text/Model.lean`) where
it is not proved: after each request of a sample sequence, every live text
of the model is in step.

The job system is tested here with no Rust library:

- `poolChecks`: warming Lean's task pool (`Editor/Job/Pool.lean`). They pin
  no size: how many threads the pool has is Lean's to say, and
  `LEAN_NUM_THREADS` in the environment changes it. Each check learns the
  pool's threads by warming it, and says what must hold relative to them;
- `jobModelChecks`: the job port's pure model (`Editor/Job/Model.lean`), its
  clock and its cancellation, and what only the model's exact clock can
  show: that a timer does not drift;
- `waitChecks`: the table of waits and the fake clock, with no job;
- `runnerChecks`: the runner (`Editor/Job/Runner.lean`) over the fake clock
  (`Editor/Job/Fake.lean`). A check controls time by moving its own fake
  clock and holds a job on a promise it resolves; it sleeps for nothing, and
  polls only as the bound after which it fails;
- `tableChecks`: the job table (`Editor/Job/Table.lean`), which is pure;
- `ownerChecks`: the shell over the table and the runner
  (`Editor/Job/Jobs.lean`): removing an owner cancels its jobs;
- `fileModelChecks`: the pure model of the files a job reaches
  (`Editor/File/Model.lean`): its decoding of bytes into the text model's
  escapes against texts written out by hand, what a load and a save answer
  and in what order they are refused, and the file data's own functions.
  They touch no file;
- `processChecks`: the pure model of the processes a job runs
  (`Editor/Process/Model.lean`), its order of refusals and its record of
  what a cancelled job had killed, and the runner's process waits on the
  fake of the process service (`Job.FakeProcesses`): cancelling a job in a
  process wait withdraws it, which is how the library comes to kill the
  child, and a runner with no process service refuses as a value. They
  start no process;
- `fileRunnerChecks`, and one check among `runnerChecks`: the runner's file
  waits, on the fake of the file service (`Job.FakeFiles`,
  `Editor/Job/Fake.lean`): a file wait holds no thread, cancelling
  withdraws it, what a job loaded is released however the job ends, a job
  cannot save what another job holds, and a save finds what the editor has
  published when it is made.

The job port's contract (`Editor/Job/Contract.lean`) is run here against the
model and against the runner over the fake clock, and its file properties
against the model of files and against the runner over the fake of the file
service, in a made-up directory: no file is touched. `contract-test` runs
the same lists against the runner over the Rust library's services.

The cases that cross the text port and the job port
(`Editor/File/Cases.lean`) are played here on the two models
(`playOnModels`), with the snapshots handed across as values: a command, a
job that reads what the command published, the job's command, which is
handed what the job held, and a last command, which is handed nothing.
`contract-test` plays them on the real binding and the library's file
service.

The config session's decisions are tested here too, with no elaborator:

- `setupChecks`: what a `setup` registers, commands, stores, jobs, key
  bindings, the leader and the localleader, modes, ex bindings and faces,
  and when it is refused;
- `setupHintChecks`: a binding's description (`bindKey`'s `desc`) and a
  prefix's name (`prefixName`), as a `setup` collects them, and the names
  it refuses;
- `registryChecks`: the registry, its commands, its jobs, its key
  bindings, its modes, its ex bindings and its faces, replaced by owner,
  and the keymap it makes, its bindings expanded against the leaders in
  force and bound by where they hold, and the bindings a scheme's leaders
  make one sequence, which are refused;
- `registryHintChecks`: a binding's description on the registry's keymap,
  and its prefix names, by owner, expanded against the leaders in force,
  and two names a scheme's leaders make one prefix, which are refused;
- `storeChecks`: the rule that meets a new config's stores with the cells
  there are, one check for each case;
- `sessionChecks`: one reload (`Config.build`), on a fake elaborator that
  records every call and a fake source, built for the test scheme;
- `reloadChecks`: the reducer that serialises reloads, with outcomes built
  by hand. The phase's acceptance tests are here on fakes (reload replaces a
  command, a rejected reload keeps the old config, a reload does not
  double-register, a store value survives a reload), and `config-test` runs
  them again with the real elaborator, queue and text binding. The reducer
  also says when the old config's jobs are cancelled: when a reload
  installs, and only then; and what the theme is: the built-in one then the
  installed config's faces, replaced as a set by an install and kept by a
  rejected reload. An install replaces config's key bindings, modes and ex
  bindings and keeps the compiled ones;
- `reloadHintChecks`: an install replaces config's descriptions and prefix
  names with its bindings, so a later config without them clears them.

How a key becomes an invocation is pure Lean with no port, so its checks
need no model and no fake of a collaborator:

- `keymapChecks`: a keymap (`Editor/Keymap.lean`), on keys built in code:
  what a sequence is bound to, which sequences a binding begins with, the
  chord a binding names a key by, the walk through a list of keymaps
  in precedence order, a binding's description, and the keys that can
  follow a pending prefix, in order, with what the walk makes of each, and
  every sequence the walk completes from rest over two tiers, shadowed and
  unreachable bindings left out;
- `keyNotationChecks`: key strings (`Editor/Key/Notation.lean`): the keys
  a string names, the strokes it is written as with `<leader>` and
  `<localleader>` and their expansion against leaders, the strings that are
  refused, and that the notation of a chord names it back;
- `invocationChecks`: an invocation (`Editor/Invocation.lean`): two are
  compared by their command names and their arguments;
- `exLineChecks`: an ex line (`Editor/Ex/Line.lean`): the name and the
  argument a typed line parses to, and the invocation an ex binding makes
  of an argument, by what the binding takes;
- `schemeChecks`: the scheme interface (`Editor/InputScheme.lean`) on the
  test scheme (`Editor/InputScheme/Test.lean`), with keymaps written as key
  strings: what the keys of a bound sequence yield, that an unbound key
  resets the scheme, which of two keymaps wins, the pending keys it
  reports, its self-insert, and the leaders in force;
- `schemeHintChecks`: what a scheme says can follow a pending prefix
  (`InputScheme.continuations`): nothing from a scheme that says nothing,
  the test scheme's list, and a continuation as a key hint;
- `schemeContractChecks`: the scheme contract
  (`Editor/InputScheme/Contract.lean`) holds of the test scheme, and
  reports schemes written here that each break one property of it, `eager`
  among them, which emits on a strict prefix;
- `continuationsContractChecks`: the contract's property of what can
  follow a pending prefix reports a scheme that lists a prefix key its walk
  does not continue, and one that lists keys at rest;
- `keyBindingsContractChecks`: the contract's property of the key bindings
  a scheme lists reports a scheme that lists one its walk does not
  complete, and the test scheme lists those of its keymaps.

The Vim scheme (`Editor/InputScheme/Vim.lean`) is checked the same way,
with no model:

- `vimEditChecks`: what an edit compiles to, the layout of each kind of
  invocation, and what an edit says of itself;
- `vimRegistryChecks`: the registry of Vim states: looking a state up by
  its name, and registering one. A record holds keymaps and so has no
  equality: the checks compare records by their fields (`vimSeen`);
- `vimGrammarChecks`: the grammar: which keymaps a key is looked up in,
  and what a key sequence parses to and yields;
- `vimStateChecks`: Vim states: which state a view is in, how one is
  entered, what the scheme reports of a view in a state, what the grammar
  reads of a state's record (typed text, an operator over the selection),
  the last change, and a mode's keys under the Vim scheme: a hand-tuned
  key is typed text in insert state, and `Mode.check` reads every state's
  keymaps;
- `vimHintChecks`: what the Vim scheme lists as able to follow a keymap
  prefix (`Vim.State.continuations`): keys of both tiers, an active prefix
  over a state's binding, the pending keymaps while an operator waits, and
  nothing after a count, an operator or the register prefix alone;
- `vimKeyBindingChecks`: the key bindings the Vim scheme lists
  (`Vim.State.keyBindings`): the commands of the walk's tiers in the view's
  state, an active binding first with its description, and no part of
  speech, no sequence that begins with a count digit, no mode's binding
  where typing is text and no binding an active prefix shadows;
- `vimDefaultChecks`: the default states and bindings
  (`Editor/InputScheme/Vim/Default.lean`), observed through the grammar:
  what each default key parses to, and what the scheme reports of the view
  after it. They restate no table and name no vocabulary or command name;
- `vimDefaultHintChecks`: over every default state, every key the scheme
  lists after a keymap prefix is what `Vim.parse` and the walk make of it,
  and every chord of the defaults it leaves out walks to nothing;
- `vimContractChecks`: the scheme contract holds of the Vim scheme, over
  the registry written here and over the default states.

The grammar's checks run on a registry and keymaps written here
(`vimStates`), so that none of them names a default binding.

Evil (`Editor/Evil.lean`), what the Vim scheme's invocations run, is
checked on the editor's models. This is where Vim keys are pressed against
a text, under the Vim scheme that ships with the commands compiled code
registers for evil (`Editor/Evil/Compiled.lean`), on the loop's driver:

- `evilRestChecks`: where a cursor rests under each rule, from every
  position of a few small texts, on the text model alone;
- `evilMotionChecks`: each motion's key in a text with the cursor written
  into it as a bar (`evilKeys`, `evilRows`), with no count, a count of 1, a
  count inside the text and a count past it; the wanted column, by keys
  and by a command that calls the move command twice with one call; a
  sweep of every motion of the vocabulary from every position a cursor may
  rest at; and that every default motion key has a motion of its name;
- `evilStateChecks`: `v`, `V` and `<Escape>`: the selection the scene
  shows, its shape and what it covers, and the scene's cursor and status
  field in each state; and, by the entering command called with a report
  written by hand (`evilEntered`), a state that keeps both ends entered
  from an exclusive selection, which no default key does: where the anchor
  rests, and that the head steps back;
- `evilInsertChecks`: `i a I A`, typed text and `<Escape>`; that an insert
  session is one step of the history, by an undo request; a key typed into
  a prompt; and a committed text in normal state and inside a session;
- `evilOperatorChecks`: the operators (`Editor/Evil/Operators.lean`). An
  operator's keys are pressed with a sentinel in the unnamed register
  (`evilEdited`), so a register left as it was is seen, and a row
  (`OperatorRow`, `operatorRows`) says the text, the cursor, the register
  and whether it is line-wise, whether the view is left in insert state,
  and whether the command gave up. `operatorTable` is every operator over
  every motion that takes no argument in five situations; beside it are the
  special cases, the calls of the operate command that give up, and that an
  operator is one step of the history. `operatorSweep` presses every default
  operator key with every default motion key from every resting position of
  a few texts, a motion that takes a character with one;
- `evilFindChecks`: `f`, `t`, `F`, `T`, `;` and `,` (`Editor/Evil/Motions.lean`)
  as moves (`findRows`) and under each operator (`findOperatorRows`, which
  `findOperatorPairs` holds to the default tables), and the last find they
  keep;
- `evilSelectionChecks`: the operators over a `v` and a `V` selection, by
  the same rows, and that the operator's key leaves one cursor;
- `evilRegisterChecks`: `x`, the registers a yank and a deletion set, the
  clipboard register on the clipboard model (`evilClipped`), and `p` and
  `P`, by the same rows;
- `evilOpenChecks`: `o` and `O`, by the same rows, and their insert
  session;
- `evilIndentChecks`: `=` by key in a JSON language whose model tree
  answers the indents query (`indentDriver`): `gg=G` over a mangled text,
  `=af`, counts, `=j`, a visual selection, one undo step, `.` over another
  range, a config entry's tab unit, and the give-up with no syntax tree, no
  indents query, or a tree not delivered yet (`undeliveredDriver`); and the
  new lines `RET`, `o` and `O` start at their level, at the row's own indent
  while the tree is not delivered, and as before this phase with neither;
- `evilUndoChecks`: `u` and `C-r` after one change of each kind
  (`undoRows`): the text and the cursor from before the change, and those
  the change left. They are the phase's rule and are not compared with
  Vim, which leaves the cursor at the start of the changed text;
- `evilRepeatChecks`: `.` after a change of each kind (`repeatRows`), a
  count before it, a change with an insert session and its typed and
  committed text, the editing keys of insert state in a session
  (`insertKeysRepeatRows`), and what is not repeated;
- `clipboardCommandChecks`: the Edit menu's Cut, Copy, Paste and Select
  All (`Editor/Evil/Clipboard.lean`), each by its chord and by its menu
  item (`clipRan`), in each Vim state, on the clipboard model.

Each expected text of a row is written by hand from Vim's documented
behaviour (`docs/design/keymaps-and-modes.md`, "Motions as built"). No
check runs Vim. The word rule outside ASCII is the text port's and is not
restated here: the word motions' rows are ASCII, and one text with letters
Vim and the editor agree on.

A view that follows its cursor (`Editor/Loop.lean`, "Following the
cursor") is checked on the same driver, under the same scheme and commands
(`viewChecks`), in frames a few rows tall (`viewDriver`): keys are pressed,
the frame is resized, and what the next scene shows of a view is asked of
the driver's models (`viewSeen`): where its scroll anchor is, the rows the
display model answers from it for the scene's view, and the row it answers
for the cursor. So no check says where a text wraps. They are the phase's
acceptance criteria for following, the scroll margin among them, and what
following costs in requests, as a difference between two frames.

Modes are checked on the test scheme, by the roles and the leader it reports
(`InputScheme.roleKey`, `InputScheme.leader`), so that no check of a mode
names a scheme's key:

- `modeRecordChecks`: the registered roles (`Editor/Role.lean`), and the
  keymaps a mode makes for a scheme (`Editor/Mode.lean`): its roles at the
  scheme's keys for them, its suffixes under the localleader, and the scheme's
  hand-tuned keys for it ahead of both; and what `Mode.check` reports;
- `modeDescriptionChecks`: a mode's descriptions of its roles and
  suffixes (`Mode.roleDescs`, `Mode.localDescs`) are on their keys in its
  keymaps;
- `modeRegistryChecks`: modes in the registry
  (`Editor/Config/Registry.lean`): a mode's lineage, and the active keymaps
  of a view, in precedence order;
- `modeDispatchChecks`: keys in the loop over the registry's active
  keymaps, on the editor's models: a role's key runs the major mode's
  command in a view of its buffer and the global binding elsewhere, a minor
  mode's wins over the major mode's, a derived mode falls to its parent,
  and the leader then a suffix runs the mode's local command;
- `modeEnterChecks`: a mode's on-enter action, on the editor's models: it
  runs once, with the view, when the mode becomes a buffer's major mode, a
  derived mode's lineage root first, and a refusal runs nothing;
- `highlightFaceChecks`: the capture-to-face rule (`Editor/Highlight.lean`),
  pure: the shipped default from the face vocabulary, the fallback of a
  dotted capture to its first component, and config's mapping over both;
- `highlightEnterChecks`: a major mode with a syntax tree, on the editor's
  models through the loop's dispatch: the text attached and highlighted in
  the faces the rule gives, a mode's own query, a refusal said in the echo
  area with the mode still set, a parent's syntax tree taken, and the text
  detached when a mode with none replaces it; and the steps after the
  highlights: injections, a language for the model's grammar, and the text
  objects and indents queries kept, each refusal said and stopping its own
  step alone.
- `indentRuleChecks`: the indent rule (`Editor/Indent.lean`), pure, over
  hand-built rows: begins on one row count once, a branch takes a level
  away only as a row's first non-blank, the level never below 0, the rows
  of an ignored node after its first kept, a node ending at a row's start
  not reaching it, a blank row's level, names the rule does not read
  ignored, and an opening bracket the tree did not close counting for every
  later row an incomplete node that holds it reaches, and for none after;
- `indentOpeningChecks`: the opening rule and the widening
  (`Editor/Indent.lean`), pure, over hand-built nodes: a begin node holding
  the position counts, an unclosed bracket before it counts, a branch at
  the first non-blank that moves takes a level away, a position inside an
  ignored node adds nothing, and an incomplete node widens a question to
  its start;
- `indentEditChecks`: levels as edits (`Editor/Indent.lean`), pure: a
  level's whitespace in spaces or tabs, the re-indent's edits, a blank row
  emptied and a kept row left, what a new line gets for each answer, and
  the edit that breaks a line;
- `indentLevelChecks`: the indent primitives (`TextId.indentLevels`,
  `TextId.openingLevel`, `TextId.reindentEdits`), on the editor's models: a
  pretty-printed JSON text under a test mode's indents query gets each
  row's indent in levels, a text with no syntax tree is refused, an empty
  indents source answers 0 for every row, a question is widened to an
  incomplete node's start, a line opened at a position gets its level, and
  the re-indent's edits are read from the text.

Version control (`Editor/VersionControl.lean` and the modules under
`Editor/VersionControl/`) is checked with no git: against what git printed,
captured as fixtures (`ModelTest.Support.Git` says how), the model of a
repository (`Editor/VersionControl/Model.lean`) and the job model:

- `versionControlParserChecks`: the reader of git's porcelain status
  (`Editor/VersionControl/Porcelain.lean`), on the fixtures, and the
  records it refuses;
- `versionControlPlumbingChecks`: the readers of git's plumbing
  (`Editor/VersionControl/Plumbing.lean`): the worktree list, the branches,
  a raw diff and a batch of blobs, and what each refuses;
- `versionControlModelChecks`: the model of a repository: its status of
  each state, how it pairs renames, what its writes do, and that the real
  parser reads what its printer prints as its status;
- `versionControlContractFailures`: the version-control contract
  (`Editor/VersionControl/Contract.lean`) against the model, and the git
  implementation's status read of each of its repositories on the job
  model that prints it (`Repository.jobModel`);
- `versionControlGitChecks`, `versionControlWorktreeGitChecks` and
  `versionControlShowChecks`: the git implementation
  (`Editor/VersionControl/Git.lean`) on the job model: the command lines it
  runs for the status and its writes, for worktrees, branches and changes,
  and for `show` and `watched`, their environments and limits, and how it
  reads what they answer;
- `hunkChecks`: the pure core of staging a hunk
  (`Editor/VersionControl/Hunk.lean`) and the patch the git implementation
  feeds `git apply` (`Git.patch`);
- `statusViewChecks` and `worktreeViewChecks`: the pure views of the status
  buffer (`Editor/VersionControl/Status.lean`) and of the worktree list
  (`Editor/VersionControl/Worktrees.lean`), on values the model gives;
- `statusBufferChecks`, `worktreeBufferChecks`, `revisionBufferChecks`
  (`vc-show`, `Editor/VersionControl/Show.lean`), `stageHunkChecks`
  (`Editor/VersionControl/Stage.lean`) and `commitBufferChecks` (the
  message buffer, `Editor/VersionControl/Commit.lean`): the commands, on
  the loop's driver over the editor's models, the job model, the model of
  files and the model of a repository in `/r`, whose git answers as the
  model does;
- `gutterCarryChecks`: carrying a buffer's gutter marks through its edits
  (`Editor/Gutter.lean`), and the gutter column in a view's padding;
- `gutterChecks`: the version-control gutter
  (`Editor/VersionControl/Gutter.lean`) on that driver and the model of
  watches, whose waiting jobs it holds parked: the head fetched, the marks
  of a diff, and what a commit made outside the editor and HEAD moving
  while a fetch or a diff runs change.
-/

namespace ModelTest

open Editor

/-- Every check, in the order they run.

The order matters where the process's one pool is measured. `poolChecks` run
first, on a pool nothing has used. Within `runnerChecks`, the check that
counts the threads jobs wait from comes before any check that holds a job in
pure code on a promise: pure code blocked in `Task.get` on a pool thread
makes Lean add a thread to the pool, which a later burst can land on. -/
def checks : List Check :=
  typedPathChecks ++ poolChecks ++ programChecks ++ jobModelChecks ++ snapshotReadChecks ++
    waitChecks ++
    runnerChecks ++
    tableChecks ++
    ownerChecks ++
    fileRunnerChecks ++
    processChecks ++
    processEnvironmentChecks ++
    environmentLookupChecks ++
    fileWatchModelChecks ++
    fileWatchRunnerChecks ++
    setupChecks ++
    setupHintChecks ++
    registryChecks ++
    registryHintChecks ++
    storeChecks ++
    sessionChecks ++
    reloadChecks ++
    reloadHintChecks ++
    windowTallyChecks ++
    windowLoopChecks ++
    windowArgumentChecks ++
    moduleLookupChecks ++
    headlessCommandLineChecks ++
    executableModeChecks ++
    versionChecks ++
    windowOptionChecks ++
    windowStartChecks ++
    windowReportChecks ++
    undoTreeChecks ++
    textModelStepChecks ++
    fileModelChecks ++
    sceneChecks ++
    modeLineChecks ++
    paddingChecks ++
    faceChecks ++
    displayChecks ++
    frameDisplayChecks ++
    commandPortChecks ++
    watchChecks ++
    clipboardChecks ++
    fuzzyChecks ++
    styleChecks ++
    styleContractChecks ++
    displayContractChecks ++
    completionDisplayChecks ++
    displayStateChecks ++
    syntaxTreeChecks ++
    guardChecks ++
    scrollChecks ++
    blockedScrollChecks ++
    originChecks ++
    heightChecks ++
    layoutChecks ++
    floatChecks ++
    stateChecks ++
    tabChecks ++
    displayRuleChecks ++
    stateRequestChecks ++
    loopChecks ++
    commitChecks ++
    keymapChecks ++
    keyNotationChecks ++
    invocationChecks ++
    exLineChecks ++
    schemeChecks ++
    schemeHintChecks ++
    schemeContractChecks ++
    continuationsContractChecks ++
    keyBindingsContractChecks ++
    dispatchChecks ++
    pressedChecks ++
    vimEditChecks ++
    vimRegistryChecks ++
    vimGrammarChecks ++
    vimStateChecks ++
    vimHintChecks ++
    vimKeyBindingChecks ++
    vimDefaultChecks ++
    vimDefaultHintChecks ++
    vimContractChecks ++
    modeRecordChecks ++
    modeDescriptionChecks ++
    languageMatchChecks ++
    modeRegistryChecks ++
    modeDispatchChecks ++
    modeEnterChecks ++
    highlightFaceChecks ++
    highlightEnterChecks ++
    treeObjectRuleChecks ++
    indentRuleChecks ++
    indentOpeningChecks ++
    indentEditChecks ++
    indentLevelChecks ++
    apiStateChecks ++
    driverChecks ++
    promptChecks ++
    candidateChecks ++
    laterChecks ++
    completionJobChecks ++
    directoryChecks ++
    insertCandidateChecks ++
    pathsChecks ++
    fileNameChecks ++
    laterLoopChecks ++
    sourceContractChecks ++
    keyHintSourceChecks ++
    atPointContractChecks ++
    wordsChecks ++
    atPointStateChecks ++
    keyHintStateChecks ++
    atPointChecks ++
    atPointRepeatChecks ++
    atPointLoopChecks ++
    atPointAskChecks ++
    atPointByItselfChecks ++
    fileCommandChecks ++
    openFilesChecks ++
    languageOpenChecks ++
    dispatchQuitChecks ++
    systemQuitChecks ++
    exChecks ++
    fileReloadChecks ++
    stalenessChecks ++
    autoReloadChecks ++
    bufferCommandChecks ++
    themeChecks ++
    executeCommandChecks ++
    bindingSearchChecks ++
    appearanceChecks ++
    faceVocabularyChecks ++
    solarizedChecks ++
    fairyFlossChecks ++
    evilRestChecks ++
    evilMotionChecks ++
    evilStateChecks ++
    evilInsertChecks ++
    evilOperatorChecks ++
    evilFindChecks ++
    evilSearchChecks ++
    searchDecorationChecks ++
    evilSelectionChecks ++
    evilObjectChecks ++
    evilRegisterChecks ++
    evilOpenChecks ++
    evilIndentChecks ++
    evilUndoChecks ++
    evilRepeatChecks ++
    viewChecks ++
    floatViewChecks ++
    tabBarChecks ++
    frameCommandChecks ++
    windowCommandChecks ++
    tabCommandChecks ++
    titleChecks ++
    menuChecks ++
    clipboardCommandChecks ++
    workspaceDataChecks ++
    workspaceGitChecks ++
    workspaceStateChecks ++
    workspaceChecks ++
    modeMarkerChecks ++
    shellChecks ++
    readOnlyChecks ++
    excerptBufferChecks ++
    excerptDisplayChecks ++
    compileChecks ++
    compileErrorChecks ++
    compileLocationChecks ++
    compileHookChecks ++
    projectFormatChecks ++
    jsonChecks ++
    listingChecks ++
    projectModeChecks ++
    versionControlParserChecks ++
    versionControlPlumbingChecks ++
    versionControlModelChecks ++
    versionControlGitChecks ++
    versionControlWorktreeGitChecks ++
    hunkChecks ++
    versionControlShowChecks ++
    statusViewChecks ++
    statusBufferChecks ++
    worktreeViewChecks ++
    worktreeBufferChecks ++
    revisionBufferChecks ++
    gutterCarryChecks ++
    gutterChecks ++
    stageHunkChecks ++
    commitBufferChecks

end ModelTest

/-- Runs the checks, then the text port's contract against its model, the
job port's contract against its model and against the runner over the fake
clock, the display interface's contract against its model, the watch
port's against its model, the clipboard interface's against its model, the
fuzzy matching interface's against its model, the syntax tree
interface's against its model and the cases of the editor API on the editor's models: exits 0 when all hold,
and 1 after naming on stderr the ones that do not.

It exits explicitly. A check of the job runner that failed may have left a
task that never ends, and returning from `main` would wait for it for ever:
seen once by hand, with a dedicated task in an endless loop. -/
def main : IO UInt32 := do
  let failed :=
    (← ModelTest.failures ModelTest.checks) ++ (← ModelTest.textFailures) ++
      (← ModelTest.adoptFailures) ++
      (← ModelTest.jobModelFailures) ++
      (← ModelTest.snapshotJobFailures) ++
      (← ModelTest.jobRunnerFailures) ++
      (← ModelTest.postFailures) ++
      (← ModelTest.fuzzyJobFailures) ++
      (← ModelTest.fileFailures) ++
      (← ModelTest.processFailures) ++
      (← ModelTest.fileWatchFailures) ++
      (← ModelTest.caseFailures) ++
      (← ModelTest.displayFailures) ++
      (← ModelTest.watchFailures) ++
      (← ModelTest.clipboardFailures) ++
      (← ModelTest.fuzzyFailures) ++
      (← ModelTest.syntaxTreeFailures) ++
      (← ModelTest.apiCaseFailures) ++
      (← ModelTest.workspaceFinderFailures) ++
      (← ModelTest.modeMarkerFailures) ++
      (← ModelTest.versionControlContractFailures)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    -- A check that failed may have left a task that never ends, and
    -- returning from `main` would wait for it for ever.
    IO.Process.exit 1
  IO.println
      s!"model-test: {ModelTest.checks.length} checks passed, {Editor.TextContract.properties.length + Editor.TextContract.adoptProperties.length + ModelTest.commandProperties.length} properties hold of the text model, {Editor.UndoTreeCases.cases.length} cases of the undo tree hold over it, and {Editor.JobContract.properties.length} properties of the job model and of the job runner over the fake clock, and {Editor.JobContract.postProperties.length} post properties of both, and {Editor.JobContract.snapshotProperties.length} snapshot properties of both, and {Editor.JobContract.fuzzyProperties.length} fuzzy properties of both, and {Editor.JobContract.fileProperties.length} file properties of the job model and of the job runner over the fake file service, and {Editor.JobContract.processProperties.length} process properties of the job model and of the job runner over the fake process service, and {Editor.JobContract.fileWatchProperties.length} watch properties of the job model and of the job runner over the fake watch service; {Editor.FileCases.cases.length} cases across the text port and the job port hold of the two models; {(Editor.DisplayContract.properties { advance := 1, lineHeight := 1 }).length} properties of the display interface hold of its model in cells of {ModelTest.displayCells.length} sizes; {Editor.WatchContract.properties.length} properties of the watch port hold of its model; {Editor.ClipboardContract.properties.length} properties of the clipboard interface hold of its model; {Editor.FuzzyContract.properties.length} properties of the fuzzy matching interface hold of its model; {Editor.SyntaxTreeContract.properties.length} properties of the syntax tree interface hold of its model; {Editor.ApiCases.cases.length} cases of the editor API hold of the editor's models; {(Editor.Workspace.FinderContract.properties "/").length} properties of the workspace finder hold of its model and of the finder on the job model; {(Editor.Workspace.MarkerContract.properties "/").length} properties of the mode marker search hold of its model and of the search on the job model; {Editor.VersionControlContract.properties.length} properties of the version-control interface hold of its model, and the git implementation's status read of each of their repositories on the job model"
  (← IO.getStdout).flush
  IO.Process.exit 0
