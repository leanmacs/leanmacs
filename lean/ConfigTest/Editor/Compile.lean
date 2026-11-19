import ConfigTest.Check
import ConfigTest.Support.Hosts
import Editor.Compile.Errors
import Editor.Compile.Shipped
import Editor.Config.Elaborate
import Editor.Config.Registry
import Editor.Config.Session
import Editor.ProjectMode
import Editor.ProjectMode.Format
import Editor.Setup
import Editor.Value

/-!
# Config tests: `Editor/Compile.lean`

The tests of the compile mode as config sees it, with the real elaborator:
`compileConfigChecks`. The root module `ConfigTest` runs them; its module doc
says what each shows. They are apart from the checks of core modules
because the compile mode is not a core module
(`docs/design/packages.md`): no test module of the core's names it.
-/

namespace ConfigTest

open Editor

/-- The checks of what a real config makes of the compile mode on the base
it is elaborated on: a shipped contribution it overrides one field of
(`Editor/Compile/Shipped.lean`), and a contribution of its own whose format
the compile mode reads a line with (`Editor/Compile/Errors.lean`). -/
def compileConfigChecks (context : Context) : List Check :=
  [{  name :=
        "a real config overrides one field of a shipped contribution: { Compile.cargoMode with commands := … } elaborates, and over the shipped contributions the hook's cargo-mode has config's one command with the shipped marker, root rule and rustc format, and lake-mode and mise-mode follow"
      run := do
        let text :=
          "def setup : SetupM Unit := do
  compileContribution
      { Compile.cargoMode with commands := #[{ name := \"build\", line := \"cargo build --release\" }] }
"
        let some state := (← onBase context "config.lean" text).state | return false
        let .ok program ← context.elaborator.setup state | return false
        let .ok registrations := Config.Registrations.ofSetup program | return false
        let registry :=
          (({} : Config.Registry).replaceContributions .compiled
                Compile.shipped).replaceContributions
            .config registrations.contributions
        let hook := registry.compileHook
        return hook.contributions.map (·.mode) == #["cargo-mode", "lake-mode", "mise-mode"] &&
            (hook.contributions[0]?.map fun cargo =>
                (cargo.commands.map (·.line), cargo.markers, cargo.outermost,
                  cargo.formats.map (·.name))) ==
              some (#["cargo build --release"], #["Cargo.toml"], true, #["rustc"]) },
    { name :=
        "a real config whose setup registers a compile contribution with a format of its own, and project commands, elaborates, and installs them: the format reads its line and the project's commands are kept"
      run := do
        let text :=
          "def atFormat : Compile.Format :=
  { name := \"at\"
    pattern :=
      [Compile.step
          [{ atom := .literal \"at \" }, { atom := .noneOf [' '], into := some .file },
            { atom := .literal \" line \" }, { atom := .digits, into := some .line }]] }

def setup : SetupM Unit := do
  compileContribution
      { mode := \"a-mode\", markers := #[\"a.toml\"], commands := #[{ name := \"build\", line := \"make\" }]
        formats := #[atFormat] }
  projectCommands (.remote \"github.com/o/r\") \"a-mode\" [(\"lint\", \"make lint\")]
      [(\"profile\", .str \"dev\")]
"
        let some state := (← onBase context "config.lean" text).state | return false
        let .ok program ← context.elaborator.setup state | return false
        let .ok registrations := Config.Registrations.ofSetup program | return false
        let registry :=
          { ({} : Config.Registry).replaceContributions .config registrations.contributions with
            projectCommands := registrations.projectCommands }
        let hook := registry.compileHook
        return hook.contributions.map (·.mode) == #["a-mode"] &&
            (hook.contributions.map fun contribution =>
                contribution.formats.map fun format =>
                  (format.read? "at src/x.rs line 4").map fun reading =>
                    (reading.file, reading.line)) ==
              #[#[some ("src/x.rs", 4)]] &&
            hook.projects.map
                (fun entry => (entry.mode, entry.commands.map (·.line), entry.settings)) ==
              #[("a-mode", #["make lint"], [("profile", Value.str "dev")])] }]

end ConfigTest
