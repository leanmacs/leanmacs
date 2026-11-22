import BuffersApi
import Editor.Config.Packages
import Editor.Jumps
import Editor.Test.Loop

/-!
# The fake of `buffers-api`

A close written over the core's API, as an implementation of the
interface: a package named `buffers` whose `close-buffer` closes the
window's buffer, or the one its first argument names, as `close` does: the
places held in its text detached into its file (`Jumps.detach`), the
interface's hook `BuffersApi.Closing` run, every window that showed it
showing the most recently used buffer left, or a new empty `scratch` when
none is, and the buffer removed. It refuses nothing: no unsaved changes are
asked about. `switch-buffer` shows the buffer of exactly the name it is
given, as a jump, and `list-buffers` is a stand-in that says it is the
fake's. A consumer's tests register it in place of the buffer
commands.
-/

namespace BuffersApiTest

open Editor

/-- Closes the buffer `id` over the core's API ("The fake", in the module
docs). -/
def close (id : BufferId) : EditorM Unit := do
  Jumps.detach id
  BuffersApi.runClosing id
  let state ← editorState
  let fallback ←
    match state.mostRecent id with
    | some fallback =>
      pure (some fallback)
    | none =>
      match ← createBuffer (state.freeName EditorState.scratchName) with
      | .ok made =>
        pure (some made)
      | .error _ =>
        pure none
  let some fallback := fallback | return
  for view in state.frame.everyWindow do
    if (state.window? view).any (·.buffer == id) then
      discard <| view.show fallback
  discard <| id.remove

/-- The fake's `BuffersApi.Buffers` value. -/
def buffers : BuffersApi.Buffers :=
  { name := BuffersApi.implementationName, close }

/-- The fake's close command: the buffer its first argument names, or the
window's. -/
def closeCommand (call : Call) : EditorM Unit := do
  let target ←
    match call.arguments with
    | .str name :: _ =>
      pure ((← editorState).findBuffer name)
    | _ =>
      pure (some call.target.window.buffer)
  if let some id := target then
    close id

/-- The fake's switch command: shows, as a jump, the buffer of exactly the
name its first argument is, in the window it was called with; nothing for
any other name. -/
def switchCommand (call : Call) : EditorM Unit := do
  let .str name :: _ := call.arguments | return
  let some id := (← editorState).findBuffer name | return
  Jumps.record call.target.window.id
  discard <| call.target.window.id.show id

/-- The fake's `setup`: its commands, but for those of `dropped`, and its
`Buffers` value. -/
def fakeSetup (dropped : List String := []) : SetupM Unit := do
  let commands : List (String × (Call → EditorM Unit)) :=
    [(BuffersApi.switchName, switchCommand),
      (BuffersApi.listName, fun _ => message "the fake lists nothing"),
      (BuffersApi.closeName, closeCommand)]
  for (name, run) in commands do
    unless dropped.contains name do
      commandWith name run
  Extension.add buffers

/-- The fake: a package named `buffers`. -/
def fake : Package :=
  { name := BuffersApi.implementationName, setup := fakeSetup }

/-- The fake's commands, under their names, as a driver of handed commands
dispatches them. -/
def commands : List (String × Editor.Test.Dispatched) :=
  fake.registered.commands.toList.filterMap fun registration =>
    match registration.action with
    | .call run =>
      some
        (registration.name, fun call => do
          run call
          return none)
    | _ => none

end BuffersApiTest
