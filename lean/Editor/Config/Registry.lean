import Editor.Command.Call
import Editor.Config.Owner
import Editor.Setup

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
command name twice or a job name twice, or registers a command over a store
it does not declare (`Registrations.problem?`). So one owner's entries have
different names, and the number of commands a config registers is the number
of names it can be run by. Two owners may still register one name: a lookup
then finds the later entry.

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

/-- The editor's table of commands and of jobs, oldest entry first. -/
structure Registry where
  /-- The command entries. -/
  entries : Array Entry := #[]
  /-- The job entries. A job is not a command: these are apart. -/
  jobs : Array JobEntry := #[]

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

end Registry

/-- What one run of a `setup` registers. -/
structure Registrations where
  /-- The commands, in the order they were registered. -/
  commands : Array Registration := #[]
  /-- The stores, in the order they were declared. -/
  stores : Array StoreDeclaration := #[]
  /-- The jobs, in the order they were registered. -/
  jobs : Array JobRegistration := #[]

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

/-- The first of `names` that an earlier one already is, if any. -/
def repeated? (names : Array String) : Option String := do
  for index in [0:names.size] do
    if let some name := names[index]? then
      if (names.extract 0 index).contains name then
        return name
  none

/-- What is wrong with what was collected, if anything: a store declared
twice, a command name or a job name registered twice, or a command over a
store that is not declared.

One config's names are each registered once. A second command under a name
would make the first unreachable, which is a mistake in the config and never
what it meant, so it is refused like a second store of a name; and so is a
second job. A job and a command may share a name: one is run and the other
is spawned. -/
def problem? (collected : Registrations) : Option String := do
  let stores := collected.stores.map (·.name)
  if let some name := repeated? stores then
    return s!"the store `{name}` is declared twice"
  if let some name := repeated? (collected.commands.map (·.name)) then
    return s!"the command `{name}` is registered twice"
  if let some name := repeated? (collected.jobs.map (·.name)) then
    return s!"the job `{name}` is registered twice"
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
