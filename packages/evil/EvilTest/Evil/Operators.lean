import Editor.Command.Model
import Editor.File
import Editor.InputScheme
import Editor.Invocation
import Editor.Job
import Editor.Language
import Editor.Language.IndentUnit
import Editor.Loop.Driver
import Editor.Mode
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.SyntaxTree
import Editor.SyntaxTree.Model
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Text
import Editor.Vocabulary
import Evil
import Evil.Motions
import Evil.Objects
import Evil.Operators
import Evil.Registers
import Evil.Repeat
import Evil.Vim
import Evil.Vim.Default
import EvilTest.Check
import EvilTest.Support.Evil
import EvilTest.Support.OperatorRows
import EvilTest.Support.Vim

/-!
# Model tests: `Evil/Operators.lean`

The model tests of `Evil/Operators.lean`: `evilOperatorChecks`,
`evilSelectionChecks` and `evilIndentChecks`. The root module `EvilTest.Model` runs
them; its module doc says what each shows.
-/

namespace EvilTest

open Editor
open Editor.Test

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

/-- Every pair of an operator's key and a motion's key of the default
tables (`Vim.Default.operators`, `Vim.Default.motions`) whose motion is a
motion alone (`bareMotionKeys`). -/
def defaultPairs : List (String × String) :=
  Vim.Default.operators.flatMap fun (operator, _) =>
    bareMotionKeys.map fun motion => (operator, motion)

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

/-- The checks of evil's operators (`Evil/Operators.lean`) on the
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
              evilText (evilUndone deleted) == some "abc" },
    { name :=
        "a line-wise operator takes a folded range its ends land in whole: d j and y j from the row above rows 2 to 4 folded take rows 1 to 4, d k from the row below takes rows 2 to 5, d d and y y on the placeholder take rows 2 to 4, 2 d d counts the fold as one line from above it and from it, and 2 d d on a fold that reaches the last line gives up"
      run :=
        pure <|
          let middle : Foldable :=
            { start := 8, stop := 19, key := "f", text := "[2-4]", folded := true }
          let lastRows : Foldable :=
            { start := 12, stop := 23, key := "f", text := "[3-5]", folded := true }
          let fed (fixture typed : String) (fold : Foldable := middle) : Option EvilDriver :=
            (foldedEvilDriver fixture #[fold]).map (evilFed · typed)
          let left (fixture typed : String) : Option EvilEdited := (fed fixture typed).map evilLeft
          let above := "ab0\n|ab1\nab2\nab3\nab4\nab5"
          let on := "ab0\nab1\n|ab2\nab3\nab4\nab5"
          let below := "ab0\nab1\nab2\nab3\nab4\n|ab5"
          let fold := "ab2\nab3\nab4\n"
          left above "d j" == some ⟨"ab0\n|ab5", linewise ("ab1\n" ++ fold), false, ""⟩ &&
            (left above "y j").map (·.register) == some (linewise ("ab1\n" ++ fold)) &&
            left below "d k" == some ⟨"ab0\n|ab1", linewise (fold ++ "ab5\n"), false, ""⟩ &&
            left on "d d" == some ⟨"ab0\nab1\n|ab5", linewise fold, false, ""⟩ &&
            (left on "y y").map (·.register) == some (linewise fold) &&
            left above "2 d d" == some ⟨"ab0\n|ab5", linewise ("ab1\n" ++ fold), false, ""⟩ &&
            left on "2 d d" == some ⟨"ab0\n|ab1", linewise (fold ++ "ab5\n"), false, ""⟩ &&
            ((fed "ab0\nab1\nab2\n|ab3\nab4\nab5" "2 d d" lastRows).map fun driver =>
                (evilText driver, (evilLeft driver).register,
                  (evilLeft driver).echo.endsWith Evil.noLineBelow)) ==
              some (some "ab0\nab1\nab2\nab3\nab4\nab5", none, true) }]

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
(`Evil/Operators.lean`), by key, as `evilOperatorChecks` are. -/
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
        "V j y from the row above a folded range yanks that row and every row the range covers, whole"
      run :=
        pure <|
          let fold : Foldable :=
            { start := 8, stop := 19, key := "f", text := "[2-4]", folded := true }
          (foldedEvilDriver "ab0\n|ab1\nab2\nab3\nab4\nab5" #[fold]).map
              (fun driver => (evilFed driver "V j y").loop.state.register? Evil.unnamed) ==
            some (some { text := "ab1\nab2\nab3\nab4\n", linewise := true }) },
    { name :=
        "v j y from the row above a folded range yanks from the anchor through the end of the range's last row, v k y from the row below it from the range's first row to the anchor, and v j y with the anchor inside the range, past its first byte, from the range's first row"
      run :=
        pure <|
          let fold : Foldable :=
            { start := 8, stop := 19, key := "f", text := "[2-4]", folded := true }
          let yanked (fixture typed : String) : Option (Option Register) :=
            (foldedEvilDriver fixture #[fold]).map
              (fun driver => (evilFed driver typed).loop.state.register? Evil.unnamed)
          yanked "ab0\na|b1\nab2\nab3\nab4\nab5" "v j y" == some (charwise "b1\nab2\nab3\nab4") &&
            yanked "ab0\nab1\nab2\nab3\nab4\na|b5" "v k y" == some (charwise "ab2\nab3\nab4\nab") &&
            yanked "ab0\nab1\nab2\na|b3\nab4\nab5" "v j y" == some (charwise "ab2\nab3\nab4\nab") },
    { name :=
        "a v selection that ends on the line break of the row above a folded range touches only that row: v y and v d from an empty row, and v $ y and v $ d, leave the range alone"
      run :=
        pure <|
          -- Rows 2 to 4 folded, below an empty row and below `ab1`.
          let belowEmpty : Foldable :=
            { start := 5, stop := 16, key := "f", text := "[2-4]", folded := true }
          let belowFull : Foldable :=
            { start := 8, stop := 19, key := "f", text := "[2-4]", folded := true }
          let fed (fixture : String) (fold : Foldable) (typed : String) : Option EvilDriver :=
            (foldedEvilDriver fixture #[fold]).map (evilFed · typed)
          let register (driver : Option EvilDriver) : Option (Option Register) :=
            driver.map (·.loop.state.register? Evil.unnamed)
          let empty := "ab0\n|\nab2\nab3\nab4\nab5"
          let full := "ab0\n|ab1\nab2\nab3\nab4\nab5"
          register (fed empty belowEmpty "v y") == some (charwise "\n") &&
            (fed empty belowEmpty "v d").bind evilText == some "ab0\nab2\nab3\nab4\nab5" &&
            register (fed empty belowEmpty "v d") == some (charwise "\n") &&
            register (fed full belowFull "v $ y") == some (charwise "ab1\n") &&
            (fed full belowFull "v $ d").bind evilText == some "ab0\nab2\nab3\nab4\nab5" &&
            register (fed full belowFull "v $ d") == some (charwise "ab1\n") },
    { name :=
        "a count typed before the operator of a visual selection changes nothing: the selection is what is acted on"
      run :=
        operatorRows
          [.rests "foo |bar baz" "v w 3 d" "foo |az" (charwise "bar b"),
            .rests "abc\nd|ef\nghi" "V 2 y" "abc\n|def\nghi" (linewise "def\n")] }]

/-- The mangled JSON text of the indent checks' repeats, with the cursor on
its second row. -/
def indentRepeatText : String :=
  "[\n|1,\n      2,\n 3,\n4,\n   5,\n6\n]"

/-- The checks of evil's `=` (`Evil.indent`, `Evil/Operators.lean`),
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
              { modelJsonIndented with
                syntaxTree :=
                  { grammar := "json", highlights := some SyntaxTreeModel.highlights } })
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
          let noQuery :=
            { modelJsonIndented with
              syntaxTree := { grammar := "json", highlights := some SyntaxTreeModel.highlights } }
          (evilEdited "    a|b" "A RET").map (·.shown) == some "    ab\n|" &&
            (evilEdited "    a|b" "o").map (·.shown) == some "    ab\n|" &&
            (evilEdited "    a|b" "O").map (·.shown) == some "|\n    ab" &&
            (indentEdited "[\n  |1\n]" "A RET" noQuery).map (·.shown) == some "[\n  1\n|\n]" &&
            (indentEdited "[\n  |1\n]" "o" noQuery).map (·.shown) == some "[\n  1\n|\n]" &&
            (indentEdited "[\n  |1\n]" "O" noQuery).map (·.shown) == some "[\n|\n  1\n]" }]

end EvilTest
