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
- **`onEnter` runs when the mode becomes a buffer's major mode**, with the
  view it was set through, once (`Config.Registry.setMajorMode`, which
  refuses with a `ModeRefusal`). It is a plain `EditorM` program, and
  cannot write a store.

## A mode's keymaps for a scheme

`Mode.keymaps scheme mode` is two keymaps, in precedence order: the
scheme's hand-tuned keys for the mode (`InputScheme.tuned`, filtered on the
mode's name), then the mode's roles and suffixes, each role at the scheme's
key for it (`InputScheme.roleKey`) and each suffix under the scheme's
leader, bound to what the scheme says a mode's key is bound to
(`InputScheme.modeCommand`). A role the scheme's table lacks, and an
unreadable suffix, bind nothing. So a tuned key wins over a role on the
same keys.

## What a mode cannot mean

`Mode.problems` is what is wrong with a mode under any scheme: a role that
is not registered, a suffix used twice (reported once), and a suffix that is
not keys or names none. `Mode.check mode scheme` adds what needs a scheme: a
hand-tuned key the scheme has for the mode that the scheme's own keymaps
(`InputScheme.defaults`) bind exactly, which it shadows. A tuned key that is
a strict prefix of one of theirs is not reported (the open question
"Unreachable bindings"). `Mode.Problem.describe` says each as a sentence.

## Where an addition goes

| Addition | Where |
|---|---|
| A new kind of key a mode declares | A field of `Mode`, and its keymap in `Mode.keymaps` |
| A new role | `Editor/Role.lean`; nothing here |
| A new mistake a mode can make | A variant of `Mode.Problem`, its sentence in `describe`, and its case in `problems` (or in `check`, when it needs a scheme) |

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

/-- What a mode cannot mean. -/
inductive Problem where
  /-- It fills a role the core does not register. -/
  | unregisteredRole (role : Role)
  /-- It uses this suffix, as chords, more than once. -/
  | duplicateSuffix (keys : List Key)
  /-- This suffix is not keys: `Key.parse` refuses it, or it names none. -/
  | unreadableSuffix (text : String)
  /-- The scheme tunes this key sequence for the mode by hand, and its own
  keymaps bind exactly that sequence. -/
  | shadowsScheme (keys : List Key)
  deriving DecidableEq, Repr

/-- The problem, as a sentence that names what is wrong. -/
def Problem.describe : Problem → String
  | .unregisteredRole role => s!"the role `{role.name}` is not registered"
  | .duplicateSuffix keys => s!"the suffix `{Key.notations keys}` is used twice"
  | .unreadableSuffix text => s!"the suffix `{text}` is not keys"
  | .shadowsScheme keys =>
    s!"the hand-tuned key `{Key.notations keys}` shadows a binding of the scheme"

/-- What `mode` cannot mean under any scheme: the roles it fills that are not
registered, then the suffixes it uses more than once, each once, compared
as chords, then the suffixes that are not keys, each in order. -/
def problems (mode : Mode) : List Problem :=
  let unregistered :=
    (mode.roles.filter fun (role, _) => !Role.registered.contains role).map fun (role, _) =>
      Problem.unregisteredRole role
  let suffixes := mode.suffixes.map (·.1)
  let duplicates :=
    (suffixes.eraseDups.filter fun keys => suffixes.count keys > 1).map Problem.duplicateSuffix
  let unreadable :=
    (mode.locals.filter fun (text, _) =>
          match Key.parse text with
          | .ok [] | .error _ => true
          | .ok _ => false).map
      fun (text, _) => Problem.unreadableSuffix text
  unregistered ++ duplicates ++ unreadable

/-- What `mode` cannot mean under `scheme`: its `problems`, then each
hand-tuned key the scheme has for it that the scheme's own keymaps
(`InputScheme.defaults`) bind exactly. A tuned key that is a strict prefix
of one of theirs is not reported. -/
def check (mode : Mode) (scheme : InputScheme) : List Problem :=
  mode.problems ++
    (tunedFor scheme mode.name).filterMap fun (keys, _) =>
      match Keymap.resolve scheme.defaults keys with
      | .bound _ => some (.shadowsScheme keys)
      | _ => none

end Mode

/-- Why setting a mode was refused. -/
inductive ModeRefusal where
  /-- The state has no window of this view. -/
  | noSuchWindow (id : ViewId)
  /-- No mode is registered under this name. -/
  | noSuchMode (name : String)
  deriving DecidableEq, Repr

end Editor
