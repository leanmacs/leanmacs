import Editor.Command.Call
import Editor.Ex.Line
import Editor.Invocation
import Editor.State

/-!
# The state requests

What a command asks of the editor state (`Editor/State.lean`): its buffers
and the files they hold, its windows, the echo area, the jobs to start and
the prompt.
A `StateRequest` is a request of the editor's port (`EditorRequest.state`,
`Editor/Command.lean`), and `EditorState.handle` is its handler: one pure
function from a request and a state to the reply and the state after it. It
reaches nothing outside the state, so it has no model and no binding: the
loop that runs a command answers the command's state requests with it, on
the models and against the library alike (`Editor/Command/Dispatch.lean`).

## The rules

- **A question is one read.** `read` hands back the whole state, and a
  question is a pure function over it (`EditorState.buffer?`, `target?`,
  `findBuffer`, `value?`, `frame.focused`). There is no request a question.
- **A write is a request of its own.** Each is one operation of
  `Editor/State.lean`, which keeps the layout invariants: a command cannot
  put a state of its own making in place of the editor's.
- **A refusal is a value.** A reply that can be refused is an `Except` of
  the operation's refusal (`LayoutRefusal`, `BufferRefusal`, `ModeRefusal`,
  `JobRefusal`, `PromptRefusal`, `ThemeRefusal`, `WorkspaceRefusal`), with the state as it was. Nothing is thrown, so a command
  matches on it, and a command's error stays a `TextError`.
- **A request holds plain data.** It cannot hold a command or a job, which
  are programs over ports that would then refer to themselves: a mode is
  named, and so is a job, and what the name stands for is the registry's.
  So eight requests are answered with more than this handler by the loop,
  which knows the registry: `setMajorMode`, which there refuses a name no
  mode is registered under and runs the mode's on-enter actions,
  `startJob`, which there refuses a name no job is registered under,
  `ex`, which there is answered the binding the registry has for an ex
  name (`Editor/Ex/Line.lean`), `exNames`, which there is answered the ex
  names that are bound, `themeNames`, which there is answered the names
  themes are registered under, `loadTheme`, which there refuses a name no
  theme is registered under, `runCommand`, which there runs the
  command registered under a name inside the asking command, and
  `displayRules`, which there is answered config's display rules
  (`Editor/DisplayRules.lean`). Here
  `setMajorMode`, `startJob` and `loadTheme` take any name, `ex` is
  answered `none`, `exNames` and `themeNames` are answered no name,
  `runCommand` is answered `false` and runs nothing, and `displayRules` is
  answered no rule: this handler knows no registry.
- **A reply holds plain data too**, so no request is answered a command:
  a command is a program over the port these requests are part of, and a
  reply that held one would be a type that refers to itself. A command
  that needs what the registry holds for a command's name has the loop
  run it (`runCommand`), with the call it hands it, which is plain data
  (`Editor/Command/Call.lean`).
- **A marker is made by the caller.** `split`, `show` and `openWindow` are
  handed the markers of the window they make or change, which the command
  marked on the buffer's text first: the handler asks the text store
  nothing.
- **A new window on a buffer is opened by one request**, `openWindow`,
  with its spot (`WindowSpot`): after the last window of the tiled list,
  or docked at an edge. It is refused with a `LayoutRefusal`, the state as
  it was, `noSuchEdge` among them for an edge the layout has none at.
  Where a buffer goes is the asking command's to decide, with the display
  rules (`displayRules`, `EditorState.displaying`).
- **A window's place and its layout's parameters are changed by one
  request**, `arrange`, with the change as data (`Arrange`: promote,
  demote, rotate, exchange, zoom, balance, resize, main's count and the
  move between an edge and the tiles), so a
  new change is a variant there and no request of its own. It is refused
  with a `LayoutRefusal`, the state as it was. `split` takes a placement
  (`Placement`), which only manual splits read.
- **A prompt's minibuffer is made by the caller too.** `openPrompt` is
  handed the minibuffer's text, a history over it and the two markers of
  its window, and names the command that receives the answer as an
  invocation (`Editor/State.lean`, "Prompts"). It is refused with a
  `PromptRefusal`.
- **A prompt is closed by one request**, `closePrompt`, with the answer or
  with none. Closing the minibuffer's window and recording the answer are
  that one request, which asks the text store nothing, so the command that
  makes it cannot be interrupted between the two. The handler releases
  nothing: the loop gives up the minibuffer's markers and text once the
  command has run to its end.
- **An open prompt's candidates are set by one request, and its choice is
  moved by another**: `setCandidates`, with the strings, and
  `chooseCandidate`, with a step (`Editor/State.lean`, "Prompts"). Each is
  refused with a `PromptRefusal`, `notOpen`, when no prompt is open. The
  listing has no request: the loop makes it, between a command and the
  scene, from what the matcher answers (`Editor/Loop.lean`), so no command
  can list what the matcher did not answer.
- **An invocation to run next is recorded by one request**, `invoke`: it
  is put after the invocations already recorded
  (`EditorState.answered`), a prompt's answer among them, and the loop
  hands them to its host once the command has run to its end
  (`Editor/Loop.lean`, "Prompts"). This is how a command has another run
  after it, as a step of its own.
- **A command is run inside the asking command by one request**,
  `runCommand`, with the name it is registered under and the call it is
  to be run with. It is the loop's to act on: the transformation that
  runs a command puts the named command's program before the rest of the
  asking command's (`Editor/Command/Dispatch.lean`, "Requests that name
  something registered"). The reply says whether a command was registered
  under the name.
- **The editor is asked to quit by one request**, `quit`, which sets the
  state's flag and nothing else (`Editor/State.lean`, "Quit"). The handler
  does not judge whether the editor may quit: the command that asks
  checks first (`quit`, `Editor/Api.lean`), since that needs the text
  store, and the loop decides when the editor leaves.
- **A reload of the config is asked for by one request**, `reload`,
  which sets a flag of the state (`EditorState.reload`) until the loop
  hands it to its host, as `starts` holds the jobs a command asked for
  (`Editor/Loop.lean`, "Reload from a command").
- **A theme is loaded by one request**, `loadTheme`, which keeps the name
  in the state (`EditorState.theme`), the latest one wins, until the loop
  hands it to its host, as `reload` is kept (`Editor/Loop.lean`, "A theme
  switch from a command").
- **A window's wanted column is set by one request**, `setWanted`, with
  the column, a goal of the display's or the line's end, and the offset it
  is kept at, or with none (`Editor/State.lean`, "The wanted column"). The
  handler stores the column as it is given. It is refused with a
  `LayoutRefusal`, `noSuchWindow`, for a view with no window.
- **A file is attached by one request, and a save is two.** `attachFile`
  has a buffer hold a file a load answered. `beginSave` records a save in
  flight, with the snapshot it writes, which the command took first, and
  `endSave` ends it with what the save answered: the stamp and the saved
  mark are set by that one request (`Editor/State.lean`, "A buffer's
  file"). The handler releases no snapshot: the loop does, once the
  command that ended the save has run to its end. What a check of the
  file found is recorded by one request, `markChanged`, and that the user
  was told of it by another, `tellChanged`, so the command a check finishes
  with is made of state requests alone and cannot be interrupted.
- **A command gives up by one request**, `giveUp`, with its reason
  (`giveUp`, `Editor/Api.lean`). It is the loop's to act on: the
  transformation that runs a command ends the command's program at this
  request, with the reason (`Editor/Command/Dispatch.lean`, "A command
  that gives up"). This handler knows no command to end, so here the
  request changes nothing and is answered like a write that has no reply.
- **A command breaks off by one request**, `breakOff`, with its reason
  (`breakOff`, `Editor/Api.lean`). It is the loop's to act on as `giveUp`
  is, and differs in what the loop then does: what the command did stays
  (`Editor/Command/Dispatch.lean`, "A command that breaks off"). Here it
  changes nothing either.
- **A register is set by one request**, `setRegister`, with its name
  (`Editor/State.lean`, "Registers"). It is never refused: a name is any
  string, and which names mean something is the asking command's rule. A
  command reads a register with a read of the state
  (`EditorState.register?`).
- **The last search is set by one request**, `setLastSearch`
  (`Editor/State.lean`, "The last search"), as the last find is.
- **The last character find is set by one request**, `setLastFind`
  (`Editor/State.lean`, "The last find"). It is never refused. A command
  reads it with a read of the state (`EditorState.lastFind`).
- **The scroll margin is set by one request**, `setScrollMargin`, with a
  number of rows (`Editor/State.lean`, "The scroll margin"). It is never
  refused: any number is taken. A command reads the margin with a read of
  the state (`EditorState.scrollMargin`).
- **Workspaces are changed by four requests** (`Editor/State.lean`,
  "Workspaces"): `recordWorkspace` takes in what the finder answered for a
  directory, and is never refused; `registerWorkspace` makes a workspace
  that is not on this machine, and refuses `local`; `setWorkspaceValue` and
  `setProjectValue` set a value in a store, and refuse `noSuchWorkspace`
  and `noSuchProject` (`WorkspaceRefusal`). A command reads them with a
  read of the state (`EditorState.workspaceOf?`, `workspaces`).
- **What the finder is handed is asked by one request**,
  `workspaceSettings`: config's workspace roots and the config generation,
  which the loop answers from what it was told of the registry
  (`Editor/Command/Dispatch.lean`). Here, with no registry, it is answered
  no root and generation 0.

## Where an addition goes

| Addition | Where |
|---|---|
| A question about the state | A pure function over `EditorState` (`Editor/State.lean`); nothing here |
| A new way to change the state | An operation in `Editor/State.lean`, a constructor here with its case in `Reply` and in `handle`, and the operation a command calls in `Editor/Api.lean` |
| A request that needs the registry | The same, and its case in `EditorM.dispatched` (`Editor/Command/Dispatch.lean`) |

Pinned by `ModelTest.stateRequestChecks`.
-/

namespace Editor

/-- What a command may ask of the editor state. -/
inductive StateRequest where
  /-- The whole state, as it is. -/
  | read
  /-- Add a buffer called `name` over `text`, whose history is `history`. -/
  | addBuffer (name : String) (text : TextId) (history : UndoTree)
  /-- Remove the buffer `id`. -/
  | removeBuffer (id : BufferId)
  /-- Give the buffer `id` the name `name`. -/
  | renameBuffer (id : BufferId) (name : String)
  /-- Make `history` the undo tree of the buffer `id`. -/
  | setHistory (id : BufferId) (history : UndoTree)
  /-- Have the buffer `id` keep `value` under `name`. -/
  | setValue (id : BufferId) (name : String) (value : Value)
  /-- Make the mode called `name` the major mode of the buffer `view`
  shows. -/
  | setMajorMode (view : ViewId) (name : String)
  /-- Add the minor mode called `name` to the buffer `id`. -/
  | addMinorMode (id : BufferId) (name : String)
  /-- Remove the minor mode called `name` from the buffer `id`. -/
  | removeMinorMode (id : BufferId) (name : String)
  /-- Split the window `view`: a new window on its buffer, with `scroll` and
  `selection` as its markers, put in the frame's list as `placement` says
  under manual splits and right after it under the other layouts. -/
  | split (view : ViewId) (scroll selection : MarkerId) (placement : Placement := {})
  /-- Make `change` on the window `view` (`Arrange`): a reorder of the list or
  a change of the layout's parameters. -/
  | arrange (view : ViewId) (change : Arrange)
  /-- Open a new window on the buffer `buffer`, with `scroll` and `selection`
  as its markers, at `spot`: after the last of the tiled list, or docked at
  an edge. -/
  | openWindow (buffer : BufferId) (scroll selection : MarkerId) (spot : WindowSpot)
  /-- Remove the window `view`. -/
  | removeWindow (view : ViewId)
  /-- Focus the window `view`. -/
  | focus (view : ViewId)
  /-- Have the window `view` show the buffer `buffer`, with `scroll` and
  `selection` as its markers. -/
  | «show» (view : ViewId) (buffer : BufferId) (scroll selection : MarkerId)
  /-- Put `text` in the echo area. -/
  | message (text : String)
  /-- Start the job registered under `name`, with `arguments`. -/
  | startJob (name : String) (arguments : List Argument)
  /-- Have the buffer `id` hold the file at `path`, whose stamp is `stamp`,
  with `ending` as the buffer's line ending. -/
  |
  attachFile (id : BufferId) (path : System.FilePath) (stamp : File.Stamp)
    (ending : File.LineEnding)
  /-- Record a save of the buffer `id` as in flight: it writes `snapshot`,
  taken with the buffer's text in the state `saved`. -/
  | beginSave (id : BufferId) (snapshot : SnapshotId) (saved : UndoTree.State)
  /-- End the save of the buffer `id` that writes `snapshot`: with the stamp
  of the file it wrote, or with `none` for a save that was refused. -/
  | endSave (id : BufferId) (snapshot : SnapshotId) (stamp : Option File.Stamp)
  /-- Record what a check of the buffer `id`'s file found, if its stamp is
  still `stamp`: the file's stamp now, or `none` for one that is gone, and
  whether the user was told (`EditorState.markChanged`). -/
  | markChanged (id : BufferId) (stamp : File.Stamp) (found : Option File.Stamp) (told : Bool)
  /-- Mark the change on disk of the buffer `id`'s file as told. -/
  | tellChanged (id : BufferId)
  /-- Choose auto-reload on or off, for as long as the editor runs. -/
  | setAutoReload (on : Bool)
  /-- Whether auto-reload is in effect: a command's choice, or else config's
  setting, which the loop that runs the command answers with. -/
  | autoReloadMode
  /-- Stop following the buffer `id` for auto-reload: its follow job ended. -/
  | unfollow (id : BufferId)
  /-- Mark the following of the buffer `id` as refused: its watch could not
  be made. -/
  | refuseFollow (id : BufferId)
  /-- Open a prompt labelled `label`, whose answer the command of
  `continuation` receives: the minibuffer is a buffer over `text`, whose
  history is `history`, in a window with `scroll` and `selection` as its
  markers. -/
  |
  openPrompt (label : String) (continuation : Invocation) (text : TextId) (history : UndoTree)
    (scroll selection : MarkerId)
  /-- Close the open prompt: with `answer`, which its continuation's command
  receives, or with `none` for a prompt that is cancelled. -/
  | closePrompt (answer : Option String)
  /-- Replace the open prompt's candidates with `all`. -/
  | setCandidates (all : Array String)
  /-- Move the open prompt's choice by `step` through its listing. -/
  | chooseCandidate (step : Candidates.Step)
  /-- Have the window `view` keep `wanted` as its wanted column, or none. -/
  | setWanted (view : ViewId) (wanted : Option Window.Wanted)
  /-- Which command the ex name `name` is bound to, and what it takes. -/
  | ex (name : String)
  /-- Which ex names are bound. -/
  | exNames
  /-- Which names themes are registered under. -/
  | themeNames
  /-- Have the theme called `name` loaded once this command has run to its
  end. -/
  | loadTheme (name : String)
  /-- Have `invocation` run after this command, as a step of its own. -/
  | invoke (invocation : Invocation)
  /-- Run the command registered under `name` inside this command, with
  `call`. -/
  | runCommand (name : String) (call : Call)
  /-- Ask the editor to quit. -/
  | quit
  /-- Ask for the config to be reloaded. -/
  | reload
  /-- End this command here, with `reason`: it gives up. -/
  | giveUp (reason : String)
  /-- End this command here, with `reason`, and keep what it did: it breaks
  off. -/
  | breakOff (reason : String)
  /-- Keep `register` under `name`, in place of the register the name
  had. -/
  | setRegister (name : String) (register : Register)
  /-- Keep `find` as the last character find. -/
  | setLastFind (find : Find)
  /-- Keep `search` as the last search. -/
  | setLastSearch (search : Search)
  /-- Keep `rows` rows between every view's cursor's row and the first and
  the last row it shows. -/
  | setScrollMargin (rows : Nat)
  /-- Take in what the finder answered for `directory` under the config
  generation `generation`: the workspace, added or with its branch updated,
  and the directory's cached answer. -/
  |
  recordWorkspace (directory : System.FilePath) (generation : Nat) (found : Option Workspace.Found)
  /-- Register a workspace at `location`, not on this machine, of the
  project of `remote`, with `branch` checked out if it is given. -/
  | registerWorkspace (location : Location) (remote : String) (branch : Option String)
  /-- Have the workspace at `location` keep `value` under `name`. -/
  | setWorkspaceValue (location : Location) (name : String) (value : Value)
  /-- Have the project of `identity` keep `value` under `name`. -/
  | setProjectValue (identity : Project.Identity) (name : String) (value : Value)
  /-- What the finder is to be handed, config's roots among it, and the
  config generation, which the loop that runs the command answers with. -/
  | workspaceSettings
  /-- Config's display rules, in order, which the loop that runs the
  command answers with. -/
  | displayRules

/-- The type of the reply to each request. -/
abbrev StateRequest.Reply : StateRequest → Type
  | .read => EditorState
  | .addBuffer .. => Except BufferRefusal BufferId
  | .removeBuffer _ => Except BufferRefusal Unit
  | .renameBuffer .. => Except BufferRefusal Unit
  | .setHistory .. => Except BufferRefusal Unit
  | .setValue .. => Except BufferRefusal Unit
  | .setMajorMode .. => Except ModeRefusal Bool
  | .addMinorMode .. => Except BufferRefusal Unit
  | .removeMinorMode .. => Except BufferRefusal Unit
  | .split .. => Except LayoutRefusal ViewId
  | .arrange .. => Except LayoutRefusal Unit
  | .openWindow .. => Except LayoutRefusal ViewId
  | .removeWindow _ => Except LayoutRefusal Window
  | .focus _ => Except LayoutRefusal Unit
  | .show .. => Except LayoutRefusal Unit
  | .message _ => Unit
  | .startJob .. => Except JobRefusal Unit
  | .attachFile .. => Except BufferRefusal Unit
  | .beginSave .. => Except BufferRefusal Unit
  | .endSave .. => Except BufferRefusal Unit
  | .markChanged .. => Except BufferRefusal Unit
  | .tellChanged _ => Except BufferRefusal Unit
  | .setAutoReload _ => Unit
  | .autoReloadMode => Bool
  | .unfollow _ => Unit
  | .refuseFollow _ => Unit
  | .openPrompt .. => Except PromptRefusal ViewId
  | .closePrompt _ => Except PromptRefusal Unit
  | .setCandidates _ => Except PromptRefusal Unit
  | .chooseCandidate _ => Except PromptRefusal Unit
  | .setWanted .. => Except LayoutRefusal Unit
  | .ex _ => Option Ex.Binding
  | .exNames => Array String
  | .themeNames => Array String
  | .loadTheme _ => Except ThemeRefusal Unit
  | .invoke _ => Unit
  | .runCommand .. => Bool
  | .quit => Unit
  | .reload => Unit
  | .giveUp _ => Unit
  | .breakOff _ => Unit
  | .setRegister .. => Unit
  | .setLastFind _ => Unit
  | .setLastSearch _ => Unit
  | .setScrollMargin _ => Unit
  | .recordWorkspace .. => Unit
  | .registerWorkspace .. => Except WorkspaceRefusal Unit
  | .setWorkspaceValue .. => Except WorkspaceRefusal Unit
  | .setProjectValue .. => Except WorkspaceRefusal Unit
  | .workspaceSettings => Workspace.Settings × Nat
  | .displayRules => Array DisplayRule

namespace EditorState

/-- Makes the mode called `name` the major mode of the buffer the window
`view` shows, and says whether it became the major mode
(`EditorState.setMajorMode`). Any name is taken. Refused, with the state
unchanged, with `noSuchWindow` for a view with no window. -/
def setMajorModeOf (view : ViewId) (name : String) (state : EditorState) :
    Except ModeRefusal Bool × EditorState :=
  match state.target? view with
  | none => (.error (.noSuchWindow view), state)
  | some target =>
    match state.setMajorMode target.window.buffer name with
    | (.ok became, next) => (.ok became, next)
    | (.error _, _) => (.error (.noSuchWindow view), state)

/-- The reply to `request` from `state`, and the state after it: each
request is its operation of `Editor/State.lean`. A refused request leaves
the state as it was. -/
def handle : (request : StateRequest) → EditorState → request.Reply × EditorState
  | .read, state => (state, state)
  | .addBuffer name text history, state => state.addBuffer name text history
  | .removeBuffer id, state => state.removeBuffer id
  | .renameBuffer id name, state => state.renameBuffer id name
  | .setHistory id history, state => state.setHistory id history
  | .setValue id name value, state => state.setValue id name value
  | .setMajorMode view name, state => state.setMajorModeOf view name
  | .addMinorMode id name, state => state.addMinorMode id name
  | .removeMinorMode id name, state => state.removeMinorMode id name
  | .split view scroll selection placement, state =>
    state.splitWindow view scroll selection placement
  | .arrange view change, state => state.arrange view change
  | .openWindow buffer scroll selection spot, state => state.openWindow buffer scroll selection spot
  | .removeWindow view, state => state.removeWindow view
  | .focus view, state => state.focusWindow view
  | .show view buffer scroll selection, state => state.showBuffer view buffer scroll selection
  | .message text, state => ((), { state with echo := text })
  | .startJob name arguments, state =>
    (.ok (), { state with starts := state.starts.push { name, arguments } })
  | .attachFile id path stamp ending, state => state.attachFile id path stamp ending
  | .beginSave id snapshot saved, state => state.beginSave id snapshot saved
  | .endSave id snapshot stamp, state => state.endSave id snapshot stamp
  | .markChanged id stamp found told, state => state.markChanged id stamp found told
  | .tellChanged id, state => state.tellChanged id
  | .setAutoReload on, state => ((), { state with autoReload := some on })
  -- Config's setting is the loop's to answer with (`Program.dispatched`):
  -- here, with no loop, a choice no command made is off.
  | .autoReloadMode, state => (state.autoReload.getD false, state)
  | .unfollow id, state => ((), { state with following := state.following.filter (·.buffer != id) })
  | .refuseFollow id, state =>
    ((),
      { state with
        following :=
          state.following.map fun entry =>
            if entry.buffer == id then { entry with refused := true } else entry })
  | .openPrompt label continuation text history scroll selection, state =>
    state.openPrompt label continuation text history scroll selection
  | .closePrompt answer, state => state.closePrompt answer
  | .setCandidates all, state => state.setCandidates all
  | .chooseCandidate step, state => state.chooseCandidate step
  | .setWanted view wanted, state => state.setWanted view wanted
  | .ex _, state => (none, state)
  | .exNames, state => (#[], state)
  | .themeNames, state => (#[], state)
  | .loadTheme name, state => (.ok (), { state with theme := some name })
  | .invoke invocation, state => ((), { state with answered := state.answered.push invocation })
  | .runCommand .., state => (false, state)
  | .quit, state => ((), { state with quitting := true })
  | .reload, state => ((), { state with reload := true })
  | .giveUp _, state => ((), state)
  | .breakOff _, state => ((), state)
  | .setRegister name register, state => ((), state.setRegister name register)
  | .setLastFind find, state => ((), state.setLastFind find)
  | .setLastSearch search, state => ((), state.setLastSearch search)
  | .setScrollMargin rows, state => ((), state.setScrollMargin rows)
  | .recordWorkspace directory generation found, state =>
    ((), state.recordWorkspace directory generation found)
  | .registerWorkspace location remote branch, state =>
    state.registerWorkspace location remote branch
  | .setWorkspaceValue location name value, state => state.setWorkspaceValue location name value
  | .setProjectValue identity name value, state => state.setProjectValue identity name value
  -- Config's roots and its generation are the loop's to answer with
  -- (`Program.dispatched`): here, with no loop, config has none.
  | .workspaceSettings, state => (({}, 0), state)
  -- Config's rules are the loop's to answer with (`Program.dispatched`):
  -- here, with no loop, config has none.
  | .displayRules, state => (#[], state)

end EditorState

end Editor
