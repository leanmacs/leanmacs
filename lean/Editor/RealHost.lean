/-!
# Real hosts and real services, marked

A check runs a real editor loop thread or a real background service only in
a module of the wiring set (`AGENTS.md`, "Deterministic concurrency in
tests"; `docs/dev-practices/real-thread-checks.md`). What starts one is a
constant with a mark beside it: a declaration named after the constant with
`realHost` added, of the type `RealHost`, its value the kind of what it
runs, written in the constant's own module before the constant.

```
/-- `Headless.withHost` runs a real loop thread (`Editor/RealHost.lean`). -/
def withHost.realHost : RealHost :=
  .loop
```

A module of the wiring set says so with a declaration named after the
module under `wiringSet`, of the type `WiringSet`: the real adapter its
checks cover and why a fake or the stepped host cannot stand in.

```
def wiringSet.ConfigTest.Editor.Job.Real : Editor.WiringSet :=
  .wiring "the library's diff and grep services" "AC4's end-to-end check of each"
```

The real-host linter (`linter.realHost`, `lean/Lint/RealHost.lean`) reads
the mark of each constant a command references, and refuses one in a test
module that declares no wiring set, outside a declaration that has a mark
itself. Both are plain data, so this module imports nothing and the config
base and the model tests stay plain Lean (`docs/design/overview.md`,
"Config is elaborated behind a port, and two adapters link Lean's
frontend"): the linter is a Lean plugin the build loads, never a module the
editor imports (`lean/lakefile.lean`, `lintPlugin`).

Its checks are the linter's fixtures (`ModelTest/Lint/RealHost.lean` and the
modules under `ModelTest/Lint/RealHost/`, `ConfigTest/Lint/RealHost.lean`,
the fixture package `greeting`'s `GreetingTest/Linked/Lint/RealHost.lean`).
-/

namespace Editor

/-- What a marked entry point runs. -/
inductive RealHost where
  /-- A real editor loop thread: a host's bracket over the library's queue,
  the headless CLI's runner, or the window mode's host. It may reach real
  services too. -/
  | loop
  /-- A real background service, and no loop thread: the completion pump,
  or the library's timer, file, process, watch, diff, grep or syntax
  service, or the session journal over them. -/
  | service

/-- Why a module may reach marked entry points. -/
inductive WiringSet where
  /-- Its checks wire a real adapter: `adapter` is the adapter they cover,
  and `why` says why a fake or the stepped host cannot. -/
  | wiring (adapter why : String)
  /-- It runs a port's contract against its real adapter. That is outside
  the rule, so it may reach a `service` and never a `loop`. -/
  | contract (port : String)
  /-- An executable's root: only its `main` wires real adapters, for `why`. -/
  | edge (why : String)

/-- A group of a test root's checks, over the root's context `κ` and its
check type `α`: what the root's check set (`checks : List (CheckGroup κ α)`)
is made of, and how the stress loop and the gate select the wiring set from
code (`docs/dev-practices/real-thread-checks.md`, "How stress runs the
set"). The lists of a module of the wiring set sit in `wired` groups,
tagged with that module's name and its declaration; every other list sits
in a `plain` group. The build's `linter.wiringSet` (`lean/Lint/Wiring.lean`)
holds the tags true and complete. Plain data, so this module still imports
nothing. -/
inductive CheckGroup (κ α : Type) where
  /-- Checks of modules outside the wiring set. -/
  | plain (checks : κ → List α)
  /-- Checks of the module `module`, which declares `set`
  (`wiringSet.<module>`). A module may have several groups, where its
  lists sit between other modules' in the order the checks run: they are
  one module of the wiring set (`CheckGroup.wiring`). -/
  | wired (module : String) (set : WiringSet) (checks : κ → List α)

namespace CheckGroup

/-- Whether `set`, a module's declaration, puts its checks in the wiring
set: `.wiring` and `.contract` do, `.edge` does not. -/
def runsWiring : WiringSet → Bool
  | .wiring .. | .contract _ => true
  | .edge _ => false

/-- Every check of `groups` over `context`, in order: what a normal run
runs. -/
def all {κ α : Type} (groups : List (CheckGroup κ α)) (context : κ) : List α :=
  groups.flatMap fun
    | .plain checks => checks context
    | .wired _ _ checks => checks context

/-- Adds `checks` to `module`'s entry of `merged`, after what it holds, or
appends an entry for it. -/
def mergeInto {κ α : Type} (merged : List (String × (κ → List α))) (module : String)
    (checks : κ → List α) : List (String × (κ → List α)) :=
  if merged.any (·.1 == module) then
    merged.map fun (name, earlier) =>
      if name == module then (name, fun context => earlier context ++ checks context)
      else (name, earlier)
  else merged ++ [(module, checks)]

/-- The wiring set's modules of `groups`, each once, in the order its first
group comes, with its checks: the `wired` groups whose set is `.wiring` or
`.contract`. A module's groups are one entry, its checks in their order, so
a run prints one line for each module of the wiring set it ran. -/
def wiring {κ α : Type} (groups : List (CheckGroup κ α)) : List (String × (κ → List α)) :=
  groups.foldl (init := []) fun merged group =>
    match group with
    | .wired module set checks => if runsWiring set then mergeInto merged module checks else merged
    | .plain _ => merged

/-- The names of the wiring set's modules of `groups`, in `wiring`'s order.
It needs no context, so a listing builds no host. -/
def modules {κ α : Type} (groups : List (CheckGroup κ α)) : List String :=
  (wiring groups).map (·.1)

/-- The line a run prints for each module of the wiring set it ran, as
`wiring` gives them, over `context`: `wiring-set: ran <root> <module> <n>
checks`, which the gate's once-check and the stress loop's coverage check
read (`tools/wiring-ledger.sh`). -/
def ranLines {κ α : Type} (root : String) (modules : List (String × (κ → List α))) (context : κ) :
    List String :=
  modules.map fun (module, checks) =>
    s!"wiring-set: ran {root} {module} {(checks context).length} checks"

end CheckGroup

/-- A run of a real host that a test executable makes as a subcommand of
its own, as `ffi-test window-host` is: the table of them, `List Scenario`,
in its module of the wiring set, is how its `main` reaches them, and what
it lists (`ffi-test wiring-scenarios`). -/
structure Scenario where
  /-- The subcommand. -/
  command : String
  /-- Runs it on the arguments after the subcommand: its exit status, 2 for
  arguments it does not take. -/
  run : List String → IO UInt8

end Editor
