import Editor.Config.Registry
import Editor.Event
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Language
import Editor.Loop
import Editor.Loop.Driver
import Editor.Scene
import Editor.State
import Editor.Text
import ModelTest.Support.Evil
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models

/-!
# Model tests: support: OperatorRows

Rows of the operator tables (`OperatorRow`) and how they are run by key. Shared
by several test modules under `ModelTest/Editor/`; it holds no checks of its
own.
-/

namespace ModelTest

open Editor

/-- One row of an oracle table of the operators: keys, the text and the
cursor they are pressed from, and what Vim leaves. -/
structure OperatorRow where
  /-- The text before, with the cursor as a bar. -/
  before : String
  /-- The key string. -/
  keys : String
  /-- The text after, with a bar at the cursor: the cell the cursor is on in
  normal state, and where the insert begins in insert state. -/
  after : String
  /-- The unnamed register after; `none` when it is as it was. -/
  register : Option Register
  /-- Whether the view is left in insert state. -/
  insert : Bool := false
  /-- Whether the command gave up or broke off: something is said in the
  echo area, which is no refusal. -/
  gaveUp : Bool := false
  /-- What the echo area says when the command did not give up: nothing,
  unless a motion said something, as a search says its warning. -/
  echo : String := ""
  /-- The text objects source of the test mode of the model's JSON grammar
  the row's buffer is set to (`treeRegistered`), so the syntax tree's text
  objects are there; none for a buffer with no syntax tree. -/
  tree : Option String := none
  /-- Whether the row's buffer is in the indent checks' JSON language
  (`indentDriver`), so its text has indent levels. -/
  indented : Bool := false

namespace OperatorRow

/-- A row whose keys leave the view in normal state. -/
def rests (before keys after : String) (register : Option Register) : OperatorRow :=
  { before, keys, after, register }

/-- A row whose keys leave the view in insert state, the bar at `after`'s. -/
def inserts (before keys after : String) (register : Option Register) : OperatorRow :=
  { before, keys, after, register, insert := true }

/-- A row whose keys' command gives up: the text, the cursor and the
register are as they were, and the view is in normal state. -/
def givesUp (before keys : String) : OperatorRow :=
  { before, keys, after := before, register := none, gaveUp := true }

/-- A row whose keys re-indent, in the indent checks' JSON language
(`indentDriver`): the view is in normal state and the register as it
was. -/
def indents (before keys after : String) : OperatorRow :=
  { before, keys, after, register := none, indented := true }

/-- A row whose keys' command breaks off: the cursor is at `after`'s bar,
the text and the register are as they were, the view is in normal state,
and the echo area says something that is no refusal. -/
def breaksOff (before keys after : String) : OperatorRow :=
  { before, keys, after, register := none, gaveUp := true }

/-- What is wrong with the row, if anything: what its keys left when that
is not what the row says, and a key string that names no keys. -/
def wrong (row : OperatorRow) : Option String :=
  if (ModelTest.keys row.keys).isEmpty then some s!"{repr row.keys} names no keys"
  else
    let edited :=
      match row.tree with
      | some textObjects =>
        (treeRegistered row.before textObjects).map fun driver => evilLeft (evilFed driver row.keys)
      | none =>
        if row.indented then indentEdited row.before row.keys else evilEdited row.before row.keys
    match edited with
    | none => some s!"no driver for {repr row.before}"
    | some left =>
      let saidSo := !left.echo.isEmpty && (left.echo.splitOn "refused").length == 1
      if
          left.shown == row.after && left.register == row.register && left.insert == row.insert &&
            (if row.gaveUp then saidSo else left.echo == row.echo) then
        none
      else some s!"{row.keys} from {repr row.before} left {repr left}"

end OperatorRow

/-- Whether each row of `rows` holds (`OperatorRow.wrong`). A failure names
each row that does not hold, with what its keys left. -/
def operatorRows (rows : List OperatorRow) : IO Bool := do
  let wrong := rows.filterMap (·.wrong)
  unless wrong.isEmpty do
    throw (IO.userError ("; ".intercalate wrong))
  return true

/-- What is wrong, if anything, with the keys `typed`, which end with the
operator `operator` acting, pressed from the byte offset `position` of a
text holding `contents` (the rules `operatorSweep` lists): a refusal said, a
cursor where normal state lets none rest after an operator that enters no
state, a text an operator that changes none changed, and a change `u` does
not give back with the cursor where it was. -/
def sweptWrong (contents : String) (position : Nat) (operator : Vim.Operator) (typed : String) :
    Option String :=
  let what := s!"{typed} at {position} of {repr contents}"
  match
    (Loop.Driver.over evilHanded (fun _ => none) (evilState contents position)
        editorModel).toOption with
  | none => some s!"{what}: no driver"
  | some driver =>
    let after := evilFed driver typed
    let text := evilText after
    let head :=
      (evilSelection after).bind fun selection => selection.ranges[selection.primary]?.map (·.head)
    let refused := (after.loop.state.echo.splitOn "refused").length != 1
    let rests :=
      operator.enters.isSome ||
        match text, head with
        | some text, some head => restsWell text head
        | _, _ => false
    let kept := operator.changes || text == some contents
    let ended := if operator.enters.isSome then evilFed after "<Escape>" else after
    let undone :=
      text == some contents || evilShown (evilFed ended "u") == withBar contents position
    if !refused && rests && kept && undone then none
    else
      some
        s!"{what}: left {repr (evilShown after)}, echo {repr after.loop.state.echo}, undone to {repr (evilShown (evilFed ended "u"))}"

end ModelTest
