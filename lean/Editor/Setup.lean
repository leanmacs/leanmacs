import Editor.Job
import Editor.Key.Notation
import Editor.Store

/-!
# `setup`: what config registers

Config defines commands and jobs, and one action, `setup`, that registers
them with the editor:

```lean
def greet : EditorM Unit := do
  let text ← createText "hello"
  append text ", world"

def count : Unit → JobM Nat := fun _ => do
  sleep 10
  return 42

def setup : SetupM Unit := do
  command "greet" greet
  bindKey "C-c g" "greet"
  job "count" count fun n => discard <| createText s!"counted {n}"
```

A job is registered with the handler that makes the command its result is
taken to the editor with. `setup` starts nothing: it is a collected program,
and nothing of a config exists until it is installed. A job is not a
command, and is not counted as one.

A key sequence is bound to a command's name (`bindKey`), written as a key
string (`Editor/Key/Notation.lean`). The name is looked up when the keys
are typed, so a binding may name a compiled command, or a command that is
not registered, which then says so in the echo area. A binding is not a
command and is not counted as one. It is called `bindKey` and not `bind`,
which would shadow the monad's inside `namespace Editor` and for config,
which opens it.

`setup` is a program over a port of its own, the *setup port*, whose requests
carry what is registered. It is plain data like any program
(`Editor/Program.lean`): it holds no `IO` and changes nothing by itself. After
a config has elaborated, the editor runs its `setup` against a handler that
collects the requests into a value (`Editor/Config/Registry.lean`), on the
thread that elaborated it, and the editor thread installs that value later.
So a reload is all-or-nothing by construction: nothing is registered until
the whole of `setup` has run and what it collected has been checked.

`setup` may refuse: a `throw` with a message ends it, the reload is rejected
with that message, and the config that was loaded before stays.

The editor refuses a `setup` too, the same way, when what it registered
cannot be meant: a command name or a job name registered twice (the first
could never run), a key sequence bound twice (the first binding could never
run), a store name declared twice, or a command over a store the `setup`
does not declare. The diagnostic names the command, the job, the keys or
the store. `bindKey` itself refuses a key string that is not keys, with the
key parser's reason, and one that names no keys.

A request of this port can carry an `EditorM`, which a request of the
editor's own port could not: the setup port is not the port `EditorM` runs
over, so the type does not refer to itself. A job's handler is carried the
same way, inside the job: a `Work` finishes with an `EditorM Unit`, so the
type of a job's result never reaches the registry.

## Adding to the port

A new kind of registration (a subscription, an option) is a
constructor of `SetupRequest` with its case in `SetupRequest.Reply`, and an
operation here that makes the request. It then needs a clause in the
collecting handler (`Config.Registrations.collect`), which is where it
becomes part of what a reload installs, and a check in `ModelTest.setupChecks`,
which is what pins it. Grow the port with requests, not with new ways to run
`setup`.
-/

namespace Editor

/-- What `setup` may ask of the editor: each request registers one thing. -/
inductive SetupRequest where
  /-- Register `run` as the command called `name`. -/
  | command (name : String) (run : EditorM Unit)
  /-- Declare a store: a cell whose value survives a reload
  (`Editor/Store.lean`). -/
  | store (declaration : StoreDeclaration)
  /-- Register the command called `name` over the store called `store`:
  `step` takes the cell's tree to its new tree. -/
  | storeCommand (name : String) (store : String) (step : Value → EditorM Value)
  /-- Register `work` as the job called `name`: a job that finishes with the
  command that takes its result to the editor (`Editor/Job.lean`). -/
  | job (name : String) (work : Work)
  /-- Bind the key sequence `keys` to the command called `command`. The
  name is looked up when the keys are typed. -/
  | bind (keys : List Key) (command : String)

/-- The type of the reply to each request: nothing, for all of them. -/
def SetupRequest.Reply : SetupRequest → Type
  | .command .. => Unit
  | .store _ => Unit
  | .storeCommand .. => Unit
  | .job .. => Unit
  | .bind .. => Unit

/-- The setup port: `SetupRequest` and the reply to each request. -/
abbrev setupPort : Port :=
  { Request := SetupRequest, Reply := SetupRequest.Reply }

/-- The type of `setup`: a program over the setup port that may refuse with a
message. -/
abbrev SetupM :=
  ExceptT String (Program setupPort)

/-- Registers `run` as the command called `name`. -/
def command (name : String) (run : EditorM Unit) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.command name run))

/-- Declares `store`: the editor keeps a cell of that name for it, whose value
survives a reload. -/
def Store.declare {α : Type} (store : Store α) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.store store.declaration))

/-- Registers the command called `name` over `store`: `run` takes the store's
value to its new value. The store must be declared in the same `setup`. -/
def Store.command {α : Type} (store : Store α) (name : String) (run : α → EditorM α) :
    SetupM Unit :=
  ExceptT.lift
    (Program.request (port := setupPort) (.storeCommand name store.name (store.step run)))

/-- Registers `run` as the job called `name`, and `handler` as what makes the
command that receives its result. Registering starts nothing: the editor
starts the job when it is asked to, on a pool thread, and runs the command
the handler makes on the editor thread when the job has finished.

`run` is a function, so that none of the job runs before its task exists. -/
def job {α : Type} (name : String) (run : Unit → JobM α) (handler : α → EditorM Unit) :
    SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.job name (Work.of run handler)))

/-- The message a binding of no keys to the command called `command` is
refused with. -/
def boundToNoKeys (command : String) : String :=
  s!"the command `{command}` is bound to no keys"

/-- Binds the key sequence the key string `keys` names (`Key.parse`:
`"C-x C-s"`) to the command called `command`. The name is looked up when
the keys are typed, so the command need not be one this `setup` registers.

Refuses the `setup` for a key string that is not keys, with the key
parser's reason, which names the stroke, and for one that names no keys. -/
def bindKey (keys : String) (command : String) : SetupM Unit := do
  match Key.parse keys with
  | .error reason =>
    throw reason
  | .ok [] =>
    throw (boundToNoKeys command)
  | .ok chords =>
    ExceptT.lift (Program.request (port := setupPort) (.bind chords command))

end Editor
