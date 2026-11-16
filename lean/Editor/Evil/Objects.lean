import Editor.Evil
import Editor.Evil.Motions

/-!
# Evil's text objects

Vim's text objects as vocabulary entries (`Editor/Vocabulary.lean`, "Text
objects"), the table the operate command and the select command look names
up in (`objects`), and the select command (`selectObject`), which sets a
visual selection to an object (`docs/design/keymaps-and-modes.md`, "Text
objects as built"). The names are the ones the Vim scheme's default tables
bind keys to (`Editor/InputScheme/Vim/Default.lean`). Nothing here names a
key. What an operator does with an object is the operate command's
(`Editor/Evil/Operators.lean`).

Each entry is Vim 9.1's, ported literally from `textobject.c`, over the
text port: the words from `current_word`, the quotes from `current_quote`
over the port's `quoted` walk, and the blocks from `current_block` over its
`unmatched` walk (`Editor/Text.lean`, "Pairs").

| Object | Composed origin | Count | Vim 9.1's rule |
|---|---|---|---|
| `inner-word`, `inner-bigword` | Vim's cursor steps over the text port (`inc`, `dec` and the word walks below), with the class of a cell by the text's word class (`wordCharacter`) | Each further count adds one word or one run of blanks | The word or the run of blanks under the cursor |
| `a-word`, `a-bigword` | The same | Each further count adds one word and its blanks | The word under the cursor and the blanks after it, or before it when none are after and they are not an indent; on blanks, the blanks and the word after them |
| `inner-double-quote`, `inner-single-quote`, `inner-backquote` | The text port's `quoted` | 2 or more takes the quotes too, and no blanks | The quoted string round the cursor, in its line, without its quotes |
| `a-double-quote`, `a-single-quote`, `a-backquote` | `quoted`, and the line's cells (`lineCells`) for the blanks | Ignored | The quoted string with its quotes and the blanks after it, or before it when none are after |
| `inner-paren`, `inner-bracket`, `inner-brace` | The text port's `unmatched`, back to the `count`th unmatched opening bracket and forward to its partner | The `count`th enclosing pair | Between the two brackets. When the closing one is at or before its line's first non-blank, up to the start of that line, after a walk back over blank lines, so an operator takes whole lines |
| `a-paren`, `a-bracket`, `a-brace` | The same | The same | The pair with its two brackets |

- **A word's cells are classed as Vim's `cls`**: 0 for a blank and for
  where a line's content ends, 2 for a word character, 1 for any other
  character; for a WORD every cell that is not a blank is 1. Word classes
  outside ASCII are the text's word class as it stands.
- **A word's cursor is Vim's**: it may be where a line's content ends, as
  Vim's may be on the line's NUL, and `inc` and `dec` step as Vim's do,
  saying whether they stayed in the line, came to its end, crossed a line
  break or could go no further. The last line is the last a cursor may
  rest in (`lastLine`).
- **A block is found back from the cursor**, and a cursor on the opening
  bracket is inside it. For `{` a cursor in its line's indent first goes to
  the line's first non-blank. **With no enclosing pair it is the next pair
  forward** (`unmatched` of an opening bracket forward, `count` times):
  Vim 9.1's `ib` ("If the cursor is not inside a () block, then find the
  next `(`") does so for every kind, the installed Vim 9.1.1752 shows.
- **Escaped brackets are passed over**: a block counts only brackets that
  are not escaped, which is Vim's `cpo` without `M`.
- **Quoted brackets are passed over on the way to the closing bracket, and
  not on the way back to the opening one**, as Vim 9.1's `current_block`
  does: it walks back with `cpo` set to `%`, so quotes are characters like
  any other there, and restores the default `cpo` before it walks forward
  to the partner, which passes over brackets Vim guesses are quoted
  (`unmatched` with `skipQuoted`). So in `(a "b|)" c)` the block is the
  outer pair. A visual selection extended to the next block out walks
  both ways with the default `cpo`, as Vim's does.
- **In a visual state** the selection is set charwise, from `Span.start`
  to its head. A selection of one cell is the object under the cursor, as
  under an operator. A wider one is extended from its head: a word object
  by one more object, forward, or backward when the head is before the
  anchor; a block object from the selection's low end, and when the block
  found is no bigger than the selection, by the next enclosing pair. A
  quote object with a selection wider than one cell is not built (a
  recorded departure): there is no object, and the selection is as it was.
  An inner block that is empty is none in a visual state, as in Vim.
- **A count is bounded by the text**: each step is a request of the text
  port, which the interrupt guards.

## The select command

`selectObject objects` is the command a text object's key runs in a visual
state (`Vim.selectObjectCommand`): its arguments are the object's name and
the count, 0 for none. It reads the primary range of the selection, asks
the object from its head with its anchor, and sets one range of the shape
the call's report says, both ends rested by its rule, with the window
keeping no wanted column. Where there is no object the selection is left
as it was and nothing is said, as Vim only beeps; but where the selection
is of another shape than the report's, which is when the key left
`visual-line` for `visual` (`StateRecord.objectEnters`), the command gives
up (`noObjectHere`), so the view stays in the state it was in, as Vim's
does. A name no entry has gives up (`noSuchObject`), and so do arguments
that are not the layout (`noObjectNamed`).

Pinned by `ModelTest.evilObjectChecks`, by key, under the Vim scheme that
ships.
-/

namespace Editor.Evil

/-- What the operate and select commands give up with for a name the
vocabulary has no text object of. -/
def noSuchObject (name : String) : String :=
  s!"{name}: no such text object"

/-- What the operate command gives up with when the text object called
`name` is not there, as Vim fails a text object, and what the select
command gives up with where it must keep the view's state. -/
def noObjectHere (name : String) : String :=
  s!"{name}: no object here"

/-- What the select command gives up with when its arguments are not an
object's name and a count. -/
def noObjectNamed : String :=
  "no text object named (expects a text object's name and a count)"

/-- How one of Vim's cursor steps went (`inc`, `dec`): Vim's 0, 2, 1 and
-1. -/
inductive Step where
  /-- Within the line, onto a character. -/
  | within
  /-- Onto the line's end: where its content ends. -/
  | ontoEnd
  /-- Across a line break. -/
  | across
  /-- Nowhere: at the text's start, or at the last line's end. -/
  | stuck
  deriving DecidableEq, Repr

/-- Vim's `inc` from `p`: onto the next cell of the line, or onto the line's
end, or from the line's end to the next line's start; stuck at the end of
the last line, `last` (`lastLine`). -/
def inc (text : TextId) (last p : Nat) : TextM (Nat × Step) := do
  let stop ← text.motion .lineEnd p
  if p < stop then
    let next ← text.motion .nextCell p
    return (next, if next < stop then .within else .ontoEnd)
  if (← text.pointOf p .cells).row < last then
    return (← text.motion .nextCell p, .across)
  return (p, .stuck)

/-- Vim's `dec` from `p`: onto the cell before it in the line, or from the
line's start to the end of the line before; stuck at the text's start. -/
def dec (text : TextId) (p : Nat) : TextM (Nat × Step) := do
  if p > (← text.motion .lineStart p) then
    return (← text.motion .previousCell p, .within)
  if p > 0 then
    return (← text.motion .previousCell p, .across)
  return (p, .stuck)

/-- Vim's `incl`: `inc`, and once more when it came to the line's end, so
the line's end is passed over. -/
def incl (text : TextId) (last p : Nat) : TextM (Nat × Step) := do
  let (q, step) ← inc text last p
  if step == .ontoEnd then
    inc text last q
  else
    return (q, step)

/-- Vim's `decl`: `dec`, and once more when it crossed to the end of a line
that has content, so a line's end is passed over. -/
def decl (text : TextId) (p : Nat) : TextM (Nat × Step) := do
  let (q, step) ← dec text p
  if step == .across && q > (← text.motion .lineStart q) then
    dec text q
  else
    return (q, step)

/-- Whether `p` is at its line's start: Vim's column 0. -/
def atLineStart (text : TextId) (p : Nat) : TextM Bool :=
  return (← text.motion .lineStart p) == p

/-- Whether `p` is at the start of an empty line. -/
def onEmptyLine (text : TextId) (p : Nat) : TextM Bool :=
  return (← text.motion .lineStart p) == p && (← text.motion .lineEnd p) == p

/-- Vim's `cls` at `p`, for words or, when `big`, for WORDs: 0 for a blank
and where the line's content ends, and otherwise 2 for a word character
and 1 for any other, or 1 for every one when `big`. -/
def cls (text : TextId) (big : Bool) (p : Nat) : TextM Nat := do
  if p ≥ (← text.motion .lineEnd p) then
    return 0
  let cell ← text.slice p (← text.motion .nextCell p)
  if isBlankCell cell then
    return 0
  if big then
    return 1
  return if isWordCell cell then 2 else 1

/-- Vim's `back_in_line`: back to the start of the word or of the run of
blanks under `p`, within its line. -/
def backInLine (text : TextId) (big : Bool) (p : Nat) : TextM Nat := do
  let sclass ← cls text big p
  let mut p := p
  while !(← atLineStart text p) do
    let (q, _) ← dec text p
    if (← cls text big q) != sclass then
      break
    p := q
  return p

/-- Vim's `fwd_word` for one word, stopping at a line's end (`eol`), as an
object asks it: whether it did not fail, and where it left the cursor. -/
def fwdWord (text : TextId) (big : Bool) (last p : Nat) : TextM (Bool × Nat) := do
  let sclass ← cls text big p
  let lastRow := (← text.pointOf p .cells).row == last
  let (p, step) ← inc text last p
  if step == .stuck || step != .within && lastRow then
    return (false, p)
  if step != .within then
    return (true, p)
  let mut p := p
  if sclass != 0 then
    while (← cls text big p) == sclass do
      let (q, step) ← inc text last p
      p := q
      if step != .within then
        return (true, p)
  while (← cls text big p) == 0 do
    if ← onEmptyLine text p then
      break
    let (q, step) ← inc text last p
    p := q
    if step != .within then
      return (true, p)
  return (true, p)

/-- Vim's `skip_chars` forward or back: past the cells of class `sclass`;
false when a step could go no further. -/
def skipClass (text : TextId) (big : Bool) (last sclass : Nat) (forward : Bool) (p : Nat) :
    TextM (Bool × Nat) := do
  let mut p := p
  while (← cls text big p) == sclass do
    let (q, step) ←
      if forward then
        inc text last p
      else
        dec text p
    p := q
    if step == .stuck then
      return (false, p)
  return (true, p)

/-- Vim's `end_word` for one word, with `empty`, stopping on an empty line:
whether it did not fail, and where it left the cursor. With `stop`, a
cursor on a word's end moves no further. -/
def endWord (text : TextId) (big : Bool) (last : Nat) (stop : Bool) (p : Nat) :
    TextM (Bool × Nat) := do
  let sclass ← cls text big p
  let (p, step) ← inc text last p
  if step == .stuck then
    return (false, p)
  let mut p := p
  if (← cls text big p) == sclass && sclass != 0 then
    let (ok, q) ← skipClass text big last sclass true p
    if !ok then
      return (false, q)
    p := q
  else if !stop || sclass == 0 then
    while (← cls text big p) == 0 do
      if ← onEmptyLine text p then
        return (true, p)
      let (q, step) ← inc text last p
      p := q
      if step == .stuck then
        return (false, p)
    let (ok, q) ← skipClass text big last (← cls text big p) true p
    if !ok then
      return (false, q)
    p := q
  return (true, (← dec text p).1)

/-- Vim's `bck_word` for one word, with `stop`: whether it did not fail, and
where it left the cursor. -/
def bckWord (text : TextId) (big : Bool) (last p : Nat) : TextM (Bool × Nat) := do
  let sclass ← cls text big p
  let (p, step) ← dec text p
  if step == .stuck then
    return (false, p)
  let mut p := p
  if sclass == (← cls text big p) || sclass == 0 then
    while (← cls text big p) == 0 do
      if ← onEmptyLine text p then
        return (true, p)
      let (q, step) ← dec text p
      p := q
      if step == .stuck then
        return (true, p)
    let (ok, q) ← skipClass text big last (← cls text big p) false p
    if !ok then
      return (true, q)
    p := q
  return (true, (← inc text last p).1)

/-- Vim's `bckend_word` for one word, stopping at a line's start (`eol`):
whether it did not fail, and where it left the cursor. -/
def bckendWord (text : TextId) (big : Bool) (p : Nat) : TextM (Bool × Nat) := do
  let sclass ← cls text big p
  let (p, step) ← dec text p
  if step == .stuck then
    return (false, p)
  if step == .across then
    return (true, p)
  let mut p := p
  if sclass != 0 then
    while (← cls text big p) == sclass do
      let (q, step) ← dec text p
      p := q
      if step != .within then
        return (true, p)
  while (← cls text big p) == 0 do
    if ← onEmptyLine text p then
      break
    let (q, step) ← dec text p
    p := q
    if step != .within then
      return (true, p)
  return (true, p)

/-- Vim 9.1's `current_word`: the word object, a WORD when `big`, the
inner one, or the one with its blanks when `include` ("Text objects as
built"). -/
def currentWord (text : TextId) (big around : Bool) (within : Vocabulary.Within) :
    TextM (Option Vocabulary.Span) := do
  let last ← lastLine text
  let visual := within.anchor.isSome
  let mut cursor := within.head
  let mut anchor := within.anchor.getD within.head
  let mut start := 0
  let mut inclusive := true
  let mut includeWhite := false
  let mut count := within.count.getD 1
  -- With no visual area, or one of one cell: the word or the blanks under
  -- the cursor.
  if anchor == cursor then
    cursor ← backInLine text big cursor
    start := cursor
    if ((← cls text big cursor) == 0) == around then
      let (ok, p) ← endWord text big last true cursor
      if !ok then
        return none
      cursor := p
    else
      let (_, p) ← fwdWord text big last cursor
      cursor := p
      -- Back off the next line's start, or the blank after the word.
      if ← atLineStart text cursor then
        cursor := (← decl text cursor).1
      else
        cursor ← text.motion .previousCell cursor
      if around then
        includeWhite := true
    anchor := start
    count := count - 1
  -- Each further count: one more object.
  while count > 0 do
    inclusive := true
    if visual && cursor < anchor then
      let (p, step) ← decl text cursor
      if step == .stuck then
        return none
      cursor := p
      if around != ((← cls text big cursor) != 0) then
        let (ok, q) ← bckWord text big last cursor
        if !ok then
          return none
        cursor := q
      else
        let (ok, q) ← bckendWord text big cursor
        if !ok then
          return none
        cursor := (← incl text last q).1
    else
      let (p, step) ← incl text last cursor
      if step == .stuck then
        return none
      cursor := p
      if around != ((← cls text big cursor) == 0) then
        let (ok, q) ← fwdWord text big last cursor
        cursor := q
        if !ok && count > 1 then
          return none
        -- An end just past a line break takes nothing of the next line.
        if ← atLineStart text cursor then
          inclusive := false
        else
          cursor ← text.motion .previousCell cursor
      else
        let (ok, q) ← endWord text big last true cursor
        if !ok then
          return none
        cursor := q
    count := count - 1
  -- With no blanks after, the blanks before, but never an indent.
  if
      includeWhite && ((← cls text big cursor) != 0 || (← atLineStart text cursor) && !inclusive) &&
        !(← atLineStart text start) then
    let before ← backInLine text big (← text.motion .previousCell start)
    if (← cls text big before) == 0 && !(← atLineStart text before) then
      if visual then
        anchor := before
      else
        start := before
  if visual then
    return some { start := anchor, stop := cursor, reach := .inclusive }
  return some { start, stop := cursor, reach := if inclusive then .inclusive else .exclusive }

/-- The word object called `name`: a WORD when `big`, with its blanks when
`include`. -/
def wordObject (name : String) (big around : Bool) : Vocabulary.TextObject :=
  { name, span := fun text within => currentWord text big around within }

/-- The word under the cursor, Vim's `iw`. -/
def innerWord : Vocabulary.TextObject :=
  wordObject "inner-word" false false

/-- The word under the cursor and its blanks, Vim's `aw`. -/
def aWord : Vocabulary.TextObject :=
  wordObject "a-word" false true

/-- The WORD under the cursor, Vim's `iW`. -/
def innerBigword : Vocabulary.TextObject :=
  wordObject "inner-bigword" true false

/-- The WORD under the cursor and its blanks, Vim's `aW`. -/
def aBigword : Vocabulary.TextObject :=
  wordObject "a-bigword" true true

/-- Vim 9.1's `current_quote` with no visual area, or one of one cell: the
quoted string of `quote` round the cursor (`TextId.quoted`), without its
quotes, or with them and its blanks when `include` ("Text objects as
built"). With a wider selection there is none, a recorded departure. -/
def currentQuote (text : TextId) (quote : Quote) (around : Bool) (within : Vocabulary.Within) :
    TextM (Option Vocabulary.Span) := do
  if within.anchor.any (· != within.head) then
    return none
  let some found ← text.quoted quote within.head | return none
  let opening := found.start
  let closing ← text.motion .previousCell found.stop
  let mut first := opening
  let mut final := closing
  if around then
    let cells ← lineCells text within.head
    let after := (cells.toList.filter (·.1 > closing)).takeWhile (isBlankCell ·.2)
    match after.getLast? with
    | some (offset, _) =>
      final := offset
    | none =>
      let before := ((cells.toList.filter (·.1 < opening)).reverse.takeWhile (isBlankCell ·.2))
      if let some (offset, _) := before.getLast? then
        first := offset
  let count := within.count.getD 1
  let start := if !around && count < 2 then found.start + 1 else first
  let stop ←
    if around || count > 1 then
      text.motion .nextCell final
    else
      pure closing
  return some { start, stop }

/-- The quote object called `name`, of `quote`, with its quotes and blanks
when `include`. -/
def quoteObject (name : String) (quote : Quote) (around : Bool) : Vocabulary.TextObject :=
  { name, span := fun text within => currentQuote text quote around within }

/-- The quoted string round the cursor without its quotes, Vim's `i"`. -/
def innerDoubleQuote : Vocabulary.TextObject :=
  quoteObject "inner-double-quote" .double false

/-- The quoted string round the cursor with its quotes and blanks, Vim's
`a"`. -/
def aDoubleQuote : Vocabulary.TextObject :=
  quoteObject "a-double-quote" .double true

/-- Vim's `i'`. -/
def innerSingleQuote : Vocabulary.TextObject :=
  quoteObject "inner-single-quote" .single false

/-- Vim's `a'`. -/
def aSingleQuote : Vocabulary.TextObject :=
  quoteObject "a-single-quote" .single true

/-- Vim's `` i` ``. -/
def innerBackquote : Vocabulary.TextObject :=
  quoteObject "inner-backquote" .back false

/-- Vim's `` a` ``. -/
def aBackquote : Vocabulary.TextObject :=
  quoteObject "a-backquote" .back true

/-- The opening bracket `count` pairs out from `p`, each step from the last
one found: back to an unmatched one, or, when there is none back from `p`,
forward to the next one. `none` when a step finds none. -/
def openingOf (text : TextId) (bracket : Bracket) (count p : Nat) : TextM (Option Nat) := do
  let forward := (← text.unmatched bracket true false false false p).isNone
  let mut reached := p
  for _ in [0:count] do
    let some found ← text.unmatched bracket true forward false false reached | return none
    reached := found
  return some reached

/-- Vim 9.1's `current_block`: the block of `bracket` round the cursor, with
its brackets when `include` and without them otherwise ("Text objects as
built"). -/
def currentBlock (text : TextId) (bracket : Bracket) (around : Bool) (within : Vocabulary.Within) :
    TextM (Option Vocabulary.Span) := do
  let last ← lastLine text
  let visual := within.anchor.isSome
  let head := within.head
  let anchor := within.anchor.getD head
  let mut oldStart := head
  let mut oldEnd := head
  let mut origin := head
  if anchor == head then
    -- For `{`, out of the indent first; a cursor on the opening bracket is
    -- inside it.
    if bracket == .curly then
      while origin < (← text.motion .lineFirstNonBlank origin) do
        let (p, step) ← inc text last origin
        origin := p
        if step != .within then
          break
    if
        origin < (← text.motion .lineEnd origin) &&
          (← text.slice origin (← text.motion .nextCell origin)) == bracket.opening.toString then
      origin ← text.motion .nextCell origin
  else if anchor < head then
    oldStart := anchor
    origin := anchor
  else
    oldEnd := anchor
  let some opening ← openingOf text bracket (within.count.getD 1) origin | return none
  let some closing ← text.unmatched bracket false true false true opening | return none
  if around then
    return some { start := opening, stop := closing, reach := .inclusive }
  let mut opening := opening
  let mut closing := closing
  let mut start := 0
  let mut stop := 0
  let mut sol := false
  -- Inside the brackets; a closing bracket that only blanks are before in
  -- its line is passed back over, with the blank lines before it.
  repeat
    start := (← incl text last opening).1
    sol ← atLineStart text closing
    stop := (← decl text closing).1
    while stop < (← text.motion .lineFirstNonBlank stop) do
      sol := true
      let (p, step) ← decl text stop
      stop := p
      if step != .within then
        break
    -- In a visual state, a block no bigger than the selection is the next
    -- one out.
    if visual && start ≥ oldStart && stop ≤ oldEnd && start != stop then
      let some outer ←
        text.unmatched bracket true false false true (← decl text oldStart).1 | return none
      let some partner ← text.unmatched bracket false true false true outer | return none
      opening := outer
      closing := partner
    else
      break
  if visual then
    if sol && stop < (← text.motion .lineEnd stop) then
      stop := (← inc text last stop).1
    return some { start, stop, reach := .inclusive }
  if sol then
    return some { start, stop := (← incl text last stop).1 }
  if start ≤ stop then
    return some { start, stop, reach := .inclusive }
  return some { start, stop := start }

/-- The block object called `name`, of `bracket`, with its brackets when
`include`. -/
def blockObject (name : String) (bracket : Bracket) (around : Bool) : Vocabulary.TextObject :=
  { name, span := fun text within => currentBlock text bracket around within }

/-- Inside the parentheses round the cursor, Vim's `i(`. -/
def innerParen : Vocabulary.TextObject :=
  blockObject "inner-paren" .round false

/-- The parentheses round the cursor, with them, Vim's `a(`. -/
def aParen : Vocabulary.TextObject :=
  blockObject "a-paren" .round true

/-- Vim's `i[`. -/
def innerBracket : Vocabulary.TextObject :=
  blockObject "inner-bracket" .square false

/-- Vim's `a[`. -/
def aBracket : Vocabulary.TextObject :=
  blockObject "a-bracket" .square true

/-- Vim's `i{`. -/
def innerBrace : Vocabulary.TextObject :=
  blockObject "inner-brace" .curly false

/-- Vim's `a{`. -/
def aBrace : Vocabulary.TextObject :=
  blockObject "a-brace" .curly true

/-- The table the operate and select commands look a text object's name up
in: one entry for each name the Vim scheme's default tables bind a key to. -/
def objects : Array Vocabulary.TextObject :=
  #[innerWord, aWord, innerBigword, aBigword, innerDoubleQuote, aDoubleQuote, innerSingleQuote,
    aSingleQuote, innerBackquote, aBackquote, innerParen, aParen, innerBracket, aBracket,
    innerBrace, aBrace]

/-- The select command over the vocabulary `objects`, as it is called ("The
select command", in the module docs): the selection's primary range is set
to the object its first argument names, asked with the count its second
argument is, 0 for none. -/
def selectObject (objects : Array Vocabulary.TextObject) (call : Call) : EditorM Unit := do
  let (name, count) ←
    match call.arguments with
    | [.str name, .nat count] => pure (name, count)
    | _ => giveUp noObjectNamed
  let some object := objects.find? (·.name == name) | giveUp (noSuchObject name)
  let text := call.target.buffer.text
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | throw .badSelection
  let within : Vocabulary.Within :=
    { head := range.head, count := if count == 0 then none else some count
      anchor := some range.anchor }
  let some span ← object.span text within |
    if selection.shape == call.report.shape then return else giveUp (noObjectHere name)
  let head ←
    if span.reach == .inclusive then pure span.stop else text.motion .previousCell span.stop
  let rest := restOf call.report
  call.target.select
    { ranges := #[⟨← rested rest text span.start, ← rested rest text head⟩]
      shape := call.report.shape }
  discard <| call.target.window.id.setWanted none

end Editor.Evil
