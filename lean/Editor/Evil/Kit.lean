import Editor.Api
import Editor.Command.Call
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Event
import Editor.Evil.Compiled
import Editor.InputScheme.Vim.Default
import Editor.Loop
import Editor.Loop.Driver
import Editor.State
import Editor.Test.AtPoint
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree

/-!
# Evil's test kit

The driver of evil's checks under the Vim scheme that ships, moved from the
core's evil test support (`ModelTest/Support/Evil.lean`, which imports it):
a fixture's text with its cursor written as a bar (`barred`, `withBar`), the
loop and the driver over the Vim scheme (`EvilLoop`, `EvilDriver`), what a
step is handed (`evilHanded`: evil's commands, the kit's minibuffer's and
at-point's, and a check's own), the state and the driver over a fixture
(`evilState`, `evilDriver`), keys fed to it (`evilFed`), and what a view of
it shows (`evilSelection`, `evilShown`).

It is evil's feature kit: a test double, which a package's test modules may
import and its library may not (`docs/design/packages.md`, "What a package
may import"). The working sets' and the workspace's tests drive their
commands under evil's keys through it until the features-as-packages
roadmap's phase 7, which moves it with evil. Project search's tests do not
(that phase's third criterion): they run on the test scheme.
-/

namespace Editor.Test

open Editor

/-- A fixture of the evil checks, which writes the cursor into the text as
a bar: the text without the bar, and the bar's byte offset. A fixture with
no bar has its cursor at 0. -/
def barred (fixture : String) : String × Nat :=
  match fixture.splitOn "|" with
  | [before, after] => (before ++ after, before.utf8ByteSize)
  | _ => (fixture, 0)

/-- `contents` with a bar written before the character at the byte offset
`offset`, or at its end. An offset that is no character's start, and none
past the end, writes no bar, so a fixture's expectation does not match. -/
def withBar (contents : String) (offset : Nat) : String :=
  let (shown, walked) :=
    contents.foldl
      (fun (shown, walked) char =>
        ((if walked == offset then shown.push '|' else shown).push char, walked + char.utf8Size))
      ("", 0)
  if walked == offset then shown.push '|' else shown

/-- The loop the evil checks run: one over the Vim scheme that ships. -/
abbrev EvilLoop :=
  Loop Vim.Default.scheme

/-- The driver the evil checks run: one over the Vim scheme that ships. -/
abbrev EvilDriver :=
  Loop.Driver Vim.Default.scheme

/-- What a step of the evil checks is handed: no active keymaps, so that a
key is looked up in the keymaps of its view's Vim state alone, and the
commands compiled code registers for evil (`Evil.package.registered.commands`), and the
kit's for the minibuffer (`Test.Minibuffer.package.registered.commands`,
`Editor/Test/Minibuffer.lean`), so that `/` and `?` ask and are answered, and the kit's for completion at point
(`Test.AtPoint.package.registered.commands`, `Editor/Test/AtPoint.lean`), so
that insert state's `RET`, `TAB` and `C-g` type and quit as the package that
ships has them do, and those of `more`, each under the
name it is registered under, then `commands`. A
command of `more` runs in place of one of evil's of the same name, as the
registry's latest entry of a name does. -/
def evilHanded (more : Array Config.Registration := #[])
    (commands : List (String × Dispatched) := []) : Loop.Keys Vim.Default.scheme :=
  {
    command? := fun name =>
      match
        (Evil.package.registered.commands ++ Test.Minibuffer.package.registered.commands ++
              Test.AtPoint.package.registered.commands ++
              more).findRev?
          (·.name == name) with
      | some { action := .call run, .. } =>
        some fun call => do
          run call
          return none
      | _ => (commands.find? (·.1 == name)).map (·.2) }

/-- A state of the evil checks: one buffer, `scratch`, over a text made
holding `contents`, so that nothing is pending in its history, and one
window on it, focused, in a frame of 640 by 480, whose selection is one
cursor at the byte offset `head`, of the shape the Vim scheme that ships
reports of a view before any key. -/
def evilState (contents : String) (head : Nat) : TextM EditorState := do
  let text ← createText contents
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let shape := (Vim.Default.scheme.report Vim.Default.scheme.init ⟨0⟩).shape
  let selection ← text.mark (.selection { ranges := #[⟨head, head⟩], shape })
  let history ← UndoTree.over text
  return {
      buffers := #[some { name := "scratch", text, history }]
      windows := #[{ id := ⟨0⟩, buffer := ⟨0⟩, scroll, selection }]
      frame := { size := ⟨640, 480⟩, windows := #[⟨0⟩], focused := ⟨0⟩ } }

/-- A driver of the evil checks over the state the fixture `fixture` says
(`evilState`), each step handed `handed`, with no job registered; `none` if
making the state was refused. -/
def evilDriver (fixture : String) (handed : Loop.Keys Vim.Default.scheme := evilHanded) :
    Option EvilDriver :=
  let (contents, head) := barred fixture
  (Loop.Driver.over handed (fun _ => none) (evilState contents head) editorModel).toOption

/-- `driver` fed a press of each key the key string `text` names, in
order. -/
def evilFed (driver : EvilDriver) (text : String) : EvilDriver :=
  (keys text).foldl (fun driver key => (driver.feed { event := press key, stamp := 0 }).1) driver

/-- The selection of the view `view` of `driver`, as the text model has
it. -/
def evilSelection (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option Selection := do
  let target ← driver.loop.state.target? view
  (target.selection.runModel driver.model.texts).1.toOption

/-- What the view `view` of `driver` shows, as a fixture writes it: its
buffer's text with a bar at the head of its selection's primary range. -/
def evilShown (driver : EvilDriver) (view : ViewId := ⟨0⟩) : String :=
  match driver.loop.state.target? view, evilSelection driver view with
  | some target, some selection =>
    match (driver.model.texts.texts[target.buffer.text.index]?).join,
      selection.ranges[selection.primary]? with
    | some content, some range => withBar content.contents range.head
    | _, _ => "no text"
  | _, _ => "no view"

end Editor.Test
