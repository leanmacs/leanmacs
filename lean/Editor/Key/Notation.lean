import Editor.Keymap

/-!
# Key strings

How keys are written as text, for bindings and for tests: `Key.parse` gives
the keys a string such as `"C-x C-s"` names, and `Key.notation` and
`Key.notations` write a key and a key sequence back, for the pending prefix
a scene shows. `Key.parse` is an ordinary function that runs when it is
called: a string that names no keys is a refusal, a value, and not an
error at elaboration (`docs/design/keymaps-and-modes.md`, the `kbd` macro
under "Open questions").

## The notation

Strokes are separated by spaces. A stroke is modifier prefixes, then a key.

| Written | Is |
|---|---|
| `C-`, `M-`, `s-`, `S-` before a key | Control, alt, super and shift held |
| One character: `x`, `A`, `-`, `<` | The key of that character (`LogicalKey.character`) |
| `<Name>`: `<Escape>`, `<ArrowLeft>` | The named key of that W3C `key` value (`NamedKey`) |
| `RET`, `ESC`, `TAB` | `<Enter>`, `<Escape>`, `<Tab>` |
| `SPC` | The space character, the W3C `key` value of the space bar |
| `<leader>` | The leader in force, expanded by a key binding (`Key.Stroke.leader`) |
| `<localleader>` | The localleader in force, expanded by a key binding (`Key.Stroke.localLeader`) |

- A prefix is one only while something follows its `-`, so `-` is the minus
  key and `C--` is control with it.
- A shifted character is written as itself (`A`, not `S-a`), and `S-` before
  a character is refused: a binding does not name shift on a character
  (`Key.chord`), so it would be dropped without a word.
- A name is letters and digits. It is not looked up: the names are the
  platform's, an open set (`Editor/Event.lean`).

What `Key.parse` gives is in chord form, so it is what `Keymap.bind` stores
and what the walk compares.

## The placeholders

`<leader>` and `<localleader>` stand for the keys the leader and the
localleader are on (`docs/design/keymaps-and-modes.md`, "Key strings").
They are lowercase and exact, and read before a name is tried, so
`<Leader>` is still the named key `Leader`. A modifier prefix on one
(`C-<leader>`) is refused, naming the stroke and what the placeholder
stands for: the leader, or the localleader.

A key string is read in two steps. `Key.parseStrokes` reads it as strokes
(`Key.Stroke`): a key, as a chord, or a placeholder. `Key.expand` puts the
leaders' keys (`Key.Leaders`) in place of the placeholders. A keymap only
ever holds what that gives, so `Key`, the walk and the keymaps know of no
placeholder. `Key.parse text (some leaders)` is the two together. Read with
no leaders, the default every caller but a key binding takes, a string
with a placeholder is refused: only a binding expands one, against the
leaders in force when the registry makes its keymaps
(`Editor/Config/Registry.lean`). `Key.strokeNotations` writes strokes back,
for refusal messages.

`Key.notation` is the inverse of `Key.parse` on chords whose key is one
character or a named key. A dead key and an unidentified one are written
`<Dead>` and `<Unidentified>`, which do not name them back.

## Where an addition goes

| Addition | Where |
|---|---|
| A new modifier | A row of `modifierPrefixes` |
| A short name for a key | A row of `aliases` |
| A new kind of key | Its case in `parseKey` and in `Key.notation` |
| A new placeholder, a stroke a binding expands | A variant of `Key.Stroke`, a row of `placeholders` (its written form, its stroke and the name messages give it), its keys in `Key.Leaders` and its case in `Key.expand` and `Key.Stroke.notation` |

Each is pinned by `ModelTest.keyNotationChecks`.
-/

namespace Editor

/-- The modifier prefixes, in the order `Key.notation` writes them: the
letter before the `-`, whether a key holds the modifier, and the modifiers
with it held too. -/
private def Key.modifierPrefixes : List (Char × (Modifiers → Bool) × (Modifiers → Modifiers)) :=
  [('C', (·.control), ({ · with control := true })), ('M', (·.alt), ({ · with alt := true })),
    ('s', (·.superKey), ({ · with superKey := true })),
    ('S', (·.shift), ({ · with shift := true }))]

/-- The short names of keys. -/
private def Key.aliases : List (String × LogicalKey) :=
  [("RET", .named .enter), ("ESC", .named .escape), ("TAB", .named .tab), ("SPC", .character " ")]

/-- The modifier prefixes at the start of a stroke, taken while something
follows the `-`, and the rest of the stroke. -/
private def Key.splitModifiers (modifiers : Modifiers) : List Char → Modifiers × List Char
  | letter :: '-' :: next :: rest =>
    match Key.modifierPrefixes.find? (·.1 == letter) with
    | some (_, _, hold) => Key.splitModifiers (hold modifiers) (next :: rest)
    | none => (modifiers, letter :: '-' :: next :: rest)
  | stroke => (modifiers, stroke)

/-- The key a stroke names once its modifier prefixes are taken, if it names
one. -/
private def Key.parseKey (text : String) : Option LogicalKey :=
  match Key.aliases.lookup text, text.toList with
  | some key, _ => some key
  | none, [_] => some (.character text)
  | none, '<' :: rest =>
    match rest.reverse with
    | '>' :: name =>
      if !name.isEmpty && name.all Char.isAlphanum then some (.named ⟨String.ofList name.reverse⟩)
      else none
    | _ => none
  | none, _ => none

/-- The key the stroke `stroke` names, or why it names none. -/
private def Key.parseStroke (stroke : String) : Except String Key :=
  let (modifiers, rest) := Key.splitModifiers {} stroke.toList
  match Key.parseKey (String.ofList rest) with
  | none =>
    .error
      s!"`{stroke}` is not a key: write modifier prefixes (C-, M-, s-, S-), then one character, a name in angle brackets such as <Escape>, or RET, ESC, TAB or SPC"
  | some (.character text) =>
    if modifiers.shift then
      .error s!"`{stroke}` puts shift on a character: write the shifted character instead"
    else .ok { logical := .character text, modifiers }
  | some logical => .ok { logical, modifiers }

/-- A stroke of a key string as it is written, before the leaders are put in
place: a key, as a chord, or the placeholder of the leader or of the
localleader (`<leader>`, `<localleader>`). A keymap never holds one: it
holds what `Key.expand` gives. -/
inductive Key.Stroke where
  /-- This key, as a chord. -/
  | key (key : Key)
  /-- The leader in force: `<leader>`. -/
  | leader
  /-- The localleader in force: `<localleader>`. -/
  | localLeader
  deriving DecidableEq, Repr

/-- The leaders a key string's placeholders are expanded against, as
chords: the leader, and the localleader with any leader in it already put
in place. -/
structure Key.Leaders where
  /-- The keys `<leader>` stands for. -/
  leader : List Key := []
  /-- The keys `<localleader>` stands for. -/
  localLeader : List Key := []
  deriving DecidableEq, Repr

/-- The placeholders, as they are written (lowercase and exact), each with
the stroke it is read as and the name of what it stands for, as messages
name it. -/
private def Key.placeholders : List (String × Key.Stroke × String) :=
  [("<leader>", .leader, "leader"), ("<localleader>", .localLeader, "localleader")]

/-- The stroke `stroke` is read as, or why it is none: a placeholder, which
takes no modifier prefix, or a key. -/
private def Key.readStroke (stroke : String) : Except String Key.Stroke :=
  match Key.placeholders.lookup stroke with
  | some (placeholder, _) => .ok placeholder
  | none =>
    let (_, rest) := Key.splitModifiers {} stroke.toList
    match Key.placeholders.lookup (String.ofList rest) with
    | some (_, named) =>
      .error
        s!"`{stroke}` puts a modifier prefix on `{String.ofList rest}`, which names the keys the {named} is on and takes none"
    | none => Key.parseStroke stroke |>.map .key

/-- The strokes `text` is written as: its strokes, separated by spaces, in
order, each a key or a placeholder (the module docs have the notation).
The empty string is no strokes. A stroke that is neither, or a placeholder
with a modifier prefix, refuses the whole string, with a reason that names
it. -/
def Key.parseStrokes (text : String) : Except String (List Key.Stroke) :=
  ((text.splitOn " ").filter (!·.isEmpty)).mapM Key.readStroke

/-- The keys `strokes` name with `leaders` in place of the placeholders, in
order. -/
def Key.expand (leaders : Key.Leaders) (strokes : List Key.Stroke) : List Key :=
  strokes.flatMap fun
    | .key chord => [chord]
    | .leader => leaders.leader
    | .localLeader => leaders.localLeader

/-- `strokes` with no placeholder, as the keys they are; `none` when one of
them is a placeholder. -/
def Key.Stroke.keys? (strokes : List Key.Stroke) : Option (List Key) :=
  strokes.mapM fun
    | .key chord => some chord
    | _ => none

/-- The keys `text` names, as chords: its strokes, separated by spaces, in
order (the module docs have the notation), with `leaders` in place of the
placeholders. The empty string names no keys. A stroke that is not a key
refuses the whole string, with a reason that names it, and so does a
placeholder read with no leaders (`leaders := none`, as every caller but a
key binding reads a key string): only a binding expands one. -/
def Key.parse (text : String) (leaders : Option Key.Leaders := none) : Except String (List Key) :=
  do
  let strokes ← Key.parseStrokes text
  match leaders with
  | some leaders =>
    pure (Key.expand leaders strokes)
  | none =>
    match Key.placeholders.find? fun (_, placeholder, _) => strokes.contains placeholder with
    | some (written, _, named) =>
      throw s!"`{written}` names the {named}, which only a key binding expands (`bindKey`)"
    | none =>
      pure (Key.expand {} strokes)

/-- `key` as a key string names it: its modifier prefixes, in the order
`C-`, `M-`, `s-`, `S-`, then the character, with the space character as
`SPC`, or the name in angle brackets. `Key.parse` reads it back when `key`
is a chord of one character or of a named key. -/
def Key.notation (key : Key) : String :=
  let held :=
    Key.modifierPrefixes.filterMap fun (letter, isHeld, _) =>
      if isHeld key.modifiers then some s!"{letter}-" else none
  let name :=
    match key.logical with
    | .character " " => "SPC"
    | .character text => text
    | .named named => s!"<{named.name}>"
    | .dead _ => "<Dead>"
    | .unidentified => "<Unidentified>"
  String.join held ++ name

/-- `keys` as a key string names them: each key's notation, separated by
spaces. -/
def Key.notations (keys : List Key) : String :=
  " ".intercalate (keys.map Key.notation)

/-- `stroke` as a key string writes it: a key's notation, or the
placeholder as `<leader>` or `<localleader>`. -/
def Key.Stroke.notation : Key.Stroke → String
  | .key chord => Key.notation chord
  | .leader => "<leader>"
  | .localLeader => "<localleader>"

/-- `strokes` as a key string writes them: each stroke's notation,
separated by spaces. `Key.parseStrokes` reads it back. -/
def Key.strokeNotations (strokes : List Key.Stroke) : String :=
  " ".intercalate (strokes.map Key.Stroke.notation)

end Editor
