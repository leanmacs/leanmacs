import Editor.Config.Diagnostic
import Editor.Config.Registry
import Editor.Config.Session
import Editor.InputScheme.Test
import Editor.Program
import Editor.Setup
import Editor.Test.Models
import ModelTest.Check
import ModelTest.Support.Elaborator

/-!
# Model tests: `Editor/Config/Session.lean`

The model tests of `Editor/Config/Session.lean`: `sessionChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The names and the states of an outcome's chunks, if it built any. -/
def builtChunks (outcome : Config.Outcome Elaborated) : Option (Array (String × Elaborated)) :=
  outcome.built.map (·.chunks.map fun chunk => (chunk.name, chunk.after))

/-- Builds `source` over `chunks` with a fake elaborator whose base is already
imported, and returns the calls the elaborator received. -/
def rebuildCalls (chunks : List String) (source : Config.Source) : IO (Array ElaboratorCall) := do
  let calls ← IO.mkRef #[]
  discard <| Config.build TestScheme.scheme (fakeElaborator calls) source (some #[]) (loaded chunks)
  calls.get

/-- The checks of the session core (`Editor/Config/Session.lean`): which
chunks a reload elaborates, from which state, and what it gives back. -/
def sessionChecks : List Check :=
  [{
      name :=
        "a first load imports the base, then elaborates every chunk in the source's order, each on the state after the one before it, then asks for setup on the last state",
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls) (fakeSource ["a", "b", "c"]) none
              #[]
        return (← calls.get) ==
              #[.base, .chunk #[] "a", .chunk #["a"] "b", .chunk #["a", "b"] "c",
                .setup #["a", "b", "c"]] &&
            outcome.base == some #[] &&
            builtChunks outcome ==
              some #[("a", #["a"]), ("b", #["a", "b"]), ("c", #["a", "b", "c"])] &&
            outcome.diagnostics.isEmpty },
    { name := "with the base given, it is not imported again, and the outcome hands it back"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls) (fakeSource ["a"]) (some #["given"])
              #[]
        return (← calls.get) == #[.chunk #["given"] "a", .setup #["given", "a"]] &&
            outcome.base == some #["given"] },
    { name :=
        "changing a chunk elaborates it and the chunks after it, from the cached state before it"
      run := do
        let calls ← rebuildCalls ["a", "b", "c"] (fakeSource ["a", "b", "c"] [("b", "changed")])
        return calls == #[.chunk #["a"] "b", .chunk #["a", "b"] "c", .setup #["a", "b", "c"]] },
    { name := "removing a chunk elaborates the chunks after it, from the state before it"
      run := do
        let calls ← rebuildCalls ["a", "b", "c"] (fakeSource ["a", "c"])
        return calls == #[.chunk #["a"] "c", .setup #["a", "c"]] },
    { name := "adding a chunk at the end elaborates it alone"
      run := do
        let calls ← rebuildCalls ["a", "b"] (fakeSource ["a", "b", "c"])
        return calls == #[.chunk #["a", "b"] "c", .setup #["a", "b", "c"]] },
    { name := "renaming a chunk elaborates it and the chunks after it"
      run := do
        let calls ← rebuildCalls ["a", "b", "c"] (fakeSource ["a", "b2", "c"] [("b2", "b")])
        return calls == #[.chunk #["a"] "b2", .chunk #["a", "b2"] "c", .setup #["a", "b2", "c"]] },
    { name := "a reload with nothing changed elaborates no chunk, and still asks for setup"
      run := do
        let calls ← rebuildCalls ["a", "b"] (fakeSource ["a", "b"])
        return calls == #[.setup #["a", "b"]] },
    { name :=
        "a chunk that fails gives a rejected outcome with its diagnostics, and no later chunk and no setup is elaborated"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls)
              (fakeSource ["a", "b", "c"] [("b", "fails")]) (some #[]) #[]
        return (← calls.get) == #[.chunk #[] "a", .chunk #["a"] "b"] && outcome.built.isNone &&
            outcome.diagnostics == #[told "b" .error] },
    { name := "a chunk with only a warning is built, and the outcome carries the warning"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls)
              (fakeSource ["a", "b"] [("a", "warns")]) (some #[]) #[]
        return builtChunks outcome == some #[("a", #["a"]), ("b", #["a", "b"])] &&
            outcome.diagnostics == #[told "a" .warning] },
    { name := "what setup registers is in the outcome"
      run := do
        let calls ← IO.mkRef #[]
        let setup : SetupM Unit := command "greet" (makes "hello")
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls (.ok setup)) (fakeSource ["a"])
              (some #[]) #[]
        return (outcome.built.map (·.registrations.commands.map (·.name))) == some #["greet"] },
    { name :=
        "a setup that throws gives a rejected outcome whose diagnostic's source is setup and whose message is the one thrown"
      run := do
        let calls ← IO.mkRef #[]
        let setup : SetupM Unit := do
          command "greet" (makes "hello")
          throw "no thanks"
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls (.ok setup)) (fakeSource ["a"])
              (some #[]) #[]
        return outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "setup", severity := .error, message := "no thanks" }] },
    { name :=
        "a setup that registers a command name twice gives a rejected outcome whose diagnostic's source is setup and names the command"
      run := do
        let calls ← IO.mkRef #[]
        let setup : SetupM Unit := do
          command "greet" (makes "hello")
          command "greet" (makes "again")
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls (.ok setup)) (fakeSource ["a"])
              (some #[]) #[]
        return outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "setup", severity := .error,
                  message := "the command `greet` is registered twice" }] },
    { name :=
        "a setup whose bindings are one sequence under the leaders in force of the scheme it is built for gives a rejected outcome whose diagnostic's source is setup and names both ways the keys are written"
      run := do
        let calls ← IO.mkRef #[]
        let setup : SetupM Unit := do
          bindKey "<leader> f" "find"
          bindKey "C-c f" "fill"
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls (.ok setup)) (fakeSource ["a"])
              (some #[]) #[]
        return outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "setup", severity := .error,
                  message :=
                    "the keys `C-c f` are bound twice: as `<leader> f` and as `C-c f`" }] },
    { name :=
        "a config whose setup cannot be produced gives a rejected outcome with the diagnostics"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls (.error #[told "setup" .error]))
              (fakeSource ["a"]) (some #[]) #[]
        return outcome.built.isNone && outcome.diagnostics == #[told "setup" .error] },
    { name := "a config with no chunks is built with nothing registered, and no setup is asked for"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls) (fakeSource []) (some #[])
              (loaded ["a"])
        return (← calls.get).isEmpty && builtChunks outcome == some #[] &&
            (outcome.built.map (·.registrations.commands.size)) == some 0 },
    { name :=
        "a source that cannot be read gives a rejected outcome, which still hands back the base"
      run := do
        let calls ← IO.mkRef #[]
        let source : Config.Source := { chunks := throw (IO.userError "no such directory") }
        let outcome ← Config.build TestScheme.scheme (fakeElaborator calls) source none #[]
        return (← calls.get) == #[.base] && outcome.built.isNone && outcome.base == some #[] &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("config", .error)] },
    { name := "an elaborator that throws gives a rejected outcome that names the chunk"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls)
              (fakeSource ["a", "b"] [("a", "throws")]) (some #[]) #[]
        return (← calls.get) == #[.chunk #[] "a"] && outcome.built.isNone &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("a", .error)] },
    { name :=
        "a base that cannot be imported gives a rejected outcome with no base and one diagnostic from the base, and no chunk is elaborated"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls (baseThrows := true))
              (fakeSource ["a"]) none #[]
        return (← calls.get) == #[.base] && outcome.built.isNone && outcome.base == none &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("base", .error)] },
    { name :=
        "an elaborator that throws when asked for setup gives a rejected outcome with a diagnostic from setup, and hands back the base"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls (setupThrows := true))
              (fakeSource ["a"]) (some #[]) #[]
        return (← calls.get) == #[.chunk #[] "a", .setup #["a"]] && outcome.built.isNone &&
            outcome.base == some #[] &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("setup", .error)] }]

end ModelTest
