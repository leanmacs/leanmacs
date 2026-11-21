import Editor.Evil.Objects
import Editor.InputScheme
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Loop.Driver
import Editor.ModeLine
import Editor.Scene
import Editor.State
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Text
import Editor.Vocabulary
import ModelTest.Check
import ModelTest.Support.Evil
import ModelTest.Support.OperatorRows
import ModelTest.Support.Vim

/-!
# Model tests: `Editor/Evil/Objects.lean`

The model tests of `Editor/Evil/Objects.lean`: `evilObjectChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The badge a scene's mode line shows first for a selected view in the
Vim state view 0 is in after the keys `typed` under the grammar alone: the
default scheme's first reported field, padded as the `state` segment pads
it. -/
def evilBadge (typed : String) : Option StatusField :=
  (vimDefaultReport typed).status[0]?.map ({ · with padding := ModeLine.badgePadding })

/-- The text objects source of a second test mode, in the model's query
subset over its JSON grammar, whose insides are smaller than their nodes: a
pair is a function, and inside one the object it holds, and a class, and
inside one the array it holds. A cursor on a pair's key is in the node and
outside its inside. -/
def jsonPairObjects : String :=
  "(pair) @function.outer\n(pair (object) @function.inner)\n(pair) @class.outer\n(pair (array) @class.inner)"

/-- The selection the scene shows after the keys `typed`, pressed from the
fixture `fixture` on `treeRegistered`: its ranges, as an anchor and a head
each, its shape, and the text each range covers. -/
def treeSelected (fixture typed : String) : Option (List (Nat × Nat) × Shape × List String) :=
  ((treeRegistered fixture).bind fun driver => evilSeen (evilFed driver typed)).map fun seen =>
    ((seen.selection.ranges.map fun range => (range.anchor, range.head)).toList,
      seen.selection.shape, seen.covered.toList)

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

end ModelTest
