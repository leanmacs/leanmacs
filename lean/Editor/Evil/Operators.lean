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

- **A motion that failed gives the operator up** (`cannotMove`), as Vim
  cancels it: nothing is taken, the register is as it was, and a change
  begins no insert. The operate command sees to it before it asks for a
  stretch.
- **Cells from the lower of the two to the higher.** A motion whose reach
  is `inclusive` takes the cell at the higher end too, unless that end is
  where its line's content ends: a line break, or the text's end.
- **The stretch stops no later than where the last line's content ends**
  (`lastLine`): a text that ends in a line feed has an empty last row,
  which is no line, and Vim cannot address the line feed before it.
- **An exclusive stretch that stops at a line's start, and so starts on an
  earlier line**: when it starts at or before its own line's first
  non-blank, it is the whole lines from its first to the line before its
  stop. Otherwise it stops where the line before ends. These are Vim's two
  exceptions for an exclusive motion whose end is in column 1.
- **Vi's rule, for an operator that says so** (`linesOverBlanks`, which
  `delete` alone does): cells that start at or before their line's first
  non-blank, stop on a later line, and have only blanks between their stop
  and that line's end are that many whole lines. So `d2$` from a line's
  indent takes two lines where `y2$` takes cells.
- **Otherwise the stretch is those cells, with the motion's reach.**

## What an operator does

| | Cells that are not empty | No cell | Lines |
|---|---|---|---|
| `delete` | The register is the cells' text. They are deleted. The cursor goes to their start, rested | Nothing is done, and the register is as it was | The register is the lines, line-wise. They are deleted. The cursor goes to the first non-blank of the line now where the first was |
| `yank` | The register is the cells' text. The cursor goes to their start, rested | The register is the empty text. The cursor stays | The register is the lines, line-wise. The cursor goes to the operand's `rest`, rested |
| `change` | The register is the cells' text. They are deleted. The selection is a bar at their start | Nothing is deleted. The register is as it was, unless the reach is `inclusive` and the text is not empty, when it is the empty text. The selection is a bar where the cells would start | The register is the lines, line-wise. The text from the first line's start to where the last line's content ends is deleted, so one line break stays. The selection is a bar at that line's start |

- **A line-wise register's text** is the lines from the first line's start
  through the last line's line break (`linesOf`), and the buffer's line
  ending (`Buffer.lineEnding`) is added when the last line has none.
- **A line-wise deletion leaves the text ending the way it ended.** The
  lines go from the first line's start through the last line's line break.
  When the last of them is the text's last line and has no line break, the
  line break before the first goes instead (`Lines.cut`), so deleting the
  last line of `a⏎b` leaves `a`, and of `a⏎b⏎` leaves `a⏎`. The cursor
  then goes to the first non-blank of the line before, there being none
  after.

- **The no-cell column is Vim's**, quirks included: `yh` at a line's start
  empties the register, `dh` and `ch` there leave it, and `c$` on an empty
  line empties it, which is the `inclusive` case.
- **`change` begins an insert only when a key that enters insert state
  runs it.** It leaves one range of the shape its call's report says, at
  the start of what it took, put where the report's state lets a cursor
  rest (`settle`): under insert state's report that is a bar there. Run by
  its name in normal state it is told normal state's report: it deletes,
  and the cursor rests there. The deletion and the text typed after it are
  one step of the history, which is the loop's rule for an insert session
  (`Editor/Loop.lean`, "Insert sessions"); nothing here sets a boundary.
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

/-- What the operate command gives up with when the motion called `name`
could not be made. -/
def cannotMove (name : String) : String :=
  s!"{name} cannot move"

/-- The row of `text` the position `offset` is in. Rows are asked in cells,
so a carriage return and line feed is one line break. -/
def rowOf (text : TextId) (offset : Nat) : TextM Nat :=
  return (← text.pointOf offset .cells).row

/-- Whether `text` holds only blanks, a blank being a space or a tab, which
are the two characters Vim's rule for a deletion over lines names. -/
def blanksOnly (text : String) : Bool :=
  text.all fun char => char == ' ' || char == '\t'

/-- What `operator` acts on in `text` when its head is at `head` and the
motion it waits for leads to `taken` ("What an operator takes", in the
module docs). -/
def stretch (operator : Vocabulary.Operator) (text : TextId) (head : Nat)
    (taken : Vocabulary.Taken) : TextM Vocabulary.Stretch := do
  let high := max head taken.head
  -- Through the cell at the higher end, where there is one on its line.
  let through ←
    if taken.reach == .inclusive && high < (← text.motion .lineEnd high) then
      text.motion .nextCell high
    else
      pure high
  let limit ← text.motion .lineEnd (← text.offsetOf ⟨← lastLine text, 0⟩)
  let stop := min through limit
  let start := min (min head taken.head) stop
  -- An exclusive stretch that stops at a line's start began on an earlier
  -- line: from that line's indent it is whole lines, and otherwise it stops
  -- where the line before ends.
  if taken.reach == .exclusive && start < stop && (← text.motion .lineStart stop) == stop then
    if start ≤ (← text.motion .lineFirstNonBlank start) then
      return .lines (← rowOf text start) ((← rowOf text stop) - 1)
    return .cells ⟨start, ← text.motion .previousCell stop⟩ taken.reach
  -- Vi's rule: cells from a line's indent to the blanks that end a later
  -- line are whole lines, for an operator that says so.
  if operator.linesOverBlanks then
    let first ← rowOf text start
    let last ← rowOf text stop
    if
        first < last && start ≤ (← text.motion .lineFirstNonBlank start) &&
          blanksOnly (← text.slice stop (← text.motion .lineEnd stop)) then
      return .lines first last
  return .cells ⟨start, stop⟩ taken.reach

/-- One range of the shape the call's report says, with both ends at
`offset`: the cursor an operator's edit carries as the one it leaves. -/
def cursorAt (call : Call) (offset : Nat) : Selection :=
  { ranges := #[⟨offset, offset⟩], shape := call.report.shape }

/-- Leaves the selection of the call's window as one range of the shape the
call's report says, with both ends where a head at `offset` rests under the
report's rule. -/
def settle (call : Call) (offset : Nat) : TextM Unit := do
  call.target.select (cursorAt call (← rested (restOf call.report) call.target.buffer.text offset))

/-- Whole lines of a text, as offsets. -/
structure Lines where
  /-- Where the first line starts. -/
  start : Nat
  /-- Where the last line's content ends. -/
  content : Nat
  /-- Where the line after the last starts, past the last line's line break,
  or the text's end. -/
  stop : Nat
  /-- Where a deletion of the lines starts, so that the text ends the way it
  ended: `start`, or, when the last of them has no line break and a line
  is before the first, where that line's content ends, so its line break
  goes instead. -/
  cut : Nat
  /-- Whether the lines run to the text's end: no line follows them. -/
  final : Bool
  /-- The lines' text as a line-wise register holds it: from `start` up to
  `stop`, and then the buffer's line ending when the last line has no line
  break. -/
  taken : String

/-- The lines of `target`'s text from the row `first` through the row
`last`. -/
def linesOf (target : Target) (first last : Nat) : TextM Lines := do
  let text := target.buffer.text
  let length ← text.byteLength
  let start ← text.offsetOf ⟨first, 0⟩
  let content ← text.motion .lineEnd (← text.offsetOf ⟨last, 0⟩)
  let stop ←
    if last + 1 < (← text.rowCount) then
      text.offsetOf ⟨last + 1, 0⟩
    else
      pure length
  let bare := stop == content
  let cut ←
    if bare && first > 0 then
      text.motion .lineEnd (← text.offsetOf ⟨first - 1, 0⟩)
    else
      pure start
  return {
      start, content, stop, cut, final := stop == length
      taken := (← text.slice start stop) ++ if bare then target.buffer.lineEnding.text else "" }

/-- The operator that deletes what it is handed into the register ("What an
operator does", in the module docs). -/
def delete : Vocabulary.Operator :=
  { name := "delete"
    linesOverBlanks := true
    act := fun call operand => do
      match operand.stretch with
      | .cells extent _ =>
        unless extent.start == extent.stop do
          let taken ← call.target.buffer.text.slice extent.start extent.stop
          call.target.replaceCarrying extent "" operand.before (cursorAt call extent.start)
          settle call extent.start
          store operand.register { text := taken }
      | .lines first last =>
        let text := call.target.buffer.text
        let lines ← linesOf call.target first last
        -- The first non-blank of the line that follows, in the text the
        -- deletion leaves; of the line before when none follows; and 0 when
        -- there is neither.
        let after ←
          if !lines.final then
            pure ((← text.motion .lineFirstNonBlank lines.stop) - (lines.stop - lines.cut))
          else if first > 0 then
            text.motion .lineFirstNonBlank (← text.offsetOf ⟨first - 1, 0⟩)
          else
            pure 0
        call.target.replaceCarrying ⟨lines.cut, lines.stop⟩ "" operand.before (cursorAt call after)
        settle call after
        store operand.register { text := lines.taken, linewise := true } }

/-- The operator that puts an insert in place of what it is handed, which
goes into the register ("What an operator does", in the module docs). It
leaves the selection as its call's report says a view's is, at the start of
what it took: a bar there when a key that enters insert state ran it, and
the cursor resting there otherwise. -/
def change : Vocabulary.Operator :=
  { name := "change"
    replaces := true
    act := fun call operand => do
      match operand.stretch with
      | .cells extent reach =>
        if extent.start == extent.stop then
          settle call extent.start
          if reach == .inclusive && (← call.target.buffer.text.byteLength) > 0 then
            store operand.register { text := "" }
        else
          let taken ← call.target.buffer.text.slice extent.start extent.stop
          call.target.replaceCarrying extent "" operand.before (cursorAt call extent.start)
          settle call extent.start
          store operand.register { text := taken }
      | .lines first last =>
        let lines ← linesOf call.target first last
        -- One line break stays: the lines' content goes, and not the last
        -- line's line break.
        unless lines.start == lines.content do
          call.target.replaceCarrying ⟨lines.start, lines.content⟩ "" operand.before
              (cursorAt call lines.start)
        settle call lines.start
        store operand.register { text := lines.taken, linewise := true } }

/-- The operator that copies what it is handed into the register and
changes no text ("What an operator does", in the module docs). -/
def yank : Vocabulary.Operator :=
  { name := "yank"
    act := fun call operand => do
      match operand.stretch with
      | .cells extent _ =>
        let taken ← call.target.buffer.text.slice extent.start extent.stop
        unless extent.start == extent.stop do
          settle call extent.start
        store operand.register { text := taken }
      | .lines first last =>
        let lines ← linesOf call.target first last
        settle call operand.rest
        store operand.register { text := lines.taken, linewise := true } }

/-- The table the operate command looks an operator's name up in: one entry
for each name the Vim scheme's default tables bind a key to. -/
def operators : Array Vocabulary.Operator :=
  #[delete, change, yank]

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
      if taken.failed then
        giveUp (cannotMove name)
      pure
          { stretch := ← stretch operator text head taken, head, rest := min head taken.head,
            register, before }
    | "text-object" =>
      giveUp noTextObject
    | _ =>
      giveUp noOperatorNamed
  discard <| call.target.window.id.setWanted none
  operator.act call operand

end Editor.Evil
