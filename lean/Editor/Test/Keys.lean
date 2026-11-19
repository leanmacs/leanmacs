import Editor.Event
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Key.Notation
import Editor.Keymap
import Editor.Role
import Editor.Scene

/-!
# The test kit: Keys

Keys and key maps for fixtures: the keys a key string names, an invocation by
name, and maps of a scheme written by hand. Shared by several test modules under
`ModelTest/Editor/`; it holds no checks of its own.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import"). The core's own model tests are written on it.
-/

namespace Editor.Test

open Editor

/-- The keys the key string `text` names, for a fixture; none when it is
refused, which `schemeChecks` checks of no fixture string. -/
def keys (text : String) : List Key :=
  match Key.parse text with
  | .ok named => named
  | .error _ => []

/-- The strokes the key string `text` is written as, placeholders in place,
for a fixture; none when it is refused. -/
def strokes (text : String) : List Key.Stroke :=
  match Key.parseStrokes text with
  | .ok read => read
  | .error _ => []

/-- The invocation of the command `name` with no arguments. -/
def invoke (name : String) : Invocation :=
  { command := name }

/-- The key of the character `text`, with `modifiers` held, as a binding
names it. -/
def charKey (text : String) (modifiers : Modifiers := {}) : Key :=
  { logical := .character text, modifiers }

/-- The named key `key`, with `modifiers` held, as a binding names it. -/
def namedKey (key : NamedKey) (modifiers : Modifiers := {}) : Key :=
  { logical := .named key, modifiers }

/-- The character `text` with control held: `C-x` for `"x"`. -/
def controlKey (text : String) : Key :=
  charKey text { control := true }

/-- A keymap for the scheme checks: sequences of two keys and of three, and
one of one key. -/
def globalMap : Keymap Invocation :=
  Keymap.ofList
    [(keys "C-x C-s", invoke "save"), (keys "C-x C-f", invoke "find-file"),
      (keys "C-x r t", invoke "string-rectangle"), (keys "C-q", invoke "quit")]

/-- A keymap that binds one of `globalMap`'s sequences to another command. -/
def localMap : Keymap Invocation :=
  Keymap.ofList [(keys "C-x C-s", invoke "save-as")]

/-- The keymaps of the scheme checks' views: `localMap` before `globalMap`
for view 1, `globalMap` alone for every other. -/
def schemeMaps (view : ViewId) : List (Keymap Invocation) :=
  if view.index == 1 then [localMap, globalMap] else [globalMap]

/-- A press of `key` with no text, as a window reports one. -/
def press (key : Key) : Event :=
  .key key true ""

/-- A press of each key the key string `text` names, in order. -/
def presses (text : String) : List Event :=
  (keys text).map press

/-- A scheme written for the test that breaks the contract: the test scheme,
with a role table that lacks the role `mark`. -/
def roleless : InputScheme :=
  { TestScheme.scheme with roles := TestScheme.roles.filter (·.1 != Role.mark) }

/-- The keys `role` is on under the test scheme; none when it has no row. -/
def roleKeys (role : Role) : List Key :=
  (TestScheme.scheme.roleKey role).getD []

end Editor.Test
