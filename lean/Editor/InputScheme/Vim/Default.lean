import Editor.InputScheme.Vim
import Editor.Key.Notation

/-!
# The Vim scheme's default states and bindings

The Vim scheme that ships: the four Vim states and what their keymaps bind,
as data, and the scheme over them (`scheme`). The grammar is
`Editor/InputScheme/Vim.lean`, which knows none of these keys
(`docs/design/keymaps-and-modes.md`, "Default bindings").

## The tables

Each table is rows of a key string (`Editor/Key/Notation.lean`) and what it
is bound to. The names in them are the vocabulary names and command names
that the motions, operators and commands are registered under: a name is
changed in its row and in its registration together. Nothing here says what
a name does.

| Table | Binds |
|---|---|
| `motions` | The motions of normal state and the visual states |
| `operators` | The operators. `c` names the state `insert`, and `y` changes no text |
| `normalCommands` | Normal state's commands: those that begin an insert, those that change text, undo, redo, repeat and the command line, the two that enter a visual state, and the register prefix |
| `insertCommands` | Insert state's: the key that returns to normal state |
| `visualCommands`, `visualLineCommands` | A visual state's: the keys that return to normal state, the key that enters the other visual state, and the register prefix |

## The states

| State | Keymaps, in precedence order | Cursor | The grammar reads |
|---|---|---|---|
| `normal`, the initial state | `normalCommands`, `operators`, `motions` | Block | |
| `insert` | `insertCommands` | Bar | Typing is text |
| `visual` | `visualCommands`, `operators`, `motions` | Block | Operators act on the selection |
| `visual-line` | `visualLineCommands`, `operators`, `motions` | Block | Operators act on the selection |

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
| A new role | A row of `roles` |
| A new default Vim state | A record in `states`, with a table of its own for the keys that leave it |
| What a name in a table does | The vocabulary or the command registry, under that name; nothing here |

Pinned by `ModelTest.vimDefaultChecks`, which observe the defaults through
the grammar and restate no table, and the scheme contract is run on
`scheme` in `ModelTest.vimContractChecks`.
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

/-- The motions: each key string, and the motion's vocabulary name. -/
def motions : List (String × Bound) :=
  [("h", .motion "left"), ("j", .motion "down"), ("k", .motion "up"), ("l", .motion "right"),
    ("w", .motion "word-forward"), ("b", .motion "word-backward"), ("e", .motion "word-end"),
    ("W", .motion "bigword-forward"), ("B", .motion "bigword-backward"),
    ("E", .motion "bigword-end"), ("0", .motion "line-start"),
    ("^", .motion "line-first-non-blank"), ("$", .motion "line-end"), ("g g", .motion "first-line"),
    ("G", .motion "last-line")]

/-- The operators. -/
def operators : List (String × Bound) :=
  [("d", .operator { name := "delete" }),
    ("c", .operator { name := "change", enters := some "insert" }),
    ("y", .operator { name := "yank", changes := false })]

/-- Normal state's commands, and the register prefix. -/
def normalCommands : List (String × Bound) :=
  [("i", inserting "insert"), ("a", inserting "append"), ("I", inserting "insert-line-start"),
    ("A", inserting "append-line-end"), ("o", inserting "open-below"),
    ("O", inserting "open-above"), ("x", changing "delete-char"), ("p", changing "put-after"),
    ("P", changing "put-before"), ("u", running "undo"), ("C-r", running "redo"),
    (".", running "repeat"), (":", running "ex"), ("v", entering "visual"),
    ("V", entering "visual-line"), ("\"", .register)]

/-- Insert state's commands. -/
def insertCommands : List (String × Bound) :=
  [("<Escape>", entering "normal")]

/-- The commands of the character-wise visual state, and the register
prefix. -/
def visualCommands : List (String × Bound) :=
  [("<Escape>", entering "normal"), ("v", entering "normal"), ("V", entering "visual-line"),
    ("\"", .register)]

/-- The commands of the line-wise visual state, and the register prefix. -/
def visualLineCommands : List (String × Bound) :=
  [("<Escape>", entering "normal"), ("V", entering "normal"), ("v", entering "visual"),
    ("\"", .register)]

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
  { initial := { name := "normal", keymaps := [normalCommands, operators, motions].map keymap }
    others :=
      [{  name := "insert"
          keymaps := [keymap insertCommands]
          cursor := .bar
          insertsText := true },
        { name := "visual"
          keymaps := [visualCommands, operators, motions].map keymap
          operatesOnSelection := true },
        { name := "visual-line"
          keymaps := [visualLineCommands, operators, motions].map keymap
          operatesOnSelection := true }] }

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
