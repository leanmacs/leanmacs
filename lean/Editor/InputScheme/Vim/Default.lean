import Editor.InputScheme.Vim
import Editor.Key.Notation

/-!
# The Vim scheme's default states and bindings

The Vim scheme that ships: the five Vim states and what their keymaps bind,
as data, and the scheme over them (`scheme`). The grammar is
`Editor/InputScheme/Vim.lean`, which knows none of these keys
(`docs/design/keymaps-and-modes.md`, "Default bindings").

## The tables

Each table is rows of a key string (`Editor/Key/Notation.lean`) and what it
is bound to. The names in them are the vocabulary names and command names
that the motions, operators and commands are registered under: a name is
changed in its row and in its registration together. Nothing here says what
a name does. The motions' entries are `Evil.motions`
(`Editor/Evil/Motions.lean`), and the commands that are built are
registered in `Editor/Evil/Compiled.lean`,
`Editor/Minibuffer/Compiled.lean`, for `ex`, which `:` names and
which opens the ex command line, `Editor/Ex/Compiled.lean`, and, for
`keyboard-quit`, which `C-g` names and which cancels a running `:!`,
`Editor/Shell/Compiled.lean`; a name with
nothing registered under it says so in the echo area when its key runs.
The operators' entries are `Evil.operators`
(`Editor/Evil/Operators.lean`), and the text objects' `Evil.objects`
(`Editor/Evil/Objects.lean`).

| Table | Binds |
|---|---|
| `motions` | The motions of normal state and the visual states. `f`, `F`, `t` and `T` are motions that take the character the next key names (`Bound.charMotion`), and `/` and `?` motions that ask for a pattern in the minibuffer (`Bound.promptMotion`, labelled `/` and `?`). `%` is the motion `matching-bracket` |
| `operators` | The operators: `d`, `c`, `y` and `=` (`indent`). `c` names the state `insert`, and `y` changes no text |
| `objects` | The text objects: `i` or `a` and then `w`, `W`, `"`, `'`, `` ` ``, `(`, `[` or `{`, Vim's; or `f`, `c` or `a`, the syntax tree's function, class and argument (`Editor/Evil/TreeObjects.lean`). `)` and `b` are aliases of `(`, `]` of `[`, and `}` and `B` of `{`, bound to the same names |
| `normalCommands` | Normal state's commands: those that begin an insert, those that change text, undo, redo and the command line, `C-g`, which cancels a running `:!` or filter (`keyboard-quit`), the two that enter a visual state, the register prefix, and the repeat key, `.`, which is a part of speech of its own and no command's key (`Bound.repeat`) |
| `insertCommands` | Insert state's: the key that returns to normal state, and its editing keys, `<Backspace>`, `RET`, `TAB` and the four arrow keys (`Editor/Evil.lean`, "Editing keys"), each bound as a command that changes no text for the grammar, so it is not the last change. `<Backspace>`, `RET` and `TAB` add themselves to the session's recording (`Command.typed`), so `.` replays them; each arrow key restarts the last change as `i` once something is typed after it (`Command.restarts`), as Vim 9.1's `ins-special-special` says |
| `visualCommands`, `visualLineCommands` | A visual state's: the keys that return to normal state, the key that enters the other visual state, and the register prefix |
| `minibufferCommands` | The minibuffer state's: `RET`, which accepts the prompt, `<Escape>`, which cancels it, `TAB` and `C-n`, which move to the next of its candidates, `S-TAB` and `C-p`, which move to the previous, `<Backspace>`, which deletes the character before the bar, and cancels the prompt when the minibuffer is empty, as Vim's command line does, `<ArrowLeft>` and `<ArrowRight>`, the motions `left` and `right`, and `C-u`, which deletes from the bar to the input's start |
| `scrollCommands` | The commands that scroll a view, of normal state and the two visual states: `C-d` and `C-u`, by half a view, `C-f` and `C-b`, by a view, and `z t`, `z z` and `z b`, which put the cursor's row at the top, in the middle and at the bottom of the view (`Editor/Evil/Scroll.lean`). Each changes no text and enters no state, so none is the last change. They are commands and not motions, so an operator's key before one is dropped. `z` begins the three sequences and is bound to nothing itself, so it is a prefix in those states. Insert state and the minibuffer's do not have the table: there `C-d` and `C-u` are Vim's editing keys, and `z` is text. `C-u` is built in the minibuffer's state, which binds it in its own table; in insert state neither is built |

## The states

| State | Keymaps, in precedence order | Cursor | Selection | The grammar reads | Run table |
|---|---|---|---|---|---|
| `normal`, the initial state | `normalCommands`, `scrollCommands`, `operators`, `motions`; while an operator waits, `objects`, `scrollCommands`, `operators`, `motions` | Block | Inclusive | | `normalRuns` |
| `insert` | `insertCommands` | Bar | Exclusive | Typing is text | `insertRuns` |
| `visual` | `visualCommands`, `scrollCommands`, `operators`, `motions`, `objects` | Block | Inclusive | Operators act on the selection | `visualRuns` |
| `visual-line` | `visualLineCommands`, `scrollCommands`, `operators`, `motions`, `objects` | Block | Line | Operators act on the selection, and a text object enters `visual` | `visualRuns` |
| `minibuffer`, the state of the minibuffer's view | `minibufferCommands` | Bar | Exclusive | Typing is text | None |

**Normal state's pending keymaps** (`StateRecord.pending`) are what it
walks while an operator waits, Vim's Operator-pending mode: its commands
are left out, so `i` and `a` begin a text object after `d`, `c` or `y`, and
every other key of `normalCommands` resets there as an unbound key does,
which is what it did as a command. `scrollCommands` stays, so `d z t`
resets as before.

## The run tables

A state's run table says what a command name, reached by a key bound to
it alone or by a menu item, is completed as in the state
(`Editor/InputScheme/Vim.lean`, "Vim states"). The names are the Edit
menu's clipboard commands (`Editor/Evil/Clipboard.lean`, whose module docs
have what each does in each state), and a name is changed here and in its
registration together:

| Table | Runs |
|---|---|
| `normalRuns` | `clipboard-paste` as `"+P` (`put-before` from `+`), and `select-all` as `select-all` entering `visual-line` |
| `insertRuns` | `select-all` as in normal state, which ends the insert session |
| `visualRuns` | `clipboard-copy` as `"+y` and `clipboard-cut` as `"+d` over the selection, `clipboard-paste` as the operator `replace` over it from `+`, each ending the selection in normal state, and `select-all` as in normal state |

The minibuffer's state has none: Paste runs `clipboard-paste` itself, which
inserts at the bar, and Copy, Cut and Select All give up.

The selection's shape is the one the text store's shapes map a state onto
(`docs/design/text-and-display.md`, "What a selection covers, and how evil
maps onto it"): a cursor between characters where typing is text, a cursor
on a cell in normal state, and what a visual state selects. What the scheme
reports of a view in each state follows from its row
(`Editor/InputScheme/Vim.lean`, "Vim states"): a motion extends the
selection in the two visual states, and a view in `insert` or `minibuffer`
is in an insert session and takes committed text.

**The minibuffer's view is in a state of its own** (`states.minibuffer`
names it), Vim's own command-line mode: no key enters it, and the scheme
puts a view in it when it is told the view is the minibuffer's
(`Editor/InputScheme/Vim.lean`, "Vim states").

- **Why not `insert`.** There `<Escape>` enters normal state and `RET` is
  bound to nothing, so answering a prompt would take `<Escape>` and then a
  key of normal state.
- **Why the accept and cancel keys are in the state's table**, though the
  minibuffer's mode fills the roles `activate` and `quit`
  (`Editor/Minibuffer.lean`). The state inserts text, so a mode's role
  keys do not hold there, and the key for `quit` is `q`, which must be
  text. A binding meant for one state belongs in that state's keymaps.
- **The keys that move through a prompt's candidates are in the table
  too**, for the same reason: the mode fills `next-item` and
  `previous-item`, whose keys here are `j` and `k`, which must be text.
  They are Vim's own keys in its command line: `TAB` and `C-n` for the
  next candidate, `S-TAB` and `C-p` for the previous. A window system may
  report Shift and Tab under another name than `S-TAB`; `C-p` is beside it.
- **`<Backspace>` is bound there**, to the minibuffer's command that
  deletes backward (`Editor/Minibuffer.lean`), because a key that prints
  nothing does nothing in a state where typing is text unless it is bound.
  On an empty minibuffer it cancels the prompt, as `<BS>` does on Vim's
  empty command line; Emacs's minibuffer does nothing there.
- **`<ArrowLeft>` and `<ArrowRight>` are the motions `left` and `right`**,
  Vim's `c_<Left>` and `c_<Right>`. The minibuffer is one line under an
  exclusive bar, so they stop at the input's start and its end. They set no
  boundary in its history, which is thrown away with the prompt.
- **`C-u` deletes from the bar to the input's start** and keeps what is
  after the bar, Vim's `c_CTRL-U` (`Editor/Minibuffer.lean`, "Deleting to
  the start"). It never cancels the prompt.
- **The ex line has these keys too**: it is a prompt, so its view is the
  minibuffer's, in this state. The one key of Vim's command line that
  edits and is not bound is `C-w`.
- **The interrupt key is not bound there**, as it is not in Vim's command
  line.

## The role table and the leader

`roles` puts each registered role (`Editor/Role.lean`) on evil-collection's
usual key for list buffers, and `leader` is `\`, Vim's own default
`maplocalleader`, which begins no binding of any default state:

| Role | Key |
|---|---|
| `next-item` | `j` |
| `previous-item` | `k` |
| `activate` | `RET` |
| `quit` | `q` |
| `refresh` | `g r`, under the `g g` prefix |
| `toggle` | `TAB` |
| `mark` | `m` |

`j` and `k` replace the motions only in buffers whose modes fill those
roles. A string `Key.parse` refuses puts its role on no key, which the
scheme contract reports.

## Where an addition goes

| Addition | Where |
|---|---|
| A new default key | A row of the table for its part of speech and its state |
| A command name that runs as another edit in a state | A row of that state's run table |
| A new role | A row of `roles` |
| A new default Vim state | A record in `states`, with a table of its own for the keys that leave it |
| What a name in a table does | The vocabulary or the command registry, under that name; nothing here |

Pinned by `ModelTest.vimDefaultChecks`, which observe the defaults through
the grammar and restate no table, and the scheme contract is run on
`scheme` in `ModelTest.vimContractChecks`. The run tables are pinned by
what the clipboard commands do in each state
(`ModelTest.clipboardCommandChecks`).
-/

namespace Editor.Vim.Default

/-- A command that enters the Vim state `state` and changes no text. Its
name is the state's. -/
private def entering (state : String) : Bound :=
  .command { name := state, enters := some state }

/-- A command that begins an insert: it changes text, and enters the state
`insert`. -/
private def inserting (name : String) : Bound :=
  .command { name, changes := true, enters := some "insert" }

/-- A command that changes text and enters no state. -/
private def changing (name : String) : Bound :=
  .command { name, changes := true }

/-- A command that changes no text and enters no state. -/
private def running (name : String) : Bound :=
  .command { name }

/-- A command of insert state's that changes no text for the grammar and
adds `typed` to the text kept for the last change, for the repeat. -/
private def typing (name typed : String) : Bound :=
  .command { name, typed := some typed }

/-- A command of insert state's that changes no text for the grammar and
restarts the last change as `i`, the command `insert`, once something is
typed after it. -/
private def restarting (name : String) : Bound :=
  .command { name, restarts := some "insert" }

/-- The motions: each key string, and the motion's vocabulary name. -/
def motions : List (String × Bound) :=
  [("h", .motion "left"), ("j", .motion "down"), ("k", .motion "up"), ("l", .motion "right"),
    ("w", .motion "word-forward"), ("b", .motion "word-backward"), ("e", .motion "word-end"),
    ("W", .motion "bigword-forward"), ("B", .motion "bigword-backward"),
    ("E", .motion "bigword-end"), ("0", .motion "line-start"),
    ("^", .motion "line-first-non-blank"), ("$", .motion "line-end"), ("g g", .motion "first-line"),
    ("G", .motion "last-line"), ("f", .charMotion "find-forward"),
    ("F", .charMotion "find-backward"), ("t", .charMotion "till-forward"),
    ("T", .charMotion "till-backward"), (";", .motion "find-again"),
    (",", .motion "find-again-reverse"), ("n", .motion "search-next"),
    ("N", .motion "search-previous"), ("*", .motion "word-search-forward"),
    ("#", .motion "word-search-backward"), ("/", .promptMotion "search-forward" "/"),
    ("?", .promptMotion "search-backward" "?"), ("%", .motion "matching-bracket")]

/-- The operators. -/
def operators : List (String × Bound) :=
  [("d", .operator { name := "delete" }),
    ("c", .operator { name := "change", enters := some "insert" }),
    ("y", .operator { name := "yank", changes := false }), ("=", .operator { name := "indent" })]

/-- The text objects: each key string, and the object's vocabulary name. -/
def objects : List (String × Bound) :=
  [("i w", .textObject "inner-word"), ("a w", .textObject "a-word"),
    ("i W", .textObject "inner-bigword"), ("a W", .textObject "a-bigword"),
    ("i \"", .textObject "inner-double-quote"), ("a \"", .textObject "a-double-quote"),
    ("i '", .textObject "inner-single-quote"), ("a '", .textObject "a-single-quote"),
    ("i `", .textObject "inner-backquote"), ("a `", .textObject "a-backquote"),
    ("i (", .textObject "inner-paren"), ("i )", .textObject "inner-paren"),
    ("i b", .textObject "inner-paren"), ("a (", .textObject "a-paren"),
    ("a )", .textObject "a-paren"), ("a b", .textObject "a-paren"),
    ("i [", .textObject "inner-bracket"), ("i ]", .textObject "inner-bracket"),
    ("a [", .textObject "a-bracket"), ("a ]", .textObject "a-bracket"),
    ("i {", .textObject "inner-brace"), ("i }", .textObject "inner-brace"),
    ("i B", .textObject "inner-brace"), ("a {", .textObject "a-brace"),
    ("a }", .textObject "a-brace"), ("a B", .textObject "a-brace"),
    ("a f", .textObject "a-function"), ("i f", .textObject "inner-function"),
    ("a c", .textObject "a-class"), ("i c", .textObject "inner-class"),
    ("a a", .textObject "an-argument"), ("i a", .textObject "inner-argument")]

/-- Normal state's commands, and the register prefix. -/
def normalCommands : List (String × Bound) :=
  [("i", inserting "insert"), ("a", inserting "append"), ("I", inserting "insert-line-start"),
    ("A", inserting "append-line-end"), ("o", inserting "open-below"),
    ("O", inserting "open-above"), ("x", changing "delete-char"), ("p", changing "put-after"),
    ("P", changing "put-before"), ("u", running "undo"), ("C-r", running "redo"), (".", .repeat),
    (":", running "ex"), ("v", entering "visual"), ("V", entering "visual-line"), ("\"", .register),
    ("C-g", running "keyboard-quit")]

/-- Insert state's commands: the key that returns to normal state, and the
editing keys. -/
def insertCommands : List (String × Bound) :=
  [("<Escape>", entering "normal"), ("<Backspace>", typing "insert-delete-backward" backspaceTyped),
    ("RET", typing "insert-newline" lineBreakTyped), ("TAB", typing "insert-tab" "\t"),
    ("<ArrowLeft>", restarting "insert-left"), ("<ArrowRight>", restarting "insert-right"),
    ("<ArrowUp>", restarting "insert-up"), ("<ArrowDown>", restarting "insert-down")]

/-- The commands of the character-wise visual state, and the register
prefix. -/
def visualCommands : List (String × Bound) :=
  [("<Escape>", entering "normal"), ("v", entering "normal"), ("V", entering "visual-line"),
    ("\"", .register)]

/-- The commands of the line-wise visual state, and the register prefix. -/
def visualLineCommands : List (String × Bound) :=
  [("<Escape>", entering "normal"), ("V", entering "normal"), ("v", entering "visual"),
    ("\"", .register)]

/-- The commands of the state the minibuffer's view is in: the key that
accepts the prompt, the key that cancels it, the keys that move to the
next and to the previous of its candidates, the key that deletes backward,
the two that move the bar, and the key that deletes to the input's
start. -/
def minibufferCommands : List (String × Bound) :=
  [("RET", running "minibuffer-accept"), ("<Escape>", running "minibuffer-cancel"),
    ("TAB", running "minibuffer-next"), ("C-n", running "minibuffer-next"),
    ("S-TAB", running "minibuffer-previous"), ("C-p", running "minibuffer-previous"),
    ("<Backspace>", running "minibuffer-delete-backward"), ("<ArrowLeft>", .motion "left"),
    ("<ArrowRight>", .motion "right"), ("C-u", running "minibuffer-delete-to-start")]

/-- The commands that scroll a view, of normal state and the visual states:
each changes no text and enters no state. -/
def scrollCommands : List (String × Bound) :=
  [("C-d", running "scroll-down"), ("C-u", running "scroll-up"),
    ("C-f", running "scroll-page-down"), ("C-b", running "scroll-page-up"),
    ("z t", running "scroll-line-to-top"), ("z z", running "scroll-line-to-center"),
    ("z b", running "scroll-line-to-bottom")]

/-- What Select All runs as in normal, insert and the visual states: the
command `select-all`, entering `visual-line`. -/
private def selectAllRun : String × Edit :=
  ("select-all", .run { name := "select-all", enters := some "visual-line" } none none)

/-- Normal state's run table: Paste is `"+P`, and Select All enters
`visual-line`. -/
def normalRuns : List (String × Edit) :=
  [("clipboard-paste", .run { name := "put-before", changes := true } none (some "+")),
    selectAllRun]

/-- Insert state's run table: Select All enters `visual-line`. -/
def insertRuns : List (String × Edit) :=
  [selectAllRun]

/-- The run table of the two visual states: Copy is `"+y`, Cut `"+d`, Paste
the operator `replace` over the selection from `+`, and Select All enters
`visual-line`. -/
def visualRuns : List (String × Edit) :=
  [("clipboard-copy", .operate { name := "yank", changes := false } .selection none (some "+")),
    ("clipboard-cut", .operate { name := "delete" } .selection none (some "+")),
    ("clipboard-paste", .operate { name := "replace" } .selection none (some "+")), selectAllRun]

/-- The keymap that binds each key string of `table` to what is beside it.
A string `Key.parse` refuses binds nothing. -/
def keymap (table : List (String × Bound)) : Keymap Bound :=
  Keymap.ofList
    (table.filterMap fun (text, bound) =>
      match Key.parse text with
      | .ok keys => some (keys, bound)
      | .error _ => none)

/-- The default registry of Vim states (the table in the module docs). -/
def states : States :=
  { initial :=
      { name := "normal"
        keymaps := [normalCommands, scrollCommands, operators, motions].map keymap
        pending := [objects, scrollCommands, operators, motions].map keymap
        runs := normalRuns }
    others :=
      [{  name := "insert"
          keymaps := [keymap insertCommands]
          cursor := .bar
          insertsText := true
          shape := .exclusive
          runs := insertRuns },
        { name := "visual"
          keymaps := [visualCommands, scrollCommands, operators, motions, objects].map keymap
          operatesOnSelection := true
          runs := visualRuns },
        { name := "visual-line"
          keymaps := [visualLineCommands, scrollCommands, operators, motions, objects].map keymap
          operatesOnSelection := true
          shape := .line
          objectEnters := some "visual"
          runs := visualRuns },
        { name := "minibuffer"
          keymaps := [keymap minibufferCommands]
          cursor := .bar
          insertsText := true
          shape := .exclusive }]
    minibuffer := some "minibuffer" }

/-- The role table: each registered role and the key string it is on. -/
def roles : List (Role × String) :=
  [(Role.nextItem, "j"), (Role.previousItem, "k"), (Role.activate, "RET"), (Role.quit, "q"),
    (Role.refresh, "g r"), (Role.toggle, "TAB"), (Role.mark, "m")]

/-- The leader, as a key string: `\`. -/
def leader : String :=
  "\\"

/-- The hand-tuned keys: a mode's name, a key string and what it is bound
to. None: no mode ships. -/
def tuned : List (String × String × Bound) :=
  []

/-- The role table, the leader and the hand-tuned keys as the scheme takes
them, as chords. A string `Key.parse` refuses puts its role on no key, and
binds no tuned key. -/
def modeKeys : ModeKeys :=
  { roles :=
      roles.filterMap fun (role, text) =>
        match Key.parse text with
        | .ok keys => some (role, keys)
        | .error _ => none
    leader := (Key.parse leader).toOption.getD []
    tuned :=
      tuned.filterMap fun (mode, text, bound) =>
        match Key.parse text with
        | .ok keys => some (mode, keys, bound)
        | .error _ => none }

/-- The Vim scheme that ships: the grammar over the default states, with the
default role table and leader. -/
def scheme : InputScheme :=
  Vim.scheme states modeKeys

end Editor.Vim.Default
