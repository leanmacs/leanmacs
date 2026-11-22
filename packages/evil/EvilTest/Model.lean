import EvilTest.Check
import EvilTest.Evil
import EvilTest.Evil.Clipboard
import EvilTest.Evil.Jumps
import EvilTest.Evil.Marks
import EvilTest.Evil.Motions
import EvilTest.Evil.Objects
import EvilTest.Evil.Operators
import EvilTest.Evil.Registers
import EvilTest.Evil.Repeat
import EvilTest.Evil.Scroll
import EvilTest.Evil.TreeObjects
import EvilTest.Evil.Undo
import EvilTest.Vim
import EvilTest.Vim.Contract
import EvilTest.Vim.Default

/-!
# The test driver of the package `evil`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of `Evil.lean`
are in `EvilTest/Evil.lean`, those of `Evil/<X>.lean` in
`EvilTest/Evil/<X>.lean`, those of the scheme, `Evil/Vim.lean`, in
`EvilTest/Vim.lean`, and those of its defaults, `Evil/Vim/Default.lean`, in
`EvilTest/Vim/Default.lean`, with the scheme contract's run over both in
`EvilTest/Vim/Contract.lean`. They run on evil's test kit
(`EvilTest/Kit.lean`), the drivers of `EvilTest/Support/` and the core's
kit. They were the core's (`ModelTest.<name>`) while evil and the Vim
scheme were modules of the core, and moved here with their sentences as
they were, in the order the core ran them.

The Vim scheme (`Evil/Vim.lean`) is checked as the core checks an input
scheme, with no model:

- `vimEditChecks`: what an edit compiles to, the layout of each kind of
  invocation, a command's with a character first, and what an edit says
  of itself;
- `vimRegistryChecks`: the registry of Vim states: looking a state up by
  its name, and registering one. A record holds keymaps and so has no
  equality: the checks compare records by their fields (`vimSeen`);
- `vimGrammarChecks`: the grammar: which keymaps a key is looked up in,
  and what a key sequence parses to and yields, a command that takes a
  character (`m`) among them;
- `vimStateChecks`: Vim states: which state a view is in, how one is
  entered, what the scheme reports of a view in a state, what the grammar
  reads of a state's record (typed text, an operator over the selection),
  the last change, and a mode's keys under the Vim scheme: a hand-tuned
  key is typed text in insert state, and `Mode.check` reads every state's
  keymaps; and a command that takes a character awaiting it, and never
  the last change;
- `vimHintChecks`: what the Vim scheme lists as able to follow a keymap
  prefix (`Vim.State.continuations`): keys of both tiers, an active prefix
  over a state's binding, the pending keymaps while an operator waits, and
  nothing after a count, an operator, the register prefix or a command
  that takes a character alone;
- `vimKeyBindingChecks`: the key bindings the Vim scheme lists
  (`Vim.State.keyBindings`): the commands of the walk's tiers in the view's
  state, an active binding first with its description, and no part of
  speech, no command that takes a character by its key alone, no sequence
  that begins with a count digit, no mode's binding
  where typing is text and no binding an active prefix shadows;
- `vimDefaultChecks`: the default states and bindings
  (`Evil/Vim/Default.lean`), observed through the grammar:
  what each default key parses to, and what the scheme reports of the view
  after it. They restate no table and name no vocabulary or command name.
  The scheme lists the cursor face of each of its states, each is a cursor
  face of the face vocabulary, which every shipped theme is held to, and
  every face it reports, with each state's badge, is in that vocabulary;
- `vimDefaultHintChecks`: over every default state, every key the scheme
  lists after a keymap prefix is what `Vim.parse` and the walk make of it,
  and every chord of the defaults it leaves out walks to nothing;
- `vimContractChecks`: the scheme contract holds of the Vim scheme, over
  the registry written here and over the default states.

The grammar's checks run on a registry and keymaps written here
(`vimStates`), so that none of them names a default binding.

Evil (`Evil.lean`), what the Vim scheme's invocations run, is
checked on the editor's models. This is where Vim keys are pressed against
a text, under the Vim scheme that ships with the commands compiled code
registers for evil (`Evil/Compiled.lean`), on the loop's driver:

- `evilRestChecks`: where a cursor rests under each rule, from every
  position of a few small texts, on the text model alone;
- `evilMotionChecks`: each motion's key in a text with the cursor written
  into it as a bar (`evilKeys`, `evilRows`), with no count, a count of 1, a
  count inside the text and a count past it; the wanted column, by keys
  and by a command that calls the move command twice with one call; a
  sweep of every motion of the vocabulary from every position a cursor may
  rest at; and that every default motion key has a motion of its name;
- `evilStateChecks`: `v`, `V` and `<Escape>`: the selection the scene
  shows, its shape and what it covers, and the scene's cursor and status
  field in each state; and, by the entering command called with a report
  written by hand (`evilEntered`), a state that keeps both ends entered
  from an exclusive selection, which no default key does: where the anchor
  rests, and that the head steps back;
- `evilInsertChecks`: `i a I A`, typed text and `<Escape>`; that an insert
  session is one step of the history, by an undo request; a key typed into
  a prompt; a committed text in normal state and inside a session; and
  the reserved invocation that presses keys, which runs `i` and `x` as
  pressing them does;
- `evilOperatorChecks`: the operators (`Evil/Operators.lean`). An
  operator's keys are pressed with a sentinel in the unnamed register
  (`evilEdited`), so a register left as it was is seen, and a row
  (`OperatorRow`, `operatorRows`) says the text, the cursor, the register
  and whether it is line-wise, whether the view is left in insert state,
  and whether the command gave up. `operatorTable` is every operator over
  every motion that takes no argument in five situations; beside it are the
  special cases, the calls of the operate command that give up, and that an
  operator is one step of the history. `operatorSweep` presses every default
  operator key with every default motion key from every resting position of
  a few texts, a motion that takes a character with one;
- `evilFindChecks`: `f`, `t`, `F`, `T`, `;` and `,` (`Evil/Motions.lean`)
  as moves (`findRows`) and under each operator (`findOperatorRows`, which
  `findOperatorPairs` holds to the default tables), and the last find they
  keep;
- `evilSearchChecks`: the searches, `/`, `?`, `n`, `N`, `*` and `#`, as moves
  and under each operator (`searchOperatorRows`, held to the default
  tables), the text model answering the searches of literal patterns;
- `evilSelectionChecks`: the operators over a `v` and a `V` selection, by
  the same rows, and that the operator's key leaves one cursor;
- `evilObjectChecks`: the text objects (`Evil/Objects.lean`), by key: what
  each operator takes over each object and what each object selects in a
  visual state, against Vim 9.1's rows, `%` under an operator, the tables'
  completeness, and two sweeps;
- `evilRegisterChecks`: `x`, the registers a yank and a deletion set, the
  clipboard register on the clipboard model (`evilClipped`), and `p` and
  `P`, by the same rows;
- `evilOpenChecks`: `o` and `O`, by the same rows, and their insert
  session;
- `evilIndentChecks`: `=` by key in a JSON language whose model tree
  answers the indents query (`indentDriver`): `gg=G` over a mangled text,
  `=af`, counts, `=j`, a visual selection, one undo step, `.` over another
  range, a config entry's tab unit, and the give-up with no syntax tree, no
  indents query, or a tree not delivered yet (`undeliveredDriver`); and the
  new lines `RET`, `o` and `O` start at their level, at the row's own indent
  while the tree is not delivered, and as before this phase with neither;
- `evilUndoChecks`: `u` and `C-r` after one change of each kind
  (`undoRows`): the text and the cursor from before the change, and those
  the change left; `u` at the root of a buffer a restore made, which
  says its history starts there; and, in an excerpt buffer
  (`evilExcerptDriver`, on the kit's `excerptRegistrations`), what `u` and
  `C-r` say of a step refused because a source moved or was removed
  (`Evil.sourceMovedSays`, `sourceRemovedSays`), and of nothing left to
  undo or redo after it. They are the phase's rule and are not compared with
  Vim, which leaves the cursor at the start of the changed text;
- `evilRepeatChecks`: `.` after a change of each kind (`repeatRows`), a
  count before it, a change with an insert session and its typed and
  committed text, the editing keys of insert state in a session
  (`insertKeysRepeatRows`), and what is not repeated;
- `evilJumpChecks`: `C-o`, `C-i` and `TAB` through the jumps that `gg`,
  `G`, the searches and `%` record (`Evil/Jumps.lean`), to the
  exact column, with a count, under an operator, as `:help jumplist`'s
  example scaled to eight lines, an entry following lines inserted above
  it, a failed search and the motions that are no jump recording nothing,
  and a split's copy of the list moved through on its own;
- `evilMarkChecks`: `m`, `` ` `` and `'` (`Evil/Marks.lean`): a
  mark set and gone to, exactly and at its line's first non-blank, as a
  jump, under an operator, after an insert above it, the marks not set or
  not named, `''` back and forth, a jump that leaves the cursor in place
  keeping `''`, `m '` and ``m` ``, a mark motion run in a window
  that is not focused, and across buffers on the file model: a buffer's
  own marks, a global mark in another buffer, under an operator, in a
  closed buffer's file, reopened with one jump recorded, attached again to
  the reopened buffer's text so that an edit above it carries it, and
  dropped with a closed buffer that held no file; a mark erased when its
  line is deleted, on the last line too, a global mark kept on the line
  that takes its place, kept by a
  deletion of part of its line, kept on the first line of `3cc` and of a
  charwise delete across lines, kept on the first line of `cj` and `2cc`
  above an empty line, erased by `3dd` on every line, by `dd` on
  a text's only line and by `3cc` on the lines after the first, kept by
  `cc` on the only line and by a redo of its `dd`, put back by undo at its line and column,
  erased again by redo and put back again by undo, and put back step by
  step by a counted undo and redo (`markUndoRows`); and
  the recorded departures, one check each named for its task: a line's
  marks erased by the edit's shape, text typed at a mark, a
  global mark's column on a deleted line, the numbered marks, the change
  marks, the visual marks, the marks of the last change and insert, the
  mark of the last exit, the sentence and paragraph marks, `m` in the
  visual states, `:marks` and `:delmarks` on the ex line, `g'` and
  ``g` ``, `]'`, `['`, ``]` `` and ``[` ``, `:mark` and `:k`,
  `:lockmarks` and `:keepmarks` on the ex line, global marks
  kept in the session alone, a lowercase mark with its buffer closed, and
  `` ` ` `` after a jump into another buffer;
- `clipboardCommandChecks`: the Edit menu's Cut, Copy, Paste and Select
  All (`Evil/Clipboard.lean`), each by its chord and by its menu
  item (`clipRan`), in each Vim state, on the clipboard model; and evil
  registers the four under the core's names (`Editor/Clipboard.lean`);
- `evilScrollChecks`: the scroll commands (`Evil/Scroll.lean`) by key, in
  frames a few rows tall, and the scroll margin after every motion of the
  vocabulary: keys are pressed, and what the next scene shows of a view is
  asked of the driver's models (the core kit's `viewSeen`,
  `Editor/Test/Views.lean`); and the scroll commands over the header blocks
  of an excerpt buffer;
- `treeObjectRuleChecks`: the syntax tree's text-object rule
  (`Evil.TreeObjects.choose`, `Evil/TreeObjects.lean`), pure, over
  hand-built rows;
- `atPointRepeatChecks`: what a repeat replays after completion at point:
  what a command typed in place of typed text reaches the last change's
  recording, only when the command ran to its end, and `.` after an insert
  that accepted a preview inserts what that insert left.

Each expected text of a row is written by hand from Vim's documented
behaviour (`docs/design/keymaps-and-modes.md`, "Motions as built"). No
check runs Vim. The word rule outside ASCII is the text port's and is not
restated here: the word motions' rows are ASCII, and one text with letters
Vim and the editor agree on.
-/

/-- Every check of the test driver, in the order they run. -/
def EvilTest.checks : List EvilTest.Check :=
  EvilTest.vimEditChecks ++ EvilTest.vimRegistryChecks ++ EvilTest.vimGrammarChecks ++
    EvilTest.vimStateChecks ++
    EvilTest.vimHintChecks ++
    EvilTest.vimKeyBindingChecks ++
    EvilTest.vimDefaultChecks ++
    EvilTest.vimDefaultHintChecks ++
    EvilTest.vimContractChecks ++
    EvilTest.treeObjectRuleChecks ++
    EvilTest.atPointRepeatChecks ++
    EvilTest.evilRestChecks ++
    EvilTest.evilMotionChecks ++
    EvilTest.evilStateChecks ++
    EvilTest.evilInsertChecks ++
    EvilTest.evilOperatorChecks ++
    EvilTest.evilFindChecks ++
    EvilTest.evilSearchChecks ++
    EvilTest.evilSelectionChecks ++
    EvilTest.evilObjectChecks ++
    EvilTest.evilRegisterChecks ++
    EvilTest.evilOpenChecks ++
    EvilTest.evilIndentChecks ++
    EvilTest.evilUndoChecks ++
    EvilTest.evilRepeatChecks ++
    EvilTest.evilJumpChecks ++
    EvilTest.evilMarkChecks ++
    EvilTest.evilScrollChecks ++
    EvilTest.clipboardCommandChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← EvilTest.failures EvilTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"evil-test: {EvilTest.checks.length} checks passed"
    return 0
  else
    return 1
