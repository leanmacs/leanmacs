import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Config.Packages
import Editor.Event
import Editor.File
import Editor.InputScheme
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Layout
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Config
import Editor.Test.Ex
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Test.States
import Editor.Text
import Editor.WindowCommands
import Evil
import Evil.Vim
import Evil.Vim.Default
import EvilTest.Check
import EvilTest.Support.Evil
import EvilTest.Support.OperatorRows
import EvilTest.Support.Vim

/-!
# Model tests: `Evil.lean`

The model tests of `Evil.lean`: `evilRestChecks`, `evilStateChecks`,
`evilInsertChecks` and `evilOpenChecks`. The root module `EvilTest.Model` runs them;
its module doc says what each shows.
-/

namespace EvilTest

open Editor
open Editor.Test

/-- Where each of `offsets` rests in a text holding `contents` under the
rule `rest` (`Evil.rested`), on the text model; none when one was
refused. -/
def restedIn (rest : Evil.Rest) (contents : String) (offsets : List Nat) : Option (List Nat) :=
  onTextModel do
    let text ← createText contents
    offsets.mapM (Evil.rested rest text)

/-- The checks of where a cursor rests in a state (`Evil.lean`), on
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

/-- The Vim scheme of the menu's run-table checks: the default states, with
normal state's run table holding `t-enter`, run as `visual-line` entering
that state, and `t-fail`, run as itself entering it too. -/
def menuRunScheme : InputScheme :=
  let enter (name : String) : Vim.Edit := .run { name, enters := some "visual-line" } none none
  Vim.scheme
    (Vim.Default.states.register
      { Vim.Default.states.initial with
        runs := [("t-enter", enter "visual-line"), ("t-fail", enter "t-fail")] })

/-- A driver of the menu's run-table checks over the text and cursor
`fixture` says, with evil's commands and `t-fail`, which gives up. -/
def menuRunDriver (fixture : String) : Option (Loop.Driver menuRunScheme) :=
  let (contents, head) := barred fixture
  let fail : Dispatched := fun _ => giveUp "failed"
  let keys : Loop.Keys menuRunScheme :=
    { command? := (evilHanded (commands := [("t-fail", fail)])).command? }
  (Loop.Driver.over keys (fun _ => none) (evilState contents head) editorModel).toOption

/-- The selection of view 0 of `driver`, as the text model has it. -/
def menuRunSelection (driver : Loop.Driver menuRunScheme) : Option Selection := do
  let target ← driver.loop.state.target? ⟨0⟩
  (target.selection.runModel driver.model.texts).1.toOption

/-- The checks of evil's states (`Evil.lean`) on the loop's driver
over the editor's models, under the Vim scheme that ships with evil's
commands: what entering a visual state and leaving one does to the view's
selection, read from the selection marker the scene names, and what the
scene then shows of the state; and, by the entering command called with a
report written by hand, a state that keeps both ends entered from an
exclusive selection. -/
def evilStateChecks : List Check :=
  [{  name :=
        "a menu item naming a command the view's state's run table has an entry for runs that entry, with the report of the state it enters: t-enter in normal state leaves the view in visual-line, its selection of the line shape, at rest; one that gives up leaves the scheme at rest in normal state"
      run :=
        pure <|
          match menuRunDriver "a|b\ncd" with
          | none => false
          | some driver =>
            let initial := menuRunScheme.report menuRunScheme.init ⟨0⟩
            let entered := (driver.feed { event := .menu "t-enter", stamp := 0 }).1
            let failed := (driver.feed { event := .menu "t-fail", stamp := 0 }).1
            let report := menuRunScheme.report entered.loop.input ⟨0⟩
            report.shape == .line && report.selecting &&
              menuRunScheme.report entered.loop.atRest ⟨0⟩ == report &&
              (menuRunSelection entered).map (·.shape) == some .line &&
              entered.loop.state.echo.isEmpty &&
              failed.loop.state.echo == "t-fail: failed" &&
              menuRunScheme.report failed.loop.input ⟨0⟩ == initial &&
              menuRunScheme.report failed.loop.atRest ⟨0⟩ == initial &&
              menuRunSelection failed == menuRunSelection driver },
    { name :=
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
    (evilDriver "a|bc"
          (evilHanded Test.Minibuffer.package.registered.commands
            [("ask", ask), ("greet", greet)])).map
      fun driver => (driver.stepped (driver.loop.runNamed driver.handed "ask")).1
  let ex :=
    (evilDriver "a|bc"
          (evilHanded
            (exLinePackage.registered.commands ++ Test.Minibuffer.package.registered.commands))).map
      (evilFed · ":")
  [(asked, "greet", fun answer => s!"hello {answer}"), (ex, ExLine.name, ExLine.unknown)]

/-- Whether `check` holds of each prompt of `evilPrompts`, each opened as
its continuation says, with the asking view left as it was. -/
def evilPromptsHold (check : EvilDriver → (String → String) → Bool) : Bool :=
  evilPrompts.all fun
    | (some asking, command, answered) =>
      asking.loop.state.prompt.map (·.continuation.command) == some command &&
        evilShown asking == "a|bc" &&
        check asking answered
    | (none, _, _) => false

/-- The checks of evil's insert state (`Evil.lean`) on the loop's
driver over the editor's models, under the Vim scheme that ships with
evil's commands: the keys that begin an insert, typed text, and `<Escape>`,
and that one insert session is one step of the history. -/
def evilInsertChecks : List Check :=
  [{  name :=
        "criterion 6, on the models, over two windows side by side: with no active keymaps C-w in insert state deletes the word before the bar and l after it is text, the view staying in insert state and focused; with active keymaps that bind the window keys, as a config's bindKey binds them, C-w l and C-w h in insert state focus the window on the right and come back without leaving insert state, and typing goes on where it was"
      run :=
        pure <|
          let stateOf (driver : EvilDriver) (view : Nat) : String :=
            (driver.loop.input : Vim.State).stateOf Vim.Default.states ⟨view⟩
          -- Stand-ins, written here over the editor API, for the two window
          -- commands the check's keys run, under their names: the windows
          -- are views 0, on the left, and 1.
          let focusing (name : String) (view : Nat) : Config.Registration :=
            { name, action := .call fun _ => discard <| (⟨view⟩ : ViewId).focus }
          let handed : Loop.Keys Vim.Default.scheme :=
            {
              evilHanded
                #[focusing WindowCommands.rightName 1, focusing WindowCommands.leftName 0] with
              layout := some Layout.default }
          let bound : Loop.Keys Vim.Default.scheme :=
            { handed with
              maps := fun _ _ =>
                [Vim.Default.keymap
                    (Vim.Default.windowKeys.map fun (text, name) => (text, .command { name }))] }
          let over (handed : Loop.Keys Vim.Default.scheme) : Option EvilDriver :=
            (Loop.Driver.over handed (fun _ => none) (windowsUnder 2 Layout.default)
                editorModel).toOption
          match (over handed).map (evilFed · "i h e l l o SPC w o r l d C-w l"), over bound with
          | some plain, some driver =>
            let typed := evilFed driver "i a b C-w l"
            let back := evilFed typed "C-w h"
            let more := evilFed back "c"
            evilText plain == some "hello l" && plain.loop.state.frame.focused == ⟨0⟩ &&
              stateOf plain 0 == "insert" &&
              typed.loop.state.frame.focused == ⟨1⟩ &&
              stateOf typed 0 == "insert" &&
              back.loop.state.frame.focused == ⟨0⟩ &&
              stateOf back 0 == "insert" &&
              evilText more == some "abc" &&
              stateOf more 0 == "insert"
          | _, _ => false },
    { name :=
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
          let handed :=
            evilHanded Test.Minibuffer.package.registered.commands [("ask", ask), ("greet", greet)]
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
        "<Backspace>, typed while a prompt is open, deletes the character before the minibuffer's bar, a character of two bytes whole, and RET then accepts what is left; with the bar at the start of a text it deletes nothing; deleting the last character leaves the minibuffer empty and the prompt open"
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
            evilHanded Test.Minibuffer.package.registered.commands
              [("ask", ask), ("greet", greet), ("home", home)]
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
            evilShown erased ⟨1⟩ == "Ad|" && evilShown erased == "a|bc" &&
              answered.loop.state.prompt.isNone &&
              answered.loop.state.echo == "hello Ad" &&
              evilShown atStart ⟨1⟩ == "|Adé7" &&
              atStart.loop.state.prompt.isSome &&
              evilShown emptied ⟨1⟩ == "|" &&
              emptied.loop.state.prompt.isSome &&
              evilShown emptied == "a|bc" },
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
        "C-u, typed while a prompt is open, the minibuffer's and the ex line's, deletes from the minibuffer's bar to the input's start and keeps what is after the bar, and RET accepts what is left; with the bar at the start it deletes nothing; on an empty minibuffer it leaves the prompt open"
      run :=
        pure <|
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
              evilShown cleared == "a|bc" },
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
              evilText (evilUndone ended) == some "abc" },
    { name :=
        "under the Vim scheme the reserved keys invocation runs a key as pressing it does: i enters insert state, and x deletes the character under the cursor"
      run :=
        pure <|
          match evilDriver "|x foo" with
          | none => false
          | some driver =>
            let report (driver : EvilDriver) := Vim.Default.scheme.report driver.loop.input ⟨0⟩
            let pressing (driver : EvilDriver) (text : String) : EvilDriver :=
              (driver.stepped
                  (driver.loop.invoke driver.handed (InputScheme.keysInvocation (keys text)))).1
            let pressedI := pressing driver "i"
            let typedI := evilFed driver "i"
            let pressedX := pressing driver "x"
            let typedX := evilFed driver "x"
            report pressedI == report typedI && report pressedI != report driver &&
              evilShown pressedI == evilShown typedI &&
              evilText pressedX == some " foo" &&
              evilShown pressedX == evilShown typedX }]

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

end EvilTest
