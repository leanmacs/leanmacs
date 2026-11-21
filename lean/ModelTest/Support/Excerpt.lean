import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Config.Registry
import Editor.Event
import Editor.File
import Editor.Floating
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Excerpt
import Editor.Test.Loop
import Editor.Text
import Editor.Text.Contract
import ModelTest.Support.Evil

/-!
# Model tests: support: Excerpt

The excerpt buffers' commands, registrations and driver, under evil's keys.
What a check reads of an excerpt buffer is the kit's
(`Editor/Test/Excerpt.lean`). Shared by several test modules under
`ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The stamp of the file `one.txt` the excerpt buffer checks give source
buffer `one` (`excerptRegistrations`, `one-changed`). -/
def excerptStamp : File.Stamp :=
  ⟨0, 0, 14⟩

/-- The commands of the excerpt buffer checks, each a `Config.Registration`
evil's commands are handed beside: `make-ex` makes source buffers `one`
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
disk, the user not told; `edit-redo` inserts `x` at the start of the
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
    { name := "edit-redo"
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
def excerptInvoked (driver : EvilDriver) (name : String) : EvilDriver :=
  (driver.stepped (driver.loop.invoke driver.handed { command := name })).1

/-- `driver` once each of `events` is taken off the queue, in order. -/
def excerptFed (driver : EvilDriver) (events : List Event) : EvilDriver :=
  events.foldl (fun driver event => (driver.feed { event, stamp := 0 }).1) driver

/-- The view `view` of the last scene `driver` published. -/
def lastView (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option View := do
  (← driver.model.display.scenes.back?).views.find? (·.id == view)

/-- A driver of the excerpt buffer checks: evil's keys and the commands of
`excerptRegistrations`, over an empty buffer, once `make-ex` has run, so
the window shows `ex` with its cursor at its start; `none` if making the
state was refused. -/
def excerptDriver : Option EvilDriver :=
  (evilDriver "|" (evilHanded excerptRegistrations)).map (excerptInvoked · "make-ex")

end ModelTest
