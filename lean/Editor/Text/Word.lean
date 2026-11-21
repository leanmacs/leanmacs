import Editor.Text

/-!
# The word under the cursor

What a line's word under the cursor is, over the text port alone
(`Editor/Text.lean`): the cells of a line (`cells`), which cells are blanks
and which word characters (`isBlank`, `isWord`, by the text's word class,
`wordCharacter`), the word under the cursor (`underCursor`), the pattern
that finds it as a whole word (`wholePattern`), and what is said when the
line has none (`noneUnderCursor`).

It is a core module because more than one feature asks it: evil's `*` and
`#` (`Editor/Evil/Motions.lean`, whose `lineCells`, `isBlankCell`,
`isWordCell`, `starWord`, `starPattern` and `noStringUnderCursor` are these)
and project search's search for the symbol under the cursor
(`Editor/ProjectSearch/Run.lean`). So a feature that asks it imports no
other feature for it.

- **A line's cells** are its characters up to where its content ends,
  without its line break, each with the byte offset it starts at.
- **The word under the cursor** is, from the cursor: the keyword under it,
  from its first cell; the first keyword after it in the line; the run of
  characters that are neither blanks nor word characters under it; the
  first such run after it (Vim's `:help star`, with its `iskeyword` read as
  the text's word class). None when the line has none of the four at or
  after the cursor.
- **Its pattern** writes each of `\ / . * $ ^ ~ [` with a backslash before
  it, with `\<` before it when it starts with a word character and `\>`
  after it when it ends with one: the pattern Vim's `*` builds
  (`nv_ident`).
- **With none** it is Vim's E348.

Pinned by `ModelTest.wordChecks`, and through evil's motions by evil's
checks of `*` and `#`.
-/

namespace Editor.Text.Word

/-- The cells of the line of `head` in `text`, each with the offset it
starts at: its characters up to where its content ends, without its line
break. -/
def cells (text : TextId) (head : Nat) : TextM (Array (Nat × String)) := do
  let start ← text.motion .lineStart head
  let line ← text.slice start (← text.motion .lineEnd head)
  let mut offset := start
  let mut cells := #[]
  for char in line.toList do
    cells := cells.push (offset, char.toString)
    offset := offset + char.utf8Size
  return cells

/-- Whether `cell`, a cell of a line's content, is a blank: a space or a tab. -/
def isBlank (cell : String) : Bool :=
  cell == " " || cell == "\t"

/-- Whether `cell` holds a word character (`wordCharacter`). -/
def isWord (cell : String) : Bool :=
  cell.toList.all wordCharacter && !cell.isEmpty

/-- The word under the cursor at `head`, among `cells`, the cells of its
line, with the offset it starts at ("The word under the cursor", in the
module docs); `none` when the line has none at or after the cursor. -/
def underCursor (cells : Array (Nat × String)) (head : Nat) : Option (Nat × String) :=
  let cursor := (cells.findIdx? (·.1 ≥ head)).getD cells.size
  let punctuation (cell : String) := !isBlank cell && !isWord cell
  -- The run of cells `inside` holds round the index `index`.
  let run (index : Nat) (inside : String → Bool) : Nat × String :=
    let before := ((cells.extract 0 index).toList.reverse.takeWhile (inside ·.2)).length
    let first := index - before
    let cellsOf := (cells.extract first cells.size).toList.takeWhile (inside ·.2)
    (cells[first]!.1, String.join (cellsOf.map (·.2)))
  let firstFrom (inside : String → Bool) : Option Nat :=
    ((List.range (cells.size - cursor)).map (· + cursor)).find? fun index => inside cells[index]!.2
  match firstFrom isWord with
  | some index => some (run index isWord)
  | none =>
    match firstFrom punctuation with
    | some index => some (run index punctuation)
    | none => none

/-- `word` as a pattern of literal characters that finds it as a whole word
("Its pattern", in the module docs). -/
def wholePattern (word : String) : String :=
  let escaped :=
    String.join
      (word.toList.map fun char =>
        if "\\/.*$^~[".toList.contains char then "\\" ++ char.toString else char.toString)
  let starts := (word.toList.head?.map wordCharacter).getD false
  let ends := (word.toList.getLast?.map wordCharacter).getD false
  (if starts then "\\<" else "") ++ escaped ++ if ends then "\\>" else ""

/-- What is said when the line has no word at or after the cursor: Vim's
E348. -/
def noneUnderCursor : String :=
  "E348: No string under cursor"

end Editor.Text.Word
