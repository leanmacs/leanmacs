import Editor.Command.Call
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Keymap
import Editor.Loop
import Editor.Program
import Editor.Scene
import Editor.Test.Keys
import Editor.Test.Loop

/-!
# Model tests: support: Switching

`switching`, an input scheme written for the core's checks: the test scheme,
with a report of each view that a key's invocation switches, so that a check
of what the loop does with a scheme's report (its cursor, its status, a
session it says is open, a view that takes no text) names no shipped
scheme's states or keys. `switchingKeys` is what a step of a loop over it is
handed. Shared by several test modules under `ModelTest/Editor/`; it holds
no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A report of the scheme `switching`, unlike the default in every field
the scene shows: a block in a face of its own, one status field, an
inclusive selection, and selecting. -/
def markedReport : InputScheme.Report :=
  { cursor := { shape := .block, face := ⟨"cursor.marked"⟩ }
    status := #[{ text := "marked", face := ⟨"mode-line.state.marked"⟩ }]
    shape := .inclusive
    selecting := true }

/-- What the scheme `switching` reports of a view it was told is the
minibuffer's: an underline in a face of its own, and one status field. -/
def askedReport : InputScheme.Report :=
  { cursor := { shape := .underline, face := ⟨"cursor.asked"⟩ }
    status := #[{ text := "asked", face := ⟨"mode-line.state.asked"⟩ }] }

/-- The reports the scheme `switching` switches a view between: a command's
name, the key string a loop over it binds to that command, and what the
scheme reports of a view once a key for the view has yielded an invocation
of the command. The keys print nothing. -/
def switchingTable : List (String × String × InputScheme.Report) :=
  [("mark", "C-m", markedReport), ("plain", "C-p", {}), ("begin", "C-b", { session := true }),
    ("end", "C-e", {}), ("deafen", "C-d", { takesText := false })]

/-- A scheme written for the core's checks, so that none of them names a
shipped scheme's states or keys: the test scheme, with a report of each
view that an invocation it yields switches (`switchingTable`). A view
is switched the same way when a menu item names a command of the table
(`invoked`), as a scheme whose key tables enter a state does for an item
of that command. A view
starts with the default report, a view told to be the minibuffer's has
`askedReport`, and a closed view's is forgotten. Its state is the test
scheme's, and the report of each view that has one. -/
def switching : InputScheme :=
  { State := TestScheme.State × List (ViewId × InputScheme.Report)
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      match yielded.bind fun invocation => switchingTable.find? (·.1 == invocation.command) with
      | some (_, _, report) => ((next, (view, report) :: state.2.filter (·.1 != view)), yielded)
      | none => ((next, state.2), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader
    localLeader := TestScheme.localLeader
    invoked := fun view state invocation =>
      match switchingTable.find? (·.1 == invocation.command) with
      | some (_, _, report) =>
        ((state.1, (view, report) :: state.2.filter (·.1 != view)), invocation)
      | none => (state, invocation)
    closeView := fun view state => (state.1, state.2.filter (·.1 != view))
    openMinibuffer := fun view state => (state.1, (view, askedReport) :: state.2)
    report := fun state view => ((state.2.find? (·.1 == view)).map (·.2)).getD {} }

/-- What a step of a loop over `switching` is handed: one keymap, the same
for every view, that binds each key of `switchingTable` to its command and
each key string of `bindings` to the invocation beside it; and commands,
one that does nothing under each name of `switchingTable`, and
`commands`. -/
def switchingKeys (bindings : List (String × Invocation) := [])
    (commands : List (String × (Call → EditorM (Option Config.Write))) := []) :
    Loop.Keys switching :=
  { maps := fun _ _ =>
      [Keymap.ofList
          ((switchingTable.map fun (name, text, _) => (keys text, invoke name)) ++
            bindings.map fun (text, invocation) => (keys text, invocation))]
    command? := fun name =>
      match commands.find? (·.1 == name) with
      | some (_, command) => some command
      | none => if switchingTable.any (·.1 == name) then some fun _ => pure none else none }

end ModelTest
