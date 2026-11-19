import Compile
import Compile.Compiled
import CompileTest.Check
import Editor.Config.Packages

/-!
# Model tests: `Compile/Compiled.lean`

The model tests of `Compile/Compiled.lean`: `compilePackageChecks`.
The test driver's root, `CompileTest/Model.lean`, runs them; its module doc
says what each shows.
-/

namespace CompileTest

open Editor

/-- The checks of the `compile` package (`Compile/Compiled.lean`):
the ex names it binds are its own to bind, and what it registers on its
own, read through the core's test double for that
(`Config.State.ofPackages`, `Editor/Config/Packages.lean`): its commands,
its job, its mode, its ex names with what each takes, no key, and the
contributions that ship, each for the owner `compile`. -/
def compilePackageChecks : List Check :=
  [{  name :=
        "the package compile binds the ex names compile, compile-command, recompile, kill-compilation, next-error and previous-error, in that order, each to a command it registers"
      run :=
        let registered := Compile.package.registered
        pure
          (registered.ex.map (·.name) ==
              #["compile", "compile-command", "recompile", "kill-compilation", "next-error",
                "previous-error"] &&
            registered.ex.all fun binding => registered.commands.any (·.name == binding.command)) },
    { name :=
        "the package compile is accepted alone and registers, for the owner compile: compile, compile-command, recompile, compile-confirm, kill-compilation, compilation-output, next-error, previous-error and compile-goto-error; the job compile-run and no job compile-list; the mode compilation; the ex names compile and compile-command, which take text, and recompile, kill-compilation, next-error and previous-error, each bound to the command of its name; no key; and cargo-mode, lake-mode and mise-mode as its contributions, in that order"
      run :=
        let (state, refused) : Config.State Unit × Array String :=
          Config.State.ofPackages #[Compile.package]
        let registry := state.registry
        let owned (name : String) : Bool :=
          (registry.find? name).any (·.owner == Compile.package.owner)
        pure
          (refused == #[] &&
            [Compile.compileName, Compile.commandName, Compile.recompileName, Compile.confirmName,
                  Compile.killName, Compile.outputName, Compile.nextName, Compile.previousName,
                  Compile.gotoName].all
              owned &&
            registry.jobs.map (fun entry => (entry.registration.name, entry.owner)) ==
              #[(Compile.runJob, Compile.package.owner)] &&
            (registry.mode? Compile.modeName).isSome &&
            registry.ex? "compile" ==
              some { name := "compile", command := Compile.compileName, takes := .text } &&
            registry.ex? "compile-command" ==
              some { name := "compile-command", command := Compile.commandName, takes := .text } &&
            (registry.ex? "recompile").map (·.command) == some Compile.recompileName &&
            (registry.ex? "kill-compilation").map (·.command) == some Compile.killName &&
            (registry.ex? "next-error").map (·.command) == some Compile.nextName &&
            (registry.ex? "previous-error").map (·.command) == some Compile.previousName &&
            registry.bindings.isEmpty &&
            registry.contributions.map (fun entry => (entry.contribution.mode, entry.owner)) ==
              #[("cargo-mode", Compile.package.owner), ("lake-mode", Compile.package.owner),
                ("mise-mode", Compile.package.owner)]) }]

end CompileTest
