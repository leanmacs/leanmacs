import Editor.Clipboard.Model
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Display.Model
import Editor.Evil.Compiled
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.Floating
import Editor.InputScheme.Vim.Default
import Editor.Language
import Editor.Layout
import Editor.Loop.Driver
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Scene
import Editor.State
import Editor.SyntaxTree.Model
import Editor.TabBar
import Editor.Watch.Model
import ModelTest.Buffers

/-!
# Model tests: the Evil scheme

The checks of the Evil scheme: motions, state, insert, find, search and its
decoration, operators, selections, text objects over the syntax tree,
registers, indentation, open, undo and repeat.

Its lists of checks: `evilRestChecks`, `evilMotionChecks`,
`evilStateChecks`, `evilInsertChecks`, `evilFindChecks`, `evilSearchChecks`,
`searchDecorationChecks`, `evilOperatorChecks`, `evilSelectionChecks`,
`treeObjectRuleChecks`, `evilObjectChecks`, `evilRegisterChecks`,
`evilIndentChecks`, `evilOpenChecks`, `evilUndoChecks`, `evilRepeatChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- Texts of the resting rule's checks, each with every position it has, in
order, and where each rests under `onCell` and under `offLineBreak`,
written out by hand: the empty text; one line feed; a line with no line
break; a line and its line feed; two lines around an empty one; a carriage
return and line feed, with the position between the two; and a character
of four bytes. -/
def restings : List (String × List Nat × List Nat × List Nat) :=
  [("", [0], [0], [0]), ("\n", [0, 1], [0, 0], [0, 0]), ("ab", [0, 1, 2], [0, 1, 1], [0, 1, 1]),
    ("ab\n", [0, 1, 2, 3], [0, 1, 2, 2], [0, 1, 1, 1]),
    ("ab\n\ncd", [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 3, 4, 5, 5], [0, 1, 1, 3, 4, 5, 5]),
    ("ab\r\ncd", [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 2, 4, 5, 5], [0, 1, 1, 1, 4, 5, 5]),
    ("a😀", [0, 1, 5], [0, 1, 1], [0, 1, 1])]

/-- Where each of `offsets` rests in a text holding `contents` under the
rule `rest` (`Evil.rested`), on the text model; none when one was
refused. -/
def restedIn (rest : Evil.Rest) (contents : String) (offsets : List Nat) : Option (List Nat) :=
  onTextModel do
    let text ← createText contents
    offsets.mapM (Evil.rested rest text)

/-- The checks of where a cursor rests in a state (`Editor/Evil.lean`), on
the text model, from every position of a few small texts. -/
def evilRestChecks : List Check :=
  [{  name :=
        "where a cursor may rest anywhere, every position rests where it is, the text's end among them"
      run :=
        pure
          (restings.all fun (contents, positions, _, _) =>
            restedIn .anywhere contents positions == some positions) },
    { name :=
        "where a cursor rests on a cell, every position rests where it is, a line break among them, but for the text's end, which rests at the start of the last cell, and the position inside a carriage return and line feed, which rests at the carriage return"
      run :=
        pure
          (restings.all fun (contents, positions, onCell, _) =>
            restedIn .onCell contents positions == some onCell) },
    { name :=
        "where a cursor rests off the line break, it rests as on a cell, and one cell back from the line break of a row that has content; the line break of an empty line is kept, and the text's end after a final line feed rests on the last character of the row before"
      run :=
        pure
          (restings.all fun (contents, positions, _, offLineBreak) =>
            restedIn .offLineBreak contents positions == some offLineBreak) },
    { name := "in the empty text every rule rests a cursor at 0"
      run :=
        pure
          ([Evil.Rest.anywhere, .onCell, .offLineBreak].all fun rest =>
            restedIn rest "" [0] == some [0]) },
    { name :=
        "the resting rule of a view is read off what the scheme reports of it: anywhere for an exclusive selection, on a cell where a motion extends the selection, and off the line break otherwise"
      run :=
        pure
          (Evil.restOf { shape := .exclusive } == .anywhere &&
            Evil.restOf { shape := .exclusive, selecting := true } == .anywhere &&
            Evil.restOf { shape := .inclusive, selecting := true } == .onCell &&
            Evil.restOf { shape := .line, selecting := true } == .onCell &&
            Evil.restOf { shape := .inclusive } == .offLineBreak &&
            Evil.restOf { shape := .line } == .offLineBreak) }]

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
commands compiled code registers for evil (`Evil.commands`) and for the
minibuffer (`Minibuffer.commands`), as the executable registers both, so
that `/` and `?` ask and are answered, and those of `more`, each under the
name it is registered under, then `commands`. A
command of `more` runs in place of one of evil's of the same name, as the
registry's latest entry of a name does. -/
def evilHanded (more : Array Config.Registration := #[])
    (commands : List (String × Dispatched) := []) : Loop.Keys Vim.Default.scheme :=
  {
    command? := fun name =>
      match (Evil.commands ++ Minibuffer.commands ++ more).findRev? (·.name == name) with
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

/-- The keys the key string `typed` names, pressed under the Vim scheme that
ships with evil's commands, from the text and the cursor `fixture` says:
the text after them with a bar at the cursor, or what the echo area says
when a command said something. -/
def evilKeys (fixture typed : String) : String :=
  match evilDriver fixture with
  | none => "no driver"
  | some driver =>
    let driver := evilFed driver typed
    if driver.loop.state.echo.isEmpty then evilShown driver else driver.loop.state.echo

/-- Whether each row of `rows` holds: the keys of a row, pressed from its
first fixture, leave its second (`evilKeys`). A failure names each row that
does not hold, with what its keys left, and each row whose key string
names no keys. -/
def evilRows (rows : List (String × String × String)) : IO Bool := do
  let wrong :=
    rows.filterMap fun (typed, before, after) =>
      let got := evilKeys before typed
      -- A key string that is refused presses nothing, which a row that
      -- expects the text unchanged would not show.
      if (keys typed).isEmpty then some s!"{repr typed} names no keys"
      else if got == after then none else some s!"{typed} from {repr before} left {repr got}"
  unless wrong.isEmpty do
    throw (IO.userError ("; ".intercalate wrong))
  return true

/-- Whether a cursor of normal state may rest at the byte offset `head` of
`contents`, said of the string alone: the text is empty and the offset 0;
or a cell starts there, which is a character's start that is not the line
feed of a carriage return and line feed, and that cell is not the line
break of a row that has content. -/
def restsWell (contents : String) (head : Nat) : Bool :=
  let chars := contents.toList
  let offsets :=
    (chars.foldl (fun (offsets, walked) char => (offsets ++ [walked], walked + char.utf8Size))
        ([], 0)).1
  let before := none :: chars.map some
  let after := (chars.drop 1).map some ++ [none]
  contents.isEmpty && head == 0 ||
    ((offsets.zip chars).zip (before.zip after)).any fun ((offset, char), (before, after)) =>
      offset == head && !(char == '\n' && before == some '\r') &&
        !((char == '\n' || char == '\r' && after == some '\n') && before.isSome &&
            before != some '\n')

/-- The texts every motion, operator and text object is swept over: those
of the resting rule's checks, one with a run of punctuation beside a word, a
run of blanks, an empty line, a line that begins with a tab, and a last line
with no line feed, and one with brackets of each kind nested, quotes of two
kinds, an escaped pair and an indented `{ }` block over lines. -/
def sweepTexts : List String :=
  restings.map (·.1) ++ ["foo.bar  x\n\n\tab\nend", "f(a [b] \"c\" 'd' \\(e\\))\n  {\n x\n }"]

/-- The counts every motion is swept with, as a move's invocation carries
one: 0, which is no count, a count of 1, a count inside most of the texts,
and one past every text. -/
def sweepCounts : List Nat :=
  [0, 1, 2, 99]

/-- Every motion of the vocabulary run by the move command, in normal
state, with each count of `sweepCounts`, from every position of a text
holding `contents` where a normal-state cursor may rest: for each, the
motion's name, the count, the position, and the selection the move left.
`none` when a move was refused. -/
def swept (contents : String) : Option (List (String × Nat × Nat × Selection)) :=
  let program : EditorM (List (String × Nat × Nat × Selection)) := do
    let mut moved := []
    for position in (List.range (contents.utf8ByteSize + 1)).filter (restsWell contents) do
      for motion in Evil.motions do
        for count in sweepCounts do
          let loop : EvilLoop := { state := ← evilState contents position }
          let stepped ←
            loop.invoke evilHanded
                { command := Vim.moveCommand, arguments := [.str motion.name, .nat count] }
          let some target := stepped.loop.state.focusedTarget? | throw .noSuchText
          moved := (motion.name, count, position, ← target.selection) :: moved
    return moved
  (program.runModel editorModel).1.toOption

/-- The rows of the oracle table for `h` and `l`
(`docs/design/keymaps-and-modes.md`, "Motions as built"): the keys, the
text before with the cursor as a bar, and the text after. -/
def leftRightRows : List (String × String × String) :=
  [("l", "a|bc", "ab|c"), ("l", "ab|c", "ab|c"), ("l", "ab|c\ndef", "ab|c\ndef"),
    ("1 l", "a|bc", "ab|c"), ("2 l", "|abcd", "ab|cd"), ("3 l", "|abcd", "abc|d"),
    ("5 l", "|abc", "ab|c"), ("l", "|\nabc", "|\nabc"), ("l", "a|b\r\ncd", "a|b\r\ncd"),
    ("h", "ab|c", "a|bc"), ("h", "|abc", "|abc"), ("h", "abc\n|def", "abc\n|def"),
    ("1 h", "ab|c", "a|bc"), ("2 h", "abc|d", "a|bcd"), ("2 h", "abc\nde|fg", "abc\n|defg"),
    ("5 h", "abc\nde|f", "abc\n|def"), ("l", "|", "|"), ("h", "|", "|"), ("l", "|\n", "|\n"),
    ("h", "|\n", "|\n")]

/-- The rows of the oracle table for `w`, `b` and `e`: a word beside a run
of punctuation, runs of blanks, an empty line, which stops `w` and `b` and
not `e`, a line of blanks only, leading blanks on the next line, the last
word with and without a final line feed, trailing blanks at the end, a
carriage return and line feed as the line break, counts inside and past the
text, the empty text and the text of one line feed, and one text with
letters outside ASCII that Vim and the editor both take for word
characters. -/
def wordRows : List (String × String × String) :=
  [("w", "foo |bar baz", "foo bar |baz"), ("1 w", "foo |bar baz", "foo bar |baz"),
    ("2 w", "|foo bar baz", "foo bar |baz"), ("w", "foo |bar", "foo ba|r"),
    ("w", "foo b|ar", "foo ba|r"), ("w", "foo ba|r", "foo ba|r"), ("w", "foo |bar\n", "foo ba|r\n"),
    ("w", "foo ba|r\n", "foo ba|r\n"), ("w", "|foo.bar  x", "foo|.bar  x"),
    ("3 w", "|foo.bar  x", "foo.bar  |x"), ("9 w", "|foo.bar  x", "foo.bar  |x"),
    ("9 w", "|ab cd ef", "ab cd e|f"), ("w", "|foo(bar)", "foo|(bar)"),
    ("w", "foo|(bar)", "foo(|bar)"), ("w", "foo(|bar)", "foo(bar|)"),
    ("3 w", "|foo(bar)", "foo(bar|)"), ("w", "|foo\n\nbar", "foo\n|\nbar"),
    ("w", "foo\n|\nbar", "foo\n\n|bar"), ("w", "|foo\n   \nbar", "foo\n   \n|bar"),
    ("w", "foo\n | \nbar", "foo\n  \n|bar"), ("2 w", "|ab cd\n  ef", "ab cd\n  |ef"),
    ("w", "a\n|\n", "a\n|\n"), ("w", "foo |bar\r\nbaz", "foo bar\r\n|baz"),
    ("w", "|héllo wörld", "héllo |wörld"), ("w", "|", "|"), ("w", "|\n", "|\n"),
    ("b", "foo b|ar", "foo |bar"), ("1 b", "foo b|ar", "foo |bar"), ("b", "foo |bar", "|foo bar"),
    ("b", "|foo bar", "|foo bar"), ("b", "foo\n\n|bar", "foo\n|\nbar"),
    ("b", "foo\n|\nbar", "|foo\n\nbar"), ("b", "foo\n   \n|bar", "|foo\n   \nbar"),
    ("b", "ab\n  |cd", "|ab\n  cd"), ("2 b", "foo.bar  |x", "foo|.bar  x"),
    ("9 b", "foo.bar  |x", "|foo.bar  x"), ("b", "foo(bar|)", "foo(|bar)"),
    ("b", "foo(|bar)", "foo|(bar)"), ("3 b", "foo(bar|)", "|foo(bar)"), ("b", "a\n|\n", "|a\n\n"),
    ("b", "foo\r\n|bar", "|foo\r\nbar"), ("b", "héllo w|örld", "héllo |wörld"), ("b", "|", "|"),
    ("b", "|\n", "|\n"), ("e", "|foo bar", "fo|o bar"), ("1 e", "|a b c d e", "a |b c d e"),
    ("e", "fo|o bar", "foo ba|r"), ("e", "foo ba|r", "foo ba|r"), ("e", "foo |bar\n", "foo ba|r\n"),
    ("e", "foo ba|r\n", "foo ba|r\n"), ("e", "fo|o\n\nbar", "foo\n\nba|r"),
    ("e", "fo|o\n   \nbar", "foo\n   \nba|r"), ("e", "a|b\n  cd", "ab\n  c|d"),
    ("e", "fo|o  ", "foo | "), ("e", "fo|o  \n", "foo | \n"),
    ("2 e", "|foo bar baz", "foo ba|r baz"), ("2 e", "|ab cd ef", "ab c|d ef"),
    ("3 e", "|a b c d e", "a b c |d e"), ("9 e", "|a b c d e", "a b c d |e"),
    ("9 e", "|ab cd ef", "ab cd e|f"), ("e", "|foo(bar)", "fo|o(bar)"),
    ("e", "fo|o(bar)", "foo|(bar)"), ("e", "foo|(bar)", "foo(ba|r)"), ("e", "a\n|\n", "a\n|\n"),
    ("e", "|héllo wörld", "héll|o wörld"), ("e", "|", "|"), ("e", "|\n", "|\n")]

/-- The rows of the oracle table for `W`, `B` and `E`, which go by runs of
characters that are not blank: with no count, with a count of 1, with a
count inside the text and with one past it, and on an empty line, which
stops `W` and `B` and not `E`. -/
def bigWordRows : List (String × String × String) :=
  [("W", "|foo.bar  x", "foo.bar  |x"), ("W", "|foo(bar) x", "foo(bar) |x"),
    ("W", "|a.b c.d e.f gh", "a.b |c.d e.f gh"), ("1 W", "|a.b c.d e.f gh", "a.b |c.d e.f gh"),
    ("2 W", "|a.b c.d e.f gh", "a.b c.d |e.f gh"), ("3 W", "|a.b c.d e.f gh", "a.b c.d e.f |gh"),
    ("9 W", "|a.b c.d e.f gh", "a.b c.d e.f g|h"),
    ("2 W", "|a.b c.d\n  e.f gh", "a.b c.d\n  |e.f gh"), ("W", "|foo\n\nbar", "foo\n|\nbar"),
    ("W", "|", "|"), ("W", "|\n", "|\n"), ("B", "foo.bar  |x", "|foo.bar  x"),
    ("B", "foo(bar) |x", "|foo(bar) x"), ("B", "a.b c.d e.f |gh", "a.b c.d |e.f gh"),
    ("1 B", "a.b c.d e.f |gh", "a.b c.d |e.f gh"), ("2 B", "a.b c.d e.f |gh", "a.b |c.d e.f gh"),
    ("2 B", "a.b c.d e.f g|h", "a.b c.d |e.f gh"), ("9 B", "a.b c.d e.f |gh", "|a.b c.d e.f gh"),
    ("B", "foo\n\n|bar", "foo\n|\nbar"), ("B", "|", "|"), ("B", "|\n", "|\n"),
    ("E", "|foo.bar  x", "foo.ba|r  x"), ("E", "|foo(bar) x", "foo(bar|) x"),
    ("E", "|a.b c.d e.f gh", "a.|b c.d e.f gh"), ("1 E", "|a.b c.d e.f gh", "a.|b c.d e.f gh"),
    ("2 E", "|a.b c.d e.f gh", "a.b c.|d e.f gh"), ("9 E", "|a.b c.d e.f gh", "a.b c.d e.f g|h"),
    ("9 E", "|a.b c.d e.f gh\n", "a.b c.d e.f g|h\n"), ("E", "fo|o\n\nbar", "foo\n\nba|r"),
    ("E", "|", "|"), ("E", "|\n", "|\n")]

/-- The rows of the oracle table for `0`, `^` and `$`: leading blanks, a
line of blanks only, an empty line, a count before `^`, which is ignored,
a `0` after a digit, which is part of a count, and for `$` a count, a count
past the last line, a count above 1 on the last line, which does not move,
an empty line as the start and as the target, a text that ends in a line
feed, and a carriage return and line feed as the line break. -/
def lineRows : List (String × String × String) :=
  [("0", "  a|bc", "|  abc"), ("0", "|abc", "|abc"), ("0", "abc\n  d|ef", "abc\n|  def"),
    ("0", "a\n|\nb", "a\n|\nb"), ("0", "ab\r\nc|d", "ab\r\n|cd"), ("0", "|", "|"),
    ("0", "|\n", "|\n"), ("1 0 l", "|abcdefghijklmno", "abcdefghij|klmno"),
    ("^", "  ab|c", "  |abc"), ("^", "|  abc", "  |abc"), ("3 ^", "  ab|c", "  |abc"),
    ("^", "|abc", "|abc"), ("^", "abc\n  de|f", "abc\n  |def"), ("^", "| \t ", " \t| "),
    ("^", "| \t \nx", " \t| \nx"), ("^", "a\n|\nb", "a\n|\nb"), ("^", "|", "|"),
    ("^", "|\n", "|\n"), ("$", "|abc\ndef", "ab|c\ndef"), ("$", "a|bc", "ab|c"),
    ("$", "ab|c", "ab|c"), ("1 $", "|abc\ndef\nghi", "ab|c\ndef\nghi"),
    ("2 $", "|abc\ndef\nghi", "abc\nde|f\nghi"), ("3 $", "|abc\ndef\nghi", "abc\ndef\ngh|i"),
    ("2 $", "|abc\ndef", "abc\nde|f"), ("5 $", "|abc\ndef\n", "abc\nde|f\n"),
    ("2 $", "abc\n|def", "abc\n|def"), ("2 $", "abc\nde|f\n", "abc\nde|f\n"),
    ("$", "|\nabc", "|\nabc"), ("2 $", "|abc\n\nghi", "abc\n|\nghi"),
    ("$", "a|b\r\ncd", "a|b\r\ncd"), ("2 $", "|ab\r\ncd", "ab\r\nc|d"), ("$", "|", "|"),
    ("$", "|\n", "|\n")]

/-- The rows of the oracle table for `j` and `k` with one key: one line,
a count of 1, a count inside the text, a count past the last line and the
first, the last line and the first line, a shorter line and an empty line
as the target, the last line of a text that ends in a line feed, a
carriage return and line feed as the line break, and characters of two
bytes before the cursor, where the column aimed for is the cursor's in
cells and its column in bytes is another. Those characters are one display
column wide, so Vim's column is the same. -/
def verticalRows : List (String × String × String) :=
  [("j", "abc|d\nx\nabcd", "abcd\n|x\nabcd"), ("k", "abcd\nx\nabc|d", "abcd\n|x\nabcd"),
    ("j", "hé|llo\nworld", "héllo\nwo|rld"), ("k", "abcdef\néö|x", "ab|cdef\néöx"),
    ("2 j", "é|bc\ndef\nghi", "ébc\ndef\ng|hi"),
    ("1 j", "a|b\ncd\nef\ngh\nij", "ab\nc|d\nef\ngh\nij"),
    ("2 j", "a|b\ncd\nef\ngh\nij", "ab\ncd\ne|f\ngh\nij"),
    ("3 j", "a|b\ncd\nef\ngh\nij", "ab\ncd\nef\ng|h\nij"),
    ("2 j", "a|b\ncd\nef\ngh\nij\n", "ab\ncd\ne|f\ngh\nij\n"),
    ("5 j", "abc|d\nx\nabcd", "abcd\nx\nabc|d"),
    ("1 k", "ab\ncd\nef\ng|h\nij", "ab\ncd\ne|f\ngh\nij"),
    ("2 k", "ab\ncd\nef\ng|h\nij", "ab\nc|d\nef\ngh\nij"),
    ("3 k", "ab\ncd\nef\ngh\ni|j", "ab\nc|d\nef\ngh\nij"),
    ("5 k", "abcd\nx\nabc|d", "abc|d\nx\nabcd"), ("j", "abcd\nx\nab|cd", "abcd\nx\nab|cd"),
    ("k", "ab|cd\nx", "ab|cd\nx"), ("j", "ab|cd\nxyz\n", "abcd\nxy|z\n"),
    ("j", "abcd\nxy|z\n", "abcd\nxy|z\n"), ("j", "ab|cd\n\nabcd", "abcd\n|\nabcd"),
    ("j", "abcd\n|\nabcd", "abcd\n\n|abcd"), ("k", "ab\r\n|cd", "|ab\r\ncd"),
    ("j", "a|b\r\ncd", "ab\r\nc|d"), ("j", "|", "|"), ("k", "|", "|"), ("j", "|\n", "|\n"),
    ("k", "|\n", "|\n")]

/-- The rows of the oracle table for the wanted column, each a sequence of
keys: `j` and `k` return to the column they started in across a shorter
line and across an empty one; a count aims for the same column; an `h`, an
`l`, a `j` or a `k` that cannot move keeps the column; a horizontal motion
that moves, and `0`, `^`, `w` and `e` whether they move or not, keep none,
so the next vertical motion aims for the cursor's own column; `$` keeps
the line's end, also when it does not move; and the column kept from a
cursor with a character of two bytes before it is its column in cells. -/
def wantedRows : List (String × String × String) :=
  [("j k", "abc|d\nx\nabcd", "abc|d\nx\nabcd"), ("j j", "abc|d\nx\nabcd", "abcd\nx\nabc|d"),
    ("j k", "hé|llo\nx\nhéllo", "hé|llo\nx\nhéllo"),
    ("j j", "hé|llo\nx\nworld", "héllo\nx\nwo|rld"), ("j j", "abc|d\n\nabcd", "abcd\n\nabc|d"),
    ("j j", "ab|cd\nxyz\n", "abcd\nxy|z\n"),
    ("2 j 2 j", "ab|cd\nx\nabcd\ny\nabcd", "abcd\nx\nabcd\ny\nab|cd"),
    ("j 2 j", "ab|cd\nx\nabcd\ny\nabcd", "abcd\nx\nabcd\n|y\nabcd"),
    ("j 3 j", "ab|cd\nx\nabcd\ny\nabcd", "abcd\nx\nabcd\ny\nab|cd"),
    ("k 2 k", "abcd\nx\nabcd\ny\nab|cd", "abcd\n|x\nabcd\ny\nabcd"),
    ("k 3 k", "abcd\nx\nabcd\ny\nab|cd", "ab|cd\nx\nabcd\ny\nabcd"),
    ("j h j", "abc|d\nx\nabcd", "abcd\nx\nabc|d"), ("j l j", "abc|d\nx\nabcd", "abcd\nx\nabc|d"),
    ("k j", "abc|d\nx\nabcd", "abcd\n|x\nabcd"), ("j h j", "abc|d\nxy\nabcd", "abcd\nxy\n|abcd"),
    ("j 0 j", "abc|d\n\nabcd", "abcd\n\n|abcd"), ("j ^ k", "abc|d\nx\nabcd", "|abcd\nx\nabcd"),
    ("j w j", "abc|d\nx\nabcd\nabcd", "abcd\nx\nabcd\n|abcd"),
    ("j e k", "abc|d\nx\nabcd", "abcd\n|x\nabcd"),
    ("$ j j", "|abc\nde\nabcdef", "abc\nde\nabcde|f"),
    ("$ j j k", "|abc\nde\nabcdef", "abc\nd|e\nabcdef"), ("2 $ k", "abc\n|def", "ab|c\ndef")]

/-- The rows of the oracle table for the display column `j` and `k` aim
for, each Vim 9.1's result with a tab stop of 8: the cursor after a tab and
after one and two wide characters, going down and going up; a column that
falls inside a tab and inside a wide character, and one just past each;
`j` then `k` across a line with a tab, and across a shorter line with a tab
and with a wide character before the cursor; a count; the head of a visual
selection; and `$` before, onto a line with a tab. -/
def displayColumnRows : List (String × String × String) :=
  [("j", "a\t|b\n0123456789", "a\tb\n01234567|89"), ("k", "0123456789\na\t|b", "01234567|89\na\tb"),
    ("j", "世|b\n0123456789", "世b\n01|23456789"), ("k", "0123456789\n世|b", "01|23456789\n世b"),
    ("j", "世界|b\n0123456789", "世界b\n0123|456789"), ("k", "0123456789\n世界|b", "0123|456789\n世界b"),
    ("j", "0123|456789\na\tb", "0123456789\na|\tb"),
    ("j", "01234567|89\na\tb", "0123456789\na\t|b"), ("j", "0|123456789\na世b", "0123456789\na|世b"),
    ("j", "01|23456789\na世b", "0123456789\na|世b"), ("j", "012|3456789\na世b", "0123456789\na世|b"),
    ("j k", "0123|456789\na\tb", "0123|456789\na\tb"),
    ("j k", "a\t|b\nxy\n0123456789", "a\t|b\nxy\n0123456789"),
    ("j j", "a\t|b\nxy\n0123456789", "a\tb\nxy\n01234567|89"),
    ("j j k k", "a\t|b\nxy\n0123456789", "a\t|b\nxy\n0123456789"),
    ("j k", "a世|b\nx\n0123456789", "a世|b\nx\n0123456789"),
    ("j j", "a世|b\nx\n0123456789", "a世b\nx\n012|3456789"),
    ("j j k k", "a世|b\nx\n0123456789", "a世|b\nx\n0123456789"),
    ("2 j", "a\t|b\nxy\n0123456789", "a\tb\nxy\n01234567|89"),
    ("v j", "a\t|b\n0123456789", "a\tb\n01234567|89"),
    ("$ j j", "|abc\nde\nc\td", "abc\nde\nc\t|d")]

/-- The rows of the oracle table for `g g` and `G`: no count, a count as
the line's number, from 1, a number past the last line, a text that ends
in a line feed, whose last line is the line before its end, leading
blanks, an empty line and a line of blanks only as the target, a text of
one line, and that neither keeps a wanted column. -/
def toLineRows : List (String × String × String) :=
  [("G", "a|bcd\n  xyz\n", "abcd\n  |xyz\n"), ("G", "a\nb\n  c|c\nd\n", "a\nb\n  cc\n|d\n"),
    ("G", "ab|c", "|abc"), ("1 G", "a\nb\n  c|c\nd", "|a\nb\n  cc\nd"),
    ("2 G", "a\nb\n  c|c\nd", "a\n|b\n  cc\nd"), ("9 9 G", "a\nb\n  c|c\nd", "a\nb\n  cc\n|d"),
    ("4 G", "a|b\ncd", "ab\n|cd"), ("2 G", "ab\n\n|cd", "ab\n|\ncd"),
    ("2 G", "ab\n   \n|cd", "ab\n  | \ncd"), ("G", "a|b\r\n  cd", "ab\r\n  |cd"), ("G", "|", "|"),
    ("G", "|\n", "|\n"), ("g g", "abcd\n  x|yz", "|abcd\n  xyz"), ("g g", "  a|b\ncd", "  |ab\ncd"),
    ("g g", "ab|c", "|abc"), ("1 g g", "a\nb\n  c|c\nd", "|a\nb\n  cc\nd"),
    ("3 g g", "a\nb\n  c|c\nd", "a\nb\n  |cc\nd"), ("9 9 g g", "a\nb\n  c|c\nd", "a\nb\n  cc\n|d"),
    ("9 9 g g", "a\nb\n  c|c\nd\n", "a\nb\n  cc\n|d\n"), ("g g", "|", "|"), ("g g", "|\n", "|\n"),
    ("j G k k", "abc|d\nx\nabcd", "|abcd\nx\nabcd")]

/-- Rows for every motion key from an empty line between two lines: where
Vim's motion puts the cursor, which for the motions along the line is
where it is. -/
def emptyLineRows : List (String × String × String) :=
  let here := "ab\n|\ncd"
  [("h", here, here), ("2 h", here, here), ("l", here, here), ("2 l", here, here),
    ("j", here, "ab\n\n|cd"), ("2 j", here, "ab\n\n|cd"), ("k", here, "|ab\n\ncd"),
    ("2 k", here, "|ab\n\ncd"), ("w", here, "ab\n\n|cd"), ("b", here, "|ab\n\ncd"),
    ("e", here, "ab\n\nc|d"), ("W", here, "ab\n\n|cd"), ("B", here, "|ab\n\ncd"),
    ("E", here, "ab\n\nc|d"), ("0", here, here), ("^", here, here), ("$", here, here),
    ("2 $", here, "ab\n\nc|d"), ("g g", here, "|ab\n\ncd"), ("G", here, "ab\n\n|cd")]

/-- Rows for every motion key from the last character of a text that ends
`ending`, which is nothing or a line feed: a motion that would leave the
text does not move, with a count as with none, and the cursor is never past
the last character. -/
def lastCharacterRows (ending : String) : List (String × String × String) :=
  let here := "ab\nc|d" ++ ending
  let lineStart := "ab\n|cd" ++ ending
  [("h", here, lineStart), ("l", here, here), ("3 l", here, here), ("j", here, here),
    ("3 j", here, here), ("k", here, "a|b\ncd" ++ ending), ("w", here, here), ("3 w", here, here),
    ("b", here, lineStart), ("e", here, here), ("3 e", here, here), ("W", here, here),
    ("3 W", here, here), ("B", here, lineStart), ("E", here, here), ("3 E", here, here),
    ("0", here, lineStart), ("^", here, lineStart), ("$", here, here), ("3 $", here, here),
    ("g g", here, "|ab\ncd" ++ ending), ("G", here, lineStart)]

/-- The move command called with `arguments`, as an invocation no key
yielded, under the Vim scheme that ships with evil's commands, from the
text and the cursor `fixture` says: the text after it with a bar at the
cursor, and what the echo area says. `none` if there is no driver. -/
def evilMoved (fixture : String) (arguments : List Argument) : Option (String × String) :=
  (evilDriver fixture).map fun driver =>
    let (moved, _) :=
      driver.stepped (driver.loop.invoke driver.handed { command := Vim.moveCommand, arguments })
    (evilShown moved, moved.loop.state.echo)

/-- What a window keeps after `j` or `k` from the cursor `fixture` says,
with the cursor come to rest at `head`: the goal the display model of the
evil checks passes back for the cursor's start, asked here of the text laid
out unwrapped, so that a check of what is kept restates no number of the
display's. `none` if the display refused. -/
def keptFrom (fixture : String) (head : Nat) : Option Window.Wanted :=
  let (contents, start) := barred fixture
  match movedBy [contents] Evil.unwrapped start 0 none editorModel.display.cells with
  | .inr moved => some { column := .goal moved.goal, head }
  | .inl _ => none

/-- The rows of the oracle table for `%` as a move, each run through Vim
9.1.1752 headless: the keys, the text before with the cursor as a bar, and
the text after. The rows after the counts pass over brackets Vim guesses
are quoted: inside a pair of double quotes, from outside and from inside,
in a line with an odd number of quotes, past escaped quotes, across lines
and in single quotes, and a first bracket inside quotes that has no
partner. The last row is the recorded departure, which shows the editor's
behaviour: `/* */` is not matched. -/
def percentRows : List (String × String × String) :=
  [("%", "|(a [b] c)", "(a [b] c|)"), ("%", "(a [b] c|)", "|(a [b] c)"),
    ("%", "(a |[b] c)", "(a [b|] c)"), ("%", "a\n|{\n b\n}", "a\n{\n b\n|}"),
    ("%", "a\n{\n b\n|}", "a\n|{\n b\n}"), ("%", "|x (a)", "x (a|)"), ("%", "|x\n(a)", "|x\n(a)"),
    ("%", "|(a", "|(a"), ("%", "|\\(a\\)", "\\(a\\|)"), ("%", "|(a \\) b)", "(a \\) b|)"),
    ("%", "(a \\|) b)", "(a \\|) b)"), ("%", "|\\\\(a)", "\\\\(a|)"),
    ("5 0 %", "|a\nb\nc\nd\n  e\nf\ng\nh\ni\nj\n", "a\nb\nc\nd\n  |e\nf\ng\nh\ni\nj\n"),
    ("1 %", "a\nb\nc\nd\ne\nf\ng\nh\ni\n|j\n", "|a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"),
    ("1 0 0 %", "|a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n", "a\nb\nc\nd\ne\nf\ng\nh\ni\n|j\n"),
    ("1 0 1 %", "|a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n", "|a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"),
    ("9 9 %", "|a\nb\nc\nd\ne\nf\ng\nh\ni\n  j\n", "a\nb\nc\nd\ne\nf\ng\nh\ni\n  |j\n"),
    ("%", "|(a \")\" b)", "(a \")\" b|)"), ("%", "(a \")\" b|)", "|(a \")\" b)"),
    ("%", "(a \"|)\" b)", "(a \"|)\" b)"), ("%", "\"(a|)\"", "\"|(a)\""),
    ("%", "x \" |(a \"b)\" c)", "x \" (a \"b|)\" c)"),
    ("%", "|(a \\\"b) \\\" c)", "(a \\\"b|) \\\" c)"),
    ("%", "(a \\\"b) \\\" c|)", "(a \\\"b) \\\" c|)"), ("%", "|{\n  \"}\"\n}", "{\n  \"}\"\n|}"),
    ("%", "{\n  \"|}\"\n}", "|{\n  \"}\"\n}"), ("%", "|(a ')' b)", "(a ')' b|)"),
    ("%", "|x \"(\" (a)", "|x \"(\" (a)"), ("%", "|/* x */", "|/* x */")]

/-- The checks of evil's motions (`Editor/Evil.lean`, `Editor/Evil/Motions.lean`)
on the loop's driver over the editor's models, under the Vim scheme that
ships with the commands compiled code registers for evil: a motion's key
is pressed in a text with the cursor written into it, and each expected
text is written by hand from Vim's documented behaviour, case by case. -/
def evilMotionChecks : List Check :=
  [{  name :=
        "% goes from the first bracket of the line at or after the cursor to its partner, across lines, both ways, counting only brackets of its escapedness, and does not move with no bracket on the line or no partner; N% goes to the first non-blank of the line N percent into the text, and above 100 does not move; brackets Vim guesses are quoted are passed over, as its default cpoptions has it; /* */ is not matched, a recorded departure"
      run := evilRows percentRows },
    { name :=
        "h and l move by cells and stay on the line: with no count one cell, with a count that many, as far as the line allows; neither leaves an empty line, the empty text or the line of a text that is one line feed, and l does not go onto the line break"
      run := evilRows leftRightRows },
    { name :=
        "w goes to the start of the next word, b to the start of the word before and e to the end of the next, a word being a run of word characters or a run of punctuation: each with a count repeats, and one past the text goes as far as there is a word; an empty line stops w and b and not e; where there is no word further on, w and e rest on the last character"
      run := evilRows wordRows },
    { name :=
        "W, B and E go as w, b and e do, by runs of characters that are not blank: with no count, with a count of 1, with a count inside the text, and with one past it, which goes as far as there is such a run"
      run := evilRows bigWordRows },
    { name :=
        "0 goes to the line's start and ^ to its first character that is not a blank, each whatever count was typed, and on a line of blanks only ^ rests on the last blank; $ goes to the last character of the line, or with a count of the line that many lines less one below, of the last line when the text has fewer, and does not move from the last line with a count above 1; none leaves an empty line"
      run := evilRows lineRows },
    { name :=
        "j and k go one line down and up by lines of the text, or with a count that many, and stop at the last line and at the first; on a shorter line the cursor is on its last character, and on an empty line on its line break; the last line of a text that ends in a line feed is the line before its end; the column they aim for is the cursor's counted in cells, not in bytes, so a character of two bytes before the cursor is one column"
      run := evilRows verticalRows },
    { name :=
        "j and k keep the column they aim for: j then k across a shorter line returns to the column it started in, and so does j twice across an empty line; an h or an l that cannot move keeps it, a motion along the line that moves keeps none, and after $ they stay at line ends; the column kept is counted in cells, not in bytes, so with a character of two bytes before the cursor j then k still returns to it"
      run := evilRows wantedRows },
    { name :=
        "gg goes to the first line and G to the last, or with a count each to the line of that number, the last line when the text has fewer, and to that line's first character that is not a blank; the last line of a text that ends in a line feed is the line before its end; neither keeps a wanted column"
      run := evilRows toLineRows },
    { name :=
        "from an empty line every motion key leaves the cursor where Vim's does: h, l, 0, ^ and $ where it is, the others on the line they lead to"
      run := evilRows emptyLineRows },
    { name :=
        "from the last character of the text, with a final line feed and with none, every motion key leaves the cursor where Vim's does, with a count as with none: a motion that would leave the text does not move, and the cursor is never past the last character"
      run := evilRows (lastCharacterRows "" ++ lastCharacterRows "\n") },
    { name :=
        "every key the default tables bind to a motion has a motion of its name in the vocabulary: pressed in a text of three lines, a motion that takes a character with one, none says it has no such motion, and none but the searches says anything in the echo area (a search says its warning or its error: n and N with no last search, and * on the one occurrence of its word)"
      run := do
        let said :=
          Vim.Default.motions.filterMap fun (typed, bound) =>
            let typed :=
              match bound with
              | .charMotion _ => typed ++ " a"
              | .promptMotion .. => typed ++ " e f RET"
              | _ => typed
            let name :=
              match bound with
              | .motion name | .charMotion name | .promptMotion name _ => name
              | _ => ""
            let searches := name.startsWith "search" || name.startsWith "word-search"
            match evilDriver "ab cd\ne|f gh\nij kl" with
            | none => some s!"{typed}: no driver"
            | some driver =>
              let echo := (evilFed driver typed).loop.state.echo
              if echo.isEmpty || searches && echo != Evil.noSuchMotion name then none
              else some s!"{typed} said {repr echo}"
        unless said.isEmpty do
          throw (IO.userError ("; ".intercalate said))
        return !Vim.Default.motions.isEmpty },
    { name :=
        "after j the window keeps the column the cursor started in, with the offset the cursor rests at; after $ it keeps the line's end; after w it keeps none"
      run :=
        pure <|
          match evilDriver "abc|d\nx\nabcd" with
          | none => false
          | some driver =>
            let wanted (driver : EvilDriver) : Option (Option Window.Wanted) :=
              (driver.loop.state.window? ⟨0⟩).map (·.wanted)
            let down := evilFed driver "j"
            let ended := evilFed down "j $"
            wanted driver == some none && wanted down == (keptFrom "abc|d\nx\nabcd" 5).map some &&
              evilShown down == "abcd\n|x\nabcd" &&
              wanted ended == some (some { column := .lineEnd, head := 10 }) &&
              evilShown ended == "abcd\nx\nabc|d" &&
              wanted (evilFed down "w") == some none },
    { name :=
        "a kept column holds only while the cursor is where it was kept: once a command written here has placed the cursor elsewhere, the next j aims for the cursor's own column"
      run :=
        pure <|
          let place : Dispatched := fun call => do
            call.target.select { ranges := #[⟨5, 5⟩], shape := .inclusive }
            return none
          match evilDriver "abc|d\nxyz\nabcd" (evilHanded (commands := [("place", place)])) with
          | none => false
          | some driver =>
            let down := evilFed driver "j"
            let (placed, _) := down.stepped (down.loop.runNamed down.handed "place")
            evilShown down == "abcd\nxy|z\nabcd" &&
              evilShown (evilFed down "j") == "abcd\nxyz\nabc|d" &&
              evilShown placed == "abcd\n|xyz\nabcd" &&
              (placed.loop.state.window? ⟨0⟩).map (·.wanted) ==
                (keptFrom "abc|d\nxyz\nabcd" 7).map some &&
              evilShown (evilFed placed "j") == "abcd\nxyz\n|abcd" },
    { name :=
        "the move command reads the column the window keeps when it is called, not the one the window kept when its command was called, so a command written here that calls it twice with one call moves as two keys do: down and then down across a shorter line lands in the column it started in, and the window then keeps what it keeps after j and j; down and then up returns to where it started; and neither says anything"
      run := do
        let fixture := "abc|d\nx\nabcd"
        let moving (names : List String) : Dispatched := fun call => do
          for name in names do
            Evil.move Evil.motions { call with arguments := [.str name] }
          return none
        let handed :=
          evilHanded (commands :=
            [("down-down", moving [Evil.down.name, Evil.down.name]),
              ("down-up", moving [Evil.down.name, Evil.up.name])])
        let some driver := evilDriver fixture handed | throw (IO.userError "no driver")
        let ran (name : String) : EvilDriver :=
          (driver.stepped (driver.loop.runNamed driver.handed name)).1
        let wanted (driver : EvilDriver) : Option (Option Window.Wanted) :=
          (driver.loop.state.window? ⟨0⟩).map (·.wanted)
        let twice := ran "down-down"
        let back := ran "down-up"
        let keyed := evilFed driver "j j"
        unless evilShown twice == "abcd\nx\nabc|d" && evilShown back == fixture do
          throw
              (IO.userError
                s!"down and down left {repr (evilShown twice)}, down and up {repr (evilShown back)}")
        return evilShown keyed == evilShown twice && wanted twice == wanted keyed &&
            wanted twice == (keptFrom fixture 10).map some &&
            twice.loop.state.echo.isEmpty &&
            back.loop.state.echo.isEmpty },
    { name :=
        "j and k aim for a display column, where Vim's do: from the character after a tab they land at the tab stop's column, and from the character after a wide character two columns further in; where the column is inside a tab or a wide character they land on that character; j then k returns across a shorter line and across a line with a tab, a count aims for the same column, the head of a visual selection goes there, and after $ they rest on a line's last character past a tab"
      run := evilRows displayColumnRows },
    { name :=
        "a departure from Vim, recorded in keymaps-and-modes.md under The wanted column: a cursor on a tab counts at the tab's first display column, and Vim's at its last, so from the tab j lands one column in, where Vim's lands seven in"
      run := evilRows [("j", "a|\tb\n0123456789", "a\tb\n0|123456789")] },
    { name :=
        "j aims for the display column in a frame of no width and no height, where no view is laid out: from the character after a tab it lands at the tab stop's column"
      run := do
        let (contents, head) := barred "a\t|b\n0123456789"
        let unsized : TextM EditorState := do
          let state ← evilState contents head
          return { state with frame := { state.frame with size := ⟨0, 0⟩ } }
        let .ok driver :=
          Loop.Driver.over evilHanded (fun _ => none) unsized
            editorModel | throw (IO.userError "no driver")
        let down := evilFed driver "j"
        unless evilShown down == "a\tb\n01234567|89" do
          throw (IO.userError s!"j left {repr (evilShown down)}")
        return down.loop.state.frame.size == ⟨0, 0⟩ },
    { name :=
        "what j asks: handed a goal it makes one request fewer than handed no column, since it does not ask the display for the cursor's own x; where it cannot move, handed a goal, it asks the display nothing and makes no more requests than handed the line's end; and j and k leave no snapshot held"
      run := do
        let asked (fixture : String) (wanted : Option WantedColumn) : Option Nat :=
          let (contents, head) := barred fixture
          let program : EditorM Nat := do
            let text ← createText contents
            let before ← Watch.now
            discard <| Evil.down.target text { head, wanted }
            return (← Watch.now) - before
          (program.runModel countingModel).1.toOption
        -- How many snapshots the motion took: a released one keeps its slot.
        let taken (fixture : String) (wanted : Option WantedColumn) : Option Nat :=
          let (contents, head) := barred fixture
          let program : EditorM Unit := do
            discard <| Evil.down.target (← createText contents) { head, wanted }
          let (ended, model) := program.runModel editorModel
          ended.toOption.map fun _ => model.texts.snapshots.size
        let some driver := evilDriver "a\t|b\nxy\n0123456789" | throw (IO.userError "no driver")
        let moving := "a|b\ncd"
        let stuck := "ab\nc|d"
        let (some kept, some bare) :=
          (asked moving (some (.goal 1)),
            asked moving none) | throw (IO.userError "a motion was refused")
        let (some stopped, some ended) :=
          (asked stuck (some (.goal 1)),
            asked stuck
              (some .lineEnd)) | throw (IO.userError "a motion that cannot move was refused")
        unless kept + 1 == bare && stopped ≤ ended do
          throw
              (IO.userError
                s!"{kept} requests with a goal, {bare} with none; {stopped} stuck with a goal, {ended} with the line's end")
        -- The snapshots still held: the loop holds those of the scene it
        -- published, as it does after a motion that asks the display nothing.
        let held (typed : String) : Nat :=
          ((evilFed driver typed).model.texts.snapshots.filterMap id).size
        return taken stuck (some (.goal 1)) == some 0 && taken moving (some (.goal 1)) == some 1 &&
            held "j j k" == held "0 0 0" },
    { name :=
        "a motion may ask the display: one written here, whose target is where the display puts the head one row down, moves the cursor there when the move command runs it over the vocabulary with it added, and says nothing"
      run := do
        let rowDown : Vocabulary.Motion :=
          { name := "row-down"
            target := fun text origin => do
              let moved ←
                text.withSnapshot fun snapshot =>
                    Display.linesFrom
                      { snapshot, width := 640, position := origin.head, lines := 1, goal := none }
              return { head := moved.position } }
        let moving : Dispatched := fun call => do
          Evil.move (Evil.motions.push rowDown) { call with arguments := [.str rowDown.name] }
          return none
        let some driver :=
          evilDriver "ab|cd\nwxyz"
            (evilHanded (commands := [("row-down", moving)])) | throw (IO.userError "no driver")
        let (ran, _) := driver.stepped (driver.loop.runNamed driver.handed "row-down")
        unless evilShown ran == "abcd\nwx|yz" do
          throw (IO.userError s!"the motion left {repr (evilShown ran)}")
        return ran.loop.state.echo.isEmpty },
    { name :=
        "a move by a name the vocabulary has no motion of says so in the echo area, the name and then no such motion, and leaves the cursor where it was"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let (driver, _) :=
              driver.stepped
                (driver.loop.invoke driver.handed
                  { command := Vim.moveCommand, arguments := [.str "nowhere", .nat 0] })
            driver.loop.state.echo == "nowhere: no such motion" && evilShown driver == "a|bc" },
    { name :=
        "the move command run by its name, which hands it no argument, says that no motion was named and what it expects, which is not what it says of a name the vocabulary has no motion of, and leaves the cursor where it was"
      run := do
        let some driver := evilDriver "a|bc" | throw (IO.userError "no driver")
        let (ran, _) := driver.stepped (driver.loop.runNamed driver.handed Vim.moveCommand)
        let echo := ran.loop.state.echo
        unless echo == "move: no motion named (expects a motion's name, then an optional count)" do
          throw (IO.userError s!"the echo area says {repr echo}")
        return echo != Evil.noSuchMotion "" && evilShown ran == "a|bc" },
    { name :=
        "the move command called with a motion's name and no count after it moves with no count: every motion of the vocabulary, from the middle of a text of three lines, leaves the cursor where it leaves it when the count is 0, which is how a key with no count calls it, and says the same, which is nothing but for the searches; by the name of the motion one cell on it goes where l does"
      run := do
        let here := "ab cd\ne|f gh\nij kl"
        let wrong :=
          Evil.motions.toList.filterMap fun motion =>
            let alone := evilMoved here [.str motion.name]
            let counted := evilMoved here [.str motion.name, .nat 0]
            -- A search says its warning or its error, the same with no count
            -- and with the count 0; every other motion says nothing.
            let searches := motion.name.startsWith "search" || motion.name.startsWith "word-search"
            if alone.isSome && alone == counted && (searches || alone.map (·.2) == some "") then
              none
            else some s!"{motion.name} alone left {repr alone}, and with the count 0 {repr counted}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong))
        return !Evil.motions.isEmpty &&
            evilMoved "a|bc" [.str Evil.right.name] == some ("ab|c", "") &&
            evilKeys "a|bc" "l" == "ab|c" },
    { name :=
        "the move command called with a first argument that is not a string says that no motion was named, as it does handed no argument, and leaves the cursor where it was: a number alone, and a number before a motion's name, which is not read as the name"
      run :=
        pure <|
          !Evil.noMotionNamed.isEmpty &&
            evilMoved "a|bc" [.nat 1] == some ("a|bc", Evil.noMotionNamed) &&
            evilMoved "a|bc" [.nat 1, .str Evil.right.name] == some ("a|bc", Evil.noMotionNamed) &&
            evilMoved "a|bc" [] == some ("a|bc", Evil.noMotionNamed) },
    { name :=
        "a motion is no step of the history: after it the buffer's tree has no node more and nothing pending, and the buffer is not modified"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let moved := evilFed driver "l"
            let seen (driver : EvilDriver) : Option (Nat × Bool × Bool) :=
              (driver.loop.state.buffer? ⟨0⟩).map fun buffer =>
                (buffer.history.nodes.size, buffer.history.pending, buffer.isModified)
            evilShown moved == "ab|c" && seen moved == some (1, false, false) &&
              seen driver == some (1, false, false) },
    { name :=
        "after every motion of the vocabulary, in normal state, from every position a cursor may rest at in each sample text, with no count and with counts of 1, 2 and 99, the selection is one cursor of normal state's shape, on a cell inside the text, or at 0 in the empty text, and never on the line break of a line that has content"
      run := do
        let mut wrong := #[]
        for contents in sweepTexts do
          let some moved :=
            swept contents | throw (IO.userError s!"a move was refused in {repr contents}")
          if moved.isEmpty then
            throw (IO.userError s!"nothing was swept in {repr contents}")
          for (name, count, position, selection) in moved do
            let rests : Bool :=
              match selection.ranges with
              | #[range] =>
                range.anchor == range.head && selection.shape == .inclusive &&
                  restsWell contents range.head
              | _ => false
            unless rests do
              wrong :=
                wrong.push
                  s!"{name} with {count} from {position} of {repr contents}: {repr selection}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong.toList))
        return !Evil.motions.isEmpty }]

/-- What a scene shows of one view, as the evil checks read it. -/
structure EvilSeen where
  /-- The selection the view's one selection marker holds. -/
  selection : Selection
  /-- The text each range of that selection covers, by its shape. -/
  covered : Array String
  /-- How the view's cursors are drawn. -/
  cursor : Cursor
  /-- The left side of the view's mode line: its badge, its buffer's name
  and its modified mark. -/
  status : Array StatusField
  deriving DecidableEq, Repr

/-- What the last scene `driver`'s display recorded shows of the view
`view`: the selection its selection marker holds in the text model, what
that selection covers, the view's cursor and its status line. `none` when
no scene has the view, or it does not name one selection marker. -/
def evilSeen (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option EvilSeen := do
  let scene ← driver.model.display.scenes.back?
  let shown ← scene.views.find? (·.id == view)
  let #[marker] := shown.selections | none
  let program : TextM (Selection × Array String) := do
    let .selection selection ← marker.text.marker marker | throw .noSuchMarker
    let extents ← marker.text.extents selection
    return (selection, ← extents.mapM fun extent => marker.text.slice extent.start extent.stop)
  let (selection, covered) ← (program.runModel driver.model.texts).1.toOption
  return { selection, covered, cursor := shown.cursor, status := leftOf shown.status }

/-- What the scene after the keys `typed`, pressed from the fixture
`fixture`, shows of view 0 (`evilSeen`). -/
def evilScene (fixture typed : String) : Option EvilSeen :=
  (evilDriver fixture).bind fun driver => evilSeen (evilFed driver typed)

/-- The selection the scene shows after the keys `typed`, pressed from the
fixture `fixture`: its ranges, as an anchor and a head each, its shape,
and the text each range covers. -/
def evilSelected (fixture typed : String) : Option (List (Nat × Nat) × Shape × List String) :=
  (evilScene fixture typed).map fun seen =>
    ((seen.selection.ranges.map fun range => (range.anchor, range.head)).toList,
      seen.selection.shape, seen.covered.toList)

/-- The cursor and the left side of the mode line a scene shows of a view of
the buffer `scratch`, not modified, in the Vim state view 0 is in after the
keys `typed` under the grammar alone: what the default scheme reports of
that state, as the badge, and then the buffer's name. -/
def evilLooks (typed : String) : Cursor × Array StatusField :=
  let report := vimDefaultReport typed
  (report.cursor,
    report.status.map ({ · with padding := ModeLine.badgePadding }) ++
      #[ModeLine.field "scratch" ModeLine.bufferFace])

/-- The badge a scene's mode line shows first for a selected view in the
Vim state view 0 is in after the keys `typed` under the grammar alone: the
default scheme's first reported field, padded as the `state` segment pads
it. -/
def evilBadge (typed : String) : Option StatusField :=
  (vimDefaultReport typed).status[0]?.map ({ · with padding := ModeLine.badgePadding })

/-- The modified mark, as the mode line of a selected view draws it. -/
def evilMark : StatusField :=
  ModeLine.field ModeLine.modifiedMark ModeLine.modifiedFace

/-- What the scheme reports of a view in a state that keeps both ends of
the selection, of the shape `shape`, written by hand: what a visual state
reports, as far as entering a state reads a report. -/
def evilKeeping (shape : Shape) : InputScheme.Report :=
  { shape, selecting := true }

/-- The selection the scene shows once the command that enters a Vim state
(`Evil.enter`) has been called with the report `report`, written by hand,
on a selection written by hand: one range from `anchor` to `head`, of the
shape `was`, in a text holding `contents`. Its ranges, as an anchor and a
head each, its shape, and the text each range covers. A command the loop
is handed places the selection and calls `Evil.enter`, since no key of the
default tables enters a state that keeps both ends from an insert session,
or with an anchor that is not on a cell; a state config registers may. -/
def evilEntered (contents : String) (was : Shape) (anchor head : Nat)
    (report : InputScheme.Report) : Option (List (Nat × Nat) × Shape × List String) := do
  let enter : Dispatched := fun call => do
    call.target.select { ranges := #[⟨anchor, head⟩], shape := was }
    Evil.enter { call with report }
    return none
  let driver ← evilDriver contents (evilHanded (commands := [("enter", enter)]))
  let (entered, _) := driver.stepped (driver.loop.runNamed driver.handed "enter")
  let seen ← evilSeen entered
  return ((seen.selection.ranges.map fun range => (range.anchor, range.head)).toList,
      seen.selection.shape, seen.covered.toList)

/-- The checks of evil's states (`Editor/Evil.lean`) on the loop's driver
over the editor's models, under the Vim scheme that ships with evil's
commands: what entering a visual state and leaving one does to the view's
selection, read from the selection marker the scene names, and what the
scene then shows of the state; and, by the entering command called with a
report written by hand, a state that keeps both ends entered from an
exclusive selection. -/
def evilStateChecks : List Check :=
  [{  name :=
        "v and then a motion: the scene shows one inclusive selection from the cell the cursor started on to the cell the motion leads to, which covers both cells and what is between them"
      run :=
        pure
          (evilSelected "foo |bar baz" "v w" == some ([(4, 8)], .inclusive, ["bar b"]) &&
            evilSelected "foo |bar baz" "v" == some ([(4, 4)], .inclusive, ["b"]) &&
            evilSelected "foo |bar baz" "v 2 l" == some ([(4, 6)], .inclusive, ["bar"])) },
    { name :=
        "v and then a motion backwards: the anchor stays on the cell the cursor started on and the head is before it, and the selection covers from the head through the anchor's cell"
      run :=
        pure
          (evilSelected "foo |bar baz" "v b" == some ([(4, 0)], .inclusive, ["foo b"]) &&
            evilSelected "foo b|ar baz" "v h h" == some ([(5, 3)], .inclusive, [" ba"])) },
    { name :=
        "V and then a motion: the scene shows one line-shaped selection whose two ends are the cells the cursor started on and came to, which covers every line from the starting line to the target line, each with its line break"
      run :=
        pure
          (evilSelected "ab|cd\nefgh\nijkl" "V j" == some ([(2, 7)], .line, ["abcd\nefgh\n"]) &&
            evilSelected "ab|cd\nefgh\nijkl" "V" == some ([(2, 2)], .line, ["abcd\n"]) &&
            evilSelected "abcd\nefgh\nij|kl" "V k k" ==
              some ([(12, 2)], .line, ["abcd\nefgh\nijkl"]) &&
            evilSelected "ab|cd\nefgh\nijkl" "V 2 j w" ==
              some ([(2, 13)], .line, ["abcd\nefgh\nijkl"])) },
    { name :=
        "in a visual state the head may rest on a line break: v then $ puts it there and the selection covers the line break, and so do l from a line's last character and j onto a shorter line"
      run :=
        pure
          (evilSelected "a|bc\ndef" "v $" == some ([(1, 3)], .inclusive, ["bc\n"]) &&
            evilSelected "ab|c\ndef" "v l" == some ([(2, 3)], .inclusive, ["c\n"]) &&
            evilSelected "abc|d\nx\nabcd" "v j" == some ([(3, 6)], .inclusive, ["d\nx\n"]) &&
            evilSelected "foo |bar\n" "v w" == some ([(4, 7)], .inclusive, ["bar\n"])) },
    { name :=
        "<Escape> from a visual state leaves one inclusive selection with equal ends on the head, which then rests as normal state's cursor does: off the line break after v and $"
      run :=
        pure
          (evilSelected "foo |bar baz" "v w <Escape>" == some ([(8, 8)], .inclusive, ["b"]) &&
            evilSelected "foo |bar baz" "v b <Escape>" == some ([(0, 0)], .inclusive, ["f"]) &&
            evilSelected "ab|cd\nefgh\nijkl" "V j <Escape>" == some ([(7, 7)], .inclusive, ["g"]) &&
            evilSelected "a|bc\ndef" "v $ <Escape>" == some ([(2, 2)], .inclusive, ["c"]) &&
            evilKeys "a|bc\ndef" "v $ <Escape>" == "ab|c\ndef" &&
            evilKeys "abc|d\nx\nabcd" "v j <Escape>" == "abcd\n|x\nabcd") },
    { name :=
        "V in the state v enters and v in the state V enters change the selection's shape and keep both its ends; v typed again in the state it enters, and V in its own, leave the selection as <Escape> does"
      run :=
        pure
          (evilSelected "foo |bar baz" "v w V" == some ([(4, 8)], .line, ["foo bar baz"]) &&
            evilSelected "foo |bar baz" "V w v" == some ([(4, 8)], .inclusive, ["bar b"]) &&
            evilSelected "foo |bar baz" "v w v" == some ([(8, 8)], .inclusive, ["b"]) &&
            evilSelected "foo |bar baz" "V w V" == some ([(8, 8)], .inclusive, ["b"])) },
    { name :=
        "a state that keeps both ends, entered with the anchor where no cursor of it may rest, puts the anchor where the head would rest: from an exclusive selection whose anchor is at the end of a text that ends in a line feed, on the line feed, which is the last cell, for the inclusive shape and for the line shape; with both ends in the empty last row, both on the line feed; at the end of a text with no line feed, on the last character; and an anchor on a cell, a line break among them, stays"
      run :=
        pure
          (evilEntered "ab\n" .exclusive 3 1 (evilKeeping .inclusive) ==
              some ([(2, 0)], .inclusive, ["ab\n"]) &&
            evilEntered "ab\n" .exclusive 3 1 (evilKeeping .line) ==
              some ([(2, 0)], .line, ["ab\n"]) &&
            evilEntered "ab\n" .exclusive 3 3 (evilKeeping .inclusive) ==
              some ([(2, 2)], .inclusive, ["\n"]) &&
            evilEntered "ab" .exclusive 2 0 (evilKeeping .inclusive) ==
              some ([(1, 0)], .inclusive, ["ab"]) &&
            evilEntered "ab\ncd" .exclusive 2 5 (evilKeeping .inclusive) ==
              some ([(2, 4)], .inclusive, ["\ncd"])) },
    { name :=
        "a state that keeps both ends, entered from an exclusive selection, keeps the anchor and steps the head back one cell, as leaving an insert session does, whichever end is first and for the line shape too; a head at its line's start stays; and from a selection that was not exclusive the head does not step back"
      run :=
        pure
          (evilEntered "abcd" .exclusive 1 3 (evilKeeping .inclusive) ==
              some ([(1, 2)], .inclusive, ["bc"]) &&
            evilEntered "abcd" .exclusive 3 1 (evilKeeping .inclusive) ==
              some ([(3, 0)], .inclusive, ["abcd"]) &&
            evilEntered "abcd" .exclusive 1 3 (evilKeeping .line) ==
              some ([(1, 2)], .line, ["abcd"]) &&
            evilEntered "ab\ncd" .exclusive 0 3 (evilKeeping .inclusive) ==
              some ([(0, 3)], .inclusive, ["ab\nc"]) &&
            evilEntered "abcd" .inclusive 1 3 (evilKeeping .inclusive) ==
              some ([(1, 3)], .inclusive, ["bcd"])) },
    { name :=
        "a departure from Vim, recorded in keymaps-and-modes.md under Where a cursor rests: on a last line with no line feed the head of a visual selection stops on the last character, where Vim's goes one past it, since there is no cell there"
      run := pure (evilSelected "foo |bar" "v w" == some ([(4, 6)], .inclusive, ["bar"])) },
    { name :=
        "the scene's cursor and status line are the state's after each key that enters one: a visual state's after v and after V, each with its own status field, and normal state's again after <Escape>"
      run :=
        pure <|
          let looks (typed : String) : Option (Cursor × Array StatusField) :=
            (evilScene "foo |bar baz" typed).map fun seen => (seen.cursor, seen.status)
          ["v", "V", "v V", "V v", "v <Escape>", "V <Escape>", "v w v", "<Escape>"].all
              (fun typed => looks typed == some (evilLooks typed)) &&
            (evilLooks "v").2 != (evilLooks "V").2 &&
            (evilLooks "v").2 != (evilLooks "").2 &&
            evilLooks "v <Escape>" == evilLooks "" },
    { name :=
        "the wanted column is kept through v, so j in the state v enters aims for it, and is not kept through <Escape>: the next j aims for the cursor's own column"
      run :=
        evilRows
          [("j v j", "abc|d\nx\nabcd", "abcd\nx\nabc|d"),
            ("j v <Escape> j", "abc|d\nx\nabcd", "abcd\nx\n|abcd")] }]

/-- The history of the buffer 0 of `driver`, as the checks read it: how many
nodes its tree has, and whether an edit is pending in its open group. -/
def evilHistory (driver : EvilDriver) : Option (Nat × Bool) :=
  (driver.loop.state.buffer? ⟨0⟩).map fun buffer =>
    (buffer.history.nodes.size, buffer.history.pending)

/-- `driver` after one undo request of the buffer 0 (`BufferId.undo`), made
by a command the loop is handed, which says in the echo area whether there
was a step to undo: `undone` or `nothing to undo`. -/
def evilUndone (driver : EvilDriver) : EvilDriver :=
  let undo : EditorM Unit := do
    match ← (⟨0⟩ : BufferId).undo with
    | .ok (some _) =>
      message "undone"
    | _ =>
      message "nothing to undo"
  (driver.stepped (driver.loop.deliver driver.handed "undo" undo)).1

/-- What the buffer 0 of `driver` holds in the text model. -/
def evilText (driver : EvilDriver) : Option String := do
  let buffer ← driver.loop.state.buffer? ⟨0⟩
  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents)

/-- The rows of the oracle table for `i`, typed text and `<Escape>`: the
text is inserted before the cursor's cell, and `<Escape>` leaves the cursor
on the last character typed, one cell back from the bar, and where it is at
a line's start. A digit, a key a motion is bound to, a shifted letter and a
space are text in the session. -/
def insertRows : List (String × String × String) :=
  [("i X <Escape>", "ab|c", "ab|Xc"), ("i <Escape>", "a|bc", "|abc"),
    ("i <Escape>", "|abc", "|abc"), ("i <Escape>", "ab\n|cd", "ab\n|cd"),
    ("i h e l l o <Escape>", "foo |bar", "foo hell|obar"), ("i h i <Escape>", "|", "h|i"),
    ("i X <Escape>", "ab\n|\ncd", "ab\n|X\ncd"), ("i 2 w <Escape>", "a|b", "a2|wb"),
    ("i x SPC A <Escape>", "a|b", "ax |Ab"), ("i é <Escape>", "a|b", "a|éb"),
    ("i X <Escape> l l", "|abc", "Xa|bc"), ("j i <Escape> j", "abc|d\nx\nabcd", "abcd\nx\n|abcd")]

/-- The rows of the oracle table for `a`, `I` and `A`: `a` begins the insert
after the cursor's cell, also on a line's last character, and where the
cursor is on an empty line; `I` at the line's first character that is not
a blank, which on a line of blanks only is after the blanks; `A` at the
line's end, before the line break. -/
def appendRows : List (String × String × String) :=
  [("a X <Escape>", "a|bc", "ab|Xc"), ("a X <Escape>", "ab|c\ndef", "abc|X\ndef"),
    ("a X <Escape>", "|\nabc", "|X\nabc"), ("a X <Escape>", "|", "|X"),
    ("a <Escape>", "ab|c", "ab|c"), ("a <Escape>", "a|bc", "a|bc"),
    ("a X <Escape>", "a|b\r\ncd", "ab|X\r\ncd"), ("I X <Escape>", "  ab|c", "  |Xabc"),
    ("I X <Escape>", "ab|c", "|Xabc"), ("I X <Escape>", "| \t ", " \t |X"),
    ("I X <Escape>", "ab\n|\ncd", "ab\n|X\ncd"), ("I <Escape>", "  ab|c", " | abc"),
    ("A X <Escape>", "a|bc", "abc|X"), ("A X <Escape>", "a|bc\ndef", "abc|X\ndef"),
    ("A X <Escape>", "ab\n|\ncd", "ab\n|X\ncd"), ("A <Escape>", "a|bc", "ab|c"),
    ("A X <Escape>", "a|b\r\ncd", "ab|X\r\ncd")]

/-- Rows for a count typed before a key that begins an insert, which
changes nothing: the text is inserted once. Vim repeats it, which is not
built. -/
def countedInsertRows : List (String × String × String) :=
  [("3 i X <Escape>", "ab|c", "ab|Xc"), ("3 a X <Escape>", "a|bc", "ab|Xc"),
    ("2 I X <Escape>", "  ab|c", "  |Xabc"), ("2 A X <Escape>", "a|bc", "abc|X")]

/-- The rows of the oracle table for `<Backspace>` in insert state, Vim
9.1's `i_<BS>` under its default `backspace=indent,eol,start`: the
character before the bar goes, a character of two bytes whole; at a line's
start the line break before it, a carriage return and line feed whole, so
the line is joined to the one above; at the text's start nothing; and past
where the insert began. -/
def insertBackspaceRows : List (String × String × String) :=
  [("i <Backspace> <Escape>", "ab|c", "|ac"), ("i <Backspace> <Escape>", "ab\n|cd", "a|bcd"),
    ("i <Backspace> <Escape>", "ab\r\n|cd", "a|bcd"), ("i <Backspace> <Escape>", "|abc", "|abc"),
    ("i <Backspace> <Escape>", "aé|b", "|ab"),
    ("a x <Backspace> <Backspace> <Escape>", "a|bc", "|ac")]

/-- The rows of the oracle table for `C-w` in insert state, Vim 9.1's
`i_CTRL-W` under its default `backspace=indent,eol,start`: the word before
the bar goes, with the blanks between it and the bar; a run of punctuation
is a word; blanks back to the line's start go when no word is before them
on the line; at a line's start the line break before it goes, a carriage
return and line feed whole, so the line is joined to the one above; and at
the text's start nothing. -/
def insertWordDeleteRows : List (String × String × String) :=
  [("A C-w", "foo ba|r", "foo |"), ("A C-w", "f|oo   ", "|"), ("A C-w", "f|oo.bar", "foo.|"),
    ("A C-w", "f|oo..", "foo|"), ("i C-w", "  |x", "|x"), ("i C-w", "ab\n  |x", "ab\n|x"),
    ("i C-w", "ab\n|cd", "ab|cd"), ("i C-w", "|abc", "|abc"), ("i C-w", "ab\r\n|cd", "ab|cd")]

/-- The rows of the oracle table for `RET` in insert state: the line is
broken at the bar, with no indent, and the bar is at the new line's
start. -/
def insertEnterRows : List (String × String × String) :=
  [("i RET <Escape>", "ab|c", "ab\n|c"), ("A RET x <Escape>", "a|b", "ab\n|x"),
    ("i RET <Escape>", "  a|b", "  a\n|b")]

/-- The rows of the oracle table for `TAB` in insert state: a tab character
at the bar, Vim 9.1's default under `noexpandtab` and `softtabstop=0`. -/
def insertTabRows : List (String × String × String) :=
  [("i TAB <Escape>", "a|b", "a|\tb"), ("i TAB x <Escape>", "|a", "\t|xa")]

/-- The rows of the oracle table for `<ArrowLeft>` and `<ArrowRight>` in
insert state: one cell left or right, and no further than the line's start
or where its content ends, so neither wraps (Vim 9.1's default
`whichwrap=b,s`). -/
def insertSideRows : List (String × String × String) :=
  [("i <ArrowLeft> X <Escape>", "ab|c", "a|Xbc"),
    ("i <ArrowLeft> X <Escape>", "ab\n|cd", "ab\n|Xcd"),
    ("i <ArrowRight> X <Escape>", "a|bc", "ab|Xc"),
    ("i <ArrowRight> <ArrowRight> X <Escape>", "a|b\ncd", "ab|X\ncd")]

/-- The rows of the oracle table for `<ArrowUp>` and `<ArrowDown>` in insert
state: a line up or down, with the column clamped to a shorter line and
kept through one, and nothing on the first line up or the last line
down. -/
def insertVerticalRows : List (String × String × String) :=
  [("A <ArrowUp> X <Escape>", "ab\nabc|d", "ab|X\nabcd"),
    ("A <ArrowUp> <ArrowUp>", "abcd\nx\nabc|d", "abcd|\nx\nabcd"),
    ("i <ArrowUp> X <Escape>", "a|b\ncd", "a|Xb\ncd"),
    ("A <ArrowDown> X <Escape>", "abc|d\nab", "abcd\nab|X"),
    ("A <ArrowDown> <ArrowDown>", "abc|d\nx\nabcd", "abcd\nx\nabcd|"),
    ("i <ArrowDown> X <Escape>", "ab\nc|d", "ab\nc|Xd")]

/-- Whether the keys `typed`, pressed from the fixture `fixture`, leave
`text` and the steps of the history an arrow key's rule says: when `moves`
the history has gained two nodes, and two undo requests give first
`between` and then the fixture's text; otherwise it has gained one, and one
undo request gives the fixture's text. -/
def arrowStep (fixture typed text between : String) (moves : Bool) : Bool :=
  match evilDriver fixture with
  | none => false
  | some driver =>
    let typed := evilFed driver typed
    let original := (barred fixture).1
    let nodes := ((evilHistory driver).map (·.1)).getD 0
    evilText typed == some text &&
      if moves then
        evilHistory typed == some (nodes + 2, false) &&
          evilText (evilUndone typed) == some between &&
          evilText (evilUndone (evilUndone typed)) == some original
      else
        evilHistory typed == some (nodes + 1, false) && evilText (evilUndone typed) == some original

/-- The prompts the checks of a prompt's editing keys run in, each from the
fixture `a|bc` with the prompt opened and nothing typed: the minibuffer of
a prompt a command opened, whose continuation `greet` says `hello` and the
answer, and the ex line, opened with `:`, whose continuation is the ex
command, which says that a name is no ex command. Each with the name of
its continuation's command, and what the echo area says once the answer is
accepted. -/
def evilPrompts : List (Option EvilDriver × String × (String → String)) :=
  let ask : Dispatched := fun _ => do
    discard <| prompt "Name: " { command := "greet" }
    return none
  let greet : Dispatched := fun call => do
    message s!"hello {" ".intercalate (call.arguments.map argumentText)}"
    return none
  let asked :=
    (evilDriver "a|bc" (evilHanded Minibuffer.commands [("ask", ask), ("greet", greet)])).map
      fun driver => (driver.stepped (driver.loop.runNamed driver.handed "ask")).1
  let ex :=
    (evilDriver "a|bc" (evilHanded (Ex.commands ++ Minibuffer.commands))).map (evilFed · ":")
  [(asked, "greet", fun answer => s!"hello {answer}"), (ex, Ex.name, Ex.unknown)]

/-- Whether `check` holds of each prompt of `evilPrompts`, each opened as
its continuation says, with the asking view left as it was. -/
def evilPromptsHold (check : EvilDriver → (String → String) → Bool) : Bool :=
  evilPrompts.all fun
    | (some asking, command, answered) =>
      asking.loop.state.prompt.map (·.continuation.command) == some command &&
        evilShown asking == "a|bc" &&
        check asking answered
    | (none, _, _) => false

/-- The checks of evil's insert state (`Editor/Evil.lean`) on the loop's
driver over the editor's models, under the Vim scheme that ships with
evil's commands: the keys that begin an insert, typed text, and `<Escape>`,
and that one insert session is one step of the history. -/
def evilInsertChecks : List Check :=
  [{  name :=
        "i begins an insert before the cursor's cell, a key that prints is inserted at the bar, and <Escape> leaves the cursor one cell back from the bar, or where it is at a line's start; a digit and a key a motion is bound to are text in the session"
      run := evilRows insertRows },
    { name :=
        "a, I and A each begin the insert at the documented position: a after the cursor's cell, I at the line's first character that is not a blank, A at the line's end"
      run := evilRows appendRows },
    { name :=
        "a count typed before i, a, I or A changes nothing: the text typed is inserted once, where the key with no count inserts it"
      run := evilRows countedInsertRows },
    { name :=
        "<Backspace> in insert state deletes the character before the bar, a character of two bytes whole; at a line's start it joins the line to the one above, a carriage return and line feed whole; at the text's start it deletes nothing; it deletes past where the insert began; and it is one step of the history with the text typed around it"
      run := do
        let rows ← evilRows insertBackspaceRows
        let step :=
          match evilDriver "a|b" with
          | none => false
          | some driver =>
            let typed := evilFed driver "i x <Backspace> y <Escape>"
            evilText typed == some "ayb" && evilHistory typed == some (2, false) &&
              evilText (evilUndone typed) == some "ab"
        return rows && step },
    { name :=
        "C-w in insert state deletes the word before the bar and the blanks after it, a run of punctuation being a word, and blanks back to the line's start when no word is before them on the line; at a line's start it joins the line to the one above, a carriage return and line feed whole; at the text's start it deletes nothing; and it is one step of the history with the text typed around it"
      run := do
        let rows ← evilRows insertWordDeleteRows
        let step :=
          match evilDriver "a|b" with
          | none => false
          | some driver =>
            let typed := evilFed driver "i x y SPC z C-w w <Escape>"
            evilText typed == some "axy wb" && evilHistory typed == some (2, false) &&
              evilText (evilUndone typed) == some "ab"
        return rows && step },
    { name :=
        "RET in insert state breaks the line at the bar with the buffer's line ending, a line feed or, in a buffer whose lines end in a carriage return and line feed, that, with no indent; and it is one step of the history with the text typed around it"
      run := do
        let rows ← evilRows insertEnterRows
        let crlf :=
          let start : TextM EditorState := do
            let state ← evilState "abc" 2
            return { state with
                buffers := state.buffers.map (·.map ({ · with lineEnding := .crlf })) }
          match (Loop.Driver.over evilHanded (fun _ => none) start editorModel).toOption with
          | none => false
          | some driver => evilShown (evilFed driver "i RET") == "ab\r\n|c"
        let step :=
          match evilDriver "a|b" with
          | none => false
          | some driver =>
            let typed := evilFed driver "i x RET y <Escape>"
            evilText typed == some "ax\nyb" && evilHistory typed == some (2, false) &&
              evilText (evilUndone typed) == some "ab"
        return rows && crlf && step },
    { name :=
        "TAB in insert state inserts a tab character at the bar, and is one step of the history with the text typed around it"
      run := do
        let rows ← evilRows insertTabRows
        return rows && arrowStep "a|b" "i x TAB y <Escape>" "ax\tyb" "" false },
    { name :=
        "<ArrowLeft> and <ArrowRight> in insert state move the bar one cell, and stop at the line's start and where its content ends: neither wraps"
      run := evilRows insertSideRows },
    { name :=
        "<ArrowUp> and <ArrowDown> in insert state move the bar a line, with the column clamped to a shorter line and kept through one, and move nothing on the first line up and on the last line down"
      run := evilRows insertVerticalRows },
    { name :=
        "an arrow key in insert state that moves starts a new step of the history, as in Vim 9.1: what was typed before it and after it are undone separately; one that fails, <ArrowLeft> at a line's start, <ArrowRight> where its content ends, <ArrowUp> on the first line and <ArrowDown> on the last, does not break the session's step"
      run :=
        pure <|
          arrowStep "a|b" "i x <ArrowLeft> y <Escape>" "ayxb" "axb" true &&
            arrowStep "a|bc" "i x <ArrowRight> y <Escape>" "axbyc" "axbc" true &&
            arrowStep "ab\na|b" "i x <ArrowUp> y <Escape>" "aby\naxb" "ab\naxb" true &&
            arrowStep "a|b\nab" "i x <ArrowDown> y <Escape>" "axb\naby" "axb\nab" true &&
            arrowStep "ab\n|cd" "i <ArrowLeft> x <Escape>" "ab\nxcd" "" false &&
            arrowStep "ab|c" "i RET <ArrowLeft> x <Escape>" "ab\nxc" "" false &&
            arrowStep "a|b" "A x <ArrowRight> y <Escape>" "abxy" "" false &&
            arrowStep "a|b\ncd" "i x <ArrowUp> y <Escape>" "axyb\ncd" "" false &&
            arrowStep "ab\nc|d" "i x <ArrowDown> y <Escape>" "ab\ncxyd" "" false },
    { name :=
        "i, typed text and <Escape>: the text is inserted at the cursor, the history has gained one node for the whole session and none inside it, one undo request gives the text from before the session, and a second finds nothing to undo"
      run :=
        pure <|
          match evilDriver "foo |bar" with
          | none => false
          | some driver =>
            let typing := evilFed driver "i h e l l o"
            let typed := evilFed typing "<Escape>"
            let undone := evilUndone typed
            let again := evilUndone undone
            evilHistory driver == some (1, false) && evilHistory typing == some (1, true) &&
              evilText typing == some "foo hellobar" &&
              evilHistory typed == some (2, false) &&
              evilText typed == some "foo hellobar" &&
              undone.loop.state.echo == "undone" &&
              evilText undone == some "foo bar" &&
              again.loop.state.echo == "nothing to undo" &&
              evilText again == some "foo bar" },
    { name :=
        "two insert sessions are two steps of the history: an undo request after the second gives the text from after the first"
      run :=
        pure <|
          match evilDriver "a|b" with
          | none => false
          | some driver =>
            let typed := evilFed driver "i x y <Escape> i z <Escape>"
            evilText typed == some "axzyb" && evilHistory typed == some (3, false) &&
              evilText (evilUndone typed) == some "axyb" &&
              evilText (evilUndone (evilUndone typed)) == some "ab" },
    { name :=
        "the scene shows the state: before i and after <Escape> a block, normal state's status field and one inclusive selection; inside the session a bar, insert state's status field and one exclusive selection at the bar, with the modified field once something is typed"
      run :=
        pure <|
          let seen (typed : String) : Option EvilSeen := evilScene "foo |bar" typed
          let modified : StatusField := evilMark
          let insert := vimDefaultReport "i"
          let normal := vimDefaultReport ""
          seen "<F5>" ==
              some
                { selection := { ranges := #[⟨4, 4⟩], shape := .inclusive }, covered := #["b"]
                  cursor := (evilLooks "").1, status := (evilLooks "").2 } &&
            seen "i" ==
              some
                { selection := { ranges := #[⟨4, 4⟩], shape := .exclusive }, covered := #[""]
                  cursor := (evilLooks "i").1, status := (evilLooks "i").2 } &&
            seen "i h" ==
              some
                { selection := { ranges := #[⟨5, 5⟩], shape := .exclusive }, covered := #[""]
                  cursor := (evilLooks "i").1, status := (evilLooks "i").2.push modified } &&
            seen "i h <Escape>" ==
              some
                { selection := { ranges := #[⟨4, 4⟩], shape := .inclusive }, covered := #["h"]
                  cursor := (evilLooks "").1, status := (evilLooks "").2.push modified } &&
            insert.cursor.shape == .bar &&
            normal.cursor.shape == .block &&
            insert.cursor != normal.cursor &&
            insert.status != normal.status },
    { name :=
        "a key that prints, typed while a prompt is open, is inserted in the minibuffer and not in the asking view; RET then accepts, and the command the prompt named is run with what was typed"
      run :=
        pure <|
          let ask : Dispatched := fun _ => do
            discard <| prompt "Name: " { command := "greet" }
            return none
          let greet : Dispatched := fun call => do
            message s!"hello {" ".intercalate (call.arguments.map argumentText)}"
            return none
          let handed := evilHanded Minibuffer.commands [("ask", ask), ("greet", greet)]
          match evilDriver "a|bc" handed with
          | none => false
          | some driver =>
            let (asking, _) := driver.stepped (driver.loop.runNamed driver.handed "ask")
            let typing := evilFed asking "A d a 7"
            let answered := evilFed typing "RET"
            asking.loop.state.frame.focused == ⟨1⟩ && evilShown typing ⟨1⟩ == "Ada7|" &&
              evilShown typing == "a|bc" &&
              answered.loop.state.prompt.isNone &&
              answered.loop.state.echo == "hello Ada7" &&
              evilShown answered == "a|bc" },
    { name :=
        "<Backspace>, typed while a prompt is open, deletes the character before the minibuffer's bar, a character of two bytes whole, and RET then accepts what is left; with the bar at the start of a text it deletes nothing; on an empty minibuffer it closes the prompt as <Escape> does, and the command the prompt named is not run; its command run by name with no prompt open says so in the echo area"
      run :=
        pure <|
          let ask : Dispatched := fun _ => do
            discard <| prompt "Name: " { command := "greet" }
            return none
          let greet : Dispatched := fun call => do
            message s!"hello {" ".intercalate (call.arguments.map argumentText)}"
            return none
          let home : Dispatched := fun call => do
            call.target.select { ranges := #[⟨0, 0⟩], shape := .exclusive }
            return none
          let handed :=
            evilHanded Minibuffer.commands [("ask", ask), ("greet", greet), ("home", home)]
          match evilDriver "a|bc" handed with
          | none => false
          | some driver =>
            let (asking, _) := driver.stepped (driver.loop.runNamed driver.handed "ask")
            let typing := evilFed asking "A d é 7"
            let erased := evilFed typing "<Backspace> <Backspace>"
            let answered := evilFed erased "RET"
            let (homed, _) := typing.stepped (typing.loop.runNamed typing.handed "home")
            let atStart := evilFed homed "<Backspace>"
            let emptied := evilFed typing "<Backspace> <Backspace> <Backspace> <Backspace>"
            let closed := evilFed emptied "<Backspace>"
            let (unasked, _) :=
              driver.stepped (driver.loop.runNamed driver.handed Minibuffer.deleteBackwardName)
            unasked.loop.state.echo == Minibuffer.notOpen && evilShown unasked == "a|bc" &&
              evilShown erased ⟨1⟩ == "Ad|" &&
              evilShown erased == "a|bc" &&
              answered.loop.state.prompt.isNone &&
              answered.loop.state.echo == "hello Ad" &&
              evilShown atStart ⟨1⟩ == "|Adé7" &&
              atStart.loop.state.prompt.isSome &&
              evilShown emptied ⟨1⟩ == "|" &&
              emptied.loop.state.prompt.isSome &&
              closed.loop.state.prompt.isNone &&
              closed.loop.state.frame.focused == ⟨0⟩ &&
              closed.loop.state.echo == "" &&
              evilShown closed == "a|bc" },
    { name :=
        "<ArrowLeft>, typed while a prompt is open, the minibuffer's and the ex line's, moves the minibuffer's bar one character back, and no further than the input's start; text typed then is inserted there, and RET accepts the whole input; the asking view is as it was"
      run :=
        pure <|
          evilPromptsHold fun asking answered =>
            let moved := evilFed asking "A d a <ArrowLeft> <ArrowLeft>"
            let answer := evilFed moved "x RET"
            let atStart := evilFed moved "<ArrowLeft> <ArrowLeft>"
            evilShown moved ⟨1⟩ == "A|da" && evilShown moved == "a|bc" &&
              evilShown atStart ⟨1⟩ == "|Ada" &&
              atStart.loop.state.prompt.isSome &&
              answer.loop.state.prompt.isNone &&
              answer.loop.state.echo == answered "Axda" &&
              evilShown answer == "a|bc" },
    { name :=
        "<ArrowRight>, typed while a prompt is open, the minibuffer's and the ex line's, moves the minibuffer's bar one character on, and no further than the input's end; text typed then is inserted there, and RET accepts the whole input"
      run :=
        pure <|
          evilPromptsHold fun asking answered =>
            let back := evilFed asking "A d a <ArrowLeft> <ArrowLeft>"
            let moved := evilFed back "<ArrowRight>"
            let atEnd := evilFed back "<ArrowRight> <ArrowRight> <ArrowRight>"
            let answer := evilFed moved "y RET"
            evilShown moved ⟨1⟩ == "Ad|a" && evilShown atEnd ⟨1⟩ == "Ada|" &&
              atEnd.loop.state.prompt.isSome &&
              answer.loop.state.echo == answered "Adya" &&
              evilShown answer == "a|bc" },
    { name :=
        "C-u, typed while a prompt is open, the minibuffer's and the ex line's, deletes from the minibuffer's bar to the input's start and keeps what is after the bar, and RET accepts what is left; with the bar at the start it deletes nothing; on an empty minibuffer it leaves the prompt open, unlike <Backspace>; its command run by name with no prompt open says so in the echo area"
      run :=
        pure <|
          let held :=
            evilPromptsHold fun asking answered =>
              let cleared := evilFed asking "A d a <ArrowLeft> C-u"
              let answer := evilFed cleared "RET"
              let atStart := evilFed asking "A d a <ArrowLeft> <ArrowLeft> <ArrowLeft> C-u"
              let empty := evilFed asking "C-u"
              evilShown cleared ⟨1⟩ == "|a" && cleared.loop.state.prompt.isSome &&
                answer.loop.state.prompt.isNone &&
                answer.loop.state.echo == answered "a" &&
                evilShown atStart ⟨1⟩ == "|Ada" &&
                evilShown empty ⟨1⟩ == "|" &&
                empty.loop.state.prompt.isSome &&
                evilShown cleared == "a|bc"
          let unasked :=
            match evilDriver "a|bc" (evilHanded Minibuffer.commands) with
            | none => false
            | some driver =>
              let (ran, _) :=
                driver.stepped (driver.loop.runNamed driver.handed Minibuffer.deleteToStartName)
              ran.loop.state.echo == Minibuffer.notOpen && evilShown ran == "a|bc"
          held && unasked },
    { name :=
        "the command typed text runs, called with no string as its first argument, inserts nothing and says so in the echo area"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let (ran, _) :=
              driver.stepped (driver.loop.runNamed driver.handed Vim.selfInsertCommand)
            ran.loop.state.echo == Evil.noText && !Evil.noText.isEmpty && evilShown ran == "a|bc" &&
              evilHistory ran == some (1, false) },
    { name :=
        "a text an input method commits in normal state is not inserted: the text, the cursor and the history are as they were; committed inside an insert session it is inserted at the bar, and is one step of the history with what was typed"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let commit (driver : EvilDriver) (text : String) : EvilDriver :=
              (driver.feed { event := .commit text, stamp := 0 }).1
            let ignored := commit driver "xy"
            let typed := evilFed (commit (evilFed driver "i x") "yz") "w"
            let ended := evilFed typed "<Escape>"
            evilShown ignored == "a|bc" && evilHistory ignored == some (1, false) &&
              evilShown typed == "axyzw|bc" &&
              evilHistory typed == some (1, true) &&
              evilShown ended == "axyz|wbc" &&
              evilHistory ended == some (2, false) &&
              evilText (evilUndone ended) == some "abc" }]

/-- What the unnamed register holds before the keys of an operator's row:
a text no row yields, so that a register the keys left as it was is seen. -/
def evilSentinel : Register :=
  { text := "the sentinel", linewise := true }

/-- What the keys of an operator's row left, as the checks read it. -/
structure EvilEdited where
  /-- The buffer's text with a bar at the head of the selection's primary
  range. -/
  shown : String
  /-- The unnamed register; `none` when it is as it was before the keys. -/
  register : Option Register
  /-- Whether the scene's status line says the view is in insert state: its
  first field, the mode line's badge, is the one the scheme reports of that
  state. -/
  insert : Bool
  /-- What the echo area says. -/
  echo : String
  deriving DecidableEq, Repr

/-- A driver of the evil checks over the state the fixture `fixture` says,
with the unnamed register holding `evilSentinel`, on the models `model`. -/
def evilRegistered (fixture : String) (model : EditorModel := editorModel) : Option EvilDriver :=
  let (contents, head) := barred fixture
  (Loop.Driver.over evilHanded (fun _ => none)
      (do
        return (← evilState contents head).setRegister Evil.unnamed evilSentinel)
      model).toOption

/-- What `driver`, made by `evilRegistered`, shows after its keys. -/
def evilLeft (driver : EvilDriver) : EvilEdited :=
  let register := driver.loop.state.register? Evil.unnamed
  { shown := evilShown driver
    register := if register == some evilSentinel then none else register
    insert :=
      let badge (field : StatusField) := (field.text, field.face)
      ((evilSeen driver).bind (·.status[0]?)).map badge ==
          (vimDefaultReport "i").status[0]?.map badge &&
        (vimDefaultReport "i").status[0]? != (vimDefaultReport "").status[0]?
    echo := driver.loop.state.echo }

/-- The keys the key string `typed` names, pressed under the Vim scheme that
ships with evil's commands, from the text and the cursor `fixture` says,
with the unnamed register holding a sentinel: what they left. -/
def evilEdited (fixture typed : String) : Option EvilEdited :=
  (evilRegistered fixture).map fun driver => evilLeft (evilFed driver typed)

/-- The operate command called with `arguments`, as an invocation no key
yielded, from the text and the cursor `fixture` says: what it left. -/
def evilOperated (fixture : String) (arguments : List Argument) : Option EvilEdited :=
  (evilRegistered fixture).map fun driver =>
    evilLeft
      (driver.stepped
          (driver.loop.invoke driver.handed { command := Vim.operateCommand, arguments })).1

/-- A register's text that is not line-wise, as a row expects it. -/
def charwise (text : String) : Option Register :=
  some { text }

/-- A register's text that is line-wise, as a row expects it. -/
def linewise (text : String) : Option Register :=
  some { text, linewise := true }

/-- The register a row expects its keys to leave as it was. -/
def asItWas : Option Register :=
  none

/-- The text objects source of the test mode the tree's text objects are
checked under, in the model's query subset over its JSON grammar: an object
is a function and inside one, an array a class and inside one, and a pair
and an array's item an argument. -/
def jsonTextObjects : String :=
  "(object) @function.outer\n(object) @function.inner\n(array) @class.outer\n(array) @class.inner\n(pair) @parameter.inner\n(array (_) @parameter.inner)"

/-- The text objects source of a second test mode, in the model's query
subset over its JSON grammar, whose insides are smaller than their nodes: a
pair is a function, and inside one the object it holds, and a class, and
inside one the array it holds. A cursor on a pair's key is in the node and
outside its inside. -/
def jsonPairObjects : String :=
  "(pair) @function.outer\n(pair (object) @function.inner)\n(pair) @class.outer\n(pair (array) @class.inner)"

/-- A driver of the evil checks over the state the fixture `fixture` says,
with the unnamed register holding `evilSentinel`, whose buffer's text is
entered in a test mode of the model's JSON grammar that keeps the text
objects source `textObjects`, `jsonTextObjects` unless another is given, on
the editor's models. -/
def treeRegistered (fixture : String) (textObjects : String := jsonTextObjects) :
    Option EvilDriver :=
  let (contents, head) := barred fixture
  let prepared : EditorM EditorState := do
    let state ← evilState contents head
    if let some (some buffer) := state.buffers[0]? then
      Highlight.enter "json-objects" buffer.text
          { grammar := "json", textObjects := some textObjects }
    return state.setRegister Evil.unnamed evilSentinel
  match prepared.runModel editorModel with
  | (.ok state, model) => (Loop.Driver.over evilHanded (fun _ => none) (pure state) model).toOption
  | (.error _, _) => none

/-- The selection the scene shows after the keys `typed`, pressed from the
fixture `fixture` on `treeRegistered`: its ranges, as an anchor and a head
each, its shape, and the text each range covers. -/
def treeSelected (fixture typed : String) : Option (List (Nat × Nat) × Shape × List String) :=
  ((treeRegistered fixture).bind fun driver => evilSeen (evilFed driver typed)).map fun seen =>
    ((seen.selection.ranges.map fun range => (range.anchor, range.head)).toList,
      seen.selection.shape, seen.covered.toList)

/-- The test language of the indent checks: the model's JSON grammar with
`jsonIndents` and `jsonTextObjects`, indented by two spaces. -/
def modelJsonIndented : Language :=
  { name := "model-json", patterns := [.extension "json"]
    syntaxTree :=
      { grammar := "json", indents := some jsonIndents, textObjects := some jsonTextObjects }
    indentUnit := .spaces 2 }

/-- What a step of the indent checks is handed: evil's commands
(`evilHanded`), with the `code` mode and `languages` registered as compiled
code registers them, and `config` registered for config. -/
def indentHanded (languages : Array Language) (config : Array Language := #[]) :
    Loop.Keys Vim.Default.scheme :=
  { evilHanded with
    registered :=
      (((({} : Config.Registry).replaceModes .compiled Language.modes).replaceLanguages .compiled
              languages).replaceLanguages
          .config config).registered }

/-- A driver of the indent checks over the state the fixture `fixture` says,
with the unnamed register holding `evilSentinel`, whose buffer's language
is `language`, `modelJsonIndented` unless another is given, and whose text
is entered in its tree; the table registers `language`, and `config` for
config. On the editor's models. -/
def indentDriver (fixture : String) (language : Language := modelJsonIndented)
    (config : Array Language := #[]) : Option EvilDriver :=
  let (contents, head) := barred fixture
  let prepared : EditorM EditorState := do
    let state ← evilState contents head
    let named := some language.name
    let state : EditorState :=
      { state with buffers := state.buffers.map (·.map ({ · with language := named })) }
    if let some (some buffer) := state.buffers[0]? then
      Highlight.enter Language.codeName buffer.text language.syntaxTree
    return state.setRegister Evil.unnamed evilSentinel
  match prepared.runModel editorModel with
  | (.ok state, model) =>
    (Loop.Driver.over (indentHanded #[language] config) (fun _ => none) (pure state) model).toOption
  | (.error _, _) => none

/-- The keys `typed` pressed from `fixture` on `indentDriver`: what they
left. -/
def indentEdited (fixture typed : String) (language : Language := modelJsonIndented)
    (config : Array Language := #[]) : Option EvilEdited :=
  (indentDriver fixture language config).map fun driver => evilLeft (evilFed driver typed)

/-- `indentDriver` over `fixture`, its syntax tree model saying the tree of
the text's last edit is not delivered (`SyntaxTreeModel.delivered`): what a
command meets when keys come faster than a reparse. -/
def undeliveredDriver (fixture : String) : Option EvilDriver :=
  (indentDriver fixture).map fun driver =>
    { driver with
      model :=
        { driver.model with syntaxTree := { driver.model.syntaxTree with delivered := false } } }

/-- The keys `typed` pressed from `fixture` on `undeliveredDriver`: what
they left. -/
def undeliveredEdited (fixture typed : String) : Option EvilEdited :=
  (undeliveredDriver fixture).map fun driver => evilLeft (evilFed driver typed)

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

/-- The text and the cursor of the oracle table's first two situations: a
cursor in the middle of a line that has words, punctuation and an indent,
with lines above and below. -/
def plainText : String :=
  "ab\ncd\n  ef |gh.ij kl\nmn\nop\n"

/-- The text and the cursor of the oracle table's third situation: a cursor
on an empty line. -/
def emptyLineText : String :=
  "ab cd\n|\n  ef gh\n"

/-- The text and the cursor of the oracle table's fourth situation: a cursor
on the last character of a buffer that ends in a line feed. -/
def endText : String :=
  "ab cd\n  ef g|h\n"

/-- The text and the cursor of the oracle table's fifth situation: a cursor
on the last character of a buffer with no final line feed. -/
def bareEndText : String :=
  "ab cd\n  ef g|h"

/-- The oracle table's rows for `d` over `h`, `l`, `0` and `^`, in its five
situations: no count, a count of 2, on an empty line, and on the buffer's
last character with and without a final line feed. `0` takes no count of
its own, so its counted row has the count before the operator. -/
def deleteAlongRows : List OperatorRow :=
  [.rests plainText "d h" "ab\ncd\n  ef|gh.ij kl\nmn\nop\n" (charwise " "),
    .rests plainText "d l" "ab\ncd\n  ef |h.ij kl\nmn\nop\n" (charwise "g"),
    .rests plainText "d 0" "ab\ncd\n|gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .rests plainText "d ^" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "d 2 h" "ab\ncd\n  e|gh.ij kl\nmn\nop\n" (charwise "f "),
    .rests plainText "d 2 l" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "2 d 0" "ab\ncd\n|gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .rests plainText "d 2 ^" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests emptyLineText "d h" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "d l" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "d 0" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "d ^" "ab cd\n|\n  ef gh\n" asItWas,
    .rests endText "d h" "ab cd\n  ef |h\n" (charwise "g"),
    .rests endText "d l" "ab cd\n  ef |g\n" (charwise "h"),
    .rests endText "d 0" "ab cd\n|h\n" (charwise "  ef g"),
    .rests endText "d ^" "ab cd\n  |h\n" (charwise "ef g"),
    .rests bareEndText "d h" "ab cd\n  ef |h" (charwise "g"),
    .rests bareEndText "d l" "ab cd\n  ef |g" (charwise "h"),
    .rests bareEndText "d 0" "ab cd\n|h" (charwise "  ef g"),
    .rests bareEndText "d ^" "ab cd\n  |h" (charwise "ef g")]

/-- The oracle table's rows for `c` and `y` over `h`, `l`, `0` and `^`, in
its five situations. A yank leaves the cursor at the start of what it took,
and a change leaves the bar there, in insert state. Over no cell `y`
empties the register and `c` leaves it as it was. -/
def yankChangeAlongRows : List OperatorRow :=
  [.inserts plainText "c h" "ab\ncd\n  ef|gh.ij kl\nmn\nop\n" (charwise " "),
    .rests plainText "y h" "ab\ncd\n  ef| gh.ij kl\nmn\nop\n" (charwise " "),
    .inserts plainText "c l" "ab\ncd\n  ef |h.ij kl\nmn\nop\n" (charwise "g"),
    .rests plainText "y l" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "g"),
    .inserts plainText "c 0" "ab\ncd\n|gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .rests plainText "y 0" "ab\ncd\n|  ef gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .inserts plainText "c ^" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "y ^" "ab\ncd\n  |ef gh.ij kl\nmn\nop\n" (charwise "ef "),
    .inserts plainText "c 2 h" "ab\ncd\n  e|gh.ij kl\nmn\nop\n" (charwise "f "),
    .rests plainText "y 2 h" "ab\ncd\n  e|f gh.ij kl\nmn\nop\n" (charwise "f "),
    .inserts plainText "c 2 l" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "y 2 l" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh"),
    .inserts plainText "2 c 0" "ab\ncd\n|gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .rests plainText "2 y 0" "ab\ncd\n|  ef gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .inserts plainText "c 2 ^" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "y 2 ^" "ab\ncd\n  |ef gh.ij kl\nmn\nop\n" (charwise "ef "),
    .inserts emptyLineText "c h" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "y h" "ab cd\n|\n  ef gh\n" (charwise ""),
    .inserts emptyLineText "c l" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "y l" "ab cd\n|\n  ef gh\n" (charwise ""),
    .inserts emptyLineText "c 0" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "y 0" "ab cd\n|\n  ef gh\n" (charwise ""),
    .inserts emptyLineText "c ^" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "y ^" "ab cd\n|\n  ef gh\n" (charwise ""),
    .inserts endText "c h" "ab cd\n  ef |h\n" (charwise "g"),
    .rests endText "y h" "ab cd\n  ef |gh\n" (charwise "g"),
    .inserts endText "c l" "ab cd\n  ef g|\n" (charwise "h"),
    .rests endText "y l" "ab cd\n  ef g|h\n" (charwise "h"),
    .inserts endText "c 0" "ab cd\n|h\n" (charwise "  ef g"),
    .rests endText "y 0" "ab cd\n|  ef gh\n" (charwise "  ef g"),
    .inserts endText "c ^" "ab cd\n  |h\n" (charwise "ef g"),
    .rests endText "y ^" "ab cd\n  |ef gh\n" (charwise "ef g"),
    .inserts bareEndText "c h" "ab cd\n  ef |h" (charwise "g"),
    .rests bareEndText "y h" "ab cd\n  ef |gh" (charwise "g"),
    .inserts bareEndText "c l" "ab cd\n  ef g|" (charwise "h"),
    .rests bareEndText "y l" "ab cd\n  ef g|h" (charwise "h"),
    .inserts bareEndText "c 0" "ab cd\n|h" (charwise "  ef g"),
    .rests bareEndText "y 0" "ab cd\n|  ef gh" (charwise "  ef g"),
    .inserts bareEndText "c ^" "ab cd\n  |h" (charwise "ef g"),
    .rests bareEndText "y ^" "ab cd\n  |ef gh" (charwise "ef g")]

/-- The oracle table's rows for the three operators over `$`, in its five
situations. With a count it reaches the end of a line below, and the line
breaks between are taken. On an empty line `c $` empties the register where
`d $` leaves it. -/
def lineEndRows : List OperatorRow :=
  [.rests plainText "d $" "ab\ncd\n  ef| \nmn\nop\n" (charwise "gh.ij kl"),
    .inserts plainText "c $" "ab\ncd\n  ef |\nmn\nop\n" (charwise "gh.ij kl"),
    .rests plainText "y $" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij kl"),
    .rests plainText "d 2 $" "ab\ncd\n  ef| \nop\n" (charwise "gh.ij kl\nmn"),
    .inserts plainText "c 2 $" "ab\ncd\n  ef |\nop\n" (charwise "gh.ij kl\nmn"),
    .rests plainText "y 2 $" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij kl\nmn"),
    .rests emptyLineText "d $" "ab cd\n|\n  ef gh\n" asItWas,
    .inserts emptyLineText "c $" "ab cd\n|\n  ef gh\n" (charwise ""),
    .rests emptyLineText "y $" "ab cd\n|\n  ef gh\n" (charwise ""),
    .rests endText "d $" "ab cd\n  ef |g\n" (charwise "h"),
    .inserts endText "c $" "ab cd\n  ef g|\n" (charwise "h"),
    .rests endText "y $" "ab cd\n  ef g|h\n" (charwise "h"),
    .rests bareEndText "d $" "ab cd\n  ef |g" (charwise "h"),
    .inserts bareEndText "c $" "ab cd\n  ef g|" (charwise "h"),
    .rests bareEndText "y $" "ab cd\n  ef g|h" (charwise "h")]

/-- The oracle table's rows for the three operators over `e`, `E`, `b` and
`B`, in its five situations. A motion to a word's end takes that end's
cell. A backward motion that stops at a line's start, from another line,
stops where the line before ends. -/
def wordEndBackRows : List OperatorRow :=
  [.rests plainText "d b" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .inserts plainText "c b" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "y b" "ab\ncd\n  |ef gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "d e" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .inserts plainText "c e" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "y e" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "d B" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .inserts plainText "c B" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "y B" "ab\ncd\n  |ef gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "d E" "ab\ncd\n  ef | kl\nmn\nop\n" (charwise "gh.ij"),
    .inserts plainText "c E" "ab\ncd\n  ef | kl\nmn\nop\n" (charwise "gh.ij"),
    .rests plainText "y E" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij"),
    .rests plainText "d 2 b" "ab\n|gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .inserts plainText "c 2 b" "ab\n|gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .rests plainText "y 2 b" "ab\n|cd\n  ef gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .rests plainText "d 2 e" "ab\ncd\n  ef |ij kl\nmn\nop\n" (charwise "gh."),
    .inserts plainText "c 2 e" "ab\ncd\n  ef |ij kl\nmn\nop\n" (charwise "gh."),
    .rests plainText "y 2 e" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh."),
    .rests plainText "d 2 B" "ab\n|gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .inserts plainText "c 2 B" "ab\n|gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .rests plainText "y 2 B" "ab\n|cd\n  ef gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .rests plainText "d 2 E" "ab\ncd\n  ef| \nmn\nop\n" (charwise "gh.ij kl"),
    .inserts plainText "c 2 E" "ab\ncd\n  ef |\nmn\nop\n" (charwise "gh.ij kl"),
    .rests plainText "y 2 E" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij kl"),
    .rests emptyLineText "d b" "ab| \n\n  ef gh\n" (charwise "cd"),
    .inserts emptyLineText "c b" "ab |\n\n  ef gh\n" (charwise "cd"),
    .rests emptyLineText "y b" "ab |cd\n\n  ef gh\n" (charwise "cd"),
    .rests emptyLineText "d e" "ab cd\n| gh\n" (charwise "\n  ef"),
    .inserts emptyLineText "c e" "ab cd\n| gh\n" (charwise "\n  ef"),
    .rests emptyLineText "y e" "ab cd\n|\n  ef gh\n" (charwise "\n  ef"),
    .rests emptyLineText "d B" "ab| \n\n  ef gh\n" (charwise "cd"),
    .inserts emptyLineText "c B" "ab |\n\n  ef gh\n" (charwise "cd"),
    .rests emptyLineText "y B" "ab |cd\n\n  ef gh\n" (charwise "cd"),
    .rests emptyLineText "d E" "ab cd\n| gh\n" (charwise "\n  ef"),
    .inserts emptyLineText "c E" "ab cd\n| gh\n" (charwise "\n  ef"),
    .rests emptyLineText "y E" "ab cd\n|\n  ef gh\n" (charwise "\n  ef"),
    .rests endText "d b" "ab cd\n  ef |h\n" (charwise "g"),
    .inserts endText "c b" "ab cd\n  ef |h\n" (charwise "g"),
    .rests endText "y b" "ab cd\n  ef |gh\n" (charwise "g"),
    .rests endText "d e" "ab cd\n  ef |g\n" (charwise "h"),
    .inserts endText "c e" "ab cd\n  ef g|\n" (charwise "h"),
    .rests endText "y e" "ab cd\n  ef g|h\n" (charwise "h"),
    .rests endText "d B" "ab cd\n  ef |h\n" (charwise "g"),
    .inserts endText "c B" "ab cd\n  ef |h\n" (charwise "g"),
    .rests endText "y B" "ab cd\n  ef |gh\n" (charwise "g"),
    .rests endText "d E" "ab cd\n  ef |g\n" (charwise "h"),
    .inserts endText "c E" "ab cd\n  ef g|\n" (charwise "h"),
    .rests endText "y E" "ab cd\n  ef g|h\n" (charwise "h"),
    .rests bareEndText "d b" "ab cd\n  ef |h" (charwise "g"),
    .inserts bareEndText "c b" "ab cd\n  ef |h" (charwise "g"),
    .rests bareEndText "y b" "ab cd\n  ef |gh" (charwise "g"),
    .rests bareEndText "d e" "ab cd\n  ef |g" (charwise "h"),
    .inserts bareEndText "c e" "ab cd\n  ef g|" (charwise "h"),
    .rests bareEndText "y e" "ab cd\n  ef g|h" (charwise "h"),
    .rests bareEndText "d B" "ab cd\n  ef |h" (charwise "g"),
    .inserts bareEndText "c B" "ab cd\n  ef |h" (charwise "g"),
    .rests bareEndText "y B" "ab cd\n  ef |gh" (charwise "g"),
    .rests bareEndText "d E" "ab cd\n  ef |g" (charwise "h"),
    .inserts bareEndText "c E" "ab cd\n  ef g|" (charwise "h"),
    .rests bareEndText "y E" "ab cd\n  ef g|h" (charwise "h")]

/-- The oracle table's rows for `d` and `y` over `w` and `W`, in its five
situations. Under an operator the last word moved over ends the stretch
where its line's content ends, and from an empty line the stretch is that
line. -/
def wordForwardRows : List OperatorRow :=
  [.rests plainText "d w" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "y w" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "d W" "ab\ncd\n  ef |kl\nmn\nop\n" (charwise "gh.ij "),
    .rests plainText "y W" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij "),
    .rests plainText "d 2 w" "ab\ncd\n  ef |ij kl\nmn\nop\n" (charwise "gh."),
    .rests plainText "y 2 w" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh."),
    .rests plainText "d 2 W" "ab\ncd\n  ef| \nmn\nop\n" (charwise "gh.ij kl"),
    .rests plainText "y 2 W" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij kl"),
    .rests emptyLineText "d w" "ab cd\n  |ef gh\n" (linewise "\n"),
    .rests emptyLineText "y w" "ab cd\n|\n  ef gh\n" (linewise "\n"),
    .rests emptyLineText "d W" "ab cd\n  |ef gh\n" (linewise "\n"),
    .rests emptyLineText "y W" "ab cd\n|\n  ef gh\n" (linewise "\n"),
    .rests endText "d w" "ab cd\n  ef |g\n" (charwise "h"),
    .rests endText "y w" "ab cd\n  ef g|h\n" (charwise "h"),
    .rests endText "d W" "ab cd\n  ef |g\n" (charwise "h"),
    .rests endText "y W" "ab cd\n  ef g|h\n" (charwise "h"),
    .rests bareEndText "d w" "ab cd\n  ef |g" (charwise "h"),
    .rests bareEndText "y w" "ab cd\n  ef g|h" (charwise "h"),
    .rests bareEndText "d W" "ab cd\n  ef |g" (charwise "h"),
    .rests bareEndText "y W" "ab cd\n  ef g|h" (charwise "h")]

/-- The oracle table's rows for `c` over `w` and `W`, in its five
situations. On a cell that is not a blank a change goes to the end of the
word and not to the next word's start. -/
def changeWordRows : List OperatorRow :=
  [.inserts plainText "c w" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .inserts plainText "c W" "ab\ncd\n  ef | kl\nmn\nop\n" (charwise "gh.ij"),
    .inserts plainText "c 2 w" "ab\ncd\n  ef |ij kl\nmn\nop\n" (charwise "gh."),
    .inserts plainText "c 2 W" "ab\ncd\n  ef |\nmn\nop\n" (charwise "gh.ij kl"),
    .inserts emptyLineText "c w" "ab cd\n|\n  ef gh\n" (linewise "\n"),
    .inserts emptyLineText "c W" "ab cd\n|\n  ef gh\n" (linewise "\n"),
    .inserts endText "c w" "ab cd\n  ef g|\n" (charwise "h"),
    .inserts endText "c W" "ab cd\n  ef g|\n" (charwise "h"),
    .inserts bareEndText "c w" "ab cd\n  ef g|" (charwise "h"),
    .inserts bareEndText "c W" "ab cd\n  ef g|" (charwise "h")]

/-- The oracle table's rows for the three operators over `j`, `k`, `g g`
and `G`, in its five situations: each takes whole lines. On the buffer's
last line `j` fails, and the operator gives up. -/
def lineMotionRows : List OperatorRow :=
  [.rests plainText "d j" "ab\ncd\n|op\n" (linewise "  ef gh.ij kl\nmn\n"),
    .inserts plainText "c j" "ab\ncd\n|\nop\n" (linewise "  ef gh.ij kl\nmn\n"),
    .rests plainText "y j" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (linewise "  ef gh.ij kl\nmn\n"),
    .rests plainText "d k" "ab\n|mn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .inserts plainText "c k" "ab\n|\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests plainText "y k" "ab\nc|d\n  ef gh.ij kl\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests plainText "d g g" "|mn\nop\n" (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .inserts plainText "c g g" "|\nmn\nop\n" (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .rests plainText "y g g" "|ab\ncd\n  ef gh.ij kl\nmn\nop\n"
      (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .rests plainText "d G" "ab\n|cd\n" (linewise "  ef gh.ij kl\nmn\nop\n"),
    .inserts plainText "c G" "ab\ncd\n|\n" (linewise "  ef gh.ij kl\nmn\nop\n"),
    .rests plainText "y G" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (linewise "  ef gh.ij kl\nmn\nop\n"),
    .rests plainText "d 2 j" "ab\n|cd\n" (linewise "  ef gh.ij kl\nmn\nop\n"),
    .inserts plainText "c 2 j" "ab\ncd\n|\n" (linewise "  ef gh.ij kl\nmn\nop\n"),
    .rests plainText "y 2 j" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n"
      (linewise "  ef gh.ij kl\nmn\nop\n"),
    .rests plainText "d 2 k" "|mn\nop\n" (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .inserts plainText "c 2 k" "|\nmn\nop\n" (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .rests plainText "y 2 k" "a|b\ncd\n  ef gh.ij kl\nmn\nop\n"
      (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .rests plainText "d 2 g g" "ab\n|mn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .inserts plainText "c 2 g g" "ab\n|\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests plainText "y 2 g g" "ab\n|cd\n  ef gh.ij kl\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests plainText "d 2 G" "ab\n|mn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .inserts plainText "c 2 G" "ab\n|\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests plainText "y 2 G" "ab\n|cd\n  ef gh.ij kl\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests emptyLineText "d j" "|ab cd\n" (linewise "\n  ef gh\n"),
    .inserts emptyLineText "c j" "ab cd\n|\n" (linewise "\n  ef gh\n"),
    .rests emptyLineText "y j" "ab cd\n|\n  ef gh\n" (linewise "\n  ef gh\n"),
    .rests emptyLineText "d k" "  |ef gh\n" (linewise "ab cd\n\n"),
    .inserts emptyLineText "c k" "|\n  ef gh\n" (linewise "ab cd\n\n"),
    .rests emptyLineText "y k" "|ab cd\n\n  ef gh\n" (linewise "ab cd\n\n"),
    .rests emptyLineText "d g g" "  |ef gh\n" (linewise "ab cd\n\n"),
    .inserts emptyLineText "c g g" "|\n  ef gh\n" (linewise "ab cd\n\n"),
    .rests emptyLineText "y g g" "|ab cd\n\n  ef gh\n" (linewise "ab cd\n\n"),
    .rests emptyLineText "d G" "|ab cd\n" (linewise "\n  ef gh\n"),
    .inserts emptyLineText "c G" "ab cd\n|\n" (linewise "\n  ef gh\n"),
    .rests emptyLineText "y G" "ab cd\n|\n  ef gh\n" (linewise "\n  ef gh\n"),
    .givesUp endText "d j", .givesUp endText "c j", .givesUp endText "y j",
    .rests endText "d k" "|" (linewise "ab cd\n  ef gh\n"),
    .inserts endText "c k" "|\n" (linewise "ab cd\n  ef gh\n"),
    .rests endText "y k" "ab c|d\n  ef gh\n" (linewise "ab cd\n  ef gh\n"),
    .rests endText "d g g" "|" (linewise "ab cd\n  ef gh\n"),
    .inserts endText "c g g" "|\n" (linewise "ab cd\n  ef gh\n"),
    .rests endText "y g g" "|ab cd\n  ef gh\n" (linewise "ab cd\n  ef gh\n"),
    .rests endText "d G" "|ab cd\n" (linewise "  ef gh\n"),
    .inserts endText "c G" "ab cd\n|\n" (linewise "  ef gh\n"),
    .rests endText "y G" "ab cd\n  |ef gh\n" (linewise "  ef gh\n"), .givesUp bareEndText "d j",
    .givesUp bareEndText "c j", .givesUp bareEndText "y j",
    .rests bareEndText "d k" "|" (linewise "ab cd\n  ef gh\n"),
    .inserts bareEndText "c k" "|" (linewise "ab cd\n  ef gh\n"),
    .rests bareEndText "y k" "ab c|d\n  ef gh" (linewise "ab cd\n  ef gh\n"),
    .rests bareEndText "d g g" "|" (linewise "ab cd\n  ef gh\n"),
    .inserts bareEndText "c g g" "|" (linewise "ab cd\n  ef gh\n"),
    .rests bareEndText "y g g" "|ab cd\n  ef gh" (linewise "ab cd\n  ef gh\n"),
    .rests bareEndText "d G" "|ab cd" (linewise "  ef gh\n"),
    .inserts bareEndText "c G" "ab cd\n|" (linewise "  ef gh\n"),
    .rests bareEndText "y G" "ab cd\n  |ef gh" (linewise "  ef gh\n")]

/-- The five situations of the operator × motion table: the text and the
cursor of each, and whether its rows have a count. -/
def operatorSituations : List (String × Bool) :=
  [(plainText, false), (plainText, true), (emptyLineText, false), (endText, false),
    (bareEndText, false)]

/-- The oracle table's rows for `=` over each motion that takes no argument,
in its five situations, the count before the operator: their buffer has no
language and no syntax tree, so the indent operator gives up in every one,
having changed nothing, as Vim's `=` does nothing with no `indentexpr` that
answers (`Evil.cannotIndent`; a motion that fails gives up first). What
`=` does over a motion in a text with indent levels is
`evilIndentChecks`'s. -/
def indentTableRows : List OperatorRow :=
  operatorSituations.flatMap fun (before, counted) =>
    (Vim.Default.motions.filterMap fun (key, bound) =>
          match bound with
          | .motion _ => some key
          | _ => none).map
      fun motion =>
      .givesUp before (" ".intercalate ((if counted then ["2"] else []) ++ ["=", motion]))

/-- The oracle table's rows for each operator over `;` and `,` in its five
situations. In each nothing was found before the keys, so there is no last
find to repeat: Vim fails the motion and cancels the operator, and the
command gives up in every one. What they take after a find is
`findOperatorRows`. -/
def findAgainTableRows : List OperatorRow :=
  operatorSituations.flatMap fun (before, counted) =>
    ["d", "c", "y"].flatMap fun operator =>
      [";", ","].map fun motion =>
        .givesUp before
          (" ".intercalate ([operator] ++ (if counted then ["2"] else []) ++ [motion]))

/-- The oracle table's rows for each operator over `n` and `N` in its five
situations: no search was made before the keys, so there is none to repeat
(`E35`), and the command gives up in every one. -/
def searchAgainTableRows : List OperatorRow :=
  operatorSituations.flatMap fun (before, counted) =>
    ["d", "c", "y"].flatMap fun operator =>
      ["n", "N"].map fun motion =>
        .givesUp before
          (" ".intercalate ([operator] ++ (if counted then ["2"] else []) ++ [motion]))

/-- The oracle table's rows for each operator over `*` and `#` in its five
situations, each written by hand from Vim 9.1. In the first two the word
under the cursor, `gh`, is the only occurrence, at the cursor: the search
wraps back to it, says so, and the operator takes no cell. On the empty
line there is no word (`E348`). On the buffer's last character the word
starts one cell before the cursor, where the search comes back to, and the
operator takes that cell. -/
def starTableRows : List OperatorRow :=
  let warned (row : OperatorRow) (forward : Bool) : OperatorRow :=
    { row with echo := Evil.wrapWarning forward }
  [("*", true), ("#", false)].flatMap fun (motion, forward) =>
    let keys (operator : String) (counted : Bool := false) :=
      " ".intercalate ([operator] ++ (if counted then ["2"] else []) ++ [motion])
    [false, true].flatMap
        (fun counted =>
          [warned (.rests plainText (keys "d" counted) plainText asItWas) forward,
            warned (.inserts plainText (keys "c" counted) plainText asItWas) forward,
            warned (.rests plainText (keys "y" counted) plainText (charwise "")) forward]) ++
      [.givesUp emptyLineText (keys "d"), .givesUp emptyLineText (keys "c"),
        .givesUp emptyLineText (keys "y"),
        warned (.rests endText (keys "d") "ab cd\n  ef |h\n" (charwise "g")) forward,
        warned (.inserts endText (keys "c") "ab cd\n  ef |h\n" (charwise "g")) forward,
        warned (.rests endText (keys "y") "ab cd\n  ef |gh\n" (charwise "g")) forward,
        warned (.rests bareEndText (keys "d") "ab cd\n  ef |h" (charwise "g")) forward,
        warned (.inserts bareEndText (keys "c") "ab cd\n  ef |h" (charwise "g")) forward,
        warned (.rests bareEndText (keys "y") "ab cd\n  ef |gh" (charwise "g")) forward]

/-- The oracle table's rows for each operator over `%` in its five
situations, each run through Vim 9.1.1752 headless. With no count no line
of the situations has a bracket at or after the cursor, so Vim fails the
motion and cancels the operator. With a count of 2, `N%` goes to the line
`(2 * 5 + 99) / 100`, the first, and is taken as whole lines. -/
def percentTableRows : List OperatorRow :=
  [plainText, emptyLineText, endText, bareEndText].flatMap
      (fun before => ["d", "c", "y"].map fun operator => .givesUp before s!"{operator} %") ++
    [.rests plainText "d 2 %" "|mn\nop\n" (linewise "ab\ncd\n  ef gh.ij kl\n"),
      .inserts plainText "c 2 %" "|\nmn\nop\n" (linewise "ab\ncd\n  ef gh.ij kl\n"),
      .rests plainText "y 2 %" "|ab\ncd\n  ef gh.ij kl\nmn\nop\n"
        (linewise "ab\ncd\n  ef gh.ij kl\n")]

/-- The rows of the operator × motion table, in the order the motions were
built. -/
def operatorTable : List OperatorRow :=
  deleteAlongRows ++ yankChangeAlongRows ++ lineEndRows ++ wordEndBackRows ++ wordForwardRows ++
    changeWordRows ++
    lineMotionRows ++
    findAgainTableRows ++
    searchAgainTableRows ++
    starTableRows ++
    percentTableRows ++
    indentTableRows

/-- The pairs of an operator's key and a motion's key that the rows of
`operatorTable` have for the situation of the text `before`, with a count
when `counted`: a row's keys without its count, the first being the
operator's and the rest the motion's. -/
def operatorPairs (before : String) (counted : Bool) : List (String × String) :=
  operatorTable.filterMap fun row =>
    let tokens := row.keys.splitOn " "
    if row.before == before && tokens.contains "2" == counted then
      match tokens.filter (· != "2") with
      | operator :: motion => some (operator, " ".intercalate motion)
      | [] => none
    else none

/-- The motion keys of the default tables that are a motion alone, with no
argument to type after them: those bound to `Bound.motion`. A key bound to a
motion that takes a character (`Bound.charMotion`) is no motion until its
character is typed, so the table of five fixed situations has no row for
it; its rows, each with a character, are `findOperatorRows`, and
`findOperatorPairs` holds them to the default tables. -/
def bareMotionKeys : List String :=
  Vim.Default.motions.filterMap fun (key, bound) =>
    match bound with
    | .motion _ => some key
    | _ => none

/-- The motion keys of the default tables that take the character the next
key names (`Bound.charMotion`). -/
def charMotionKeys : List String :=
  Vim.Default.motions.filterMap fun (key, bound) =>
    match bound with
    | .charMotion _ => some key
    | _ => none

/-- Every pair of an operator's key and a motion's key of the default
tables (`Vim.Default.operators`, `Vim.Default.motions`) whose motion is a
motion alone (`bareMotionKeys`). -/
def defaultPairs : List (String × String) :=
  Vim.Default.operators.flatMap fun (operator, _) =>
    bareMotionKeys.map fun motion => (operator, motion)

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

/-- What is wrong, if anything, with each operator key of the default tables
pressed with each motion key, with no count and with a count of 2, from
every position of a text holding `contents` where a normal-state cursor may
rest. For each: the echo area says no refusal; after an operator that
enters no state the cursor is where normal state lets one rest; an operator
that changes no text leaves the text; and when the text changed, `u`, after
`<Escape>` for an operator that enters a state, gives the text back and
puts the cursor where it was. It reads the tables, so it covers a key added
later. A motion key that takes a character (`Bound.charMotion`) is pressed
with `a` after it, a character every text but the empty one holds, so the
sweep runs the find and does not leave the operator waiting; a motion key
that asks (`Bound.promptMotion`, `/` and `?`) is answered with the pattern
`a` and `RET`, through the minibuffer, whose commands the evil checks are
handed (`evilHanded`). -/
def operatorSweep (contents : String) : List String :=
  ((List.range (contents.utf8ByteSize + 1)).filter (restsWell contents)).flatMap fun position =>
    Vim.Default.operators.flatMap fun (operatorKey, bound) =>
      match bound with
      | .operator operator =>
        Vim.Default.motions.flatMap fun (motionKey, motion) =>
          -- A motion that takes a character is given one the sweep's texts
          -- hold, so that it is a motion and not an operator left waiting.
          let motionKey :=
            match motion with
            | .charMotion _ => motionKey ++ " a"
            -- A motion that asks is answered with a pattern the texts hold.
            | .promptMotion .. => motionKey ++ " a RET"
            | _ => motionKey
          [false, true].filterMap fun counted =>
            sweptWrong contents position operator
              ((if counted then "2 " else "") ++ operatorKey ++ " " ++ motionKey)
      | _ => []

/-- Whether `left` is what a command that gave up with `reason` leaves: the
text and the cursor `shown`, the register as it was, the view not in insert
state, and an echo area that ends with the reason and says no refusal. -/
def evilGaveUp (left : Option EvilEdited) (shown reason : String) : Bool :=
  !reason.isEmpty &&
    match left with
    | some left =>
      left.shown == shown && left.register == none && !left.insert && left.echo.endsWith reason &&
        (left.echo.splitOn "refused").length == 1
    | none => false

/-- The rows of the oracle table for `f`, `t`, `F`, `T`, `;` and `,` under an
operator, each written by hand from Vim 9.1's `:help f` and `:help ;`: `f`
and `t` are inclusive and `F` and `T` exclusive, `;` and `,` take the reach
of the motion they run, a till with a count of 1 repeated by `;` or `,`
passes over the character beside the cursor, and a find with nowhere to go
cancels the operator. -/
def findOperatorRows : List OperatorRow :=
  [.rests "|abcabc" "d f c" "|abc" (charwise "abc"),
    .rests "|abcabc" "d t c" "|cabc" (charwise "ab"),
    .rests "abcab|c" "d F a" "abc|c" (charwise "ab"),
    .rests "abcab|c" "d T a" "abca|c" (charwise "b"),
    .rests "|abcabc" "d 2 f c" "|" (charwise "abcabc"),
    .rests "|abcabc" "2 d t c" "|c" (charwise "abcab"),
    .rests "|abcabcabc" "f c d ;" "ab|abc" (charwise "cabc"),
    .rests "|abcabc" "f c ; d ," "ab|c" (charwise "cab"),
    .rests "|abcabc" "t c d ;" "a|c" (charwise "bcab"),
    .rests "|abcabc" "t c ; d ," "abc|bc" (charwise "a"),
    .rests "abcab|c" "F a d ;" "|abc" (charwise "abc"),
    .rests "a|bcabc" "F a d ," "|bc" (charwise "abca"),
    .rests "abcab|c" "T a d ;" "a|bc" (charwise "bca"),
    .rests "abcab|ca" "T a d ," "abca|a" (charwise "bc"),
    .inserts "|abcabc" "c f c" "|abc" (charwise "abc"),
    .inserts "abcab|c" "c F a" "abc|c" (charwise "ab"),
    .rests "|abcabc" "y t c" "|abcabc" (charwise "ab"),
    .rests "ab|cabc" "y T a" "a|bcabc" (charwise "b"), .rests "|ax" "d t x" "|x" (charwise "a"),
    .inserts "|ax" "c t x" "|x" (charwise "a"), .rests "|abcabc" "y f c" "|abcabc" (charwise "abc"),
    .rests "abcab|c" "y F a" "abc|abc" (charwise "ab"),
    .inserts "abcab|c" "c T a" "abca|c" (charwise "b"), .givesUp "|abc" "d f z",
    .givesUp "|abc" "d F a", .givesUp "|ab\nz" "d t z", .givesUp "|abc" "d ;",
    .givesUp "|abc" "y ,", .givesUp "|abcabc" "d 3 f c",
    -- `=` re-indents the one row a find stays on, in a text with indent
    -- levels.
    .indents "[\n|\"abc\",\n      \"cba\"\n]" "= f c" "[\n  |\"abc\",\n      \"cba\"\n]",
    .indents "[\n|\"abc\",\n      \"cba\"\n]" "= t c" "[\n  |\"abc\",\n      \"cba\"\n]",
    .indents "[\n\"abc\"|,\n      \"cba\"\n]" "= F a" "[\n  |\"abc\",\n      \"cba\"\n]",
    .indents "[\n\"abc\"|,\n      \"cba\"\n]" "= T a" "[\n  |\"abc\",\n      \"cba\"\n]"]

/-- The pairs of an operator's key and a motion's key that take a character
the rows of `findOperatorRows` have, with the keys typed before the
operator left out: the operator's key, and the motion's key after it. -/
def findOperatorPairs : List (String × String) :=
  findOperatorRows.filterMap fun row =>
    match ((row.keys.splitOn " ").filter (· != "2")).reverse with
    | _ :: motion :: operator :: _ =>
      if charMotionKeys.contains motion then some (operator, motion) else none
    | _ => none

/-- The rows of the oracle table for `f`, `t`, `F`, `T`, `;` and `,` as
moves, each written by hand from Vim 9.1's `:help f`, `:help t` and
`:help ;`: the keys, the text before with the cursor as a bar, and the text
after. -/
def findRows : List (String × String × String) :=
  [("f c", "|abcabc", "ab|cabc"), ("1 f c", "|abcabc", "ab|cabc"), ("2 f c", "|abcabc", "abcab|c"),
    ("f c", "ab|cabc", "abcab|c"), ("3 f c", "|abcabc", "|abcabc"), ("f z", "|abc", "|abc"),
    ("f x", "|ab\nx", "|ab\nx"), ("f x", "|ab\r\nx", "|ab\r\nx"), ("F a", "abca|bc", "abc|abc"),
    ("2 F a", "abcab|c", "|abcabc"), ("F a", "|abc", "|abc"), ("F x", "x\na|b", "x\na|b"),
    ("t c", "|abcabc", "a|bcabc"), ("2 t c", "|abcabc", "abca|bc"), ("t x", "|ax", "|ax"),
    ("t z", "|abc", "|abc"), ("t x", "|ab\nx", "|ab\nx"), ("T a", "abcab|c", "abca|bc"),
    ("2 T a", "abcab|c", "a|bcabc"), ("T x", "x|a", "x|a"), ("T x", "x\na|b", "x\na|b"),
    ("f c ;", "|abcabc", "abcab|c"), ("f c ; ,", "|abcabc", "ab|cabc"),
    ("f c 2 ;", "|abcabcabc", "abcabcab|c"), ("F a ;", "abcab|c", "|abcabc"),
    ("F a ,", "a|bcabc", "abc|abc"), ("t c ;", "|abcabc", "abca|bc"),
    ("t x ;", "|axbxcx", "ax|bxcx"), ("t x 2 ;", "|axbxcx", "ax|bxcx"),
    ("t x 3 ;", "|axbxcx", "axbx|cx"), ("T x ,", "x|axbx", "xax|bx"), ("T x ;", "xaxb|x", "x|axbx"),
    ("f c ; ; ,", "|abcabcabc", "abcab|cabc"), (";", "|abc", "|abc"), (",", "|abc", "|abc"),
    ("f z ;", "|abz", "ab|z"), ("2 f é", "|aébé", "aéb|é"), ("f é", "|aébé", "a|ébé"),
    ("f 1", "|a1b1", "a|1b1"), ("2 f 1", "|a1b1", "a1b|1"), ("f TAB", "|a\tb", "a|\tb"),
    ("f <Escape> l", "|abc", "a|bc"), ("v f c d", "|abcabc", "|abc"),
    ("v t c d", "|abcabc", "|cabc"), ("v F a d", "abcab|c", "ab|c")]

/-- The checks of evil's character finds (`Editor/Evil/Motions.lean`), on the
loop's driver over the editor's models, under the Vim scheme that ships
with evil's commands. -/
def evilFindChecks : List Check :=
  [{  name :=
        "f, t, F and T move within the line to the character their next key names, with and without a count, and not when the line has fewer; t and T stop one cell short and do not move with the character beside the cursor; ; and , repeat the last find, , in the other direction, and a till repeated with a count of 1 passes over the character beside the cursor; a character of several bytes, a digit and TAB are characters; f then <Escape> does nothing; and in a visual state a find extends the selection"
      run := evilRows findRows },
    { name :=
        "an operator over f, t, F, T, ; and , takes the range Vim 9.1 documents: f and t through the cell they lead to, F and T up to it, ; and , as the motion they run, and a find with nowhere to go gives the operator up"
      run := operatorRows findOperatorRows },
    { name :=
        "every operator key of the default tables with every motion key that takes a character has a row of findOperatorRows"
      run :=
        pure <|
          !charMotionKeys.isEmpty &&
            Vim.Default.operators.all fun (operator, _) =>
              charMotionKeys.all fun motion => findOperatorPairs.contains (operator, motion) },
    { name :=
        "a find is kept as the last find, also when it fails, and ; and , keep it as it was, its direction included; a find under an operator that gives up is rolled back with the command"
      run :=
        let lastFind (fixture typed : String) : Option (Option Find) :=
          (evilDriver fixture).map fun driver => (evilFed driver typed).loop.state.lastFind
        pure
          (lastFind "|abc" "" == some none &&
            lastFind "|abc" "f c" == some (some { char := "c", forward := true, till := false }) &&
            lastFind "|abc" "T z" == some (some { char := "z", forward := false, till := true }) &&
            lastFind "|abcabc" "f c ; ," ==
              some (some { char := "c", forward := true, till := false }) &&
            lastFind "|abc" "d f z" == some none &&
            lastFind "|abc" "d f c" ==
              some (some { char := "c", forward := true, till := false })) },
    { name :=
        "the move command runs a find with its argument after the motion's name, before the count"
      run :=
        pure <|
          match evilDriver "|abcabc" with
          | none => false
          | some driver =>
            let ran (arguments : List Argument) : String :=
              evilShown
                (driver.stepped
                    (driver.loop.invoke driver.handed { command := Vim.moveCommand, arguments })).1
            ran [.str "find-forward", .str "c", .nat 2] == "abcab|c" &&
              ran [.str "find-forward", .str "c"] == "ab|cabc" &&
              ran [.str "find-forward", .nat 1] == "|abcabc" &&
              ran [.str "find-again", .nat 0] == "|abcabc" },
    { name :=
        "the operate command takes a motion's argument after the motion's name, before the count and the register"
      run :=
        pure
          ((evilOperated "|abcabc"
                    [.str "delete", .str "motion", .str "find-forward", .str "c", .nat 2,
                      .str ""]).map
                (·.shown) ==
              some "|" &&
            (evilOperated "|abcabc"
                    [.str "delete", .str "motion", .str "till-forward", .str "c", .nat 0,
                      .str ""]).map
                (·.shown) ==
              some "|cabc") }]

/-- `driver` with the move command run by the motion `name` with `pattern`
as its argument and the count `count`, as an invocation no key yielded. -/
def evilSearchedBy (driver : EvilDriver) (name pattern : String) (count : Nat := 0) : EvilDriver :=
  (driver.stepped
      (driver.loop.invoke driver.handed
        { command := Vim.moveCommand, arguments := [.str name, .str pattern, .nat count] })).1

/-- One row of the search checks: the text before with the cursor as a bar,
the keys pressed first, the searches run then by invocation (a motion's
name, its pattern and a count), the keys pressed after them, and what is
left: the text with a bar at the cursor, and what the echo area says. -/
structure SearchRow where
  /-- The text before, with the cursor as a bar. -/
  before : String
  /-- The keys pressed first. -/
  first : String := ""
  /-- The searches run by invocation, in order. -/
  searches : List (String × String × Nat) := []
  /-- The keys pressed after them. -/
  keys : String := ""
  /-- The text after, with a bar at the cursor. -/
  after : String
  /-- What the echo area says after. -/
  echo : String := ""

/-- What is wrong with each of `rows`, if anything. -/
def searchRows (rows : List SearchRow) : IO Bool := do
  let wrong :=
    rows.filterMap fun row =>
      match evilDriver row.before with
      | none => some s!"no driver for {repr row.before}"
      | some driver =>
        let driver := evilFed driver row.first
        let driver :=
          row.searches.foldl
            (fun driver (name, pattern, count) => evilSearchedBy driver name pattern count) driver
        let driver := evilFed driver row.keys
        let left := (evilShown driver, driver.loop.state.echo)
        if left == (row.after, row.echo) then none
        else
          some
            s!"{row.first} {repr row.searches} {row.keys} from {repr row.before} left {repr left}"
  unless wrong.isEmpty do
    throw (IO.userError ("; ".intercalate wrong))
  return true

/-- The search motions' rows as moves, each written by hand from Vim 9.1's
`:help /`, `:help n` and `:help star` under its default options: `/` and
`?` by invocation, with their patterns, and `n`, `N`, `*` and `#` by key. -/
def searchMoveRows : List SearchRow :=
  let forward (pattern : String) (count : Nat := 0) := ("search-forward", pattern, count)
  let backward (pattern : String) (count : Nat := 0) := ("search-backward", pattern, count)
  let bottom := Evil.wrapWarning true
  let top := Evil.wrapWarning false
  [ -- From before a match, at its start and inside it.
    { before := "|x foo foo", searches := [forward "foo"], after := "x |foo foo" },
    { before := "x |foo foo", searches := [forward "foo"], after := "x foo |foo" },
    { before := "x f|oo foo", searches := [forward "foo"], after := "x foo |foo" },
    -- `cpo-c`, across lines, and a count.
    { before := "|abababab", searches := [forward "abab"], after := "abab|abab" },
    { before := "a|b\nfoo", searches := [forward "foo"], after := "ab\n|foo" },
    { before := "|foo foo foo foo", searches := [forward "foo" 3], after := "foo foo foo |foo" },
    -- Wrapping, the only match at the cursor, and no match.
    { before := "foo |foo", searches := [forward "foo"], after := "|foo foo", echo := bottom },
    { before := "|foo", searches := [forward "foo"], after := "|foo", echo := bottom },
    { before := "|abc", searches := [forward "x"], after := "|abc",
      echo := Evil.patternNotFound "x" },
    -- Backward, strictly before the cursor, and wrapping.
    { before := "foo foo |foo", searches := [backward "foo"], after := "foo |foo foo" },
    { before := "foo f|oo", searches := [backward "foo"], after := "foo |foo" },
    { before := "|foo foo", searches := [backward "foo"], after := "foo |foo", echo := top },
    -- `n` and `N` after `/` and after `?`, with counts.
    { before := "|x foo foo foo", searches := [forward "foo"], keys := "n",
      after := "x foo |foo foo" },
    { before := "|x foo foo foo", searches := [forward "foo"], keys := "2 n",
      after := "x foo foo |foo" },
    { before := "|x foo foo foo", searches := [forward "foo"], keys := "N",
      after := "x foo foo |foo", echo := top },
    { before := "foo foo fo|o", searches := [backward "foo"], keys := "n",
      after := "foo |foo foo" },
    { before := "foo foo foo fo|o", searches := [backward "foo"], keys := "2 N",
      after := "foo |foo foo foo", echo := bottom },
    -- `N` does not change the direction kept.
    { before := "foo foo fo|o", searches := [backward "foo"], keys := "N n",
      after := "foo foo |foo", echo := top },
    -- The empty pattern is the last search's, in the new direction.
    { before := "|x foo foo", searches := [forward "foo", forward ""], after := "x foo |foo" },
    { before := "|x foo foo", searches := [forward "foo", forward "foo", backward ""],
      after := "x |foo foo" },
    { before := "|abc", searches := [forward ""], after := "|abc", echo := Evil.noPreviousPattern },
    { before := "|abc", keys := "n", after := "|abc", echo := Evil.noPreviousPattern },
    { before := "|abc", keys := "N", after := "|abc", echo := Evil.noPreviousPattern },
    -- An escaped special, a pattern of several bytes, and a carriage return.
    { before := "|axb a.b", searches := [forward "a\\.b"], after := "axb |a.b" },
    { before := "|é x é", searches := [forward "é"], after := "é x |é" },
    { before := "|a\r\nfoo", searches := [forward "foo"], after := "a\r\n|foo" },
    -- In a visual state a search extends the selection.
    { before := "|abcxdef", first := "v", searches := [forward "x"], keys := "d", after := "|def" },
    -- `*` on a word's start, inside it and on its last character.
    { before := "|foo bar foo", keys := "*", after := "foo bar |foo" },
    { before := "f|oo bar foo", keys := "*", after := "foo bar |foo" },
    { before := "fo|o bar foo", keys := "*", after := "foo bar |foo" },
    -- On a blank before a word: the first keyword after the cursor.
    { before := "foo| bar x bar", keys := "*", after := "foo bar x |bar" },
    -- Whole words only, and a word outside ASCII.
    { before := "|foo food foo_bar foo", keys := "*", after := "foo food foo_bar |foo" },
    { before := "|héllo x héllo", keys := "*", after := "héllo x |héllo" },
    -- Punctuation with no keyword after it: a literal, with no boundaries.
    { before := "|+= +=", keys := "*", after := "+= |+=" },
    { before := "| += +=", keys := "*", after := " += |+=" },
    -- No word in the line.
    { before := "a\n|  \nb", keys := "*", after := "a\n|  \nb", echo := Evil.noStringUnderCursor },
    { before := "a\n|\nb", keys := "#", after := "a\n|\nb", echo := Evil.noStringUnderCursor },
    -- The only occurrence: the cursor goes to the word's start, with the
    -- warning.
    { before := "x f|oo y", keys := "*", after := "x |foo y", echo := bottom },
    { before := "x f|oo y", keys := "#", after := "x |foo y", echo := top },
    { before := "|foo foo foo", keys := "2 *", after := "foo foo |foo" },
    -- `#` mirrored.
    { before := "foo bar |foo", keys := "#", after := "|foo bar foo" },
    { before := "foo bar f|oo", keys := "#", after := "|foo bar foo" },
    { before := "foo foo |foo", keys := "2 #", after := "|foo foo foo" },
    -- `n` after `*` keeps the whole word, `n` after `#` goes back, and `N`.
    { before := "|foo x foo food foo", keys := "* n", after := "foo x foo food |foo" },
    { before := "foo x foo x f|oo", keys := "# n", after := "|foo x foo x foo" },
    { before := "|foo x foo x foo", keys := "* N", after := "|foo x foo x foo" },
    -- `/` and `?` by key, through the minibuffer.
    { before := "|x foo foo", keys := "/ f o o RET", after := "x |foo foo" },
    { before := "x |foo foo", keys := "/ f o o RET", after := "x foo |foo" },
    { before := "x f|oo foo", keys := "/ f o o RET", after := "x foo |foo" },
    { before := "|abababab", keys := "/ a b a b RET", after := "abab|abab" },
    { before := "a|b\nfoo", keys := "/ f o o RET", after := "ab\n|foo" },
    { before := "|foo foo foo foo", keys := "3 / f o o RET", after := "foo foo foo |foo" },
    { before := "foo |foo", keys := "/ f o o RET", after := "|foo foo", echo := bottom },
    { before := "|foo", keys := "/ f o o RET", after := "|foo", echo := bottom },
    { before := "|abc", keys := "/ x RET", after := "|abc", echo := Evil.patternNotFound "x" },
    -- The failed search is kept, so `n` repeats it, and says E486, not E35.
    { before := "|abc", keys := "/ z RET n", after := "|abc", echo := Evil.patternNotFound "z" },
    { before := "foo foo |foo", keys := "? f o o RET", after := "foo |foo foo" },
    { before := "|foo foo", keys := "? f o o RET", after := "foo |foo", echo := top },
    { before := "|x foo foo foo", keys := "/ f o o RET n", after := "x foo |foo foo" },
    { before := "|x foo foo foo", keys := "/ f o o RET 2 n", after := "x foo foo |foo" },
    { before := "foo foo fo|o", keys := "? f o o RET n", after := "foo |foo foo" },
    { before := "x|ax", keys := "? x RET N n", after := "|xax" },
    { before := "|x foo foo", keys := "/ f o o RET / RET", after := "x foo |foo" },
    { before := "|x foo foo", keys := "/ f o o RET / RET ? RET", after := "x |foo foo" },
    { before := "|abc", keys := "/ RET", after := "|abc", echo := Evil.noPreviousPattern },
    { before := "|axb a.b", keys := "/ a \\ . b RET", after := "axb |a.b" },
    { before := "|é x é", keys := "/ é RET", after := "é x |é" },
    { before := "|a\r\nfoo", keys := "/ f o o RET", after := "a\r\n|foo" },
    { before := "|abcxdef", keys := "v / x RET d", after := "|def" },
    -- A cancelled prompt leaves nothing waiting: the next key is a key.
    { before := "|abc abc", keys := "/ b <Escape> l", after := "a|bc abc" },
    { before := "|abc abc", keys := "d / b <Escape> l", after := "a|bc abc" }]

/-- The rows of the oracle table for the operators over `n`, `N`, `*` and
`#`, each written by hand from Vim 9.1: each is exclusive, an operator
takes what lies from the cursor where the key was typed to where the search
leads, also when it wrapped and so leads back, and `*` takes from the
cursor, not from the word's start, which is where its search begins. The
two rules for an exclusive motion that ends in column 1 apply. -/
def searchOperatorRows : List OperatorRow :=
  [.rests "|foo x foo y foo" "* 0 d n" "|foo y foo" (charwise "foo x "),
    .rests "|foo x foo y foo" "* * d N" "foo x |foo" (charwise "foo y "),
    { (OperatorRow.rests "|foo x foo y foo" "# d N" "|foo" (charwise "foo x foo y ")) with
      echo := Evil.wrapWarning true },
    .rests "f|oo x foo" "d *" "f|foo" (charwise "oo x "),
    .rests "foo x f|oo" "d #" "|oo" (charwise "foo x f"),
    .rests "|foo x foo x foo" "* 0 y n" "|foo x foo x foo" (charwise "foo x "),
    .inserts "|foo x foo" "c *" "|foo" (charwise "foo x "),
    .rests "|foo x foo x foo" "* 0 d 2 n" "|foo" (charwise "foo x foo x "),
    -- The column-1 rules: from the line's first non-blank, whole lines;
    -- from after it, up to the line before's end.
    .rests "|foo\nfoo" "d *" "|foo" (linewise "foo\n"),
    .rests "x |foo\nfoo" "d *" "x| \nfoo" (charwise "foo"), .givesUp "|abc" "d n",
    .givesUp "|abc" "c N", .givesUp "a\n|  \nb" "d *",
    -- `/` and `?` through the minibuffer.
    .rests "|foo bar" "d / b a r RET" "|bar" (charwise "foo "),
    .rests "foo bar f|oo" "d ? b a r RET" "foo |oo" (charwise "bar f"),
    .rests "|foo bar" "y / b a r RET" "|foo bar" (charwise "foo "),
    .inserts "|abcxdef" "c / x RET" "|xdef" (charwise "abc"),
    .rests "|foo bar foo bar" "d 2 / b a r RET" "|bar" (charwise "foo bar foo "),
    .rests "|foo\nbar" "d / b a r RET" "|bar" (linewise "foo\n"),
    .rests "x|foo\nbar" "d / b a r RET" "|x\nbar" (charwise "foo"),
    .rests "foo\n|bar" "d ? f o o RET" "|bar" (linewise "foo\n"),
    .rests "foo bar f|oo" "y ? b a r RET" "foo |bar foo" (charwise "bar f"),
    .givesUp "|abc" "d / z RET", .givesUp "|abc" "c ? z RET", .givesUp "|abc" "d / RET",
    -- `=` re-indents the rows from the cursor to where the search leads, in
    -- a text with indent levels.
    .indents "[\n|1,\n      2,\n 3\n]" "= / 3 RET" "[\n  |1,\n  2,\n  3\n]",
    .indents "[\n1,\n      2,\n |3\n]" "= ? 1 RET" "[\n  |1,\n  2,\n  3\n]"]

/-- The pairs of an operator's key and a motion's key that asks that the
rows of `searchOperatorRows` have, with the keys typed before the operator
left out. -/
def searchOperatorPairs : List (String × String) :=
  let asking : List String :=
    Vim.Default.motions.filterMap fun (key, bound) =>
      match bound with
      | .promptMotion .. => some key
      | _ => none
  searchOperatorRows.filterMap fun row =>
    match (row.keys.splitOn " ").filter (· != "2") with
    | operator :: motion :: _ => if asking.contains motion then some (operator, motion) else none
    | _ => none

/-- The checks of evil's searches (`Editor/Evil/Motions.lean`), on the loop's
driver over the editor's models, under the Vim scheme that ships with
evil's commands, the text model answering the searches of literal
patterns. -/
def evilSearchChecks : List Check :=
  [{  name :=
        "/ and ? (by invocation and by key, through the minibuffer), n, N, * and # move as Vim 9.1 documents for a literal pattern: from before, at and inside a match, cpo-c, across lines, with counts, wrapping with Vim's warning, not found with E486, n with no last search with E35, N keeping the direction, the empty pattern the last one, whole words for * and #, from the word's start, and a visual selection extended"
      run := searchRows searchMoveRows },
    { name :=
        "an operator over /, ?, n, N, * and # takes the range Vim 9.1 documents: exclusive, from the cursor to where the search leads, also back over a wrap, with the rules for an exclusive motion that ends in column 1, and a search with nowhere to go gives the operator up with E486, E35 or E348"
      run := do
        let rows ← operatorRows searchOperatorRows
        return rows &&
            evilGaveUp (evilEdited "|abc" "d / z RET") "|abc" (Evil.patternNotFound "z") &&
            evilGaveUp (evilEdited "|abc" "d n") "|abc" Evil.noPreviousPattern &&
            evilGaveUp (evilEdited "a\n|  \nb" "d *") "a\n|  \nb" Evil.noStringUnderCursor },
    { name :=
        "every operator key of the default tables with / and ?, the motion keys that ask, has a row of searchOperatorRows"
      run :=
        pure <|
          Vim.Default.operators.all fun (operator, _) =>
            ["/", "?"].all fun motion => searchOperatorPairs.contains (operator, motion) },
    { name :=
        "an answer for the input scheme is handed to the scheme and no command of the reserved name is looked up: with nothing asked, a command registered under it does not run; after / it completes the search"
      run :=
        let reserved : Dispatched := fun _ => do
          message "the reserved name ran"
          return none
        pure <|
          match evilDriver "|x foo" (evilHanded #[] [(InputScheme.answerName, reserved)]) with
          | none => false
          | some driver =>
            let answer (driver : EvilDriver) : EvilDriver :=
              (driver.stepped
                  (driver.loop.invoke driver.handed
                    { command := InputScheme.answerName, arguments := [.str "foo"] })).1
            let unasked := answer driver
            -- The prompt was closed without an answer, and no key came
            -- since: an answer that comes now completes the edit.
            let asked := answer (evilFed driver "/ <Escape>")
            unasked.loop.state.echo.isEmpty && evilShown unasked == "|x foo" &&
              asked.loop.state.echo.isEmpty &&
              evilShown asked == "x |foo" },
    { name :=
        "a search is kept as the last search, pattern and direction: * keeps the whole word, escaped, and # keeps it going back; n and N keep it as it was; a search that fails as a move is kept, as Vim keeps the pattern; a search under an operator that gives up is rolled back with the command, so the last search is the one from before it"
      run :=
        let last (fixture typed : String) : Option (Option Search) :=
          (evilDriver fixture).map fun driver => (evilFed driver typed).loop.state.lastSearch
        pure
          (last "|foo" "" == some none &&
            last "|foo foo" "*" == some (some { pattern := "\\<foo\\>", forward := true }) &&
            last "|foo foo" "#" == some (some { pattern := "\\<foo\\>", forward := false }) &&
            last "|foo foo" "* N" == some (some { pattern := "\\<foo\\>", forward := true }) &&
            last "|.* .*" "*" == some (some { pattern := "\\.\\*", forward := true }) &&
            last "|a.b" "*" == some (some { pattern := "\\<a\\>", forward := true }) &&
            last "|$^ $^" "*" == some (some { pattern := "\\$\\^", forward := true }) &&
            last "a\n|  \nb" "d *" == some none &&
            -- A failed move keeps its pattern: the motion hands it back.
            last "|abc" "/ z RET" == some (some { pattern := "z", forward := true }) &&
            last "|abc" "? z RET" == some (some { pattern := "z", forward := false }) &&
            -- An operator's give-up rolls the pattern it set back, to none
            -- and to the one kept before it.
            last "|abc" "d / z RET" == some none &&
            last "|foo foo" "* d / z RET" ==
              some (some { pattern := "\\<foo\\>", forward := true }) &&
            last "|foo foo" "/ f RET d ? z RET" ==
              some (some { pattern := "f", forward := true }) &&
            (evilDriver "|x foo").map
                (fun driver =>
                  (evilSearchedBy driver "search-backward" "foo").loop.state.lastSearch) ==
              some (some { pattern := "foo", forward := false })) }]

/-- The text of the decoration checks: a hundred rows of `foo` and the row's
number, more than a view of the decoration checks' frame shows
(`decorationState`), but for row 10, which holds two matches, and row 50,
whose word is `food`. -/
def decoratedText : String :=
  String.join <|
    (List.range 100).map fun row =>
      if row == 10 then "foo foo 10\n" else if row == 50 then "food 50\n" else s!"foo {row}\n"

/-- A text whose rows are longer than the decoration checks' frame is wide:
sixty rows of `foo` and a blank, fifty times each, two hundred cells, so
every row wraps, and the view shows fewer rows than it is high. -/
def wrappingText : String :=
  String.join
    ((List.range 60).map fun _ => String.join ((List.range 50).map fun _ => "foo ") ++ "\n")

/-- A state of the decoration checks: `evilState` of `contents`, with the
cursor at 0, in a frame of 80 by 40, where a row of the display model is
one high and a cell one wide, so a view shows a few dozen rows. -/
def decorationState (contents : String) : TextM EditorState := do
  let state ← evilState contents 0
  return { state with frame := { state.frame with size := ⟨80, 40⟩ } }

/-- A driver of the decoration checks over `decorationState`. -/
def decorationDriver (contents : String) : Option EvilDriver :=
  (Loop.Driver.over evilHanded (fun _ => none) (decorationState contents) editorModel).toOption

/-- The matches of `needle` in `contents`, found by hand, row by row: from
each row's start, each occurrence, and the walk goes on from its end. With
`whole`, an occurrence that does not start and end a word is passed over
and the walk goes on one character after its start. Byte offsets, with the
row each starts in. -/
def naiveMatches (contents needle : String) (whole : Bool := false) : List (Nat × Nat × Nat) :=
  Id.run do
    let chars := contents.toList.toArray
    let offsets :=
      (chars.foldl (fun (acc : Array Nat × Nat) c => (acc.1.push acc.2, acc.2 + c.utf8Size))
          (#[], 0)).1
    let width := needle.length
    let word (index : Nat) : Bool := (chars[index]?.map wordCharacter).getD false
    let mut found := #[]
    let mut index := 0
    let mut row := 0
    let mut rowAt := #[]
    for char in chars do
      rowAt := rowAt.push row
      if char == '\n' then
        row := row + 1
    while index + width ≤ chars.size do
      let here := (chars.extract index (index + width)).toList == needle.toList
      let bounded :=
        !whole ||
          (word index && (index == 0 || !word (index - 1)) && word (index + width - 1) &&
            !word (index + width))
      if here && bounded then
        found :=
          found.push
            (rowAt[index]!, offsets[index]!, (offsets[index + width]?).getD contents.utf8ByteSize)
        index := index + width
      else
        index := index + 1
    return found.toList

/-- What is wrong, if anything, with the decorations of the view `view` in
the last scene `driver` published, for the matches of `needle` in
`contents`: every match that starts in a row from the view's anchor's
through `height / heights.text` rows on is decorated, and every
decoration is in `search-match` and is a match that starts in a row
through one more, which is what the loop reads (`Loop.decorationsOf`). -/
def decorationsWrong (driver : EvilDriver) (contents needle : String) (whole : Bool := false)
    (view : ViewId := ⟨0⟩) : Option String := do
  let some scene := driver.model.display.scenes.back? | some "no scene"
  let some shown := scene.views.find? (·.id == view) | some "no view"
  let some target := driver.loop.state.target? view | some "no window"
  let anchor :=
    match (target.buffer.text.marker target.window.scroll).runModel driver.model.texts with
    | (.ok (.anchor anchor), _) => some anchor.offset
    | _ => none
  let some anchor := anchor | some "no anchor"
  let rowOf (offset : Nat) : Nat :=
    ((contents.toList.foldl
        (fun (acc : Nat × Nat) c =>
          if acc.1 < offset then (acc.1 + c.utf8Size, acc.2 + if c == '\n' then 1 else 0) else acc)
        (0, 0)).2)
  let first := rowOf anchor
  let rows := shown.rect.height / max 1 driver.loop.state.heights.text
  let all := naiveMatches contents needle whole
  let visible := all.filter fun (row, _, _) => first ≤ row && row ≤ first + rows
  let reachable := all.filter fun (row, _, _) => first ≤ row && row ≤ first + rows + 1
  let drawn := shown.decorations.toList.map fun decoration => (decoration.start, decoration.stop)
  if visible.isEmpty then
    some "no match is visible"
  else if !visible.all fun (_, start, stop) => drawn.contains (start, stop) then
    some s!"a visible match is not decorated: {repr drawn}"
  else if !shown.decorations.all (·.face == Loop.searchMatchFace) then
    some "a decoration is in another face"
  else if
    !drawn.all fun range =>
        (reachable.map fun (_, start, stop) => (start, stop)).contains range then
    some s!"a decoration is no match the loop reads: {repr drawn}"
  else
    none

/-- The decorations of the view `view` in the last scene `driver`
published. -/
def decorationsOfScene (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option (Array Decoration) :=
  driver.model.display.scenes.back?.bind fun scene =>
    (scene.views.find? (·.id == view)).map (·.decorations)

/-- A state of the decoration checks: `evilState` of `contents`, with a
second window on the same buffer below the first, whose anchor is at the
byte offset `second`. -/
def twoViewState (contents : String) (second : Nat) : TextM EditorState := do
  let state ← decorationState contents
  let some buffer := state.buffers[0]?.join | throw .noSuchText
  let scroll ← buffer.text.mark (.anchor { offset := second, bias := .before })
  let selection ←
    buffer.text.mark (.selection { ranges := #[⟨second, second⟩], shape := .inclusive })
  return {
      state with
      windows := state.windows.push { id := ⟨1⟩, buffer := ⟨0⟩, scroll, selection }
      nextView := 2
      frame :=
        { state.frame with
          windows := #[⟨0⟩, ⟨1⟩], layout := .masterStack { side := .top } } }

/-- The checks of the decorations of a view (`Editor/Loop.lean`,
"Decorations"): the matches of the last search, in `search-match`, on the
loop's driver over the editor's models and the display recorder, under the
Vim scheme that ships. -/
def searchDecorationChecks : List Check :=
  let fed (fixture typed : String) : Option EvilDriver :=
    (decorationDriver (barred fixture).1).map (evilFed · typed)
  [{  name :=
        "after / f o o RET every match in the rows the view shows is drawn in search-match, and every decoration is a match of the rows the loop reads, food among none"
      run :=
        pure <|
          match fed ("|" ++ decoratedText) "/ f o o RET" with
          | none => false
          | some driver => decorationsWrong driver decoratedText "foo" == none },
    { name := "after C-f the decorations follow the rows the view shows from its new anchor"
      run :=
        pure <|
          match fed ("|" ++ decoratedText) "/ f o o RET C-f",
            fed ("|" ++ decoratedText) "/ f o o RET" with
          | some paged, some first =>
            decorationsWrong paged decoratedText "foo" == none &&
              decorationsOfScene paged != decorationsOfScene first
          | _, _ => false },
    { name :=
        "in rows that wrap, every match the view shows is decorated, and every decoration is a match"
      run :=
        pure <|
          match fed ("|" ++ wrappingText) "/ f o o RET" with
          | none => false
          | some driver => decorationsWrong driver wrappingText "foo" == none },
    { name := "a second view of the buffer has the decorations of its own rows by the same rule"
      run :=
        pure <|
          match
            (Loop.Driver.over evilHanded (fun _ => none) (twoViewState decoratedText 300)
                editorModel).toOption with
          | none => false
          | some driver =>
            let driver := evilFed driver "/ f o o RET"
            decorationsWrong driver decoratedText "foo" == none &&
              decorationsWrong driver decoratedText "foo" (view := ⟨1⟩) == none &&
              decorationsOfScene driver ⟨1⟩ != decorationsOfScene driver ⟨0⟩ },
    { name :=
        "the minibuffer's view has no decorations while the prompt is open, and with no search no view has any"
      run :=
        pure <|
          match fed ("|" ++ decoratedText) "/ f o o RET / f", fed ("|" ++ decoratedText) "l" with
          | some asking, some unsearched =>
            let minibuffer := asking.loop.state.prompt.map (·.view)
            (asking.model.display.scenes.back?.map fun scene =>
                  scene.views.all fun view =>
                    some view.id != minibuffer || view.decorations.isEmpty) ==
                some true &&
              minibuffer.isSome &&
              (unsearched.model.display.scenes.back?.map fun scene =>
                  scene.views.all (·.decorations.isEmpty)) ==
                some true
          | _, _ => false },
    { name := "after * on foo, food is not decorated: the pattern is the whole word"
      run :=
        pure <|
          match fed ("|" ++ decoratedText) "*" with
          | none => false
          | some driver => decorationsWrong driver decoratedText "foo" (whole := true) == none },
    { name := "a pattern with no match, and one the syntax refuses, draws nothing"
      run :=
        pure <|
          match fed ("|" ++ decoratedText) "/ x y z RET",
            fed ("|" ++ decoratedText) "/ \\ ( RET" with
          | some missing, some refused =>
            decorationsOfScene missing == some #[] && decorationsOfScene refused == some #[]
          | _, _ => false },
    { name :=
        "a buffer's spans within a covered range are kept, clipped to it, in order, and those outside it and those left empty are dropped"
      run :=
        let span (start stop : Nat) : Decoration := { start, stop, face := ⟨"s"⟩ }
        pure
          (Loop.spansIn #[span 0 5, span 8 12, span 15 20, span 30 40, span 10 10] 10 32 ==
            #[span 10 12, span 15 20, span 30 32]) },
    { name :=
        "a view's decorations are its buffer's spans in the rows it covers, with no search too, and then the last search's matches, which are drawn over them"
      run :=
        let face : FaceName := ⟨"compilation.error"⟩
        let spans : Array Decoration :=
          #[{ start := 0, stop := 3, face }, { start := 30000, stop := 30004, face }]
        let spanned : TextM EditorState := do
          let state ← decorationState decoratedText
          return { state with buffers := state.buffers.modify 0 (·.map ({ · with spans })) }
        let driver := (Loop.Driver.over evilHanded (fun _ => none) spanned editorModel).toOption
        pure <|
          match driver.map (evilFed · "l"), driver.map (evilFed · "/ f o o RET") with
          | some unsearched, some searched =>
            let found := (decorationsOfScene searched).map (·.extract 1 1000)
            decorationsOfScene unsearched == some #[{ start := 0, stop := 3, face }] &&
              (decorationsOfScene searched).bind (·[0]?) == some { start := 0, stop := 3, face } &&
              (found.map fun all => !all.isEmpty && all.all (·.face == Loop.searchMatchFace)) ==
                some true
          | _, _ => false }]

/-- The checks of evil's operators (`Editor/Evil/Operators.lean`) on the
loop's driver over the editor's models, under the Vim scheme that ships
with evil's commands: an operator's keys are pressed in a text with the
cursor written into it, with a sentinel in the unnamed register, and each
expected text, cursor and register is written by hand from Vim's
documented behaviour, case by case. -/
def evilOperatorChecks : List Check :=
  [{  name :=
        "an operator's key and a motion's run the operate command: d l deletes the cell under the cursor into the unnamed register, and nothing is said in the echo area"
      run := pure (evilEdited "a|bc" "d l" == some ⟨"a|c", charwise "b", false, ""⟩) },
    { name :=
        "each operator over each motion, in five situations (no count, a count of 2, on an empty line, on the buffer's last character with and without a final line feed), leaves the text, the cursor and the unnamed register Vim leaves"
      run := operatorRows operatorTable },
    { name :=
        "the table is complete: in each of its five situations, the pairs of an operator's key and a motion's key its rows have are exactly those of the default tables whose motion takes no argument, each once (the motions that take a character are held to the default tables by findOperatorPairs)"
      run :=
        pure <|
          !defaultPairs.isEmpty &&
            operatorTable.length == operatorSituations.length * defaultPairs.length &&
            operatorSituations.all fun (before, counted) =>
              let pairs := operatorPairs before counted
              pairs.length == defaultPairs.length && defaultPairs.all pairs.contains },
    { name :=
        "a sweep of every default operator key over every default motion key, with no count and with a count of 2, from every position a cursor may rest at in a few texts: nothing is refused, after an operator that enters no state the cursor is where normal state lets one rest, an operator that changes no text leaves the text, and u gives back a text that changed, with the cursor where it was"
      run := do
        let wrong := sweepTexts.flatMap operatorSweep
        unless wrong.isEmpty do
          throw
              (IO.userError s!"{wrong.length} cases, the first: {"; ".intercalate (wrong.take 5)}")
        return true },
    { name :=
        "the doubled operator acts on whole lines, and with a count on that many, stopped at the last line: d d leaves the cursor on the first non-blank of the line now there, or of the last line; c c leaves one line break and the bar at the line's start; y y leaves the cursor; and the counts of 2 d 3 d multiply"
      run :=
        operatorRows
          [.rests "ab\n  cd\n|ef\n  gh" "d d" "ab\n  cd\n  |gh" (linewise "ef\n"),
            .rests "a\n|b" "d d" "|a" (linewise "b\n"),
            .rests "a\n|b\n" "d d" "|a\n" (linewise "b\n"),
            .rests "|a\n" "d d" "|" (linewise "a\n"),
            .rests "|ab\ncd\nef" "2 d d" "|ef" (linewise "ab\ncd\n"),
            .rests "ab\n|cd\nef" "3 d d" "|ab" (linewise "cd\nef\n"),
            .inserts "ab\n c|d\nef" "c c" "ab\n|\nef" (linewise " cd\n"),
            .inserts "ab\n c|d\nef" "2 c c" "ab\n|" (linewise " cd\nef\n"),
            .inserts "ab\n|cd" "c c" "ab\n|" (linewise "cd\n"),
            .rests "ab\nc|d\nef" "y y" "ab\nc|d\nef" (linewise "cd\n"),
            .rests "ab\nc|d" "y y" "ab\nc|d" (linewise "cd\n"),
            .rests "ab\nc|d\nef" "2 y y" "ab\nc|d\nef" (linewise "cd\nef\n"),
            .rests "ab\nc|d\nef" "5 y y" "ab\nc|d\nef" (linewise "cd\nef\n"),
            .rests "|a\nb\nc\nd\ne\nf" "2 d 3 d" "|" (linewise "a\nb\nc\nd\ne\nf\n")] },
    { name :=
        "a doubled operator with a count above 1 on the last line is cancelled, as Vim cancels it, there being no line below to go to: 2 d d, 2 c c and 2 y y there, with and without a final line feed, in a text of one line and in the empty text, leave the text, the cursor and the register as they were and the view in normal state, and so do a count inside the operator, counts that multiply, a count past the text and a named register; counts of 1 do not fail, and from a line above a count past the text stops at the last line; the echo area says the sentence the function makes, and the register a cancelled operator named holds nothing"
      run := do
        let held ←
          operatorRows
              [.givesUp "ab\ncd\n|ef" "2 d d", .givesUp "ab\ncd\n|ef" "2 c c",
                .givesUp "ab\ncd\n|ef" "2 y y", .givesUp "ab\ncd\ne|f\n" "2 d d",
                .givesUp "ab\ncd\ne|f\n" "2 c c", .givesUp "ab\ncd\ne|f\n" "2 y y",
                .givesUp "a|b" "2 d d", .givesUp "a|b" "2 c c", .givesUp "a|b" "2 y y",
                .givesUp "a|b\n" "2 d d", .givesUp "a|b\n" "2 c c", .givesUp "a|b\n" "2 y y",
                .givesUp "|" "2 d d", .givesUp "|" "2 c c", .givesUp "|" "2 y y",
                .givesUp "ab\ncd\n  e|f" "d 2 d", .givesUp "ab\ncd\n  e|f" "c 2 c",
                .givesUp "ab\ncd\n  e|f" "y 2 y", .givesUp "ab\ncd\n|ef" "2 d 3 d",
                .givesUp "ab\ncd\n|ef" "2 c 3 c", .givesUp "ab\ncd\n|ef" "2 y 3 y",
                .givesUp "ab\ncd\n|ef" "9 d d", .givesUp "ab\ncd\ne|f\n" "9 c c",
                .givesUp "a|b" "9 y y", .givesUp "ab\ncd\n|ef" "\" a 2 d d",
                .rests "ab\ncd\n|ef" "1 d 1 d" "ab\n|cd" (linewise "ef\n"),
                .rests "ab\ncd\ne|f\n" "1 d 1 d" "ab\n|cd\n" (linewise "ef\n"),
                .rests "ab\n|cd\nef\n" "9 d d" "|ab\n" (linewise "cd\nef\n"),
                .inserts "ab\n|cd\nef" "9 c c" "ab\n|" (linewise "cd\nef\n"),
                .rests "ab\n|cd\nef\n" "9 y y" "ab\n|cd\nef\n" (linewise "cd\nef\n")]
        return held &&
            evilGaveUp (evilEdited "ab\ncd\n|ef" "2 d d") "ab\ncd\n|ef" Evil.noLineBelow &&
            (evilEdited "ab\ncd\n|ef" "2 c c").map (·.echo) ==
              some s!"{Vim.operateCommand}: {Evil.noLineBelow}" &&
            ((evilRegistered "ab\ncd\n|ef").map fun driver =>
                (evilFed driver "\" a 2 d d").loop.state.register? "a") ==
              some none },
    { name :=
        "in the empty text d and c change neither the text nor the register, c still begins an insert, and y y yanks one line break, line-wise; and the counts before and after an operator multiply: 2 d 3 w deletes six words"
      run :=
        operatorRows
          [.rests "|" "d d" "|" asItWas, .inserts "|" "c c" "|" asItWas,
            .rests "|" "d G" "|" asItWas, .inserts "|" "c G" "|" asItWas,
            .rests "|" "d w" "|" asItWas, .inserts "|" "c $" "|" asItWas,
            .rests "|" "y y" "|" (linewise "\n"),
            .rests "|a b c d e f g" "2 d 3 w" "|g" (charwise "a b c d e f ")] },
    { name :=
        "d ^ on a line of blanks only deletes from the cursor up to the line's last blank, and nothing from the last blank; d h at a line's start and d l on an empty line delete nothing and leave the register as it was"
      run :=
        operatorRows
          [.rests "|   " "d ^" "| " (charwise "  "), .rests "  | " "d ^" "  | " asItWas,
            .rests "|abc" "d h" "|abc" asItWas, .rests "ab\n|abc" "d h" "ab\n|abc" asItWas,
            .rests "ab\n|\ncd" "d l" "ab\n|\ncd" asItWas] },
    { name :=
        "over no cell a yank empties the register and leaves the cursor, and a change leaves the register as it was and begins an insert where the cursor is: y h and c h at a line's start, y l and c l on an empty line"
      run :=
        operatorRows
          [.rests "|abc" "y h" "|abc" (charwise ""), .inserts "|abc" "c h" "|abc" asItWas,
            .rests "ab\n|abc" "y h" "ab\n|abc" (charwise ""),
            .inserts "ab\n|abc" "c h" "ab\n|abc" asItWas,
            .rests "ab\n|\ncd" "y l" "ab\n|\ncd" (charwise ""),
            .inserts "ab\n|\ncd" "c l" "ab\n|\ncd" asItWas] },
    { name :=
        "$ under an operator: c 2 $ from a line's start takes the cells through the end of the line below; on an empty line c $ empties the register where d $ leaves it, and in the empty text c $ leaves it too; with a count above 1 on the last line the motion fails and the operator gives up, with and without a final line feed"
      run := do
        let held ←
          operatorRows
              [.inserts "|ab\ncd\nef" "c 2 $" "|\nef" (charwise "ab\ncd"),
                .rests "ab\n|\ncd" "d $" "ab\n|\ncd" asItWas,
                .inserts "ab\n|\ncd" "c $" "ab\n|\ncd" (charwise ""), .inserts "" "c $" "|" asItWas,
                .givesUp "ab\n|cd" "d 2 $", .givesUp "ab\n|cd" "c 2 $", .givesUp "ab\n|cd" "y 2 $",
                .givesUp "ab\n|cd\n" "d 2 $", .rests "ab\n|cd\n" "d 1 $" "ab\n|\n" (charwise "cd")]
        -- The sentence is the one the function makes of the motion's name.
        return held &&
            evilGaveUp (evilEdited "ab\n|cd" "d 2 $") "ab\n|cd"
              (Evil.cannotMove Evil.lineEnd.name) },
    { name :=
        "e and b under an operator: d e on a text's last character takes it, and d 2 e takes through the second word's end; a backward motion that stops at a line's start takes the whole line before when it starts at or before its own line's first non-blank, with d, y and c, and otherwise stops where the line before ends; d 3 b with one word before the cursor takes it; at the text's start b fails and the operator gives up"
      run := do
        let held ←
          operatorRows
              [.rests "ab|c\n" "d e" "a|b\n" (charwise "c"),
                .rests "a|b c" "d 2 e" "|a" (charwise "b c"),
                .rests "foo\n|bar" "d b" "|bar" (linewise "foo\n"),
                .rests "foo\n|bar" "y b" "|foo\nbar" (linewise "foo\n"),
                .inserts "foo\n|bar" "c b" "|\nbar" (linewise "foo\n"),
                .rests "abc foo\n|bar" "d b" "abc| \nbar" (charwise "foo"),
                .rests "foo\n  |bar" "d b" "|bar" (charwise "foo\n  "),
                .rests "ab |cd" "d 3 b" "|cd" (charwise "ab "), .givesUp "|abc" "d b",
                .givesUp "|abc" "c b", .givesUp "|abc" "y B", .givesUp "|" "d b"]
        return held &&
            evilGaveUp (evilEdited "|abc" "d b") "|abc" (Evil.cannotMove Evil.wordBackward.name) },
    { name :=
        "w under d and y: the last word of a line is taken with the blanks after it and not the line break, with a count that ends there too; a count that ends on a later line takes up to that word; from an empty line the stretch is that line, whole; at the text's end the last word is taken, with and without a final line feed, and a count past the text takes what there is"
      run :=
        operatorRows
          [.rests "one |two\nthree" "d w" "one| \nthree" (charwise "two"),
            .rests "|two\nthree" "d w" "|\nthree" (charwise "two"),
            .rests "|foo   \nbar" "d w" "|\nbar" (charwise "foo   "),
            .rests "foo|   \nbar" "d w" "fo|o\nbar" (charwise "   "),
            .rests "|foo\n  bar" "d w" "|\n  bar" (charwise "foo"),
            .rests "|one two\nthree" "d 2 w" "|\nthree" (charwise "one two"),
            .rests "|one\ntwo three" "d 2 w" "|three" (charwise "one\ntwo "),
            .rests "foo |bar\nbaz" "y w" "foo |bar\nbaz" (charwise "bar"),
            .rests "a b |c" "d w" "a b| " (charwise "c"),
            .rests "a b |c\n" "d w" "a b| \n" (charwise "c"),
            .rests "a |b c\nd" "d 9 w" "a| " (charwise "b c\nd"),
            .rests "x |foo.bar\nbaz" "d W" "x| \nbaz" (charwise "foo.bar"),
            .rests "ab\n|\nfoo" "d w" "ab\n|foo" (linewise "\n"),
            .rests "|one\n\nthree" "d 2 w" "|three" (linewise "one\n\n"),
            .rests "x |one\n\nthree" "d 2 w" "x| \nthree" (charwise "one\n")] },
    { name :=
        "Vi's rule for a deletion over lines: cells that start at or before their line's first non-blank, stop on a later line and have only blanks after them on it are whole lines for d, and cells for y; from past the indent they are cells for d too"
      run :=
        operatorRows
          [.rests "|one\ntwo\nthree" "d 3 w" "|" (linewise "one\ntwo\nthree\n"),
            .rests "|one\ntwo\nthree" "y 3 w" "|one\ntwo\nthree" (charwise "one\ntwo\nthree"),
            .rests "|ab\ncd\nef" "d 2 $" "|ef" (linewise "ab\ncd\n"),
            .rests "a|b\ncd\nef" "d 2 $" "|a\nef" (charwise "b\ncd"),
            .rests "|ab\n  cd  \nef" "d 2 e" "|ef" (linewise "ab\n  cd  \n"),
            .rests "ab\n|\ncd" "d e" "|ab" (linewise "\ncd\n"),
            .rests "  |ab\n\tcd \t\nef\n" "d 2 $" "|ef\n" (linewise "  ab\n\tcd \t\n")] },
    { name :=
        "c w on a cell that is not a blank changes to the end of the word, where d w takes the blanks after it too: the word under the cursor counts as the first of a count, also from its last character; a run of punctuation and a WORD are changed whole; on a blank c w is d w; the last word of a line is changed up to the line break; on an empty line the line is changed"
      run :=
        operatorRows
          [.inserts "foo |bar baz" "c w" "foo | baz" (charwise "bar"),
            .rests "foo |bar baz" "d w" "foo |baz" (charwise "bar "),
            .inserts "foo ba|r baz" "c w" "foo ba| baz" (charwise "r"),
            .inserts "foo |bar baz qux" "c 2 w" "foo | qux" (charwise "bar baz"),
            .inserts "foo ba|r baz qux" "c 2 w" "foo ba| qux" (charwise "r baz"),
            .inserts "foo |.,bar" "c w" "foo |bar" (charwise ".,"),
            .inserts "foo |b.r baz" "c W" "foo | baz" (charwise "b.r"),
            .inserts "foo|   bar" "c w" "foo|bar" (charwise "   "),
            .inserts "foo|\t bar" "c w" "foo|bar" (charwise "\t "),
            .inserts "foo |bar\nbaz" "c w" "foo |\nbaz" (charwise "bar"),
            .inserts "ab\n|\ncd" "c w" "ab\n|\ncd" (linewise "\n")] },
    { name :=
        "j and k under an operator take whole lines: on the last line j fails and on the first k does, and the operator gives up; a count past the text stops at the last line and does not fail"
      run := do
        let held ←
          operatorRows
              [.givesUp "ab\n|cd" "d j", .givesUp "ab\n|cd" "c j", .givesUp "|ab\ncd" "d k",
                .givesUp "ab\n|cd\n" "y j",
                .rests "ab\n|cd\nef" "d 5 j" "|ab" (linewise "cd\nef\n"),
                .rests "ab\ncd\n|ef" "y 5 k" "|ab\ncd\nef" (linewise "ab\ncd\nef\n")]
        return held &&
            evilGaveUp (evilEdited "ab\n|cd" "d j") "ab\n|cd" (Evil.cannotMove Evil.down.name) &&
            evilGaveUp (evilEdited "|ab\ncd" "d k") "|ab\ncd" (Evil.cannotMove Evil.up.name) },
    { name :=
        "a line-wise deletion leaves the text ending the way it ended: to a last line that ends in a line feed the lines go with their line breaks, to one that does not the line break before the first goes instead, and deleting every line leaves the empty text; a line-wise register of a last line with no line feed ends in a line feed all the same"
      run :=
        operatorRows
          [.rests "ab\n|cd\n" "d G" "|ab\n" (linewise "cd\n"),
            .rests "ab\n|cd" "d G" "|ab" (linewise "cd\n"),
            .rests "|ab\ncd" "d G" "|" (linewise "ab\ncd\n"),
            .rests "|ab\ncd\n" "d G" "|" (linewise "ab\ncd\n"),
            .rests "ab\nc|d" "y G" "ab\n|cd" (linewise "cd\n"),
            .inserts "ab\nc|d" "c G" "ab\n|" (linewise "cd\n")] },
    { name :=
        "in a buffer whose lines end in a carriage return and line feed, a line-wise register of a last line with no line break ends in that, and the deletion takes the whole line break before the line"
      run :=
        pure <|
          let start : TextM EditorState := do
            let state ← evilState "ab\r\ncd" 4
            return { state with
                buffers := state.buffers.map (·.map ({ · with lineEnding := .crlf })) }
          match (Loop.Driver.over evilHanded (fun _ => none) start editorModel).toOption with
          | none => false
          | some driver =>
            let deleted := evilFed driver "d G"
            evilShown deleted == "|ab" &&
              deleted.loop.state.register? Evil.unnamed == linewise "cd\r\n" },
    { name :=
        "a departure from Vim, recorded: a cursor cannot rest in the empty last row. d $ on the only word of the last line of a text with no final line feed leaves the text Vim writes, and the cursor on the line above, where Vim's is on the emptied line"
      run := operatorRows [.rests "ab\n|cd" "d $" "a|b\n" (charwise "cd")] },
    { name :=
        "a motion that fails after it moved cancels the operator and leaves the cursor where it got to, as Vim does: when b or B with a count comes to rest on an empty first line with steps left over, the cursor is on that line, nothing is deleted, changed or yanked, the register is as it was, and the view is in normal state; the echo area says the sentence the function makes of the motion's name"
      run := do
        let held ←
          operatorRows
              [.breaksOff "\nab |cd" "d 3 b" "|\nab cd", .breaksOff "\nab |cd" "c 3 B" "|\nab cd",
                .breaksOff "\nab |cd" "y 3 b" "|\nab cd", .breaksOff "\nab |cd" "d 3 B" "|\nab cd",
                .breaksOff "\nab |cd" "c 3 b" "|\nab cd", .breaksOff "\nab |cd" "y 3 B" "|\nab cd",
                .breaksOff "\n|ab" "d 2 b" "|\nab", .breaksOff "\n\nab |cd" "d 9 b" "|\n\nab cd",
                .breaksOff "\nab |cd\n" "d 3 b" "|\nab cd\n",
                -- With no step left over the motion has not failed.
                .rests "\nab |cd" "d 2 b" "|cd" (charwise "\nab "),
                .rests " a|b" "d 2 b" "|b" (charwise " a"), .givesUp "|\nab" "d b"]
        return held &&
            (evilEdited "\nab |cd" "d 3 b").map (·.echo) ==
              some s!"{Vim.operateCommand}: {Evil.cannotMove Evil.wordBackward.name}" &&
            (evilEdited "\nab |cd" "c 3 B").map (·.echo) ==
              some s!"{Vim.operateCommand}: {Evil.cannotMove Evil.bigwordBackward.name}" &&
            -- The cursor a cancelled c leaves is one range of normal state's
            -- shape, and the window keeps no wanted column: k kept one.
            ((evilDriver "\nab cd\ne|f").map fun driver =>
                let moved := evilFed driver "k"
                let broke := evilFed moved "c 3 b"
                (((moved.loop.state.window? ⟨0⟩).bind (·.wanted)).isSome,
                  (broke.loop.state.window? ⟨0⟩).bind (·.wanted), evilSelection broke)) ==
              some
                (true, none, some { ranges := #[⟨0, 0⟩], shape := (vimDefaultReport "").shape }) },
    { name :=
        "the other motions under an operator with a count they cannot go the whole way of, as Vim has them: w, W, e and E at the text's end take what there is and do not fail, with and without a final line feed; h and l take the cells there are on the line, and none at a line's start or on an empty line; j and k with a count past the text stop at the last line and at the first, and $ at the last line's end; on the last line j and a counted $ fail, and on the first k does, each where it is, so the operator gives up with nothing moved"
      run :=
        operatorRows
          [.rests "ab |cd" "d 3 w" "ab| " (charwise "cd"),
            .rests "ab c|d" "d 3 w" "ab |c" (charwise "d"),
            .rests "ab |cd\n" "d 3 w" "ab| \n" (charwise "cd"),
            .inserts "ab |cd" "c 3 w" "ab |" (charwise "cd"),
            .rests "ab |cd" "y 3 w" "ab |cd" (charwise "cd"),
            .rests "ab |cd" "d 3 W" "ab| " (charwise "cd"),
            .inserts "ab c|d" "c 3 W" "ab c|" (charwise "d"),
            .rests "ab |cd\n" "y 3 W" "ab |cd\n" (charwise "cd"),
            .rests "ab |cd" "d 3 e" "ab| " (charwise "cd"),
            .rests "ab c|d" "d 3 e" "ab |c" (charwise "d"),
            .rests "ab |cd\n" "d 3 e" "ab| \n" (charwise "cd"),
            .inserts "ab |cd" "c 3 e" "ab |" (charwise "cd"),
            .rests "ab c|d" "y 3 e" "ab c|d" (charwise "d"),
            .rests "ab |cd" "d 3 E" "ab| " (charwise "cd"),
            .inserts "ab c|d" "c 3 E" "ab c|" (charwise "d"),
            .rests "ab |cd\n" "y 3 E" "ab |cd\n" (charwise "cd"),
            .rests "ab c|d\n" "d 2 w" "ab |c\n" (charwise "d"),
            .rests "ab c|d\n" "d 2 e" "ab |c\n" (charwise "d"),
            .rests "a|bcd" "d 3 h" "|bcd" (charwise "a"),
            .rests "ab\n|cd" "d 3 h" "ab\n|cd" asItWas,
            .inserts "ab\n|cd" "c 3 h" "ab\n|cd" asItWas,
            .rests "ab\nc|d" "y 3 h" "ab\n|cd" (charwise "c"),
            .rests "ab|cd\nef" "d 5 l" "a|b\nef" (charwise "cd"),
            .rests "abc|d\nef" "d 3 l" "ab|c\nef" (charwise "d"),
            .inserts "ab|cd\nef" "c 5 l" "ab|\nef" (charwise "cd"),
            .rests "ab|cd\nef" "y 5 l" "ab|cd\nef" (charwise "cd"),
            .rests "ab\n|\ncd" "d 3 l" "ab\n|\ncd" asItWas,
            .rests "ab\n|cd\nef" "d 3 j" "|ab" (linewise "cd\nef\n"),
            .givesUp "ab\ncd\n|ef" "d 3 j", .givesUp "ab\ncd\n|ef" "c 3 j",
            .givesUp "ab\ncd\ne|f" "y 3 j",
            .rests "ab\n|cd\nef" "d 3 k" "|ef" (linewise "ab\ncd\n"),
            .givesUp "|ab\ncd\nef" "d 3 k", .givesUp "a|b\ncd" "c 3 k",
            .rests "ab\nc|d" "y 3 k" "a|b\ncd" (linewise "ab\ncd\n"),
            .rests "a|b\ncd\nef" "d 3 $" "|a" (charwise "b\ncd\nef"),
            .rests "ab\nc|d\nef" "d 3 $" "ab\n|c" (charwise "d\nef"),
            .givesUp "ab\ncd\ne|f" "d 3 $", .givesUp "ab\ncd\n|ef" "c 3 $"] },
    { name :=
        "a change and the text typed after it are one step of the history: c l deletes the cell and leaves its group open, the typed text joins it, <Escape> closes it as one node, and one undo request gives the text from before the change"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let changed := evilFed driver "c l"
            let typed := evilFed changed "X Y"
            let ended := evilFed typed "<Escape>"
            evilHistory changed == some (1, true) && evilShown changed == "a|c" &&
              evilHistory typed == some (1, true) &&
              evilShown typed == "aXY|c" &&
              evilHistory ended == some (2, false) &&
              evilShown ended == "aX|Yc" &&
              evilText (evilUndone ended) == some "abc" },
    { name :=
        "a change begins an insert only when a key that enters insert state runs it: operate with the operator change, run by its name in normal state, deletes the cell into the register and leaves the cursor resting there, in normal state"
      run :=
        pure <|
          evilOperated "a|bc"
                [.str Evil.change.name, .str "motion", .str Evil.right.name, .nat 0, .str ""] ==
              some ⟨"a|c", charwise "b", false, ""⟩ &&
            evilOperated "ab|c"
                [.str Evil.change.name, .str "motion", .str Evil.right.name, .nat 0, .str ""] ==
              some ⟨"a|b", charwise "c", false, ""⟩ &&
            evilOperated "a|bc"
                [.str Evil.yank.name, .str "motion", .str Evil.right.name, .nat 2, .str ""] ==
              some ⟨"a|bc", charwise "bc", false, ""⟩ },
    { name :=
        "operate gives up, with the sentence its function makes and nothing changed, when it names an operator no entry has, a motion no entry has, a text object no entry has, a text object that is not there, a kind there is none of, and when its arguments are not an operator's"
      run :=
        pure <|
          let operated (arguments : List Argument) := evilOperated "a|bc" arguments
          evilGaveUp (operated [.str "frob", .str "motion", .str Evil.right.name, .nat 0, .str ""])
              "a|bc" (Evil.noSuchOperator "frob") &&
            evilGaveUp
              (operated [.str Evil.delete.name, .str "motion", .str "nowhere", .nat 0, .str ""])
              "a|bc" (Evil.noSuchMotion "nowhere") &&
            evilGaveUp
              (operated [.str Evil.delete.name, .str "text-object", .str "word", .nat 0, .str ""])
              "a|bc" (Evil.noSuchObject "word") &&
            evilGaveUp
              (operated
                [.str Evil.delete.name, .str "text-object", .str Evil.innerParen.name, .nat 0,
                  .str ""])
              "a|bc" (Evil.noObjectHere Evil.innerParen.name) &&
            evilGaveUp (operated [.str Evil.delete.name, .str "sideways", .str "", .nat 0, .str ""])
              "a|bc" Evil.noOperatorNamed &&
            evilGaveUp (operated []) "a|bc" Evil.noOperatorNamed &&
            evilGaveUp (operated [.str Evil.delete.name, .str "motion"]) "a|bc"
              Evil.noOperatorNamed &&
            operated
                [.str Evil.delete.name, .str "motion", .str Evil.right.name, .nat 2, .str ""] ==
              some ⟨"|a", charwise "bc", false, ""⟩ },
    { name :=
        "an operator leaves the window with no wanted column: after j the window keeps one, and after d l it keeps none"
      run :=
        pure <|
          match evilDriver "ab|cd\nxyz\nabcd" with
          | none => false
          | some driver =>
            let wanted (driver : EvilDriver) := (driver.loop.state.window? ⟨0⟩).bind (·.wanted)
            let moved := evilFed driver "j"
            let deleted := evilFed moved "d l"
            (wanted moved).isSome && (wanted deleted).isNone &&
              evilShown deleted == "abcd\nx|y\nabcd" },
    { name :=
        "a deletion is one step of the history: after d l the buffer's tree has one node more and nothing pending, and one undo request gives the text from before it"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let deleted := evilFed driver "d l"
            evilHistory driver == some (1, false) && evilHistory deleted == some (2, false) &&
              evilText deleted == some "ac" &&
              evilText (evilUndone deleted) == some "abc" }]

/-- The oracle table's rows for the operators over a visual selection: a
`v` selection is acted on through the cell under its head, and a `V`
selection as whole lines. -/
def selectionRows : List OperatorRow :=
  [.rests "foo |bar baz" "v w d" "foo |az" (charwise "bar b"),
    .rests "foo |bar baz" "v w y" "foo |bar baz" (charwise "bar b"),
    .inserts "foo |bar baz" "v w c" "foo |az" (charwise "bar b"),
    .rests "foo bar |baz" "v b y" "foo |bar baz" (charwise "bar b"),
    .rests "a|bc\ndef" "v $ d" "a|def" (charwise "bc\n"),
    .rests "a|bc\ndef\nghi" "v j d" "a|f\nghi" (charwise "bc\nde"),
    .rests "ab\n|\ncd" "v d" "ab\n|cd" (charwise "\n"),
    .rests "ab\nc|d\n" "v $ d" "ab\n|c\n" (charwise "d"), .rests "ab\n|\n" "v d" "ab\n|\n" asItWas,
    .rests "abc\nd|ef\nghi" "V d" "abc\n|ghi" (linewise "def\n"),
    .rests "abc\nd|ef\nghi" "V y" "abc\n|def\nghi" (linewise "def\n"),
    .rests "abc\nd|ef\nghi" "V j y" "abc\n|def\nghi" (linewise "def\nghi\n"),
    .rests "abc\nd|ef\nghi" "V k y" "a|bc\ndef\nghi" (linewise "abc\ndef\n"),
    .rests "abc\nd|ef\nghi" "V j d" "|abc" (linewise "def\nghi\n"),
    .rests "abc\n  d|ef\nghi\n  jkl" "V j d" "abc\n  |jkl" (linewise "  def\nghi\n"),
    .inserts "abc\nd|ef\nghi" "V c" "abc\n|\nghi" (linewise "def\n"),
    .inserts "abc\nd|ef\nghi" "V j c" "abc\n|" (linewise "def\nghi\n")]

/-- The checks of evil's operators over a visual selection
(`Editor/Evil/Operators.lean`), by key, as `evilOperatorChecks` are. -/
def evilSelectionChecks : List Check :=
  [{  name :=
        "d, c and y on a v selection act on the inclusive range, and on a V selection on whole lines: the text, the cursor and the unnamed register are Vim's, and the view is left in normal state, or in insert state for c"
      run := operatorRows selectionRows },
    { name :=
        "an operator's key leaves the visual state with one cursor: after it the selection is one range with both ends on the cursor, of normal state's shape, and a motion moves the cursor alone"
      run :=
        pure <|
          let normal := (vimDefaultReport "").shape
          let cursor (fixture typed : String) (head : Nat) : Bool :=
            (evilSelected fixture typed).map (fun (ranges, shape, _) => (ranges, shape)) ==
              some ([(head, head)], normal)
          cursor "foo |bar baz qux" "v w d" 4 && cursor "foo |bar baz qux" "v w y" 4 &&
            cursor "abc\nd|ef\nghi" "V j y" 4 &&
            cursor "abc\nd|ef\nghi" "V d" 4 &&
            cursor "foo |bar baz qux" "v w y w" 8 &&
            cursor "foo |bar baz qux" "v w c <Escape>" 3 },
    { name :=
        "a count typed before the operator of a visual selection changes nothing: the selection is what is acted on"
      run :=
        operatorRows
          [.rests "foo |bar baz" "v w 3 d" "foo |az" (charwise "bar b"),
            .rests "abc\nd|ef\nghi" "V 2 y" "abc\n|def\nghi" (linewise "def\n")] }]

/-- The oracle table's rows for each operator over each text object, each
run through Vim 9.1.1752 headless (`vim -Nu NONE -es`), with what an insert
leaves read off a marker typed in it: every default operator over every
object name, then the rules of `:help text-objects` and Vim 9.1's
`textobject.c` one by one. Two rows differ from Vim's own report and are the
editor's: a deletion of every line leaves the empty text, where Vim keeps
one empty line, and an empty object is no give-up, as Vim's own no-op is no
error. The last rows are the blocks' quoted brackets: the walk to the
closing bracket passes over those Vim guesses are quoted, with the cursor
inside the string and outside it, in a line with an odd number of quotes,
past an escaped quote, across lines and for each kind, and the walk back
to the opening one does not, so a single-quoted closing bracket before the
cursor leaves no block. -/
def objectOperatorRows : List OperatorRow :=
  [.rests "foo b|ar baz" "d i w" "foo | baz" (charwise "bar"),
    .inserts "foo b|ar baz" "c i w" "foo | baz" (charwise "bar"),
    .rests "foo b|ar baz" "y i w" "foo |bar baz" (charwise "bar"),
    .rests "foo b|ar baz" "d a w" "foo |baz" (charwise "bar "),
    .inserts "foo b|ar baz" "c a w" "foo |baz" (charwise "bar "),
    .rests "foo b|ar baz" "y a w" "foo |bar baz" (charwise "bar "),
    .rests "foo b|a.r baz" "d i W" "foo | baz" (charwise "ba.r"),
    .inserts "foo b|a.r baz" "c i W" "foo | baz" (charwise "ba.r"),
    .rests "foo b|a.r baz" "y i W" "foo |ba.r baz" (charwise "ba.r"),
    .rests "foo b|a.r baz" "d a W" "foo |baz" (charwise "ba.r "),
    .inserts "foo b|a.r baz" "c a W" "foo |baz" (charwise "ba.r "),
    .rests "foo b|a.r baz" "y a W" "foo |ba.r baz" (charwise "ba.r "),
    .rests "x = \"a|b c\" y" "d i \"" "x = \"|\" y" (charwise "ab c"),
    .inserts "x = \"a|b c\" y" "c i \"" "x = \"|\" y" (charwise "ab c"),
    .rests "x = \"a|b c\" y" "y i \"" "x = \"|ab c\" y" (charwise "ab c"),
    .rests "x = \"a|b c\" y" "d a \"" "x = |y" (charwise "\"ab c\" "),
    .inserts "x = \"a|b c\" y" "c a \"" "x = |y" (charwise "\"ab c\" "),
    .rests "x = \"a|b c\" y" "y a \"" "x = |\"ab c\" y" (charwise "\"ab c\" "),
    .rests "x = 'a|b c' y" "d i '" "x = '|' y" (charwise "ab c"),
    .inserts "x = 'a|b c' y" "c i '" "x = '|' y" (charwise "ab c"),
    .rests "x = 'a|b c' y" "y i '" "x = '|ab c' y" (charwise "ab c"),
    .rests "x = 'a|b c' y" "d a '" "x = |y" (charwise "'ab c' "),
    .inserts "x = 'a|b c' y" "c a '" "x = |y" (charwise "'ab c' "),
    .rests "x = 'a|b c' y" "y a '" "x = |'ab c' y" (charwise "'ab c' "),
    .rests "x = `a|b c` y" "d i `" "x = `|` y" (charwise "ab c"),
    .inserts "x = `a|b c` y" "c i `" "x = `|` y" (charwise "ab c"),
    .rests "x = `a|b c` y" "y i `" "x = `|ab c` y" (charwise "ab c"),
    .rests "x = `a|b c` y" "d a `" "x = |y" (charwise "`ab c` "),
    .inserts "x = `a|b c` y" "c a `" "x = |y" (charwise "`ab c` "),
    .rests "x = `a|b c` y" "y a `" "x = |`ab c` y" (charwise "`ab c` "),
    .rests "f(a, |b)" "d i (" "f(|)" (charwise "a, b"),
    .inserts "f(a, |b)" "c i (" "f(|)" (charwise "a, b"),
    .rests "f(a, |b)" "y i (" "f(|a, b)" (charwise "a, b"),
    .rests "f(a, |b)" "d a (" "|f" (charwise "(a, b)"),
    .inserts "f(a, |b)" "c a (" "f|" (charwise "(a, b)"),
    .rests "f(a, |b)" "y a (" "f|(a, b)" (charwise "(a, b)"),
    .rests "x [a |b] y" "d i [" "x [|] y" (charwise "a b"),
    .inserts "x [a |b] y" "c i [" "x [|] y" (charwise "a b"),
    .rests "x [a |b] y" "y i [" "x [|a b] y" (charwise "a b"),
    .rests "x [a |b] y" "d a [" "x | y" (charwise "[a b]"),
    .inserts "x [a |b] y" "c a [" "x | y" (charwise "[a b]"),
    .rests "x [a |b] y" "y a [" "x |[a b] y" (charwise "[a b]"),
    .rests "if x {\n  a|b\n  cd\n}\n" "d i {" "if x {\n|}\n" (linewise "  ab\n  cd\n"),
    .inserts "if x {\n  a|b\n  cd\n}\n" "c i {" "if x {\n|\n}\n" (linewise "  ab\n  cd\n"),
    .rests "if x {\n  a|b\n  cd\n}\n" "y i {" "if x {\n|  ab\n  cd\n}\n" (linewise "  ab\n  cd\n"),
    .rests "if x {\n  a|b\n  cd\n}\n" "d a {" "if x| \n" (charwise "{\n  ab\n  cd\n}"),
    .inserts "if x {\n  a|b\n  cd\n}\n" "c a {" "if x |\n" (charwise "{\n  ab\n  cd\n}"),
    .rests "if x {\n  a|b\n  cd\n}\n" "y a {" "if x |{\n  ab\n  cd\n}\n"
      (charwise "{\n  ab\n  cd\n}"),
    .rests "foo b|ar" "d a w" "fo|o" (charwise " bar"),
    .rests "foo|  bar" "d i w" "foo|bar" (charwise "  "),
    .rests "foo|  bar" "d a w" "fo|o" (charwise "  bar"),
    .rests "|ab cd ef" "d 3 i w" "| ef" (charwise "ab cd"),
    .rests "|ab cd ef" "d 2 a w" "|ef" (charwise "ab cd "),
    .rests "foo b|a.r baz" "d i w" "foo |.r baz" (charwise "ba"),
    .rests "  |foo bar" "d a w" "  |bar" (charwise "foo "),
    .rests "  foo b|ar" "d a w" "  fo|o" (charwise " bar"),
    .rests "ab c|d\nef gh" "d 3 i w" "ab |gh" (charwise "cd\nef "),
    .rests "ab c|d\nef gh" "d 2 a w" "ab |gh" (charwise "cd\nef "),
    .rests "|ab\n\ncd" "d 2 i w" "|cd" (linewise "ab\n\n"),
    .rests "ab|  \n\ncd" "d a w" "a|b\ncd" (charwise "  \n"),
    .rests "ab\n|\ncd" "d a w" "|ab" (linewise "\ncd\n"),
    .rests "ab\n|\ncd" "d i w" "ab\n|\ncd" asItWas,
    .rests "ab\n|\ncd" "y i w" "ab\n|\ncd" (charwise ""),
    .inserts "ab\n|\ncd" "c i w" "ab\n|\ncd" (charwise ""),
    .rests "ab c|d." "d 2 a w" "a|b" (charwise " cd."), .givesUp "ab c|d" "d 2 a w",
    .inserts "foo b|ar baz" "c a w" "foo |baz" (charwise "bar "),
    .rests "foo b|ar baz" "2 d a w" "fo|o" (charwise " bar baz"),
    .rests "x = \"a|b c\"" "d a \"" "x |=" (charwise " \"ab c\""),
    .rests "|x = \"ab\" y" "d i \"" "x = \"|\" y" (charwise "ab"),
    .rests "x = \"ab|\" y" "d i \"" "x = \"|\" y" (charwise "ab"),
    .rests "\"a\" |x \"b\"" "d i \"" "\"a\"|\"b\"" (charwise " x "),
    .rests "x = \"a|b c\" y" "d 2 i \"" "x = | y" (charwise "\"ab c\""),
    .rests "x = \"a|b c\" y" "y 2 i \"" "x = |\"ab c\" y" (charwise "\"ab c\""),
    .rests "x \"a\\\"|b\" y" "d i \"" "x \"|\" y" (charwise "a\\\"b"),
    .rests "x \\\"a|b\" y" "d i \"" "x \\\"|\" y" (charwise "ab"),
    .inserts "x = \"|\" y" "c i \"" "x = \"|\" y" asItWas,
    .rests "x = \"|\" y" "d i \"" "x = \"|\" y" asItWas, .givesUp "a|b" "d i \"",
    .givesUp "x \"ab\" |y" "d i \"",
    .rests "x = \"a|b c\" y" "d 3 a \"" "x = |y" (charwise "\"ab c\" "),
    .rests "\"a\" \"b|\"" "d i \"" "\"a\" \"|\"" (charwise "b"),
    .rests "x \"a|b\" \ty" "d a \"" "x |y" (charwise "\"ab\" \t"),
    .rests "  \"a|b\"" "d a \"" "|" (charwise "  \"ab\""),
    .rests "f|(a, b)" "d i (" "f(|)" (charwise "a, b"),
    .rests "f(a, b|)" "d i (" "f(|)" (charwise "a, b"),
    .rests "f(a, (b|), c)" "d 2 i (" "f(|)" (charwise "a, (b), c"),
    .rests "|f(a)" "d i (" "f(|)" (charwise "a"),
    .rests "|x ((a))" "d 2 i (" "x ((|))" (charwise "a"), .givesUp "|x) (a)" "d i (",
    .givesUp "(|x) (a)" "d 2 i (", .rests "f(a \\( |b)" "d i (" "f(|)" (charwise "a \\( b"),
    .givesUp "\\(a |b\\)" "d i (", .rests "f|()" "d i (" "f(|)" asItWas,
    .rests "f|()" "y i (" "f(|)" (charwise ""), .inserts "f|()" "c i (" "f(|)" asItWas,
    .rests "{ a\n  b|\n}" "d i {" "|{\n}" (charwise " a\n  b"),
    .rests "if x {\n  a|b\n}\n" "d a {" "if x| \n" (charwise "{\n  ab\n}"),
    .rests "  |  {\n  a\n  }\n" "d i {" "    {\n  |}\n" (linewise "  a\n"),
    .rests "  |  {\n  a\n  }\n" "d a {" "|" (linewise "    {\n  a\n  }\n"),
    .rests "{a {b |c} d}" "d 2 i {" "{|}" (charwise "a {b c} d"),
    .rests "|x {a}" "d i {" "x {|}" (charwise "a"),
    .rests "|x\n(a)" "d i (" "x\n(|)" (charwise "a"),
    .rests "|x (a\n)" "d i (" "x |(\n)" (charwise "a"), .rests "|{\n}" "d i {" "{\n|}" asItWas,
    .rests "|{\n}" "y i {" "{\n|}" (charwise ""), .rests "|{\n\n}" "d i {" "{\n|}" (linewise "\n"),
    .rests "|{\n  \n}" "d i {" "{\n|  \n}" asItWas,
    .rests "|{\n a\n  \n}" "d i {" "{\n | \n}" (linewise " a\n"),
    .rests "if x {\n  a|b\n  cd\n}\n" "y i {" "if x {\n|  ab\n  cd\n}\n" (linewise "  ab\n  cd\n"),
    .rests "f(a, |b)" "d i )" "f(|)" (charwise "a, b"),
    .rests "f(a, |b)" "d i b" "f(|)" (charwise "a, b"),
    .rests "f(a, |b)" "d a )" "|f" (charwise "(a, b)"),
    .rests "f(a, |b)" "d a b" "|f" (charwise "(a, b)"),
    .rests "x [a |b] y" "d i ]" "x [|] y" (charwise "a b"),
    .rests "x [a |b] y" "d a ]" "x | y" (charwise "[a b]"),
    .rests "{a |b}" "d i }" "{|}" (charwise "a b"), .rests "{a |b}" "d i B" "{|}" (charwise "a b"),
    .rests "{a |b}" "d a }" "|" (charwise "{a b}"), .rests "{a |b}" "d a B" "|" (charwise "{a b}"),
    .rests "(a [b|) c]" "d i [" "(a [|]" (charwise "b) c"),
    .rests "(a \"b|)\" c)" "d i (" "(|)" (charwise "a \"b)\" c"),
    .rests "(a \"b|)\" c)" "d a (" "|" (charwise "(a \"b)\" c)"),
    .inserts "(a \"b|)\" c)" "c i (" "(|)" (charwise "a \"b)\" c"),
    .rests "\"(|a)\"" "d i (" "\"(|)\"" (charwise "a"),
    .rests "x \" (a \"b|)\" c)" "d i (" "x \" (|)\" c)" (charwise "a \"b"),
    .rests "(a \\\"b|)\" c)" "d i (" "(|)\" c)" (charwise "a \\\"b"),
    .rests "{\n  a|\n  \"}\"\n}" "d i {" "{\n|}" (linewise "  a\n  \"}\"\n"),
    .rests "{a \"|}\" b}" "d i {" "{|}" (charwise "a \"}\" b"),
    .rests "[a \"|]\" b]" "d i [" "[|]" (charwise "a \"]\" b"),
    .rests "x|(a ')' b)" "d i (" "x(|)" (charwise "a ')' b"), .givesUp "(a ')' |b)" "d i ("]

/-- The JSON text the tree's text objects are checked over, on one line:
an object holding a pair of an array and a pair of an object. -/
def treeText : String :=
  "{\"a\": [1, 2], \"b\": {\"c\": 3}}"

/-- `treeText` with the cursor at the byte offset `at`. -/
def treeAt (at_ : Nat) : String :=
  withBar treeText at_

/-- The rows of the syntax tree's text objects under an operator, on a test
mode of the model's JSON grammar (`jsonTextObjects`), written by hand: each
default operator over each of the six objects, a count, an argument with a
comma after, before and neither, a pair as an argument, dot repeat over
`a a`, and the objects that are not there on a buffer with no syntax
tree; and, on the test mode of `jsonPairObjects`, the inside of a function
and of a class from a cursor on the key, in the node but outside its
inside. -/
def treeObjectOperatorRows : List OperatorRow :=
  let onTree (row : OperatorRow) : OperatorRow := { row with tree := some jsonTextObjects }
  let onPairs (row : OperatorRow) : OperatorRow := { row with tree := some jsonPairObjects }
  let three := treeAt 25
  let two := treeAt 10
  (([.rests three "d a f" "{\"a\": [1, 2], \"b\": |}" (charwise "{\"c\": 3}"),
            .inserts three "c a f" "{\"a\": [1, 2], \"b\": |}" (charwise "{\"c\": 3}"),
            .rests three "y a f" "{\"a\": [1, 2], \"b\": |{\"c\": 3}}" (charwise "{\"c\": 3}"),
            .rests three "d i f" "{\"a\": [1, 2], \"b\": {|}}" (charwise "\"c\": 3"),
            .inserts three "c i f" "{\"a\": [1, 2], \"b\": {|}}" (charwise "\"c\": 3"),
            .rests three "y i f" "{\"a\": [1, 2], \"b\": {|\"c\": 3}}" (charwise "\"c\": 3"),
            .rests three "d 2 a f" "|" (charwise treeText),
            .rests two "d a c" "{\"a\": |, \"b\": {\"c\": 3}}" (charwise "[1, 2]"),
            .inserts two "c a c" "{\"a\": |, \"b\": {\"c\": 3}}" (charwise "[1, 2]"),
            .rests two "y a c" "{\"a\": |[1, 2], \"b\": {\"c\": 3}}" (charwise "[1, 2]"),
            .rests two "d i c" "{\"a\": [|], \"b\": {\"c\": 3}}" (charwise "1, 2"),
            .inserts two "c i c" "{\"a\": [|], \"b\": {\"c\": 3}}" (charwise "1, 2"),
            .rests two "y i c" "{\"a\": [|1, 2], \"b\": {\"c\": 3}}" (charwise "1, 2"),
            .rests two "d a a" "{\"a\": [1|], \"b\": {\"c\": 3}}" (charwise ", 2"),
            .inserts two "c a a" "{\"a\": [1|], \"b\": {\"c\": 3}}" (charwise ", 2"),
            .rests two "y a a" "{\"a\": [1|, 2], \"b\": {\"c\": 3}}" (charwise ", 2"),
            .rests two "d i a" "{\"a\": [1, |], \"b\": {\"c\": 3}}" (charwise "2"),
            .inserts two "c i a" "{\"a\": [1, |], \"b\": {\"c\": 3}}" (charwise "2"),
            .rests two "y i a" "{\"a\": [1, |2], \"b\": {\"c\": 3}}" (charwise "2"),
            .rests (treeAt 7) "d a a" "{\"a\": [|2], \"b\": {\"c\": 3}}" (charwise "1, "),
            .rests (treeAt 2) "d a a" "{|\"b\": {\"c\": 3}}" (charwise "\"a\": [1, 2], "),
            .rests three "d a a" "{\"a\": [1, 2], \"b\": {|}}" (charwise "\"c\": 3"),
            .rests (treeAt 7) "d a a ." "{\"a\": [|], \"b\": {\"c\": 3}}" (charwise "2"),
            .rests (treeAt 3) "d i a" "{|, \"b\": {\"c\": 3}}" (charwise "\"a\": [1, 2]"),
            .givesUp three "d a c", .givesUp (treeAt 0) "d i a"] :
          List OperatorRow).map
      onTree) ++
    [.givesUp three "d a f", .givesUp three "d i f", .givesUp two "d a c", .givesUp two "d i c",
      .givesUp two "d a a", .givesUp two "d i a"] ++
    ([.rests (treeAt 15) "d i f" "{\"a\": [1, 2], \"b\": {|}}" (charwise "\"c\": 3"),
            .rests (treeAt 2) "d i c" "{\"a\": [|], \"b\": {\"c\": 3}}" (charwise "1, 2"),
            .rests (treeAt 15) "d a f" "{\"a\": [1, 2], |}" (charwise "\"b\": {\"c\": 3}"),
            .givesUp (treeAt 21) "d i f"] :
          List OperatorRow).map
      onPairs

/-- The rows of the syntax tree's text objects in a visual state, on the
test mode of `treeObjectOperatorRows`, written by hand: the text and the
cursor, the keys, the selection's one range as an anchor and a head, and
the text it covers. One-cell selections of each object, a wider selection
extended to the next node out, a count, and an object that is not there,
which leaves the selection as it was. -/
def treeSelectionRows : List (String × String × List (Nat × Nat) × List String) :=
  [(treeAt 25, "v a f", [(19, 26)], ["{\"c\": 3}"]), (treeAt 25, "v i f", [(20, 25)], ["\"c\": 3"]),
    (treeAt 10, "v a c", [(6, 11)], ["[1, 2]"]), (treeAt 10, "v i c", [(7, 10)], ["1, 2"]),
    (treeAt 10, "v a a", [(8, 10)], [", 2"]), (treeAt 10, "v i a", [(10, 10)], ["2"]),
    (treeAt 25, "v a f a f", [(0, 27)], [treeText]), (treeAt 25, "v 2 a f", [(0, 27)], [treeText]),
    (treeAt 25, "v a c", [(25, 25)], ["3"])]

/-- The rows of the oracle table for `%` under an operator, each run through
Vim 9.1.1752 headless: inclusive, from the cursor, a bracket after the
cursor on the line included, across lines, and a line with no bracket. -/
def percentOperatorRows : List OperatorRow :=
  [.rests "|(a) b" "d %" "| b" (charwise "(a)"), .rests "|x (a) b" "d %" "| b" (charwise "x (a)"),
    .givesUp "|ab" "d %", .inserts "|(a\nb) c" "c %" "| c" (charwise "(a\nb)"),
    .rests "|(a\nb) c" "y %" "|(a\nb) c" (charwise "(a\nb)")]

/-- The name the default `objects` table binds the key string `key` to, if it
binds one. -/
def objectNamed (key : String) : Option String :=
  Vim.Default.objects.findSome? fun (text, bound) =>
    match bound with
    | .textObject name => if text == key then some name else none
    | _ => none

/-- Every name the default `objects` table binds a key to, once each. -/
def objectNames : List String :=
  (Vim.Default.objects.filterMap fun (_, bound) =>
      match bound with
      | .textObject name => some name
      | _ => none).eraseDups

/-- The JSON text of `indentObjectRows`, its rows mangled: a string holding
a word, parentheses, single quotes and backquotes; an array over two rows;
and an object in an object. -/
def indentObjectText : String :=
  "{\n\"a\": \"x (y) 'z' `w`\",\n      \"b\": [1,\n2],\n \"c\": {\"d\": 3}\n}"

/-- `indentObjectText` with the cursor at the byte offset `at`. -/
def indentObjectAt (at_ : Nat) : String :=
  withBar indentObjectText at_

/-- `indentObjectText` with the rows `rows` re-indented to the levels of its
two-space pretty form, and the cursor on the first non-blank of the row
`cursor`. -/
def indentObjectReindented (rows : List Nat) (cursor : Nat) : String :=
  let pretty := ["", "  ", "  ", "    ", "  ", ""]
  let lines :=
    (indentObjectText.splitOn "\n").zipIdx.map fun (line, row) =>
      if rows.contains row then pretty.getD row "" ++ (line.dropWhile (· == ' ')).toString else line
  let before := (lines.take cursor).foldl (fun walked line => walked + line.utf8ByteSize + 1) 0
  let blanks := ((lines.getD cursor "").takeWhile (· == ' ')).utf8ByteSize
  withBar ("\n".intercalate lines) (before + blanks)

/-- The rows of `=` over each text object the default tables name, in the
indent checks' JSON language (`indentDriver`), written by hand: an object
inside the string re-indents its one row, a bracket and an array the rows
they cover, `i{` the whole lines inside the outer object and `a{` all of
them, a function the inner object's row, and an argument its rows. -/
def indentObjectRows : List OperatorRow :=
  let row1 := indentObjectReindented [1] 1
  let rows23 := indentObjectReindented [2, 3] 2
  [.indents (indentObjectAt 8) "= i w" row1, .indents (indentObjectAt 8) "= a w" row1,
    .indents (indentObjectAt 8) "= i W" row1, .indents (indentObjectAt 8) "= a W" row1,
    .indents (indentObjectAt 8) "= i \"" row1, .indents (indentObjectAt 8) "= a \"" row1,
    .indents (indentObjectAt 15) "= i '" row1, .indents (indentObjectAt 15) "= a '" row1,
    .indents (indentObjectAt 19) "= i `" row1, .indents (indentObjectAt 19) "= a `" row1,
    .indents (indentObjectAt 11) "= i (" row1, .indents (indentObjectAt 11) "= a (" row1,
    .indents (indentObjectAt 36) "= i [" rows23, .indents (indentObjectAt 36) "= a [" rows23,
    .indents (indentObjectAt 3) "= i {" (indentObjectReindented [1, 2, 3, 4] 1),
    .indents (indentObjectAt 3) "= a {" (indentObjectReindented [0, 1, 2, 3, 4, 5] 0),
    .indents (indentObjectAt 51) "= a f" (indentObjectReindented [4] 4),
    .indents (indentObjectAt 51) "= i f" (indentObjectReindented [4] 4),
    .indents (indentObjectAt 36) "= a c" rows23, .indents (indentObjectAt 36) "= i c" rows23,
    .indents (indentObjectAt 39) "= i a" (indentObjectReindented [3] 3),
    .indents (indentObjectAt 39) "= a a" rows23, .givesUp "a|b" "= a f"]

/-- The pairs of an operator's key and a text object's name that the rows of
`objectOperatorRows`, `treeObjectOperatorRows` and `indentObjectRows` have,
with the counts left out. -/
def objectOperatorPairs : List (String × String) :=
  (objectOperatorRows ++ treeObjectOperatorRows ++ indentObjectRows).filterMap fun row =>
    match (row.keys.splitOn " ").filter (fun token => !token.all Char.isDigit) with
    | operator :: rest => (objectNamed (" ".intercalate rest)).map (operator, ·)
    | [] => none

/-- The rows of the oracle table for the text objects in a visual state, each
run through Vim 9.1.1752 headless and read off its marks: the text and the
cursor, the keys, the selection's one range as an anchor and a head, and
the text it covers. A block's closing bracket is found past quoted ones,
and a selection extended to the next pair out passes over a quoted opening
bracket too. Each word, WORD and block object has rows over a selection
made wider forward by a motion or an object, and over one made wider
backward, its head before its anchor, where a block's search starts from
the head and one no bigger than the selection is the next one out; Vim
leaves such a block's selection forward. The last four are an object that is not there, where
the selection is as it was, and the recorded departure of a quote object
over a selection wider than one cell, which is left as it was too. -/
def objectSelectionRows : List (String × String × List (Nat × Nat) × List String) :=
  [("foo b|ar baz", "v i w", [(4, 6)], ["bar"]), ("foo b|ar baz", "v a w", [(4, 7)], ["bar "]),
    ("foo b|a.r baz", "v i W", [(4, 7)], ["ba.r"]), ("foo b|a.r baz", "v a W", [(4, 8)], ["ba.r "]),
    ("a|  b", "v i w", [(1, 2)], ["  "]), ("a|  b", "v a w", [(1, 3)], ["  b"]),
    ("foo b|ar baz", "v 3 i w", [(4, 10)], ["bar baz"]),
    ("foo |bar baz", "v i w i w", [(4, 7)], ["bar "]),
    ("foo |bar baz", "v a w a w", [(4, 10)], ["bar baz"]),
    ("foo b|ar baz", "v b i w", [(5, 3)], [" ba"]),
    ("foo bar b|az", "v h a w", [(9, 4)], ["bar ba"]), ("ab\n|\ncd", "v i w", [(3, 3)], ["\n"]),
    ("ab\n|\ncd", "v a w", [(3, 5)], ["\ncd"]), ("|ab\n\ncd", "v 2 i w", [(0, 4)], ["ab\n\nc"]),
    ("x = \"a|b c\" y", "v i \"", [(5, 8)], ["ab c"]),
    ("x = \"a|b c\" y", "v a \"", [(4, 10)], ["\"ab c\" "]),
    ("|x = \"ab\" y", "v i \"", [(5, 6)], ["ab"]),
    ("x = \"a|b c\" y", "v 2 i \"", [(4, 9)], ["\"ab c\""]),
    ("x \"|\" y", "v i \"", [(3, 2)], ["\"\""]), ("x 'a|b' y", "v i '", [(3, 4)], ["ab"]),
    ("x 'a|b' y", "v a '", [(2, 6)], ["'ab' "]), ("x `a|b` y", "v i `", [(3, 4)], ["ab"]),
    ("x `a|b` y", "v a `", [(2, 6)], ["`ab` "]), ("f(a, |b)", "v i (", [(2, 5)], ["a, b"]),
    ("f(a, |b)", "v a (", [(1, 6)], ["(a, b)"]), ("g(f(a|b))", "v i ( i (", [(2, 6)], ["f(ab)"]),
    ("g(f(|a))", "v i ( a (", [(3, 5)], ["(a)"]), ("g(f(|a))", "v a ( a (", [(1, 6)], ["(f(a))"]),
    ("|x (a)", "v i (", [(3, 3)], ["a"]), ("{\n  a|b\n}", "v i {", [(2, 6)], ["  ab\n"]),
    ("x {\n  a|b\n  }", "v i {", [(4, 8)], ["  ab\n"]), ("x{\n  |}", "v i {", [(3, 2)], ["\n "]),
    ("x [a |b] y", "v i [", [(3, 5)], ["a b"]), ("x [a |b] y", "v a [", [(2, 6)], ["[a b]"]),
    ("{a |b}", "v i {", [(1, 3)], ["a b"]), ("{a |b}", "v a {", [(0, 4)], ["{a b}"]),
    ("f(a|b)", "v l i (", [(2, 3)], ["ab"]), ("f(a|b)", "v l a (", [(1, 4)], ["(ab)"]),
    ("(a \"b|)\" c)", "v i (", [(1, 8)], ["a \"b)\" c"]),
    ("(x \"(\" (|ab) y)", "v i ( i (", [(1, 12)], ["x \"(\" (ab) y"]),
    ("foo b|a.r baz", "v l i W", [(5, 7)], ["a.r"]),
    ("foo |a.r baz", "v i W i W", [(4, 7)], ["a.r "]),
    ("foo b|a.r baz", "v l a W", [(5, 8)], ["a.r "]),
    ("foo b.a|r baz", "v b i W", [(7, 4)], ["b.ar"]),
    ("foo b.r b|a.z", "v h a W", [(9, 4)], ["b.r ba"]),
    ("foo b.r b|a.z", "v h i W", [(9, 7)], [" ba"]), ("x [a |bc] y", "v l i [", [(3, 6)], ["a bc"]),
    ("[x[a|b]]", "v i [ i [", [(1, 5)], ["x[ab]"]),
    ("x [a |bc] y", "v l a [", [(2, 7)], ["[a bc]"]), ("{a |bc}", "v l i {", [(1, 4)], ["a bc"]),
    ("{x{a|b}}", "v i { i {", [(1, 5)], ["x{ab}"]), ("{a |bc}", "v l a {", [(0, 5)], ["{a bc}"]),
    ("{\n  {\n    a|b\n  }\n}", "v i { i {", [(2, 16)], ["  {\n    ab\n  }\n"]),
    ("{\n  a|b\n  cd\n}", "v j i {", [(2, 11)], ["  ab\n  cd\n"]),
    ("x {\n  a|b\n  cd\n  }", "v j i {", [(4, 13)], ["  ab\n  cd\n"]),
    ("f(ab c|d)", "v h i (", [(2, 6)], ["ab cd"]), ("g(f(a|b))", "v h i (", [(2, 6)], ["f(ab)"]),
    ("f(ab c|d)", "v h a (", [(1, 7)], ["(ab cd)"]), ("g(f(a|b))", "v h a (", [(3, 6)], ["(ab)"]),
    ("x [ab c|d] y", "v h i [", [(3, 7)], ["ab cd"]), ("[x[a|b]]", "v h i [", [(1, 5)], ["x[ab]"]),
    ("x [ab c|d] y", "v b a [", [(2, 8)], ["[ab cd]"]),
    ("{ab c|d}", "v h i {", [(1, 5)], ["ab cd"]), ("{x{a|b}}", "v h i {", [(1, 5)], ["x{ab}"]),
    ("{ab c|d}", "v b a {", [(0, 6)], ["{ab cd}"]), ("{x{a|b}}", "v h a {", [(2, 5)], ["{ab}"]),
    ("{\n  {\n    ab|c\n  }\n}", "v k i {", [(2, 17)], ["  {\n    abc\n  }\n"]),
    ("g(f(ab|))", "v h h h a (", [(1, 7)], ["(f(ab))"]),
    ("[x[ab|]]", "v h h h a [", [(0, 6)], ["[x[ab]]"]),
    ("{x{ab|}}", "v h h h a {", [(0, 6)], ["{x{ab}}"]),
    ("g(f(|ab))", "v l l l a (", [(3, 6)], ["(ab)"]),
    ("g(f(ab|))", "v h h h i (", [(2, 6)], ["f(ab)"]),
    ("g(f(|ab))", "v l l l i (", [(2, 6)], ["f(ab)"]),
    ("foo b|a.r baz", "v b a W", [(5, 0)], ["foo ba"]),
    ("foo b|ar baz", "V i w", [(4, 6)], ["bar"]), ("f(|a)", "V i (", [(2, 2)], ["a"]),
    ("f(|a)", "V a b", [(1, 3)], ["(a)"]), ("a|b", "v i (", [(1, 1)], ["b"]),
    ("f|()", "v i (", [(1, 1)], ["("]), ("|{\n}", "v i {", [(0, 0)], ["{"]),
    ("x = \"a|b c\" y", "v l i \"", [(6, 7)], ["b "])]

/-- What is wrong, if anything, with each of `v` and `V` followed by each key
of the default `objects` table, with no count and with a count of 2, from
every position of a text holding `contents` where a normal-state cursor may
rest: the echo area says no refusal, the selection is one range with both
ends at positions of the text, and the view is in `visual`, or, where the
object is not there after `V`, in the state it was in, with the give-up's
sentence said. -/
def visualObjectSweep (contents : String) : List String :=
  let visual := evilBadge "v"
  let visualLine := evilBadge "V"
  ((List.range (contents.utf8ByteSize + 1)).filter (restsWell contents)).flatMap fun position =>
    ["v", "V"].flatMap fun state =>
      Vim.Default.objects.flatMap fun (objectKey, bound) =>
        let name :=
          match bound with
          | .textObject name => name
          | _ => ""
        [false, true].filterMap fun counted =>
          let typed := state ++ (if counted then " 2 " else " ") ++ objectKey
          let what := s!"{typed} at {position} of {repr contents}"
          match
            (Loop.Driver.over evilHanded (fun _ => none) (evilState contents position)
                editorModel).toOption with
          | none => some s!"{what}: no driver"
          | some driver =>
            let after := evilFed driver typed
            let refused := (after.loop.state.echo.splitOn "refused").length != 1
            let atPositions :=
              match evilSelection after with
              | some { ranges := #[range], .. } =>
                [range.anchor, range.head].all fun end_ =>
                  end_ ≤ contents.utf8ByteSize && (String.Pos.Raw.mk end_).IsValid contents
              | _ => false
            let seen := (evilSeen after).bind (·.status[0]?)
            let kept :=
              seen == visual ||
                state == "V" && seen == visualLine &&
                  after.loop.state.echo.endsWith (Evil.noObjectHere name)
            if !refused && atPositions && kept then none
            else
              some s!"{what}: left {repr (evilSelection after)}, echo {repr after.loop.state.echo}"

/-- A row of the text objects query, for the tree objects' rule checks. -/
def objectRow (name : String) (start stop : Nat) : Evil.TreeObjects.Row :=
  { name, start, stop }

/-- The checks of the syntax tree's text-object rule
(`Evil.TreeObjects.choose`, `Editor/Evil/TreeObjects.lean`), pure, over
hand-built rows, answered for a range as the syntax tree port answers: the
rows that overlap it (`SyntaxTree.overlaps`), each range asked recorded. -/
def treeObjectRuleChecks : List Check :=
  let rows :=
    #[objectRow "function.outer" 0 100, objectRow "function.inner" 10 99,
      objectRow "function.outer" 20 60, objectRow "function.inner" 30 59,
      objectRow "function.inner" 31 40, objectRow "function.outer" 20 60,
      objectRow "class.outer" 70 80, objectRow "parameter.inner" 22 25, objectRow "comment" 21 26]
  let ask (first last : Nat) : StateM (List (Nat × Nat)) (Array Evil.TreeObjects.Row) := do
    modify (·.concat (first, last))
    return rows.filter fun row => SyntaxTree.overlaps row.start row.stop first last
  let asked (kind : Evil.TreeObjects.Kind) (inner : Bool) (low high : Nat) (wider : Bool := false)
    (count : Nat := 1) : Option (Nat × Nat) × List (Nat × Nat) :=
    (Evil.TreeObjects.choose ask kind inner low high (high + 1) wider count).run [] |>.run
  let choose (kind : Evil.TreeObjects.Kind) (inner : Bool) (low high : Nat) (wider : Bool := false)
    (count : Nat := 1) := (asked kind inner low high wider count).1
  [{  name := "the smallest node round the cursor comes first, a range captured twice once"
      run :=
        pure
          (choose .function false 35 35 == some (20, 60) &&
            choose .argument false 23 23 == some (22, 25)) },
    { name := "a count takes the node that many out, and too few is no object"
      run :=
        pure
          (choose .function false 35 35 (count := 2) == some (0, 100) &&
            choose .function false 35 35 (count := 3) == none) },
    { name := "a wider selection passes over a node no bigger than it for the next one out"
      run :=
        pure
          (choose .function false 20 59 (wider := true) == some (0, 100) &&
            choose .function false 21 59 (wider := true) == some (20, 60) &&
            choose .function false 20 59 == some (20, 60)) },
    { name := "the inside is the longest inner row within the chosen node"
      run :=
        pure
          (choose .function true 35 35 == some (30, 59) &&
            choose .function true 5 5 == some (10, 99)) },
    { name :=
        "the inside is asked over the chosen node's range, so a cursor in the node outside its inner row has the inside: the selection's cells are asked first, and the node's range only for an inside"
      run :=
        pure
          (asked .function true 5 5 == (some (10, 99), [(5, 6), (0, 100)]) &&
            asked .function true 21 21 == (some (30, 59), [(21, 22), (20, 60)]) &&
            asked .function false 5 5 == (some (0, 100), [(5, 6)]) &&
            asked .argument true 23 23 == (some (22, 25), [(23, 24)]) &&
            asked .class true 35 35 == (none, [(35, 36)])) },
    { name := "a node with no inner row has no inside"
      run :=
        pure (choose .class true 75 75 == none && choose .class false 75 75 == some (70, 80)) },
    { name :=
        "with no node round the cursor there is no object, and names the rule does not read count for nothing"
      run :=
        pure
          (choose .class false 35 35 == none && choose .argument false 21 21 == none &&
            choose .function false 100 100 == none) }]

/-- The checks of evil's text objects (`Editor/Evil/Objects.lean`), by key,
on the loop's driver over the editor's models, under the Vim scheme that
ships: what each operator takes over each object and what each object
selects in a visual state, against Vim 9.1's rows, `%` under an operator,
the tables' completeness, and two sweeps. -/
def evilObjectChecks : List Check :=
  [{  name :=
        "an operator over each text object takes the range Vim 9.1 documents: the words and WORDs with their blanks and counts, the quoted strings and their blanks, the blocks with an escaped bracket passed over, a block found forward with none round the cursor, an empty block, and i{ over lines as whole lines; the text, the cursor, the register and the insert state are Vim's"
      run := operatorRows objectOperatorRows },
    { name :=
        "an operator over each of the syntax tree's text objects, on a test mode of the model's JSON grammar, takes the node the tree's rule chooses: a function, a class and an argument, inside each, with a count, an argument's separator after it, before it or none, dot repeat, the inside from a cursor in the node outside it, and no object where the tree has none or the buffer no syntax tree"
      run := operatorRows treeObjectOperatorRows },
    { name :=
        "in v each of the syntax tree's text objects sets the selection to its node, inclusive, in visual: a wider selection is extended to the next node out, a count takes the node that many out, and an object that is not there leaves the selection as it was"
      run := do
        let visual := evilBadge "v"
        let wrong :=
          treeSelectionRows.filterMap fun (fixture, typed, ranges, covered) =>
            let got := treeSelected fixture typed
            let state :=
              ((treeRegistered fixture).bind fun driver => evilSeen (evilFed driver typed)).bind
                (·.status[0]?)
            if got == some (ranges, .inclusive, covered) && state == visual then none
            else some s!"{typed} from {repr fixture} left {repr got}, in {repr state}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong))
        return true },
    { name :=
        "% under an operator takes from the cursor through the partner of the first bracket of the line at or after it, across lines, and gives up on a line with no bracket; v % extends the selection to the partner, as Vim 9.1.1752 does"
      run := do
        let held ← operatorRows percentOperatorRows
        return held &&
            evilSelected "x |(a [b] c)" "v %" == some ([(2, 10)], .inclusive, ["(a [b] c)"]) &&
            evilSelected "|x (a)" "v %" == some ([(0, 4)], .inclusive, ["x (a)"]) },
    { name :=
        "= over each text object re-indents the rows the object touches, whole, in a text with indent levels, and the cursor goes to the first row's first non-blank"
      run := operatorRows indentObjectRows },
    { name :=
        "the object table is complete: every operator key of the default tables has a row over every text object the default tables name"
      run :=
        pure <|
          !objectNames.isEmpty &&
            Vim.Default.operators.all fun (operator, _) =>
              objectNames.all fun name => objectOperatorPairs.contains (operator, name) },
    { name :=
        "in v and V each text object sets the selection Vim 9.1 documents: one range, inclusive, covering the object, with the view in visual; a selection wider than one cell is extended from its head, a block one out when it is no bigger; an object that is not there leaves the selection as it was, and so does a quote object over a wider selection, a recorded departure"
      run := do
        let visual := evilBadge "v"
        let wrong :=
          objectSelectionRows.filterMap fun (fixture, typed, ranges, covered) =>
            let got := evilSelected fixture typed
            let state := (evilScene fixture typed).bind (·.status[0]?)
            if got == some (ranges, .inclusive, covered) && state == visual then none
            else some s!"{typed} from {repr fixture} left {repr got}, in {repr state}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong))
        return true },
    { name :=
        "an object that is not there leaves the selection as the visual state had it: in v the view stays in visual and nothing is said; in V, where the object would make the selection charwise, the view stays in visual-line, as Vim 9.1.1752 does, and the give-up's sentence is said"
      run := do
        let visual := evilBadge "v"
        let visualLine := evilBadge "V"
        -- What a give-up of the select command says.
        let gaveUp (object : Vocabulary.TextObject) :=
          s!"{Vim.selectObjectCommand}: {Evil.noObjectHere object.name}"
        let wrong :=
          [("a|b", "v", "i (", visual, ""), ("a|b", "v", "a [", visual, ""),
                ("a|b", "v", "i \"", visual, ""),
                ("a|b", "V", "i (", visualLine, gaveUp Evil.innerParen),
                ("a|b", "V", "a {", visualLine, gaveUp Evil.aBrace),
                ("a|b", "V", "i '", visualLine, gaveUp Evil.innerSingleQuote)].filterMap
            fun (fixture, state, object, shown, echo) =>
            let before := evilSelected fixture state
            let typed := state ++ " " ++ object
            let got := evilSelected fixture typed
            let seen := (evilScene fixture typed).bind (·.status[0]?)
            let echoed :=
              (evilDriver fixture).map fun driver => (evilFed driver typed).loop.state.echo
            if before.isSome && got == before && seen == shown && echoed == some echo then none
            else
              some
                s!"{typed} from {repr fixture} left {repr got} (before {repr before}), in {repr seen}, echo {repr echoed}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong))
        return true },
    { name := "the visual table is complete: every text object the default tables name has a row"
      run :=
        pure <|
          objectNames.all fun name =>
            (objectSelectionRows ++ treeSelectionRows).any fun (_, typed, _, _) =>
              let tokens := (typed.splitOn " ").filter (fun token => !token.all Char.isDigit)
              (objectNamed (" ".intercalate (tokens.drop (tokens.length - 2)))) == some name },
    { name :=
        "the visual table covers wider selections: each of iw aw iW aW i( a( i[ a[ i{ a{ has a row over a selection a motion or an object made wider than one cell, and a row over one a backward motion made, its head before its anchor"
      run :=
        pure <|
          ["i w", "a w", "i W", "a W", "i (", "a (", "i [", "a [", "i {", "a {"].all fun key =>
            -- The keys of each row of `key`, between the visual state's key
            -- and the object, with any count left out.
            let widened :=
              objectSelectionRows.filterMap fun (_, typed, _, _) =>
                let tokens := typed.splitOn " "
                if tokens.drop (tokens.length - 2) == key.splitOn " " then
                  some
                    (((tokens.drop 1).take (tokens.length - 3)).filter fun token =>
                      !token.all Char.isDigit)
                else none
            widened.any (!·.isEmpty) &&
              widened.any fun keys => keys.contains "h" || keys.contains "b" },
    { name :=
        "a sweep of every default operator key over every default text object key, with no count and with a count of 2, from every position a cursor may rest at in a few texts: nothing is refused, after an operator that enters no state the cursor is where normal state lets one rest, a yank leaves the text, and u gives back a text that changed, with the cursor where it was"
      run := do
        let wrong :=
          sweepTexts.flatMap fun contents =>
            ((List.range (contents.utf8ByteSize + 1)).filter (restsWell contents)).flatMap
              fun position =>
              Vim.Default.operators.flatMap fun (operatorKey, bound) =>
                match bound with
                | .operator operator =>
                  Vim.Default.objects.flatMap fun (objectKey, _) =>
                    [false, true].filterMap fun counted =>
                      sweptWrong contents position operator
                        ((if counted then "2 " else "") ++ operatorKey ++ " " ++ objectKey)
                | _ => []
        unless wrong.isEmpty do
          throw
              (IO.userError s!"{wrong.length} cases, the first: {"; ".intercalate (wrong.take 5)}")
        return true },
    { name :=
        "a sweep of v and V followed by every default text object key, with no count and with a count of 2, from every position a cursor may rest at in a few texts: nothing is refused, the selection is one range with both ends at positions, and the view is in visual"
      run := do
        let wrong := sweepTexts.flatMap visualObjectSweep
        unless wrong.isEmpty do
          throw
              (IO.userError s!"{wrong.length} cases, the first: {"; ".intercalate (wrong.take 5)}")
        return true },
    { name :=
        "the select command sets the selection by its call: an object no entry has and arguments that are not a name and a count give up with the sentence their function makes"
      run :=
        pure <|
          let selected (arguments : List Argument) : Option EvilEdited :=
            (evilRegistered "a|bc").map fun driver =>
              evilLeft
                (driver.stepped
                    (driver.loop.invoke driver.handed
                      { command := Vim.selectObjectCommand, arguments })).1
          evilGaveUp (selected [.str "word", .nat 0]) "a|bc" (Evil.noSuchObject "word") &&
            evilGaveUp (selected []) "a|bc" Evil.noObjectNamed &&
            evilGaveUp (selected [.str Evil.innerWord.name]) "a|bc" Evil.noObjectNamed }]

/-- The keys the key string `typed` names, pressed from the text and the
cursor `fixture` says with the unnamed register holding a sentinel, on the
editor's models with the clipboard model `clipboard`: what they left, and
the text the clipboard model then holds. -/
def evilClipped (fixture typed : String) (clipboard : ClipboardModel := {}) :
    Option (EvilEdited × Option String) :=
  (evilRegistered fixture { editorModel with clipboard }).map fun driver =>
    let after := evilFed driver typed
    (evilLeft after, after.model.clipboard.held)

/-- A driver of the evil checks over a buffer holding `contents` whose lines
end in a carriage return and line feed (`Buffer.lineEnding`), with the
cursor at `head`, on the models `model`. -/
def evilCrlfDriver (contents : String) (head : Nat) (model : EditorModel := editorModel) :
    Option EvilDriver :=
  (Loop.Driver.over evilHanded (fun _ => none)
      (do
        let state ← evilState contents head
        return { state with buffers := state.buffers.map (·.map ({ · with lineEnding := .crlf })) })
      model).toOption

/-- What a step of the replace checks is handed: evil's commands, with
`<F5>` bound in an active keymap to the operator `replace`, which no
default key binds, so that a visual state's selection is replaced by key. -/
def replaceHanded : Loop.Keys Vim.Default.scheme :=
  { evilHanded with
    maps := fun _ _ => [Vim.Default.keymap [("<F5>", .operator { name := Evil.replace.name })]] }

/-- A driver of the replace checks over the text and cursor `fixture` says,
with the unnamed register holding `evilSentinel`, on the editor's models
with the clipboard model `clipboard`. -/
def replaceDriver (fixture : String) (clipboard : ClipboardModel := {}) : Option EvilDriver :=
  let (contents, head) := barred fixture
  (Loop.Driver.over replaceHanded (fun _ => none)
      (do
        return (← evilState contents head).setRegister Evil.unnamed evilSentinel)
      { editorModel with clipboard }).toOption

/-- The keys `typed` pressed on `replaceDriver`: what they left, and the
text the clipboard model then holds. -/
def evilReplaced (fixture typed : String) (clipboard : ClipboardModel := {}) :
    Option (EvilEdited × Option String) :=
  (replaceDriver fixture clipboard).map fun driver =>
    let after := evilFed driver typed
    (evilLeft after, after.model.clipboard.held)

/-- The checks of evil's registers and of the commands that read and set
them without an operator's key (`Editor/Evil/Registers.lean`,
`Editor/Evil/Operators.lean`), by key, as `evilOperatorChecks` are. -/
def evilRegisterChecks : List Check :=
  [{  name :=
        "x deletes the cell under the cursor into the unnamed register and leaves the cursor on the cell that follows, or on the line's last cell when it deleted the last one; with a count it deletes that many cells and no further than the line's end; on an empty line it does nothing"
      run :=
        operatorRows
          [.rests "a|bc" "x" "a|c" (charwise "b"), .rests "ab|c" "x" "a|b" (charwise "c"),
            .rests "ab|c\ndef" "x" "a|b\ndef" (charwise "c"),
            .rests "a|bcde" "3 x" "a|e" (charwise "bcd"),
            .rests "a|bcde" "9 x" "|a" (charwise "bcde"),
            .rests "ab\n|\ncd" "x" "ab\n|\ncd" asItWas] },
    { name :=
        "x is d l: from the same text and cursor the two leave the same text, cursor and register, with no count and with one, and each is one step of the history"
      run :=
        pure <|
          ["a|bc", "ab|c", "ab|c\ndef", "ab\n|\ncd", "|", "a|é😀b\r\nc"].all
              (fun fixture =>
                (evilEdited fixture "x").isSome &&
                  evilEdited fixture "x" == evilEdited fixture "d l" &&
                  evilEdited fixture "3 x" == evilEdited fixture "d 3 l") &&
            ((evilDriver "a|bc").map fun driver => evilHistory (evilFed driver "x")) ==
              some (some (2, false)) },
    { name :=
        "a yank or a deletion that names the clipboard register writes the clipboard and sets the unnamed register too: \" + y w leaves the clipboard model holding the word, \" + d d the line with its line break, and \" + x the cell"
      run :=
        pure <|
          evilClipped "foo |bar baz" "\" + y w" ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "bar ") &&
            evilClipped "ab\n|cd\nef" "\" + d d" ==
              some (⟨"ab\n|ef", linewise "cd\n", false, ""⟩, some "cd\n") &&
            evilClipped "a|bc" "\" + x" == some (⟨"a|c", charwise "b", false, ""⟩, some "b") },
    { name :=
        "naming the unnamed register is naming none: \" \" y w and y w leave the same, and the clipboard model holds what it held"
      run :=
        pure <|
          evilClipped "foo |bar baz" "\" \" y w" { held := some "before" } ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "before") &&
            evilClipped "foo |bar baz" "y w" { held := some "before" } ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "before") },
    { name :=
        "a register evil has none of gives the command up, with the sentence its function makes: nothing is yanked or deleted, a change begins no insert, and nothing is written to the clipboard"
      run :=
        pure <|
          !(Evil.noRegister "a").isEmpty &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a y w") "foo |bar baz"
              (Evil.noRegister "a") &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a c w") "foo |bar baz"
              (Evil.noRegister "a") &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a d d") "foo |bar baz"
              (Evil.noRegister "a") &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a x") "foo |bar baz" (Evil.noRegister "a") &&
            (evilClipped "foo |bar baz" "\" a y w").map (·.2) == some none },
    { name :=
        "with a clipboard that is not available, a yank that names it says so in the echo area, with the sentence its function makes, and the unnamed register holds the word"
      run :=
        pure <|
          !Evil.clipboardUnavailable.isEmpty &&
            evilClipped "foo |bar baz" "\" + y w" { available := false } ==
              some (⟨"foo |bar baz", charwise "bar ", false, Evil.clipboardUnavailable⟩, none) },
    { name :=
        "a yank that names the clipboard and takes no cell empties the unnamed register and writes nothing: the clipboard model holds what it held"
      run :=
        pure <|
          evilClipped "|abc" "\" + y h" { held := some "before" } ==
            some (⟨"|abc", charwise "", false, ""⟩, some "before") },
    { name :=
        "p and P put a character-wise register after and before the cursor's cell, count times, and leave the cursor on the last cell put, or on the first when the text holds a line break; on an empty line p puts at the cursor"
      run :=
        operatorRows
          [.rests "foo |bar baz" "y w p" "foo bbar| ar baz" (charwise "bar "),
            .rests "foo |bar baz" "y w P" "foo bar| bar baz" (charwise "bar "),
            .rests "|ab cd" "y w 2 p" "aab ab| b cd" (charwise "ab "),
            .rests "|ab cd\n\nef" "y w j p" "ab cd\nab| \nef" (charwise "ab "),
            .rests "|ab" "x p" "b|a" (charwise "a"),
            .rests "a|bc\ndef\nghi" "v j y p" "ab|bc\ndec\ndef\nghi" (charwise "bc\nde"),
            .rests "a|bc\ndef\nghi" "v j y P" "a|bc\ndebc\ndef\nghi" (charwise "bc\nde")] },
    { name :=
        "p and P put a line-wise register below and above the cursor's line, count times, and leave the cursor on the first non-blank of the first line put; below a last line with no line break the line break goes before the lines and their last one is left out"
      run :=
        operatorRows
          [.rests "ab\nc|d\nef" "y y p" "ab\ncd\n|cd\nef" (linewise "cd\n"),
            .rests "ab\nc|d\nef" "y y P" "ab\n|cd\ncd\nef" (linewise "cd\n"),
            .rests "ab\nc|d\nef" "y y 2 p" "ab\ncd\n|cd\ncd\nef" (linewise "cd\n"),
            .rests "ab\n  c|d\nef" "y y j p" "ab\n  cd\nef\n  |cd" (linewise "  cd\n"),
            .rests "ab\nc|d" "y y p" "ab\ncd\n|cd" (linewise "cd\n"),
            .rests "a|b\n" "y y p" "ab\n|ab\n" (linewise "ab\n"),
            .rests "|ab\ncd" "d d p" "cd\n|ab" (linewise "ab\n"),
            .rests "ab\n|cd" "d d P" "|cd\nab" (linewise "cd\n"),
            .rests "a|b" "y y 2 p" "ab\n|ab\nab" (linewise "ab\n")] },
    { name :=
        "a put from the clipboard register inserts what the clipboard model holds, character-wise for a text with no final line feed and line-wise for one that ends in one, and leaves the unnamed register as it was"
      run :=
        pure <|
          evilClipped "a|b" "\" + p" { held := some "XY" } ==
              some (⟨"abX|Y", asItWas, false, ""⟩, some "XY") &&
            evilClipped "a|b" "\" + P" { held := some "XY" } ==
              some (⟨"aX|Yb", asItWas, false, ""⟩, some "XY") &&
            evilClipped "a|b" "\" + p" { held := some "cd\n" } ==
              some (⟨"ab\n|cd", asItWas, false, ""⟩, some "cd\n") &&
            evilClipped "a|b\n" "\" + P" { held := some "  cd\n" } ==
              some (⟨"  |cd\nab\n", asItWas, false, ""⟩, some "  cd\n") },
    { name :=
        "a put with nothing to put gives up, with the sentence its function makes, and changes nothing: an unnamed register nothing was set in, one that holds the empty text, a clipboard that holds no text, and one that is not available; and a register evil has none of"
      run :=
        pure <|
          let unset :=
            (evilDriver "a|b").map fun driver =>
              let put := evilFed driver "p"
              (evilShown put, put.loop.state.echo.endsWith Evil.nothingToPut, evilHistory put)
          let emptied :=
            (evilEdited "|ab" "y h p").map fun left =>
              (left.shown, left.echo.endsWith Evil.nothingToPut)
          !Evil.nothingToPut.isEmpty && unset == some ("a|b", true, some (1, false)) &&
            emptied == some ("|ab", true) &&
            evilGaveUp ((evilClipped "a|b" "\" + p").map (·.1)) "a|b" Evil.nothingToPut &&
            evilGaveUp ((evilClipped "a|b" "\" + P" { available := false }).map (·.1)) "a|b"
              Evil.clipboardUnavailable &&
            evilGaveUp (evilEdited "a|b" "\" a p") "a|b" (Evil.noRegister "a") },
    { name :=
        "a put is one step of the history: after y w p the buffer's tree has one node more and nothing pending, and one undo request gives the text from before the put"
      run :=
        pure <|
          match evilDriver "|ab cd" with
          | none => false
          | some driver =>
            let put := evilFed driver "y w p"
            evilHistory put == some (2, false) && evilText put == some "aab b cd" &&
              evilText (evilUndone put) == some "ab cd" },
    { name :=
        "the name a command names the clipboard by when it will write it itself: a yank under that name sets the unnamed register and keeps the same text under the name, and writes nothing to the clipboard; a put under it puts what the clipboard holds; and it is no name a key types, being longer than one character"
      run :=
        pure <|
          let ran (fixture : String) (invocation : Invocation) (clipboard : ClipboardModel) :
            Option (EvilEdited × Option String × Option Register) :=
            (evilRegistered fixture { editorModel with clipboard }).map fun driver =>
              let after := (driver.stepped (driver.loop.invoke driver.handed invocation)).1
              (evilLeft after, after.model.clipboard.held,
                after.loop.state.register? Evil.clipboardLater)
          Evil.clipboardLater.length > 1 &&
            ran "foo |bar baz"
                { command := Vim.operateCommand
                  arguments :=
                    [.str Evil.yank.name, .str "motion", .str Evil.wordForward.name, .nat 0,
                      .str Evil.clipboardLater] }
                { held := some "before" } ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "before", charwise "bar ") &&
            ran "a|b" { command := "put-after", arguments := [.nat 0, .str Evil.clipboardLater] }
                { held := some "XY" } ==
              some (⟨"abX|Y", asItWas, false, ""⟩, some "XY", none) },
    { name :=
        "in a buffer whose lines end in a carriage return and line feed, a line-wise put keeps that line break: y y p on a middle line puts the line below it, y y P above it, and below a last line with no line break the buffer's line break goes before the lines and their last one is left out whole, with a count too"
      run :=
        pure <|
          let put (contents : String) (head : Nat) (typed : String) :
            Option (String × Option Register) :=
            (evilCrlfDriver contents head).map fun driver =>
              let after := evilFed driver typed
              (evilShown after, after.loop.state.register? Evil.unnamed)
          put "ab\r\ncd" 5 "y y p" == some ("ab\r\ncd\r\n|cd", linewise "cd\r\n") &&
            put "ab\r\ncd\r\nef" 5 "y y p" == some ("ab\r\ncd\r\n|cd\r\nef", linewise "cd\r\n") &&
            put "ab\r\ncd" 5 "y y P" == some ("ab\r\n|cd\r\ncd", linewise "cd\r\n") &&
            put "ab\r\ncd" 5 "y y 2 p" == some ("ab\r\ncd\r\n|cd\r\ncd", linewise "cd\r\n") &&
            put "ab\r\n  cd" 6 "y y p" == some ("ab\r\n  cd\r\n  |cd", linewise "  cd\r\n") },
    { name :=
        "in such a buffer a put from the clipboard register of a text that ends in a carriage return and line feed is line-wise: below a middle line and above a line the text goes in as it is, and below a last line with no line break the buffer's line break goes first and the text's own is left out whole; a text that ends in a line feed alone is put below the last line after the buffer's line break"
      run :=
        pure <|
          let put (contents : String) (head : Nat) (typed held : String) : Option String :=
            (evilCrlfDriver contents head
                  { editorModel with clipboard := { held := some held } }).map
              fun driver => evilShown (evilFed driver typed)
          put "ab\r\ncd" 5 "\" + p" "xy\r\n" == some "ab\r\ncd\r\n|xy" &&
            put "ab\r\ncd" 0 "\" + p" "xy\r\n" == some "ab\r\n|xy\r\ncd" &&
            put "ab\r\ncd" 5 "\" + P" "xy\r\n" == some "ab\r\n|xy\r\ncd" &&
            put "ab\r\ncd" 5 "\" + p" "xy\n" == some "ab\r\ncd\r\n|xy" },
    { name :=
        "the operator replace over a character-wise selection puts the clipboard's text in place of it, the cursor on the last cell put, or on the first when the text holds a line break, which goes in as it is; the unnamed register holds the replaced text and the clipboard model what it held; the view is in normal state"
      run :=
        pure <|
          evilReplaced "a|bcd" "v l \" + <F5>" { held := some "XY" } ==
              some (⟨"aX|Yd", charwise "bc", false, ""⟩, some "XY") &&
            evilReplaced "a|bcd" "v l \" + <F5>" { held := some "XY\n" } ==
              some (⟨"a|XY\nd", charwise "bc", false, ""⟩, some "XY\n") &&
            ((replaceDriver "a|bcd" { held := some "XY" }).map fun driver =>
                (evilSeen (evilFed driver "v l \" + <F5>")).bind (·.status[0]?)) ==
              some (evilLooks "").2[0]? },
    { name :=
        "the operator replace over a line-wise selection puts the clipboard's text in place of the lines, a character-wise text with the buffer's line ending added, and the cursor on the first non-blank of the first line put; below a last line with no line break the text's last line break is left out; the unnamed register holds the lines, line-wise"
      run :=
        pure <|
          evilReplaced "ab\nc|d\nef" "V \" + <F5>" { held := some "XY" } ==
              some (⟨"ab\n|XY\nef", linewise "cd\n", false, ""⟩, some "XY") &&
            evilReplaced "ab\nc|d\nef" "V \" + <F5>" { held := some "  XY\n" } ==
              some (⟨"ab\n  |XY\nef", linewise "cd\n", false, ""⟩, some "  XY\n") &&
            evilReplaced "ab\nc|d" "V \" + <F5>" { held := some "XY\n" } ==
              some (⟨"ab\n|XY", linewise "cd\n", false, ""⟩, some "XY\n") &&
            evilReplaced "a|b\ncd\nef" "V j \" + <F5>" { held := some "XY" } ==
              some (⟨"|XY\nef", linewise "ab\ncd\n", false, ""⟩, some "XY") },
    { name :=
        "the operator replace with a clipboard model holding no text gives up with nothingToPut, and with one not available with clipboardUnavailable, and the buffer is as it was"
      run :=
        pure <|
          evilGaveUp ((evilReplaced "a|bcd" "v l \" + <F5>").map (·.1)) "ab|cd" Evil.nothingToPut &&
            evilGaveUp ((evilReplaced "a|bcd" "v l \" + <F5>" { available := false }).map (·.1))
              "ab|cd" Evil.clipboardUnavailable &&
            evilGaveUp ((evilReplaced "ab\nc|d\nef" "V \" + <F5>").map (·.1)) "ab\nc|d\nef"
              Evil.nothingToPut },
    { name :=
        "the operator replace is one step of the history: one undo request gives the text from before it"
      run :=
        pure <|
          match replaceDriver "a|bcd" { held := some "XY" } with
          | none => false
          | some driver =>
            let replaced := evilFed driver "v l \" + <F5>"
            evilText replaced == some "aXYd" && evilHistory replaced == some (2, false) &&
              evilText (evilUndone replaced) == some "abcd" }]

/-- The mangled JSON text of the indent checks' repeats, with the cursor on
its second row. -/
def indentRepeatText : String :=
  "[\n|1,\n      2,\n 3,\n4,\n   5,\n6\n]"

/-- The checks of evil's `=` (`Evil.indent`, `Editor/Evil/Operators.lean`),
by key, on the models: in the indent checks' JSON language
(`indentDriver`), where the model's syntax tree answers the indents query,
and on the plain evil driver, whose buffer has no language. -/
def evilIndentChecks : List Check :=
  [{  name :=
        "g g = G over a mangled JSON text gives the two-space text, a blank row of blanks emptied, with the cursor on the first row's first non-blank; = G from a row whose indent changes leaves the cursor on that row's new first non-blank"
      run :=
        let mangled := "{\n\"a\": [\n      1,\n   \n {\n\"b\": null\n    }\n],\n\"c\": {}\n}"
        let pretty :=
          "{\n  \"a\": [\n    1,\n\n    {\n      \"b\": null\n    }\n  ],\n  \"c\": {}\n}"
        operatorRows
          [.indents (withBar mangled 25) "g g = G" (withBar pretty 0),
            .indents (withBar mangled 2) "= G" (withBar pretty 4)] },
    { name :=
        "= a f inside a nested object re-indents exactly that object's rows, and the rows outside it keep their indentation"
      run :=
        operatorRows
          [.indents "[\n{\n\"|x\": 1\n},\n2\n]" "= a f" "[\n  |{\n    \"x\": 1\n  },\n2\n]"] },
    { name :=
        "= = re-indents the cursor's row, a count that many rows, = j two rows, and V j = the selection's rows; a row already right is left, and nothing is put in the register"
      run :=
        operatorRows
          [.indents indentRepeatText "= =" "[\n  |1,\n      2,\n 3,\n4,\n   5,\n6\n]",
            .indents indentRepeatText "3 = =" "[\n  |1,\n  2,\n  3,\n4,\n   5,\n6\n]",
            .indents indentRepeatText "= j" "[\n  |1,\n  2,\n 3,\n4,\n   5,\n6\n]",
            .indents indentRepeatText "V j =" "[\n  |1,\n  2,\n 3,\n4,\n   5,\n6\n]",
            .indents "[\n  |1\n]" "= =" "[\n  |1\n]", .indents "|[\n  1\n]" "= j" "|[\n  1\n]"] },
    { name :=
        "one = is one step of the history: u gives back the mangled text and the cursor from before"
      run :=
        pure <|
          match indentDriver indentRepeatText with
          | none => false
          | some driver =>
            let indented := evilFed driver "= j"
            let nodes (driver : EvilDriver) := (evilHistory driver).map (·.1)
            evilShown indented == "[\n  |1,\n  2,\n 3,\n4,\n   5,\n6\n]" &&
              nodes indented == (nodes driver).map (· + 1) &&
              evilShown (evilFed indented "u") == indentRepeatText },
    { name :=
        ". repeats = over another range: = = then j . re-indents the next row, = j then j j j . the two rows from there, and a count before . replaces the count"
      run :=
        operatorRows
          [.indents indentRepeatText "= = j ." "[\n  1,\n  |2,\n 3,\n4,\n   5,\n6\n]",
            .indents indentRepeatText "= j j j j ." "[\n  1,\n  2,\n 3,\n  |4,\n  5,\n6\n]",
            .indents indentRepeatText "2 = = j j ." "[\n  1,\n  2,\n  |3,\n  4,\n   5,\n6\n]",
            .indents indentRepeatText "2 = = j j 3 ." "[\n  1,\n  2,\n  |3,\n  4,\n  5,\n6\n]"] },
    { name := "= over a visual selection re-indents it and is not repeated by ."
      run :=
        pure <|
          match indentDriver indentRepeatText with
          | none => false
          | some driver =>
            let indented := evilFed driver "V j ="
            let repeated := evilFed indented "j j ."
            evilText repeated == some "[\n  1,\n  2,\n 3,\n4,\n   5,\n6\n]" &&
              repeated.loop.state.echo.endsWith (Evil.notRepeated Evil.overSelection) },
    { name :=
        "in a buffer with no language = = , = j and g g = G leave the text and the cursor and say there is no syntax tree; the give-up is not the last change, so . after it repeats the change before it"
      run :=
        pure <|
          let fixture := "    a|b\n  cd"
          let reason := Evil.cannotIndent .notAttached
          evilGaveUp (evilEdited fixture "= =") fixture reason &&
            evilGaveUp (evilEdited fixture "= j") fixture reason &&
            evilGaveUp (evilEdited fixture "g g = G") "    |ab\n  cd" reason &&
            (evilDriver fixture).bind (fun driver => evilText (evilFed driver "x = = .")) ==
              some "    \n  cd" },
    { name :=
        "while the tree of the text's last edit is not delivered, = = and g g = G leave the text and the cursor and say the tree is not parsed yet, where the tree would re-indent the rows; the give-up is not the last change, so . after it repeats the change before it"
      run :=
        pure <|
          let fixture := "[\n   |1,\n 2\n]"
          let reason := Evil.cannotIndent .notParsed
          (indentEdited fixture "= =").map (·.shown) == some "[\n  |1,\n 2\n]" &&
            evilGaveUp (undeliveredEdited fixture "= =") fixture reason &&
            evilGaveUp (undeliveredEdited fixture "g g = G") "|[\n   1,\n 2\n]" reason &&
            (undeliveredDriver "[\n   |12\n]").bind
                (fun driver => evilText (evilFed driver "x = = .")) ==
              some "[\n   \n]" },
    { name :=
        "while the tree of the text's last edit is not delivered, A RET, o and O start the new row at the cursor row's own leading whitespace, Vim's autoindent, where the tree would give its level, and . replays a RET so"
      run :=
        pure <|
          (indentEdited "[\n   |1\n]" "o").map (·.shown) == some "[\n   1\n  |\n]" &&
            (undeliveredEdited "[\n   |1\n]" "A RET").map (·.shown) == some "[\n   1\n   |\n]" &&
            (undeliveredEdited "[\n   |1\n]" "o").map (·.shown) == some "[\n   1\n   |\n]" &&
            (undeliveredEdited "[\n   |1\n]" "O").map (·.shown) == some "[\n   |\n   1\n]" &&
            (undeliveredDriver "[\n   |1,\n 2\n]").bind
                (fun driver => evilText (evilFed driver "A RET <Escape> j .")) ==
              some "[\n   1,\n   \n 2\n \n]" },
    { name :=
        "in a buffer whose language's tree keeps no indents query = = leaves the text and says so"
      run :=
        pure <|
          let fixture := "[\n|1\n]"
          evilGaveUp
            (indentEdited fixture "= ="
              { modelJsonIndented with syntaxTree := { grammar := "json" } })
            fixture (Evil.cannotIndent .noQuery) },
    { name :=
        "a config entry of the buffer's language that indents by a tab wins over the compiled one: = = indents with tabs"
      run :=
        pure
          ((indentEdited "[\n[\n|1\n]\n]" "= =" (config :=
                  #[{ modelJsonIndented with indentUnit := .tab }])).map
              (·.shown) ==
            some "[\n[\n\t\t|1\n]\n]") },
    { name :=
        "RET after an opening bracket starts the new line one level deeper than its row; o inside an object and O on its closing row start at the object's level"
      run :=
        operatorRows
          [{
              OperatorRow.indents "{\n  \"a\": |[\n  ]\n}" "A RET"
                "{\n  \"a\": [\n    |\n  ]\n}" with
              insert := true },
            { OperatorRow.indents "{\n  |\"a\": 1\n}" "o" "{\n  \"a\": 1\n  |\n}" with
              insert := true },
            { OperatorRow.indents "{\n  \"a\": 1\n|}" "O" "{\n  \"a\": 1\n  |\n}" with
              insert := true },
            { OperatorRow.indents "{\n  \"a\": [\n|  ]\n}" "O" "{\n  \"a\": [\n    |\n  ]\n}" with
              insert := true }] },
    { name :=
        "RET before a closing bracket leads the new row out at the bracket's level; RET between blanks replaces the blanks on both sides, so the row left keeps none and the rest starts at its level; RET RET leaves the first new row empty"
      run :=
        operatorRows
          [{ OperatorRow.indents "{\n  \"a\": [|]\n}" "i RET" "{\n  \"a\": [\n  |]\n}" with
              insert := true },
            { OperatorRow.indents "[\n  1,   |   2\n]" "i RET" "[\n  1,\n  |2\n]" with
              insert := true },
            { OperatorRow.indents "[\n  |1\n]" "a RET RET" "[\n  1\n\n  |\n]" with
              insert := true }] },
    { name :=
        ". replays an insert session's RET with its new line indented, and o replayed indents itself"
      run :=
        pure <|
          (indentDriver "[\n  |1,\n  2\n]").bind
                (fun driver => evilText (evilFed driver "o RET <Escape> j .")) ==
              some "[\n  1,\n\n  \n  2\n\n  \n]" &&
            (indentDriver "[\n  |1,\n  2\n]").bind
                (fun driver => evilText (evilFed driver "A RET <Escape> j .")) ==
              some "[\n  1,\n  \n  2\n  \n]" },
    { name := "a config entry's tab unit indents new lines with tabs"
      run :=
        pure
          ((indentEdited "[\n[\n|1\n]\n]" "o" (config :=
                  #[{ modelJsonIndented with indentUnit := .tab }])).map
              (·.shown) ==
            some "[\n[\n1\n\t\t|\n]\n]") },
    { name :=
        "in a buffer with no language, and in one whose tree keeps no indents query, A RET, o and O insert the bare line break, copying no indent"
      run :=
        pure <|
          let noQuery := { modelJsonIndented with syntaxTree := { grammar := "json" } }
          (evilEdited "    a|b" "A RET").map (·.shown) == some "    ab\n|" &&
            (evilEdited "    a|b" "o").map (·.shown) == some "    ab\n|" &&
            (evilEdited "    a|b" "O").map (·.shown) == some "|\n    ab" &&
            (indentEdited "[\n  |1\n]" "A RET" noQuery).map (·.shown) == some "[\n  1\n|\n]" &&
            (indentEdited "[\n  |1\n]" "o" noQuery).map (·.shown) == some "[\n  1\n|\n]" &&
            (indentEdited "[\n  |1\n]" "O" noQuery).map (·.shown) == some "[\n|\n  1\n]" }]

/-- The checks of the two commands that open a line (`Evil.openBelow`,
`Evil.openAbove`), by key, as `evilOperatorChecks` are. -/
def evilOpenChecks : List Check :=
  [{  name :=
        "o opens an empty line below the cursor's line and O one above it, each with the bar on the new line in insert state and the register as it was; the text typed is on the new line, and <Escape> leaves the cursor on it"
      run :=
        operatorRows
          [.inserts "ab\nc|d\nef" "o" "ab\ncd\n|\nef" asItWas,
            .inserts "ab\nc|d\nef" "O" "ab\n|\ncd\nef" asItWas,
            .inserts "ab\nc|d" "o" "ab\ncd\n|" asItWas, .inserts "|ab" "O" "|\nab" asItWas,
            .rests "ab\nc|d\nef" "o X <Escape>" "ab\ncd\n|X\nef" asItWas,
            .rests "ab\nc|d\nef" "O X <Escape>" "ab\n|X\ncd\nef" asItWas,
            .rests "ab\nc|d\nef" "o <Escape>" "ab\ncd\n|\nef" asItWas] },
    { name :=
        "a departure from Vim, recorded: a cursor cannot rest in the empty last row. o and <Escape> on a last line with no line feed leaves the text Vim writes, and the cursor on the line above, where Vim's is on the new line"
      run := operatorRows [.rests "ab\nc|d" "o <Escape>" "ab\nc|d\n" asItWas] },
    { name :=
        "inside the session o began, the selection is one exclusive range on the new line and the status field is insert state's; a count before o or O changes nothing"
      run := do
        let held ←
          operatorRows
              [.rests "ab\nc|d\nef" "3 o X <Escape>" "ab\ncd\n|X\nef" asItWas,
                .rests "ab\nc|d\nef" "3 O X <Escape>" "ab\n|X\ncd\nef" asItWas]
        return held &&
            (evilScene "ab\nc|d\nef" "o").map (fun seen => (seen.selection, seen.status)) ==
              some
                ({ ranges := #[⟨6, 6⟩], shape := .exclusive }, (evilLooks "i").2.push evilMark) },
    { name :=
        "o and the text typed after it are one step of the history: o leaves its group open, <Escape> closes it as one node, and one undo request gives the text from before the o"
      run :=
        pure <|
          match evilDriver "ab\nc|d\nef" with
          | none => false
          | some driver =>
            let opened := evilFed driver "o"
            let ended := evilFed opened "X Y <Escape>"
            evilHistory opened == some (1, true) && evilHistory ended == some (2, false) &&
              evilText ended == some "ab\ncd\nXY\nef" &&
              evilText (evilUndone ended) == some "ab\ncd\nef" },
    { name :=
        "in a buffer whose lines end in a carriage return and line feed, the line break o and O insert is that"
      run :=
        pure <|
          ((evilCrlfDriver "ab\r\ncd" 5).map fun driver => evilShown (evilFed driver "o")) ==
              some "ab\r\ncd\r\n|" &&
            ((evilCrlfDriver "ab\r\ncd" 5).map fun driver => evilShown (evilFed driver "O")) ==
              some "ab\r\n|\r\ncd" },
    { name :=
        "o and O begin an insert only when a key that enters insert state runs them: open-below and open-above, run by name in normal state, open the line and leave the cursor resting on it, in normal state"
      run :=
        pure <|
          let ran (name : String) : Option EvilEdited :=
            (evilRegistered "ab\nc|d\nef").map fun driver =>
              evilLeft (driver.stepped (driver.loop.invoke driver.handed { command := name })).1
          ran "open-below" == some ⟨"ab\ncd\n|\nef", asItWas, false, ""⟩ &&
            ran "open-above" == some ⟨"ab\n|\ncd\nef", asItWas, false, ""⟩ }]

/-- One change of each kind, for the checks of `u` and `C-r`: the text and
the cursor it is made from, its keys, and the text and the cursor from
before the change's command, which is the fixture unless keys before the
change's own moved the cursor. -/
def undoRows : List (String × String × String) :=
  [("|a b c", "d w", "|a b c"), ("ab\n|cd\nef", "d d", "ab\n|cd\nef"),
    ("ab\nc|d\nef\ngh", "d j", "ab\nc|d\nef\ngh"),
    ("foo |bar baz", "c w X <Escape>", "foo |bar baz"),
    ("ab\nc|d\nef", "c c X <Escape>", "ab\nc|d\nef"), ("foo |bar baz", "v e d", "foo ba|r baz"),
    ("abc\nd|ef\nghi\njk", "V j d", "abc\ndef\ng|hi\njk"), ("a|bc", "x", "a|bc"),
    ("a|bcde", "3 x", "a|bcde"), ("foo |bar baz", "y w p", "foo |bar baz"),
    ("ab\nc|d\nef", "y y p", "ab\nc|d\nef"), ("ab\nc|d\nef", "y y P", "ab\nc|d\nef"),
    ("foo |bar baz", "y w P", "foo |bar baz"), ("ab\nc|d\nef", "o X <Escape>", "ab\nc|d\nef"),
    ("ab\nc|d\nef", "O X <Escape>", "ab\nc|d\nef"),
    -- A session that typed nothing leaves its bar at a line's start, where
    -- `<Escape>` does not step back and a redo must not either.
    ("ab\nc|d\nef", "o <Escape>", "ab\nc|d\nef"), ("ab\nc|d\nef", "O <Escape>", "ab\nc|d\nef"),
    ("ab\nc|d\nef", "c c <Escape>", "ab\nc|d\nef"), ("ab\n|cd ef", "c w <Escape>", "ab\n|cd ef"),
    ("foo |bar baz", "v e c X <Escape>", "foo ba|r baz")]

/-- The checks of evil's undo and redo (`Editor/Evil/Undo.lean`), by key,
on the loop's driver over the editor's models, under the Vim scheme that
ships with evil's commands. What `u` leaves is the phase's rule and not
Vim's, which leaves the cursor at the start of the changed text. -/
def evilUndoChecks : List Check :=
  [{  name :=
        "u after a change restores the text and the cursor from before the change's command, and C-r reapplies it, leaving the text and the cursor the change left: for d over a motion, lines and a selection, c with typed text, x, p, P, o and O; for c over a selection; and for o, O, c c and c w at a line's start with nothing typed, whose session leaves its bar at a line's start, where C-r does not step back across the line break"
      run := do
        let wrong :=
          undoRows.filterMap fun (fixture, typed, before) =>
            match evilDriver fixture with
            | none => some s!"no driver for {repr fixture}"
            | some driver =>
              let changed := evilFed driver typed
              let undone := evilFed changed "u"
              let redone := evilFed undone "C-r"
              if
                  evilText changed != evilText driver && evilShown undone == before &&
                    undone.loop.state.echo.isEmpty &&
                    evilShown redone == evilShown changed &&
                    redone.loop.state.echo.isEmpty then
                none
              else
                some
                  s!"{typed} from {repr fixture} left {repr (evilShown changed)}, u {repr (evilShown undone)} saying {repr undone.loop.state.echo}, C-r {repr (evilShown redone)} saying {repr redone.loop.state.echo}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong))
        return true },
    { name :=
        "u after an insert session that typed text restores the text and leaves the cursor on the cell the insert began before, and C-r leaves the cursor where <Escape> left it"
      run :=
        pure <|
          evilKeys "a|bc" "i X Y <Escape> u" == "a|bc" &&
            evilKeys "a|bc" "a X Y <Escape> u" == "ab|c" &&
            evilKeys "a|bc" "i X Y <Escape> u C-r" == evilKeys "a|bc" "i X Y <Escape>" &&
            evilKeys "a|bc" "i X Y <Escape>" == "aX|Ybc" },
    { name :=
        "a count before u or C-r takes that many steps: 2 u takes two back, a count past the history stops at the first step, and 2 C-r takes two forward"
      run :=
        pure <|
          evilKeys "|abcd" "x x x" == "|d" && evilKeys "|abcd" "x x x 2 u" == "|bcd" &&
            evilKeys "|abcd" "x x x 9 u" == "|abcd" &&
            evilKeys "|abcd" "x x x 9 u 2 C-r" == "|cd" &&
            evilKeys "|abcd" "x x x 9 u 9 C-r" == "|d" },
    { name :=
        "u with nothing to undo and C-r with nothing to redo say so in the echo area, each with the sentence its function makes, and change nothing"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let undone := evilFed driver "u"
            let redone := evilFed driver "C-r"
            !Evil.nothingToUndo.isEmpty && !Evil.nothingToRedo.isEmpty &&
              undone.loop.state.echo == Evil.nothingToUndo &&
              evilShown undone == "a|bc" &&
              evilHistory undone == evilHistory driver &&
              redone.loop.state.echo == Evil.nothingToRedo &&
              evilShown redone == "a|bc" &&
              (evilFed (evilFed driver "x u") "u").loop.state.echo == Evil.nothingToUndo },
    { name :=
        "u after a visual deletion leaves one range with equal ends at the selection's head, in normal state's shape"
      run :=
        pure <|
          (evilSelected "foo |bar baz" "v e d u").map (fun (ranges, shape, _) => (ranges, shape)) ==
            some ([(6, 6)], (vimDefaultReport "").shape) },
    { name :=
        "a step whose edits carried no selection is undone with the cursor rested where the selection's marker is: a command written here inserts at a position, and u after it leaves the cursor on the cell it was on"
      run :=
        pure <|
          let stamp : Config.Registration :=
            { name := "stamp"
              action := .call fun _ => discard <| (⟨0⟩ : BufferId).insertAt 0 "XY" }
          match evilDriver "ab|c" (evilHanded #[stamp]) with
          | none => false
          | some driver =>
            let stamped :=
              (driver.stepped (driver.loop.invoke driver.handed { command := "stamp" })).1
            evilShown stamped == "XYab|c" && evilShown (evilFed stamped "u") == "ab|c" },
    { name :=
        "after u and after C-r the window keeps no wanted column: j keeps one, and the u and the C-r after it leave none"
      run :=
        pure <|
          match evilDriver "ab|cd\nxyz\nabcd" with
          | none => false
          | some driver =>
            let wanted (driver : EvilDriver) := (driver.loop.state.window? ⟨0⟩).bind (·.wanted)
            let moved := evilFed driver "x j"
            let undone := evilFed moved "u"
            let again := evilFed (evilFed undone "j") "C-r"
            (wanted moved).isSome && (wanted undone).isNone && (wanted again).isNone }]

/-- The oracle table's rows for `.`: the keys, the text before with the
cursor as a bar, and the text after. A count before `.` replaces the
change's; a change with an insert session is replayed with the text typed
in it, and leaves the cursor where `<Escape>` would; a yank is not the last
change. -/
def repeatRows : List (String × String × String) :=
  [("d w .", "|a b c d e f", "|c d e f"), ("d w 3 .", "|a b c d e f g", "|e f g"),
    ("d w 3 . .", "|a b c d e f g h i", "|h i"), ("d 2 w 3 .", "|a b c d e f g", "|f g"),
    ("2 d d .", "|a\nb\nc\nd\ne", "|e"), ("x .", "|abcd", "|cd"), ("x 3 .", "|abcdefgh", "|efgh"),
    ("c w X Y <Escape> w .", "|foo bar baz", "XY X|Y baz"),
    ("c w X Y <Escape> w w .", "|foo bar baz", "XY bar X|Y"),
    ("c w X Y <Escape> w 2 .", "|foo bar baz qux", "XY X|Y qux"),
    ("c w <Escape> w .", "|foo bar baz", "|  baz"),
    ("c c X <Escape> j .", "|ab\ncd\nef", "X\n|X\nef"), ("o X <Escape> .", "|ab", "ab\nX\n|X"),
    ("O X <Escape> .", "|ab", "|X\nX\nab"), ("i X <Escape> .", "a|b", "a|XXb"),
    ("a X <Escape> .", "a|b", "abX|X"), ("A X <Escape> j .", "|ab\ncd", "abX\ncd|X"),
    ("I X <Escape> j .", "  a|b\n  cdef", "  Xab\n  |Xcdef"),
    ("I X <Escape> j $ .", "  a|b\n  cdef", "  Xab\n  |Xcdef"),
    ("y w P .", "|ab cd", "abab|  ab cd"), ("y y p .", "|ab", "ab\nab\n|ab"),
    ("d w y w .", "|a b c d", "|c d")]

/-- The oracle table's rows for `.` after an insert session that used insert
state's editing keys, Vim 9.1's results: `<Backspace>`, `RET` and `TAB` are
replayed as typed, a `<Backspace>` past where the insert began included;
after an arrow key that moved and a text typed after it the change is `i`
with that text (`ins-special-special`); an arrow key with nothing typed
after it, and one that did not move, leave the change as it was. -/
def insertKeysRepeatRows : List (String × String × String) :=
  [("i x <Backspace> y <Escape> .", "a|b", "a|yyb"),
    ("i a b SPC c d C-w <Escape> .", "|x", "abab|  x"),
    ("a <Backspace> X <Escape> .", "ab|cd", "ab|Xd"),
    ("i x RET y <Escape> .", "a|b", "ax\nx\n|yyb"), ("i x TAB y <Escape> .", "a|b", "ax\tx\t|yyb"),
    ("i x <ArrowLeft> y <Escape> .", "a|b", "a|yyxb"),
    ("i x <ArrowRight> y <Escape> .", "a|bc", "axb|yyc"),
    ("i x <ArrowUp> y <Escape> .", "ab\na|b", "ab|yy\naxb"),
    ("i x <ArrowDown> y <Escape> .", "a|b\nab", "axb\nab|yy"),
    ("A x <ArrowLeft> y <Escape> 0 .", "a|b", "|yabyx"),
    ("c w X <ArrowLeft> <Escape> w .", "|foo bar", "X |X"),
    ("A x <ArrowRight> y <Escape> 0 .", "a|b", "abxyx|y")]

/-- The checks of evil's dot repeat (`Editor/Evil/Repeat.lean`), by key, on
the loop's driver over the editor's models, under the Vim scheme that ships
with evil's commands. -/
def evilRepeatChecks : List Check :=
  [{  name :=
        ". after an operator over a text object replays it where the cursor is then: c i w with typed text, d a w, d i ( on another pair, d a w with a count that replaces the change's, d 2 i w, and c i \" with typed text in another string, as Vim 9.1.1752 does them"
      run :=
        evilRows
          [("c i w x y <Escape> w .", "|foo bar baz", "xy x|y baz"),
            ("d a w .", "|a b c d", "|c d"), ("d i ( $ .", "f(|a) g(b)", "f() g(|)"),
            ("d a w 3 .", "|a b c d e f", "|e f"), ("d 2 i w .", "|a b c d e", "|c d e"),
            ("c i \" z <Escape> f c .", "\"|ab\" \"cd\"", "\"z\" \"|z\"")] },
    { name :=
        ". after an operator over a find replays it with the same character: d f c deletes to the next c again, d t c up to the next c, d ; repeats the last find as it is at the replay, and c f c with typed text makes the same change"
      run :=
        evilRows
          [("d f c .", "|abcabcabc", "|abc"), ("d t c .", "|abcabcab", "|cab"),
            ("f a d ; .", "|xabxabxab", "x|b"), ("c f c z <Escape> .", "|abcabcab", "|zab")] },
    { name :=
        ". after an operator over a search replays it with the search as it is at the replay: d n deletes to the next match of the last search again, and d * to the next occurrence of the word under the cursor"
      run :=
        evilRows
          [("* 0 d n .", "|foo x foo x foo x", "|foo x"), ("d * .", "|a x a x a x", "|a x"),
            ("d / f o o RET .", "|a foo b foo c foo", "|foo c foo"),
            ("c / x RET y <Escape> l .", "|abxcdxef", "y|yxef")] },
    { name :=
        ". replays the last change: after d w it deletes the next word, and after c w, typed text and <Escape> it makes the same change with the same text at the cursor; a count before it replaces the change's and is kept; x, the doubled operator, o, O, i, a, I, A, p and P are replayed, and a yank is not the last change"
      run := evilRows repeatRows },
    { name :=
        ". after a session that used <Backspace>, C-w, RET or TAB replays them as typed, a <Backspace> past where the insert began included, and RET with the buffer's line ending; after an arrow key that moved and a text typed after it, . is i with that text, as in Vim 9.1; after an arrow key with nothing typed after it, or one that did not move, . replays the change as it was"
      run := do
        let rows ← evilRows insertKeysRepeatRows
        let crlf :=
          let start : TextM EditorState := do
            let state ← evilState "abc" 2
            return { state with
                buffers := state.buffers.map (·.map ({ · with lineEnding := .crlf })) }
          match (Loop.Driver.over evilHanded (fun _ => none) start editorModel).toOption with
          | none => false
          | some driver => evilShown (evilFed driver "i RET <Escape> .") == "ab\r\n\r\n|c"
        return rows && crlf },
    { name :=
        "a replayed change that itself gives up gives the replay up and changes nothing: after d j, G and . on the last line, where j fails, the text, the cursor, the register and the history are as they were, the view is in normal state, and the echo area says why under the repeat command's name; after c j, a text, <Escape> and G, . likewise, with no text inserted and the view left in normal state; and the change is still the last change, which . replays from the first line"
      run :=
        pure <|
          let said := s!"{Vim.repeatCommand}: {Evil.cannotMove Evil.down.name}"
          let steps (typed : String) : Option (Option (Nat × Bool)) :=
            (evilDriver "|ab\ncd\nef\ngh").map fun driver => evilHistory (evilFed driver typed)
          let status (typed : String) : Option (Array StatusField) :=
            (evilScene "|ab\ncd\nef\ngh" typed).map (·.status)
          evilEdited "|ab\ncd\nef\ngh" "d j G" ==
              some ⟨"ef\n|gh", linewise "ab\ncd\n", false, ""⟩ &&
            evilEdited "|ab\ncd\nef\ngh" "d j G ." ==
              some ⟨"ef\n|gh", linewise "ab\ncd\n", false, said⟩ &&
            steps "d j G ." == steps "d j G" &&
            status "d j G ." == status "d j G" &&
            evilEdited "|ab\ncd\nef\ngh" "c j X <Escape> G" ==
              some ⟨"X\nef\n|gh", linewise "ab\ncd\n", false, ""⟩ &&
            evilEdited "|ab\ncd\nef\ngh" "c j X <Escape> G ." ==
              some ⟨"X\nef\n|gh", linewise "ab\ncd\n", false, said⟩ &&
            steps "c j X <Escape> G ." == steps "c j X <Escape> G" &&
            steps "c j X <Escape> G" == some (some (2, false)) &&
            status "c j X <Escape> G ." == status "c j X <Escape> G" &&
            evilEdited "|ab\ncd\nef\ngh" "c j X <Escape> G . g g ." ==
              some ⟨"|X\ngh", linewise "X\nef\n", false, ""⟩ },
    { name :=
        "a replayed change with an insert session is one step of the history and leaves the view in normal state: after c w X Y <Escape> w . the tree has one node more and nothing pending, and one u takes the whole replay back, with the cursor where it was"
      run :=
        pure <|
          match evilDriver "|foo bar baz" with
          | none => false
          | some driver =>
            let changed := evilFed driver "c w X Y <Escape> w"
            let replayed := evilFed changed "."
            evilHistory changed == some (2, false) && evilHistory replayed == some (3, false) &&
              evilShown replayed == "XY X|Y baz" &&
              (evilSeen replayed).map (·.status) == some ((evilLooks "").2.push evilMark) &&
              evilShown (evilFed replayed "u") == "XY |bar baz" },
    { name :=
        ". with no change to repeat says nothing and changes nothing, and the repeat command run by its name, which is handed no change, gives up with the sentence its function makes"
      run :=
        pure <|
          let named :=
            (evilRegistered "a|bc").map fun driver =>
              evilLeft
                (driver.stepped
                    (driver.loop.invoke driver.handed { command := Vim.repeatCommand })).1
          evilEdited "a|bc" "." == some ⟨"a|bc", asItWas, false, ""⟩ &&
            evilEdited "a|bc" "y l ." == some ⟨"a|bc", charwise "b", false, ""⟩ &&
            evilGaveUp named "a|bc" Evil.nothingToRepeat },
    { name :=
        "what is not repeated gives the command up and changes nothing: a change over a visual selection, and a change whose command the registry has none of"
      run :=
        pure <|
          let unknown :=
            (evilRegistered "a|bc").map fun driver =>
              evilLeft
                (driver.stepped
                    (driver.loop.invoke driver.handed
                      { command := Vim.repeatCommand
                        arguments :=
                          [.bool false, .str "", .str "frobnicate", .nat 0, .str ""] })).1
          let selected :=
            (evilDriver "foo |bar baz qux").map fun driver =>
              let deleted := evilFed driver "v e d w"
              let repeated := evilFed deleted "."
              (evilShown deleted, evilShown repeated,
                repeated.loop.state.echo.endsWith (Evil.notRepeated Evil.overSelection),
                evilHistory deleted == evilHistory repeated)
          !(Evil.notRepeated "frobnicate").isEmpty &&
            evilGaveUp unknown "a|bc" (Evil.notRepeated "frobnicate") &&
            selected == some ("foo  |baz qux", "foo  |baz qux", true, true) },
    { name :=
        "a text committed in the session a change began is replayed with it: after c w, a committed text, <Escape> and w, . changes the next word to that text"
      run :=
        pure <|
          match evilDriver "|foo bar baz" with
          | none => false
          | some driver =>
            let changing := evilFed driver "c w"
            let committed := (changing.feed { event := .commit "かな", stamp := 0 }).1
            evilShown (evilFed committed "X <Escape> w .") == "かなX かな|X baz" },
    { name :=
        "an operator that a motion's failure cancelled is not the last change, whether or not the motion moved first, as in Vim: after x, a d 3 b that leaves the cursor on the empty first line, and w, . replays the x; and after x and a d j that fails on the last line, . replays the x"
      run :=
        pure <|
          evilEdited "\nab |cd ef" "x d 3 b w ." == some ⟨"\n|b d ef", charwise "a", false, ""⟩ &&
            evilEdited "\nab |cd ef" "x c 3 B w ." == some ⟨"\n|b d ef", charwise "a", false, ""⟩ &&
            evilEdited "ab\n|cde" "x d j ." == some ⟨"ab\n|e", charwise "d", false, ""⟩ },
    { name :=
        "a doubled operator that its count cancelled on the last line is not the last change, as in Vim: after x and then 2 d d, 2 c c, 2 y y or d 2 d on the last line, . replays the x"
      run :=
        pure <|
          evilEdited "ab\ncd\n|efg" "x 2 d d ." == some ⟨"ab\ncd\n|g", charwise "f", false, ""⟩ &&
            evilEdited "ab\ncd\n|efg" "x 2 c c ." == some ⟨"ab\ncd\n|g", charwise "f", false, ""⟩ &&
            evilEdited "ab\ncd\n|efg" "x 2 y y ." == some ⟨"ab\ncd\n|g", charwise "f", false, ""⟩ &&
            evilEdited "ab\ncd\n|efg\n" "x 2 d d ." ==
              some ⟨"ab\ncd\n|g\n", charwise "f", false, ""⟩ &&
            evilEdited "|abc" "x d 2 d ." == some ⟨"|c", charwise "b", false, ""⟩ },
    { name :=
        "a replayed doubled operator that comes to the last line with a count above 1 gives the replay up, as Vim cancels it: 2 d d and . on the one line left, 2 d d . . when the second replay is on the last line, d d, G and 2 ., and 2 c c, a text, <Escape>, j and . each leave the text, the cursor, the register and the history as they were and the view in normal state, with no text inserted, and the echo area says why under the repeat command's name; and the change is still the last change, which . replays from the first line, with the count it had and not the count of the replay that gave up"
      run :=
        pure <|
          let steps (fixture typed : String) : Option (Option (Nat × Bool)) :=
            (evilDriver fixture).map fun driver => evilHistory (evilFed driver typed)
          -- Whether the replay `replay`, typed after `typed`, gave up: what
          -- `typed` left is `shown` and `register`, and the replay left that
          -- and the history, and said why under the repeat command's name.
          let gaveUp (fixture typed replay shown : String) (register : Option Register) : Bool :=
            let after := typed ++ " " ++ replay
            match evilEdited fixture after with
            | some left =>
              evilEdited fixture typed == some ⟨shown, register, false, ""⟩ &&
                left.shown == shown &&
                left.register == register &&
                !left.insert &&
                left.echo == s!"{Vim.repeatCommand}: {Evil.noLineBelow}" &&
                steps fixture after == steps fixture typed
            | none => false
          gaveUp "|ab\ncd\nef" "2 d d" "." "|ef" (linewise "ab\ncd\n") &&
            gaveUp "|ab\ncd\nef\ngh\nij" "2 d d ." "." "|ij" (linewise "ef\ngh\n") &&
            gaveUp "ab\ncd\nef\n|gh" "d d G" "2 ." "ab\ncd\n|ef" (linewise "gh\n") &&
            gaveUp "|ab\ncd\nef" "2 c c X <Escape> j" "." "X\n|ef" (linewise "ab\ncd\n") &&
            evilEdited "|ab\ncd\nef\ngh\nij\nkl" "2 d d G . g g ." ==
              some ⟨"|ij\nkl", linewise "ef\ngh\n", false, ""⟩ &&
            evilEdited "|ab\ncd\nef\ngh" "2 c c X <Escape> G . g g ." ==
              some ⟨"|X\ngh", linewise "X\nef\n", false, ""⟩ &&
            -- The count of a replay that gave up is not kept.
            evilEdited "|ab\ncd\nef\ngh\nij" "d d G 2 . g g ." ==
              some ⟨"|ef\ngh\nij", linewise "cd\n", false, ""⟩ },
    { name :=
        "a replayed change whose motion fails after it moved breaks the replay off, as Vim does: the cursor is where the motion got to, in normal state, nothing is deleted or inserted, the register is the one the change left, the history has no step for it, and the change is still the last change"
      run :=
        pure <|
          let said := s!"{Vim.repeatCommand}: {Evil.cannotMove Evil.wordBackward.name}"
          let steps (fixture typed : String) : Option (Option (Nat × Bool)) :=
            (evilDriver fixture).map fun driver => evilHistory (evilFed driver typed)
          evilEdited "\nab cd |ef gh" "d 2 b ." ==
              some ⟨"|\nef gh", charwise "ab cd ", false, said⟩ &&
            evilEdited "\nab cd |ef gh" "c 2 b X <Escape> ." ==
              some ⟨"|\nXef gh", charwise "ab cd ", false, said⟩ &&
            steps "\nab cd |ef gh" "d 2 b ." == steps "\nab cd |ef gh" "d 2 b" &&
            steps "\nab cd |ef gh" "c 2 b X <Escape> ." ==
              steps "\nab cd |ef gh" "c 2 b X <Escape>" &&
            evilEdited "\nab cd ef |gh" "d 2 b $ . ." ==
              some ⟨"|\nh", charwise "ab g", false, said⟩ &&
            evilEdited "\nab cd |ef gh ij" "d 2 b . G $ ." ==
              some ⟨"\nef |j", charwise "gh i", false, ""⟩ },
    { name :=
        ". replays a change with the command the registry holds for its name, which is the one the change's own keys ran: with operate registered again over the operators that ship and one more, and a key bound to that operator, the key and w erase a word and . erases the next; with a command registered in place of delete-char that deletes two cells, x deletes two and . two more; and with one in place of append that inserts before the cursor, a, a text and <Escape> insert before it and . does again"
      run :=
        pure <|
          let erase : Vocabulary.Operator := { Evil.delete with name := "erase" }
          let more : Array Config.Registration :=
            #[{ name := Vim.operateCommand
                action :=
                  .call (Evil.operate (Evil.operators.push erase) Evil.motions Evil.objects) },
              { name := "delete-char"
                action :=
                  .call fun call => Evil.deleteChar { call with arguments := [.nat 2, .str ""] } },
              { name := "append", action := .call Evil.insert }]
          let handed : Loop.Keys Vim.Default.scheme :=
            { evilHanded more with
              maps := fun _ _ =>
                [Keymap.ofList [(keys "Z", Vim.Bound.operator { name := erase.name })]] }
          let typed (fixture keys : String) : Option (String × String) :=
            (evilDriver fixture handed).map fun driver =>
              let after := evilFed driver keys
              (evilShown after, after.loop.state.echo)
          typed "|a b c d" "Z w" == some ("|b c d", "") &&
            typed "|a b c d" "Z w ." == some ("|c d", "") &&
            typed "|abcdef" "x" == some ("|cdef", "") &&
            typed "|abcdef" "x ." == some ("|ef", "") &&
            typed "a|b" "a X <Escape>" == some ("a|Xb", "") &&
            typed "a|b" "a X <Escape> ." == some ("a|XXb", "") },
    { name :=
        "the repeat command handed its own name as the change gives up, with the sentence its function makes: a replay is no change"
      run :=
        pure <|
          let named :=
            (evilRegistered "a|bc").map fun driver =>
              evilLeft
                (driver.stepped
                    (driver.loop.invoke driver.handed
                      { command := Vim.repeatCommand
                        arguments :=
                          [.bool false, .str "", .str Vim.repeatCommand, .bool false, .str "",
                            .str "delete-char", .nat 0, .str ""] })).1
          evilGaveUp named "a|bc" (Evil.notRepeated Vim.repeatCommand) },
    { name :=
        "every command a default key of the Vim scheme is bound to as changing text is one evil registers, and so is the command an operator's keys run: . finds each in the registry"
      run :=
        pure <|
          let changing :=
            (Vim.Default.normalCommands ++ Vim.Default.insertCommands ++
                  Vim.Default.visualCommands ++
                  Vim.Default.visualLineCommands).filterMap
              fun (_, bound) =>
              match bound with
              | .command command => if command.changes then some command.name else none
              | _ => none
          !changing.isEmpty &&
            (Vim.operateCommand :: changing).all fun name => Evil.commands.any (·.name == name) },
    { name :=
        "a replayed change that names the clipboard register and began an insert session writes the clipboard as the replay's last request: run to its end it leaves the clipboard model holding the word it changed, and stopped by the interrupt before any one of its requests it is rolled back with the clipboard model holding what it held before"
      run :=
        pure <|
          match evilRegistered "|foo bar baz" with
          | none => false
          | some driver =>
            let changed := evilFed driver "\" + c w X <Escape> w"
            -- The replay with an interrupt key that arrives once it has made
            -- `asks` of its requests, or with none.
            let replayed (asks : Option Nat) : EvilEdited × Option String :=
              let after :=
                evilFed
                  { changed with
                    model :=
                      { changed.model with
                        watch := { changed.model.watch with arrivesAfter := asks } } }
                  "."
              (evilLeft after, after.model.clipboard.held)
            let before : EvilEdited × Option String :=
              (⟨"X |bar baz", charwise "foo", false, ""⟩, some "foo")
            let whole : EvilEdited × Option String :=
              (⟨"X |X baz", charwise "bar", false, ""⟩, some "bar")
            let stopped : EvilEdited × Option String :=
              ({ before.1 with echo := s!"{Vim.repeatCommand}: interrupted" }, some "foo")
            let runs := (List.range 80).map fun asks => replayed (some asks)
            (evilLeft changed, changed.model.clipboard.held) == before && replayed none == whole &&
              runs.all (fun run => run == stopped || run == whole) &&
              (runs.filter (· == stopped)).length > 8 &&
              runs.getLast? == some whole },
    { name :=
        "the clipboard a replayed change writes is the text the replay took, whatever the unnamed register held: where the clipboard model was set to another text since the change, and the word the replay changes is the one the unnamed register already holds, the replay writes that word; a replayed change that takes no cell writes nothing; and with a clipboard that is not available the replay runs to its end and says so in the echo area"
      run :=
        pure <|
          let replayed (fixture typed : String) (clipboard : ClipboardModel) :
            Option (EvilEdited × Option String) :=
            (evilRegistered fixture).map fun driver =>
              let changed := evilFed driver typed
              let after := evilFed { changed with model := { changed.model with clipboard } } "."
              (evilLeft after, after.model.clipboard.held)
          replayed "|foo foo baz" "\" + c w X <Escape> w" { held := some "other" } ==
              some (⟨"X |X baz", charwise "foo", false, ""⟩, some "foo") &&
            replayed "|ab\ncd" "\" + c h X <Escape> j" { held := some "other" } ==
              some (⟨"Xab\n|Xcd", asItWas, false, ""⟩, some "other") &&
            replayed "|foo bar baz" "\" + c w X <Escape> w" { available := false } ==
              some (⟨"X |X baz", charwise "bar", false, Evil.clipboardUnavailable⟩, none) &&
            replayed "|a b c d" "\" + d w" {} ==
              some (⟨"|c d", charwise "b ", false, ""⟩, some "b ") }]

end ModelTest
