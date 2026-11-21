import Editor.Api
import Editor.Command.Call
import Editor.Config.Registry
import Editor.Loop.Driver
import Editor.State
import Editor.Text

/-!
# The test kit: Excerpt

What a check reads of an excerpt buffer (`excerptBufferNamed`,
`excerptRead`), and the stand-in for a project search's results
(`excerptFilesName`, `excerptFiles`, `excerptFilesRegistration`): a command
that makes an excerpt buffer of the whole texts of buffers it is named, each
under a header of its name, and shows it in the window, over the core's
excerpt buffers (`createExcerptBuffer`, `Editor/Api.lean`). A test of a
feature that takes ranges from a search's results, such as the working
sets', runs it in place of the project search package (D9 of the
features-as-packages roadmap's phase 6); the two together are held by the
fixture `tests/headless/working-set-from-search` of the default set. It
names no module of evil and none of project search. Shared by several test
modules; it holds no checks of its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test

open Editor

/-- The buffer called `name` in `driver`'s state, if there is one. -/
def excerptBufferNamed {scheme : InputScheme} (driver : Loop.Driver scheme) (name : String) :
    Option Buffer := do
  driver.loop.state.buffer? (← driver.loop.state.findBuffer name)

/-- What the text of the buffer called `name` holds in `driver`'s text model,
read as a command reads it, so an excerpt text is caught up. -/
def excerptRead {scheme : InputScheme} (driver : Loop.Driver scheme) (name : String) :
    Option String := do
  let buffer ← excerptBufferNamed driver name
  (buffer.text.read.runModel driver.model.texts).1.toOption

/-- The name of the kit's stand-in for a project search's results
(`excerptFiles`). -/
def excerptFilesName : String :=
  "excerpt-files"

/-- The name of the excerpt buffer `excerptFiles` makes. -/
def excerptFilesBuffer : String :=
  "*excerpts*"

/-- The kit's stand-in for a project search's results: makes the excerpt
buffer `excerptFilesBuffer` of the whole text of each buffer the call's
arguments name, in order, each under a header of its name, and shows it in
the window, its cursor at its start. A name no buffer has is left out;
nothing is made when the buffer's name is taken. -/
def excerptFiles (call : Call) : EditorM Unit := do
  let names :=
    call.arguments.filterMap fun
      | .str name => some name
      | _ => none
  let mut list : Array BufferExcerpt := #[]
  for name in names do
    let some id ← findBuffer name | continue
    let some held := (← editorState).buffer? id | continue
    let content ← (held.text.read : TextM String)
    list := list.push { buffer := id, start := 0, stop := content.utf8ByteSize, header := name }
  let .ok results ← createExcerptBuffer excerptFilesBuffer list | return
  discard <| call.target.window.id.show results

/-- `excerptFiles` as a registration, as a package's `setup` registers a
command. -/
def excerptFilesRegistration : Config.Registration :=
  { name := excerptFilesName, action := .call excerptFiles }

end Editor.Test
