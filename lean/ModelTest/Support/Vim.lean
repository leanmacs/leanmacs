import Editor.Event
import Editor.InputScheme
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Keymap
import Editor.Role
import Editor.Scene
import Editor.Test.Keys
import Editor.Text

/-!
# Model tests: support: Vim

The Vim scheme as a check builds it: its keymaps and states, input parsed by it,
and the scheme that ships. Shared by several test modules under
`ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The delete operator of the Vim checks: it changes text and names no
state. -/
def vimDelete : Vim.Operator :=
  { name := "delete" }

/-- The change operator of the Vim checks: it changes text and enters the
state `insert`. -/
def vimChange : Vim.Operator :=
  { name := "change", enters := some "insert" }

/-- The yank operator of the Vim checks: it changes no text. -/
def vimYank : Vim.Operator :=
  { name := "yank", changes := false }

/-- A command of the Vim checks that changes text and enters the state
`insert`. -/
def vimInsert : Vim.Command :=
  { name := "insert", changes := true, enters := some "insert" }

/-- The keymap that binds each key string of `table` to what is beside it.
A string that names no keys binds nothing. -/
def vimKeymap (table : List (String × Vim.Bound)) : Keymap Vim.Bound :=
  Keymap.ofList (table.map fun (text, bound) => (keys text, bound))

/-- What the Vim checks' normal state binds: three operators, the motion
`word` on `w`, a motion on two keys and one on `0`, a text object, and
commands: one that enters `insert` and changes text, one that enters
`visual`, one that does neither, and one that changes text and enters no
state; and the register prefix on `"`. The names are the checks' own, and
are no default's. -/
def vimNormalTable : List (String × Vim.Bound) :=
  [("d", .operator vimDelete), ("c", .operator vimChange), ("y", .operator vimYank),
    ("w", .motion "word"), ("g g", .motion "first-line"), ("0", .motion "line-start"),
    ("t", .textObject "thing"), ("i", .command vimInsert),
    ("v", .command { name := "visual", enters := some "visual" }),
    ("u", .command { name := "undo" }), ("x", .command { name := "delete-char", changes := true }),
    ("\"", .register)]

/-- What the Vim checks' insert and visual states bind first: a command
that enters `normal`. -/
def vimEscapeTable : List (String × Vim.Bound) :=
  [("<Escape>", .command { name := "normal", enters := some "normal" })]

/-- The registry of Vim states the grammar's checks run on, written here so
that no check of the grammar names a default binding: `normal`, the initial
state; `insert`, where typing is text and the selection is exclusive, which
is also the state the registry names for the minibuffer's view; and
`visual`, where an operator acts on the selection and normal's keys are
bound too. -/
def vimStates : Vim.States :=
  { initial := { name := "normal", keymaps := [vimKeymap vimNormalTable] }
    others :=
      [{  name := "insert"
          keymaps := [vimKeymap vimEscapeTable]
          cursor := .bar
          insertsText := true
          shape := .exclusive },
        { name := "visual"
          keymaps := [vimKeymap vimEscapeTable, vimKeymap vimNormalTable]
          operatesOnSelection := true }]
    minibuffer := some "insert" }

/-- No active keymaps, for every view: a key is looked up in the keymaps of
the view's Vim state alone. -/
def vimNoMaps (_ : ViewId) : List (Keymap Vim.Bound) :=
  []

/-- `Vim.parse` over `states` folded from `state` through the keys the key
string `text` names: the state it is left in, and what each key parsed
to. -/
def vimParsedFrom (state : Vim.State) (text : String)
    (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps) (view : ViewId := ⟨0⟩)
    (states : Vim.States := vimStates) : Vim.State × List Vim.Parsed :=
  (keys text).foldl
    (fun (state, parsed) key =>
      let (next, result) := Vim.parse states maps view state key
      (next, parsed ++ [result]))
    (state, [])

/-- `vimParsedFrom` the scheme's initial state. -/
def vimParsed (text : String) (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps)
    (view : ViewId := ⟨0⟩) (states : Vim.States := vimStates) : Vim.State × List Vim.Parsed :=
  vimParsedFrom (Vim.scheme states).init text maps view states

/-- The inputs the Vim checks give the scheme contract as complete, as key
strings. -/
def vimSequences : List String :=
  ["g g", "w", "d w", "d d", "d 2 w", "2 d 3 w", "\" + y w"]

/-- The role table, leader and localleader the Vim checks give the scheme,
written here so that no check names a default: each registered role on a
key of its own, the leader on `SPC`, and the localleader on the leader and
then `m`. -/
def vimModeKeys : Vim.ModeKeys :=
  { roles :=
      Role.registered.zip
        ([["n"], ["N"], ["RET"], ["Q"], ["z", "r"], ["TAB"], ["M"]].map fun strokes =>
          keys (" ".intercalate strokes))
    leader := keys "SPC"
    localLeader := [.leader, .key (charKey "m")] }

/-- The default Vim scheme's grammar folded from its initial state through
the keys the key string `text` names, keys for view 0 with no active
keymaps: the state it is left in, and what each key parsed to. -/
def vimDefault (text : String) : Vim.State × List Vim.Parsed :=
  vimParsed text (states := Vim.Default.states)

/-- The edit the last key of `text` completed under the default Vim
scheme, if it completed one. -/
def vimDefaultEdit (text : String) : Option Vim.Edit :=
  match (vimDefault text).2.getLast? with
  | some (.edit edit) => some edit
  | _ => none

/-- The command the last key of `text` runs under the default Vim scheme,
with no count and no register, if it runs one. -/
def vimDefaultCommand (text : String) : Option Vim.Command :=
  match vimDefaultEdit text with
  | some (.run command none none) => some command
  | _ => none

/-- What the default Vim scheme reports of view 0 after the keys `text`
names. -/
def vimDefaultReport (text : String) : InputScheme.Report :=
  Vim.Default.scheme.report (vimDefault text).1 ⟨0⟩

end ModelTest
