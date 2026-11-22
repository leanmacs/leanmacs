import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Config.Registry
import Editor.Event
import Editor.File
import Editor.Floating
import Editor.Invocation
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.Scroll
import Editor.State
import Editor.Text
import Editor.Text.Contract

/-!
# The test kit: Excerpt

What a check reads of an excerpt buffer (`excerptBufferNamed`,
`excerptRead`); the commands of the excerpt buffer checks
(`excerptRegistrations`), which a driver of any scheme is handed, with what
runs one and reads its view (`excerptInvoked`, `excerptFed`, `lastView`,
`blockedSeen`), so the core's checks of excerpt buffers and a scheme
package's checks of its keys in one start from the same buffers; and the
stand-in for a project search's results
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

/-- The stamp of the file `one.txt` the excerpt buffer checks give source
buffer `one` (`excerptRegistrations`, `one-changed`). -/
def excerptStamp : File.Stamp :=
  ⟨0, 0, 14⟩

/-- The commands of the excerpt buffer checks, each a `Config.Registration`
a driver is handed beside its scheme's commands: `make-ex` makes source buffers `one`
(`one\ntwo\nthree\n`) and `two` (`alpha\nbeta\n`) and an excerpt buffer `ex`
of the second row of the first and the first row of the second
(`two\n\nalpha\n`), and shows `ex` in the window; `edit-both` applies one
transaction to the window's text that inserts `X` in the first excerpt and
replaces the first byte of the second with `A`; `edit-both-fails` does that
and is then refused; `edit-one` inserts `Z` at the start of `one`'s text;
`show-one` shows `one` in the window; `two-ro` makes `two` read-only;
`make-unheld` makes an excerpt buffer `ex2` of a text no buffer holds and
shows it; `insert-x` inserts `x` at the window's cursors; `one-changed` has
`one` hold the file `one.txt`, at `excerptStamp`, and marks it changed on
disk, the user not told; `insert-redo` inserts `x` at the start of the
window's buffer and then redoes in it, saying `redo moved` unless the redo
answered nothing; `remove-one` removes `one`, which no window shows.
For the display checks (`excerptDisplayChecks`): `make-six` makes an
excerpt buffer `six` of six whole lines of two buffers, headed `h1` to
`h6`, and shows it; `make-overlap` gives `one` the span `4..7` in
`compilation.error`, makes an excerpt buffer `overlap` of `one` 0..8 and
4..14, which show `two` twice, gives it a span `0..1` of its own, sets the
last search to `w`, and shows it; `make-plain` shows a plain buffer `plain`
of `ex`'s text; and `float-five` floats a buffer `note`, unfocused, at the
position 5 of the window's view. For the viewed checks
(`excerptDisplayChecks`): `make-tracked` makes an excerpt buffer `tracked`
of the same six lines as `six`, each excerpt tracked, and shows it; and
`noop` does nothing, so its step only publishes. -/
def excerptRegistrations : Array Config.Registration :=
  #[{ name := "make-ex"
      action :=
        .call fun call => do
          let .ok one ← createBuffer "one" "one\ntwo\nthree\n" | return
          let .ok two ← createBuffer "two" "alpha\nbeta\n" | return
          let .ok ex ←
            createExcerptBuffer "ex"
                #[{ buffer := one, start := 4, stop := 8, header := "one" },
                  { buffer := two, start := 0, stop := 6, header := "two" }] | return
          discard <| call.target.window.id.show ex },
    { name := "edit-both"
      action :=
        .call fun call =>
          discard <| call.target.buffer.text.apply TextContract.acrossBoth Origin.user },
    { name := "edit-both-fails"
      action :=
        .call fun call => do
          discard <| call.target.buffer.text.apply TextContract.acrossBoth Origin.user
          call.target.buffer.text.delete 9 99 },
    { name := "edit-one"
      action :=
        .call fun _ => do
          let some one ← findBuffer "one" | return
          discard <| one.insertAt 0 "Z" },
    { name := "show-one"
      action :=
        .call fun call => do
          let some one ← findBuffer "one" | return
          discard <| call.target.window.id.show one },
    { name := "two-ro"
      action :=
        .call fun _ => do
          let some two ← findBuffer "two" | return
          discard <| two.setReadOnly true },
    { name := "make-unheld"
      action :=
        .call fun call => do
          let free ← createText "free\n"
          let .ok ex ← createExcerptBufferOf "ex2" #[⟨free, 0, 5⟩] | return
          discard <| call.target.window.id.show ex },
    { name := "insert-x", action := .call fun call => call.target.insertAtSelections "x" },
    { name := "one-changed"
      action :=
        .call fun _ => do
          let some one ← findBuffer "one" | return
          discard <| one.attachFile "one.txt" excerptStamp .lf
          discard <| one.markChanged excerptStamp (some { excerptStamp with size := 15 }) false },
    { name := "insert-redo"
      action :=
        .call fun call => do
          discard <| call.target.window.buffer.insertAt 0 "x"
          let answer ← call.target.window.buffer.redo
          unless answer matches .ok none do
            message "redo moved" },
    { name := "remove-one"
      action :=
        .call fun _ => do
          let some one ← findBuffer "one" | return
          discard <| one.remove },
    { name := "make-six"
      action :=
        .call fun call => do
          let .ok first ← createBuffer "first" "one\ntwo\nthree\n" | return
          let .ok second ← createBuffer "second" "alpha\nbeta\nx\n" | return
          let ranges :=
            #[(first, 0, 4), (first, 4, 8), (first, 8, 14), (second, 0, 6), (second, 6, 11),
              (second, 11, 13)]
          let list :=
            ranges.mapIdx fun index (buffer, start, stop) =>
              { buffer, start, stop, header := s!"h{index + 1}" : BufferExcerpt }
          let .ok six ← createExcerptBuffer "six" list | return
          discard <| call.target.window.id.show six },
    { name := "make-overlap"
      action :=
        .call fun call => do
          let some one ← findBuffer "one" | return
          discard <| one.setSpans #[⟨4, 7, ⟨"compilation.error"⟩⟩]
          let .ok overlap ←
            createExcerptBuffer "overlap"
                #[{ buffer := one, start := 0, stop := 8 },
                  { buffer := one, start := 4, stop := 14 }] | return
          discard <| overlap.setSpans #[⟨0, 1, ⟨"own"⟩⟩]
          setLastSearch { pattern := "w", forward := true }
          discard <| call.target.window.id.show overlap },
    { name := "make-plain"
      action :=
        .call fun call => do
          let .ok plain ← createBuffer "plain" "two\n\nalpha\n" | return
          discard <| call.target.window.id.show plain },
    { name := "float-five"
      action :=
        .call fun call => do
          let .ok note ← createBuffer "note" "n" | return
          discard <| note.float (.position call.target.window.id 5) (focus := false) },
    { name := "make-tracked"
      action :=
        .call fun call => do
          let .ok first ← createBuffer "first" "one\ntwo\nthree\n" | return
          let .ok second ← createBuffer "second" "alpha\nbeta\nx\n" | return
          let ranges :=
            #[(first, 0, 4), (first, 4, 8), (first, 8, 14), (second, 0, 6), (second, 6, 11),
              (second, 11, 13)]
          let list :=
            ranges.mapIdx fun index (buffer, start, stop) =>
              { buffer, start, stop, header := s!"h{index + 1}", tracked := true : BufferExcerpt }
          let .ok tracked ← createExcerptBuffer "tracked" list | return
          discard <| call.target.window.id.show tracked },
    { name := "noop", action := .call fun _ => pure () }]

/-- `driver` once the command `name` has run, as an invocation no key
yielded. -/
def excerptInvoked {scheme : InputScheme} (driver : Loop.Driver scheme) (name : String) :
    Loop.Driver scheme :=
  (driver.stepped (driver.loop.invoke driver.handed { command := name })).1

/-- `driver` once each of `events` is taken off the queue, in order. -/
def excerptFed {scheme : InputScheme} (driver : Loop.Driver scheme) (events : List Event) :
    Loop.Driver scheme :=
  events.foldl (fun driver event => (driver.feed { event, stamp := 0 }).1) driver

/-- The view `view` of the last scene `driver` published. -/
def lastView {scheme : InputScheme} (driver : Loop.Driver scheme) (view : ViewId := ⟨0⟩) :
    Option View := do
  (← driver.model.display.scenes.back?).views.find? (·.id == view)

/-- Of the window's view in the last scene of `driver`: its scroll anchor's
offset, the head of its selection's primary range, and whether the rows the
display model answers from its anchor, asked with its blocks, hold the
row of that head, also asked with them. -/
def blockedSeen {scheme : InputScheme} (driver : Loop.Driver scheme) : Option (Nat × Nat × Bool) :=
  do
  let shown ← lastView driver
  let #[marker] := shown.selections | none
  let program : EditorM (Nat × Nat × Bool) := do
    let .anchor anchor ← shown.scroll.text.marker shown.scroll | throw .noSuchMarker
    let .selection selection ← marker.text.marker marker | throw .noSuchMarker
    let some range := selection.ranges[selection.primary]? | throw .badSelection
    let area :=
      Scroll.Area.ofRect shown.snapshot shown.rect driver.model.display.cells.heights.status
        shown.padding shown.blocks
    let rows ← area.rows anchor.offset
    let own := (← area.rows range.head)[0]?
    return (anchor.offset, range.head, own.any rows.contains)
  (program.runModel driver.model).1.toOption

end Editor.Test
