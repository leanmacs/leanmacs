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
the fixture package `greeting`'s `GreetingTest/Lint/RealHost.lean`).
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

end Editor
