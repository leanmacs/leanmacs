import Editor.Setup

/-!
# The registry, and what a `setup` registers

The registry is the editor's table of commands. Each entry has an *owner*,
and an owner's entries are replaced as a set, never added to: installing a
reloaded config is `replace` for the owner `config`, so a command the new
config no longer registers is gone, and one it registers again is there
once.

A registered command is a value: the `EditorM` program `setup` handed over
(`Editor/Setup.lean`). Running it is running that program against the
editor's port. Nothing looks a command up in an environment.

`Registrations` is what one run of a `setup` asks for, collected by a pure
handler of the setup port and then checked. `Registrations.ofSetup` is the
whole of it: the registrations, or the message the `setup` is refused with.

Dispatch by key, command names in keymaps and overriding a compiled command
are for the command loop to build on this table.
-/

namespace Editor.Config

/-- Who registered something. What an owner registered is replaced as a set. -/
structure Owner where
  /-- The owner's name. -/
  name : String
  deriving DecidableEq, Repr

/-- The owner of everything the user's config registers. -/
def Owner.config : Owner :=
  { name := "config" }

/-- What a registered command runs. -/
inductive Action where
  /-- A plain command. -/
  | plain (run : EditorM Unit)
  /-- A command over the store called `name`: `step` takes the tree of the
  store's cell to its new tree. -/
  | store (name : String) (step : Value → EditorM Value)

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

/-- The editor's table of commands, oldest entry first. -/
structure Registry where
  /-- The entries. -/
  entries : Array Entry := #[]

namespace Registry

/-- `registry` with every entry of `owner` removed and `registrations` added
as its entries. -/
def replace (registry : Registry) (owner : Owner) (registrations : Array Registration) : Registry :=
  {
    entries :=
      registry.entries.filter (·.owner != owner) ++
        registrations.map fun registration => { owner, registration } }

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

end Registry

/-- What one run of a `setup` registers. -/
structure Registrations where
  /-- The commands, in the order they were registered. -/
  commands : Array Registration := #[]
  /-- The stores, in the order they were declared. -/
  stores : Array StoreDeclaration := #[]

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

/-- What is wrong with what was collected, if anything: a store declared
twice, or a command over a store that is not declared. -/
def problem? (collected : Registrations) : Option String := do
  let names := collected.stores.map (·.name)
  for index in [0:names.size] do
    if let some name := names[index]? then
      if (names.extract 0 index).contains name then
        return s!"the store `{name}` is declared twice"
  for registration in collected.commands do
    if let .store store _ := registration.action then
      unless names.contains store do
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
