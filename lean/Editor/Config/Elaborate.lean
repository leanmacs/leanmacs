import Editor.Config.Modules
import Editor.Config.Session
import Lean
import Std

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

`base` imports the modules it is given from their `.olean` files and
elaborates `open Editor`, so config needs no prefix. The session core calls
it once per process. The editor's base is its package set's: `Editor`, then
the entry module of each package of the set outside the core
(`Editor/Main.lean`, "The base"); a host that is handed none uses `Editor`
alone.

- **Paths are arguments.** The search path is exactly the `.olean`
  directories it is given, in order, and then `lib/lean` under the
  toolchain's directory: the core's directory, and that of each package
  whose modules the base holds (`Editor/ModuleLookup.lean`). A base module
  that is in none of them fails the import, and `base` then says, in one
  line, which module has no `.olean` file, the directories searched, and
  that an executable with no record of its set's directories must be given
  every one, joined with `:` (`notImported`): the first thing that goes
  wrong for an editor copied away from its record is this, and Lean's own
  message names a module prefix the user never wrote. It is not
  Lean's `initSearchPath`, which also reads `LEAN_PATH` from the
  environment.
- **One copy of a module's globals.** `enableInitializersExecution` and
  `importModules (loadExts := true)` are what make interpreted config and
  compiled code see the same values. The import runs no initialiser of a
  module that is linked into the executable: Lean looks for a module's
  native initialiser first, and that one already ran when the process
  started. So every module of the editor's base must be linked into any
  executable that can elaborate config. That matters because the import
  runs on a job thread while the editor thread is running, and Lean
  documents running initialisers as unsafe beside other threads. This
  module does not import `Editor` to make it so: it is a core module, and
  the base is not (`docs/design/packages.md`). Each root that links this
  module imports `Editor` beside it (the root the package-set build
  generates for the editor, which also imports each entry module its base
  names; `ConfigTest/Check.lean`; `FfiTest/Editor/Window/Real.lean`), and
  the gate checks on Lake's module graph that every root that reaches this
  module reaches `Editor` (`tools/core-imports-check.sh`).
  `Settings.imports` still defaults to the name `Editor`, which is data.
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
  /-- The directories holding the `.olean` files of the base's modules,
  in the order they are searched: the core's, and each package's whose
  modules the base holds. -/
  oleanDirs : List System.FilePath
  /-- The modules of the base. The core's is `Editor`; the editor's adds
  the entry module of each package of its set, and tests and the benchmark
  add to it. -/
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
  Lean.searchPathRef.set (settings.oleanDirs ++ [settings.sysroot / "lib" / "lean"])
  Lean.enableInitializersExecution
  Lean.importModules (settings.imports.map fun module => { module }) options (loadExts := true)

/-- The environment after importing the base's modules from their `.olean`
files. -/
@[implemented_by importUnsafe]
opaque importBase (settings : Settings) : IO Lean.Environment

/-- The directories the base's modules are looked for in, in the order they
are searched: the `.olean` directories given, then `lib/lean` under the
toolchain's. -/
def Settings.searched (settings : Settings) : List System.FilePath :=
  settings.oleanDirs ++ [settings.sysroot / "lib" / "lean"]

/-- The modules of the base that have no `.olean` file in any directory
searched (`Settings.searched`), in the base's order. It asks the file
system, after an import has failed, to say which module the caller left a
directory out for. -/
def missing (settings : Settings) : IO (Array Lean.Name) :=
  settings.imports.filterM fun module =>
    return !(← settings.searched.anyM fun directory =>
        (Lean.modToFilePath directory module "olean").pathExists)

/-- What `base` says when the import of the base fails with `reason`, in one
line, so that a host that shows a diagnostic's first line shows all of it:
Lean's reason, its first line; the base; which of its modules have no
`.olean` file in the directories searched (`missing`), or that all have
one; those directories; and what to do. A base module is missing when the
directory of its Lake package was not given: each package of an editor's
set has an `.olean` directory of its own, the build records them beside
the editor it links, and an executable with no record must be given every
one. -/
def notImported (settings : Settings) (missing : Array Lean.Name) (reason : String) : String :=
  let first := ((reason.splitOn "\n").headD reason).trimAscii.toString
  let names (modules : Array Lean.Name) : String := ", ".intercalate (modules.map toString).toList
  let found :=
    if missing.isEmpty then
      "each of them has an .olean file there, so a module one of them imports is what is not found"
    else s!"no .olean file of {names missing} is there"
  let directories := ", ".intercalate (settings.searched.map toString)
  s!"the base config is elaborated on could not be imported: {first}. The base is {names settings.imports}, looked for in {directories}: {found}. Each package of the editor's set has an .olean directory of its own; an executable with no record of them beside it (<executable>.oleans) must be given every one, the core's and each package's, joined with `:` (--oleans, or the headless mode's <olean dir>)"

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
      let environment ←
        try
          importBase settings
        catch error =>
          throw (IO.userError (notImported settings (← missing settings) (toString error)))
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

/-! ## Config as modules

What follows answers the port of the session over modules
(`Editor/Config/Modules.lean`), which stands beside the chunk session
until the hosts are switched to it. -/

/-- The base of the adapter: the import state every module read so far is
kept in, the imports the environment was made from, and the environment a
file with no config import is elaborated on. -/
structure Base where
  /-- Lean's import state: every module file read, each once. A base is
  grown from it, and a file that imports config files gets an environment
  made from it and their module files. -/
  state : Lean.ImportState
  /-- The modules the environment imports, in the order they were asked
  for: the settings' first. -/
  imports : Array Lean.Import
  /-- The environment of those imports. -/
  environment : Lean.Environment

/-- The adapter's handle of a config file that elaborated. -/
inductive Handle where
  /-- A config file other than the root: its module name, and the file its
  module data was written to. -/
  | module (name : Lean.Name) (file : System.FilePath)
  /-- The root: the environment after it. -/
  | root (environment : Lean.Environment)

/-- Where the module data of config files is written: each version of a
file at a path of its own, never written twice, since an environment that
imported an earlier version may still be alive and its file still mapped. -/
structure ModuleFiles where
  /-- The directory the files are written in, made when it is first asked
  for. -/
  directory : IO System.FilePath
  /-- A number no file of the directory has been named with yet. -/
  next : IO Nat

/-- Module files in the directory `make` makes, which is called once, when
the first file is written. -/
def ModuleFiles.over (make : IO System.FilePath) : IO ModuleFiles := do
  let made ← IO.mkRef (none : Option System.FilePath)
  let count ← IO.mkRef 0
  return {
      directory := do
        if let some directory← made.get then
          return directory
        let directory ← make
        made.set (some directory)
        return directory,
      next := count.modifyGet fun count => (count, count + 1) }

/-- The first components of the modules of the Lean toolchain that are
linked into every executable that links this adapter: it imports `Lean` and
`Std`, which import `Init`. -/
def toolchainRoots : Array Lean.Name :=
  #[`Init, `Std, `Lean]

/-- Whether `base` holds `module`. -/
def Base.holds (base : Base) (module : Lean.Name) : Bool :=
  (base.environment.getModuleIdx? module).isSome

/-- Whether a config file may import `module` on `base`: the base holds
it, or it is a module of `Init`, `Std` or `Lean` (`toolchainRoots`) whose
`.olean` file is in the toolchain. Every such module is linked into the
executable, so reading it runs no initialiser. -/
def isLinked (settings : Settings) (base : Base) (module : Lean.Name) : IO Bool := do
  if base.holds module then
    return true
  unless toolchainRoots.contains module.getRoot do
    return false
  (Lean.modToFilePath (settings.sysroot / "lib" / "lean") module "olean").pathExists

/-- Reads the modules `added`, and what they import, into `state`, each
module file once, the ones `artifacts` names from the files it names, and
makes the environment that imports `held` and then `added`. It turns on
the execution of initialisers before each import, since Lean turns it off
when an import ends. It is `unsafe` because Lean's
`enableInitializersExecution` is: the modules read are linked into the
executable, whose native initialisers have already run and are not run
again, or are config files, which declare none (see the module docs). -/
unsafe def importOnUnsafe (state : Lean.ImportState) (held added : Array Lean.Import)
    (artifacts : Lean.NameMap Lean.ImportArtifacts) : IO (Lean.ImportState × Lean.Environment) := do
  Lean.enableInitializersExecution
  Lean.withImporting do
      let (_, state) ← (Lean.importModulesCore added (arts := artifacts)).run state
      let environment ←
        Lean.finalizeImport state (held ++ added) options (leakEnv := false) (loadExts := true)
      return (state, environment)

/-- The import state after reading `added` into `state`, and the
environment that imports `held` and then `added`. -/
@[implemented_by importOnUnsafe]
opaque importOn (state : Lean.ImportState) (held added : Array Lean.Import)
    (artifacts : Lean.NameMap Lean.ImportArtifacts) : IO (Lean.ImportState × Lean.Environment)

/-- The base that holds the settings' modules and `modules`, grown from
`earlier` when there is one: only the modules it does not hold are read. The
search path is set when the first base is made. -/
def grow (settings : Settings) (earlier : Option Base) (modules : Array Lean.Name) : IO Base := do
  let base ←
    match earlier with
    | some base =>
      pure base
    | none =>
      Lean.searchPathRef.set settings.searched
      let imports : Array Lean.Import := settings.imports.map fun module => { module }
      let (state, environment) ←
        try
          importOn default #[] imports {}
        catch error =>
          throw (IO.userError (notImported settings (← missing settings) (toString error)))
      pure { state, imports, environment }
  let added := modules.filter fun module => !base.holds module
  if added.isEmpty then
    return base
  for module in added do
    unless ← isLinked settings base module do
      throw (IO.userError s!"module `{module}` is not linked into this editor")
  let imports : Array Lean.Import := added.map fun module => { module }
  let (state, environment) ← importOn base.state base.imports imports {}
  return { state, imports := base.imports ++ imports, environment }

/-- The imports of the header of the file at `path` whose text is `text`,
each with the line and column it starts at, or why the header cannot be
read: Lean's messages, or that the file starts with `module`, which config
files may not: they are plain modules. -/
def headerImports (path text : String) : IO (Except (Array Diagnostic) (Array Modules.Import)) := do
  let input := Lean.Parser.mkInputContext text path
  let (header, _, messages) ← Lean.Parser.parseHeader input
  if messages.hasErrors then
    return .error (← diagnostics path messages)
  let placed (syntaxNode : Lean.Syntax) : Lean.Position :=
    input.fileMap.toPosition (syntaxNode.getPos?.getD 0)
  match header with
  | `(Lean.Parser.Module.header| $[module%$moduleToken?]? $[prelude]? $imports*) =>
    if let some token := moduleToken? then
      let position := placed token
      return .error
          #[{ source := path, line := position.line, column := position.column, severity := .error,
              message :=
                "a config file may not start with `module`: config files are plain modules, which the editor elaborates each on its own" }]
    return .ok
        (imports.filterMap fun «import» =>
          match «import» with
          | `(Lean.Parser.Module.import| $[public]? $[meta]? import $[all]? $module) =>
            let position := placed «import»
            some
              { module := module.getId.toString, line := position.line, column := position.column }
          | _ => none)
  | _ =>
    return .ok #[]

/-- The environment the file called `module` is elaborated on: the base's
when it is handed no config file, and otherwise one made from the base's
import state and the module files of `handles`, which are read each time,
since each is one version of a file. A root's handle among them is left
out: nothing imports a root. -/
def environmentOver (base : Base) (handles : Array Handle) (module : Lean.Name) :
    IO Lean.Environment := do
  let files :=
    handles.filterMap fun handle =>
      match handle with
      | .module name file => some (name, file)
      | .root _ => none
  if files.isEmpty then
    return base.environment.setMainModule module
  let artifacts : Lean.NameMap Lean.ImportArtifacts :=
    files.foldl (fun artifacts (name, file) => artifacts.insert name (.ofArrays #[#[file]])) {}
  let imports : Array Lean.Import := files.map fun (name, _) => { module := name }
  let (_, environment) ← importOn base.state base.imports imports artifacts
  return environment.setMainModule module

/-- Elaborates the file `file` as a module on `base` over `handles`: the
diagnostics, and the environment after it unless a diagnostic is an error
or it declares `initialize`. The parser starts after the header, whose
imports the session core has already acted on, and messages carry the
file's own lines. -/
def elaborateFile (base : Base) (handles : Array Handle) (file : Modules.SourceFile) :
    IO (Array Diagnostic × Option Lean.Environment) := do
  let environment ← environmentOver base handles file.module.toName
  let input := Lean.Parser.mkInputContext file.text file.path
  let (_, parserState, messages) ← Lean.Parser.parseHeader input
  let frontend ←
    Lean.Elab.IO.processCommands input parserState
        (Lean.Elab.Command.mkState environment messages options)
  let after := frontend.commandState
  let found ← diagnostics file.path after.messages
  if after.messages.hasErrors then
    return (found, none)
  let refused :=
    (initialised after.env).map fun name =>
      failure file.path
        s!"`{name}` is declared with `initialize`, which config may not use: keep state that must outlive a reload in a store (`Editor.Store`)"
  unless refused.isEmpty do
    return (found ++ refused, none)
  return (found, some after.env)

/-- The name of the constant the editor runs: the root's own `setup`. -/
def setupName : Lean.Name :=
  `setup

/-- What is elaborated after the root: the root's own `setup`, at the type
the editor runs. -/
def rootTrailer : String :=
  "def «editor.setup» : Editor.SetupM Unit := _root_.setup"

/-- What is said of a root that declares no `setup` itself: the rule, and,
when a module it imports declares one, whose that is. -/
def noSetup (environment : Lean.Environment) : String :=
  let elsewhere :=
    match environment.getModuleIdxFor? setupName with
    | some index =>
      match environment.header.moduleNames[index.toNat]? with
      | some module => s!" (the `setup` it can see is the one of `{module}`, which is not run)"
      | none => ""
    | none => ""
  s!"{Modules.rootPath} defines no `setup`: the editor runs the `setup` the root itself defines, at the type `Editor.SetupM Unit`, and no other{elsewhere}; a config file the root imports exports its programs under other names, and the root's `setup` calls them"

/-- The real elaborator of config as modules, over `settings`, which
writes the module data of config files through `files`. -/
def moduleElaborator (settings : Settings) (files : ModuleFiles) : Modules.Elaborator Base Handle :=
  { imports := fun file => headerImports file.path file.text,
    base := fun earlier modules => grow settings earlier (modules.map String.toName),
    linked := fun base module => isLinked settings base module.toName,
    file := fun base handles file => do
      let (found, environment) ← elaborateFile base handles file
      let some environment := environment | return { diagnostics := found, handle := none }
      let name := file.module.toName
      let directory ← files.directory
      let written := directory / s!"{← files.next}-{file.module}.olean"
      Lean.writeModule environment written
      return { diagnostics := found, handle := some (.module name written) },
    root := fun base handles file => do
      let (found, environment) ← elaborateFile base handles file
      return { diagnostics := found, handle := environment.map .root },
    setup := fun handle => do
      let .root environment := handle
        | return .error #[failure "setup" "only a root has a `setup` the editor runs"]
      unless environment.constants.map₂.contains setupName do
        return .error #[failure "setup" (noSetup environment)]
      let after ← elaborate (Lean.Elab.Command.mkState environment {} options) "setup" rootTrailer
      if after.messages.hasErrors then
        return .error (← diagnostics "setup" after.messages)
      match evalSetup after.env with
      | .error message =>
        return .error #[failure "setup" message]
      | .ok program =>
        return .ok program }

end Editor.Config.Elaborate
