import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.GeneratedView
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Test.Config
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Test.States
import Editor.Text
import Editor.Text.Model
import Editor.Value
import Editor.Workspace

/-!
# The test kit: Prompts

Prompts and the minibuffer: the commands, bindings and registry of the prompt
checks and the driver they run on, and what a scene shows of an open
prompt: the minibuffer's status line and the candidate list's view. Shared by several test modules under
`ModelTest/Editor/`; it holds no checks of its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

open Editor

/-- What the command `greet` of the prompt checks says in the echo area: the
arguments it was called with, the view of its target, and how many keys it
was told of. -/
def greeted (arguments : List Argument) (view : Nat := 0) (keys : Nat := 0) : String :=
  s!"greet {arguments.map argumentText} in view {view} with {keys} keys"

/-- The invocation the command `hand` of the prompt checks asks to be run
after it: `greet`, with two arguments of its own. -/
def handed : Invocation :=
  { command := "greet", arguments := [.str "handed", .nat 3] }

/-- The commands of the prompt checks, by name.

- `ask` asks `Name: ` with the continuation `asked`, the command `greet`
  and the argument 7, and says the refusal when it is refused. `ask-missing`,
  `ask-boom`, `ask-again` and `ask-job` ask the same with the continuations
  `nobody`, which no command is registered under, `boom`, `ask` and `start`.
  `ask-then-fail` asks and is then refused.
- `accept` and `cancel` are the API's operations.
- `greet` says what it was called with (`greeted`).
- The test scheme's self-insert inserts its argument at its target's
  cursors.
- `boom` inserts and is then refused, `other` says `other`, and `start`
  starts the job `double`.
- `hand` says `handing` and asks for `handed` to be run after it
  (`invoke`, `Editor/Api.lean`), with no prompt; `hand-then-fail` asks the
  same and is then refused; `hand-missing` asks for a command nobody
  registered. -/
def promptCommands : List (String × Dispatched) :=
  let asks (continuation : Invocation) : Dispatched := fun _ => do
    if let .error refusal← prompt "Name: " continuation then
      message s!"not asked: {refusal.describe}"
    return none
  let says (text : String) : Dispatched := fun _ => do
    message text
    return none
  [("ask", asks asked), ("ask-missing", asks { command := "nobody" }),
    ("ask-boom", asks { command := "boom" }), ("ask-again", asks { command := "ask" }),
    ("ask-job", asks { command := "start" }),
    ("ask-then-fail", failingAfter fun _ => discard <| prompt "Name: " asked),
    ("accept", fun _ => do
      discard acceptPrompt
      return none),
    ("cancel", fun _ => do
      discard cancelPrompt
      return none),
    ("greet", fun call =>
      says (greeted call.arguments call.target.window.id.index call.keys.length) call),
    ((TestScheme.selfInsert "").command, fun call => do
      let [.str text] := call.arguments | throw .badRange
      call.target.insertAtSelections text
      return none),
    ("boom", boom), ("other", says "other"),
    ("start", fun _ => do
      discard <| startJob "double" [.nat 21]
      return none),
    ("hand", fun _ => do
      message "handing"
      Editor.invoke handed
      return none),
    ("hand-then-fail", failingAfter fun _ => Editor.invoke handed),
    ("hand-missing", fun _ => do
      Editor.invoke { command := "nobody" }
      return none)]

/-- What the minibuffer holds in `driver`'s text model, while a prompt is
open. -/
def minibufferText (driver : TestDriver) : Option String := do
  let state := driver.loop.state
  let buffer ← state.buffer? (← state.minibufferBuffer?)
  (← driver.model.texts.texts[buffer.text.index]?).map (·.contents)

/-- The echo area of `driver`'s loop. -/
def promptEcho (driver : TestDriver) : String :=
  driver.loop.state.echo

/-- The commands of the minibuffer checks that `promptCommands` does not
have, by name: `ask-ada` asks as `ask` does, with the initial value `Ada`;
`to-window` focuses view 0, and `to-minibuffer` the minibuffer's view;
`close-asker` closes the view the open prompt was asked from. -/
def minibufferCommands : List (String × Dispatched) :=
  let ran (run : EditorM Unit) : Dispatched := fun _ => do
    run
    return none
  [("ask-ada", ran (discard <| prompt "Name: " asked "Ada")),
    ("to-window", ran (discard <| (⟨0⟩ : ViewId).focus)),
    ("to-minibuffer",
      ran do
        if let some view := (← editorState).minibufferView? then
          discard view.focus),
    ("close-asker",
      ran do
        if let some asking := (← editorState).prompt then
          discard asking.asker.close)]

/-- The global bindings of the minibuffer checks: a key sequence under `C-c`
and the name of the command it runs. The last two run the minibuffer's own
commands by their names, from any view: the kit's names
(`Editor/Test/Minibuffer.lean`), which are the ones a minibuffer package
registers them under. -/
def minibufferBindings : List (String × String) :=
  [("C-c a", "ask"), ("C-c i", "ask-ada"), ("C-c s", "start"), ("C-c w", "to-window"),
    ("C-c v", "to-minibuffer"), ("C-c k", "close-asker"), ("C-c 1", Minibuffer.acceptName),
    ("C-c 2", Minibuffer.cancelName)]

/-- The registry of the minibuffer checks: the commands and the modes of
`package`, by default the kit's minibuffer (`Minibuffer.package`,
`Editor/Test/Minibuffer.lean`), registered for the owner `compiled`, an
owner that is not config, as a host registers a package's, and the checks'
bindings as config's. A package's own tests hand their package. -/
def minibufferRegistry (package : Package := Minibuffer.package) : Config.Registry :=
  ((({} : Config.Registry).replace .compiled package.registered.commands).replaceModes .compiled
        package.registered.modes).replaceBindings
    .config (minibufferBindings.toArray.map fun (text, command) => .ofKeys (keys text) command)

/-- What a step of the minibuffer checks is handed: the active keymaps the
registry of `package` makes for the test scheme from the loop's state, so
the minibuffer's mode holds in the minibuffer's view and nowhere else; the
registry's commands, each given its call; and, for any other name, the
commands of the prompt checks and of these. -/
def minibufferKeys (package : Package := Minibuffer.package) : Loop.Keys TestScheme.scheme :=
  { maps := (minibufferRegistry package).activeMaps TestScheme.scheme
    command? := fun name =>
      match (minibufferRegistry package).find? name with
      | some { registration := { action := .call run, .. }, .. } =>
        some fun call => do
          run call
          return none
      | _ => ((promptCommands ++ minibufferCommands).find? (·.1 == name)).map (·.2) }

/-- A driver of the minibuffer checks over the state `start` makes, with the
registry of `package` and the jobs of the driver checks; `none` if making
the state was refused. -/
def minibufferDriver (start : TextM EditorState := EditorState.initial ⟨640, 480⟩)
    (package : Package := Minibuffer.package) : Option TestDriver :=
  (Loop.Driver.over (minibufferKeys package) driverJobs start editorModel).toOption

/-- A press of each key the test scheme has `role` on. -/
def rolePresses (role : Role) : List Event :=
  (roleKeys role).map press

/-- The text of the minibuffer's buffer in `driver`'s state, while a prompt
is open. -/
def minibufferTextId (driver : TestDriver) : Option TextId := do
  let state := driver.loop.state
  return (← state.buffer? (← state.minibufferBuffer?)).text

/-- The candidates of the prompt open in `driver`'s loop, with their listing
and the choice. -/
def candidatesOf (driver : TestDriver) : Option Candidates :=
  driver.loop.state.prompt.map (·.candidates)

/-- The place a prompt of these checks is asked with: the editor's working
directory, `/` until a host sets it, for a buffer with no file, and no
home. -/
def rootPlace : Completion.Place :=
  { directory := some "/" }

/-- The status line of the view `id` in the last scene `driver`'s display
model holds. -/
def statusIn (driver : TestDriver) (id : ViewId) : Option (Array StatusField) := do
  ((← driver.model.display.scenes.back?).views.find? (·.id == id)).map (·.status)

/-- The candidate list's view in the last scene `driver`'s display model
holds, if it is there. -/
def listView (driver : TestDriver) : Option View := do
  let drawn ← driver.loop.state.candidateList
  (← driver.model.display.scenes.back?).views.find? (·.id == drawn.view)

/-- What the last scene `driver`'s display model holds shows of the open
prompt: the fields of the minibuffer's status line, then one field for
each row of the candidate list's view, if it is there: the row's text, read
from the view's snapshot, in the face of the decoration that starts the
row. -/
def pickShown (driver : TestDriver) : Option (Array StatusField) := do
  let status ← statusIn driver (← driver.loop.state.minibufferView?)
  let rows : Array StatusField :=
    match listView driver with
    | none => #[]
    | some view =>
      let text := (shownText driver.model view).getD ""
      if text.isEmpty then #[]
      else
        ((text.splitOn "\n").foldl
            (fun (fields, offset) row =>
              let face := ((view.decorations.find? (·.start == offset)).map (·.face)).getD ⟨""⟩
              (fields.push { text := row, face }, offset + row.utf8ByteSize + 1))
            ((#[] : Array StatusField), 0)).1
  return status ++ rows

end Editor.Test
