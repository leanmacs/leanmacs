import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Model
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Display
import Editor.Display.Model
import Editor.Evil
import Editor.Evil.Motions
import Editor.InputScheme
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Loop
import Editor.Loop.Driver
import Editor.Menu
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Vocabulary
import Editor.Watch
import Editor.Watch.Model
import ModelTest.Check
import ModelTest.Support.Display
import ModelTest.Support.Evil
import ModelTest.Support.OperatorRows

/-!
# Model tests: `Editor/Evil/Motions.lean`

The model tests of `Editor/Evil/Motions.lean`: `evilMotionChecks`,
`evilFindChecks` and `evilSearchChecks`. The root module `ModelTest` runs them;
its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

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
        "every key the default tables bind to a motion has a motion of its name in the vocabulary: pressed in a text of three lines, a motion that takes a character with one, none says it has no such motion, and none but the searches and the marks says anything in the echo area (a search says its warning or its error: n and N with no last search, and * on the one occurrence of its word; a mark that is not set says so)"
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
            let marks := name == Evil.markExact.name || name == Evil.markLine.name
            match evilDriver "ab cd\ne|f gh\nij kl" with
            | none => some s!"{typed}: no driver"
            | some driver =>
              let echo := (evilFed driver typed).loop.state.echo
              if
                  echo.isEmpty || searches && echo != Evil.noSuchMotion name ||
                    marks && echo == Evil.markNotSet then
                none
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
            discard <| Evil.down.target text { head, view := ⟨0⟩, buffer := ⟨0⟩, wanted }
            return (← Watch.now) - before
          (program.runModel countingModel).1.toOption
        -- How many snapshots the motion took: a released one keeps its slot.
        let taken (fixture : String) (wanted : Option WantedColumn) : Option Nat :=
          let (contents, head) := barred fixture
          let program : EditorM Unit := do
            discard <|
                Evil.down.target (← createText contents)
                  { head, view := ⟨0⟩, buffer := ⟨0⟩, wanted }
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
        "the move command called with a motion's name and no count after it moves with no count: every motion of the vocabulary, from the middle of a text of three lines, leaves the cursor where it leaves it when the count is 0, which is how a key with no count calls it, and says the same, which is nothing but for the searches and the marks, which with no mark named say so; by the name of the motion one cell on it goes where l does"
      run := do
        let here := "ab cd\ne|f gh\nij kl"
        let wrong :=
          Evil.motions.toList.filterMap fun motion =>
            let alone := evilMoved here [.str motion.name]
            let counted := evilMoved here [.str motion.name, .nat 0]
            -- A search says its warning or its error, the same with no count
            -- and with the count 0; every other motion says nothing.
            let searches := motion.name.startsWith "search" || motion.name.startsWith "word-search"
            let marks := motion.name == Evil.markExact.name || motion.name == Evil.markLine.name
            if
                alone.isSome && alone == counted &&
                  (searches || marks && alone.map (·.2) == some Evil.unknownMark ||
                    alone.map (·.2) == some "") then
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

/-- The motion keys of the default tables that take the character the next
key names (`Bound.charMotion`) as a find does: all but the two that go to a
mark, whose rows are `evilMarkChecks`' (`ModelTest/Editor/Evil/Marks.lean`). -/
def charMotionKeys : List String :=
  Vim.Default.motions.filterMap fun (key, bound) =>
    match bound with
    | .charMotion name =>
      if name == Evil.markExact.name || name == Evil.markLine.name then none else some key
    | _ => none

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

end ModelTest
