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

- A prefix is one only while something follows its `-`, so `-` is the minus
  key and `C--` is control with it.
- A shifted character is written as itself (`A`, not `S-a`), and `S-` before
  a character is refused: a binding does not name shift on a character
  (`Key.chord`), so it would be dropped without a word.
- A name is letters and digits. It is not looked up: the names are the
  platform's, an open set (`Editor/Event.lean`).

What `Key.parse` gives is in chord form, so it is what `Keymap.bind` stores
and what the walk compares.

`Key.notation` is the inverse of `Key.parse` on chords whose key is one
character or a named key. A dead key and an unidentified one are written
`<Dead>` and `<Unidentified>`, which do not name them back.

## Where an addition goes

| Addition | Where |
|---|---|
| A new modifier | A row of `modifierPrefixes` |
| A short name for a key | A row of `aliases` |
| A new kind of key | Its case in `parseKey` and in `Key.notation` |

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

/-- The keys `text` names, as chords: its strokes, separated by spaces, in
order (the module docs have the notation). The empty string names no
keys. A stroke that is not a key refuses the whole string, with a reason that
names it. -/
def Key.parse (text : String) : Except String (List Key) :=
  ((text.splitOn " ").filter (!·.isEmpty)).mapM Key.parseStroke

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

end Editor
