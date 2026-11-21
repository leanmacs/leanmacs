import Editor.Api
import Editor.Command.Call
import Editor.Jumps
import Editor.WorkingSet.Places

/-!
# Buffers: switching a window to another buffer, listing them, closing one

The commands over the editor's open buffers, written over the editor API
(`Editor/Api.lean`): `switch-buffer`, `list-buffers` and `close-buffer`,
which the ex names `b`, `ls` and `bd` run (`Editor/Ex/Compiled.lean`). Each
reads the order the buffers were last used in, which the state keeps
(`EditorState.recent`, `openBuffers`, `mostRecent`: `Editor/State.lean`,
"Most recently used"), so none of them keeps that order by hand.

`Editor.lean` imports this module, so config calls the commands. Their
registrations, which name the registry, are in
`Editor/Buffers/Compiled.lean`. Each message is a function here, and the
checks compare the echo area with that function, never with a sentence.

## Switch

- **With a string first argument** (`switchCommand`) the command shows the
  buffer it names in the window it was called with: the buffer of exactly
  that name, and otherwise the first of the open buffers' names, in the
  prompt's order, that the completion style of the category `buffer`
  matches it with (`matchByCategory`, `Editor/Api.lean`): the fuzzy
  matcher's best (`Fuzzy.rank`, `Editor/Fuzzy.lean`) unless config chose
  another style for `buffer`. Nothing matching is said (`noMatch`), and
  the window keeps its buffer. A window
  that is the minibuffer's shows the buffer in the window the prompt was
  asked from (`EditorState.shownIn`), as the open command does. Switching is a
  jump, as opening a file is: the window records one before it shows the
  buffer (`Jumps.record`).
- **With anything else first** it asks, with a prompt labelled
  `switchPrompt` whose continuation is the command itself, as `open-file`
  and `ex` ask. A key bound to it under the Vim scheme hands it a count and
  a register, so it asks. The prompt's candidates are the open buffers'
  names, most recently used first, with the asking window's own buffer
  last: the empty pattern lists the buffer used before this one first, so
  choosing the first candidate and accepting is "the other buffer". They
  come from the completion source `buffers`, of the category `buffer`
  (`source`, `Editor/Completion.lean`), registered by compiled code under
  its name: the prompt asks for the sources of the category `buffer`, with
  `source` as its default. So config adds candidates after the buffers' by
  registering a source in `buffer`, and replaces them by registering one
  under the name `buffers`; a host that registered none lists the
  buffers.
- **So a buffer is chosen as the prompt lists it, both ways.** A pattern
  typed and accepted with nothing chosen answers the text, and the command
  takes the first open buffer the prompt lists for it, by the style the
  listing was made with; a key of the minibuffer that chooses a listed
  candidate makes the answer exactly that candidate's name. A candidate
  config's source adds is no buffer's name, so it is passed over.
- Where the prompt is refused, because one is open, the echo area says so
  (`notAsking`).

## List

- **The list is a text view over generated text** (`listCommand`): a buffer
  called `listBuffer`, with no file, whose text is one line per open buffer
  (`listing`), most recently used first, the list's own buffer and the
  minibuffer's left out. Each line is a mark, `+` for a buffer with unsaved
  changes and a space otherwise, a space and the buffer's name, and for a
  buffer with a file two spaces and its path.
- **"Unsaved" is what `quit` asks** (`BufferId.hasUnsavedChanges`), so an
  edit made earlier in the same command counts, and a buffer with no file
  never has unsaved changes.
- **The list is the buffer the list command marked** (`listOf`): it sets a
  buffer-local value, `listMark`, on the buffer it makes, and a later list
  finds the buffer by that value and that it has no file, never by its
  name. A buffer that only happens to be called `listBuffer`, such as a
  file's, is neither replaced nor left out of the list; the list is then
  made under a free name made from `listBuffer`
  (`EditorState.freeName`).
- **The first list makes the buffer, and a later one replaces its text**,
  whole: there is one list. The text is what the buffers were when the
  command ran; listing again brings it up to date.
- **The list is shown where the display rules say** (`BufferId.display`,
  `Editor/DisplayRules.lean`), for the opener `list-buffers`: by default in
  a new window at the end of the tiled list, the stack, focused, so the
  window the command was called in keeps its buffer. A window that shows
  the list already is used, so `ls` again focuses the list's window and
  makes no other.
- **It is an ordinary buffer.** Motions and search work in it, it is a
  candidate of the switch, and closing it is closing a buffer. A mode of
  its own, with keys that act on the line's buffer, is not built.

## Close

- **The places held in a closed buffer's text outlive it**: before the
  windows show another buffer, every jump list entry and global mark held
  in it is detached into its file's path, row and column, or dropped when
  it has no file (`Jumps.detach`); its own marks go with it. So do the
  working sets' ranges held in it: each is detached into its stored form,
  refreshed from the text as it is (`WorkingSet.detach`,
  `Editor/WorkingSet/Places.lean`).
- **The buffer closed** (`closeCommand`) is the one a string first argument
  names, exactly, and otherwise the buffer of the window the command was
  called with. A name no buffer has is said (`noBuffer`). The minibuffer's
  buffer is not closed this way (`ofMinibuffer`).
- **A buffer with unsaved changes is not closed**: it is a buffer that
  holds a file, and nothing changes but the echo area, which says so
  (`notClosing`), in the shape `quit` says it. A buffer with no file never
  blocks it, by `quit`'s rule (`Editor/Ex.lean`, "Quit").
- **A buffer with a save in flight is not closed** either, whatever its
  text: the echo area says so (`beingSaved`), and the close can be asked
  again once the save is delivered. The save may still be refused, the
  file having changed behind the editor, and the buffer is then the only
  holder of the edits it was writing; `quit` waits for the save for the
  same reason (`EditorState.leaves`). Refusing is chosen over waiting, as
  quit waits, because a close request has nothing in the state to wait
  in.
- **Every window that showed it shows the most recently used buffer left**
  (`EditorState.mostRecent`), with one cursor at its start (`ViewId.show`),
  and then the buffer is removed. The loop releases the windows' old
  markers and the buffer's text once the command has run to its end
  (`Editor/Loop.lean`, "What a finished command gave up"). It says
  nothing, as Vim's `:bd` says nothing.
- **The last open buffer leaves an empty one** with no file, called
  `EditorState.scratchName`, as the initial buffer is: it is made, shown in
  every window that showed the closed one, the closed one is removed, and
  the new one is then renamed to `scratchName`, which is free by then even
  when the closed buffer was the initial `scratch`. A buffer that is shown
  cannot be removed and a name that is taken cannot be given, so the new
  buffer is made under a free name first. Vim calls its equivalent
  `[No Name]`.
- **The rule of what takes a closed buffer's place is `close`'s**, which
  checks nothing else; the close command calls it once its own checks
  pass, and a feature that removes a buffer of its own, such as the commit
  message buffer (`Editor/VersionControl/Commit.lean`), calls it too.
- **Not built**: a buffer's last cursor, which Vim gives back when a window
  shows it again.

Pinned by `ModelTest.bufferCommandChecks`, on the loop's driver over the
editor's models, and the order the state keeps by `ModelTest.stateChecks`.
-/

namespace Editor.Buffers

/-- The name the switch command is registered under. -/
def switchName : String :=
  "switch-buffer"

/-- The name the list command is registered under. -/
def listName : String :=
  "list-buffers"

/-- The name the close command is registered under. -/
def closeName : String :=
  "close-buffer"

/-- The label of the prompt the switch command asks for a buffer with. -/
def switchPrompt : String :=
  "Buffer: "

/-- What the name of the buffer the list command makes is. -/
def listBuffer : String :=
  "buffer-list"

/-- The name of the buffer-local value the list command sets on the buffer
it makes, by which a later list finds it (`listOf`): no other command sets
it, so a buffer that only happens to be called `listBuffer`, a file's among
them, is not taken for the list. -/
def listMark : String :=
  "list-buffers"

/-- What the echo area says when no open buffer matches `text`. -/
def noMatch (text : String) : String :=
  s!"{switchName}: no buffer matches {text}"

/-- What the echo area says when the switch command was called with no
buffer and could not ask for one: the refusal's own sentence, after the
command's name. -/
def notAsking (refusal : PromptRefusal) : String :=
  s!"{switchName}: {refusal.describe}"

/-- What the echo area says when the buffer called `name` was chosen and
the state refused to show it. -/
def notShown (name : String) : String :=
  s!"{switchName}: could not show {name}"

/-- What the echo area says when the list could not be made or shown. -/
def notListed : String :=
  s!"{listName}: could not show the list"

/-- What the echo area says when no buffer is called `name`. -/
def noBuffer (name : String) : String :=
  s!"{closeName}: no buffer called {name}"

/-- What the echo area says when the buffer to close is the minibuffer's. -/
def ofMinibuffer : String :=
  s!"{closeName}: the minibuffer is closed by answering or cancelling its prompt"

/-- What the echo area says when the buffer called `name` was not closed
because it has unsaved changes. -/
def notClosing (name : String) : String :=
  s!"{closeName}: {name} has unsaved changes"

/-- What the echo area says when the buffer called `name` was not closed
because a save of it is in flight. -/
def beingSaved (name : String) : String :=
  s!"{closeName}: {name} is being saved; try again when it is written"

/-- The open buffers of `state` and their names, most recently used first
(`EditorState.openBuffers`). -/
def named (state : EditorState) : Array (BufferId × String) :=
  state.openBuffers.filterMap fun id => (state.buffer? id).map fun buffer => (id, buffer.name)

/-- The open buffers of `state` and their names in the switch prompt's
order: most recently used first, with `asking`, the asking window's buffer,
last. -/
def ordered (state : EditorState) (asking : BufferId) : Array (BufferId × String) :=
  let all := named state
  (all.filter (·.1 != asking)) ++ all.filter (·.1 == asking)

/-- The switch prompt's candidates, as `state` is: the open buffers' names,
most recently used first, with the name of `asking`, the asking window's
buffer, last. -/
def candidates (state : EditorState) (asking : BufferId) : Array String :=
  (ordered state asking).map (·.2)

/-- The completion source of the switch prompt's candidates (`candidates`),
as the state is when it is asked, with the buffer of the view the query is
asked from as the asking window's: `buffers`, of the category `buffer`. A
view with no window answers none. -/
def source : Completion.Source :=
  { name := "buffers", category := "buffer"
    candidates := fun query => do
      let state ← editorState
      let some target := state.target? query.view | return #[]
      return (candidates state target.window.buffer).map Completion.Candidate.ofText }

/-- The open buffer `text` names, as `state` is, asked from a window showing
`asking`: the one of exactly that name, and otherwise the first of the
open buffers' names, in the switch prompt's order (`ordered`), that the
style of the category `buffer` matches it with (`matchByCategory`), so the
first the prompt lists for it; `none` when none matches. -/
def resolve (state : EditorState) (asking : BufferId) (text : String) : EditorM (Option BufferId) :=
  do
  let all := ordered state asking
  if let some (id, _) := all.find? (·.2 == text) then
    return some id
  let hits ← matchByCategory source.category text (all.map (·.2))
  return (hits[0]?.bind (all[·.index]?)).map (·.1)

/-- Shows the open buffer `text` names (`resolve`) in `view`, or, for the
minibuffer's view, in the window its prompt was asked from
(`EditorState.shownIn`), whose buffer is the asking one. Nothing matching is said
(`noMatch`), and the window keeps its buffer. -/
def switchTo (view : ViewId) (text : String) : EditorM Unit := do
  let state ← editorState
  let some target := state.target? (state.shownIn view) | message (noMatch text)
  let some id ← resolve state target.window.buffer text | message (noMatch text)
  let name := ((state.buffer? id).map (·.name)).getD text
  -- Switching buffers is a jump, as opening a file is.
  Jumps.record (state.shownIn view)
  if let .error _← (state.shownIn view).show id then
    message (notShown name)

/-- The switch command as it is called ("Switch", in the module docs): shows
the buffer its first argument, a string, names (`switchTo`). With anything
else first, or nothing, it asks for one (`prompt`, labelled
`switchPrompt`), with itself as the continuation and the open buffers'
names as the candidates (`source`). Where the prompt is refused it says
so (`notAsking`). -/
def switchCommand (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str text :: _ =>
    switchTo call.target.window.id text
  | _ =>
    if let .error refusal←
        prompt switchPrompt { command := switchName } (sources :=
          [.category "buffer" [source]]) then
      message (notAsking refusal)

/-- The buffer list of `state`, if there is one: the open buffer with no file
that keeps the value `listMark`, which the list command sets on the buffer
it makes. -/
def listOf (state : EditorState) : Option BufferId :=
  state.openBuffers.find? fun id =>
    (state.buffer? id).any (·.file.isNone) && (state.value? id listMark).isSome

/-- The text of the buffer list ("List", in the module docs): one line per
open buffer of `state` (`EditorState.openBuffers`) but the list's own (`listOf`), each
`+` when `unsaved` says the buffer has unsaved changes and a space
otherwise, a space and the buffer's name, and for a buffer with a file two
spaces and its path, each line ending in a line feed. -/
def listing (state : EditorState) (unsaved : BufferId → Bool) : String :=
  let list := listOf state
  String.join <|
    (state.openBuffers.filterMap fun id => do
        guard (list != some id)
        let buffer ← state.buffer? id
        let mark := if unsaved id then "+" else " "
        let path := (buffer.file.map fun file => s!"  {file.path}").getD ""
        return s!"{mark} {buffer.name}{path}\n").toList

/-- The list command as it is called ("List", in the module docs): makes the
text of the buffer list (`listing`), with each buffer's unsaved changes as
`BufferId.hasUnsavedChanges` answers them; puts it in the buffer list
(`listOf`), made by the first list, called `listBuffer` or, where a buffer
has that name, a free name made from it, and marked with `listMark`, and
with its whole text replaced by a later list; and displays that buffer
where the display rules say, for the opener `listName`, from the window it
was called with (`BufferId.display`). It reads nothing else of its call. -/
def listCommand (call : Call) : EditorM Unit := do
  let state ← editorState
  let mut unsaved : Array BufferId := #[]
  for id in state.openBuffers do
    if let .ok true← id.hasUnsavedChanges then
      unsaved := unsaved.push id
  let text := listing state unsaved.contains
  let mut made : Option BufferId := none
  if let some id := listOf state then
    if let .ok held← id.text then
      let length ← held.byteLength
      held.replaceRange 0 length text
      made := some id
  else if let .ok id← createBuffer (state.freeName listBuffer) text then
    if let .ok ()← id.setValue listMark (.bool true) then
      made := some id
  let some id := made | message notListed
  if let .error _← id.display call.target.window.id listName then
    message notListed

/-- Ends the command, rolled back, for a request the command's own reading
of the state says cannot be refused. -/
def unrefused {ε : Type} (what : String) : Except ε Unit → EditorM Unit
  | .ok () => pure ()
  | .error _ => giveUp s!"{what} was refused"

/-- Closes the buffer `id` ("Close", in the module docs): the places held in
its text are detached into its file first (`Jumps.detach`), then every
window of every tab that shows it, tiled, docked or floating
(`Frame.everyWindow`), shows `fallback`, and then it is removed. -/
def closeInto (id fallback : BufferId) : EditorM Unit := do
  -- The places held in its text outlive it, in its file.
  Jumps.detach id
  discard <| WorkingSet.detach id
  -- A working set's buffer takes its drifted quotes with it.
  WorkingSet.freeDrifted id
  let state ← editorState
  for view in state.frame.everyWindow do
    if (state.window? view).any (·.buffer == id) then
      unrefused "showing the buffer left" (← view.show fallback)
  unrefused "removing the buffer" (← id.remove)

/-- Closes the buffer `id` whatever it holds ("Close", in the module docs):
every window that showed it shows the most recently used buffer left
(`closeInto`), and when none is left, a new empty buffer with no file
called `EditorState.scratchName`, made under a free name and renamed once
the closed one has given its name up. It checks nothing: the close command
refuses a buffer with unsaved changes or a save in flight before it calls
this, and a feature closing a buffer of its own calls it directly. -/
def close (id : BufferId) : EditorM Unit := do
  let state ← editorState
  match state.mostRecent id with
  | some fallback =>
    closeInto id fallback
  | none =>
    -- The last buffer: an empty one takes its place, made under a free name
    -- and renamed once the closed one has given its name up.
    let .ok made ←
      createBuffer
          (state.freeName EditorState.scratchName) | giveUp "making the empty buffer was refused"
    closeInto id made
    unrefused "naming the empty buffer" (← made.rename EditorState.scratchName)

/-- The close command as it is called ("Close", in the module docs): closes
the buffer its first argument, a string, names exactly, and otherwise the
buffer of the window it was called with. A name no buffer has is said
(`noBuffer`), and so is the minibuffer's buffer (`ofMinibuffer`). A buffer
with a save in flight is not closed (`beingSaved`), and nor is one with
unsaved changes (`notClosing`); the echo area says which. Otherwise it is
closed (`close`). -/
def closeCommand (call : Call) : EditorM Unit := do
  let state ← editorState
  let named? : Option BufferId :=
    match call.arguments with
    | .str name :: _ => state.findBuffer name
    | _ => some call.target.window.buffer
  let some id := named? |
    match call.arguments with
    | .str name :: _ =>
      message (noBuffer name)
    | _ =>
      pure ()
  if state.minibufferBuffer? == some id then
    message ofMinibuffer
    return
  let name := ((state.buffer? id).map (·.name)).getD ""
  if (state.buffer? id).any (·.file.any (·.saving.isSome)) then
    message (beingSaved name)
    return
  if let .ok true← id.hasUnsavedChanges then
    message (notClosing name)
    return
  close id

end Editor.Buffers
