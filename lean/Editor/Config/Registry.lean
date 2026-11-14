import Editor.Command.Call
import Editor.Config.Owner
import Editor.InputScheme
import Editor.Mode
import Editor.Setup
import Editor.State

/-!
# The registry, and what a `setup` registers

The registry is the editor's table of commands and of jobs. Each entry has an
*owner* (`Editor/Config/Owner.lean`), and an owner's entries are replaced as
a set, never added to: installing a reloaded config is `replace` for the
owner `config`, so a command the new config no longer registers is gone, and
one it registers again is there once.

A registered command is a value: the `EditorM` program `setup` handed over
(`Editor/Setup.lean`). Running it is running that program against the
editor's port. Nothing looks a command up in an environment.

A registered job is a value too, a `Work`: the job with the handler that
makes the command its result is taken to the editor with. The job entries
are held apart from the command entries, by owner, and replaced as a set the
same way (`replaceJobs`). A job is not a command and is not counted as one.
Registering a job starts nothing: the runtime that owns the job table starts
it (`Editor/Job/Jobs.lean`).

`Registrations` is what one run of a `setup` asks for, collected by a pure
handler of the setup port and then checked. `Registrations.ofSetup` is the
whole of it: the registrations, or the message the `setup` is refused with.
A `setup` is refused when it declares a store name twice, registers a
command name twice or a job name twice, binds a key sequence twice or binds
no keys, or registers a command over a store it does not declare
(`Registrations.problem?`). So one owner's entries have different names, and
the number of commands a config registers is the number of names it can be
run by. Two owners may still register one name: a lookup then finds the
later entry.

## Key bindings

A key binding is a key sequence and a command's name (`KeyBinding`), held by
owner like a command and replaced as a set (`replaceBindings`). The registry
holds no scheme's binding type: `Registry.keymap` makes the keymap for a
scheme by asking the scheme what a key bound to a command name is
(`InputScheme.command`). The entries are bound oldest first, so of two
owners that bind one sequence the later owner's binding is the keymap's, as
`Keymap.ofList` has it. The name is not looked up here: a binding to a name
nobody registered is kept, and the name is looked up when the keys are
typed.

## Modes

A mode (`Editor/Mode.lean`) is held by owner like a command, in a
`ModeEntry`, and replaced as a set (`replaceModes`): the owner is on the
entry, never on the mode, so `setup` cannot choose it. The latest entry of a
name is the one found (`mode?`), so config's mode of a compiled mode's name
is used in its place until a reload drops it.

- **A mode's lineage** (`lineage`) is the mode, then its parent, and so
  on, nearest first, stopping at a name no mode is registered under and at
  a mode already in it, so a cycle ends.
- **The keymaps a mode contributes** for a scheme (`modeKeymaps`) are its
  lineage's, nearest first, each mode's tuned keymap then its roles and
  suffixes (`Mode.keymaps`): a derived mode's own role wins, and a role it
  does not fill falls to the nearest parent that fills it.
- **The active keymaps of a view** (`activeMaps`) are its buffer's minor
  modes', the one added last first, then its major mode's, then the global
  keymap (`keymap`). A name no mode is registered under contributes
  nothing, and a view with no window has the global keymap alone. The host
  makes them for each key, so a reload's modes hold from the next key.

Motions, operators and text objects will be registered the same way, as
vocabulary: entries by owner, replaced as a set, the latest of a name
winning. No table of them is here, since no type for their entries exists
yet.

## Compiled commands

Compiled code is an owner too (`Owner.compiled`). A host registers its
compiled commands with `replace .compiled …` when it starts, before any
config, and nothing replaces them afterwards. `replace` puts an owner's
entries after every other owner's, and `find?` returns the latest entry of a
name, so config's command of a name a compiled command has is the one that
runs while config registers it, and the compiled one runs again once a
reload drops it.

A compiled command may be given what it was called with (`Action.call`,
`Editor/Command/Call.lean`): the window it acts on, the invocation's
arguments and the keys. `setup` registers a plain command, which is told
nothing of its call.
-/

namespace Editor.Config

/-- What a registered command runs. -/
inductive Action where
  /-- A plain command. -/
  | plain (run : EditorM Unit)
  /-- A command over the store called `name`: `step` takes the tree of the
  store's cell to its new tree. -/
  | store (name : String) (step : Value → EditorM Value)
  /-- A command that is given what it was called with: the window it acts
  on, the invocation's arguments and the keys that yielded it. -/
  | call (run : Call → EditorM Unit)

/-- A command as `setup` registers it. -/
structure Registration where
  /-- The command's name. -/
  name : String
  /-- What it runs. -/
  action : Action

/-- An entry of the registry: a registered command and its owner. -/
structure Entry where
  /-- Who registered it. -/
  owner : Owner
  /-- The command. -/
  registration : Registration

/-- A job as `setup` registers it. -/
structure JobRegistration where
  /-- The job's name. -/
  name : String
  /-- The job, with the handler that makes the command its result is taken
  to the editor with. -/
  work : Work

/-- A job entry of the registry: a registered job and its owner. -/
structure JobEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The job. -/
  registration : JobRegistration

/-- A key sequence bound to a command's name. -/
structure KeyBinding where
  /-- The keys, in order, as chords. -/
  keys : List Key
  /-- The name of the command the keys run, looked up when they are
  typed. -/
  command : String
  deriving DecidableEq, Repr

/-- A binding entry of the registry: a key binding and its owner. -/
structure BindingEntry where
  /-- Who bound the keys. -/
  owner : Owner
  /-- The binding. -/
  binding : KeyBinding
  deriving DecidableEq, Repr

/-- A mode entry of the registry: a mode and its owner. -/
structure ModeEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The mode. -/
  mode : Mode

/-- The editor's table of commands, of jobs, of key bindings and of modes,
oldest entry first. -/
structure Registry where
  /-- The command entries. -/
  entries : Array Entry := #[]
  /-- The job entries. A job is not a command: these are apart. -/
  jobs : Array JobEntry := #[]
  /-- The key bindings. -/
  bindings : Array BindingEntry := #[]
  /-- The mode entries. -/
  modes : Array ModeEntry := #[]

namespace Registry

/-- `registry` with every entry of `owner` removed and `registrations` added
as its entries. -/
def replace (registry : Registry) (owner : Owner) (registrations : Array Registration) : Registry :=
  { registry with
    entries :=
      registry.entries.filter (·.owner != owner) ++
        registrations.map fun registration => { owner, registration } }

/-- `registry` with every job entry of `owner` removed and `registrations`
added as its job entries. -/
def replaceJobs (registry : Registry) (owner : Owner) (registrations : Array JobRegistration) :
    Registry :=
  { registry with
    jobs :=
      registry.jobs.filter (·.owner != owner) ++
        registrations.map fun registration => { owner, registration } }

/-- The job entry `name` starts: the latest one of that name. -/
def findJob? (registry : Registry) (name : String) : Option JobEntry :=
  registry.jobs.findRev? (·.registration.name == name)

/-- The entry `name` runs: the latest one of that name. -/
def find? (registry : Registry) (name : String) : Option Entry :=
  registry.entries.findRev? (·.registration.name == name)

/-- The names that run a command, each once, in the order they were first
registered. -/
def names (registry : Registry) : Array String :=
  registry.entries.foldl
    (fun names entry =>
      if names.contains entry.registration.name then names else names.push entry.registration.name)
    #[]

/-- `registry` with every key binding of `owner` removed and `bindings` added
as its bindings. -/
def replaceBindings (registry : Registry) (owner : Owner) (bindings : Array KeyBinding) :
    Registry :=
  { registry with
    bindings :=
      registry.bindings.filter (·.owner != owner) ++
        bindings.map fun binding => { owner, binding } }

/-- The keymap of every owner's bindings for `scheme`: each key sequence
bound to what the scheme says runs the command of its name. The entries are
bound oldest first, so of two owners that bind one sequence the later
owner's is the keymap's. -/
def keymap (registry : Registry) (scheme : InputScheme) : Keymap scheme.Binding :=
  Keymap.ofList
    (registry.bindings.toList.map fun entry =>
      (entry.binding.keys, scheme.command entry.binding.command))

/-- `registry` with every mode entry of `owner` removed and `modes` added as
its mode entries. -/
def replaceModes (registry : Registry) (owner : Owner) (modes : Array Mode) : Registry :=
  { registry with
    modes := registry.modes.filter (·.owner != owner) ++ modes.map fun mode => { owner, mode } }

/-- The mode called `name`: the latest entry of that name. -/
def mode? (registry : Registry) (name : String) : Option Mode :=
  (registry.modes.findRev? (·.mode.name == name)).map (·.mode)

/-- The lineage of the mode called `name`: that mode, then its parent, and
so on, nearest first. It stops at a name no mode is registered under, and
at a mode already in it, so a cycle ends; it has at most as many modes as
the registry has entries. -/
def lineage (registry : Registry) (name : String) : List Mode :=
  go registry.modes.size name []
where
  /-- The lineage from `name`, with `found` the modes already in it, the
  nearest last, and at most `fuel` more. -/
  go : Nat → String → List Mode → List Mode
    | 0, _, found => found.reverse
    | fuel + 1, name, found =>
      match registry.mode? name with
      | none => found.reverse
      | some mode =>
        if found.any (·.name == name) then found.reverse
        else
          match mode.parent with
          | some parent => go fuel parent (mode :: found)
          | none => (mode :: found).reverse

/-- The keymaps the mode called `name` contributes for `scheme`, in
precedence order: for each mode of its lineage, nearest first, its keymaps
(`Mode.keymaps`). None for a name no mode is registered under. -/
def modeKeymaps (registry : Registry) (scheme : InputScheme) (name : String) :
    List (Keymap scheme.Binding) :=
  (registry.lineage name).flatMap (Mode.keymaps scheme)

/-- The active keymaps of `view` in `state` for `scheme`, in precedence
order: the keymaps of each minor mode of the view's buffer, the one added
last first, then its major mode's, then the global keymap of every owner's
key bindings (`keymap`). A view with no window has the global keymap
alone. -/
def activeMaps (registry : Registry) (scheme : InputScheme) (state : EditorState) (view : ViewId) :
    List (Keymap scheme.Binding) :=
  let global := registry.keymap scheme
  match state.target? view with
  | none => [global]
  | some target =>
    let minors := target.buffer.minors.toList.flatMap (registry.modeKeymaps scheme)
    let major := (target.buffer.major.map (registry.modeKeymaps scheme)).getD []
    minors ++ major ++ [global]

end Registry

/-- What one run of a `setup` registers. -/
structure Registrations where
  /-- The commands, in the order they were registered. -/
  commands : Array Registration := #[]
  /-- The stores, in the order they were declared. -/
  stores : Array StoreDeclaration := #[]
  /-- The jobs, in the order they were registered. -/
  jobs : Array JobRegistration := #[]
  /-- The key bindings, in the order they were made, their keys as chords. -/
  bindings : Array KeyBinding := #[]

namespace Registrations

/-- The handler of the setup port that collects: its answer to each request,
and what has been registered after it. -/
def collect : (request : SetupRequest) → Registrations → request.Reply × Registrations
  | .command name run, collected =>
    ((), { collected with commands := collected.commands.push { name, action := .plain run } })
  | .store declaration, collected =>
    ((), { collected with stores := collected.stores.push declaration })
  | .storeCommand name store step, collected =>
    ((),
      { collected with commands := collected.commands.push { name, action := .store store step } })
  | .job name work, collected => ((), { collected with jobs := collected.jobs.push { name, work } })
  | .bind keys command, collected =>
    ((),
      { collected with
        bindings := collected.bindings.push { keys := keys.map Key.chord, command } })

/-- The first of `items` that an earlier one already is, if any. -/
def repeated? {α : Type} [BEq α] (items : Array α) : Option α := do
  for index in [0:items.size] do
    if let some item := items[index]? then
      if (items.extract 0 index).contains item then
        return item
  none

/-- What is wrong with what was collected, if anything: a store declared
twice, a command name or a job name registered twice, a key sequence bound
twice, a binding of no keys, or a command over a store that is not declared.

One config's names are each registered once. A second command under a name
would make the first unreachable, which is a mistake in the config and never
what it meant, so it is refused like a second store of a name; and so is a
second job, and a second binding of one key sequence, to the same command
or to another. A job and a command may share a name: one is run and the
other is spawned. A binding's command is not looked up: it may be compiled,
or not registered at all. -/
def problem? (collected : Registrations) : Option String := do
  let stores := collected.stores.map (·.name)
  if let some name := repeated? stores then
    return s!"the store `{name}` is declared twice"
  if let some name := repeated? (collected.commands.map (·.name)) then
    return s!"the command `{name}` is registered twice"
  if let some name := repeated? (collected.jobs.map (·.name)) then
    return s!"the job `{name}` is registered twice"
  for binding in collected.bindings do
    if binding.keys.isEmpty then
      return boundToNoKeys binding.command
  if let some keys := repeated? (collected.bindings.map (·.keys)) then
    return s!"the keys `{Key.notations keys}` are bound twice"
  for registration in collected.commands do
    if let .store store _ := registration.action then
      unless stores.contains store do
        return s!"the command `{registration.name}` is over the store `{store}`, which is not declared"
  none

/-- What `setup` registers, or the message it is refused with: the one it
threw, or what is wrong with what it registered. A `setup` that is refused
registers nothing. -/
def ofSetup (setup : SetupM Unit) : Except String Registrations :=
  match Program.run (port := setupPort) collect setup.run {} with
  | (.error message, _) => .error message
  | (.ok (), collected) =>
    match collected.problem? with
    | some problem => .error problem
    | none => .ok collected

end Registrations

end Editor.Config
