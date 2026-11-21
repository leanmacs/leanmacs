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
import ModelTest.Editor.Buffers
import ModelTest.Editor.Clipboard.Contract
import ModelTest.Editor.Clipboard.Model
import ModelTest.Editor.Command
import ModelTest.Editor.Command.Append
import ModelTest.Editor.Command.Control
import ModelTest.Editor.Command.Dispatch
import ModelTest.Editor.Command.Registry
import ModelTest.Editor.Completion.AtPointContract
import ModelTest.Editor.Completion.Compiled
import ModelTest.Editor.Completion.Contract
import ModelTest.Editor.Completion.Display
import ModelTest.Editor.Completion.DisplayContract
import ModelTest.Editor.Completion.Displays
import ModelTest.Editor.Completion.Filtering
import ModelTest.Editor.Completion.Keys
import ModelTest.Editor.Completion.Later
import ModelTest.Editor.Completion.Paths
import ModelTest.Editor.Completion.Style
import ModelTest.Editor.Completion.StyleContract
import ModelTest.Editor.Completion.Styles
import ModelTest.Editor.Completion.Words
import ModelTest.Editor.Config.Elaborator.Model
import ModelTest.Editor.Config.LakePackage
import ModelTest.Editor.Config.Lakefile
import ModelTest.Editor.Config.Packages
import ModelTest.Editor.Config.Registry
import ModelTest.Editor.Config.Reload
import ModelTest.Editor.Config.Session
import ModelTest.Editor.Config.Stores
import ModelTest.Editor.Display.Contract
import ModelTest.Editor.Display.Model
import ModelTest.Editor.DisplayRules
import ModelTest.Editor.Evil
import ModelTest.Editor.Evil.Clipboard
import ModelTest.Editor.Evil.Jumps
import ModelTest.Editor.Evil.Marks
import ModelTest.Editor.Evil.Motions
import ModelTest.Editor.Evil.Objects
import ModelTest.Editor.Evil.Operators
import ModelTest.Editor.Evil.Registers
import ModelTest.Editor.Evil.Repeat
import ModelTest.Editor.Evil.TreeObjects
import ModelTest.Editor.Evil.Undo
import ModelTest.Editor.Ex
import ModelTest.Editor.Ex.Compiled
import ModelTest.Editor.Ex.Line
import ModelTest.Editor.ExcerptView
import ModelTest.Editor.Executable
import ModelTest.Editor.Extension
import ModelTest.Editor.Face
import ModelTest.Editor.Face.Vocabulary
import ModelTest.Editor.File.Cases
import ModelTest.Editor.File.Model
import ModelTest.Editor.FileWatch.Model
import ModelTest.Editor.Files
import ModelTest.Editor.Files.Compiled
import ModelTest.Editor.Floating
import ModelTest.Editor.FrameCommands
import ModelTest.Editor.Fuzzy.Contract
import ModelTest.Editor.Fuzzy.Model
import ModelTest.Editor.Grep.Model
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
import ModelTest.Editor.JumpList
import ModelTest.Editor.Jumps
import ModelTest.Editor.Jumps.Go
import ModelTest.Editor.Key.Notation
import ModelTest.Editor.Keymap
import ModelTest.Editor.Language
import ModelTest.Editor.Layout
import ModelTest.Editor.Loop
import ModelTest.Editor.Loop.Driver
import ModelTest.Editor.Marks
import ModelTest.Editor.Marks.Follow
import ModelTest.Editor.Menu
import ModelTest.Editor.Mode
import ModelTest.Editor.ModeLine
import ModelTest.Editor.ModuleLookup
import ModelTest.Editor.PackageSet.Build
import ModelTest.Editor.PackageSet.Edit
import ModelTest.Editor.PackageSet.Fingerprint
import ModelTest.Editor.PackageSet.Running
import ModelTest.Editor.Process.Environment
import ModelTest.Editor.Process.Model
import ModelTest.Editor.Program
import ModelTest.Editor.ProjectMode
import ModelTest.Editor.ProjectMode.Format
import ModelTest.Editor.ProjectMode.Listing
import ModelTest.Editor.ProjectSearch
import ModelTest.Editor.ProjectSearch.Run
import ModelTest.Editor.Restart.Handover
import ModelTest.Editor.Restart.Launch
import ModelTest.Editor.Restore
import ModelTest.Editor.Restore.Compiled
import ModelTest.Editor.Restore.Document
import ModelTest.Editor.Restore.Frame
import ModelTest.Editor.Restore.Indexed
import ModelTest.Editor.Restore.Journal
import ModelTest.Editor.Restore.Restart
import ModelTest.Editor.Restore.Run
import ModelTest.Editor.Restore.Value
import ModelTest.Editor.Restore.Workspaces
import ModelTest.Editor.Scene
import ModelTest.Editor.Scroll
import ModelTest.Editor.Setup
import ModelTest.Editor.Shell
import ModelTest.Editor.State
import ModelTest.Editor.State.Request
import ModelTest.Editor.Store
import ModelTest.Editor.Store.Codec
import ModelTest.Editor.SyntaxTree.Contract
import ModelTest.Editor.SyntaxTree.Model
import ModelTest.Editor.TabBar
import ModelTest.Editor.TabCommands
import ModelTest.Editor.Text
import ModelTest.Editor.Text.Contract
import ModelTest.Editor.Text.Model
import ModelTest.Editor.Themes
import ModelTest.Editor.TypedPath
import ModelTest.Editor.UndoTree
import ModelTest.Editor.Version
import ModelTest.Editor.VersionControl.Blame
import ModelTest.Editor.VersionControl.Commit
import ModelTest.Editor.VersionControl.Compiled
import ModelTest.Editor.VersionControl.Contract
import ModelTest.Editor.VersionControl.Git
import ModelTest.Editor.VersionControl.Gutter
import ModelTest.Editor.VersionControl.HistoryRead
import ModelTest.Editor.VersionControl.Hunk
import ModelTest.Editor.VersionControl.Log
import ModelTest.Editor.VersionControl.Model
import ModelTest.Editor.VersionControl.Plumbing
import ModelTest.Editor.VersionControl.Porcelain
import ModelTest.Editor.VersionControl.Review
import ModelTest.Editor.VersionControl.ReviewHunks
import ModelTest.Editor.VersionControl.Show
import ModelTest.Editor.VersionControl.Stage
import ModelTest.Editor.VersionControl.Status
import ModelTest.Editor.VersionControl.Views
import ModelTest.Editor.VersionControl.Worktrees
import ModelTest.Editor.Watch.Contract
import ModelTest.Editor.Watch.Model
import ModelTest.Editor.Window
import ModelTest.Editor.WindowCheck
import ModelTest.Editor.WindowCommands
import ModelTest.Editor.WorkingSet
import ModelTest.Editor.WorkingSet.Disk
import ModelTest.Editor.WorkingSet.Places
import ModelTest.Editor.WorkingSet.Refind
import ModelTest.Editor.WorkingSet.Run
import ModelTest.Editor.Workspace
import ModelTest.Editor.Workspace.Attach
import ModelTest.Editor.Workspace.Compiled
import ModelTest.Editor.Workspace.Contract
import ModelTest.Editor.Workspace.FindFile
import ModelTest.Editor.Workspace.FindInProject
import ModelTest.Editor.Workspace.Lister
import ModelTest.Editor.Workspace.Projects
import ModelTest.Editor.Workspace.Reach
import ModelTest.EditorCore.EditorPackage

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
small support modules, each of one kind of fixture: under
`ModelTest/Support/`, and, for the ones a package's tests are also written
on, under `Editor/Test/` (the core's test kit, in the namespace
`Editor.Test`, which the core publishes as a test double;
`docs/design/packages.md`, "What a package may import").
`ModelTest.Check` holds the `Check` type and `failures`. Each module
imports the editor's modules and the model test modules it uses, and no
others. Every check list is in the namespace `ModelTest`, so a list is
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
and a watch request goes to the watch model. `registryRequestChecks` and
`controlRequestChecks` pin what a runner answers a question to the
registry and a control request where no loop runs the command
(`Editor/Command/Registry.lean`, `Editor/Command/Control.lean`), and
`dispatchRegistryChecks` the loop's answers to the questions and that
neither sub-port is guarded.

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
the pattern its order is the candidates'; and of a located pattern, its
order among spans of the fewest errors (nearest, earliest, longest) and
that it answers no span that cuts a character. They also show the contract
biting on each of the three things it asks: a matcher written here that
ignores case, one that does not put an exact match first, and locators
that answer nothing or a span with more errors than the fewest.

The completion style interface (`Editor/Completion/Style.lean`) is checked
over the fuzzy model (`styleChecks`): the core's own style, `ranked`,
answers the model's order with no ranges, the model keeps what its
predicate says, and a category picks its style. Its contract
(`Editor/Completion/StyleContract.lean`) is run against the core's own
style and the model (`styleContractChecks`), and seen to bite on a style
that answers an index twice and on one with a range past its candidate's
end; `contract-test` runs it against the core's own style over the real
binding. The styles that ship (`Editor/Completion/Styles.lean`) are checked
over the fuzzy model (`shippedStyleChecks`): the fuzzy style answers the
model's order with its in-order spans, the orderless style matches exactly
the candidates that hold every component of the text, as a property over
every short text and candidate of a small alphabet, the path style ranks
by the last component, and the contract holds of each.

The completion display interface (`Editor/Completion/Display.lean`) is
checked pure (`completionDisplayChecks`): a sheet's text, whether a listing
is grouped, the model, the core's own display, and a category's display
chosen. Its contract (`Editor/Completion/DisplayContract.lean`) is run
against the model, `Display.plain`, and the core's own display
(`displayContractChecks`), and seen to bite on a display with a decoration
past its row's end. The minibuffer display's rule
(`Editor/Completion/Displays.lean`), the one that ships, is checked pure
(`minibufferDisplayChecks`): the row cap, the faces of the chosen row and
the others, the matched ranges and their offsets in the sheet, a label in
place of the text, the annotation column, the group headers, the window
round the choice, the contract at 0, 1, 3 and 10 rows, and its five faces
in the vocabulary.

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

A window's jump list as plain data (`Editor/JumpList.lean`) is checked
pure, over line numbers (`jumpListChecks`): a record appends and drops the
oldest past the limit, a filter-map changes and drops entries and carries
the index, a clean-up keeps the latest entry of a line and carries the
index, a step's plan records first from one past the end and
fails off either end, and `:help jumplist`'s worked example step by step.

The rules of marks across line deletions and undo (`Editor/Marks.lean`)
are checked pure (`markRuleChecks`): a place's marker is an anchor with
the bias `after`; a deletion of a whole line with its
line break removes it and one of part of it does not, the row an edit
starts at the start of only when the edit stops at a row's start, the last
row only with the line break before it; a node made keeps the marks at the
boundary, an undo and a redo across it put back what it kept and swap in
the marks before the move, and a move across more than one edge or to
another tree puts back nothing. The loop's following of the editor
state's marks (`Editor/Marks/Follow.lean`) is checked on the text model
(`markFollowChecks`): a mark whose line an edit removed is erased, and one
a command decided about is not; the marker a mark put back replaced is
given up; an excerpt buffer's marks are not followed; a buffer whose text
refuses is left as it was, the others followed and the refusal handed
back; `BufferId.followMarks` erases, leaves an excerpt buffer alone and is
refused by a text that refuses; and, through the loop, a mark's marker is
given up once the mark is erased by a charwise delete or by `dd`, or put
back by an undo, and `m a` on an excerpt buffer sets a mark a charwise
delete across its line keeps.

The editor state (`Editor/State.lean`) is checked on the text model
(`stateChecks`): the initial state, that the rectangles of its views are
the layout's above the minibuffer's strip, and the layout operations, each refused with the state as it
was when it would break an invariant. The places of jump lists and marks
(`placeChecks`, part of `stateChecks`): the defaults, each set and read and
refused, a split's copy of the jumps, a removed buffer's places dropped,
what a buffer keeps beside its marks set, the place markers listed
once, and those a state after no longer holds
given up (`givenUpPlaces`). The invariants themselves are checked
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
`stateChecks` also checks a buffer marked as restored, and that every change
of the workspace table bumps its revision, a restored table among them.

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
view alone. A restored frame (`restoreFrameStateChecks`): its tabs, windows,
next view, chosen layout and most recent buffer set, what is frame-wide
kept, a float at a position held by the marker handed, and each refusal,
`malformed` for each break of `wellFormed` and `promptOpen`, leaving the
state as it was. The tab commands (`Editor/TabCommands.lean`) are checked by
key under the Vim scheme that ships (`tabCommandChecks`): tmux's keys under
`C-w`, the prompts of `tab-switch` and `tab-rename`, each command acting on
the tab of its call's window, and a publish's layout reaching the tab in
view alone. The tab bar (`Editor/TabBar.lean`) is checked by `tabBarChecks`:
its line, its strip, and the view a publish draws it in.

The command loop (`Editor/Loop.lean`) is checked on the editor's models
(`loopChecks`): events fed to `Loop.step` one by one, the state each leaves
(a layout a restore holds passed over until config installs past it among
them)
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
  and a mark of the saved state is; and the recorded departure of task
  `places-restore-on-rollback`, a mark and a jump entry inside the deleted
  text carried to the end of the text put back;
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
  its end, and not before: a closed window's markers, the markers of a
  jump list's entries and marks no place holds any more, before a removed
  buffer's text, a removed buffer's text, the snapshot of a save that is no longer in flight, and the
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
  before it, and a delay of another generation that changes nothing; and
  a journal order the file model refuses is kept, its path and why, with
  the orders after it still handed;
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
  written here: first, that a prompt matched by a style and drawn by a
  display written here, neither shipped, registered in a registry the loop
  is handed, lists what the style keeps, draws the display's rows and
  accepts the chosen one; then, matched and drawn by the style and the
  display written for the core's tests (`marking` and `windowed`,
  `ModelTest/Support/Listings.lean`), the listing the loop makes before
  each scene, for the
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
- `filteringChecks`: a source a command filters
  (`Editor/Completion/Filtering.lean`): its job on the job model with
  canned process answers, the lister then the filter fed its output with
  the typed text as one argument, the first records delivered in one batch,
  a cut head's whole records, the no-matches statuses, a lister's
  partial-listing statuses and the failures naming the program, a lister's or a filter's time-out among them; and through the loop on the driver, a new text
  cancelling the old generation, a stale batch never listed, the filter's
  order kept with the style's ranges, and a missing filter said in the
  echo area;
- `sourceContractChecks`: the completion sources' contract
  (`Editor/Completion/Contract.lean`) on the model, the fake, each source
  the core ships but the command prompt's and the binding search's, which
  their own lists hold to it, and the key hints' source, run on the kit's
  runner over `twoBuffers` and the editor's models
  (`Editor.Test.sourceRunner`, `Editor/Test/Sources.lean`), and seen to
  report a source that writes and one that is refused;
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
- `jumpChecks`: a window's jump list held by markers (`Editor/Jumps.lean`)
  on that driver, over the model of files: a record, an entry following
  edits before it on the text model, entries edits brought onto one line
  being one at the next move, a move past either end, a closed buffer's
  places detached into its file or dropped, attached again when the file
  is loaded, opening a file, a visit and switching buffers each recording
  a jump, a visit at a row's first non-blank or that records none,
  deleting rows erasing their lowercase marks, and keeping the first
  row's as decided;
- `jumpGoChecks`: going through the list to another buffer or a closed
  file (`Editor/Jumps/Go.lean`) on that driver: the index moving at once,
  the cursor at the entry once the load lands, and no entry recorded by
  the visit of a `C-o` or of a jump to a place;
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
- `faceVocabularyChecks`: the face vocabulary (`Editor/Face/Vocabulary.lean`)
  names each face once with its meaning, and lists every face the shipped
  Vim scheme and the loop draw, layout's four and the faces declared
  ahead; the completeness check (`Editor/Themes/Check.lean`) finds each
  problem in a theme spoiled from the built-in one, a cursor colour that
  falls through to the default face's among them; one palette mapping over
  two palettes gives two complete themes; and the built-in theme is
  complete, pads the mode line and the echo area and defines the tab bar's
  faces.

The palettes that ship are a package outside the core
(`packages/shipped-themes/`), and their checks are its own
(`ShippedThemesTest.shippedThemesChecks`, `.solarizedChecks`,
`.fairyFlossChecks`).

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
  bindings (in a prompt category too, and of keys given as values), the leader and the localleader, modes, ex bindings and faces,
  a job given as its work, an ex name's fixed arguments and menus, a
  store's codec across a restart and a job reported as stopped by one, and
  when it is refused;
- `setupHintChecks`: a binding's description (`bindKey`'s `desc`) and a
  prefix's name (`prefixName`), as a `setup` collects them, and the names
  it refuses;
- `registryChecks`: the registry, its commands, its jobs, its key
  bindings, its modes, its ex bindings and its faces, replaced by owner,
  and the keymap it makes, its bindings expanded against the leaders in
  force and bound by where they hold, and the bindings a scheme's leaders
  make one sequence, which are refused; a prompt category's keymap, first
  among the open prompt's minibuffer view's active keymaps and out of the
  global keymap and the menu bar's, and a sequence bound twice in one
  category, which is refused; its menus, replaced by owner, and the
  menu bar they make (`menuBar?`); its store codecs across a restart,
  the latest owner's found, and the jobs reported by one, as the loop is
  told them; and the style and the display a prompt gets with no choice:
  the one registered first, config's of that name in its place, or with
  none registered the core's own, owned by `compiled`;
- `registryHintChecks`: a binding's description on the registry's keymap,
  and its prefix names, by owner, expanded against the leaders in force,
  and two names a scheme's leaders make one prefix, which are refused;
- `storeChecks`: the rule that meets a new config's stores with the cells
  there are, one check for each case, and that it is the install rule
  `StoreDeclaration.meet` with the owner and name filled in; and an install
  with cells a restore parked;
- `storeCodecDeclarationChecks`: that install rule over a version and a
  tree (`Editor/Store/Codec.lean`), pure, one check for each case;
- `storeCodecChecks`: a store's codec across a restart (`Store.codec`),
  which keeps what its `keep` keeps and answers none for a tree its
  decode refuses;
- `sessionChecks`: one reload (`Config.build`), on the elaborator's model
  and a source held in memory, built for the test scheme: the order a
  config's files are elaborated in and what each is handed, which files a
  reload keeps (after a change to one file, that file and the files that
  import it are elaborated, and no other), the base grown by a linked
  module a file imports, what is refused before anything is elaborated (a
  module that is not linked, with what the config's lakefile says of it, in
  a host with no package port and in one with no generator too; a config
  file that is not there; a cycle; a config in the old form; a root spelt
  `Init.lean`, which is a misspelt root and not the old form), the generated
  lakefile and toolchain file, what an outcome carries, and what every
  reload reads of the config directory as a package set (`packageFacts`);
- `lakePackageChecks`: the config directory as a Lake package
  (`Editor/Config/LakePackage.lean`): the generated lakefile's text, and
  what is done about the lakefile and the toolchain file given what the
  directory holds;
- `lakefileChecks`: the library a package's modules are under, and which
  of a lakefile's requires a module belongs to
  (`Editor/Config/Lakefile.lean`);
- `elaboratorContractChecks`: the elaborator port's contract
  (`Editor/Config/Elaborator/Contract.lean`) held of its model, which
  `config-test` holds of the real adapter; `elaboratorModelChecks`: the
  edges of the model's language, and a base asked to hold a module that is
  not linked;
- `reloadChecks`: the reducer that serialises reloads, with outcomes built
  by hand. The phase's acceptance tests are here on fakes (reload replaces a
  command, a rejected reload keeps the old config, a reload does not
  double-register, a store value survives a reload), and `config-test` runs
  them again with the real elaborator, queue and text binding. The reducer
  also says when the old config's jobs are cancelled: when a reload
  installs, and only then; and what the theme is: the built-in one then the
  installed config's faces, replaced as a set by an install and kept by a
  rejected reload. An install replaces config's key bindings, modes and ex
  bindings and keeps the compiled ones, and replaces config's menus and
  keeps another owner's. The cells a restore kept for config are parked and
  met at its first install that declares them with a codec, or dropped and
  said; the cells' revision moves with each writer; and a package's
  declared store goes through the host's half (`restoreCells`,
  `keptCells`). A reload whose package set differs from the running
  editor's starts one build after its report and keeps what it read; none
  while a build is in flight, whoever started it, and one again once it
  ended; none for a reload that matches; and what it has to say instead
  (no `lake`) is said once;
- `reloadHintChecks`: an install replaces config's descriptions and prefix
  names with its bindings, so a later config without them clears them;
- `packageChecks`: packages (`Editor/Package.lean`) and registering them
  (`Editor/Config/Packages.lean`): a package's registrations of every kind
  belong to the owner named after it; packages register in the order of
  the array, and of one name the later package's is found; a package with
  a reserved, empty or repeated name, one whose `setup` is refused and one
  that sets what only config may choose register nothing and are reported
  by name, and the others register; a reload leaves a package's entries,
  its style default and its store's cell; config's command and binding
  replace a package's until a reload drops them; a package's
  `useStyleFor` is a default config's `useStyleFor` overrides; and of two
  packages that contribute one compile mode the later package's is the one
  listed, once, where the mode was first registered;
- `extensionChecks`: extension points (`Editor/Extension.lean`), laid out
  as an interface package, two implementation packages and a consumer:
  values two packages register at a point come back typed, in
  registration order, to a consumer that names neither; a value's fields
  are programs over the editor's port; a point nobody registered at holds
  nothing, bare too; a value is registered at its own type's point only;
  a reload replaces config's values and keeps a package's; and `named`
  finds the latest value of a name, config's over a package's;
- `completionPackageChecks`: the package of what ships in core modules
  registers it, in order: the shipped styles and displays
  (`Editor/Completion/Compiled.lean`). The shipped segments are the
  default package `mode-line`'s (`packages/mode-line/`), and the `code`
  mode with the shipped languages the default package `languages`'
  (`packages/languages/`), whose own tests hold them
  (`ModeLineTest.modeLinePackageChecks`,
  `LanguagesTest.languagePackageChecks`);
- `exPackageChecks` and `versionControlPackageChecks`: each package binds
  its own ex names, in order: the `ex` package the files', its own and the
  buffers' and no other (`Editor/Ex/Compiled.lean`), and the
  `version-control` package its twelve, the gutter's package none
  (`Editor/VersionControl/Compiled.lean`), each to a command it registers;
  the compile mode's six are its package's, outside the core
  (`CompileTest.compilePackageChecks`, `packages/compile/`); and the
  gutter's three jobs restarted by their owner, none of version control's;
- `filesPackageChecks`, `workspacePackageChecks` and
  `restorePackageChecks`: which jobs each package leaves to its owner to
  start again after a restart, never counted as stopped: the `files`
  package `check-files` and `follow-file` (`Editor/Files/Compiled.lean`),
  the `workspace` package `find-workspace`, `find-mode-markers` and
  `compile-list` (`Editor/Workspace/Compiled.lean`), and the `restore`
  package its four (`Editor/Restore/Compiled.lean`);
- `packageSetFingerprintChecks`: a user's package set's fingerprint
  (`Editor/PackageSet/Fingerprint.lean`): each require's line, a path
  made absolute and normalised; the manifest's git pins, read from a
  manifest a real `lake update` wrote, its path entries left out; the
  comparison, which ignores the set's name and a manifest's path entries;
  the record `editor.packages` and its read; the shipped default's
  fingerprint, which a generated lakefile matches; a `lakefile.lean`
  known by its hash; and the root's own-core require left out, by any path
  that resolves to the running core against the config directory
  (`namesCore`, which the edits and the build's core check share);
- `packageSetRunningChecks`: what the running editor knows of its own
  package set (`Editor/PackageSet/Running.lean`): the records beside it,
  or in an app bundle's `Contents/Resources`, the shipped fingerprint with no `.packages` record and the recorded one
  with one, and the toolchain's `lake` only when it is there;
- `packageSetEditChecks`: the edits of a config's `lakefile.toml`
  (`Editor/PackageSet/Edit.lean`), on exact texts: where each require's
  table is, install of a path, a git and a Reservoir require, remove, the
  default set expanded without one of its packages, a rev set, each
  refusal, and the core's require at the root through the one composition
  the commands make each edit through (`withCoreEdit`): a set-only
  lakefile repaired, a git or other-path core replaced, a repaired
  lakefile a fixed point, a relative path to the running core taken for
  it as the fingerprint takes it, and `editor-core` refused to install,
  rev and remove through it;
- `packageSetBuildChecks`: a user's package-set build and its commands
  (`Editor/PackageSet/Build.lean`, `Editor/PackageSet/Compiled.lean`):
  when a reload starts it and when it says it cannot, an editor in a
  bundle starting none for the lakefile generated for it; the order carried
  as text; the requires resolved; the user's Lean, Lake and compiler
  variables removed from every command it runs, and the build record set
  over them; git required and absent or failing, for
  a git and for a Reservoir dependency;
  Cargo required for a Rust crate and none run for a set with no crate; a
  failing build shown, its staging directory removed and nothing
  published; macOS refusing a bundle's lake at lake update, lake query
  and lake build, decided in one place (`LakeFailure.of`); a failing
  probe; the core check, a relative entry resolved against the config
  directory; a success that writes the record, publishes version 1 and
  restarts into it; what is pruned, never the running
  editor's version; the three commands'
  edits, their refusals and the reload after them; and `:package-update`
  with no rev repairing a lakefile without the core's require at its root
  first, through the edit job, and starting the build on a repaired one;
- `packageSetChecks`: the packages of the core's Lake package, its entry
  module (`EditorCore/EditorPackage.lean`, a module outside `Editor/`,
  whose test module is `ModelTest/EditorCore/EditorPackage.lean`): the
  list is the 24 packages, in order, each accepted, with no package of
  the shipped palettes or of the compile mode among them, in the state
  they make every entry's owner is one of them, the ex names are bound in
  the order the headless fixtures show, the `ex` package's and then
  version control's, and the one theme is `default`; and the set keeps
  exactly the shell's history and version control's reviews across a
  restart, reports exactly the jobs a person waits on, and leaves exactly
  the files' check and follow, the workspace's find, marker search and
  listing, the restore's four and the gutter's three to their owners to
  start again.

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
  invocation, a command's with a character first, and what an edit says
  of itself;
- `vimRegistryChecks`: the registry of Vim states: looking a state up by
  its name, and registering one. A record holds keymaps and so has no
  equality: the checks compare records by their fields (`vimSeen`);
- `vimGrammarChecks`: the grammar: which keymaps a key is looked up in,
  and what a key sequence parses to and yields, a command that takes a
  character (`m`) among them;
- `vimStateChecks`: Vim states: which state a view is in, how one is
  entered, what the scheme reports of a view in a state, what the grammar
  reads of a state's record (typed text, an operator over the selection),
  the last change, and a mode's keys under the Vim scheme: a hand-tuned
  key is typed text in insert state, and `Mode.check` reads every state's
  keymaps; and a command that takes a character awaiting it, and never
  the last change;
- `vimHintChecks`: what the Vim scheme lists as able to follow a keymap
  prefix (`Vim.State.continuations`): keys of both tiers, an active prefix
  over a state's binding, the pending keymaps while an operator waits, and
  nothing after a count, an operator, the register prefix or a command
  that takes a character alone;
- `vimKeyBindingChecks`: the key bindings the Vim scheme lists
  (`Vim.State.keyBindings`): the commands of the walk's tiers in the view's
  state, an active binding first with its description, and no part of
  speech, no command that takes a character by its key alone, no sequence
  that begins with a count digit, no mode's binding
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
  the change left; and `u` at the root of a buffer a restore made, which
  says its history starts there. They are the phase's rule and are not compared with
  Vim, which leaves the cursor at the start of the changed text;
- `evilRepeatChecks`: `.` after a change of each kind (`repeatRows`), a
  count before it, a change with an insert session and its typed and
  committed text, the editing keys of insert state in a session
  (`insertKeysRepeatRows`), and what is not repeated;
- `evilJumpChecks`: `C-o`, `C-i` and `TAB` through the jumps that `gg`,
  `G`, the searches and `%` record (`Editor/Evil/Jumps.lean`), to the
  exact column, with a count, under an operator, as `:help jumplist`'s
  example scaled to eight lines, an entry following lines inserted above
  it, a failed search and the motions that are no jump recording nothing,
  and a split's copy of the list moved through on its own;
- `evilMarkChecks`: `m`, `` ` `` and `'` (`Editor/Evil/Marks.lean`): a
  mark set and gone to, exactly and at its line's first non-blank, as a
  jump, under an operator, after an insert above it, the marks not set or
  not named, `''` back and forth, a jump that leaves the cursor in place
  keeping `''`, `m '` and ``m` ``, a mark motion run in a window
  that is not focused, and across buffers on the file model: a buffer's
  own marks, a global mark in another buffer, under an operator, in a
  closed buffer's file, reopened with one jump recorded, attached again to
  the reopened buffer's text so that an edit above it carries it, and
  dropped with a closed buffer that held no file; a mark erased when its
  line is deleted, on the last line too, a global mark kept on the line
  that takes its place, kept by a
  deletion of part of its line, kept on the first line of `3cc` and of a
  charwise delete across lines, kept on the first line of `cj` and `2cc`
  above an empty line, erased by `3dd` on every line, by `dd` on
  a text's only line and by `3cc` on the lines after the first, kept by
  `cc` on the only line and by a redo of its `dd`, put back by undo at its line and column,
  erased again by redo and put back again by undo, and put back step by
  step by a counted undo and redo (`markUndoRows`); and
  the recorded departures, one check each named for its task: a line's
  marks erased by the edit's shape, text typed at a mark, a
  global mark's column on a deleted line, the numbered marks, the change
  marks, the visual marks, the marks of the last change and insert, the
  mark of the last exit, the sentence and paragraph marks, `m` in the
  visual states, `:marks` and `:delmarks` on the ex line, `g'` and
  ``g` ``, `]'`, `['`, ``]` `` and ``[` ``, `:mark` and `:k`,
  `:lockmarks` and `:keepmarks` on the ex line, global marks
  kept in the session alone, a lowercase mark with its buffer closed, and
  `` ` ` `` after a jump into another buffer;
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
- `versionControlHistoryParserChecks`: the readers of git's history
  (`Editor/VersionControl/HistoryRead.lean`): a log, a blame with two
  authors and a commit named twice, and a range-diff of each relation, on
  fixtures, and what each refuses;
- `versionControlModelChecks`: the model of a repository: its status of
  each state, how it pairs renames, what its writes do, and that the real
  parser reads what its printer prints as its status;
- `versionControlContractFailures`: the version-control contract
  (`Editor/VersionControl/Contract.lean`) against the model, and the git
  implementation's status read of each of its repositories on the job
  model that prints it (`Repository.jobModel`);
- `versionControlGitChecks`, `versionControlWorktreeGitChecks`,
  `versionControlHistoryGitChecks` and `versionControlShowChecks`: the git
  implementation (`Editor/VersionControl/Git.lean`) on the job model: the
  command lines it runs for the status and its writes, for worktrees,
  branches and changes, for a log, a blame, a range-diff and a change
  against no base, and for `show` and `watched`, their environments and limits, and how it
  reads what they answer;
- `hunkChecks`: the pure core of staging a hunk
  (`Editor/VersionControl/Hunk.lean`) and the patch the git implementation
  feeds `git apply` (`Git.patch`);
- `reviewHunkChecks`, `reviewOrderChecks` and `reviewRecordChecks`: the
  pure core of the review buffer (`Editor/VersionControl/ReviewHunks.lean`):
  a change's hunks with their context and git's numbers, on strings; the
  order of a change's files, over the change the version-control model
  gives; and the record, its counts and the hunk at an offset;
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
  while a fetch or a diff runs change;
- `reviewBufferChecks`: the review buffer
  (`Editor/VersionControl/Review.lean`) on that driver (and `vc-review`
  kept across a restart without its buffer's number), its read run over
  the version-control interface's model (`Model.readHandler`): the four
  criteria of the excerpts roadmap's phase 4, its refusals, refresh, the
  old buffers a round that ends early removes, the rounds its store keeps,
  the commit each records and the store's migration, edits through its
  excerpts, a commit's review, and `vc-review-since`, into a review buffer
  and, past a rewritten branch, the range-diff buffer;
- `logViewChecks` and `logBufferChecks`, `blameViewChecks` and
  `blameBufferChecks`: the log buffer (`Editor/VersionControl/Log.lean`)
  and the blame view (`Editor/VersionControl/Blame.lean`), their pure views
  on values and their commands on that driver, their reads over the
  interface's model: what each lists, with each commit's author, and the
  review a row's visit opens;
- `versionControlViewsChecks`: what the version-control buffers share
  (`Editor/VersionControl/Views.lean`), on values: a day as the log's and
  the blame's rows show it;
- `excerptViewedChecks`: what a view shows of a tracked excerpt
  (`Editor/ExcerptView.lean`) and the marking of what was viewed
  (`EditorState.markViewed`, `creditViewed`), on hand-built rows and
  entries; the loop's marking and the face of what was not examined are
  among `excerptDisplayChecks`, on the loop's driver.

What a minor mode contributes for a kind of project is the core's, and the
compile mode is one reader of it (`docs/design/packages.md`), so each side
has its own checks and no check of the core's names the compile mode:

- `contributionChecks`: a contribution as data (`Editor/ProjectMode.lean`),
  pure: its defaults, its marker mode, and a hook's project commands and
  settings by a project's identity;
- `formatDataChecks`: an error format as data
  (`Editor/ProjectMode/Format.lean`), pure, with no matcher: the
  severities' names, a step and an optional step, a format's defaults, the
  general format's parts, and the two tree helpers;
- `listingChecks`: a contribution's computed commands
  (`Editor/ProjectMode/Listing.lean`), on the loop's driver over a host
  handed core packages' commands and jobs only: a mode that turns on runs
  its listing once in its root, a failed listing keeps why and says it
  once, what is kept where, no listing where commands cannot run, each end
  of a run's words, and an order's and an entry's round trip.

What the compile mode makes of them is checked in its package
(`packages/compile/CompileTest/`): `CompileTest.compileOfferChecks`,
`.compileListedChecks`, `.compileHookChecks`, `.projectFormatChecks`,
`.projectModeChecks` and `.miseTaskChecks`, which were this executable's
until the compile mode moved out of the core, with `.compileChecks`,
`.compileErrorChecks`, `.compileLocationChecks` and
`.compilePackageChecks`.
Working sets (`Editor/WorkingSet.lean` and its modules) are checked in Lean
alone too:

- `workingSetChecks`: the stored form, pure: the document's JSON round trip
  and the refusals of one it cannot read, a newer version first; a
  workspace's key; a range captured from a text and its points found
  again; the headers; and the excerpts' grouping by file and merging;
- `workingSetRefindChecks`: the re-find ladder
  (`Editor/WorkingSet/Refind.lean`), against the fuzzy model: exact, moved
  past lines inserted above, the copy whose context matches over the
  nearer one and the nearer of two alike, changed with one character
  edited, drifted when deleted and when a short quote was edited, a long
  quote found by its ends or drifted without its last lines, text that is
  not ASCII, and a stored point past the text's end;
- `workingSetPlaceChecks`: where a range is held while the editor runs
  (`Editor/WorkingSet/Places.lean`), on the loop's driver over the models
  with a workspace at `/r`: a held range follows edits through its
  markers, closing its buffer detaches it as edited, opening the file
  again holds it again, or leaves it drifted when another program removed
  its text, and nothing is attached while the workspace's sets are not
  read;
- `workingSetRunChecks`: `working-set-add` and `working-set-open`
  (`Editor/WorkingSet/Run.lean`) on that driver, the first acceptance
  criterion of navigation-and-windows phase 5: a linewise selection added
  and opened as the set's buffer, edited through it, visited and returned
  from; a row of project search's results pinned as its file's range; a
  selection across two files refused; a cursor's row; a range added twice;
  overlapping ranges in one excerpt; the prompt; a set there is none of;
  and `working-set-remove`, `working-set-note` and `working-set-refresh`
  in the set's buffer;
- `workingSetDiskChecks`: the sets on disk (`Editor/WorkingSet/Disk.lean`)
  on that driver with the state directory `/state` and the version-control
  interface's model at `/r`, the second acceptance criterion: three ranges
  written with `HEAD`'s commit; a fresh editor over the same files, one of
  them edited by another program, opening the set as a changed, a moved
  and a drifted range; the drifted form not moved by a later write; memory
  only with no state directory; a newer or unparsable store left alone; no
  repository; and the writes a save and a close make.

Session restore is checked in Lean alone too:

- `journalFormatChecks`: a buffer's journal (`Editor/Restore/Journal.lean`),
  pure and over the text model: a log of a header and records round-trips
  through its bytes, a byte that is not UTF-8, a NUL and every width of
  character among them; a torn last line dropped and said; a line of an
  unknown kind or a newer format stops the reading before it; a log with no
  header; and edits read from a text's log and replayed make the text.
- `restoreDocumentChecks`: the session index
  (`Editor/Restore/Document.lean`), pure: the round trip, and format 2's
  with every key it added, a kept place's run and the other jobs' count
  among them; a format-1 index as phase 1 wrote it read
  fully; a newer format's keys inside the frame passed over; a format-2
  index stripped to format 1 reading as the same buffers; a store, job,
  frame or workspaces entry that does not parse said; a newer
  format read leniently with each unknown key named; a bad entry skipped; a
  file that is not JSON; which index is restored (the highest run, whatever
  its format, none when it ended) and which are removed or left; the next
  run's number; and the names of indexes and journals.
- `restoreValueChecks`: a plain tree as the session index writes it
  (`Editor/Restore/Value.lean`), pure: every kind round-trips through its
  JSON, rendered and parsed, nested, a record's fields in order and a name
  twice, negative integers and big naturals, a NUL, bytes that are not
  UTF-8 and multi-byte characters; JSON that is no tree read as none; and
  the shipped stores kept across a restart, initial and populated.
- `restoreFrameChecks`: the frame as the session index records it
  (`Editor/Restore/Frame.lean`), pure and on the text model: its JSON
  round trip over every layout, anchor and a zoomed, named tab, a newer
  key passed over; renumbering; each record `check` refuses; and the
  record of a state of two tabs with splits, a docked window, a float at
  a position and a window elsewhere.
- `restoreWorkspaceChecks`: the workspace table as the index records it
  (`Editor/Restore/Workspaces.lean`), pure: the JSON round trip of each
  identity, location and branch; only cells with a codec, through its
  keep; a restore that meets, migrates, resets and parks; a kept cell met
  into each scope with its loss line (`Workspaces.meetInto`); restore then
  record; and parked cells carried back into their stores.
- `restoreOffsetChecks`: where a recorded spot is put back
  (`Restore.offsetOf`, `Editor/Restore/Indexed.lean`), on the text model: its
  column in bytes, after a multi-byte character, clamped past the row's
  content, moved back from inside a character, and a row past the last.
- `journalReconcileChecks`: the journal's reconciler
  (`Editor/Restore.lean`) on the loop's driver over the models with the
  state directory `/state`, each read from the file model, decoded and
  replayed: from an empty state directory the restore makes the journals'
  directory, and typing gives one record per event; a buffer that did not
  move gets none; a save, an undo to the saved state and a close remove the
  journal; the bound and a forgotten log give a new generation; a save
  while modified gives a new header stamp; read-only, excerpt and
  minibuffer buffers are never journalled; no state directory journals
  nothing; a leave removes everything and saves the index ended; the index
  write fires once for a burst; every window's place is recorded; the
  index after a split, a tab and a jump carries the frame and the jumps;
  a change of the host's cells is mirrored and written once, and an
  unchanged revision reads nothing; a parked table cell an install
  registers no codec for dropped, said once, and gone from the next index;
  one whose codec refuses its value reset and the loss said; an install
  that settles a deferred mode no config registers as well says both, in
  one sentence, whether the cell is dropped or reset; a reported
  job's start and end each change the jobs listed; the other jobs counted
  are those neither reported nor restarted, whoever registered them; and a
  change of their count alone starts no write, the next write recording
  it.
- `restoreChecks`: restoring a session (`Editor/Restore/Run.lean`) on that
  driver, from what a first loop wrote or a check wrote by hand: buffers,
  texts, line endings, modes and the focused cursor come back; a file
  changed on disk is restored marked, its first edit and its save refused;
  an unmodified file reopened and a gone one said; journals of a run with no
  index, one with no header, and two of one name; the new bases before the
  stale files' removal; the other windows put back with the frame, or,
  from an index with none, their places kept and written again, and never
  taken for a later run's window of the same view id; the
  version rule end to end; a mode only config registers deferred until it
  installs, or said when it does not register it; a cursor after a
  multi-byte character put back where it was; and phase 2's: (a) windows
  and layouts and (b) tabs back as they were up to their ids, (c) the jump
  list: at its end and in its middle with an entry before the index
  dropped, an entry in a kept buffer with no file, one in a file no buffer
  keeps, and one in the file of a buffer restored, held there again, each
  window's C-o and C-i going where the first loop's went, (d) every
  restored buffer marked with no history before the restore, (h) a frame
  refused falling back to phase 1's placement, (i) a
  window of a buffer not kept showing scratch, said, (e) the workspace
  table and (f) its stores, met, never written or parked and claimed, (g)
  a reported job said stopped and the host's count of other jobs said,
  other jobs alone counted, and (j) a package's declared store met with its
  codec.

Listing a workspace's files is checked in Lean alone too:

- `workspaceListerChecks`: which command lists a workspace's files
  (`Editor/Workspace/Lister.lean`), pure: config's lister for the root,
  then for the project, then git's for a workspace git found, then the
  fallback; their exact command lines, the fallback's records without
  `./`, its exit 1 a partial listing and no other's, and a lister as plain
  arguments;
- `findFileChecks`: `find-file-in-workspace`
  (`Editor/Workspace/FindFile.lean`) on the loop's driver over the
  editor's models and the job model of the workspace driver's world, each
  lister and filter scripted by its exact command line: the eight criteria
  of project navigation's phase 2, the lister run in the buffer's workspace
  alone, config's listers, the fallback, the accept through `open-file`,
  an absolute typed answer opened as it is, a refused prompt said,
  the label, the working directory of a buffer with no workspace, the
  refusals, that no step runs a process, a fallback that exits 1
  still listing what it printed, and the text after a location typed
  into the input, the list opened matched against it;
- `projectWorkspaceChecks`: the project's workspaces
  (`Editor/Workspace/Projects.lean`), pure: the worktrees in the reply's
  order, those not found labelled by `Workspace.labelOf`, then the table's
  others, one per location, the current one last; the table's label for a
  worktree it knows, a detached worktree by its directory, two entries of
  one label told apart by their annotation, and what is asked through its
  arguments' round trip, and split from what follows it;
- `findInProjectChecks`: `find-file-in-project`
  (`Editor/Workspace/FindInProject.lean`) on the finder checks' driver,
  with `/r`'s repository model and a third worktree `/u`: the five
  criteria of project navigation's phase 3, the three worktrees listed by
  `name@branch` with no file opened in two of them, the choice reaching
  `find-file-in-workspace` rooted there, by a choice or by a typed text,
  a worktree first reached added with the finder's identity and branch
  and found once, a gone worktree said, a registered workspace listed and
  refused, two of one label told apart, no project said, a project with
  no git, a failing worktree list said, and one that fails only when the
  accept lists again said by the command, with no prompt and no find; and
  the four criteria of phase 4: the escape key in the finder opening the
  picker, the choice opening the finder with the typed text, through a
  reach or the table, the key doing nothing new in any other prompt, under
  the Vim scheme too, and config's key in the category stepping out;
- `reachChecks`: reaching the workspace at a path the table has no
  answer for (`Editor/Workspace/Reach.lean`), with a probe continuation,
  on the workspace driver: the find job started and its answer recorded
  and handed on, a cached answer handed on with no job, a path in no
  repository said by the gone sentence and cached, an unregistered job
  said under the continuation's name, the arguments a caller carries
  through the find job handed on, and the order's round trip.
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
    grepModelChecks ++
    grepRunnerChecks ++
    setupChecks ++
    setupHintChecks ++
    registryChecks ++
    registryHintChecks ++
    storeChecks ++
    storeCodecDeclarationChecks ++
    storeCodecChecks ++
    sessionChecks ++
    lakePackageChecks ++
    lakefileChecks ++
    elaboratorContractChecks ++
    elaboratorModelChecks ++
    reloadChecks ++
    reloadHintChecks ++
    packageChecks ++
    extensionChecks ++
    completionPackageChecks ++
    exPackageChecks ++
    versionControlPackageChecks ++
    filesPackageChecks ++
    workspacePackageChecks ++
    restorePackageChecks ++
    restartChecks ++
    restartHandoverChecks ++
    restartLaunchChecks ++
    packageSetChecks ++
    windowTallyChecks ++
    windowLoopChecks ++
    windowArgumentChecks ++
    moduleLookupChecks ++
    packageSetFingerprintChecks ++
    packageSetRunningChecks ++
    packageSetEditChecks ++
    packageSetBuildChecks ++
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
    registryRequestChecks ++
    controlRequestChecks ++
    watchChecks ++
    clipboardChecks ++
    fuzzyChecks ++
    styleChecks ++
    styleContractChecks ++
    shippedStyleChecks ++
    displayContractChecks ++
    completionDisplayChecks ++
    minibufferDisplayChecks ++
    displayStateChecks ++
    syntaxTreeChecks ++
    guardChecks ++
    scrollChecks ++
    blockedScrollChecks ++
    originChecks ++
    heightChecks ++
    layoutChecks ++
    floatChecks ++
    jumpListChecks ++
    markRuleChecks ++
    markFollowChecks ++
    stateChecks ++
    tabChecks ++
    restoreFrameStateChecks ++
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
    dispatchRegistryChecks ++
    highlightFaceChecks ++
    highlightEnterChecks ++
    treeObjectRuleChecks ++
    indentRuleChecks ++
    indentOpeningChecks ++
    indentEditChecks ++
    indentLevelChecks ++
    apiStateChecks ++
    insertExcerptChecks ++
    projectSearchChecks ++
    projectSearchRunChecks ++
    workingSetChecks ++
    workingSetRefindChecks ++
    workingSetPlaceChecks ++
    workingSetRunChecks ++
    workingSetDiskChecks ++
    journalFormatChecks ++
    restoreDocumentChecks ++
    restoreOffsetChecks ++
    restoreValueChecks ++
    restoreFrameChecks ++
    restoreWorkspaceChecks ++
    journalReconcileChecks ++
    restoreChecks ++
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
    filteringChecks ++
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
    jumpChecks ++
    jumpGoChecks ++
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
    appearanceChecks ++
    faceVocabularyChecks ++
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
    evilJumpChecks ++
    evilMarkChecks ++
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
    workspaceListerChecks ++
    findFileChecks ++
    projectWorkspaceChecks ++
    findInProjectChecks ++
    reachChecks ++
    modeMarkerChecks ++
    shellChecks ++
    readOnlyChecks ++
    excerptBufferChecks ++
    excerptDisplayChecks ++
    excerptViewedChecks ++
    jsonChecks ++
    contributionChecks ++
    formatDataChecks ++
    listingChecks ++
    versionControlParserChecks ++
    versionControlPlumbingChecks ++
    versionControlHistoryParserChecks ++
    versionControlModelChecks ++
    versionControlGitChecks ++
    versionControlWorktreeGitChecks ++
    versionControlHistoryGitChecks ++
    hunkChecks ++
    reviewHunkChecks ++
    reviewOrderChecks ++
    reviewRecordChecks ++
    versionControlShowChecks ++
    statusViewChecks ++
    statusBufferChecks ++
    worktreeViewChecks ++
    worktreeBufferChecks ++
    revisionBufferChecks ++
    gutterCarryChecks ++
    gutterChecks ++
    stageHunkChecks ++
    commitBufferChecks ++
    reviewBufferChecks ++
    logViewChecks ++
    logBufferChecks ++
    blameViewChecks ++
    blameBufferChecks ++
    versionControlViewsChecks

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
      s!"model-test: {ModelTest.checks.length} checks passed, {Editor.TextContract.properties.length + Editor.TextContract.adoptProperties.length + ModelTest.commandProperties.length} properties hold of the text model, {Editor.UndoTreeCases.cases.length} cases of the undo tree hold over it, and {Editor.JobContract.properties.length} properties of the job model and of the job runner over the fake clock, and {Editor.JobContract.postProperties.length} post properties of both, and {Editor.JobContract.snapshotProperties.length} snapshot properties of both, and {Editor.JobContract.fuzzyProperties.length} fuzzy properties of both, and {Editor.JobContract.fileProperties.length} file properties of the job model and of the job runner over the fake file service, and {Editor.JobContract.grepProperties.length} search properties of both, and {Editor.JobContract.processProperties.length} process properties of the job model and of the job runner over the fake process service, and {Editor.JobContract.fileWatchProperties.length} watch properties of the job model and of the job runner over the fake watch service; {Editor.FileCases.cases.length} cases across the text port and the job port hold of the two models; {(Editor.DisplayContract.properties { advance := 1, lineHeight := 1 }).length} properties of the display interface hold of its model in cells of {ModelTest.displayCells.length} sizes; {Editor.WatchContract.properties.length} properties of the watch port hold of its model; {Editor.ClipboardContract.properties.length} properties of the clipboard interface hold of its model; {Editor.FuzzyContract.properties.length} properties of the fuzzy matching interface hold of its model; {Editor.SyntaxTreeContract.properties.length} properties of the syntax tree interface hold of its model; {Editor.ApiCases.cases.length} cases of the editor API hold of the editor's models; {(Editor.Workspace.FinderContract.properties "/").length} properties of the workspace finder hold of its model and of the finder on the job model; {(Editor.Workspace.MarkerContract.properties "/").length} properties of the mode marker search hold of its model and of the search on the job model; {Editor.VersionControlContract.properties.length} properties of the version-control interface hold of its model, and the git implementation's status read of each of their repositories on the job model"
  (← IO.getStdout).flush
  IO.Process.exit 0
