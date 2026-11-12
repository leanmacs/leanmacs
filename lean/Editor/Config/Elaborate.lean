import Editor
import Editor.Config.Session
import Lean

/-!
# The elaborator port, answered by Lean's elaborator

The real adapter of `Config.Elaborator` (`Editor/Config/Session.lean`), and
the only module of the editor that imports Lean's elaborator. An executable
that imports it links the elaborator in, and grows by about 170 MB.

It is thin. What is elaborated, in which order and from which state, and
what a failure means, are the session core's decisions. Here a state is
Lean's `Command.State`, and each operation of the port is one run of Lean's
frontend.

It imports the whole of `Lean`, on purpose. Lean's built-in elaborators, its
pretty printer, its linters and the passes that compile a definition for the
interpreter each register themselves in the initialiser of the module that
defines them, and only the initialisers of imported modules run when the
process starts. `Lean.Elab.Frontend` alone builds, but its imports hold
neither the `do` elaborators nor the tactics; `Lean.Elab` adds those and
still leaves out the compiler.

## The base

`base` imports the modules it is given (`Editor`, for the editor) from their
`.olean` files and elaborates `open Editor`, so config needs no prefix. The
session core calls it once per process.

- **Paths are arguments.** The search path is exactly the package's `.olean`
  directory and `lib/lean` under the toolchain's directory. It is not Lean's
  `initSearchPath`, which also reads `LEAN_PATH` from the environment.
- **One copy of a module's globals.** `enableInitializersExecution` and
  `importModules (loadExts := true)` are what make interpreted config and
  compiled code see the same values. The import runs no initialiser of a
  module that is linked into the executable: Lean looks for a module's
  native initialiser first, and that one already ran when the process
  started. This module imports `Editor`, so every module of the editor's
  base is linked into any executable that can elaborate config. That matters
  because the import runs on a job thread while the editor thread is
  running, and Lean documents running initialisers as unsafe beside other
  threads.
- **Config cannot name a binding.** `Editor` never imports `Editor.Ffi`
  (`Editor.lean`), so the base does not hold it.

## A chunk

A chunk is elaborated like a file with no `import` line, on the environment
the chunk before it left. Its scopes start from the base's, so an `open` or a
`namespace` in one chunk does not reach the next. Lean's messages become
diagnostics, and a chunk with an error leaves no state.

A chunk may not declare `initialize`. Such a chunk elaborates, but the
interpreter throws a C++ exception the first time a declaration that reads
the constant is evaluated, and an exception from the interpreter ends the
process (`Editor/Ffi.lean`). This one can be refused before any code runs, so
the adapter rejects the chunk with a diagnostic that points at the store,
which is where config keeps state.

## `setup`

After the last chunk the adapter elaborates a trailer,
`def «editor.setup» : Editor.SetupM Unit := setup`, so the elaborator checks
that the config defines `setup` at the type the editor runs. It then
evaluates that one constant at that type: the only unchecked evaluation of a
reload. A missing `setup` and one of another type are diagnostics from the
trailer. A `setup` that depends on `sorry` is an error value from the
evaluation, and nothing runs.

Commands are not looked up here. A command is the value `setup` registered.

## Tests

`config-test` runs the checks of this adapter (`ConfigTest.elaboratorChecks`).
The session core's own tests run on a fake of the port.
-/

namespace Editor.Config.Elaborate

/-- The elaborator's state after some chunks: Lean's command state. -/
abbrev State :=
  Lean.Elab.Command.State

/-- Where the adapter finds what it imports, and what that is. -/
structure Settings where
  /-- The Lean toolchain's directory: its modules are under `lib/lean`. -/
  sysroot : System.FilePath
  /-- The directory holding the `.olean` files of the editor's package. -/
  oleanDir : System.FilePath
  /-- The modules of the base. The editor's is `Editor`; tests and the
  benchmark add to it. -/
  imports : Array Lean.Name := #[`Editor]

/-- The options every elaboration runs with: synchronously, so that every
message is in the state the frontend returns. -/
def options : Lean.Options :=
  ({} : Lean.Options).setBool `Elab.async false

/-- Elaborates `text` on `state` and returns the state after it, with only the
messages of this text. `source` is the file name the messages carry. -/
def elaborate (state : State) (source text : String) : IO State := do
  let input := Lean.Parser.mkInputContext text source
  let frontend ← Lean.Elab.IO.processCommands input {} { state with messages := {} }
  return frontend.commandState

/-- Lean's messages as diagnostics tagged `source`. -/
def diagnostics (source : String) (messages : Lean.MessageLog) : IO (Array Diagnostic) :=
  messages.toArray.mapM fun message => do
    let severity :=
      match message.severity with
      | .information => Severity.information
      | .warning => Severity.warning
      | .error => Severity.error
    return { source, line := message.pos.line, column := message.pos.column, severity,
             message := ← message.data.toString }

/-- The constants declared since the import that are declared with
`initialize`, in either of its forms: a constant with an initialiser, or an
initialiser alone. -/
def initialised (environment : Lean.Environment) : Array Lean.Name :=
  environment.constants.map₂.foldl
    (fun names name _ =>
      if Lean.hasInitAttr environment name || Lean.isIOUnitInitFn environment name then
        names.push name
      else names)
    #[]

/-- Sets the search path, turns on the execution of initialisers and imports
the base. It is `unsafe` because Lean's `enableInitializersExecution` is: the
imported modules' initialisers must be safe to run beside the threads that
are running, and those of the editor's base are not run at all (see the
module docs). -/
unsafe def importUnsafe (settings : Settings) : IO Lean.Environment := do
  Lean.searchPathRef.set [settings.oleanDir, settings.sysroot / "lib" / "lean"]
  Lean.enableInitializersExecution
  Lean.importModules (settings.imports.map fun module => { module }) options (loadExts := true)

/-- The environment after importing the base's modules from their `.olean`
files. -/
@[implemented_by importUnsafe]
opaque importBase (settings : Settings) : IO Lean.Environment

/-- The name of the constant the trailer defines. Config cannot define it by
accident: it is not an identifier one writes without the quotes. -/
def trailerName : Lean.Name :=
  `«editor.setup»

/-- What is elaborated after the last chunk: `setup`, at the type the editor
runs. -/
def trailer : String :=
  "def «editor.setup» : Editor.SetupM Unit := setup"

/-- Evaluates the trailer's constant. It is `unsafe` because evaluating a
constant trusts the type it is given; the elaborator has just checked the
trailer at this type. -/
unsafe def evalSetupUnsafe (environment : Lean.Environment) : Except String (SetupM Unit) :=
  environment.evalConst (SetupM Unit) options trailerName

/-- The `setup` program of the config `environment` holds, or why it cannot be
evaluated. -/
@[implemented_by evalSetupUnsafe]
opaque evalSetup (environment : Lean.Environment) : Except String (SetupM Unit)

/-- The real elaborator. -/
def elaborator (settings : Settings) : Elaborator State :=
  {
    base := do
      let environment ← importBase settings
      let state ← elaborate (Lean.Elab.Command.mkState environment {} options) "base" "open Editor"
      if state.messages.hasErrors then
        let problems ← diagnostics "base" state.messages
        throw
            (IO.userError
              ("the base did not elaborate: " ++
                "; ".intercalate (problems.map (·.message)).toList))
      return { state with messages := {} },
    chunk := fun before chunk => do
      let after ← elaborate before chunk.name chunk.text
      let found ← diagnostics chunk.name after.messages
      if after.messages.hasErrors then
        return { diagnostics := found, state := none }
      let refused :=
        (initialised after.env).map fun name =>
          failure chunk.name
            s!"`{name}` is declared with `initialize`, which config may not use: keep state that must outlive a reload in a store (`Editor.Store`)"
      unless refused.isEmpty do
        return { diagnostics := found ++ refused, state := none }
      -- Like a file: the next chunk starts from the scopes this one started
      -- from, not from the ones it left open.
      return { diagnostics := found,
               state :=
                 some
                   { after with
                     messages := {}, scopes := before.scopes } },
    setup := fun state => do
      let after ← elaborate state "setup" trailer
      if after.messages.hasErrors then
        return .error (← diagnostics "setup" after.messages)
      match evalSetup after.env with
      | .error message =>
        return .error #[failure "setup" message]
      | .ok program =>
        return .ok program }

end Editor.Config.Elaborate
