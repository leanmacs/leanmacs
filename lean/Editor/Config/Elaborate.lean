import Editor.Config.ExactPath
import Editor.Config.Session
import Lean
import Std

/-!
# The elaborator port, answered by Lean's elaborator

The real adapter of `Config.Elaborator` (`Editor/Config/Session.lean`): it
turns a config file into a module with Lean's own frontend. It is one of
the two modules of the editor that link Lean's parser and elaborator; the
other reads a lakefile's requires with Lake's TOML loader
(`Editor/Config/Lakefile/Toml.lean`). An executable that imports it links
the elaborator in, and grows by about 170 MB.

It is thin. Which files are elaborated, in which order, over which
handles and on which base, and what a failure means, are the session
core's decisions. The port's contract
(`Editor/Config/Elaborator/Contract.lean`) holds this adapter and the
port's pure model to the same properties.

It imports the whole of `Lean`, and `Std`, on purpose, for two reasons.
Lean's built-in elaborators, its pretty printer, its linters and the
passes that compile a definition for the interpreter each register
themselves in the initialiser of the module that defines them, and only
the initialisers of imported modules run when the process starts:
`Lean.Elab.Frontend` alone builds, but its imports hold neither the `do`
elaborators nor the tactics, and `Lean.Elab` adds those and still leaves
out the compiler. And a config file may import any module of `Init`,
`Std` or `Lean` (`toolchainRoots`): importing both here links every
module of them into any executable that can elaborate config, by
construction, so reading one at runtime runs no initialiser.

## The base

A base (`Base`) is the linked modules config is elaborated on: Lean's
import state, which holds every module file read so far, each once, the
list of modules imported, and the environment made from them.

- **It starts as the settings' modules.** The editor's are its package
  set's: `Editor`, then the entry module of each package of the set
  outside the core (`Editor/Main.lean`, "The base"); a host that is handed
  none uses `Editor` alone.
- **It grows with what config imports** (`grow`). A reload whose files
  import linked modules the base does not hold reads them into the import
  state it kept, and what they import, and makes a new environment over
  the old imports and the new. A module file is read once in a process:
  the state remembers it, and a second read would map the file again at
  another address and about double its memory. The base the reload was
  handed stays usable, since both are values.
- **What is linked** (`linkedAs`): a module the base holds, or a module
  of `Init`, `Std` or `Lean` whose `.olean` file is in the toolchain. The
  name is exact about case: `Lean.data.json` is not linked though a file
  system that ignores case opens `Lean/Data/Json.olean` for it, and looking
  it up says that it is `Lean.Data.Json` misspelt
  (`Editor/Config/ExactPath.lean`). A module of the editor that the base
  does not hold, a binding (`Editor.Ffi`) among them, is not: config
  cannot name a binding.
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
  an import that loads the extensions are what make interpreted config and
  compiled code see the same values. The import runs no initialiser of a
  module that is linked into the executable: Lean looks for a module's
  native initialiser first, and that one already ran when the process
  started. So every module a base may hold must be linked into any
  executable that can elaborate config. That matters because every import
  runs on a job thread while the editor thread is running, and Lean
  documents running initialisers as unsafe beside other threads. This
  module does not import `Editor` to make it so: it is a core module, and
  the base is not (`docs/design/packages.md`). Each root that links this
  module imports `Editor` beside it (the root the package-set build
  generates for the editor, which also imports each entry module its base
  names; `ConfigTest/Check.lean`; `FfiTest/Editor/Window/Real.lean`), and
  every root that reaches this module reaches `Editor`
  (`.agents/rules/structure.md`, "Core imports").
  `Settings.imports` still defaults to the name `Editor`, which is data.
- **The importing flag.** Lean's import runs with its "importing" flag up
  (`Lean.withImporting`), and turns the execution of initialisers off when
  it ends, so each import here turns it on first (`importOnUnsafe`). The
  flag is up for each environment made, the base's and each file's that
  imports config files, tens to hundreds of milliseconds each, on the
  reload's job thread (`docs/design/concurrency.md`).

## A file

A config file is elaborated as a Lean module of its own (`elaborateFile`),
with its module name as the environment's main module, so its private
declarations are its own.

- **Its header is not elaborated.** The session core reads a header's
  imports (`headerImports`, each with the line and column it starts at),
  decides what each names, and hands the file's elaboration the handles of
  the config files it imports. The parser then starts after the header,
  and messages carry the file's own lines. A file that starts with
  `module` is refused: config files are plain modules.
- **With no config import**, it is elaborated on the base's environment
  directly. So it sees every module the base holds, imported or not: the
  editor accepts a file that Lean's language server would reject for a
  missing `import Lean`, once another file made the base hold it.
- **With config imports**, it gets an environment of its own
  (`environmentOver`): the base's import state, plus the module files of
  the config files it is handed, all of them, the ones it reaches through
  others too. So it sees only the config files it imports, and an `open`
  or a `namespace` of one of them does not reach it.
- Lean's messages become diagnostics tagged with the file's path, and a
  file with an error leaves no handle.

A file may not declare `initialize`. Such a file elaborates, but the
interpreter throws a C++ exception the first time a declaration that reads
the constant is evaluated, and an exception from the interpreter ends the
process (`Editor/Ffi.lean`). This one can be refused before any code runs,
so the adapter rejects the file with a diagnostic that points at the
store, which is where config keeps state.

## Module files

A config file other than the root that elaborates has its module data
written (`Lean.writeModule`) so that the files that import it can import
it: about 1 ms and tens of kilobytes. Its handle is the module's name and
that file. Each version of a file is written at a path of its own, in a
directory the host gives (`ModuleFiles`), and never overwritten: an
environment that imported an earlier version may still be alive, and its
file still mapped. The root's handle is its environment: nothing imports
a root.

A module file is read again for each environment that imports it, and the
memory it is read into is never freed: freeing it is unsafe while a
closure of an old config may be alive. That is a small leak for each
reload that elaborates a file with config imports
(`docs/design/lean-runtime.md`, "Config and reload").

## `setup`

The `setup` the editor runs is the constant `setup` the root itself
declares. A root that declares none is refused with a diagnostic that
says so, also when a config file it imports declares one, which the
diagnostic names (`noSetup`). After the root the adapter elaborates a
trailer, `def «editor.setup» : Editor.SetupM Unit := _root_.setup`, so the
elaborator checks `setup` at the type the editor runs. It then evaluates
that one constant at that type: the only unchecked evaluation of a
reload. A `setup` of another type is a diagnostic from the trailer. A
`setup` that depends on `sorry` is an error value from the evaluation,
and nothing runs.

Commands are not looked up here. A command is the value `setup` registered.

## Lean internals this rests on

`Lean.importModulesCore` on a retained `Lean.ImportState`,
`Lean.finalizeImport`, `Lean.ImportArtifacts`, `Lean.writeModule`,
`Lean.Parser.parseHeader`, `Lean.Elab.IO.processCommands` and
`Lean.Environment.evalConst`. A toolchain bump can change any of them
(`docs/design/lean-runtime.md`).

## Tests

`config-test` runs the checks of this adapter (`ConfigTest.elaboratorChecks`)
and holds it to the port's contract (`ConfigTest.elaboratorContractChecks`).
The session core's own tests run on the port's model.
-/

namespace Editor.Config.Elaborate

/-- Where the adapter finds what it imports, and what that is. -/
structure Settings where
  /-- The Lean toolchain's directory: its modules are under `lib/lean`. -/
  sysroot : System.FilePath
  /-- The directories holding the `.olean` files of the base's modules,
  in the order they are searched: the core's, and each package's whose
  modules the base holds. -/
  oleanDirs : List System.FilePath
  /-- The modules the base starts as. The core's is `Editor`; the editor's
  adds the entry module of each package of its set, and tests and the
  benchmark add to it. -/
  imports : Array Lean.Name := #[`Editor]

/-- The options every elaboration runs with: synchronously, so that every
message is in the state the frontend returns. -/
def options : Lean.Options :=
  ({} : Lean.Options).setBool `Elab.async false

/-- Elaborates `text` on `state` and returns the state after it, with only the
messages of this text. `source` is the file name the messages carry. -/
def elaborate (state : Lean.Elab.Command.State) (source text : String) :
    IO Lean.Elab.Command.State := do
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

/-- Evaluates the trailer's constant. It is `unsafe` because evaluating a
constant trusts the type it is given; the elaborator has just checked the
trailer at this type. -/
unsafe def evalSetupUnsafe (environment : Lean.Environment) : Except String (SetupM Unit) :=
  environment.evalConst (SetupM Unit) options trailerName

/-- The `setup` program of the config `environment` holds, or why it cannot be
evaluated. -/
@[implemented_by evalSetupUnsafe]
opaque evalSetup (environment : Lean.Environment) : Except String (SetupM Unit)

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
  /-- Removes the directory and what is in it, if it was made. Only when no
  environment that read a file of it is in use any more: when the host has
  ended. -/
  remove : IO Unit := pure ()

/-- Module files in the directory `make` makes, which is called once, when
the first file is written. `remove` removes that directory when it was
made, with `removeMade`. -/
def ModuleFiles.over (make : IO System.FilePath)
    (removeMade : System.FilePath → IO Unit := fun _ => pure ()) : IO ModuleFiles := do
  let made ← IO.mkRef (none : Option System.FilePath)
  let count ← IO.mkRef 0
  return {
      directory := do
        if let some directory← made.get then
          return directory
        let directory ← make
        made.set (some directory)
        return directory,
      next := count.modifyGet fun count => (count, count + 1),
      remove := do
        if let some directory← made.modifyGet fun made => (made, none) then
          removeMade directory }

/-- Module files in a temporary directory, made by `make` when the first
file is written and removed, with what is in it, by `remove`: what an
executable's host uses, with the default `make`, which makes a directory of
the system's. A test hands a `make` that makes one under a directory of its
own. A process that ends without `remove`, one that crashed, leaves the
directory to the system's cleaning of its temporary files. -/
def ModuleFiles.temporary (make : IO System.FilePath := IO.FS.createTempDir) : IO ModuleFiles :=
  ModuleFiles.over make IO.FS.removeDirAll

/-- The first components of the modules of the Lean toolchain that are
linked into every executable that links this adapter: it imports `Lean` and
`Std`, which import `Init`. -/
def toolchainRoots : Array Lean.Name :=
  #[`Init, `Std, `Lean]

/-- Whether `base` holds `module`. -/
def Base.holds (base : Base) (module : Lean.Name) : Bool :=
  (base.environment.getModuleIdx? module).isSome

/-- The components of the module name `module`, unescaped. -/
def components (module : Lean.Name) : List String :=
  (module.toString (escape := false)).splitOn "."

/-- What looking `module` up on `base` finds: whether a config file may
import it. It is linked when the base holds it, or when it is a module of
`Init`, `Std` or `Lean` (`toolchainRoots`) whose `.olean` file is in the
toolchain: every such module is linked into the executable, so reading it
runs no initialiser. The name is exact about case, whatever the file
system makes of it (`Editor/Config/ExactPath.lean`): a name that is a
module's of the base, or a module file's of the toolchain, but for the
case of its letters is that module misspelt. The toolchain is asked only
for a module the base does not hold. -/
def linkedAs (settings : Settings) (base : Base) (module : Lean.Name) : IO (Lookup Unit) := do
  if base.holds module then
    return .found ()
  let folded (name : Lean.Name) : String := ExactPath.folded (name.toString (escape := false))
  if let some held := base.environment.header.moduleNames.find? (folded · == folded module) then
    return .misspelt (held.toString (escape := false))
        ("/".intercalate (components held) ++ ".olean")
  unless toolchainRoots.any (folded · == folded module.getRoot) do
    return .absent
  let path :=
    match (components module).reverse with
    | last :: before => (s!"{last}.olean" :: before).reverse
    | [] => []
  match ← ExactPath.find (settings.sysroot / "lib" / "lean") path with
  | .exact =>
    return .found ()
  | .absent =>
    return .absent
  | .spelled found =>
    let file := "/".intercalate found
    let spelling := ".".intercalate found
    return .misspelt
        (if spelling.endsWith ".olean" then (spelling.dropEnd 6).toString else spelling) file

/-- Whether a config file may import `module` on `base` (`linkedAs`). -/
def isLinked (settings : Settings) (base : Base) (module : Lean.Name) : IO Bool :=
  return (← linkedAs settings base module).isFound

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
search path is set before each import. -/
def grow (settings : Settings) (earlier : Option Base) (modules : Array Lean.Name) : IO Base := do
  -- Set for every import, not once: another elaborator of the process, a
  -- test's, may have set its own since.
  Lean.searchPathRef.set settings.searched
  let base ←
    match earlier with
    | some base =>
      pure base
    | none =>
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
def headerImports (path text : String) : IO (Except (Array Diagnostic) (Array Import)) := do
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
def elaborateFile (base : Base) (handles : Array Handle) (file : SourceFile) :
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
  s!"{rootPath} defines no `setup`: the editor runs the `setup` the root itself defines, at the type `Editor.SetupM Unit`, and no other{elsewhere}; a config file the root imports exports its programs under other names, and the root's `setup` calls them"

/-- The real elaborator, over `settings`, which writes the module data of
config files through `files`. -/
def elaborator (settings : Settings) (files : ModuleFiles) : Elaborator Base Handle :=
  { imports := fun file => headerImports file.path file.text,
    base := fun earlier modules => grow settings earlier (modules.map String.toName),
    linked := fun base module => linkedAs settings base module.toName,
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
