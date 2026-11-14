import Editor.Command
import Editor.InputScheme
import Editor.Key.Notation
import Editor.Role

/-!
# Modes

A mode is a record: a name, an optional parent, the roles it fills, its
local commands under suffixes, and what runs when it becomes a buffer's
major mode (`Mode`; `docs/design/keymaps-and-modes.md`, "Modes"). It names
no key of a top-level binding and no scheme's binding type, so it works
under any scheme: each scheme says once where the roles and the suffixes go
(`InputScheme.roles`, `InputScheme.leader`), and the mode's keymaps for a
scheme are made from that (`Mode.keymaps`).

## The record

- **Commands are named by `String`**, as everywhere in the registry: a
  role's command and a suffix's are looked up when the key runs.
- **A role is a `Role`** (`Editor/Role.lean`). A mode may name one that is
  not registered, which `Mode.check` reports.
- **A suffix is a key string**, as every binding table is (`bindKey`,
  `Vim.Default`), so one written twice is visible, and suffixes are
  compared as parsed chords (`TAB` and `<Tab>` are one suffix). A string
  that does not parse binds nothing and is reported.
- **No owner.** The owner is on the registry's entry
  (`Config.ModeEntry`), as for commands and key bindings, so `setup`
  cannot choose it.

## A mode's keymaps for a scheme

`Mode.keymaps scheme mode` is two keymaps, in precedence order: the
scheme's hand-tuned keys for the mode (`InputScheme.tuned`, filtered on the
mode's name), then the mode's roles and suffixes, each role at the scheme's
key for it (`InputScheme.roleKey`) and each suffix under the scheme's
leader, bound to what the scheme says a mode's key is bound to
(`InputScheme.modeCommand`). A role the scheme's table lacks, and an
unreadable suffix, bind nothing. So a tuned key wins over a role on the
same keys.

## Where an addition goes

| Addition | Where |
|---|---|
| A new kind of key a mode declares | A field of `Mode`, and its keymap in `Mode.keymaps` |
| A new role | `Editor/Role.lean`; nothing here |

Pinned by `ModelTest.modeRecordChecks`, on the test scheme.
-/

namespace Editor

/-- A mode: what it is called, what it derives from, the roles it fills,
its local commands, and what runs when it becomes a buffer's major mode.
No key of a top-level binding and no scheme's binding type appears in it. -/
structure Mode where
  /-- Its name, by which a buffer holds it and the registry finds it. -/
  name : String
  /-- The name of the mode it derives from, if any: a role or a suffix this
  mode does not fill falls to it. -/
  parent : Option String := none
  /-- The roles it fills: each role, and the name of the command the
  role's key runs. -/
  roles : List (Role × String) := []
  /-- Its local commands: each suffix, as a key string typed after the
  scheme's leader, and the name of the command it runs. -/
  locals : List (String × String) := []
  /-- What runs, given the view, when the mode becomes a buffer's major
  mode. -/
  onEnter : ViewId → EditorM Unit := fun _ => pure ()

namespace Mode

/-- The suffixes that are keys, as chords, each with its command's name, in
order. A string `Key.parse` refuses, or one that names no keys, is left
out. -/
def suffixes (mode : Mode) : List (List Key × String) :=
  mode.locals.filterMap fun (text, command) =>
    match Key.parse text with
    | .ok [] => none
    | .ok keys => some (keys, command)
    | .error _ => none

/-- The hand-tuned keys `scheme` has for the mode called `name`: each key
sequence and its binding, in the scheme's order. -/
def tunedFor (scheme : InputScheme) (name : String) : List (List Key × scheme.Binding) :=
  (scheme.tuned.filter (·.1 == name)).map fun (_, keys, binding) => (keys, binding)

/-- The keymaps of `mode` for `scheme`, in precedence order: the scheme's
hand-tuned keys for the mode, then the mode's roles, each at the scheme's
key for it, and its suffixes, each under the scheme's leader, bound to
`scheme.modeCommand` of the command's name. -/
def keymaps (scheme : InputScheme) (mode : Mode) : List (Keymap scheme.Binding) :=
  let roles :=
    mode.roles.filterMap fun (role, command) =>
      (scheme.roleKey role).map fun keys => (keys, scheme.modeCommand command)
  let suffixes :=
    mode.suffixes.map fun (keys, command) => (scheme.leader ++ keys, scheme.modeCommand command)
  [Keymap.ofList (tunedFor scheme mode.name), Keymap.ofList (roles ++ suffixes)]

end Mode

end Editor
