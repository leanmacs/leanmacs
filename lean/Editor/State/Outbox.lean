import Editor.Invocation
import Editor.Store.Codec

/-!
# The outbox

What the commands of a step asked the loop to hand its host once a command
has run to its end (`EditorState.Outbox`, the state's `outbox`): the jobs
to start and the keys of the jobs to cancel (`Editor/Loop.lean`, "Jobs
from commands"), the invocations to run next, a prompt's continuation with
its answer among them ("Prompts"), whether the config is to be reloaded
("Reload from a command"), the theme to load ("A theme switch from a
command") and the declared stores' cells a session restore read, for the
host that holds the cells ("Restoring", `Editor/Restore/Run.lean`).

## The rules

- **Each entry is set by one state request** (`Editor/State/Request.lean`):
  `starts` by `startJob`, `cancels` by `cancelJob`, `answered` by `invoke`
  and by `closePrompt` (`EditorState.closePrompt`), `reload` by `reload`,
  `theme` by `loadTheme` and `restoredCells` by `restoreCells`. Each of the first three appends in order;
  `reload` and `theme` are set in place of what was there, so the latest
  wins.
- The jobs a command asked to be started are kept in order, a `JobStart`
  each: a registered job's name and plain arguments, and the key a host
  keeps it under, if it has one.
- The invocations to run next are kept the same way: the continuation of a
  prompt that was accepted, with its answer as its first argument
  (`Editor/State.lean`, "Prompts"), and an invocation a command asked to be
  run after it. The field `answered` is named for the first, which came
  first.
- **It is a field of the state, so a command that does not run to its end
  hands nothing on.** A command that is refused, interrupted, gives up or
  is superseded is rolled back to the state from before it, whose outbox
  is empty.
- **The loop empties it whole** after a command that ran to its end or
  broke off, and hands it back with the step (`Loop.dispatch`,
  `Loop.ranInto`, `Loop.Stepped`). A new entry is emptied with the rest,
  with no line of its own in the loop.
- **What is not in it.** That a command asked the editor to quit
  (`EditorState.quitting`, `Editor/State.lean`, "Quit") is a standing
  request, not a one-shot output: it outlives the command that set it, so
  that a quit can wait for a save in flight, and only `settleQuit` and
  `endSave` withdraw it. Emptying it with the outbox would drop a quit
  that waits for a save. What a command typed in place of typed text
  (`EditorState.retyped`, "A session at point") goes to the input scheme,
  not the host, and a command that broke off hands on its outbox but not
  what it retyped.

## Where a new entry goes

1. A field of `EditorState.Outbox`, empty by default.
2. A constructor of `StateRequest` whose `handle` case sets it, and the
   function a command calls in `Editor/Api.lean` (`Editor/State/Request.lean`,
   "Where an addition goes").
3. A field of `Loop.Stepped` that `Loop.ranInto` fills from `ran.outbox`,
   and the hosts that take it in (`Loop.Driver`, `Editor/Headless.lean`).

Pinned by `ModelTest.stateRequestChecks` (each request's case), and by
`ModelTest.dispatchQuitChecks` and `ModelTest.driverChecks` (handed back
and emptied).
-/

namespace Editor

/-- A job a command asked to be started: the name it is registered under,
and the arguments to start it with. It is plain data: the job itself is
the registry's. -/
structure JobStart where
  /-- The name the job is registered under. -/
  name : String
  /-- What the job is started with, in order. -/
  arguments : List Argument := []
  /-- The key a host keeps the job under, if it has one: starting a job of a
  key cancels the running job of that key, and a cancel of the key ends it
  (`Loop.Stepped.cancels`). -/
  key : Option String := none
  deriving DecidableEq, Repr

/-- What commands asked the loop to hand its host, which it has not yet
handed: emptied whole after each command that ran to its end or broke off
("The outbox", in the module docs). -/
structure EditorState.Outbox where
  /-- The jobs commands asked to be started, in order. -/
  starts : Array JobStart := #[]
  /-- The keys of the jobs commands asked to be cancelled, in order. -/
  cancels : Array String := #[]
  /-- The invocations to run next, in order: the continuations of the
  prompts commands accepted, each with its answer as its first argument,
  and the invocations commands asked to be run after them
  (`StateRequest.invoke`, `Editor/State/Request.lean`). -/
  answered : Array Invocation := #[]
  /-- Whether a command asked for the config to be reloaded. -/
  reload : Bool := false
  /-- The theme a command asked to be loaded, the latest if it asked more
  than once. -/
  theme : Option String := none
  /-- The declared stores' cells a session restore read, a package's met
  with its codec and config's as they were, for the host that holds the
  cells (`Config.State.restoreCells`), in order. -/
  restoredCells : Array KeptCell := #[]
  deriving BEq, Repr

end Editor
