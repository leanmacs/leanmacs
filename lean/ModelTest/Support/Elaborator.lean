import Editor.Appearance
import Editor.Config.Diagnostic
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Config.Session
import Editor.Program
import Editor.Setup

/-!
# Model tests: support: Elaborator

A hand-written fake of the config elaborator, and what a check sees of the
elaborations it answers. Shared by several test modules under
`ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The state of the fake elaborator: the names of the chunks elaborated so
far, oldest first. Its base is the state with none. -/
abbrev Elaborated :=
  Array String

/-- A call the fake elaborator received. -/
inductive ElaboratorCall where
  /-- The base was imported. -/
  | base
  /-- The chunk called `name` was elaborated on the state `before`. -/
  | chunk (before : Elaborated) (name : String)
  /-- The `setup` program was asked for, of a config that left `state`. -/
  | setup (state : Elaborated)
  deriving DecidableEq, Repr

/-- The diagnostic the fake elaborator gives for the chunk called `name` when
the chunk's text tells it to. -/
def told (name : String) (severity : Config.Severity) : Config.Diagnostic :=
  { source := name, line := 1, severity, message := "the fake was told to" }

/-- A hand-written fake of the elaborator port. It records every call in
`calls`. A chunk whose text is "fails" fails with an error; one whose text is
"warns" elaborates with a warning; one whose text is "throws" makes the port
itself throw. `setup` is the program it says the config defines, or the
diagnostics it has instead. With `baseThrows` the port throws when it is
asked to import the base, and with `setupThrows` when it is asked for the
`setup` program. -/
def fakeElaborator (calls : IO.Ref (Array ElaboratorCall))
    (setup : Except (Array Config.Diagnostic) (SetupM Unit) := .ok (pure ()))
    (baseThrows setupThrows : Bool := false) : Config.Elaborator Elaborated :=
  {
    base := do
      calls.modify (·.push .base)
      if baseThrows then
        throw (IO.userError "the fake elaborator's base broke")
      return #[],
    chunk := fun before chunk => do
      calls.modify (·.push (.chunk before chunk.name))
      match chunk.text with
      | "fails" =>
        return { diagnostics := #[told chunk.name .error], state := none }
      | "warns" =>
        return { diagnostics := #[told chunk.name .warning],
                 state := some (before.push chunk.name) }
      | "throws" =>
        throw (IO.userError "the fake elaborator broke")
      | _ =>
        return { diagnostics := #[], state := some (before.push chunk.name) },
    setup := fun state => do
      calls.modify (·.push (.setup state))
      if setupThrows then
        throw (IO.userError "the fake elaborator's setup broke")
      return setup }

/-- A hand-written fake of the source port: the chunks called `names`, each
with its own name as its text unless `texts` gives it another. -/
def fakeSource (names : List String) (texts : List (String × String) := []) : Config.Source :=
  {
    chunks :=
      pure
        (names.toArray.map fun name =>
          { name, text := ((texts.find? (·.1 == name)).map (·.2)).getD name }) }

/-- The chunks a config of the fake elaborator has once the chunks called
`names` are loaded, each with its name as its text. -/
def loaded (names : List String) : Array (Config.Chunk Elaborated) :=
  (List.range names.length).toArray.map fun index =>
    { name := names.getD index "", text := names.getD index "",
      after := (names.take (index + 1)).toArray }

/-- An effect of the reload reducer, as a check compares it: a start with the
base and the names of the chunks it carries, the cancelling of an owner's
jobs with the owner's name, or a report with its number, whether it
installed, the sources of its diagnostics, and its counts of files and
commands. -/
inductive Seen where
  /-- A job was started. -/
  | start (base : Option Elaborated) (chunks : Array String)
  /-- The jobs of the owner called `owner` were cancelled. -/
  | cancelJobs (owner : String)
  /-- A reload was reported. -/
  | report (number : Nat) (installed : Bool) (sources : Array String) (files commands : Nat)
  /-- The theme in force was switched. -/
  | themed
  /-- The window was asked for this appearance. -/
  | appearance (appearance : Appearance)
  deriving DecidableEq, Repr

/-- `effect` as a check compares it. -/
def seen : Config.Effect Elaborated → Seen
  | .start base chunks => .start base (chunks.map (·.name))
  | .cancelJobs owner => .cancelJobs owner.name
  | .report report =>
    .report report.number report.installed (report.diagnostics.map (·.source)) report.files
      report.commands
  | .themed => .themed
  | .appearance appearance => .appearance appearance

/-- The outcome of a reload that built the chunks called `names`, whose
`setup` is `setup`. Built by hand: no elaborator ran. -/
def accepted (names : List String) (setup : SetupM Unit) : Config.Outcome Elaborated :=
  { base := some #[], diagnostics := #[],
    built :=
      (Config.Registrations.ofSetup setup).toOption.map fun registrations =>
        { chunks := loaded names, registrations } }

/-- The outcome of a reload that was rejected with one error from `source`. -/
def rejected (source : String) : Config.Outcome Elaborated :=
  { base := some #[], diagnostics := #[told source .error], built := none }

end ModelTest
