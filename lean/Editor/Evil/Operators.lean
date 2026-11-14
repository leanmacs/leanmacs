import Editor.Evil
import Editor.Evil.Motions
import Editor.Evil.Registers

/-!
# Evil's operators

Vim's operators as vocabulary entries (`Editor/Vocabulary.lean`,
"Operators"), the table the operate command looks names up in
(`operators`), and the command (`operate`), which composes an operator with
what it acts on (`docs/design/keymaps-and-modes.md`, "Operators as built").
The names are the ones the Vim scheme's default tables bind keys to
(`Editor/InputScheme/Vim/Default.lean`). Nothing here names a key.

## The operate command

`operate operators motions` is the command an operator's keys run: a
function of the two tables it looks names up in, as the move command is of
one (`Editor/Evil.lean`), so the caller supplies the vocabulary.

- **Its arguments are the layout the Vim scheme compiles an operator to**
  (`Editor/InputScheme/Vim.lean`, "Edits"): the operator's name, the kind
  of what it acts on, that thing's name, the count, 0 for none, and the
  register's name, empty for none.
- **It reads the selection once, when it is called**: the head the stretch
  is worked out from, and the selection every edit of the operator carries
  as the one before (`Operand.before`), so an undo hands back the cursor
  the user saw.
- **It works the stretch out and hands it to the operator** (`stretch`),
  then has the window keep no wanted column.
- **A call that cannot be made gives up** (`giveUp`, `Editor/Api.lean`),
  each with a sentence a function here makes: an operator no entry has
  (`noSuchOperator`), a motion no entry has (`noSuchMotion`), a text
  object, none being built (`noTextObject`), and arguments that are not
  the layout (`noOperatorNamed`). It gives up and does not only say so:
  the key that ran it may have entered a state and has been made the last
  change, and a command that gives up is rolled back with the scheme put
  back at rest.

## What an operator takes

`stretch` works out what an operator acts on from the head and from where
the motion leads under an operator (`Motion.taken`), by Vim's rules, in
order:

- **Cells from the lower of the two to the higher.**
- **The stretch stops no later than where the last line's content ends**
  (`lastLine`): a text that ends in a line feed has an empty last row,
  which is no line, and Vim cannot address the line feed before it.
- **Otherwise the stretch is those cells, with the motion's reach.**

## What an operator does

| | Cells that are not empty | No cell |
|---|---|---|
| `delete` | The register is the cells' text. They are deleted. The cursor goes to their start, rested | Nothing is done, and the register is as it was |

- **An edit carries the selection from before the command and the cursor
  it leaves**, before that cursor is rested, in the shape of the call's
  report (`Target.replaceCarrying`).
- **The register is set last** (`store`, `Editor/Evil/Registers.lean`).

Pinned by `ModelTest.evilOperatorChecks`, by key, under the Vim scheme
that ships.
-/

namespace Editor.Evil

/-- What the operate command gives up with for a name the vocabulary has no
operator of. -/
def noSuchOperator (name : String) : String :=
  s!"{name}: no such operator"

/-- What the operate command gives up with when it is asked to act on a
text object: none is built. -/
def noTextObject : String :=
  "no text object is built"

/-- What the operate command gives up with when its arguments are not the
layout an operator is compiled to: the call is malformed, so it says what
the command expects. -/
def noOperatorNamed : String :=
  "no operator named (expects an operator's name, the kind of what it acts on, that thing's name, a count and a register's name)"

/-- What an operator acts on in `text` when its head is at `head` and the
motion it waits for leads to `taken` ("What an operator takes", in the
module docs). -/
def stretch (text : TextId) (head : Nat) (taken : Vocabulary.Taken) : TextM Vocabulary.Stretch := do
  let limit ← text.motion .lineEnd (← text.offsetOf ⟨← lastLine text, 0⟩)
  let stop := min (max head taken.head) limit
  let start := min (min head taken.head) stop
  return .cells ⟨start, stop⟩ taken.reach

/-- Leaves the selection of the call's window as one range of the shape the
call's report says, with both ends where a head at `offset` rests under the
report's rule. -/
def settle (call : Call) (offset : Nat) : TextM Unit := do
  let head ← rested (restOf call.report) call.target.buffer.text offset
  call.target.select { ranges := #[⟨head, head⟩], shape := call.report.shape }

/-- The operator that deletes what it is handed into the register ("What an
operator does", in the module docs). -/
def delete : Vocabulary.Operator :=
  { name := "delete"
    act := fun call operand => do
      match operand.stretch with
      | .cells extent _ =>
        unless extent.start == extent.stop do
          let taken ← call.target.buffer.text.slice extent.start extent.stop
          call.target.replaceCarrying extent "" operand.before
              { ranges := #[⟨extent.start, extent.start⟩], shape := call.report.shape }
          settle call extent.start
          store operand.register { text := taken }
      | .lines .. =>
        pure () }

/-- The table the operate command looks an operator's name up in: one entry
for each name the Vim scheme's default tables bind a key to. -/
def operators : Array Vocabulary.Operator :=
  #[delete]

/-- The operate command over the vocabulary `operators` and `motions`, as it
is called ("The operate command", in the module docs): its arguments name
the operator, the kind of what it acts on, that thing, the count, 0 for
none, and the register. The operator is handed the stretch its target
amounts to from the head of the primary range of the target's selection,
and the window then keeps no wanted column. A call that cannot be made
gives up. -/
def operate (operators : Array Vocabulary.Operator) (motions : Array Vocabulary.Motion)
    (call : Call) : EditorM Unit := do
  let [.str operator, .str kind, .str name, .nat count, .str register] :=
    call.arguments | giveUp noOperatorNamed
  let some operator := operators.find? (·.name == operator) | giveUp (noSuchOperator operator)
  let text := call.target.buffer.text
  let before ← call.target.selection
  let some range := before.ranges[before.primary]? | throw .badSelection
  let head := range.head
  let operand : Vocabulary.Operand ←
    match kind with
    | "motion" =>
      let some motion := motions.find? (·.name == name) | giveUp (noSuchMotion name)
      let taken ←
        motion.taken operator.replaces text
            { head, count := if count == 0 then none else some count }
      pure
          { stretch := ← stretch text head taken, head, rest := min head taken.head, register,
            before }
    | "text-object" =>
      giveUp noTextObject
    | _ =>
      giveUp noOperatorNamed
  discard <| call.target.window.id.setWanted none
  operator.act call operand

end Editor.Evil
