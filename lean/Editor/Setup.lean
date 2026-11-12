import Editor.Store

/-!
# `setup`: what config registers

Config defines commands, and one action, `setup`, that registers them with
the editor:

```lean
def greet : EditorM Unit := do
  let text ← createText "hello"
  append text ", world"

def setup : SetupM Unit := do
  command "greet" greet
```

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
cannot be meant: a command name registered twice (the first could never
run), a store name declared twice, or a command over a store the `setup`
does not declare. The diagnostic names the command or the store.

A request of this port can carry an `EditorM`, which a request of the
editor's own port could not: the setup port is not the port `EditorM` runs
over, so the type does not refer to itself.

## Adding to the port

A new kind of registration (a key binding, a subscription, an option) is a
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

/-- The type of the reply to each request: nothing, for all of them. -/
def SetupRequest.Reply : SetupRequest → Type
  | .command .. => Unit
  | .store _ => Unit
  | .storeCommand .. => Unit

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

end Editor
