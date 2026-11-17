import Editor.Evil
import Editor.Evil.Motions
import Editor.Evil.Objects
import Editor.Evil.Registers
import Editor.Indent

/-!
# Evil's operators

Vim's operators as vocabulary entries (`Editor/Vocabulary.lean`,
"Operators"), the table the operate command looks names up in
(`operators`), and the command (`operate`), which composes an operator with
what it acts on (`docs/design/keymaps-and-modes.md`, "Operators as built").
The names are the ones the Vim scheme's default tables bind keys to
(`Editor/InputScheme/Vim/Default.lean`). Nothing here names a key.

## The operate command

`operate operators motions objects` is the command an operator's keys run:
a function of the three tables it looks names up in, as the move command is
of one (`Editor/Evil.lean`), so the caller supplies the vocabulary.

- **Its arguments are the layout the Vim scheme compiles an operator to**
  (`Editor/InputScheme/Vim.lean`, "Edits"): the operator's name, the kind
  of what it acts on, that thing's name, the count, 0 for none, and the
  register's name, empty for none. A motion's argument, when it has one, is
  a string right after the motion's name, so the register stays last.
- **It keeps and says what the motion hands back** (`Vocabulary.Taken`):
  the find it made as the last find (`setLastFind`), and its `said` in the
  echo area once the operator has acted. A motion that failed gives the
  command up, or breaks it off, with its `said` in place of `cannotMove`.
  A give-up rolls the find back: `dfz` where the line has no `z` leaves the
  last find as it was, where Vim keeps `z`, a recorded departure.
- **It reads the selection once, when it is called**: the head the stretch
  is worked out from, and the selection every edit of the operator carries
  as the one before (`Operand.before`), so an undo hands back the cursor
  the user saw.
- **It works the stretch out and hands it to the operator**: for the kind
  `motion`, from where the motion leads (`stretch`); for the kind `lines`,
  which is the doubled key, the head's line and `count - 1` lines below,
  stopped at the last line ("The doubled operator on the last line"); for
  the kind `text-object`, from what the object covers ("A text object
  under an operator"); for the kind `selection`, which an operator's key in a visual state
  compiles to, what the selection covers. A selection of the line shape
  is the lines of its two ends. Any other is
  what the text port says its primary range covers by its shape
  (`TextId.extents`), stopped where the last line's content ends; the two
  rules below for a stretch that stops at a line's start and for a
  deletion over lines are a motion's and are not applied, as Vim applies
  neither in Visual mode. A count is ignored. The window then keeps no
  wanted column.
- **The operator's key left the visual state**, so the command is told
  normal state's report, or insert state's for a change, and what it
  leaves is one cursor of that shape.
- **A call that cannot be made gives up** (`giveUp`, `Editor/Api.lean`),
  each with a sentence a function makes: an operator no entry has
  (`noSuchOperator`), a motion no entry has (`noSuchMotion`), a text
  object no entry has (`noSuchObject`, `Editor/Evil/Objects.lean`), a text
  object that is not there (`noObjectHere`), and arguments that are not
  the layout (`noOperatorNamed`). It gives up and does not only say so:
  the key that ran it may have entered a state and has been made the last
  change, and a command that gives up is rolled back with the scheme put
  back at rest.

## A text object under an operator

The kind `text-object` names an entry of `objects`, which is asked from the
head with the count (`Vocabulary.Within`, with no anchor) and answers what
it covers (`Vocabulary.Span`).

- **An object that is not there gives up** (`noObjectHere`), as a motion
  that did not move does: nothing is taken, the register is as it was, a
  change begins no insert, and the edit is not the last change. Vim fails
  the object and beeps.
- **What the operator takes is worked out as for a motion** (`stretch`),
  from the span's start, as the head, to its stop, with its reach as the
  motion's: so an exclusive object that stops at a line's start takes
  whole lines from an indent (`di{` over lines), and Vi's rule makes `daw`
  of a last word on its own line whole lines, as Vim's `op_delete` does.
  The operand's `rest` is the span's start.
- **An object that covers no cell first moves the cursor to its start**,
  rested, as Vim's `do_pending_operator` does: `d i (` on `f|()` leaves
  `f(|)`, and `y i (` there empties the register with the cursor on `)`.

## The doubled operator on the last line

A doubled operator with a count above 1 on the last line (`lastLine`)
gives up (`noLineBelow`): `2dd`, `2cc` and `2yy` there, `d2d`, and `dd`
replayed there with a count. Nothing is taken, the register is as it was,
a change begins no insert, and the edit is not the last change.

- **It is Vim's rule.** Vim's doubled operator first goes down `count - 1`
  lines, and going down fails on the last line, which cancels the
  operator, where from a line above a count past the text stops at the
  last line and does not fail. That is the rule of `down` under an
  operator with a count one less (`Editor/Evil/Motions.lean`), and `d2$`
  gives up there for the same reason.
- **It holds in a text of one line and in the empty text**, whose one
  line is the last: `2yy` in the empty text gives up, where `yy` yanks a
  line break.
- **A count of 1 never fails**: `dd`, `1dd` and `1d1d` take the last
  line.

## What an operator takes

`stretch` works out what an operator acts on from the head and from where
the motion leads under an operator (`Motion.taken`), by Vim's rules, in
order:

- **A motion that failed cancels the operator** (`cannotMove`), as Vim
  cancels it: nothing is taken, the register is as it was, a change begins
  no insert, and the edit is not the last change. The operate command sees
  to it before it asks for a stretch.
  - **Where the motion did not move**, the command gives up (`giveUp`):
    `dj` on the last line, `d2$` there, `db` at the text's start.
  - **Where the motion moved before it failed**, the cursor goes where it
    got to and the command breaks off (`breakOff`, `Editor/Api.lean`),
    which keeps the cursor and puts the scheme back at rest as a give-up
    does: `d3b` that comes to rest on an empty first line with a step left
    over leaves the cursor on that line, as Vim does. The cursor is one
    range of the shape the selection had before the command, rested as a
    view that extends no selection rests one, since that is the state the
    scheme goes back to; the window then keeps no wanted column. Whether
    the motion moved is asked of the rested position, so a raw target
    that rests where the cursor was has not moved it.
  - Of the motions that ship only `word-backward` and `bigword-backward`
    fail after moving. A replayed change breaks its replay off the same
    way (`Editor/Evil/Repeat.lean`).
- **A motion whose reach is `lines`** takes the lines of the head and of
  its target, and those between.
- **Otherwise cells from the lower of the two to the higher.** A motion
  whose reach
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
| `replace` | The text of the register the call names (`fetch`) goes in place of the cells, as it is, line breaks included. The cursor goes on the last cell put, or on the first when the text holds a line break, as a character-wise `P` leaves it. The unnamed register is the cells' text | The text is put where the cells would start, as for cells | The text goes in place of the lines, with the buffer's line ending added to a character-wise one; below a last line with no line break its last line break is left out, so the text ends the way it ended. The cursor goes to the first non-blank of the first line put. The unnamed register is the lines, line-wise |
| `indent` | The rows from the first cell's through the last cell's | The row the cells would start on | The lines |

- **`indent` is Vim's `=`.** Whatever it is handed, it acts on whole rows,
  as Vim's `=` does: each row's leading whitespace becomes its level times
  the buffer's indent unit (`Target.indentUnit`), and a blank row's
  becomes nothing; a row inside a multi-line string or block comment keeps
  its own (`TextId.reindentEdits`, `Editor/Indent.lean`). All the rows'
  edits are one edit that carries the selection from before the command
  (`Target.replaceEachCarrying`), so one `u` gives back the text and the
  cursor; with no edit the text is not touched. The cursor goes to the
  first non-blank of the first row, rested, as Vim's `op_reindent` leaves
  it. No register is read or written: a register named before `=` is
  taken and ignored. With no levels to read, a buffer with no syntax tree,
  a tree that keeps no indents query, or a text whose last edit's tree is
  not delivered yet, it gives up (`cannotIndent`), having changed nothing,
  so it is not the last change. `.` replays it over the rows from the
  cursor, as for any operator; over a visual selection it is not repeated.
  Vim's own `=` reads `indentexpr` or `cindent`, so its levels are its own;
  ours are the indents query's, a recorded departure.
- **`replace` is the visual Paste** (`Editor/Evil/Clipboard.lean`), which
  no default key binds. It fetches the register first, before any edit,
  so with nothing to put (`nothingToPut`, `clipboardUnavailable`) it gives
  up having changed nothing. It sets the unnamed register directly and
  never through `store`, so the text it replaces never reaches the
  clipboard: its one request of the clipboard is that first read. As in
  Vim, the register it put from is otherwise as it was. A line-wise text
  put in place of a character-wise selection goes in as it is, where Vim
  would split the line.

- **In the empty text `delete` and `change` do nothing to the text or the
  register**, and `change` still leaves its bar; `yank` follows the table,
  so `yy` there yanks one line break, line-wise.
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
that ships, and `indent` by `ModelTest.evilIndentChecks` and, over the
library's Rust grammar, `ConfigTest.indentChecks`.
-/

namespace Editor.Evil

/-- What the operate command gives up with for a name the vocabulary has no
operator of. -/
def noSuchOperator (name : String) : String :=
  s!"{name}: no such operator"

/-- What the operate command gives up with when its arguments are not the
layout an operator is compiled to: the call is malformed, so it says what
the command expects. -/
def noOperatorNamed : String :=
  "no operator named (expects an operator's name, the kind of what it acts on, that thing's name, a count and a register's name)"

/-- What the operate command gives up with when a doubled operator with a
count above 1 is on the last line, where no line is below to count. -/
def noLineBelow : String :=
  "no line below"

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
  if taken.reach == .lines then
    return .lines (← rowOf text (min head taken.head)) (← rowOf text high)
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
        -- The empty text has no line to delete.
        if (← text.byteLength) == 0 then
          return
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
        -- The empty text has no line to change: the insert begins, and the
        -- register is as it was.
        if (← call.target.buffer.text.byteLength) == 0 then
          settle call 0
          return
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

/-- The operator that puts the register its call names in place of what it
is handed, a visual Paste ("What an operator does", in the module docs).
The register is fetched first (`fetch`), before any edit, so with nothing to
put it gives up having changed nothing. The text it replaces goes to the
unnamed register alone, never through `store`, so a Paste in place of a
selection never writes the clipboard: its one request of the clipboard is
the read, made first. -/
def replace : Vocabulary.Operator :=
  { name := "replace"
    act := fun call operand => do
      let put ← fetch operand.register
      let text := call.target.buffer.text
      match operand.stretch with
      | .cells extent _ =>
        let taken ← text.slice extent.start extent.stop
        let start := extent.start
        let stop := start + put.text.utf8ByteSize
        if put.text.any (· == '\n') then
          call.target.replaceCarrying extent put.text operand.before (cursorAt call start)
          settle call start
        else
          -- On the last cell put, as a character-wise `P` leaves it.
          let last := stop - put.text.back.utf8Size
          call.target.replaceCarrying extent put.text operand.before (cursorAt call last)
          settle call (← text.motion .previousCell stop)
        setRegister unnamed { text := taken }
      | .lines first last =>
        let lines ← linesOf call.target first last
        let body :=
          if put.linewise then put.text else put.text ++ call.target.buffer.lineEnding.text
        -- Below a last line with no line break the text ends the way it
        -- ended: the replacement's last line break is left out.
        let body := if lines.stop == lines.content then withoutLastBreak body else body
        let indent := (body.takeWhile fun char => char == ' ' || char == '\t').utf8ByteSize
        let cursor := lines.start + indent
        call.target.replaceCarrying ⟨lines.start, lines.stop⟩ body operand.before
            (cursorAt call cursor)
        settle call cursor
        setRegister unnamed { text := lines.taken, linewise := true } }

/-- What the indent operator gives up with when its text's indent levels are
refused: the buffer has no syntax tree, its tree keeps no indents query, or
the tree of the text's last edit is not delivered yet. -/
def cannotIndent (refusal : SyntaxTreeError) : String :=
  match refusal with
  | .notAttached => "indent: this buffer has no syntax tree"
  | .noQuery => "indent: its language has no indents query"
  | .notParsed => "indent: the syntax tree is not parsed yet"
  | refusal => s!"indent: {refusal.describe}"

/-- The rows from the first through the last an operator's stretch touches,
as `=` takes them: whole lines, or the rows of the first and last cells. -/
def rowsOf (text : TextId) (stretched : Vocabulary.Stretch) : TextM (Nat × Nat) := do
  match stretched with
  | .lines first last =>
    return (first, last)
  | .cells extent _ =>
    let first ← rowOf text extent.start
    if extent.stop > extent.start then
      return (first, ← rowOf text (← text.motion .previousCell extent.stop))
    return (first, first)

/-- The operator that re-indents the rows of what it is handed by the
indents query its text keeps, Vim's `=` ("What an operator does", in the
module docs): each row's leading whitespace becomes its level in the
buffer's indent unit (`TextId.reindentEdits`, `Editor/Indent.lean`), in one
edit that carries the selection from before the command, and the cursor
goes to the first non-blank of the first row, rested. No register is read
or written. With no indent levels to read it gives up (`cannotIndent`),
having changed nothing. -/
def indent : Vocabulary.Operator :=
  { name := "indent"
    act := fun call operand => do
      let text := call.target.buffer.text
      let (first, last) ← rowsOf text operand.stretch
      let unit ← call.target.indentUnit
      match ← text.reindentEdits first last unit with
      | .error refusal =>
        giveUp (cannotIndent refusal)
      | .ok edits =>
        -- The first row's first non-blank in the text the edits leave: the
        -- first edit, when it is the first row's, starts where the row does.
        let firstStart ← text.offsetOf ⟨first, 0⟩
        let cursor ←
          match edits[0]? with
          | some (extent, leading) =>
            if extent.start == firstStart then
              pure (firstStart + leading.utf8ByteSize)
            else
              text.motion .lineFirstNonBlank firstStart
          | none =>
            text.motion .lineFirstNonBlank firstStart
        unless edits.isEmpty do
          call.target.replaceEachCarrying edits operand.before (cursorAt call cursor)
        settle call cursor }

/-- The table the operate command looks an operator's name up in: one entry
for each name the Vim scheme's default tables bind a key to, and `replace`,
which the clipboard commands' run tables name (`Editor/Evil/Clipboard.lean`). -/
def operators : Array Vocabulary.Operator :=
  #[delete, change, yank, replace, indent]

/-- The operate command over the vocabulary `operators`, `motions` and
`objects`, as it is called ("The operate command", in the module docs): its
arguments name the operator, the kind of what it acts on, that thing, the
count, 0 for none, and the register. The operator is handed the stretch its target
amounts to from the head of the primary range of the target's selection,
and the window then keeps no wanted column. A call that cannot be made
gives up, and so does one whose motion failed where the cursor is; one
whose motion failed after it moved leaves the cursor where the motion got
to and breaks off ("What an operator takes", in the module docs). A
doubled operator with a count above 1 on the last line gives up too ("The
doubled operator on the last line", in the module docs). -/
def operate (operators : Array Vocabulary.Operator) (motions : Array Vocabulary.Motion)
    (objects : Array Vocabulary.TextObject) (call : Call) : EditorM Unit := do
  -- A motion's argument, when it has one, is the string after its name.
  let (operator, kind, name, argument, count, register) ←
    match call.arguments with
    | [.str operator, .str kind, .str name, .nat count, .str register] =>
      pure (operator, kind, name, none, count, register)
    | [.str operator, .str kind, .str name, .str argument, .nat count, .str register] =>
      pure (operator, kind, name, some argument, count, register)
    | _ =>
      giveUp noOperatorNamed
  let some operator := operators.find? (·.name == operator) | giveUp (noSuchOperator operator)
  -- Before anything is taken: an operator may never reach its store.
  discard <| registerNamed register
  let text := call.target.buffer.text
  let before ← call.target.selection
  let some range := before.ranges[before.primary]? | throw .badSelection
  let head := range.head
  -- What the echo area is to say once the operator has acted: what the
  -- motion handed back to be said.
  let (operand, said) : Vocabulary.Operand × Option String ←
    match kind with
    | "motion" =>
      let some motion := motions.find? (·.name == name) | giveUp (noSuchMotion name)
      let taken ←
        motion.taken operator.replaces text
            { head, count := if count == 0 then none else some count, argument }
      if let some find := taken.find then
        setLastFind find
      if let some search := taken.search then
        setLastSearch search
      if taken.failed then
        -- Vim cancels the operator and leaves the cursor where the motion
        -- got to, as the state the view was in before the key has it: the
        -- scheme goes back to that state.
        let cursor :=
          { call.report with
            shape := before.shape, selecting := false }
        let reached ← rested (restOf cursor) text taken.head
        if reached == head then
          giveUp (taken.said.getD (cannotMove name))
        call.target.select { ranges := #[⟨reached, reached⟩], shape := before.shape }
        discard <| call.target.window.id.setWanted none
        breakOff (taken.said.getD (cannotMove name))
      pure
          ({ stretch := ← stretch operator text head taken, head, rest := min head taken.head,
             register, before },
            taken.said)
    | "lines" =>
      -- The doubled operator: the head's line and `count - 1` lines below,
      -- stopped at the last line. Vim goes down those lines first, which
      -- fails on the last line and cancels the operator.
      let first ← rowOf text head
      let last ← lastLine text
      if count > 1 && first ≥ last then
        giveUp noLineBelow
      pure
          ({ stretch := .lines first (max first (min (first + count - 1) last)), head, rest := head,
             register, before },
            none)
    | "selection" =>
      if before.shape == .line then
        -- The lines of the selection's two ends. A yank leaves the cursor
        -- at the start of the anchor's line, or on the head when the head
        -- is before the anchor.
        let rest ←
          if range.head < range.anchor then
            pure head
          else
            text.motion .lineStart range.anchor
        pure
            ({
                stretch :=
                  .lines (← rowOf text (min range.anchor head))
                    (← rowOf text (max range.anchor head)),
                head, rest, register, before },
              none)
      else
        -- What the text says the range covers, by the selection's shape,
        -- and nothing past where the last line's content ends.
        let covered ←
          text.extents
              { before with
                ranges := #[range], primary := 0 }
        let some extent := covered[0]? | throw .badSelection
        let limit ← text.motion .lineEnd (← text.offsetOf ⟨← lastLine text, 0⟩)
        let stop := min extent.stop limit
        let start := min extent.start stop
        pure
            ({ stretch := .cells ⟨start, stop⟩ .exclusive, head, rest := start, register, before },
              none)
    | "text-object" =>
      let some object := objects.find? (·.name == name) | giveUp (noSuchObject name)
      let some span ←
        object.span text
            { head, count := if count == 0 then none else some count } | giveUp (noObjectHere name)
      let stretched ← stretch operator text span.start { head := span.stop, reach := span.reach }
      -- An object of no cell: the cursor goes to where it starts.
      if let .cells extent _ := stretched then
        if extent.start == extent.stop then
          settle call extent.start
      pure ({ stretch := stretched, head, rest := span.start, register, before }, none)
    | _ =>
      giveUp noOperatorNamed
  discard <| call.target.window.id.setWanted none
  operator.act call operand
  if let some said := said then
    message said

/-- The command that deletes the cell under the cursor, Vim's `x`, as it is
called: with the count and the register a command's key compiles to
(`Editor/InputScheme/Vim.lean`, "Edits"), each of which may be left out. It
is the operate command's own path, with the operator `delete` over the
motion `right`, and has no rule of its own: it deletes up to `count` cells
and no further than the line's end, into the register, and the cursor
rests on the cell that follows or on the line's last cell. -/
def deleteChar (call : Call) : EditorM Unit :=
  let (count, register) :=
    match call.arguments with
    | .nat count :: .str register :: _ => (count, register)
    | .nat count :: _ => (count, "")
    | _ => (0, "")
  operate operators motions #[]
    { call with
      arguments := [.str delete.name, .str "motion", .str right.name, .nat count, .str register] }

end Editor.Evil
