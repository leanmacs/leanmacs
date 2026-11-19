import Editor.Api
import Editor.AtPoint
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Completion.Displays
import Editor.Completion.Keys
import Editor.Completion.Later
import Editor.Completion.Styles
import Editor.Config.Owner
import Editor.Config.Stores
import Editor.Event
import Editor.Ex
import Editor.Files
import Editor.Gutter
import Editor.InputScheme
import Editor.Key.Notation
import Editor.ModeLine
import Editor.State
import Editor.VersionControl.Gutter

/-!
# The command loop

Events go in, the state changes, a scene comes out. `Loop.step` takes the
loop (the editor state, what the last scene showed and the input scheme's
state) and one event, handles it (`Loop.handle`), and publishes a scene of
the state after it (`Loop.publish`). It is pure: a command (`EditorM`) over
the editor's composite port, so the same loop runs on the models in
`model-test` and against the Rust library in the headless host, which pulls
the events and hands each to it.

## The scheme

A loop runs one input scheme (`Editor/InputScheme.lean`), which it is given
when it starts and keeps for its life: `Loop scheme`
(`docs/design/keymaps-and-modes.md`, "The loop runs one scheme"). It holds
the scheme's state. It starts over the initial state, with the first
window's selection of the shape the scheme reports of the first view
before any key (`Loop.start`). A step is also handed `Loop.Keys`: the active keymaps
of each view, as a function of the editor state and the view, which the
caller makes for each step. The loop applies it to its own state
(`Loop.key`): the active keymaps depend on the buffers' modes, which only
the loop's state holds, so a mode set by one key holds from the next.

- **Which keys are stepped** (`Loop.stepped?`). A key press, a repeat among
  them, whose key is not a modifier by itself (`Key.isModifier`). A release
  is not stepped, and neither is the press of Shift a window reports before
  a shifted key: stepped, it would be an unbound key and would reset the
  sequence begun.
- **The key is for the focused view** (`Loop.key`): the frame's. The
  event's text is not read: a scheme asks `Key.printed?`.
- **The scene shows the pending keys** (`Loop.pending`): what the scheme
  reports as pending, as a key string. It is empty once a sequence
  completes and after a key that goes on with no binding, since the scheme
  then reports none. The selected window's status line draws them, in the
  `pending-keys` segment (`ModeLine.pendingKeys`, `contextOf`). **And,
  once the key hint delay has passed, the keys that can follow them**
  (`Loop.keyHints`, `shownHints`, `Scene.keyHints`; "Key hints", below):
  what the scheme lists after its keymap prefix for the
  focused view (`InputScheme.continuations`), over the active keymaps and
  with the prefix names the host hands (`Keys.prefixNames`), each with its
  description or its name and count. None while no keymap prefix is
  pending, and none before the delay has passed.
- **The scheme is told of a view that is closed** (`Loop.forgetViews`,
  `InputScheme.closeView`). After a command that ran to its end, each view
  the state before it had a window of and the state it left has none of is
  told to both states of the scheme the loop keeps. A command that did not
  run to its end closed nothing, and the scheme is told nothing.
- **The scheme is told when the minibuffer's view opens**
  (`Loop.toldViews`, `InputScheme.openMinibuffer`). After a command that
  ran to its end and left a prompt open that was not open before it
  (`Loop.openedMinibuffer`), both states of the scheme are told that the
  prompt's view is the minibuffer's, after they are told of the views the
  command closed: a command that closes one prompt and asks for another
  tells the first view closed and then the second opened. A command that
  did not run to its end opened nothing, and the scheme is told nothing.
  Closing the prompt closes the view, so the notice above is what forgets
  it.

## Running an invocation

When a key completes a sequence the scheme yields an invocation, a
command's name and plain arguments, and the loop runs it (`Loop.run`):

1. **The echo area is cleared.** It is what the last command left: a key
   that yields nothing leaves it as it was.
2. **The command is looked up** by its name (`Loop.Keys.command?`), in the
   registry as it is at this step. A name no command is registered under is
   said in the echo area: `<name>: no such command`.
3. **It is run with a `Call`** (`Editor/Command/Call.lean`): the focused
   window and its buffer, the invocation's arguments, which hold the count
   where the scheme laid it out, the keys that yielded it, which are
   what the scheme reported as pending before the last key, then that key's
   chord, and what the scheme reports of the focused view
   (`InputScheme.report`) in its state after the key. So the command of
   the key that enters a state of the scheme's is told of that state. When
   the command does not run to its end the scheme goes back to its state
   at rest ("The scheme after a command that failed", below), so the
   report a later command is told is the one from before the failed key.
4. **Its state requests are answered from the loop's state**
   (`EditorM.dispatched`, `Editor/Command/Dispatch.lean`), each from the
   state the one before left, starting with the echo area cleared. When the
   command runs to its end, the state it left is the loop's. When it does
   not, the loop's state is the one from before the command ("Rollback").
5. **A refusal is said in the echo area**, `<name>: refused: ` and the
   refusal (`TextError.describe`), and the editor keeps running: the step
   is not refused, and the next key is handled. What the command did before
   it was refused is rolled back ("Rollback"). **A command that gives up**
   (`giveUp`, `Editor/Api.lean`) is rolled back the same way, and what is
   said is `<name>: ` and its reason, with no `refused:`: the store refused
   nothing (`Editor/Command/Dispatch.lean`, "A command that gives up").
   **A command that breaks off** (`breakOff`, `Editor/Api.lean`) is said
   the same way and is not rolled back: the state it reached is the
   loop's (`Editor/Command/Dispatch.lean`, "A command that breaks off").
   What this module says of a command that ran to its end holds for it
   too (the jobs, the invocations and the reload it asked for are handed
   back, what it dropped is given up, and the scheme is told of the views
   it closed), with two differences: it has no value, so it asks for
   nothing to be written, and the scheme goes back to its state at rest
   ("The scheme after a command that failed", below).
6. **What the command asked to be written** (a command over a store) is
   handed back with the step (`Loop.Stepped.write`), for whoever holds the
   cells.
7. **A slow command is logged.** The loop reads the watch port's clock just
   before the command and just after it, however it ended. When it took
   longer than the threshold the step was handed (`Loop.Keys.slowAfter`,
   `Loop.slowAfter` by default), the step hands back one entry
   (`Loop.Stepped.log`): `slow command: <name> took <n> ms`. The loop
   writes no log itself: the host does, with what the step hands back.
8. **The jobs the command asked for are handed back** with the step
   (`Loop.Stepped.starts`), for the host to start ("Jobs from commands").
9. **The invocations to run next are handed back** with the step
   (`Loop.Stepped.answered`): each prompt the command accepted, as the
   invocation to run with its answer, and each invocation the command
   asked to be run after it, for the host to run before its next event
   ("Prompts").
10. **The step says how the command ended** (`Loop.Stepped.ended`, a
    `Loop.Ending`), for a host that prints it.

A call into a config command is not guarded against the interpreter: an
exception thrown by interpreted code ends the process
(`docs/design/lean-runtime.md`, "An exception from the interpreter ends the
process").

## Every command goes through the loop

A key is one of three ways a command comes to run, and the loop runs all
three the same way (`Loop.dispatch`): the command is dispatched from the
loop's state, so it is guarded and its state requests are answered; it is
rolled back if it does not run to its end; what it gave up is given up, its
jobs are handed back, and a scene is published after it.

- **A key's invocation** (`Loop.key`, above).
- **An invocation no key yielded** (`Loop.invoke`): the echo area is
  cleared, the name is looked up, and the command is called with the
  focused window, the invocation's arguments, no keys, and what the scheme
  reports of the focused view in the state it is in. The scheme's
  states are left as they are but for a view the command closed: no key
  was typed. Two things are run this way: a command run by its name
  (`Loop.runNamed`), for a host's driver, which is an invocation with no
  arguments; and the continuation of a prompt that was accepted
  ("Prompts").
- **A command the loop is handed** (`Loop.deliver`), with a label for it: a
  finished job's command, which is no invocation. The echo area is **not**
  cleared, because a result that arrives in the background should not wipe
  what the user is reading; a command that says nothing leaves it. When the
  command does not run to its end the echo area reads `<label>: refused: `
  and the refusal, or `<label>: interrupted`, as an invocation's does under
  its name.

## A command run inside another

A command can have the command registered under a name run inside it
(`runCommand`, `Editor/Api.lean`), which is no fourth way: the named
command's program becomes part of the asking command's
(`Editor/Command/Dispatch.lean`, "Requests that name something
registered"), so it is guarded, answered, rolled back and said with it.

- **The name is looked up as a key's invocation is** (`Loop.dispatch`):
  what the dispatcher is told of the registry's commands
  (`Loop.Registered.command`) is made, for each command the loop runs,
  from `Loop.Keys.command?`, the lookup `Loop.run` makes. So a name stands
  for one command at a step, whether a key, a name or another command runs
  it, and a reload changes all three together.
- **A command run this way has nothing written back.** What a command
  over a store asks to be written is the value of the command the loop
  ran, and a command run inside another is not that one. So one that asks
  for a write gives the asking command up (`Loop.writesInside`), and the
  loop rolls both back: the write is not lost in silence.
- **Why it exists.** Evil's dot repeat replays a change by the name the
  change's keys compiled to (`Editor/Evil/Repeat.lean`). Looked up in a
  table of its own, the name could stand for another command than the one
  the key ran: config's command of a compiled command's name runs in its
  place, and a second table would not know.

Pinned by `ModelTest.dispatchRunCommandChecks`.

## Jobs from commands

A command starts a job by the name it is registered under, with plain
arguments (`startJob`, `Editor/Api.lean`). A request holds no job: a job is
a program that ends in a program over the editor's port, so a request of
that port cannot carry one (`docs/design/lean-runtime.md`, "A request that
carries a program over its own port"). The loop starts none either: it
holds no job table.

- **The name is checked when the command asks.** The request is refused,
  as a value the command sees, with `noSuchJob` for a name the step was not
  told a job is registered under (`Loop.Registered.jobs`).
- **A start is kept in the state** until the command ends
  (`EditorState.Outbox.starts`). The starts, the cancels, the answers, the
  reload and the theme are one field of the state (`EditorState.outbox`,
  `Editor/State/Outbox.lean`), which the loop takes out whole. After a
  command that ran to its end the loop takes the starts out of the state
  and hands them back with the step, in the order they were asked for. A command that did not run to its end
  starts no job: its starts go with the state it left.
- **A start may carry a key, and a command may cancel a key**
  (`cancelJob`): the cancels are kept in the state too
  (`EditorState.Outbox.cancels`), taken out with the starts after a
  command that ran to its end, and handed back in `Loop.Stepped.cancels`,
  ahead of the loop's own ("Auto-reload"). A command that did not run to its end
  cancels nothing. The host ends the job of each key, and starting a job
  of a key ends the running job of that key first ("Keyed jobs", below).
- **The host starts each**, for whoever registered it, and when the job has
  ended hands the loop the command it finished with (`Loop.deliver`). The
  result comes back through the host's queue, so events that arrived before
  it are handled before it: a job never interleaves with a command.
- **On the models** `Loop.Driver` (`Editor/Loop/Driver.lean`) is that host:
  it runs each job a step hands back on the job model and keeps what it
  ended with until a test says the job is finished.
- **The loop's own work is spawned, not started** (`Loop.Stepped.spawns`,
  `Loop.Spawn`): work a step made, a prompt's match ("Prompts", below),
  which no registered name and no plain arguments can carry, with its key,
  the label its delivery is printed with, and its owner. A host runs the
  spawns after the step's cancels and starts, each as a job of its owner
  under its key: a spawn of a key ends the running job of that key first.

Pinned by `ModelTest.driverChecks`.

## Prompts

A command asks for a string and does not wait for it (`prompt`,
`Editor/Api.lean`): it names the command that receives the answer, as an
invocation, and runs to its end (`docs/design/concurrency.md`, "Prompts").
The open prompt is editor state (`Editor/State.lean`, "Prompts"), so the
loop has little of its own to do.

- **An answer is kept in the state** until the accepting command ends
  (`EditorState.Outbox.answered`): the prompt's continuation with the
  answer as its first argument, recorded by the request that closed the
  prompt.
  After a command that ran to its end the loop takes the answers out of
  the state and hands them back with the step (`Loop.Stepped.answered`),
  as it does the jobs to start. A command that did not run to its end
  answers nothing: its answers go with the state it left.
- **The host runs each answered invocation with `Loop.invoke`, with keys
  made anew, before it pulls another event**, and takes that step in as it
  takes any step in: its write, its log, its jobs, and the answers it
  hands back in turn. So a key typed after the accept key is handled after
  the answer's command. Every host must do this; `Loop.Driver` does on
  the models and the headless host against the library.
- **Why the host and not this step.** The host holds the cells of the
  stores, and a command over a store is made over the cell as it is when
  the command is looked up. Run inside the accepting command's step, the
  answer's command would be looked up before that step's write was
  written back. As a step of its own it is like every other command: one
  rollback, one scene, one log entry, one ending.
- **An answer for the input scheme** is one whose continuation is the
  reserved name `InputScheme.answerName`: `Loop.invoke` hands it to the
  scheme (`Loop.answer`, `InputScheme.answered`) and looks no command up.
  The invocation the scheme yields for it is run as a key's is, with the
  scheme's report after the answer, and the scheme's state is kept as the
  state at rest when the command ran to its end, and put back to the state
  at rest when it did not. This is how Vim's `/` asks for its pattern and
  then makes its edit (`Editor/InputScheme/Vim.lean`, "Motions that ask").
- **Keys pressed by an invocation** are one whose name is the reserved
  `InputScheme.keysName`, with a key string as its argument: `Loop.invoke`
  hands it to `Loop.pressed`, which feeds the keys to the scheme for the
  focused view and runs what they complete as `Loop.key` runs a key's,
  with those keys, the scheme's report after them, and the same rule for
  the state at rest. It looks no command up. The keys are fed from the
  state at rest (`Loop.atRest`), the scheme's state with nothing pending,
  so a prefix left pending cannot extend them, and the Vim scheme still
  knows which state each view is in. Keys that complete nothing are said
  (`Loop.notBound`). The binding search runs the binding accepted this way
  (`Editor/BindingSearch.lean`), so it runs as its key would: the scheme's
  own invocation, with no count and no register, and the scheme's state
  changed as the key changes it.
- **Which keys reach a command** (`RegistryRequest.keyBindings`) is answered
  per step, from the scheme's state the step's report is computed from
  (`Loop.keyBindingsIn`): after the key, after the answer, the loop's for
  an invocation, after `invoked` for a menu item. A command a job runs is
  answered none.
- **A command has another run after it the same way** (`invoke`,
  `Editor/Api.lean`): the invocation is recorded in the same field, after
  what is there, with no prompt, and is handed back and run by the host
  as an answered one is. So the answers a step hands back are the
  invocations to run next: a prompt's continuation with its answer, and
  what the command asked for. The ex command runs the command a line
  names this way (`Editor/Ex.lean`), and so does the command prompt,
  `execute-command`, the command accepted (`Editor/ExecuteCommand.lean`).
  A name no command is registered
  under is said by that step, `<name>: no such command`.
- **Rollback needs no rule of its own.** A command that asks and then
  fails is rolled back to a state with no prompt; one that fails while a
  prompt is open, an accept among them, to a state in which it is open,
  with the minibuffer's history and markers kept and restored like any
  buffer's and window's; and an answer's command that fails to the state
  after the accept, with the prompt closed.
- **The minibuffer is given up by the rules that exist** ("What a finished
  command gave up"): the closing command removed its window and emptied
  its buffer's slot.
- **The loop lists a prompt's candidates, before each scene**
  (`Loop.listed`, in `Loop.publish`). While a prompt is open and has
  candidates, the minibuffer's text is read; when it is not the text the
  listing is for, the style chosen for the prompt's category
  (`Loop.Keys.matching`, `Completion.Matching.styleFor`,
  `Editor/Completion/Style.lean`) is asked which candidates' texts it
  matches, in what order and with which ranges, and the state keeps the
  answer, followed by the candidates filtered sources passed
  (`EditorState.listCandidates`, `Editor/State.lean`, "Prompts"). Nothing
  else asks a style for a prompt. With nothing chosen by config the style
  is the fuzzy matcher's (`Completion.Styles.fuzzy`), which asks
  `Fuzzy.rank` once (`Editor/Fuzzy.lean`).
  - **The candidates listed are those that answer the typed text**
    (`Candidates.answering`, in `Candidates.listing`): an asking source's
    answer for another directory, and a candidate the text does not
    reveal, are left out, inline and in a match job alike. The size that
    chooses between the two is counted per source (`Candidates.current`).
  - **The style is looked up for each step**, from the keys the host
    hands, and never kept in the state: the state holds only the prompt's
    category. So a reload changes it from the next listing, and a listing
    already made stays until the text changes.
  - **It runs on the editor thread for a short list**, inside the publish,
    as config's mode-line segments do: a style is a program over the fuzzy
    port alone, so it cannot be refused, read the state or be interrupted.
    A short list is one with at most `Loop.Keys.inlineMatches` candidates
    handed the style (`Candidates.listingSize`: those to match, and those
    passed as given, which it marks) (`Loop.inlineMatches`, 250, set by the
    prompt benchmark). `listed` and `completionJobs` both count with it, so
    a long passed list is marked on the pool too.
  - So the first listing of a short list is made by the scene of the asking
    step, for the initial text, and every event ends in a scene: a command
    always finds the listing of the text the last scene showed.
  - **A long list is matched by a job of the loop's own**, on Lean's task
    pool (`completionJobs`, `matchWork`): the publish asks no style and only
    reads the text, and the step hands back a spawn (`Loop.Stepped.spawns`)
    under `completion-match <view>`, of the owner of the style, whose work
    makes the listing with the same program a short list's is made with
    (`Candidates.listing`), asking the matcher through the job port
    (`JobRequest.fuzzy`), and finishes with the command that lists it
    (`StateRequest.listMatched`) if it is still the match in flight. So a
    key never waits on the match, and the listing arrives a moment after the
    key: while typing fast it can be the listing of an earlier text.
    - **At most one match is in flight** (`Candidates.matching`): a key or a
      batch while one runs spawns nothing, and the scene of its delivery
      spawns the next, for the latest text. So a stream of batches cannot
      starve the listing, as cancelling and restarting would. A match
      whose listing came back current while it ran, as when a key is
      typed and undone, is no longer in flight (`listed`): its job is
      cancelled, and a delivery of it already on its way lists nothing.
    - **A match that fails** (its matcher threw) finishes with the command
      that says `completion-match: ` and why in the echo area
      (`StateRequest.matchFailed`); the text and revision it failed for are
      not matched again until one of them changes.
    - **A match is stamped with the config generation** it was spawned
      under: an install cancels a match of config's style with config's
      other jobs, and the first scene after the install, which reconciles
      too (`Headless.Running.publish`), finds the stamp old and spawns a
      match with the new config's style.
- **The display shows them** (`EditorState.displayed`, in `Loop.publish`,
  right after the listing). The display the keys hand for the prompt's
  category (`Loop.Keys.displaying`, `Completion.Displaying.displayFor`,
  `Editor/Completion/Display.lean`) is handed the whole listing, the
  choice and where its window started last, and answers its rows: by
  default the minibuffer display's (`Completion.Displays.minibuffer`), at
  most ten (`Completion.Displays.rows`, as Emacs's vertico and ivy list
  ten), in a window round the choice, so moving the choice past the last
  row shown scrolls the list. The listing is handed over as it is and
  never copied, so each publish builds text for at most the display's
  rows, whatever the listing's size. The state keeps what it answered on
  the prompt (`Prompt.sheet`) and draws it in the candidate list's view
  (`candidateListView`), in the top of the minibuffer's place, directly
  above the minibuffer's own view; the minibuffer's status line is the
  label alone (`promptStatus`). The list is not written into the
  minibuffer's buffer: the whole text of that buffer is the input.
  - **The display is looked up for each step**, from the keys the host
    hands, and never kept in the state: a display is a pure function,
    so it runs inside the publish, on the editor thread, and cannot be
    refused or interrupted. So the scene an install publishes draws with
    the new config's display, and no code of the old config runs after
    it.
  - **The list's place grows and never shrinks while the prompt is open**
    (`Prompt.tallest`, `EditorState.listRows`): typing that cuts the
    matches leaves the strip as tall as it has been, with blank rows under
    the list, and closing the prompt gives the windows the height back.
- **Sources that answer later** (`Editor/Completion/Later.lean`) are asked
  by the loop, after each publish, by the same reconciler
  (`completionJobs`), pure over the state and the text the publish read
  (`Loop.typed`): an asking source not yet asked has its registered job
  started under `completion <view> <source>`; one that depends on the text
  and was asked with another has its key cancelled and its job started
  again, at the next generation, after its pause. Their batches come back
  as posts, taken by `minibuffer-candidates`, and the scene after each
  lists them: a later source's candidates after those that answered now.
- **Closing the prompt cancels its jobs**: every key the loop recorded for
  the prompt (`EditorState.completionKeys`) that the open prompt no longer
  wants is cancelled at the publish of the step that closed it, accepted or
  cancelled, its sources' jobs and its match alike.
  - **The typing command knows no prompt.** The listing is made here and
    not by the command that typed because that is the scheme's
    self-insert, and an undo, a put and a committed text change the text
    too.
  - **A text that did not change costs one read and no ranking**, and
    leaves the listing and the choice as they were, unless a batch came in
    since (`Candidates.revision`): the list is then listed again for the
    same text, the choice kept on its candidate. A listing for a new text
    has no choice.
  - **A prompt with no candidates costs what it cost before**: nothing is
    read and no style is asked. Nor is one asked when every candidate was
    passed by a filtered source.
  - It is the loop's own request, not a command's: it is not guarded, so
    the interrupt flag never stops a scene. A refusal of the read leaves
    the listing as it was and is in the echo area with the publish's other
    refusals ("When publishing is refused").
  - The listing is editor state, so a command that fails is rolled back
    to the listing and the choice from before it.

Pinned by `ModelTest.promptChecks`, the listing by
`ModelTest.candidateChecks`, the reconciler by `completionJobChecks`, and
sources that answer later and matching off the thread through the loop by
`laterLoopChecks`; on the headless host by `ConfigTest.promptChecks`.

## Completion at point

A session at point (`EditorState.atPoint`, `docs/design/keymaps-and-modes.md`,
"Completion at point") is listed, shown and matched by the same rules as a
prompt: `listed`, `displayed`, `candidateListView` and `completionJobs` read
what is completing (`EditorState.completing?`), a prompt or a session, and
a session's pattern is the text the user typed (`AtPointSession.typed`),
never its region's text, so a preview is not matched against itself. In
the publish, before `listed`:

- **`atPointKept`** closes the session when its view is not focused, is no
  window or shows another buffer, when a prompt is open, when the view no
  longer takes text (insert state was left), when its markers cannot be
  read, and when the cursor is before its region's start or after its end.
  Otherwise, when the region does not hold what the session last left
  there, the user edited it, and its text becomes what is typed
  (`retakeAtPoint`): so typing on keeps a preview.
- **`atPointExhausted`**, after `listed`, closes it when nothing more is to
  come and nothing matches (`Candidates.exhausted`), saying `no
  completions` when it never showed a row.
- **A session closed there** gives up its markers, releases its snapshots
  and, when it made a preview, closes its buffer's group
  (`closedAtPoint`, `EditorState.closeGroupOf`). One a command closed is
  given up by `gaveUp`.

**What a command typed** in place of typed text (`EditorState.retyped`) is
told to the scheme, once the command has run to its end, as committed text
(`ranInto`).

**Asking by itself.** A step that took a key, or a committed text that was
inserted, says the view and the text it typed (`Stepped.key`). Once its
scene is published, `atPointAsks` (pure) looks at the chain of the buffer's
at-point sources: a trigger character runs `at-point-triggered` as the next
step (`Stepped.answered`), and the sources' pauses are armed
(`Stepped.pause`, `PauseChange`), replacing whatever was; any other key, or
one while a prompt or a session is open, withdraws them. The host arms each
pause as a wait on the job clock, and runs `at-point-paused` when one fires
(`Headless.Running.pause`, `paused`); the driver on the models by
`Loop.Driver.pass`.

Pinned by `ModelTest.atPointLoopChecks`, `atPointRepeatChecks`,
`atPointAskChecks`, `atPointByItselfChecks` and `completionJobChecks`; on the
headless host by `ConfigTest.atPointChecks`.

## Key hints

The keys that can follow a pending prefix are listed through the completion
display config chose for the category `key`, once a delay has passed
(`docs/design/keymaps-and-modes.md`, "The key hints"). They are a
candidate list with no typed text, held in the state
(`EditorState.keyHints`, "Key hints" in `Editor/State.lean`), and the loop
opens, closes and lists them before every publish (`keyHinted`), a step's
and the one a host makes with no step after an install or a theme switch
alike (`publishHinted`), so a reload that sets `.never`, or rebinds the
keys under a pending prefix, closes or opens them with no key typed:

- **The reconciler, `armedHints`** (pure), compares the hints open with
  the keys that can follow now (`keyHints`). They are wanted while some key
  can follow, nothing is completing and the delay is not `.never`
  (`Keys.keyHintDelay`). Not open and wanted: they open at a new
  generation (`EditorState.keyHintGeneration`), due at once with a delay of
  0, and otherwise with a wait of the delay armed for that generation
  (`Stepped.hintDelay`, `HintDelayChange.arm`). Open and no longer wanted
  (the sequence completed, an unbound key reset it, a command failed and
  the scheme went back to rest, or a prompt or a session opened): they
  close, and the wait is withdrawn (`.disarm`). Otherwise as they are.
- **The delay runs from the start of a sequence, and the list then follows
  the walk.** While keys can follow, nothing is armed again: once due, a
  further prefix (`SPC f`) lists its keys in the next scene. Typing walks
  the keymaps as it does with no hints shown; the list never consumes a key
  or narrows on typed text.
- **The delay is a wait on the job clock**, not a spawned job: it prints
  nothing and takes no job id. The host arms and withdraws it as it does a
  pause of completion at point (`Headless.Running.delayHints`), and when it
  fires runs `keyHintsDue`, a step that runs no command and makes the
  hints of its generation due, so a stale wait changes nothing; the driver
  on the models by `Loop.Driver.pass`. The walk itself has no timeout
  (`Keymap.walk_unbound`).
- **Listing them**: once due, the `key` source of the keys that can follow
  (`Completion.Keys.source`) is asked with no typed text, from the focused
  view, and its candidates are the hints' listing; the publish shows it
  with the display chosen for `key` as the candidate list's view, above
  the bottom row with no input row (`EditorState.displayed`,
  `candidateListView`). The scene's `keyHints` are the hints shown
  (`shownHints`), a Lean-only readout the headless host prints.

Pinned by `ModelTest.keyHintLoopChecks` and `dispatchHintChecks`, the
driver by `driverChecks`, the state by `keyHintStateChecks`; on the
headless host by `ConfigTest.keyHintChecks` and `hintChecks`.

## Reload from a command

A command asks for the config to be reloaded (`reloadConfig`,
`Editor/Api.lean`). The loop holds no config session, so the request is a
one-shot output of the step, like the jobs to start
(`docs/design/concurrency.md`, "Reload").

- **The request is kept in the state** until the command ends
  (`EditorState.Outbox.reload`). After a command that ran to its end the
  loop takes it out and hands it back with the step
  (`Loop.Stepped.reload`). A command that did not run to its end asks for
  none: the flag goes with the state it left.
- **The host asks its config session**, as it does for its driver's
  request: one reload job at a time, and a request made while one runs
  makes one follow-up (`Editor/Config/Reload.lean`). The reload is
  installed later, between two events, so a key typed right after the
  command still runs the old config's binding.
- **On the models** `Loop.Driver` counts the requests
  (`Loop.Driver.reloads`): it has no config session.

Pinned by `ModelTest.dispatchQuitChecks`.

## A theme switch from a command

A command asks for a theme to be loaded (`loadTheme`, `Editor/Api.lean`),
and the loop refuses a name it was not told a theme is registered under
(`Editor/Command/Dispatch.lean`). The loop holds no config session, and the
theme in force is the reload reducer's, so the request is a one-shot output
of the step, as a reload is.

- **The request is kept in the state** until the command ends
  (`EditorState.Outbox.theme`, the latest one asked for). After a command
  that ran to its end the loop takes it out and hands it back with the
  step (`Loop.Stepped.theme`). A command that did not run to its end asks for
  none.
- **The host switches the theme** with no reload: it feeds its reload
  reducer a choice (`Config.Event.choose`), hands its display the new theme
  and publishes a scene in it (`Editor/Headless.lean`).
- **On the models** `Loop.Driver` records the names
  (`Loop.Driver.themes`): it has no config session.

Pinned by `ModelTest.dispatchQuitChecks`.

## Quit

A command asks the editor to quit (`quit`, `Editor/Api.lean`), and the
request sets a flag of the editor state (`EditorState.quitting`,
`Editor/State.lean`, "Quit"). The loop turns the flag into "stop"
(`docs/design/concurrency.md`, "Quit").

- **The step says stop once the editor can leave.** Every step that
  publishes a scene, an event's, an invocation's and a delivered
  command's, says stop when the state it left leaves
  (`EditorState.leaves`: asked to quit, no buffer with unsaved changes, no
  save in flight) and to go on otherwise (`Loop.nextOf`,
  `Stepped.published`). The scene is published first, so the scene of the
  step that says stop is the last one. A host ends its loop at a stop,
  whatever step said it; nothing else crosses to it.
- **A quit waits for a save in flight.** Asked to quit while a save is in
  flight, the step says to go on, and the editor goes on handling events.
  The step that delivers the save's result finds the buffer saved and says
  stop. The order is fixed by the wait, not by timing.
- **A quit that cannot go ahead is withdrawn when the scene is made**
  (`Loop.publish`, `EditorState.settleQuit`), after the histories were
  told their texts' revisions, so that "unsaved" is right: asked to quit
  with a buffer that has unsaved changes, the state is no longer asked. A
  command's own `quit` is refused in that case and never asks, so this is
  where a quit that was waiting ends without quitting because the buffer
  was edited while it waited.
- **A save that is refused withdraws a quit that waited for it.** The
  request that ends a save with no stamp clears the flag
  (`EditorState.endSave`), whether or not the buffer is modified: the
  delivery's step says to go on, with the save's refusal in the echo
  area. So neither `wq`, nor `w` and then `q`, leaves when the file was
  not written.
- **A command that asks and does not run to its end has not asked.** The
  flag is editor state, and the loop's state is then the one from before
  the command ("Rollback").
- **A window's close request is a quit by `q`'s rule.** The loop runs the
  rule itself (`Ex.closeRequested`, `Editor/Ex.lean`, "A window's close
  request") as it runs a delivered command (`deliver`, labelled
  `Ex.quitName`): guarded, rolled back and published, with the echo area
  not cleared first, and saying stop only when the state it left leaves.
  So a close request while a buffer that holds a file has unsaved changes
  publishes one scene, with the refusal in the bottom row, and the loop
  goes on; one with a save in flight waits for the save's delivery; and
  one with nothing unsaved publishes one scene, the last, and says stop.
  The loop runs the rule rather than the command registered as `quit`, so
  a host that registers no ex command still closes, and config's `quit`
  does not replace the close button's rule.
- **A queue's quit is not this.** It stops the loop and publishes nothing
  ("What each event does"): the host must return.
- **The system's quit is put through `quit`** (`Event.quitRequested`:
  Command-Q, the Dock's Quit, a logout). The step remembers it
  (`EditorState.systemQuit`) and runs the command named `quit`
  (`Ex.quitName`) as an invocation no key yielded, so the rules above hold
  of it: config's command of that name runs in its place, and the step
  says stop when the editor leaves, as for `:q`. When the editor does not
  quit, because `quit` was refused or did not ask, or a quit that waited is
  withdrawn, the publish asks the frame `keepRunning` once
  (`EditorState.answerSystemQuit`, `Display.askFrame`), and the system's
  quit is forgotten. While it waits for a save, nothing is asked. A quit
  typed in the editor asks the frame nothing. Unlike a close request, it
  runs config's `quit` when config registers one.

Pinned by `ModelTest.systemQuitChecks` and `ModelTest.dispatchQuitChecks`.

**The scheme after a command that failed.** The loop keeps two states of
the scheme: the one after the last key (`Loop.input`), and the last one at
rest (`Loop.atRest`), in which nothing was pending. When an invocation does
not run to its end, the scheme goes back to its state at rest: it is as it
was before the first key of the sequence, so a key that entered a state of
the scheme's has not entered it, and no prefix is left pending. When the
invocation runs to its end, or a key yields nothing and leaves nothing
pending, the state at rest becomes the state after the key. A command that
breaks off (`breakOff`, `Editor/Api.lean`) has not run to its end for
this: the scheme goes back to its state at rest, though what the command
did stays.

## Rollback

A command that does not run to its end leaves the texts and the windows as
they were before it (`docs/design/concurrency.md`, "Foreground: commands").

- **Before a command** the loop keeps (`Loop.keep`), for each buffer, the
  state of its undo tree once told the revision its text is at, and, for
  each window, its selection marker and its scroll marker as read. A buffer
  whose text refuses, and a marker that does, is not kept.
- **After a command that did not run to its end** (`Loop.Kept.restore`)
  each kept buffer's tree is told the revision and reverted to the kept
  state (`UndoTree.revertTo`), with the user's origin, and the tree it
  returns is the buffer's. Then each kept marker is placed back. The editor
  state is the one before the command: the windows, the buffers, the echo
  and everything else a state request of the command changed are as they
  were.
- **The tree that is reverted is the one the command left**, when the kept
  state is a state of its open group. A command can move in a buffer's
  history and record the moved tree (`StateRequest.setHistory`). The tree
  from before the command does not know of the move, and the move dropped
  the inverses that tree's edges cross: reverting it would be refused, or
  would leave a tree out of step with the store. So each kept buffer is
  reverted from the tree it has in the state the command left, when that
  state still has the buffer, over the same text, and from the tree it had
  before otherwise. The buffer of the state the loop keeps gets the tree
  that comes back.
- **A boundary the command set is taken back with its edits.** A command
  can close the open group (`BufferId.closeGroup`). The kept state is then
  no state of the open group of the tree the command left, though nothing
  moved. The tree from before the command knows of no boundary set since:
  told the revision, its open group is everything the command did, so it
  is the one reverted, by one inverse, and the buffer's. The steps the
  command closed go with the tree the command left: the history has no
  step for the command and nothing to redo, and the markers are placed
  back. That tree is reverted only when the tree the command left still
  has each of its edges as it has them (`UndoTree.keepsEdgesOf`): a move
  over one of them dropped the inverse the edge held, and the tree from
  before is then out of step with the store. When the command also moved
  over a step it had closed itself, the store refuses the revert, with
  nothing changed, since that move dropped inverses of the run, and the
  command is one that moved in the history (below).
- **A mark of the saved state is taken back.** A command can mark a state
  of a buffer's history as saved: by recording a tree it marked
  (`StateRequest.setHistory`), or by ending a save
  (`StateRequest.endSave`). The tree the command left carries that mark,
  and it may be the tree that is reverted. So the tree that comes back is
  given the saved state of the tree from before the command: a buffer that
  was modified is modified again, beside the stamp and the save in flight
  the state from before has. Without this a failed command that ended a
  save would leave a buffer that says "not modified" beside a stamp from
  before the save.
- **Markers are placed back, and not left to the inverse.** A marker moves
  with every transaction: a deletion and its inverse do not return a marker
  inside the deleted range to where it was, and a command can place a
  marker with no edit. A revert hands back only the selection a transaction
  carried.
- **No group of its own.** The kept state may be a point inside an open
  group, and the revert goes back to it, whether or not the command set a
  boundary: the edits from before the command are then still pending. That
  is the case for a command run inside an insert session, whose buffer's
  group the loop leaves open ("Insert sessions"): the session's earlier
  edits stay pending, and are one step with what follows. For any other
  buffer the loop closes the group after every event (`Loop.publish`), so
  the kept state is a node's, and the revert leaves nothing pending, no
  node and nothing to redo.
- **An excerpt buffer's own tree is neither kept nor reverted**: its text
  keeps no inverse, and the store would refuse to revert it. Its sources
  are buffers, kept and reverted as every buffer is, so a command that
  edited several sources through one excerpt buffer is rolled back in each,
  and the excerpt text catches up from them. The steps it keeps are state,
  and come back with the state from before the command. Pinned by
  `ModelTest.excerptBufferChecks`.
- **What is not undone**: the texts, snapshots and markers the command
  made, the scenes it published, what it wrote to the clipboard, and what
  it asked of the syntax tree port: a text attached, highlighted or
  detached stays so in the library, as the clipboard is outside the editor
  state. The step publishes the true scene right after.
- **A rollback that is refused is said, and the rest is still done.** A
  command that released a buffer's text, gave up a window's marker or
  dropped the inverses of its own edits cannot be rolled back. The echo
  area then ends `; not rolled back: ` and the first refusal.
- **A move in the history is not taken back.** When the kept state is no
  longer a state of the open group, and the tree from before the command
  cannot be reverted to it, the history moved since it was kept. The loop
  then reverts the group that is open (`UndoTree.revert`), which takes
  back the edits made since the move and leaves the text at the node the
  move reached. The echo area ends `; the command moved in the history`,
  and the markers of that text are left where the store moved them. It is
  pinned on a command that moves and records the move, on one that sets a
  boundary and moves over the step it closed, and on a state whose history
  was moved by hand.

An event's own handler, such as the commit's (`Loop.insert`), is one
transaction, which the store accepts whole or refuses whole, and is not
routed through this.

## What a finished command gave up

A state request that closes a window, removes a buffer or ends a save
changes the editor state and nothing in the text store: the window's
markers, the buffer's text and the save's snapshot are still held. The loop
gives them up, once the command has run to its end (`Loop.gaveUp`), by
comparing the state from before the command with the state it left:

- **A window's markers.** Each marker of a window of the state before that
  no window of the state after uses is given up (`TextId.unmark`): the
  window was closed, by itself or with its tab, or shown another buffer.
- **A float's anchor marker.** The anchor marker of each float of every
  tab of the state before (`Floating.Anchor.position`) that no float of any
  tab of the state after holds is given up: the float was closed, its tab
  was closed, or its anchor went and a pinned float was anchored to the
  frame (`Editor/State.lean`, "A floating window"). Every tab's floats are
  read, so selecting another tab gives up none of the tab left.
- **A buffer's text.** The text of each buffer of the state before whose
  slot is empty in the state after is released, unless a buffer that is
  left is over the same text. The markers go first, so a window closed with
  its buffer gives up its markers on a text that is still there.
- **A save's snapshot.** The snapshot of each save in flight in the state
  before (`Buffer.File.saving`, `Editor/State.lean`) that is not in flight
  in the state after is released (`Loop.savesInFlight`): the save's result
  was delivered and its command ended the save, whether the save wrote the
  file or was refused, or the buffer was removed while its save ran. The
  command that takes the snapshot and begins the save releases nothing: the
  job reads the snapshot.
- **Not before the command has ended.** A command that is refused or
  interrupted after it closed a window, removed a buffer or ended a save
  is rolled back whole: nothing was given up, so the window and the buffer
  of the state from before are over markers and a text that still answer,
  and the save that is in flight again is over a snapshot that still
  reads. Giving up inside the request would leave a rollback with a window
  over markers that are gone.
- **A refusal is said.** What the store refuses here, such as the release
  of a text the command had released itself, is in the echo area, as a
  refusal met while publishing is (`refused: ` and the refusal), in place
  of what the command left there. The rest is still given up.
- **What is not given up**: the texts, snapshots and markers a command
  made and no window or buffer of the state it left holds, whether it ran
  to its end or not.

## The interrupt

The Rust library raises a flag as the interrupt key arrives, before the key
is queued, and marks that event. What the loop does with the flag is here
(`Editor/Watch.lean` has the port):

- **A command the loop runs is guarded** (`EditorM.dispatched`,
  `Editor/Command/Dispatch.lean`, "The guard", the rule's one definition):
  the flag is asked before each of its requests that reaches the library,
  and once it is up the command makes no further request. A state request
  is answered without asking. The command is then rolled back like one
  that was refused, and the echo area reads `<name>: interrupted`.
- **Only the command is guarded.** The loop's own requests (keeping,
  rolling back, publishing) are not, so a flag that is up stops neither a
  rollback nor a scene.
- **The flag comes down when the loop takes the interrupt key off the
  queue** (`Loop.take`): for an event the library marked
  (`Received.interrupt`), the loop makes the request `Watch.lower`, and for
  no other event. The library decided once, at arrival, which event is an
  interrupt key, so the two cannot disagree. The flag is a count, so with
  two interrupt keys queued it stays up until the second is taken.
- **The interrupt key is then stepped like any key**, after the flag is
  lowered, so a scheme can bind it, and what it is bound to is not
  interrupted by it.
- **Consequences.** A command for a key queued ahead of the interrupt key
  finds the flag up at its first check and makes no request. An interrupt
  key that arrives while nothing runs interrupts nothing: the flag is down
  again before the next key's command starts. The echo of an interrupted
  command is still there after the interrupt key is stepped and found
  bound to nothing, since a key that yields nothing leaves the echo. A
  command that makes no request is not interruptible.

## What each event does

| Event | What it does to the state |
|---|---|
| `commit text` | Where the scheme reports that the focused view takes text (`InputScheme.Report.takesText`): replaces what each range of the focused window's selection covers with `text`, as one transaction with the user's origin. Elsewhere the text is dropped, and so is a commit into a read-only buffer (`Buffer.readOnly`), the echo area saying `<name> is read-only`, and the first commit into a buffer whose file changed on disk unbeknown to the user ("Files that changed on disk"). In an excerpt buffer the sources what the selection covers reaches are looked at as a command's edit's are (`Loop.commitExcerpts`): a read-only source drops it, saying `<source> is read-only`, a text no buffer holds drops it, saying `<buffer> reads a text no buffer holds`, and a source whose file changed unbeknown drops it as above; an inserted one touches the sources. Either way it clears the preedit |
| `preedit text` | Sets the preedit to `text`; an empty one clears it |
| `compositionDisabled` | Clears the preedit |
| `resize` | Sets the frame's size, whether the window is in fullscreen (`Frame.fullscreen`), its corner clearance in points (`Frame.corner`), which the bottom row is inset by (`EditorState.bottomInset`), and its top inset in points (`Frame.top`), which the views along the frame's top edge start their text below (`EditorState.topInset`); the views are laid out in it when the scene is made, and each then follows its cursor ("Following the cursor"). Its scale is not kept: Lean handles no scale, and the display lays out at its own |
| `focus gained` | Sets whether the frame has the keyboard focus. A gain starts a check of every file buffer after the publish ("Files that changed on disk") |
| `closeRequested` | Runs the quit rule (`Ex.closeRequested`) as a delivered command is run (`Loop.deliver`), labelled `quit`: it publishes a scene, and says stop only once the editor leaves ("Quit") |
| `quit` | Nothing: the step says stop, and publishes nothing |
| `openFiles paths` | Runs `open-file` (`Files.openName`) with the paths as its arguments, as an invocation no key yielded (`Loop.invoke`), in the focused window: guarded, rolled back and published as every command is, and config's command of that name runs in its place. The open command opens the paths one after another, so the last path's buffer is shown last (`Editor/Files.lean`, "Open"). With no path it does nothing |
| `quitRequested` | Remembers that the system asked to quit (`EditorState.systemQuit`) and runs `quit` (`Ex.quitName`) with no arguments, as an invocation no key yielded (`Loop.invoke`), in the focused window: guarded, rolled back and published as every command is, and config's command of that name runs in its place. The step says stop when the editor leaves; otherwise the publish asks the frame `keepRunning` once ("Quit") |
| `menu name` | Tells the scheme that a menu item named the command `name`, with no arguments, for the focused view (`InputScheme.invoked`), and runs the invocation it hands back as one no key yielded, in the focused window, with the report of the scheme's state it hands back: guarded, rolled back and published as every command is, and config's command of the name runs in its place. A name no command is registered under says so, as an invocation does. The scheme's states are then as after a key: a command that runs to its end keeps the state handed back, which is the state at rest when nothing is pending, and one that does not puts the scheme back at rest. A scheme that treats no menu item apart hands back the invocation and the state as they were, so the command `name` runs |
| a key press | It is stepped through the scheme, whose state the loop keeps ("The scheme"), and the invocation it yields, if it yields one, is run ("Running an invocation") |
| a key release, the press of a modifier by itself, a pointer, `windowOpened`, `compositionEnabled`, a message, a completion | Nothing |
| `parsed` | Nothing; the scene is published, laid out with the tree the library delivered, so a highlighted text is drawn with its new highlights, which replace the old ones only then (`Editor/Highlight.lean`) |

**A committed text is typed text.** It is inserted only where the scheme
says the view takes text, which under a scheme that says nothing is every
view, and under the Vim scheme a view in insert state and the
minibuffer's. In a state whose selection is on a cell, a commit would
replace the character under the cursor and leave the cursor where the
state does not let one rest, so there it is dropped
(`docs/design/keymaps-and-modes.md`, "Insert sessions"). A commit inside
an insert session joins the session's step of the history.

**The scheme is told of a commit that was inserted**
(`InputScheme.committed`, what `Loop.handle` hands back), for the focused view, in both
states of it the loop keeps, the one it is in and the one it was last at
rest in: no key printed the text, so the scheme's `step` never saw it, and
a scheme that keeps what is typed would miss it. A commit that is dropped,
and one whose insertion is refused, is not told.

A handler is given what it acts on (a `Target`: the window and its buffer),
never "the current buffer". When one is refused, the state stays as it was
and the echo area reads `refused: ` and the refusal (`TextError.describe`).
A handler's edit is one transaction, so a refusal leaves nothing behind in
the store; what a command leaves behind is rolled back ("Rollback").

## After each event

Every event but `quit` publishes a scene, whether it
changed the state or not (`Loop.publish`):

1. **The histories.** Each buffer's undo tree is told the revision its text
   is at, and its group is closed (`EditorState.recordHistories`): what an
   event edited is one step of the history. **But for a buffer in an
   insert session**, whose group is left open ("Insert sessions", below).
   Then each excerpt buffer that is not held makes the source buffers its
   edits touched one step of its own (`EditorState.closeExcerptGroup`,
   `Editor/State.lean`, "Excerpt buffers"), over their trees just closed.
   Then a quit that cannot go ahead is withdrawn ("Quit", above).
2. **The scene** (`Loop.views`, `Loop.scene`). Each window the layout
   places, in drawing order, is a view in the rectangle `EditorState.rects`
   gives it in the frame; a window the layout does not show (monocle's
   others) is not in the scene. The layout is the one the step's keys hand
   the publish (`Loop.Keys.layout`, config's `layout` or the default
   through the host), which the publish has the frame choose before it
   lays the views out when it is not the layout the frame last chose
   (`Frame.choose`, `Frame.chosen`); so a zoom, a resized share, a main
   count or a split tree a command made lasts every step until config
   chooses another layout, and a config that does rearranges the same
   windows. A loop handed none keeps the frame's own. While a prompt
   is open the minibuffer's
   window is a view too, in the lower part of the strip the minibuffer's
   place then takes, below the candidate list's rows (`Editor/State.lean`,
   "The window list, the layout and their invariants"; the listing is made
   and shown first, so the rows are this scene's): its text is the input
   typed so far,
   its selection the cursor in it, and it is the focused view while it has
   the focus. A view
   whose buffer's text is at the revision it was last shown at keeps the
   same snapshot; otherwise a new snapshot is taken, and views of one
   buffer share it. A view's scroll anchor and selection are its window's
   markers. Its decorations are the matches of the last search
   ("Decorations", below), read once the follow has placed its anchor. Its
   padding is `EditorState.paddingOf`'s, in points, from the padding the
   step's keys hand the publish (`Loop.Keys.padding`, config's
   `framePadding` or the editor's 8 through the host, and 0 for a loop
   handed none), which the state keeps (`EditorState.padding`); the
   scene's echo padding is the bottom row's inset
   (`EditorState.bottomInset`: at least the corner clearance the last
   resize said, outside fullscreen). Its
   cursor is the one the scheme reports of the view
   (`InputScheme.report`, in the scheme's state after the last key): a bar
   in the face `cursor` under a scheme that says nothing. Its status line
   (`Loop.statusOf`) is the mode line's (`ModeLine.fields`,
   `Editor/ModeLine.lean`): the segments the step's keys name
   (`Loop.Keys.modeLine`, config's listing or the default order), each
   given what the window shows (`Loop.contextOf`): its buffer, the fields
   the scheme reports of the view, which the `state` segment draws as a
   badge, its cursor's row and column in cells, read from the head of the
   primary range of its selection in the view's snapshot, the snapshot's
   rows, and whether it is the selected window
   (`EditorState.selectedView`). A window that is not selected has no
   badge, every field in `mode-line.inactive`, and that face as its row's
   (`View.statusFace`); the selected one's row is in `mode-line.active`
   (`ModeLine.activeFace`), whose background marks it. "Modified" is the
   `modified` segment's mark (`ModeLine.Context.modified`): for a plain
   buffer `Buffer.isModified`, and for an excerpt buffer whether a buffer
   over one of its entries' sources is; one that is not has no such
   field. The answer is right because the histories were told
   their texts' revisions in step 1. A selection marker the text does not
   answer for gives a context with no cursor, and so no line:col and no
   position. The minibuffer's view has another status line
   (`Loop.promptStatus`): the prompt's label alone, in the face
   `Loop.promptFace`, with no segment and none of the scheme's fields,
   and no status face; its cursor is the scheme's report's. That is how the
   scene shows the prompt text: the scene's shape is the display
   contract, and it has no field for a prompt. The candidates the prompt
   has listed are not in it: they are the candidate list's view's rows
   (step 5). The input is the whole text
   of the minibuffer's buffer, so the label is no part of it: the text
   store has no read-only range to keep a label in. The focused view is named only while the frame has
   the keyboard focus. The pending prefix is the scheme's pending keys
   (`Loop.pending`).
3. **The follow** (`Loop.followed`). Each view's scroll anchor is placed
   so that the view shows its cursor ("Following the cursor", below), the
   floats' last. The scene names the anchor's marker, not its offset, so
   placing it changes no value of the scene.
4. **The floats' places** (`Loop.spots`, `EditorState.located`). Once the
   tiles, the docked windows and the minibuffer's view have followed their
   cursors, the display is asked where each float anchored at a position
   is drawn, in its window's view as it will be published: the view's
   snapshot, its rectangle less its bottom row, its padding, and its scroll
   anchor where the follow left it, and the anchor marker's offset. The
   spot is kept on the float, offset into frame pixels, so the rectangles
   of the state (`EditorState.rects`) stay pure. A transient float whose
   anchor is not drawn, a position its window does not show or a window
   with no rectangle, closes here, and the focus on it goes back as
   `removeWindow` sends it; a pinned one keeps the spot it last had. The
   views are then given their rectangles and paddings again, a closed
   float's view is dropped, and the floats follow their cursors. A float
   is listed after every tile and docked window, so the display, which
   draws views in scene order each over its own background, draws it
   above them.

   **4b. What was viewed.** Once the views are decorated, the time between
   the last publish and this one, on the clock the step's keys hand
   (`Loop.Keys.now`), is credited to each tracked excerpt the last scene
   showed (`EditorState.creditViewed`), of each buffer that still has as
   many entries as it had then. Then each view of an excerpt buffer with a
   tracked entry asks the display which rows it shows, as the follow asks,
   with its blocks, and each excerpt a row starts in is marked shown by one
   more scene, first at `now` (`Loop.viewedBy`, `ExcerptView.shown`,
   `EditorState.markViewed`). It comes after the decorations because the
   face of what was not examined shows the state before this scene: an
   excerpt is drawn unexamined in the first scene that shows it
   ("Decorations", below). A view of no height, and one whose questions are
   refused, marks nothing. The loop keeps what it marked and the time
   (`Loop.viewing`, `Loop.publishedAt`) for the next publish.
5. **The candidate list and the tab bar** (`Loop.candidateListView`,
   `Loop.tabBarView`, `Editor/TabBar.lean`), each a view over generated
   text made, kept and drawn by one procedure (`Loop.generatedView`,
   `Editor/GeneratedView.lean`). While a prompt's list has
   shown a row (`EditorState.candidateListRect?`), the candidate list's
   view is appended, in the top of the minibuffer's place directly above
   the minibuffer's view, as tall as the most rows shown since the prompt
   opened. It is made and kept as the tab bar's is (`EditorState.candidateList`),
   its text is the rows the display answered for this scene
   (`Prompt.sheet`, `Completion.Sheet.text`), with blank rows under them
   when the list shows fewer than it has, its decorations the rows' faces,
   with no selection and no status field, and its anchor at 0, since the
   sheet holds only the rows shown. Then, while the bar is shown
   (`EditorState.tabBarRect?`), the tab bar's view is appended last, in
   its strip above the minibuffer's place. The two are the views of the
   scene that are not windows. For the tab bar: The first time, the publish makes its text, an anchor marker
   at 0 and its view id, which the state keeps (`EditorState.tabBar`); when
   the line of the tabs' labels changes, the text's content is replaced
   with it, and a snapshot of it is taken or kept as for any view. Its
   decorations are the chips' faces, it has no selection and no status
   field, and it is appended after the follow and the decorations, so it
   is never followed and gets no search match. It is never the scene's
   focused view.
6. **Publish** it through the display port.
7. **Release** each snapshot the previous scene named that this one does
   not, and each taken for a float closed in step 4: the tab bar's line
   before a change among them. So a scene's handles
   are alive while it is the last one published, and a real binding
   resolves them when it is published.
8. **What the closed floats held.** A float step 4 closed gives up its
   markers and its anchor marker (`Loop.gaveUp`), and the scheme is told
   its view closed (`Loop.forgetViews`, on both of the loop's states of
   the scheme), as for a window a command closed: only the publish knows
   what the follow scrolled.
9. **The checks of files** (`Loop.fileJobs`): the loop compares what the
   state shows with what it saw at the last publish (`Loop.Seen`) and
   starts one `check-files` for the files that are due ("Files that
   changed on disk", below).

Every edit the loop makes for an input event carries `Origin.user`.

## Files that changed on disk

The editor watches no file unless auto-reload is on, and it is off by
default: what notices that another program changed a buffer's file is a
check, one stat a file (`Files.checkWork`, `Editor/Files.lean`), which the
loop asks for at three moments, and a save's own check.

- **When.** After each publish, `Loop.fileJobs` compares the state with
  `Loop.seen`, what the last publish saw (`Loop.seenOf`: whether the frame
  had the focus, the buffers shown, modified and open). A file buffer with
  no save in flight is due (`Loop.dueChecks`) when the frame gained the
  keyboard focus, every one of them; when it is shown now, was open and no
  view showed it, which covers a switch, a closed buffer's fallback and an
  open of a path that is open; and when it is modified now, was open and
  was not, its first edit. A buffer opened this step is not due: its stamp
  is a moment old. All that are due go in one `check-files` start, handed
  back with the step's other starts, and only where that job is
  registered, so a host not handed the `files` package checks nothing.
- **What the check does.** Its command (`Files.checked`) is made of state
  requests alone, so it cannot be interrupted or rolled back: for each
  file it records what the stat found (`BufferId.markChanged`), told when
  the buffer is modified, and says `Files.changedUnderEdits` for the first
  modified buffer newly found changed. A file that is gone is `found =
  none`. Any other refusal of the stat is ignored.
- **What it shows.** The mode line's `changed` segment gives the field
  `ModeLine.changedMark`, in the face `ModeLine.changedFace`
  (`mode-line.changed`), after the modified mark, while the buffer is
  marked (`Editor/ModeLine.lean`).
- **The first edit is refused.** A dispatched command whose next request
  would edit the text of a marked buffer that was not told ends
  `Guarded.superseded` (`Editor/Command/Dispatch.lean`). It is rolled back
  as one that gave up is; then the told flag is set on the restored state,
  so it survives the rollback, and the echo area reads
  `Files.changedOnDisk`, which names `:e`, or for a file that is gone
  `Files.goneFromDisk`, which names `:w!`, with no command name before it.
  A committed text is dropped the same way (`handle`).
- **The next edit lands**, since the user was told, as Emacs's supersession
  check lets the next modification through. The mark stays, and a save is
  still refused until `:w!` or `:e!`.
- **The gap.** The check is a job, so the refusal acts on what the last
  check found: a change made while nothing asked for a check is not refused
  at the first edit, which lands and starts a check, whose result then
  marks the buffer and says so. Emacs stats synchronously at the first
  modification; the editor thread never blocks on I/O.

Pinned by `ModelTest.stalenessChecks`.

## Auto-reload

An opt-in mode, off by default: **compiled code opens no file watch unless
auto-reload is on.** A config's own jobs may still watch, as a plugin would.

- **Whether it is on** is a command's choice (`EditorState.autoReload`, set
  by `auto-reload-mode`, the ex names `autoread` and `noautoread`), which
  lasts until the editor stops and survives a reload of config; and
  otherwise config's setting (`autoReload` in `setup`,
  `Loop.Registered.autoReload`); and otherwise off. `Files.autoReloadOn`
  reads the choice from the state and asks the registry for config's
  setting (`RegistryRequest.autoReload`), which the dispatcher answers.
- **The reconciler** (`Loop.reconcile`, after each publish, in
  `Loop.fileJobs`) keeps `EditorState.following` in step with what is
  wanted: every open file buffer with no save in flight, while the mode is
  on and `follow-file` is registered, and nothing otherwise. A buffer
  wanted and not followed gets a `follow-file` start of the key
  `follow <buffer>` (`JobStart.key`); one followed and no longer wanted (the
  mode off, the buffer closed, its path changed, a save started) gets a
  cancel of its key (`Loop.Stepped.cancels`). One whose buffer's stamp
  changed since it was armed (a reload, a save) is armed again, so its
  order's stamp, which guards `markChanged`, is the buffer's. A rename keeps
  the watch: the key is the buffer's id. A follow whose watch was refused stays, refused,
  and is not armed again until the mode is turned off and on.
- **Keyed jobs.** A host keeps a map from key to job id (`Running.keyed`,
  `Loop.Driver`): starting a job of a key cancels the running job of that
  key, and a cancel ends the job of its key, even one that has finished
  and not been delivered, so its command never runs (`Job.Jobs.cancel`).
- **The follow job** (`Files.followWork`) starts a watch on the file, with
  a window of 50 ms and a bound of one path, then stats the file, and
  waits for the next delivery while the stat answers what its order
  expected: the last stamp found, which is the buffer's own unless it is
  marked, or `none` for a gone file. Watching before the stat means a
  change made before the watch existed is still seen. A stat that answers
  something else finishes it with `Files.followed`; a refused watch or
  stat with `Files.unfollowable`, which says so.
- **`followed`** drops the following, so the reconciler arms it again with
  the new expected stamp, ignores a stale order, and marks the buffer: an
  unmodified one untold, reloaded when the file is there (`reload-file`),
  only marked when it is gone; a modified one told, its text left, its
  status line showing the mark. A check that finds an unmodified buffer
  changed under the mode reloads it too.
- **The model driver holds a waiting job** (`Loop.Driver.parked`,
  `JobModel.runParking`): `Loop.Driver.touch` records changes in the
  parked jobs' watches and resumes those with a delivery, and
  `Loop.Driver.openWatches` is how many watches they hold.

Pinned by `ModelTest.autoReloadChecks` on the models, and by
`ConfigTest.autoReloadChecks` on real files with the library's watch
service.

## Decorations

A view's decorations come from these sources, in this order: for an
excerpt buffer, its sources' buffers' spans, each translated to every
excerpt of its source (`ExcerptView.sourceSpansOf`,
`Editor/ExcerptView.lean`); its buffer's spans (`Buffer.spans`,
`Editor/State.lean`, "Buffers"), each in the face its owner gave it, such
as the compile mode's locations (`Editor/Compile.lean`, "Locations"); then
what no scene has shown of its tracked excerpts, each in
`review-unexamined` (`ExcerptView.unexaminedOf`), read before this scene
marks what it shows (step 4b of "After each event"); then the matches of
the last search (`EditorState.lastSearch`), each in the face `search-match`
(`searchMatchFace`, defined in the built-in theme, `Editor/Face.lean`). A
later decoration is drawn over an earlier one, so a match is over a span,
the mark of what was not examined is over the buffer's own spans, and an
excerpt buffer's own span is over its sources'.

A view of an excerpt buffer also has its headers as blocks
(`View.blocks`, `ExcerptView.blocksOf`), read of the snapshot it shows when
the view is made (`views`), so the follow and a float's spot ask with them
(`follow`, `spots`).

A view of a buffer with a gutter (`Buffer.gutter`) has its marks
(`View.marks`, `marksOf`), carried from the gutter's revision to the one
its snapshot shows through the text's log and clipped to the same range as
its decorations (`Gutter.marksOf`, `Editor/Gutter.lean`), and its window's
padding has the gutter's column (`EditorState.paddingOf`), so the follow
asks the display with it.

- **Every view but the minibuffer's** covers the range from the start of
  its scroll anchor's row to the start of the row `rows + 1` text rows
  below, or the text's end, where `rows` is the view's height over the
  height of a text row (`EditorState.heights.text`) plus 1. A view of `n`
  display rows shows at most `n` text rows from its anchor's, so every
  visible row is covered, whatever the wrapping; decorations just below the
  fold are drawn too.
- **The spans** that meet the range are kept, each clipped to it, in order,
  and one left empty is dropped (`spansIn`), with or without a last search.
- **The matches** are what its snapshot answers for the pattern in the
  range (`SnapshotId.matches`).
- **It is read after the follow** (step 3 of "After each event"), so the
  anchor is where the scene shows it from: `/` that moves the cursor off
  the view draws the matches round where it went.
- **An empty match draws nothing**, nor does a pattern the syntax refuses,
  nor a text that refuses.
- **They sit under the selection** in layout's precedence, so a cursor
  over a match shows the cursor (`docs/design/text-and-display.md`,
  "Decorations").
- **A recorded departure**: Vim 9.1's default is `nohlsearch`; here the
  matches are always drawn, and `:nohlsearch` is not built. Matches are
  not drawn while a pattern is typed (`incsearch`).

## Following the cursor

A view follows its cursor: before each scene, a view whose cursor's row is
not among the rows it shows has its scroll anchor moved so that it is
(`Loop.follow`). The policy is `Scroll.follow` (`Editor/Scroll.lean`): the
least movement, with the state's scroll margin
(`EditorState.scrollMargin`, `Editor/State.lean`, "The scroll margin").
Layout is asked through the display port's two queries and nothing of it
is kept here.

- **The tab bar's view does not follow**: it is appended after the follow,
  and its one line is always at its anchor (`Loop.tabBarView`). Nor does
  the candidate list's (`Loop.candidateListView`): its text is only the
  rows the display shows, so it is always at its anchor, at 0.
- **It runs in the publish, after the views are made and before the scene
  is published.** After the views, because a question of layout names a
  snapshot and `Loop.views` is what takes one of a text that changed: the
  follow asks with each view's own snapshot and rectangle, so it takes
  nothing and releases nothing. Before the publish, so that the anchor is
  in place when a display resolves the scene's markers.
- **So it comes after everything a step did**: after the command, after
  its rollback if it did not run to its end, and after what it gave up was
  given up. A command that moved the cursor and failed is followed from
  the cursor that was put back.
- **And after every event, not only a command.** A resize, a committed
  text, a job's command, an answered prompt and a host's own publish all
  end in `Loop.publish`. A resize runs no command, and a view it left with
  fewer rows than its cursor's row shows the cursor in the next scene.
- **Every view is followed**, the minibuffer's among them, not the focused
  one alone: an edit made through one window moves the cursor of another
  window on the same buffer.
- **The cursor is the head of the primary range** of the window's
  selection.
- **The anchor keeps its bias**: the marker is placed with the bias it was
  read with.
- **A view of no height is not asked about**: no request is made for it.
  No pixels hold no row under any layout. So a host whose frame is 0 by 0,
  as the headless host's is until a script resizes it, makes the requests
  it made before views followed.
- **A view that shows no row**, because it is less than a row tall, keeps
  its anchor: there is no row to show the cursor in.
- **It is the loop's own program**, not a command's: it is not guarded, so
  the interrupt flag never stops a scene.
- **It is not refused, and its refusals are not said.** A view whose
  marker was given up, or whose snapshot was released, is not followed
  (`Loop.followed`). The marker stays gone, and every command that touches
  it says so; a second line from here would replace the echo of the
  command that could not be rolled back for want of the same marker.
- **What it costs**, in requests, for each view at each scene:

  | The view | Text requests | Display requests |
  |---|---|---|
  | No height | 0 | 0 |
  | Shows no row | 1: the anchor | 1: the rows shown |
  | Keeps its anchor, the margin as set holding | 2: and the selection | 2: and the rows from the cursor |
  | Is moved | 3: and the place | 2 to 4 (`Editor/Scroll.lean`, "What it costs") |
  | A float anchored at a position, placed (`Loop.spots`) | 2 more: the anchor marker and its window's scroll anchor | 1 more: the spot |

- Not done: following inside the dispatch of a command, since a resize
  and a committed text run none; and following inside each motion, since
  the typing command, an undo, a put and a job's command move the cursor
  too, and a motion has no snapshot.

Pinned by `ModelTest.viewChecks`, on the loop's driver over the editor's
models; by a case of `Editor/Api/Cases.lean`, on the models and on the
real text binding with the recorder; and by the fixture
`tests/headless/view`, on the executable. The floats' places are pinned by
`ModelTest.floatViewChecks`, on the same driver, and by the fixture
`tests/headless/float-anchor`.

## Insert sessions

A view is in an insert session while the scheme reports it so
(`InputScheme.Report.session`): under the Vim scheme, while it is in a
state where typing is text. What is edited in its buffer during one
session is one step of the history
(`docs/design/keymaps-and-modes.md`, "Insert sessions").

- **The loop leaves a buffer's group open while a view of it is in a
  session** (`Loop.sessions`, read from the scheme's state after the last
  key): the tree is told the text's revision and not closed. Every other
  buffer's group is closed after each event, as before.
- **A session's boundary is the state change itself.** The scene published
  after the command of the key that ends the session finds no view of the
  buffer in one, and closes the group: one node for everything edited
  meanwhile. The loop keeps nothing of its own for a session. A command
  may still set a boundary inside one itself, with `BufferId.closeGroup`
  (`Editor/Api.lean`, "Undo"): evil's arrow keys of insert state do, once
  they moved (`Editor/Evil.lean`, "Editing keys"), so the session is then
  more than one step.
- **A session with nothing edited makes no node**: closing a group with
  nothing pending makes none.
- **An excerpt buffer that is held holds the source buffers it touched**
  (`Editor/State.lean`, "Excerpt buffers"), so a session typed in it is one
  step in each source buffer, and one step of the excerpt buffer's once the
  session ends.
- **A buffer shown in two windows is held while either view is in a
  session**, whichever window an edit is made through. A buffer no such
  view shows is not held: an edit a command makes to it is a step at the
  end of its event.
- **Anything that edits the buffer during the session joins its step**: a
  key's command, a job's command, a committed text.
- **The buffer is modified while its group is open** (`Buffer.isModified`),
  so its status line shows the modified field during the session.
- **A command that fails inside a session** is rolled back to the point of
  the open group it began at ("Rollback"): the session's earlier edits are
  still pending, and are one step with what follows.

Pinned by `ModelTest.dispatchUndoChecks`, with a scheme written in the test
whose keys begin and end a session.

## When publishing is refused

Publishing asks the store too: each buffer's text for its revision, a text
that changed for a snapshot, and the store to release the snapshots the
last scene named. Each is refused once the text or the snapshot is gone,
and a command can release either: their ids are plain indices. The cause
that refuses a handler (the focused buffer's text was released) refuses
these as well, so a publish that failed with them would lose the echo the
handler's refusal had just written.

`Loop.publish` is therefore not refused by any of them, and neither is
`Loop.step`: a scene is published after the event all the same.

- **A buffer whose text refuses keeps its history as it was.** The other
  buffers' histories are recorded.
- **A view whose buffer's text refuses is left out of the scene**, and
  nothing is taken for it. The other views keep their rectangles, so the
  views then do not tile the frame, and the scene names a focused view it
  does not hold when that view is the one left out.
- **The refusal is in the echo area**, as a refused handler's is (`refused: `
  and `TextError.describe`), in the state the loop keeps and in the scene
  it publishes. It is the first refusal of the publish, and it replaces the
  echo a refused handler wrote in the same step.
- **A release that is refused** comes after the scene is published, for a
  snapshot that was released behind the loop. The loop keeps the new
  scene's snapshots all the same, and the refusal is in the echo area of
  the state it returns, so the next scene shows it.

Nothing here touches the layout or the windows: the state the loop keeps is
the one the handler left, with the echo set, and a well-formed state stays
well formed. A host still has to deal with a program of the loop that is
refused, because an `EditorM` can be; none is today, and a host prints one
that is instead of dropping it (`Headless.Running.attempt`).

One case is not seen: a snapshot of the last scene released behind the loop
while its text did not change. The loop asks nothing of a snapshot it
keeps, so nothing is refused, and the scenes go on naming a snapshot that
is gone until the text changes.

These are pinned by `ModelTest.loopChecks`, and through the headless host by
`ConfigTest.scriptChecks`.

## Where a new event handler goes

A new event is handled by a case of `Loop.handle`, which hands a handler of
its own the `Target` it acts on (`EditorState.focusedTarget?`, or the window
the event names) and the state. Its effect on the state and on the scene is
pinned by a check in `ModelTest.loopChecks`, on the models.

What a key does is not a handler's: keys, the commands they run and
rollback are pinned by `ModelTest.dispatchChecks`, on the models and the
test scheme.
-/

namespace Editor

/-- What a view showed: a buffer's text, the revision it was at, and the
snapshot taken of it then. -/
structure Loop.Shown where
  /-- The text. -/
  text : TextId
  /-- Its revision when the snapshot was taken. -/
  revision : Nat
  /-- The snapshot. -/
  snapshot : SnapshotId
  deriving DecidableEq, Repr

/-- What the loop saw of the editor state at its last publish, which the
next one compares its own with to know which files to check for a change
on disk ("Files that changed on disk", in the module docs). -/
structure Loop.Seen where
  /-- Whether the frame had the keyboard focus. -/
  focused : Bool := false
  /-- The buffers a window showed. -/
  shown : Array BufferId := #[]
  /-- The buffers that were modified. -/
  modified : Array BufferId := #[]
  /-- The buffers that were open. -/
  present : Array BufferId := #[]
  deriving DecidableEq, Repr

/-- What a step does to the pause of completion at point ("Completion at
point", in the module docs), for its host to carry out on the job clock. -/
inductive Loop.PauseChange where
  /-- Leave what is armed as it is. -/
  | keep
  /-- Withdraw what is armed, and arm a pause of each of `pauses`
  milliseconds for `view`. -/
  | arm (view : ViewId) (pauses : Array Nat)
  /-- Withdraw what is armed. -/
  | disarm
  deriving DecidableEq, Repr

/-- What a step does to the key hint delay ("Key hints", in the module docs),
for its host to carry out on the job clock. -/
inductive Loop.HintDelayChange where
  /-- Leave what is armed as it is. -/
  | keep
  /-- Withdraw what is armed, and arm a wait of `ms` milliseconds after
  which the hints of `generation` are due (`Loop.keyHintsDue`). -/
  | arm (generation ms : Nat)
  /-- Withdraw what is armed. -/
  | disarm
  deriving DecidableEq, Repr

/-- The pauses the loop last asked its host to arm: the view, and each
pause's milliseconds. -/
structure Loop.Pausing where
  /-- The view the pauses are for. -/
  view : ViewId
  /-- Each pause's milliseconds. -/
  pauses : Array Nat
  deriving DecidableEq, Repr

/-- The loop's own state, for a loop that runs the input scheme `scheme`:
the editor state, the snapshots the last scene named, and the scheme's
state.

The scheme is a parameter and not a field: an `InputScheme` has type-valued
fields, so it is in `Type 1`, and a loop is handed through `EditorM` and
`IO`, whose values are in `Type`. It has no equality, since a scheme's state
has none. -/
structure Loop (scheme : InputScheme) where
  /-- The editor state. -/
  state : EditorState
  /-- The snapshots the last scene published named, one a text. -/
  shown : Array Loop.Shown := #[]
  /-- The scheme's state after the last key. -/
  input : scheme.State := scheme.init
  /-- The scheme's state at rest: the last one in which nothing was pending
  and no command had just failed. It is what the scheme goes back to when
  the invocation a key yields does not run to its end. -/
  atRest : scheme.State := scheme.init
  /-- What the last publish saw of the editor state. -/
  seen : Loop.Seen := {}
  /-- The menu bar the scenes name: the one the last step, invocation or
  delivery was handed (`Keys.menu`, `keyedBy`), with its key equivalents
  as the registry's bindings then were; `none` until one is. -/
  menu : Option Menu := none
  /-- The minibuffer's text as the last publish read it, while a prompt
  with candidates was open; `none` otherwise ("Prompts", in the module
  docs). The reconciler of the prompt's jobs reads it (`completionJobs`). -/
  typed : Option String := none
  /-- The pauses of completion at point the loop last asked its host to arm,
  if any ("Completion at point", in the module docs). -/
  pausing : Option Loop.Pausing := none
  /-- What the last scene showed of tracked excerpts: each excerpt buffer, how
  many entries it had, and the indexes of the tracked excerpts its views
  showed ("After each event", in the module docs, step 4b). -/
  viewing : Array (BufferId × Nat × Array Nat) := #[]
  /-- The host clock's milliseconds at the last publish, once there was
  one. -/
  publishedAt : Option Nat := none

/-- What the loop does after a step. -/
inductive Loop.Next where
  /-- Pull the next event. -/
  | continue
  /-- End: the window was asked to close, the queue was quit, or a command
  asked the editor to quit and it can leave ("Quit", in the module
  docs). -/
  | stop
  deriving DecidableEq, Repr

/-- How long a command may take before it is logged as slow, in
milliseconds, unless a step is handed another threshold. -/
def Loop.slowAfter : Nat :=
  100

/-- The editor's frame padding when config sets none, in whole points: what
every window's text is inset by from its edges, and the bottom row at least
(`EditorState.paddingOf`). The host applies it (`Headless.keys`); a loop
handed no padding (`Loop.Keys.padding`) has none. -/
def Loop.padding : Nat :=
  8

/-- The editor's key hint delay when config sets none, in milliseconds: how
long a prefix is pending before the keys that can follow it are shown
("Key hints", in the module docs). The host applies it (`Headless.keys`);
a loop handed none (`Loop.Keys.keyHintDelay`) never shows them. -/
def Loop.keyHintDelay : Nat :=
  500

/-- How many candidates a prompt may have to match for the loop to list it
on the editor thread, in the scene of the step ("Prompts", in the module
docs): more are matched by a job, off the thread. Set by the prompt
benchmark (`mise run prompt-bench`, `docs/design/concurrency.md`,
"Matching off the editor thread, measured"): 250 is the largest size it
measured whose key's 99th percentile, listed inline, was under 1 ms. -/
def Loop.inlineMatches : Nat :=
  250

/-- What a step is handed beside the loop and the event: what the keys are
looked up in, and what an invocation runs. It is rebuilt by the caller for
each step, from the registry as it then is, so a reload changes it between
two events. -/
structure Loop.Keys (scheme : InputScheme) where
  /-- The active keymaps of each view in an editor state, in precedence
  order. The loop applies it to its own state. -/
  maps : EditorState → ViewId → List (Keymap scheme.Binding) := fun _ _ => []
  /-- The name of a prefix, given its keys as chords, for the key hints
  (`Loop.keyHints`): the registry's (`Config.Registry.prefixName?`), which
  the host hands; none for a loop handed none. -/
  prefixNames : List Key → Option String := fun _ => none
  /-- What an invocation of the command of a name runs: given what it is
  called with, the program, whose value is what the command asks to be
  written; `none` for a name no command is registered under. -/
  command? : String → Option (Call → EditorM (Option Config.Write)) := fun _ => none
  /-- How long a command may take before it is logged as slow, in
  milliseconds: one that takes longer is logged. -/
  slowAfter : Nat := Loop.slowAfter
  /-- What a command's state requests are told of the registry
  (`Editor/Command/Dispatch.lean`). Its `command` is not read: the loop
  tells a command run inside another what `command?` says of the name. -/
  registered : Loop.Registered := {}
  /-- The mode line the scene's status lines are drawn by: the registry's
  segments in the order config listed, or the default one
  (`Editor/ModeLine.lean`). -/
  modeLine : ModeLine := ModeLine.standard
  /-- The frame padding the scene's views are laid out with, in whole points
  (`EditorState.paddingOf`). It is 0 unless the host hands one: the
  editor's own default, `Loop.padding`, is applied by the host from config
  (`framePadding`, `Editor/Setup.lean`), so a loop handed none draws and
  scrolls as with no padding. -/
  padding : Nat := 0
  /-- The layout the frame's windows are arranged by (`Editor/Layout.lean`),
  which the publish sets on the frame before it lays the views out; `none`
  keeps the frame's own, so a state built by hand keeps the layout it was
  built with. The host hands config's choice, or the default
  (`Headless.keys`). -/
  layout : Option Layout := none
  /-- When the tab bar is shown (`Editor/TabBar.lean`), which the publish
  sets on the state (`EditorState.tabBarShown`); `none` keeps the state's.
  The host hands config's choice, or the editor's own (`Headless.keys`). -/
  tabBar : Option TabBar.Shown := none
  /-- The menu bar the scene names, its key equivalents filled from the
  registry's bindings as they are now (`Config.Registry.menuOf`,
  `Editor/Menu/Compiled.lean`); `none` for a host with no menu bar, whose
  scenes name none. -/
  menu : Option Menu := none
  /-- The styles a prompt's candidates are listed with, chosen by its
  category (`Editor/Completion/Style.lean`): the host hands the registry's,
  config's choices or the fuzzy style for every category
  (`Config.Registry.matching`, `Headless.keys`). It is looked up for each
  step and never kept in the state, so a reload changes it from the next
  listing. -/
  matching : Completion.Matching := Completion.Matching.standard
  /-- How many candidates a prompt may have to match for its listing to be
  made in the publish, on the editor thread; more are matched by a job of
  the loop's own ("Prompts", in the module docs). -/
  inlineMatches : Nat := Loop.inlineMatches
  /-- The displays a prompt's listing is shown with, chosen by its category
  (`Editor/Completion/Display.lean`): the host hands the registry's,
  config's choices or the minibuffer display for every category
  (`Config.Registry.displaying`, `Headless.Running.keys`). It is looked up
  for each step and never kept in the state, so a reload changes it from
  the next scene. -/
  displaying : Completion.Displaying := Completion.Displaying.standard
  /-- How long a prefix is pending before its key hints are shown ("Key
  hints", in the module docs). The host hands config's setting
  (`keyHintDelay`, `Editor/Setup.lean`) or the editor's own,
  `Loop.keyHintDelay` (`Headless.Running.keys`); a loop handed none never
  shows them, as a loop handed no padding has none. -/
  keyHintDelay : Completion.Keys.Delay := .never
  /-- The host clock's milliseconds at this step, which what is viewed of a
  tracked excerpt is timed by ("After each event", in the module docs, step
  4b). A loop handed none records 0, so every duration is 0. -/
  now : Nat := 0

/-- How a command the loop ran ended. -/
inductive Loop.Ending where
  /-- It ran to its end. -/
  | finished
  /-- It was refused, with `error`, and rolled back. -/
  | refused (error : TextError)
  /-- The interrupt flag was up before one of its requests, and it was
  rolled back. -/
  | interrupted
  /-- It gave up, with `reason`, and was rolled back. -/
  | gaveUp (reason : String)
  /-- It broke off, with `reason`: what it did was kept, and the scheme is
  back in its state at rest. -/
  | brokeOff (reason : String)
  /-- No command is registered under the name. -/
  | noSuchCommand
  /-- No window is focused for the command to act on. -/
  | noWindow
  deriving DecidableEq, Repr

/-- Work the loop hands its host to run as a job of its own ("Prompts", in
the module docs): not a `JobStart`, since the work is made by this step
(the style it chose and the candidates it matches), which no registered
name and no plain arguments can carry. A step's spawns are a one-shot
output and never state, so a spawn may hold a program. -/
structure Loop.Spawn where
  /-- The key it runs under: a spawn of a key ends the running job of that
  key first, as a start of a key does. -/
  key : String
  /-- What its delivery is labelled with, `job <id> <label>`. -/
  label : String
  /-- Whose job it is: an install that removes this owner's jobs ends it
  (`Jobs.removeOwner`). -/
  owner : Config.Owner := .compiled
  /-- The job. -/
  work : Work

/-- What a step hands back: the loop after it, and what to do next. A
one-shot output of a step is a field here. -/
structure Loop.Stepped (scheme : InputScheme) where
  /-- The loop after the step. -/
  loop : Loop scheme
  /-- Whether to pull the next event. -/
  next : Loop.Next
  /-- What the command the step ran asked to be written: the new tree of a
  store's cell, for whoever holds the cells to write back. `none` for a
  step that ran no command, and for one whose command did not run to its
  end. -/
  write : Option Config.Write := none
  /-- What the step has to say to whoever keeps a log, one entry a line: a
  command it ran that took longer than the threshold. The loop writes
  nothing itself. -/
  log : Array String := #[]
  /-- The jobs the command the step ran asked to be started, in the order it
  asked, for the host to start. None for a step that ran no command, and
  for one whose command did not run to its end. -/
  starts : Array JobStart := #[]
  /-- The invocations to run next, in order: the continuations of the
  prompts the command the step ran accepted, each with its answer as its
  first argument, and the invocations it asked to be run after it
  (`invoke`, `Editor/Api.lean`). They are for the host to run, each as a
  step of its own (`Loop.invoke`), before it pulls another event. None for
  a step that ran no command, and for one whose command did not run to its
  end. -/
  answered : Array Invocation := #[]
  /-- Whether the command the step ran asked for the config to be reloaded
  (`reloadConfig`, `Editor/Api.lean`), for the host to ask its config
  session. `false` for a step that ran no command, and for one whose
  command did not run to its end. -/
  reload : Bool := false
  /-- The theme the command the step ran asked to be loaded (`loadTheme`,
  `Editor/Api.lean`), for the host to switch to. `none` for a step that ran
  no command, for one whose command asked for none, and for one whose
  command did not run to its end. -/
  theme : Option String := none
  /-- How the command the step ran ended; `none` for a step that ran no
  command. -/
  ended : Option Loop.Ending := none
  /-- The keys of the jobs the host is to cancel: a cancel ends the job of
  that key, if there is one, even one that has finished and not yet been
  delivered, so its command never runs. Those the command the step ran
  asked for (`cancelJob`), when it ran to its end, come first, then the
  loop's own ("Jobs from commands", "Auto-reload", in the module docs). -/
  cancels : Array String := #[]
  /-- The work the loop hands its host to run as jobs of its own, each under
  its key (`Loop.Spawn`): a prompt's match ("Prompts", in the module docs).
  A host runs them after the cancels and the starts. -/
  spawns : Array Loop.Spawn := #[]
  /-- The view the step's key was for and the text it typed there, if it
  typed some, for a step that took a key or a committed text that was
  inserted; `none` for any other step ("Completion at point", in the module
  docs). -/
  key : Option (ViewId × Option String) := none
  /-- What the host is to do with the pause of completion at point: what
  `atPointAsks` said of the step's key, once its scene is published. -/
  pause : Loop.PauseChange := .keep
  /-- What the host is to do with the key hint delay: what `armedHints`
  said of the state the step's scene shows ("Key hints", in the module
  docs). -/
  hintDelay : Loop.HintDelayChange := .keep

namespace EditorState

/-- `state` with `refusal` in the echo area: `refused: ` and what it was. -/
def refused (state : EditorState) (refusal : TextError) : EditorState :=
  { state with echo := s!"refused: {refusal.describe}" }

/-- `state`, with `refusal` in the echo area if there is one. -/
def refusedBy (state : EditorState) : Option TextError → EditorState
  | some refusal => state.refused refusal
  | none => state

/-- Tells each buffer's undo tree the revision its text is at, and closes its
group, but for the buffers `held`, whose groups are left open: what an
event edited becomes one step of its history, and what is edited in a held
buffer goes on being one step with what is edited next. It is not refused:
a buffer whose text refuses, because it was released, keeps its history as
it was, and the first such refusal is handed back. -/
def recordHistories (state : EditorState) (held : Array BufferId := #[]) :
    TextM (EditorState × Option TextError) := do
  -- An excerpt buffer that is held holds the source buffers it touched, so
  -- a session typed in it is one step in each.
  let held :=
    held ++ held.flatMap fun id => (((state.buffer? id).bind (·.excerpts)).map (·.touched)).getD #[]
  let mut buffers := #[]
  let mut refusal := none
  for index in [0:state.buffers.size] do
    let some buffer := state.buffer? ⟨index⟩ |
      buffers := buffers.push none
      continue
    match ← observing buffer.history.sync with
    | .ok history =>
      let history := if held.contains ⟨index⟩ then history else history.close
      buffers := buffers.push (some { buffer with history })
    | .error error =>
      buffers := buffers.push (some buffer)
      refusal := refusal <|> some error
  -- Each excerpt buffer that is not held makes what it touched one step,
  -- over the source trees just closed.
  let state :=
    (List.range state.buffers.size).foldl
      (fun state index => if held.contains ⟨index⟩ then state else state.closeExcerptGroup ⟨index⟩)
      { state with buffers }
  return (state, refusal)

/-- `state` with the group of the buffer `id`'s history closed, its undo tree
told the revision its text is at first, as `recordHistories` closes every
group: what was edited in it becomes one step. A buffer there is none of is
left alone; a refusal of its text is handed back, with its history as it
was. -/
def closeGroupOf (state : EditorState) (id : BufferId) : TextM (EditorState × Option TextError) :=
  do
  let some buffer := state.buffer? id | return (state, none)
  match ← observing buffer.history.sync with
  | .ok history =>
    return ({ state with
          buffers := state.buffers.set! id.index (some { buffer with history := history.close }) },
        none)
  | .error error =>
    return (state, some error)

end EditorState

namespace Loop

variable {scheme : InputScheme}

/-- A loop that runs `scheme`, over the initial state, in a frame of `size`,
with nothing shown yet and no key typed. The first window's selection has
the shape the scheme reports of the first view before any key
(`InputScheme.report`). -/
def start (scheme : InputScheme) (size : Size) : TextM (Loop scheme) :=
  return { state := ← EditorState.initial size (scheme.report scheme.init ⟨0⟩).shape }

/-- The face of the minibuffer's status line, which is the prompt's label. -/
def promptFace : FaceName :=
  ⟨"minibuffer.prompt"⟩

/-- The fields of the minibuffer's status line for the prompt `asked`: its
label, in `promptFace`, alone. The candidates it has listed are the
candidate list's (`candidateListView`). -/
def promptStatus (asked : Prompt) : Array StatusField :=
  #[{ text := asked.label, face := promptFace }]

/-- The status line of the view `id` of `state`, whose window `context`
describes, and the face of its row: for the minibuffer's view the prompt's
label (`promptStatus`) and no face; for
any other the fields of `modeLine` (`ModeLine.fields`), and
`mode-line.active` for the selected window (`EditorState.selectedView`, the
asker while a prompt is open) or `mode-line.inactive` for one that is
not. -/
def statusOf (modeLine : ModeLine) (state : EditorState) (id : ViewId)
    (context : ModeLine.Context) : Array StatusField × Option FaceName :=
  let lined :=
    (modeLine.fields context,
      some (if context.selected then ModeLine.activeFace else ModeLine.inactiveFace))
  match state.prompt with
  | some asked => if asked.view == id then (promptStatus asked, none) else lined
  | none => lined

/-- What the mode line's segments read of the window `target`, the view `id`
of `state`, whose text is shown at `snapshot` and of which the scheme
reports the fields `reported` (`ModeLine.Context`): its buffer; its cursor,
the head of the primary range of its selection, as a row and a column in
cells of the snapshot; the snapshot's lines (`SnapshotId.lineCount`);
whether it is the selected view
(`EditorState.selectedView`); whether it is modified: a plain buffer
when it is (`Buffer.isModified`), and an excerpt buffer when a buffer over
one of its entries' sources is (`EditorState.bufferOver?`); and, for the
selected view only, `pending`, the keys pending (`pending`), which the
`pending-keys` segment draws. It is not refused: when the selection marker
or the snapshot does not answer, there is no cursor and no row. -/
def contextOf (state : EditorState) (id : ViewId) (target : Target) (snapshot : SnapshotId)
    (reported : Array StatusField) (pending : String := "") : TextM ModeLine.Context := do
  let marker := target.window.selection
  let read : TextM (Point × Nat) := do
    let .selection selection ← marker.text.marker marker | throw .noSuchMarker
    let some range := selection.ranges[selection.primary]? | throw .noSuchMarker
    let point ← snapshot.pointOf range.head .cells
    return (point, ← snapshot.lineCount)
  let (cursor, lines) :=
    match ← (observing read : TextM (Except TextError (Point × Nat))) with
    | .ok (point, lines) => (some point, lines)
    | .error _ => (none, 0)
  let modified :=
    match target.buffer.excerpts with
    | some excerpts =>
      excerpts.entries.any fun entry =>
        ((state.bufferOver? entry.source).bind state.buffer?).any (·.isModified)
    | none => target.buffer.isModified
  let selected := id == state.selectedView
  return {
      buffer := target.buffer, reported, cursor, lines, selected
      pending := if selected then pending else "", modified }

/-- The views of the loop's state, in drawing order, and the snapshots they
name: its windows, and the minibuffer's view in the minibuffer's place
while a prompt is open. A text at the revision it was last shown at keeps
its snapshot; any other is given a new one. A view's cursor is the one the
scheme reports of it, in the scheme's state after the last key
(`InputScheme.report`). Its status line is the fields of `modeLine` for its
window, read as `contextOf` reads it, and the prompt's label for the
minibuffer's view (`statusOf`). It is not refused: a view whose buffer's
text refuses, because it was released, is left out, with nothing taken for
it, and the first such refusal is handed back. -/
def views (loop : Loop scheme) (modeLine : ModeLine := ModeLine.standard) :
    TextM (Array View × Array Shown × Option TextError) := do
  let state := loop.state
  let mut shown : Array Shown := #[]
  let mut views : Array View := #[]
  let mut refusal := none
  for (id, rect) in state.rects do
    let some target := state.target? id | continue
    let text := target.buffer.text
    let taken ←
      observing do
          let revision ← text.revision
          match
            (shown ++ loop.shown).find? fun was => was.text == text && was.revision == revision with
          | some was =>
            pure (revision, was.snapshot)
          | none =>
            return (revision, ← text.snapshot)
    match taken with
    | .error error =>
      refusal := refusal <|> some error
    | .ok (revision, snapshot) =>
      unless shown.any (·.text == text) do
        shown := shown.push { text, revision, snapshot }
      let report := scheme.report loop.input id
      let context ←
        contextOf state id target snapshot report.status (Key.notations (scheme.pending loop.input))
      let (status, statusFace) := statusOf modeLine state id context
      -- An excerpt buffer's headers, placed by the snapshot shown, so the
      -- follow asks with them (`ExcerptView.blocksOf`).
      let blocks ← ExcerptView.blocksOf target.buffer snapshot
      views :=
        views.push
          { id, rect, snapshot, scroll := target.window.scroll,
            selections := #[target.window.selection]
            cursor := report.cursor, decorations := #[], status, statusFace
            padding := state.paddingOf id, blocks }
  return (views, shown, refusal)

/-- The face the matches of the last search are drawn in. -/
def searchMatchFace : FaceName :=
  ⟨"search-match"⟩

/-- The spans of `spans` that start before `stop` and end after `start`,
each clipped to `start` through `stop`, those left empty dropped, in order
("Decorations", in the module docs). -/
def spansIn (spans : Array Decoration) (start stop : Nat) : Array Decoration :=
  (spans.map fun span =>
        { span with
          start := max span.start start, stop := min span.stop stop }).filter
    fun span => span.start < span.stop

/-- The range of `view`'s snapshot its decorations and its gutter marks are
read over ("Decorations", in the module docs): from the row of its scroll
anchor through `rect.height / heights.text + 1` rows below, or the text's
end; `none` when its anchor is not a marker of its text. -/
def rangeOf (state : EditorState) (view : View) : TextM (Option (Nat × Nat)) := do
  let some target := state.target? view.id | return none
  let .anchor anchor ← target.buffer.text.marker view.scroll | return none
  let snapshot := view.snapshot
  let row := (← snapshot.pointOf anchor.offset).row
  -- A view of `n` display rows shows at most `n` text rows from its
  -- anchor's, however its rows wrap; one more is drawn, which nothing sees.
  let rows := view.rect.height / max 1 state.heights.text + 1
  let start ← snapshot.offsetOf ⟨row, 0⟩
  let stop ←
    if row + rows + 1 < (← snapshot.rowCount) then
      snapshot.offsetOf ⟨row + rows + 1, 0⟩
    else
      snapshot.byteLength
  return some (start, stop)

/-- The gutter marks of `view` in `state` ("Decorations", in the module docs):
its buffer's gutter's marks carried to the revision its snapshot shows and
clipped to its range (`Gutter.marksOf`); none for the minibuffer's view, a
buffer with no gutter, and a text that refuses. -/
def marksOf (state : EditorState) (view : View) : TextM (Array GutterMark) := do
  if state.prompt.map (·.view) == some view.id then
    return #[]
  let some target := state.target? view.id | return #[]
  try
    let some (start, stop) ← rangeOf state view | return #[]
    Gutter.marksOf target.buffer.text target.buffer.gutter view.snapshot start stop
  catch _ =>
    return #[]

/-- The decorations of `view` in `state` ("Decorations", in the module docs),
for a view that is not the minibuffer's, over the range from the row of the
view's scroll anchor through `rect.height / heights.text + 1` rows below:
for an excerpt buffer, its sources' spans, then its buffer's spans in that
range (`spansIn`), then what is not examined of its tracked excerpts
(`ExcerptView.unexaminedOf`), then, when there is a last search, each match
of its pattern there that is not empty, in `searchMatchFace`, in order. A pattern the syntax refuses draws no match,
and a text that refuses draws nothing. -/
def decorationsOf (state : EditorState) (view : View) : TextM (Array Decoration) := do
  if state.prompt.map (·.view) == some view.id then
    return #[]
  let some target := state.target? view.id | return #[]
  try
    let some (start, stop) ← rangeOf state view | return #[]
    let snapshot := view.snapshot
    -- An excerpt buffer's sources' spans come first, under its own.
    let sources := spansIn (← ExcerptView.sourceSpansOf state target.buffer snapshot) start stop
    -- What no scene has shown of a tracked excerpt, read before this
    -- scene marks what its rows show.
    let unexamined := spansIn (← ExcerptView.unexaminedOf target.buffer snapshot) start stop
    let spans := sources ++ spansIn target.buffer.spans start stop ++ unexamined
    let some search := state.lastSearch | return spans
    match ← snapshot.matches search.pattern start stop with
    | .ranges all =>
      return spans ++
          (all.filter fun extent => extent.start < extent.stop).map fun extent =>
            { start := extent.start, stop := extent.stop, face := searchMatchFace }
    | .invalid _ =>
      return spans
  catch _ =>
    return #[]

/-- `views` with their decorations (`decorationsOf`) and their gutter marks
(`marksOf`), each read with its scroll anchor where the follow left it. -/
def decorated (state : EditorState) (views : Array View) : TextM (Array View) :=
  views.mapM fun view =>
    return { view with
        decorations := ← decorationsOf state view, marks := ← marksOf state view }

/-- The face the dividers between tiled windows are drawn in, Emacs's
`window-divider`: the divider is filled in its foreground. -/
def dividerFace : FaceName :=
  ⟨"window-divider"⟩

/-- The scene of `state` over `views`: what the state says of the frame, the
dividers between its tiled windows (`EditorState.dividers`) in
`dividerFace`, the echo area, inset by the bottom row's inset
(`EditorState.bottomInset`), and the preedit, around the views made of its
windows, with `pending` as the keys typed of a sequence not yet completed,
`menu` as the menu bar and `keyHints` as the keys that can follow. -/
def scene (state : EditorState) (views : Array View) (pending : String) (menu : Option Menu := none)
    (keyHints : Array KeyHint := #[]) : Scene :=
  let frame := state.frame
  { size := frame.size, views
    dividers := state.dividers.map ({ rect := ·, face := dividerFace })
    focused := if frame.hasFocus then some frame.focused else none
    echo := state.echo, echoPadding := state.bottomInset, pending, keyHints
    preedit := state.preedit
    title := state.title, menu }

/-- The keys the scheme reports as pending in the loop's state, as a key
string (`Key.notations`): what the scene shows of a sequence begun and not
completed, and empty when none is. -/
def pending (loop : Loop scheme) : String :=
  Key.notations (scheme.pending loop.input)

/-- The keys that can follow the keymap prefix pending for the focused view,
as key hints (`InputScheme.continuations`, `Keymap.Continuation.hint`), over
the active keymaps and with the prefix names `keys` hands: what the scene
shows beside the pending keys, and none when no keymap prefix is pending. -/
def keyHints (keys : Keys scheme) (loop : Loop scheme) : Array KeyHint :=
  (scheme.continuations (keys.maps loop.state) keys.prefixNames loop.state.frame.focused
        loop.input).toArray.map
    (·.hint)

/-- The loop with its key hints opened or closed for `hints`, the keys that
can follow now, and what the host is to do with the delay ("Key hints", in
the module docs). The hints are wanted while some key can follow, nothing
is completing and the delay `keys` hands is not `.never`:

- open and no longer wanted: closed, and the delay withdrawn;
- not open and wanted: opened at a new generation, due at once with a
  delay of 0, and otherwise not due, with a wait of the delay armed for
  that generation;
- otherwise as they are, so a further prefix keeps hints that are due and
  arms no new delay.

It is pure. -/
def armedHints (keys : Keys scheme) (loop : Loop scheme) (hints : Array KeyHint) :
    Loop scheme × HintDelayChange :=
  let state := loop.state
  let wanted := !hints.isEmpty && state.completing?.isNone && keys.keyHintDelay != .never
  match state.keyHints, keys.keyHintDelay with
  | some _, _ =>
    if wanted then (loop, .keep)
    else ({ loop with state := { state with keyHints := none } }, .disarm)
  | none, .after ms =>
    if wanted then
      let generation := state.keyHintGeneration + 1
      let due := ms == 0
      ({ loop with
          state :=
            { state with
              keyHints := some { generation, due }, keyHintGeneration := generation } },
        if due then .keep else .arm generation ms)
    else (loop, .keep)
  | none, .never => (loop, .keep)

/-- The loop with its key hints opened or closed for the keys that can follow
now (`keyHints`, `armedHints`), and, when they are due and shown, listed:
the `key` source of those keys (`Completion.Keys.source`) asked with no
typed text, from the focused view. What the host is to do with the delay
comes with it. -/
def keyHinted (keys : Keys scheme) (loop : Loop scheme) : EditorM (Loop scheme × HintDelayChange) :=
  do
  let hints := loop.keyHints keys
  let (loop, change) := loop.armedHints keys hints
  if loop.state.hinting?.isNone then
    return (loop, change)
  let candidates ←
    (Completion.Keys.source hints).candidates { text := "", view := loop.state.frame.focused }
  return ({ loop with state := loop.state.listKeyHints candidates }, change)

/-- The key hints the scene shows: the keys that can follow (`keyHints`)
while the hints are shown (`EditorState.hinting?`), and none before their
delay has passed. -/
def shownHints (keys : Keys scheme) (loop : Loop scheme) : Array KeyHint :=
  if loop.state.hinting?.isSome then loop.keyHints keys else #[]

/-- The buffers in an insert session: the buffer of each window whose view
the scheme reports as in one (`InputScheme.Report.session`), in the scheme's
state after the last key. -/
def sessions (loop : Loop scheme) : Array BufferId :=
  loop.state.windows.filterMap fun window =>
    if (scheme.report loop.input window.id).session then some window.buffer else none

/-- What the loop does after a step whose scene has been published: stop
when the editor leaves (`EditorState.leaves`: a command asked it to quit,
no buffer has unsaved changes and no save is in flight), and go on
otherwise ("Quit", in the module docs). -/
def nextOf (loop : Loop scheme) : Next :=
  if loop.state.leaves then .stop else .continue

/-- The listing of `candidates` for `pattern` with `style`, as a program
over the fuzzy port: the candidates to match (`Candidates.matchable`) that
the style answers, in its order, each with the ranges that matched, then
those listed as given (`Candidates.passing`), every one in the order given,
none dropped, each with the ranges of the style's hit for it where the
style matches it and none where it does not; the hits' order is ignored.
No style is asked when there is nothing to match, nor for the passed
candidates when the pattern is empty. It is the one way a listing is made
("Prompts", in the module docs): in the publish for a short list, and in a
match job, on a pool thread, for a long one, so the editor thread never
maps the candidates of a long list. -/
def _root_.Editor.Candidates.listing (candidates : Candidates) (pattern : String)
    (style : Completion.Style) : FuzzyM (Array Completion.Listed) := do
  -- As they answer the pattern: no other directory's answer, and no hidden
  -- candidate the pattern does not reveal.
  let candidates := candidates.answering pattern
  let matchable := candidates.matchable
  let hits ←
    if matchable.isEmpty then
      pure #[]
    else
      style.hits pattern (matchable.map (·.text))
  let matched := hits.filterMap fun hit => (matchable[hit.index]?).map (.of · hit.ranges)
  let passing := candidates.passing
  let marks ←
    if passing.isEmpty || pattern.isEmpty then
      pure #[]
    else
      style.hits pattern (passing.map (·.text))
  -- Each passed candidate's ranges, by its index: the first hit for it.
  let ranges :=
    marks.foldl (init :=
      (Array.replicate passing.size none : Array (Option (Array Completion.Span))))
      fun ranges hit =>
      match ranges[hit.index]? with
      | some none => ranges.set! hit.index (some hit.ranges)
      | _ => ranges
  return matched ++
      passing.mapIdx fun index candidate => .of candidate ((ranges[index]?).join.getD #[])

/-- `state` with the open prompt's listing brought up to date ("Prompts", in
the module docs), and the minibuffer's text it read: while a prompt is open
and has candidates, given, passed or to come from a source that answers
later, the minibuffer's text is read. When the listing is not for that text
or not at the candidates' revision, a prompt with at most `inlineMatches`
candidates handed the style (`Candidates.listingSize`) is listed here (`Candidates.listing`, with the style
`matching` chooses for the prompt's category, and `Candidates.relist`,
which keeps the choice on its candidate while the text is the same); one
with more is listed by a match job (`completionJobs`), and here only
forgets its choice when the text changed. When the listing is already for
that text at that revision, a match still in flight is for a text or a
revision gone by, and is no longer in flight, so the reconciler cancels it.
A state with no prompt, or a prompt with no candidates, is as it was, and
nothing is read or asked. It is not refused: a refusal of the read is
handed back, with the state as it was. -/
def listed (state : EditorState) (matching : Completion.Matching := .standard)
    (inlineMatches : Nat := Loop.inlineMatches) :
    EditorM (EditorState × Option String × Option TextError) := do
  let some completing := state.completing? | return (state, none, none)
  let view := completing.view
  let candidates := completing.candidates
  if candidates.all.isEmpty && candidates.passed.isEmpty && candidates.asking.isEmpty then
    return (state, none, none)
  -- A session matches the text the user typed, never its region's text, so
  -- a preview is not matched against itself; a prompt its minibuffer's.
  let read : EditorM (Except TextError String) :=
    match completing.typed with
    | some typed => pure (.ok typed)
    | none =>
      match state.target? view with
      | some minibuffer => (observing minibuffer.buffer.text.read : TextM (Except TextError String))
      | none => pure (.error .noSuchMarker)
  match ← read with
  | .error error =>
    if completing.typed.isNone && (state.target? view).isNone then
      return (state, none, none)
    return (state, none, some error)
  | .ok pattern =>
    if candidates.listedFor == some pattern && candidates.listedAt == candidates.revision then
      -- The listing is current, so a match still running is for a text or a
      -- revision gone by (a key typed and undone while it ran): it is no
      -- longer in flight, so the reconciler cancels its job and its
      -- delivery, if it was already on its way, lists nothing.
      if candidates.matching.isSome then
        return (state.replaceCandidatesIn view { candidates with matching := none }, some pattern,
            none)
      return (state, some pattern, none)
    if (candidates.current pattern).listingSize ≤ inlineMatches then
      let listing ← candidates.listing pattern (matching.styleFor candidates.category)
      -- A match job that was running is overtaken by this listing.
      return (state.replaceCandidatesIn view
            { candidates.relist pattern candidates.revision listing with matching := none },
          some pattern, none)
    -- A long list is matched by a job: the choice was made in a listing for
    -- another text, and is forgotten.
    if candidates.listedFor == some pattern then
      return (state, some pattern, none)
    return (state.replaceCandidatesIn view { candidates with chosen := none }, some pattern, none)

/-- What the loop does to a session at point it closes ("Completion at
point", in the module docs): its markers are given up, its snapshots
released, and, when it made a preview, its buffer's group is closed, so the
previews and what was typed after them are one step. The first refusal is
handed back, and the rest is still done. -/
def closedAtPoint (state : EditorState) (session : AtPointSession) :
    TextM (EditorState × Option TextError) := do
  let mut refusal := none
  for id in [session.start, session.stop] do
    if let .error error← observing (id.text.unmark id) then
      refusal := refusal <|> some error
  for snapshot in session.candidates.texts do
    if let .error error← (observing snapshot.release : TextM (Except TextError Unit)) then
      refusal := refusal <|> some error
  if session.previewed then
    let (closed, unclosed) ← state.closeGroupOf session.buffer
    return (closed, refusal <|> unclosed)
  return (state, refusal)

/-- `state` with its session at point kept or closed ("Completion at point",
in the module docs), `report` being what the scheme says of a view. It is
closed, and handed back, when its view is not focused, is no window or
shows another buffer, when a prompt is open, when the view does not take
text (insert state was left), when its markers cannot be read, and when the
cursor is before its region's start or after its end. Otherwise, when the
region does not hold what the session last left there, the user edited it,
and its text is taken as what is typed (`retakeAtPoint`). With no session
it is as it was, and nothing is read. -/
def atPointKept (state : EditorState) (report : ViewId → InputScheme.Report) :
    TextM (EditorState × Option AtPointSession) := do
  let some session := state.atPoint | return (state, none)
  let close : TextM (EditorState × Option AtPointSession) :=
    pure ({ state with atPoint := none }, some session)
  let some target := state.target? session.view | return ← close
  if
      state.frame.focused != session.view || target.window.buffer != session.buffer ||
        state.prompt.isSome ||
        !(report session.view).takesText then
    return ← close
  match
    ←
      observing
          (do
            let (start, stop, text) ← session.region
            let selection ← target.selection
            let head := (selection.ranges[selection.primary]?).map (·.head)
            return (start, stop, text, head)) with
  | .error _ =>
    close
  | .ok (start, stop, text, head) =>
    match head with
    | none =>
      close
    | some head =>
      if head < start || stop < head then
        return ← close
      if text != session.shown then
        return ((state.retakeAtPoint text).2, none)
      return (state, none)

/-- `state` with its session at point closed, and handed back, when nothing
more is to come of its candidates and nothing is listed for what is typed
(`Candidates.exhausted`): the text stopped matching. When it never showed a
row and was not asked silently (`AtPointSession.silent`), the echo area says
`no completions`. -/
def atPointExhausted (state : EditorState) : EditorState × Option AtPointSession :=
  match state.prompt, state.atPoint with
  | none, some session =>
    if session.candidates.exhausted session.typed then
      ({ state with
          atPoint := none
          echo :=
            if session.tallest == 0 && !session.silent then AtPoint.noCompletions else state.echo },
        some session)
    else (state, none)
  | _, _ => (state, none)

/-- Has `view`, a view of the scene about to be published, follow its cursor
("Following the cursor", in the module docs): where the row of the cursor,
the head of the primary range of the view's selection, is not among the
rows the display answers from the view's scroll anchor, or is nearer an
edge of them than `margin` rows, the anchor's marker is placed where the
follow policy says (`Scroll.follow`, `Editor/Scroll.lean`), with the bias
it had. The display is asked with the view's own snapshot, rectangle and
padding.

A view of no height is not asked about: no request is made for it. A view
that shows no row keeps its anchor. Refused, with nothing placed, when a
marker of the view was given up or its snapshot released. -/
def follow (margin : Nat) (bottom : Nat) (view : View) : EditorM Unit := do
  -- No pixels hold no row under any layout.
  if view.rect.height == 0 then
    return
  let text := view.scroll.text
  let .anchor anchor ← text.marker view.scroll | throw .noSuchMarker
  let area := Scroll.Area.ofRect view.snapshot view.rect bottom view.padding view.blocks
  let shown ← area.rows anchor.offset
  if shown.isEmpty then
    return
  let some marker := view.selections[0]? | return
  let .selection selection ← text.marker marker | throw .noSuchMarker
  let some range := selection.ranges[selection.primary]? | return
  if let some offset← Scroll.follow area margin shown range.head then
    text.place view.scroll (.anchor { anchor with offset })

/-- Has each of `views` follow its cursor (`follow`), with the scroll margin
`margin`. It is not refused: a view whose follow is refused, because one of
its markers was given up or its snapshot released, is not followed, and the
refusal is dropped ("Following the cursor", in the module docs). -/
def followed (margin : Nat) (bottomOf : ViewId → Nat) (views : Array View) : EditorM Unit := do
  for view in views do
    discard <| observing (follow margin (bottomOf view.id) view)

/-- The snapshots of the saves in flight in `state`: one for each buffer
that has one (`Buffer.File.saving`). -/
def savesInFlight (state : EditorState) : Array SnapshotId :=
  state.buffers.filterMap fun slot => ((slot.bind (·.file)).bind (·.saving)).map (·.snapshot)

/-- Gives up what a command that ran to its end dropped ("What a finished
command gave up", in the module docs), `before` being the state from before
it and `after` the state it left: each marker of a window of `before` that
no window of `after` uses, then the snapshot of each save in flight in
`before` that is not in flight in `after`, and then the text of each buffer
of `before` whose slot is empty in `after`, unless a buffer of `after` is
over it. It is not refused: the first thing the store refuses is handed
back, and the rest is still given up. -/
def gaveUp (before after : EditorState) : TextM (Option TextError) := do
  let mut refusal := none
  let held := after.windows.flatMap fun window => #[window.selection, window.scroll]
  for window in before.windows do
    for id in [window.selection, window.scroll] do
      unless held.contains id do
        if let .error error← observing (id.text.unmark id) then
          refusal := refusal <|> some error
  -- The floats of every tab hold their anchors: selecting another tab gives
  -- none up, and closing one gives up its floats'.
  let anchored := (after.frame.tabs.flatMap (·.floats)).filterMap (·.anchor.marker?)
  for float in before.frame.tabs.flatMap (·.floats) do
    if let some id := float.anchor.marker? then
      unless anchored.contains id do
        if let .error error← observing (id.text.unmark id) then
          refusal := refusal <|> some error
  -- A session at point the state after does not hold gives up its
  -- markers, and a prompt or a session it does not hold its snapshots.
  if let some session := before.atPoint then
    unless after.atPoint.any (·.start == session.start) do
      for id in [session.start, session.stop] do
        if let .error error← observing (id.text.unmark id) then
          refusal := refusal <|> some error
  let texts (state : EditorState) : Array SnapshotId :=
    (state.prompt.map (·.candidates.texts)).getD #[] ++
      (state.atPoint.map (·.candidates.texts)).getD #[]
  let kept := texts after
  for snapshot in texts before do
    unless kept.contains snapshot do
      if let .error error← (observing snapshot.release : TextM (Except TextError Unit)) then
        refusal := refusal <|> some error
  let saving := savesInFlight after
  for snapshot in savesInFlight before do
    unless saving.contains snapshot do
      if let .error error← (observing snapshot.release : TextM (Except TextError Unit)) then
        refusal := refusal <|> some error
  for index in [0:before.buffers.size] do
    let some buffer := before.buffer? ⟨index⟩ | continue
    if (after.buffer? ⟨index⟩).isSome || after.buffers.any (·.any (·.text == buffer.text)) then
      continue
    if let .error error← observing buffer.text.release then
      refusal := refusal <|> some error
  return refusal

/-- The views `before` has a window of and `after` has none of: the views a
command that took the one to the other closed. -/
def closedViews (before after : EditorState) : Array ViewId :=
  before.windows.filterMap fun window =>
    if (after.window? window.id).isNone then some window.id else none

/-- `state`, a state of the loop's scheme, once it is told that each of
`views` is closed (`InputScheme.closeView`). -/
def forgetViews (views : Array ViewId) (state : scheme.State) : scheme.State :=
  views.foldl (fun state view => scheme.closeView view state) state

/-- Where each float of `state` anchored at a position is drawn in its
window's view, one of `views`, as the display answers (`Display.spotOf`):
from the view's top left, asked with the view's snapshot, its rectangle less
its bottom row, its padding, and its scroll anchor where the follow left it.
None when the view does not show the position, when the window has no view
or no height, and when a marker of it was given up or its snapshot
released: its anchor is not drawn ("After each event", in the module
docs). Each costs two text requests, the anchor marker and the view's
scroll anchor, and one display request. -/
def spots (state : EditorState) (views : Array View) :
    EditorM (Array (ViewId × Option Display.Spot)) :=
  state.frame.floats.filterMapM fun float => do
    let .position view marker := float.anchor | return none
    let some shown := views.find? (·.id == view) | return some (float.view, none)
    if shown.rect.height == 0 then
      return some (float.view, none)
    let answer ←
      observing do
          let .anchor anchor ← marker.text.marker marker | throw .noSuchMarker
          let .anchor scroll ← shown.scroll.text.marker shown.scroll | throw .noSuchMarker
          let area :=
            Scroll.Area.ofRect shown.snapshot shown.rect (state.bottomRow view) shown.padding
              shown.blocks
          area.spot scroll.offset anchor.offset
    return some (float.view, (answer : Except TextError (Option Display.Spot)).toOption.join)

/-- A view over generated text (`GeneratedView`, `Editor/GeneratedView.lean`)
in `rect`, holding `content` with `decorations`, what it shows, and `state`
with it kept by `keep`. `drawn?` is what `state` keeps of it so far: the
first time, with none, the text, its anchor marker at 0 and the view's id
(`EditorState.freshView`, with `nextView` past it) are made and kept; when
`content` differs from what the text holds, the text's content is replaced
with it. The snapshot is one of `shown` while the text is at its revision,
and a new one otherwise. The view has no selection, so no cursor is drawn,
no status field, so its whole strip is text rows, and the padding
`EditorState.paddingOf` gives its id. Its anchor stays at 0. It is not
refused: a refusal of the store is handed back, with no view. The tab bar's
view and the candidate list's are this (`tabBarView`, `candidateListView`). -/
def generatedView (state : EditorState) (drawn? : Option GeneratedView)
    (keep : EditorState → GeneratedView → EditorState) (rect : Rect) (content : String)
    (decorations : Array Decoration) (shown : Array Shown) :
    TextM (EditorState × Option (View × Shown) × Option TextError) := do
  let made ←
    observing do
        match drawn? with
        | some drawn =>
          pure (state, drawn)
        | none =>
          let text ← createText ""
          let scroll ← text.mark (.anchor { offset := 0, bias := .before })
          let view := state.freshView
          let drawn : GeneratedView := { view, text, scroll, content := "" }
          pure (keep { state with nextView := view.index + 1 } drawn, drawn)
  let (state, drawn) ←
    match made with
    | .ok made =>
      pure made
    | .error error =>
      return (state, none, some error)
  let taken ←
    observing do
        if content != drawn.content then
          drawn.text.replaceRange 0 (← drawn.text.byteLength) content
        let revision ← drawn.text.revision
        match shown.find? fun was => was.text == drawn.text && was.revision == revision with
        | some was =>
          pure was
        | none =>
          return { text := drawn.text, revision, snapshot := ← drawn.text.snapshot }
  match taken with
  | .error error =>
    return (state, none, some error)
  | .ok was =>
    let drawn := { drawn with content }
    let state := keep state drawn
    let view : View :=
      { id := drawn.view, rect, snapshot := was.snapshot, scroll := drawn.scroll
        selections := #[], cursor := { shape := .hollow, face := ⟨"cursor"⟩ }, decorations
        status := #[], padding := state.paddingOf drawn.view }
    return (state, some (view, was), none)

/-- The tab bar's view of `state` while the bar is shown
(`EditorState.tabBarRect?`, `Editor/TabBar.lean`), what it shows, and the
state with the bar drawn: a view over generated text (`generatedView`) kept
in `EditorState.tabBar`, whose content is the line of the tabs' labels
(`TabBar.line`) with its chips' faces, and the bar's padding. -/
def tabBarView (state : EditorState) (shown : Array Shown) :
    TextM (EditorState × Option (View × Shown) × Option TextError) := do
  let some rect := state.tabBarRect? | return (state, none, none)
  let labels := (Array.range state.frame.tabs.size).map state.tabLabel
  let (line, decorations) := TabBar.line labels state.frame.tabIndex
  generatedView state state.tabBar (fun state drawn => { state with tabBar := some drawn }) rect
      line decorations shown

/-- The candidate list's view of `state` while a prompt, a session at point
or the key hints shown have a list that has shown a row
(`EditorState.candidateListRect?`), what it shows, and the state with the
list drawn: a view over generated text (`generatedView`) kept in
`EditorState.candidateList`, whose content is the text of the sheet the
display answered at this publish (`EditorState.candidateSheet?`: the
prompt's, the session's or the hints', `Completion.Sheet.text`) with the
sheet's decorations, and the list's padding. Its anchor stays at 0: the
sheet holds only the rows shown. -/
def candidateListView (state : EditorState) (shown : Array Shown) :
    TextM (EditorState × Option (View × Shown) × Option TextError) := do
  let some rect := state.candidateListRect? | return (state, none, none)
  let some (sheet, _) := state.candidateSheet? | return (state, none, none)
  generatedView state state.candidateList
      (fun state drawn => { state with candidateList := some drawn }) rect sheet.text
      sheet.decorations shown

/-- What `views` of `state` show of tracked excerpts ("After each event", in
the module docs, step 4b): for each view of an excerpt buffer with a tracked
entry (`Buffer.ExcerptEntry.viewed`), the excerpts the rows the display
answers for it show (`ExcerptView.shown`), asked as the follow asks, with its
blocks; each buffer once, with how many entries it has and what its views
show between them. A view of no height and one whose questions are refused
show nothing. -/
def viewedBy (state : EditorState) (views : Array View) :
    EditorM (Array (BufferId × Nat × Array Nat)) := do
  let mut viewing : Array (BufferId × Nat × Array Nat) := #[]
  for view in views do
    if view.rect.height == 0 then
      continue
    let some target := state.target? view.id | continue
    let some excerpts := target.buffer.excerpts | continue
    unless excerpts.entries.any (·.viewed.isSome) do
      continue
    let asked : EditorM (Array Nat) := do
      let .anchor anchor ← view.scroll.text.marker view.scroll | throw .noSuchMarker
      let placed ← view.snapshot.excerpts
      let area :=
        Scroll.Area.ofRect view.snapshot view.rect (state.bottomRow view.id) view.padding
          view.blocks
      return ExcerptView.shown placed (← area.rows anchor.offset)
    let .ok indices ← (observing asked : EditorM (Except TextError (Array Nat))) | continue
    let id := target.window.buffer
    viewing :=
      match viewing.findIdx? (·.1 == id) with
      | some index =>
        viewing.modify index fun (id, count, was) =>
          (id, count, was ++ indices.filter (!was.contains ·))
      | none => viewing.push (id, excerpts.entries.size, indices)
  return viewing

/-- Records the histories, leaving open the group of each buffer in an insert
session (`sessions`), withdraws a quit that cannot go ahead
(`EditorState.settleQuit`), brings an open prompt's listing up to date
with the style `matching` chooses for its category (`listed`) and shows it
with the display `displaying` chooses (`EditorState.displayed`), has the
frame choose `layout` when one is handed that is not
the one it last chose (`Frame.choose`), sets when the tab bar is shown
from `tabBar` when one is handed, has
each view but the floats follow its cursor (`followed`), places the floats
anchored at a position where the display drew it and closes a transient
one whose anchor is not drawn (`spots`, `EditorState.located`), has the
floats follow their cursors, appends the candidate list's view while a
prompt's, a session's or the key hints' list has shown a row
(`candidateListView`; the hints are shown by the display `displaying`
chooses for the category `key`) and the tab bar's view
while the bar is shown (`tabBarView`), publishes a scene
of the state, with `keyHints` as its key hints (`shownHints`), releases each
snapshot the last scene named that this one does not, and gives up what
the floats it closed held, telling the scheme they closed. It is not refused
("When publishing is refused", in the module docs): a refusal of a buffer's
text is in the echo area of the scene it publishes, and one of a release in
the echo area of the state it returns. -/
def publish (loop : Loop scheme) (modeLine : ModeLine := ModeLine.standard) (padding : Nat := 0)
    (layout : Option Layout := none) (tabBar : Option TabBar.Shown := none)
    (matching : Completion.Matching := .standard) (inlineMatches : Nat := Loop.inlineMatches)
    (displaying : Completion.Displaying := .standard) (now : Nat := 0)
    (keyHints : Array KeyHint := #[]) : EditorM (Loop scheme) := do
  let (state, unrecorded) ← loop.state.recordHistories loop.sessions
  -- The histories know their texts' revisions now, so "unsaved" is right.
  let state := state.settleQuit
  -- A system quit that was refused or withdrawn is answered, once: the
  -- system stops waiting for the editor to quit ("Quit", in the module docs).
  let (state, keepRunning) := state.answerSystemQuit
  if keepRunning then
    Display.askFrame .keepRunning
  -- A session at point is kept or closed before it is listed: the cursor
  -- left its region, or insert state was left.
  let (state, unkept) ← atPointKept state (scheme.report loop.input)
  let (state, typed, unlisted) ← listed state matching inlineMatches
  -- One whose text stopped matching closes once it is listed.
  let (state, exhausted) := atPointExhausted state
  let mut closing := state
  let mut unclosed := none
  for session in unkept.toArray ++ exhausted.toArray do
    let (closed, refusal) ← closedAtPoint closing session
    closing := closed
    unclosed := unclosed <|> refusal
  -- The listing is shown before the views are laid out, so the rectangles
  -- of this scene are for the rows this scene shows.
  let state := closing.displayed displaying
  -- The heights of the rows, as the display answers them now, before the
  -- views are laid out: they size the views and the minibuffer's place.
  -- The padding the views are laid out with is the one handed in, and so
  -- is the layout, when one is.
  -- Config's layout is applied when it is not the one last applied, so a
  -- command's change to the layout lasts until config chooses another.
  let frame :=
    match layout with
    | some chosen =>
      if state.frame.chosen == some chosen then state.frame else state.frame.choose chosen
    | none => state.frame
  let state :=
    { state with
      heights := ← Display.heights, padding, frame
      tabBarShown := tabBar.getD state.tabBarShown }
  let (views, shown, unshown) ← ({ loop with state } : Loop scheme).views modeLine
  -- Each view follows its cursor before the scene names its anchor: the
  -- snapshots the questions of layout need were taken just above. Each is
  -- asked with its height less its bottom row. The floats follow once they
  -- are placed, below.
  let floating (state : EditorState) (view : View) : Bool := (state.frame.floating? view.id).isSome
  followed state.scrollMargin state.bottomRow (views.filter (!floating state ·))
  -- Each float anchored at a position is placed where the display drew it,
  -- in the views as the follow left them, and a transient one whose anchor
  -- is not drawn closes.
  let before := state
  let placed := state.located (← spots state views)
  let views :=
    views.filterMap fun view =>
      (placed.rect? view.id).map fun rect =>
        { view with
          rect, padding := placed.paddingOf view.id }
  followed placed.scrollMargin placed.bottomRow (views.filter (floating placed))
  -- The matches are read from where each anchor now is.
  let views ← decorated placed views
  -- What was viewed of tracked excerpts, once the decorations have read
  -- what was not examined: the last scene's time on screen is credited to
  -- what it showed, and what this scene's rows show is marked.
  let elapsed := now - loop.publishedAt.getD now
  let credited :=
    loop.viewing.foldl
      (fun (state : EditorState) (id, count, indices) =>
        if ((state.buffer? id).bind (·.excerpts)).any (·.entries.size == count) then
          state.creditViewed id indices elapsed
        else state)
      placed
  let viewing ← viewedBy credited views
  let placed :=
    viewing.foldl (fun (state : EditorState) (id, _, indices) => state.markViewed id indices now)
      credited
  -- The candidate list's view and then the tab bar's come last, once the
  -- views are followed and decorated: they are never followed and get no
  -- search match.
  let add (views : Array View) (shown : Array Shown) :
    Option (View × Shown) → Array View × Array Shown
    | some (view, was) =>
      (views.push view, if shown.any (·.snapshot == was.snapshot) then shown else shown.push was)
    | none => (views, shown)
  let (placed, listedView, unlistedView) ← candidateListView placed (shown ++ loop.shown)
  let (views, shown) := add views shown listedView
  let (placed, barred, unbarred) ← tabBarView placed (shown ++ loop.shown)
  let (views, shown) := add views shown barred
  let state :=
    placed.refusedBy
      (unrecorded <|> unlisted <|> unclosed <|> unshown <|> unlistedView <|> unbarred)
  Display.publish (scene state views loop.pending loop.menu keyHints)
  -- A snapshot is kept while a view of the scene names it: one taken for a
  -- float that closed above is released with the last scene's others.
  let named := shown.filter fun was => views.any (·.snapshot == was.snapshot)
  let taken := shown.filter fun was => !loop.shown.any (·.snapshot == was.snapshot)
  let mut unreleased := none
  for was in loop.shown ++ taken do
    unless named.any (·.snapshot == was.snapshot) do
      if let .error error← (observing was.snapshot.release : TextM (Except TextError Unit)) then
        unreleased := unreleased <|> some error
  -- The floats closed above give up their markers, and the scheme is told
  -- they closed, as for a command's closed windows.
  let closed := closedViews before placed
  let ungiven ←
    if closed.isEmpty then
      pure none
    else
      gaveUp before placed
  return { loop with
      state := state.refusedBy (unreleased <|> ungiven), shown := named
      input := forgetViews closed loop.input, atRest := forgetViews closed loop.atRest, typed
      viewing, publishedAt := some now }

/-- Replaces what each range of `target`'s selection covers with `text`, as
one transaction with the user's origin, which carries the selection before
and the cursors after, and places the selection at those cursors
(`Target.replaceSelections`, `Editor/Api.lean`). Refused with
`noSuchMarker` when the window's selection marker was given up. -/
def insert (target : Target) (text : String) : TextM Unit :=
  target.replaceSelections text

/-- What the echo area says when the first edit of the buffer of `path` was
refused because its file changed on disk, or, with `found = none`, is
gone. -/
def supersededSays (path : System.FilePath) : Option File.Stamp → String
  | some _ => Files.changedOnDisk path
  | none => Files.goneFromDisk path

/-- `state` once the commit of `text` into an excerpt buffer, `excerpt`,
shown by `target`, is dropped or inserted ("What each event does", in the
module docs): the sources what each range of the selection covers reaches
are looked for as the command dispatcher looks for them
(`excerptSources`, `Editor/Command/Dispatch.lean`). A read-only source
drops it, saying `<source> is read-only`; a text no buffer holds drops it,
saying `<buffer> reads a text no buffer holds`; a source buffer whose file
changed on disk unbeknown to the user drops it and says so, and the change
is then told. Otherwise it is inserted and the sources are touched. The
text inserted, if it was. -/
def commitExcerpts (state : EditorState) (target : Target) (excerpt : BufferId) (text : String) :
    EditorM (EditorState × Option String) := do
  let extents ← target.buffer.text.extents (← target.selection)
  let ranges := extents.map fun extent => (extent.start, extent.stop)
  match ← excerptSources state target.buffer.text ranges with
  | .error (.readOnly name) =>
    return ({ state with echo := EditorState.readOnlyReason name }, none)
  | .error .unheld =>
    return ({ state with echo := EditorState.unheldReason target.buffer.name }, none)
  | .error (.untold buffer path found) =>
    let (_, told) := state.tellChanged buffer
    return ({ told with echo := supersededSays path found }, none)
  | .ok sources =>
    insert target text
    return (state.touch excerpt sources, some text)

/-- What `event` does to `state` ("What each event does", in the module
docs), `report` being what the scheme says of the focused view, and the text
it inserted: a committed text is inserted only where the report says the
view takes text, its buffer is not read-only, its buffer's file did not
change on disk unbeknown to the user, and, for an excerpt buffer, no source
it reaches says otherwise (`commitExcerpts`). None for any other event, and
for a commit that is dropped. -/
def handle (state : EditorState) (report : InputScheme.Report := {}) :
    Event → EditorM (EditorState × Option String)
  | .preedit text => return ({ state with preedit := if text.isEmpty then none else some text }, none)
  | .compositionDisabled => return ({ state with preedit := none }, none)
  | .resize resize =>
    return ({ state with
          frame :=
            { state.frame with
              size := ⟨resize.width, resize.height⟩, fullscreen := resize.fullscreen
              corner := resize.corner, top := resize.top } },
        none)
  | .focus gained => return ({ state with frame := { state.frame with hasFocus := gained } }, none)
  | .commit text => do
    let some target := state.focusedTarget? | return ({ state with preedit := none }, none)
    unless report.takesText do
      return ({ state with preedit := none }, none)
    -- A commit into a read-only buffer is dropped and said, as a command's
    -- edit gives up, with no command to name.
    if let some (_, name) := state.readOnly? target.buffer.text then
      return ({ state with echo := EditorState.readOnlyReason name, preedit := none }, none)
    -- The first edit after a change on disk the user was not told of is
    -- dropped and said, as a command's is refused ("Files that changed on
    -- disk", in the module docs).
    if let some (buffer, path, found) := state.untold? target.buffer.text then
      let (_, told) := state.tellChanged buffer
      return ({ told with echo := supersededSays path found, preedit := none }, none)
    match state.excerptBufferOver? target.buffer.text with
    | some excerpt =>
      let (state, typed) ← commitExcerpts state target excerpt text
      return ({ state with preedit := none }, typed)
    | none =>
      insert target text
      return ({ state with preedit := none }, some text)
  | _ => return (state, none)

/-- Whether the loop steps `event` through its scheme: a key press, a
repeat among them, whose key is not a modifier by itself
(`Key.isModifier`). The key it steps, if so. -/
def stepped? : Event → Option Key
  | .key key true _ => if key.isModifier then none else some key
  | _ => none

/-- What the loop keeps before a command, to roll back to if the command
does not run to its end ("Rollback", in the module docs). -/
structure Kept where
  /-- For each buffer whose text answered, by its index in the state's
  buffers: the state of its undo tree, once told the revision the text was
  at. -/
  histories : Array (Nat × UndoTree.State) := #[]
  /-- Each window's selection marker and scroll marker that answered, as it
  was read. -/
  markers : Array (MarkerId × Marker) := #[]
  deriving DecidableEq, Repr

/-- What to roll back to from `state`: each buffer's history state and each
window's markers, as they are now. It is not refused: a buffer whose text
refuses, and a marker that does, is not kept. -/
def keep (state : EditorState) : TextM Kept := do
  let mut histories := #[]
  for index in [0:state.buffers.size] do
    let some buffer := state.buffer? ⟨index⟩ | continue
    -- An excerpt buffer's own tree is not kept: its text keeps no inverse
    -- to revert it by, and its sources are buffers of their own.
    if buffer.excerpts.isSome then
      continue
    if let .ok history← observing buffer.history.sync then
      histories := histories.push (index, history.state)
  let mut markers := #[]
  for window in state.windows do
    for id in [window.selection, window.scroll] do
      if let .ok marker← observing (id.text.marker id) then
        markers := markers.push (id, marker)
  return { histories, markers }

/-- Rolls one buffer's text back to the history state `was`, which `kept`,
the buffer's tree from before the command, was in when it was kept. `left`
is the tree the command left. Each tree it reverts is told the revision the
text is at first, and each revert is made with the user's origin. The tree
after it, and whether the history moved since `was` was kept.

- `left` is reverted to `was` when `was` is a state of its open group: the
  command set no boundary and made no move it did not make back.
- Otherwise the command set a boundary or moved. When `left` still has
  every edge of `kept` (`UndoTree.keepsEdgesOf`), `kept` is reverted to
  `was`: its open group is everything since, across the steps the command
  closed, and none of them is left. The store refuses that when the command
  also moved over a step of its own.
- Otherwise the history moved: the move is not taken back, and the group
  that is open in `left` is reverted instead, which takes back the edits
  made since the move. -/
def revertBuffer (kept left : UndoTree) (was : UndoTree.State) : TextM (UndoTree × Bool) := do
  let history ← left.sync
  if let some reverted← history.revertTo was Origin.user then
    return (reverted.tree, false)
  if left.keepsEdgesOf kept then
    -- Refused, with nothing changed, when the command moved over a step of
    -- its own: the move dropped inverses of the run this would take back.
    let whole ←
      observing do
          (← kept.sync).revertTo was Origin.user
    if let .ok (some reverted) := whole then
      return (reverted.tree, false)
  match ← history.revert Origin.user with
  | some reverted =>
    return (reverted.tree, true)
  | none =>
    return (history, true)

/-- Rolls back to what was kept ("Rollback", in the module docs), from
`before`, the state from before the command, and `after`, the state the
command left: each kept buffer's text is reverted to its kept history
state (`revertBuffer`), from the tree the buffer has in `before` and the
one it has in `after`, when `after` still has it over the same text, and
each kept marker is placed back. The tree that comes back is given the
saved state the buffer's tree has in `before`. Returns `before`
with the buffers' histories after it, and what to say of the rollback after
the command's error, which is nothing when all of it was done.

It is not refused. The first thing that refuses is said, `; not rolled
back: ` and the refusal, and the rest is still done. A buffer whose history
moved since it was kept is said too, `; the command moved in the history`,
and the markers of its text are left where the store moved them. -/
def Kept.restore (kept : Kept) (before after : EditorState) : TextM (EditorState × String) := do
  let mut buffers := before.buffers
  let mut refusal : Option TextError := none
  let mut moved : Array TextId := #[]
  for (index, was) in kept.histories do
    let some (some buffer) := buffers[index]? | continue
    -- The tree the command left knows of a move the command made, and of
    -- the boundaries it set.
    let left :=
      match after.buffer? ⟨index⟩ with
      | some left => if left.text == buffer.text then left.history else buffer.history
      | none => buffer.history
    match ← observing (revertBuffer buffer.history left was) with
    | .ok (reverted, movedSince) =>
      -- The tree that was reverted may be the one the command left, which
      -- carries a mark of the saved state the command set: the mark from
      -- before the command is put back.
      let history := { reverted with saved := buffer.history.saved }
      buffers := buffers.modify index (·.map ({ · with history }))
      if movedSince then
        moved := moved.push buffer.text
    | .error error =>
      refusal := refusal <|> some error
  for (id, marker) in kept.markers do
    unless moved.contains id.text do
      if let .error error← observing (id.text.place id marker) then
        refusal := refusal <|> some error
  let history := if moved.isEmpty then "" else "; the command moved in the history"
  let unrestored :=
    match refusal with
    | some error => s!"; not rolled back: {error.describe}"
    | none => ""
  return ({ before with buffers }, history ++ unrestored)

/-- The minibuffer's view a command that took `before` to `after` opened:
the view of the prompt that is open in `after`, unless it was the open
prompt's in `before`. -/
def openedMinibuffer (before after : EditorState) : Option ViewId :=
  after.minibufferView?.filter (some · != before.minibufferView?)

/-- `state`, a state of the loop's scheme, once it is told of what a command
did to the views: that each of `closed` is closed (`forgetViews`), and then
that `opened`, if there is one, is the minibuffer's
(`InputScheme.openMinibuffer`). -/
def toldViews (closed : Array ViewId) (opened : Option ViewId) (state : scheme.State) :
    scheme.State :=
  let state := forgetViews closed state
  match opened with
  | some view => scheme.openMinibuffer view state
  | none => state

/-- What running a command came to. -/
structure Ran where
  /-- The editor state after it, with what it left in the echo area. -/
  state : EditorState
  /-- How the command ended. -/
  ending : Ending
  /-- The views the command closed, when it ran to its end. -/
  closed : Array ViewId := #[]
  /-- The minibuffer's view the command opened, when it ran to its end and
  left a prompt open that was not open before it. -/
  opened : Option ViewId := none
  /-- What the command asked to be written, when it ran to its end. -/
  write : Option Config.Write := none
  /-- The log entry of a command that took longer than the threshold. -/
  log : Array String := #[]
  /-- What the command asked to be handed on, when it ran to its end or
  broke off (`EditorState.outbox`); empty for a command that did not. -/
  outbox : EditorState.Outbox := {}
  /-- What the command typed in place of typed text, each with its view,
  when it ran to its end (`EditorState.retyped`): the input scheme is told
  it as committed text (`ranInto`). -/
  retyped : Array (ViewId × String) := #[]

/-- Whether the command ran to its end: one that broke off did not, though
what it did was kept. -/
def Ran.finished (ran : Ran) : Bool :=
  ran.ending == .finished

/-- `state` with what became of the command called `name` in the echo
area: its name, then `what`. -/
def said (state : EditorState) (name what : String) : EditorState :=
  { state with echo := s!"{name}: {what}" }

/-- The log entries of the command called `name`, which took `took`
milliseconds: one, with its name and how long it took, when that is more
than `threshold`, and none otherwise. -/
def slow (name : String) (took threshold : Nat) : Array String :=
  if took > threshold then #[s!"slow command: {name} took {took} ms"] else #[]

/-- What a command gives up with when a command it had run inside it, the
one registered under `name`, asked for a store to be written: only the
command the loop runs has its write written back ("A command run inside
another", in the module docs). -/
def writesInside (name : String) : String :=
  s!"{name} writes a store, which a command run inside another cannot"

/-- The key sequences that reach a command in each view, as the scheme says
in `input`, over the active keymaps of `state` (`InputScheme.keyBindings`):
what a command run in a step whose scheme state is `input` is answered when
it asks. A function, so nothing is listed for a step whose command does not
ask. -/
def keyBindingsIn (keys : Keys scheme) (state : EditorState) (input : scheme.State) :
    ViewId → Array KeyBinding := fun view =>
  (scheme.keyBindings (keys.maps state) view input).toArray

/-- Runs `command` from `state`, under `name`, as the loop runs every
command ("Every command goes through the loop", in the module docs):
dispatched (`EditorM.dispatched`: guarded, with its state requests answered
from `state`). The state of a command that ran to its end is the one it
left, with its outbox (`EditorState.Outbox`) taken out and handed back.
It is not refused: a refusal of the command, an interrupt and the reason
of a command that gave up are each said in the echo area, after `name`,
and a command that was refused or interrupted, or that gave up, is rolled
back to the state from before it, with what could not be said after it.
The reason of a command that broke off is said the same way, and the
state it reached is kept as that of a command that ran to its end is.

A command the command has run inside it is the one `keys` has of the name
(`Loop.Keys.command?`), and one that asks for a store to be written gives
the command up ("A command run inside another", in the module docs).

Only the command is guarded. What this makes of its own requests, keeping
before it, rolling back after it and giving up what a command that ran to
its end dropped (`gaveUp`), is not, so a flag that is up does not stop a
rollback.

The clock is read just before the command and just after it, however it
ended, and a command that took longer than the threshold is logged
(`slow`). Keeping and rolling back are not timed.

The command is answered `keyBindings` when it asks which key sequences
reach a command in a view: what the scheme says in the state of the step
that runs it (`keyBindingsIn`), or none for a command no step hands it
to, as a job's. -/
def dispatch (keys : Keys scheme) (state : EditorState) (name : String)
    (command : EditorM (Option Config.Write))
    (keyBindings : ViewId → Array KeyBinding := fun _ => #[]) : EditorM Ran := do
  let kept ← keep state
  let started ← Watch.now
  -- A command run inside this one is looked up as an invocation's is, and
  -- gives this one up if it asks for a write.
  let registered : Registered :=
    { keys.registered with
      matching := keys.matching
      keyBindings
      command := fun inside =>
        (keys.command? inside).map fun run call => do
          if (← run call).isSome then
            giveUp (writesInside inside) }
  let (outcome, left) ← command.dispatched registered state
  let log := slow name ((← Watch.now) - started) keys.slowAfter
  let failed (what : String) (ending : Ending) : EditorM Ran := do
    let (state, unrestored) ← kept.restore state left
    return { state := said state name (what ++ unrestored), ending, log }
  -- What the command did stays: `left`, the state it reached, is the loop's.
  let stays (left : EditorState) (ending : Ending) (write : Option Config.Write) : EditorM Ran := do
    let ungiven ← gaveUp state left
    return {
        state :=
          { left.refusedBy ungiven with
            outbox := {}, retyped := #[] }
        ending
        closed := closedViews state left
        opened := openedMinibuffer state left
        write
        log
        outbox := left.outbox
        retyped := if ending == .finished then left.retyped else #[] }
  match outcome with
  | .finished write =>
    stays left .finished write
  | .refused refusal =>
    failed s!"refused: {refusal.describe}" (.refused refusal)
  | .interrupted =>
    failed "interrupted" .interrupted
  | .gaveUp reason =>
    failed reason (.gaveUp reason)
  | .brokeOff reason =>
    stays (said left name reason) (.brokeOff reason) none
  | .superseded buffer path found =>
    -- Rolled back as a command that gave up is; the told flag is written
    -- on the restored state, so it survives the rollback, and the echo
    -- area has no command name before it.
    let (state, _) ← kept.restore state left
    let (_, state) := state.tellChanged buffer
    let reason := supersededSays path found
    return { state := { state with echo := reason }, ending := .gaveUp reason, log }

/-- Runs `invocation`, which the keys `typed` yielded, from `state` ("Running
an invocation", in the module docs): clears the echo area, looks the
command up, and runs it (`dispatch`) with the focused window, the
invocation's arguments, the keys, and `report`, what the scheme says of the
focused view. It is not refused: a name with no command and a state with no
focused window are each said in the echo area, as what became of a command
that did not run to its end is. -/
def run (keys : Keys scheme) (state : EditorState) (invocation : Invocation) (typed : List Key)
    (report : InputScheme.Report := {}) (keyBindings : ViewId → Array KeyBinding := fun _ => #[]) :
    EditorM Ran := do
  let state := { state with echo := "" }
  let name := invocation.command
  let some command :=
    keys.command?
      name | return { state := said state name "no such command", ending := .noSuchCommand }
  let some target :=
    state.focusedTarget? | return { state := said state name "no window is focused", ending := .noWindow }
  dispatch keys state name
      (command { target, arguments := invocation.arguments, keys := typed, report }) keyBindings

/-- What a step that ran a command hands back, before its scene is
published: `loop` with the state the command left, and the scheme's two
states told of each view the command closed and of the minibuffer's view it
opened (`toldViews`). -/
def ranInto (loop : Loop scheme) (ran : Ran) : Stepped scheme :=
  -- What the command typed in place of typed text is committed text the
  -- scheme saw no key of: both states are told, as for a commit.
  let told (state : scheme.State) : scheme.State :=
    ran.retyped.foldl (fun state (view, text) => scheme.committed view text state) state
  { loop :=
      { loop with
        state := ran.state
        input := told (toldViews ran.closed ran.opened loop.input)
        atRest := told (toldViews ran.closed ran.opened loop.atRest) }
    next := .continue
    write := ran.write
    log := ran.log
    starts := ran.outbox.starts
    answered := ran.outbox.answered
    reload := ran.outbox.reload
    theme := ran.outbox.theme
    ended := some ran.ending
    cancels := ran.outbox.cancels }

/-- One key through the scheme, for the focused view, and the invocation it
yields, if it yields one, run (`run`): what the step hands back, with the
loop after them, whose scene is not yet published. The keys the command is
told of are what the scheme reported as pending before the key, then the
key's chord, and the report it is told of is the scheme's of the focused
view in its state after the key: the key that enters a state of the
scheme's runs its command in that state.

The scheme's state after the key is kept, and it is the state at rest from
then on, when the invocation ran to its end, or when the key yielded
nothing and left nothing pending. When the invocation did not run to its
end the scheme goes back to its state at rest: it is as it was before the
first key of the sequence. -/
def key (keys : Keys scheme) (loop : Loop scheme) (key : Key) : EditorM (Stepped scheme) := do
  let before := scheme.pending loop.input
  let (input, yielded) := scheme.step (keys.maps loop.state) loop.state.frame.focused loop.input key
  let focused := loop.state.frame.focused
  let some invocation := yielded |
    return {
        loop :=
          { loop with
            input, atRest := if (scheme.pending input).isEmpty then input else loop.atRest }
        next := .continue, key := some (focused, none) }
  let ran ←
    run keys loop.state invocation (before ++ [key.chord]) (scheme.report input focused)
        (keyBindingsIn keys loop.state input)
  -- The key typed its text where typing was text before it and after it,
  -- outside the minibuffer, and its command ran to its end.
  let typed :=
    if
        ran.finished && (scheme.report loop.input focused).takesText &&
          (scheme.report input focused).takesText &&
          loop.state.minibufferView? != some focused then
      key.printed?
    else none
  if ran.finished then
    return {
        ({ loop with
                input, atRest := input } :
              Loop scheme).ranInto
          ran with
        key := some (focused, typed) }
  else
    return { ({ loop with input := loop.atRest } : Loop scheme).ranInto ran with
        key := some (focused, none) }

/-- What `state` shows the loop of itself, for the next publish to compare
with ("Files that changed on disk", in the module docs). -/
def seenOf (state : EditorState) : Seen :=
  let present :=
    (List.range state.buffers.size).filterMap fun index =>
      (state.buffer? ⟨index⟩).map fun _ => (⟨index⟩ : BufferId)
  { focused := state.frame.hasFocus
    shown := state.windows.map (·.buffer)
    modified := present.toArray.filter fun id => (state.buffer? id).any (·.isModified)
    present := present.toArray }

/-- The files of `state` that are due a check, `seen` being what the last
publish saw ("Files that changed on disk", in the module docs): every file
buffer with no save in flight, when the frame gained the keyboard focus;
otherwise one shown now that was open and shown by no view then, and one
modified now that was open and unmodified then. A buffer opened since is
not due: its stamp is a moment old. -/
def dueChecks (seen : Seen) (state : EditorState) : Array Files.Checked :=
  let now := seenOf state
  let gained := now.focused && !seen.focused
  now.present.filterMap fun id => do
    let buffer ← state.buffer? id
    let file ← buffer.file
    if file.saving.isSome then
      none
    let switched := now.shown.contains id && !seen.shown.contains id
    let edited := now.modified.contains id && !seen.modified.contains id
    if gained || (seen.present.contains id && (switched || edited)) then
      some { buffer := id, path := file.path, stamp := file.stamp }
    else
      none

/-- The reconciler of auto-reload ("Auto-reload", in the module docs): the
state with what it follows brought in step with what it should follow, the
follow jobs to start, and the keys of those to cancel. It wants every open
file buffer with no save in flight while auto-reload is in effect and
`follow-file` is registered, and nothing otherwise. A refused entry stays,
and is not armed again, while it is wanted. -/
def reconcile (state : EditorState) (keys : Keys scheme) :
    EditorState × Array JobStart × Array String :=
  let on := state.autoReload.getD keys.registered.autoReload && keys.registered.jobs Files.followJob
  let wanted : Array (BufferId × Buffer.File) :=
    if on then
      (seenOf state).present.filterMap fun id => do
        let file ← (← state.buffer? id).file
        if file.saving.isSome then
          none
        else
          some (id, file)
    else #[]
  let wants (entry : Following) : Bool :=
    wanted.any fun (id, file) =>
      id == entry.buffer && file.path == entry.path && file.stamp == entry.stamp
  let kept := state.following.filter wants
  let cancels := (state.following.filter (!wants ·)).map (Following.keyOf ·.buffer)
  let arming := wanted.filter fun (id, _) => !kept.any (·.buffer == id)
  let starts : Array JobStart :=
    arming.map fun (id, file) =>
      { name := Files.followJob
        arguments :=
          Files.FollowOrder.arguments
            { buffer := id, path := file.path, stamp := file.stamp
              expected := (file.changed.map (·.found)).getD (some file.stamp) }
        key := some (Following.keyOf id) }
  ({ state with
      following :=
        kept ++
          arming.map fun (id, file) => { buffer := id, path := file.path, stamp := file.stamp } },
    starts, cancels)

/-- The loop after a publish, with what it saw kept, the jobs it starts and
the keys of those it cancels: one `check-files` holding every file that is
due (`dueChecks`), where that job is registered; and the follow jobs of
auto-reload's reconciler (`reconcile`). -/
def fileJobs (loop : Loop scheme) (keys : Keys scheme) :
    Loop scheme × Array JobStart × Array String :=
  let due := dueChecks loop.seen loop.state
  let checks :=
    if keys.registered.jobs Files.checkJob && !due.isEmpty then
      #[{ name := Files.checkJob, arguments := Files.checkArguments due }]
    else #[]
  let (state, follows, cancels) := reconcile loop.state keys
  ({ loop with
      seen := seenOf loop.state, state },
    checks ++ follows, cancels)

/-- The key the job of the source `source` of the prompt in `view` runs
under ("Prompts", in the module docs). -/
def sourceKey (view : ViewId) (source : String) : String :=
  s!"completion {view.index} {source}"

/-- The key the match job of the prompt in `view` runs under. -/
def matchKey (view : ViewId) : String :=
  s!"completion-match {view.index}"

/-- What a match job's delivery is labelled with, `job <id> completion-match`,
and what it says before why it could not list. -/
def matchLabel : String :=
  "completion-match"

/-- The work of a match job: the listing of `candidates` for `pattern` with
`style` (`Candidates.listing`), made on the job's thread over the job
port's matcher (`Job.embedFuzzy`), finishing with the command that lists it
in the prompt open in `view`, if it is still the match in flight
(`StateRequest.listMatched`). A matcher that fails finishes it with the
command that says so (`StateRequest.matchFailed`): a match job that is not
cancelled always delivers, and its delivery always ends the match in
flight. -/
def matchWork (view : ViewId) (candidates : Candidates) (pattern : String) (revision : Nat)
    (style : Completion.Style) : Work := fun _ => do
  let listed : Except String (Array Completion.Listed) ←
    try
      pure (.ok (← Job.embedFuzzy (candidates.listing pattern style)))
    catch message =>
      pure (.error message)
  match listed with
  | .ok listed =>
    return EditorState.ask (.listMatched view pattern revision listed)
  | .error message =>
    return EditorState.ask (.matchFailed view pattern revision message)

/-- The reconciler of the open prompt's jobs ("Prompts", in the module
docs), pure over `loop.state` and the text the last publish read
(`Loop.typed`): the loop with what the prompt holds of its jobs brought up
to date, the source jobs to start, the keys to cancel, and the match to
spawn.

- **Each asking source** whose job is registered is asked once: its job
  starts under `sourceKey`, at generation 1, for the text it was asked
  with and with no pause. A source that depends on the text and was asked
  with another than the typed one (`Reask.asksAgain`) has its key
  cancelled and its job started again at the next generation, for the
  typed text, after its pause; what it answered stays listed until the new
  generation's first batch.
- **The match**: a prompt with more candidates handed the style than
  `keys.inlineMatches` (`Candidates.listingSize`), whose listing is not for the typed text at the
  candidates' revision, and for which no match is in flight and none
  failed for that text and revision (`Candidates.unmatched`), has one
  spawned under `matchKey`, of the owner of its style
  (`Completion.Matching.ownerFor`), and recorded as in flight, stamped with
  the config generation (`Loop.Registered.generation`). One stamped with an
  older generation was ended by an install: its key is cancelled and it is
  spawned again with the style the new config chose.
- **Closing**: every key recorded for the prompt's jobs
  (`EditorState.completionKeys`) that the open prompt does not want, all
  of them once no prompt is open, is cancelled. -/
def completionJobs (loop : Loop scheme) (keys : Keys scheme) :
    Loop scheme × Array JobStart × Array String × Array Spawn :=
  let state := loop.state
  match state.completing? with
  | none =>
    ({ loop with state := { state with completionKeys := #[] } }, #[], state.completionKeys, #[])
  | some completing =>
    let view := completing.view
    let candidates := completing.candidates
    -- The sources' jobs.
    let (asking, starts, cancels, wanted) :=
      (List.range candidates.asking.size).foldl (init :=
        (candidates.asking, (#[] : Array JobStart), (#[] : Array String), (#[] : Array String)))
        fun (asking, starts, cancels, wanted) index =>
        match asking[index]? with
        | none => (asking, starts, cancels, wanted)
        | some source =>
            let key := sourceKey view source.source
            let start (generation : Nat) (text : String) (pause : Nat) : JobStart :=
            { name := source.later.job
              arguments :=
                Completion.Order.arguments
                  { view, index, generation, pause
                    query :=
                      { text, view := completing.asker, region := candidates.region
                        texts := candidates.texts, place := candidates.place
                        context := candidates.context } }
              key := some key }
            if !keys.registered.jobs source.later.job then (asking, starts, cancels, wanted)
          else
            if source.generation == 0 then
              (asking.set! index { source with generation := 1 },
                starts.push (start 1 source.askedFor 0), cancels, wanted.push key)
            else
              match loop.typed with
              | some typed =>
                if source.later.reask.asksAgain source.askedFor typed then
                  let generation := source.generation + 1
                  (asking.set! index
                      { source with
                        askedFor := typed, generation, fresh := false, done := false },
                    starts.push (start generation typed source.later.reask.pause), cancels.push key,
                    wanted.push key)
                else (asking, starts, cancels, wanted.push key)
              | none => (asking, starts, cancels, wanted.push key)
    let candidates := { candidates with asking }
    -- The match: one stamped with an older config generation is no longer in
    -- flight, since an install ended it.
    let generation := keys.registered.generation
    let stale := candidates.matching.any (·.generation != generation)
    let candidates := if stale then { candidates with matching := none } else candidates
    let cancels := if stale then cancels.push (matchKey view) else cancels
    let (candidates, spawns) : Candidates × Array Spawn :=
      match loop.typed with
      | some typed =>
        if
            (candidates.current typed).listingSize > keys.inlineMatches &&
              (candidates.listedFor != some typed || candidates.listedAt != candidates.revision) &&
              candidates.matching.isNone &&
              candidates.unmatched != some (typed, candidates.revision) then
          let revision := candidates.revision
          let style := keys.matching.styleFor candidates.category
          ({ candidates with matching := some { pattern := typed, revision, generation } },
            #[{ key := matchKey view, label := matchLabel
                owner := keys.matching.ownerFor candidates.category
                work := matchWork view candidates typed revision style }])
        else (candidates, #[])
      | none => (candidates, #[])
    let wanted := if candidates.matching.isSome then wanted.push (matchKey view) else wanted
    let unwanted := state.completionKeys.filter (!wanted.contains ·)
    ({ loop with
        state := { state.replaceCandidatesIn view candidates with completionKeys := wanted } },
      starts, cancels ++ unwanted.filter (!cancels.contains ·), spawns)

/-- What a step's key asks of completion at point ("Completion at point",
in the module docs), from `loop`, once its scene is published, pure: the
invocations to run next and what to do with the pause. A key that typed
`text` in the focused view, with no prompt and no session open, looks at the
chain of its buffer's at-point sources: when the text's last character is a
trigger of one of them, `at-point-triggered` with it is run next; when any
declares a pause, a pause of each length is armed, replacing whatever was.
A key that typed nothing, and any key while a prompt or a session is open,
withdraws what is armed. A step that took no key leaves it. -/
def atPointAsks (loop : Loop scheme) (keys : Keys scheme) (key : Option (ViewId × Option String)) :
    Array Invocation × PauseChange :=
  let withdraw := if loop.pausing.isSome then PauseChange.disarm else .keep
  match key with
  | none => (#[], .keep)
  | some (view, typed) =>
    let state := loop.state
    if state.prompt.isSome || state.atPoint.isSome || state.frame.focused != view then
      (#[], withdraw)
    else
      match typed, state.target? view with
      | some text, some target =>
        let sources :=
          (keys.registered.atPointNames target.buffer.major target.buffer.minors).filterMap
            keys.registered.atPoint
        let trigger :=
          text.toList.getLast?.filter fun char => sources.any (·.triggers.contains char)
        let invocations : Array Invocation :=
          trigger.toArray.map fun char =>
            { command := AtPoint.triggeredName, arguments := [.str char.toString] }
        let pauses := (sources.filterMap (·.pause)).toList.eraseDups.toArray
        (invocations, if pauses.isEmpty then .keep else .arm view pauses)
      | _, _ => (#[], withdraw)

/-- `loop` with the menu bar `keys` names (`Keys.menu`) as the one its
scenes name: how a step, an invocation and a delivery start, so that a
reload's bindings move the menu's shortcuts from the next one. -/
def keyedBy (keys : Keys scheme) (loop : Loop scheme) : Loop scheme :=
  { loop with menu := keys.menu }

/-- The loop once a scene of it is published with the key hints opened,
closed and listed for the keys that can follow now (`keyHinted`), and
shown (`shownHints`): the publish of a step (`Stepped.published`) and the
one a host makes with no step, after an install or a theme switch. Its
views' status lines are drawn by the mode line `keys` names and padded by
its padding, its windows laid out by its layout and a prompt's candidates
listed by its matching and drawn by its displays (`publish`). What the host
is to do with the hints' delay comes with it, so an install that sets
`.never`, or binds keys under a pending prefix anew, closes or opens the
hints with no key typed. -/
def publishHinted (keys : Keys scheme) (loop : Loop scheme) :
    EditorM (Loop scheme × HintDelayChange) := do
  let (hinted, change) ← loop.keyHinted keys
  let published ←
    hinted.publish keys.modeLine keys.padding keys.layout keys.tabBar keys.matching
        keys.inlineMatches keys.displaying keys.now (keyHints := hinted.shownHints keys)
  return (published, change)

/-- `stepped`, a step whose scene is not yet published, once it is
(`publish`), its views' status lines drawn by the mode line `keys` names
and padded by its padding, its windows laid out by its layout and a
prompt's candidates listed by its matching (`Keys.modeLine`,
`Keys.padding`, `Keys.layout`, `Keys.matching`), a long one by a match
job (`Keys.inlineMatches`): its loop is
the one the publish left, with the file jobs it starts and cancels
(`fileJobs`) after the step's own, then the open prompt's jobs it starts,
cancels and spawns (`completionJobs`), then the version-control gutter's
(`VersionControl.reconcile`), handed the git program of the workspace
settings `keys` was told of (`Registered.workspaceSettings`, what the
version-control commands ask for), and it says stop when the editor then
leaves (`nextOf`) and to go on otherwise. The key hints are opened, closed
and listed with the publish (`publishHinted`), and the step hands what the
host is to do with their delay (`Stepped.hintDelay`). The scene comes
first, so the scene of the step that says stop is the last one. -/
def Stepped.published (keys : Keys scheme) (stepped : Stepped scheme) : EditorM (Stepped scheme) :=
  do
  let (loop, hintDelay) ← stepped.loop.publishHinted keys
  let (loop, starts, cancels) := loop.fileJobs keys
  let (loop, sourceStarts, sourceCancels, spawns) := loop.completionJobs keys
  let (state, gutterStarts, gutterCancels) ←
    VersionControl.reconcile keys.registered.jobs keys.registered.workspaceSettings.git loop.state
  let loop := { loop with state }
  -- What the key asks of completion at point, from the state the scene
  -- shows: a trigger's command to run next, and the pause.
  let (asked, pause) := loop.atPointAsks keys stepped.key
  let pausing :=
    match pause with
    | .keep => loop.pausing
    | .arm view pauses => some { view, pauses }
    | .disarm => none
  let loop := { loop with pausing }
  return { stepped with
      loop, next := nextOf loop
      starts := stepped.starts ++ starts ++ sourceStarts ++ gutterStarts
      cancels := stepped.cancels ++ cancels ++ sourceCancels ++ gutterCancels
      spawns := stepped.spawns ++ spawns, answered := stepped.answered ++ asked, pause, hintDelay }

/-- The step the key hint delay of `generation` firing is: the loop with its
key hints due when they are of that generation (`EditorState.keyHintsDue`),
and a scene published, which lists and shows them. It runs no command:
the echo area, the scheme's state and everything else are as they were. A
delay for hints since closed, or for others, changes nothing, and its scene
is the same as the last. -/
def keyHintsDue (keys : Keys scheme) (loop : Loop scheme) (generation : Nat) :
    EditorM (Stepped scheme) :=
  let loop := loop.keyedBy keys
  ({      loop := { loop with state := loop.state.keyHintsDue generation }
          next := .continue } : Stepped scheme).published keys

/-- Hands the answer `invocation` carries, its first argument, to the input
scheme, for the focused view (`InputScheme.answered`), and runs the
invocation the answer completes as `key` runs a key's: told of the scheme's
report of the focused view after the answer, and keeping the scheme's state
as its state at rest when the command ran to its end, or going back to the
state at rest when it did not ("Prompts", in the module docs). An answer
that completes nothing keeps the scheme's state after it. Then a scene is
published. No command of the reserved name is looked up. -/
def answer (keys : Keys scheme) (loop : Loop scheme) (invocation : Invocation) :
    EditorM (Stepped scheme) := do
  let text :=
    match invocation.arguments with
    | .str text :: _ => text
    | _ => ""
  let focused := loop.state.frame.focused
  let (input, yielded) := scheme.answered focused text loop.input
  let some completed := yielded |
    return ← ({ loop := { loop with input, atRest := input }, next := .continue } : Stepped scheme).published keys
  let ran ←
    run keys loop.state completed [] (scheme.report input focused)
      (keyBindingsIn keys loop.state input)
  let stepped :=
    if ran.finished then
      ({ loop with input, atRest := input } : Loop scheme).ranInto ran
    else ({ loop with input := loop.atRest } : Loop scheme).ranInto ran
  stepped.published keys

/-- What the echo area says when the keys of the key string `text`, pressed
from rest by the reserved keys invocation (`pressed`), complete nothing. -/
def notBound (text : String) : String :=
  s!"{text}: not bound"

/-- Runs the reserved invocation that presses keys
(`InputScheme.keysName`), whose first argument is a key string, and
publishes a scene of the state after it ("Prompts", in the module docs).
The keys are fed to the scheme for the focused view from its state at rest
(`InputScheme.feed`), so nothing pending extends them. When every key but
the last yields nothing and the last yields an invocation, that invocation
runs as `key` runs a key's: told of the keys, of the scheme's report of the
focused view after them, and keeping the scheme's state after them as its
state at rest when the command ran to its end, or going back to the state
at rest when it did not. Otherwise the echo area says so (`notBound`) and
nothing runs. No command of the reserved name is looked up. -/
def pressed (keys : Keys scheme) (loop : Loop scheme) (invocation : Invocation) :
    EditorM (Stepped scheme) := do
  let text :=
    match invocation.arguments with
    | .str text :: _ => text
    | _ => ""
  let chords := ((Key.parse text).toOption.getD []).map Key.chord
  let focused := loop.state.frame.focused
  let (input, yields) := scheme.feed (keys.maps loop.state) focused loop.atRest chords
  let completed := if yields.dropLast.all (·.isNone) then yields.getLast?.join else none
  let some completed := completed |
    let said : Loop scheme := { loop with state := { loop.state with echo := notBound text } }
    return ← ({ loop := said, next := .continue } : Stepped scheme).published keys
  let ran ←
    run keys loop.state completed chords (scheme.report input focused)
        (keyBindingsIn keys loop.state input)
  let stepped :=
    if ran.finished then
      ({ loop with
              input, atRest := input } :
            Loop scheme).ranInto
        ran
    else ({ loop with input := loop.atRest } : Loop scheme).ranInto ran
  stepped.published keys

/-- Runs `invocation`, which no key yielded (`run`), and publishes a scene of
the state after it: the echo area is cleared, the command is looked up, and
it is called with the focused window, the invocation's arguments, no keys,
and what the scheme reports of the focused view in the state it is in. The
scheme's states are left as they are, but for a view the command closed.
The two reserved names are no command's: an answer is handed to the scheme
(`answer`), and keys are pressed (`pressed`). -/
def invoke (keys : Keys scheme) (loop : Loop scheme) (invocation : Invocation) :
    EditorM (Stepped scheme) := do
  let loop := loop.keyedBy keys
  if invocation.command == InputScheme.answerName then
    return ← loop.answer keys invocation
  if invocation.command == InputScheme.keysName then
    return ← loop.pressed keys invocation
  let report := scheme.report loop.input loop.state.frame.focused
  (loop.ranInto
          (←
            run keys loop.state invocation [] report
                (keyBindingsIn keys loop.state loop.input))).published
      keys

/-- Runs the command registered under `name` as an invocation with no
arguments that no key yielded (`invoke`), and publishes a scene of the
state after it: what a host's driver asks for. -/
def runNamed (keys : Keys scheme) (loop : Loop scheme) (name : String) : EditorM (Stepped scheme) :=
  loop.invoke keys { command := name }

/-- Runs `command`, which the loop is handed with `label` as its name, and
publishes a scene of the state after it: how a finished job's command is
run. It is run as every command is (`dispatch`), and it is no invocation:
the echo area is not cleared, so a command that says nothing leaves what
the user was reading. When it does not run to its end the echo area reads
`<label>: refused: ` and the refusal, `<label>: interrupted`, or `<label>: `
and the reason it gave up with. -/
def deliver (keys : Keys scheme) (loop : Loop scheme) (label : String) (command : EditorM Unit) :
    EditorM (Stepped scheme) := do
  let loop := loop.keyedBy keys
  let ran ←
    dispatch keys loop.state label do
        command
        return none
  (loop.ranInto ran).published keys

/-- Handles `event` and publishes a scene of the state after it, and says
whether to go on: stop, once the editor leaves ("Quit", in the module
docs). A queue's quit stops the loop and publishes nothing; a window's
close request is a quit by `q`'s rule (`Ex.closeRequested`), run as a
delivered command is (`deliver`). A key press is stepped through the scheme, and the invocation it
yields is run (`stepped?`, `key`). A handler that is refused leaves the
state as it was, with the refusal in the echo area. The step itself is not
refused: the publish puts a refusal of its own in the echo area too ("When
publishing is refused", in the module docs). -/
def step (keys : Keys scheme) (loop : Loop scheme) (event : Event) : EditorM (Stepped scheme) := do
  let loop := loop.keyedBy keys
  if let some pressed := stepped? event then
    return ← (← loop.key keys pressed).published keys
  match event with
  | .quit =>
    return { loop, next := .stop }
  | .closeRequested =>
    -- A quit by `q`'s rule, run as a delivered command is: guarded, rolled
    -- back and published, with the echo left, and stop once the editor
    -- leaves.
    loop.deliver keys Ex.quitName Ex.closeRequested
  | .openFiles (path :: rest) =>
    -- An invocation no key yielded, run as every command is, in the
    -- focused window: config's command of the name runs in its place.
    loop.invoke keys { command := Files.openName, arguments := (path :: rest).map .str }
  | .quitRequested =>
    -- The system's quit is remembered first, so that a `quit` that is
    -- refused or interrupted rolls back to a state that still holds it,
    -- and the publish answers it.
    ({ loop with state := { loop.state with systemQuit := true } }).invoke keys
        { command := Ex.quitName }
  | .menu name =>
    -- An invocation no key yielded, as a file to open is: config's
    -- command of the name runs in its place. The scheme says what it runs
    -- as in the focused view's state, and the state it leaves.
    let focused := loop.state.frame.focused
    let (input, invocation) := scheme.invoked focused loop.input { command := name }
    let ran ←
      run keys loop.state invocation [] (scheme.report input focused)
          (keyBindingsIn keys loop.state input)
    if ran.finished then
      let atRest := if (scheme.pending input).isEmpty then input else loop.atRest
      (({ loop with
                    input, atRest } :
                  Loop scheme).ranInto
              ran).published
          keys
    else
      (({ loop with input := loop.atRest } : Loop scheme).ranInto ran).published keys
  | _ =>
    let focused := loop.state.frame.focused
    let report := scheme.report loop.input focused
    let (state, typed) ←
      try
        handle loop.state report event
      catch refusal =>
        pure (loop.state.refused refusal, none)
    -- A committed text that was inserted is typed text the scheme saw no
    -- key of: both states the loop keeps of it are told.
    let told (input : scheme.State) : scheme.State :=
      match typed with
      | some text => scheme.committed focused text input
      | none => input
    ({        loop :=
                { loop with
                  state, input := told loop.input, atRest := told loop.atRest }
              next := .continue, key := typed.map fun text => (focused, some text) } :
            Stepped scheme).published keys

/-- Lowers the interrupt flag for an event taken off the queue when the
library marked it as a press of the interrupt key (`interrupt`), and for no
other: one fewer interrupt key is on the queue. `take` makes it for each
event it steps, and a host for a window event no loop takes, one it cannot
read or one that arrives when it has no loop: that event has been taken off
the queue all the same. -/
def lowerFor (interrupt : Bool) : WatchM Unit := do
  if interrupt then
    Watch.lower

/-- Takes what arrived off the queue: lowers the interrupt flag when the
library marked the event as a press of the interrupt key
(`Received.interrupt`, `lowerFor`), and then steps the event like any other
(`step`), so a scheme can bind the interrupt key. This is what a host calls
for each event it pulls.

The flag is lowered first: the key has been taken off the queue, so what
its own binding runs is not interrupted by it. -/
def take (keys : Keys scheme) (loop : Loop scheme) (received : Received) :
    EditorM (Stepped scheme) := do
  lowerFor received.interrupt
  loop.step keys received.event

end Loop

end Editor
