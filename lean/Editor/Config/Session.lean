import Editor.Config.Diagnostic
import Editor.Config.LakePackage
import Editor.Config.Lakefile
import Editor.Config.Registry

/-!
# The config session: what one reload builds

A config is a directory of Lean modules: a root, `init.lean`, and the
config files it imports, directly or through others, each a module of its
own under `Config/` (`Config/Keys.lean` is the module `Config.Keys`). Lean
environments are immutable and a declaration cannot be redefined, so a
reload builds a new config from the files as they now are. `build` is one
reload, from reading the source to the registrations of the new config's
`setup`. It installs nothing: it returns an `Outcome`, and the reducer
(`Editor/Config/Reload.lean`) decides what becomes of it.

The decisions are here, in plain Lean with no elaborator in it:

- **What a config is.** The files reached from the root by imports of
  config files. A file under `Config/` that nothing imports is not read.
- **What a file may import.** An import is one of three things.
  `Config.<…>` names a config file; a file that is not there is a
  diagnostic at the import. A module that is linked into the editor
  (`Elaborator.linked`) is loaded with the base. Anything else is refused,
  at the import, naming the module; when the module belongs to a package
  the config's lakefile requires (`Lakefile.owner?`), the diagnostic says
  the editor's package set needs a rebuild. An import cycle among config
  files is refused, naming the cycle. Every header is read, and every
  problem found, before anything is elaborated.
- **A module's name is exact about case.** On a file system that ignores
  case, a path spelt in another case opens the same file, so `import
  Config.keys` would load `Config/Keys.lean` under a module name its file
  does not have, and load nowhere else. The ports look a module up by
  exactly its name (`Lookup`), and an import whose name is another
  module's but for case is refused at the import, naming the file found
  and the spelling to use (`misspelt`).
- **What is elaborated.** Each file is a module of its own, elaborated
  after the config files it imports and handed the handles of all of them,
  the ones it reaches through others too (`order`, `reach`). A loaded file
  is kept when its text is unchanged and every config file it imports is
  kept (`plan`); every other file is elaborated again. So a change
  re-elaborates that file and the files that import it, and no other. The
  base is no part of that rule: a module built on a smaller base is still
  valid beside a larger one.
- **The base grows.** The base starts as what the elaborator's `base`
  gives with no module named, and a reload whose files import linked
  modules asks for a base that holds them, grown from the one it has. A
  reload that is handed the base does not import it again, and every
  outcome hands the base back, whether the config was built or not.
- **All or nothing.** A file that fails ends the reload: no later file is
  elaborated and `setup` is not run.
- **`setup` runs last, here, and it is the root's.** The config's `setup`
  program is produced from the root's handle and run against the
  collecting handler (`Registrations.ofSetup`), on the thread that runs
  `build`. A `setup` that throws, or registers something that is refused,
  rejects the reload. `build` is given the host's input scheme, and
  refuses too what is wrong under its leaders
  (`Registrations.problemUnder?`): two bindings whose keys expand to one
  sequence.
- **The old form is refused.** A directory with no root that holds `.lean`
  files directly in it is a config in the form of byte-ordered chunks with
  no header. It is rejected with one diagnostic that names the files and
  the command that converts them (`oldForm`). A directory with no root and
  no such file is an empty config.
- **Failure is data.** A rejected outcome carries diagnostics. A port that
  throws is a rejected outcome too, with a diagnostic that names what was
  being done.

## The ports

`build` reaches the outside through ports, each a record of functions:

- `Elaborator β σ` turns text into modules. A `β` is a base, the linked
  modules config is elaborated on, and a `σ` the handle of a config file
  that elaborated. The core never looks inside either. Its real adapter
  links Lean's elaborator (`Editor/Config/Elaborate.lean`), and its pure
  model (`Editor/Config/Elaborator/Model.lean`) is what the core's tests
  run on; one contract holds the two together
  (`Editor/Config/Elaborator/Contract.lean`).
- `Source` is where the files come from. Its real adapter reads a
  directory (`Editor/Config/Directory.lean`).

The core imports no adapter, and nothing of Lean's elaborator. Two modules
of the editor link Lean's parser and elaborator, each the adapter of a
port defined here: `Editor/Config/Elaborate.lean`, of the elaborator port,
and `Editor/Config/Lakefile/Toml.lean`, which answers
`PackageFiles.requires` with Lake's TOML loader
(`docs/design/overview.md`, "Rules of the boundary").

## The package ports

A config directory is also a Lake package (`Editor/Config/LakePackage.lean`),
and `build` reaches that side of it through two more ports. They are two
because reading and writing are two capabilities, and a host may have the
first without the second:

- `PackageFiles` reads: a file of the directory by its name, and the names a
  lakefile's text requires. Every host passes it. `build` reads the
  lakefile through it when an import names a module that is not linked, to
  say whether the package set needs a rebuild. `PackageFiles.none` holds no
  file, for a host with no directory.
- `Generator` writes: it creates a file that is not there, and carries the
  editor's toolchain pin and the package set it was built from. A host
  passes it only when it may write into the config directory: the window
  mode, and the headless mode when asked (`--generate`). `build` then
  creates the lakefile and the toolchain file a directory lacks
  (`LakePackage.actions`), after the headers are read and before anything
  is elaborated. A host that passes none writes nothing, and a config
  directory under `tests/` is never written to.
-/

namespace Editor.Config

/-- A config file as the source holds it. -/
structure SourceFile where
  /-- The file's module name: `init` for the root, `Config.Keys` for
  `Config/Keys.lean`. -/
  module : String
  /-- The file's path in the config directory, which a diagnostic about it
  is tagged with: `init.lean`, `Config/Keys.lean`. -/
  path : String
  /-- The file's Lean source. -/
  text : String
  deriving DecidableEq, Repr

/-- The module name of a config's root. -/
def rootModule : String :=
  "init"

/-- The path of a config's root in the config directory. -/
def rootPath : String :=
  "init.lean"

/-- The path, in the config directory, of the config file whose module is
`module`: `Config/Keys.lean` for `Config.Keys`. -/
def pathOf (module : String) : String :=
  "/".intercalate (module.splitOn ".") ++ ".lean"

/-- Whether `module` names a config file other than the root: a module
under `Config`, as `Config.Keys` is. `Config` itself is not one: the
library of a config directory is the modules under it. -/
def isConfigModule (module : String) : Bool :=
  match module.splitOn "." with
  | "Config" :: _ :: _ => true
  | _ => false

/-- What looking a module up by its name found. A module's name is exact
about the case of its letters, whatever the file system is: on one that
ignores case a path spelt in another case opens the same file, and a
config that loads there must load, or be refused, everywhere alike. So a
port that looks a module up says when the name it was asked for is another
module's but for case, and loads nothing. -/
inductive Lookup (α : Type) where
  /-- The module is there, under exactly this name. -/
  | found (value : α)
  /-- There is no such module. -/
  | absent
  /-- No module has exactly this name, and one has a name that differs from
  it only in the case of its letters: `spelling` is that module's name, and
  `file` the file found for it, as a diagnostic names it. -/
  | misspelt (spelling file : String)
  deriving DecidableEq, Repr

/-- Whether the lookup found the module under exactly the name asked
for. -/
def Lookup.isFound {α : Type} : Lookup α → Bool
  | .found _ => true
  | _ => false

/-- The port a config's source is read through. -/
structure Source where
  /-- The root as it now is, or none when the config has none. Throws when
  it cannot be read. -/
  root : IO (Option SourceFile)
  /-- The config file whose module name is exactly this, as it now is;
  absent when there is no such file; misspelt when a file is there whose
  module name differs from this one only in case. Throws when it cannot be
  read. -/
  file : String → IO (Lookup SourceFile)
  /-- The names of the `.lean` files directly in the config directory other
  than the root, in the byte order of their names: what a config in the old
  form is made of. Throws when they cannot be listed. -/
  stray : IO (Array String)

/-- One import of a file's header. -/
structure Import where
  /-- The module the import names. -/
  module : String
  /-- The line the import is on, from 1. -/
  line : Nat
  /-- The column the import starts at, from 0. -/
  column : Nat
  deriving DecidableEq, Repr

/-- What elaborating one file gave. -/
structure FileResult (σ : Type) where
  /-- What the elaborator had to say: errors, and warnings as well. -/
  diagnostics : Array Diagnostic
  /-- The handle of the module the file elaborated to; `none` when the file
  failed, and then `diagnostics` holds an error. -/
  handle : Option σ

/-- The port config is elaborated through. A `β` is a base, the linked
modules config is elaborated on; a `σ` is the handle of a config file that
elaborated. -/
structure Elaborator (β σ : Type) where
  /-- The imports of a file's header, in order, or why the header cannot be
  read. It reads the header alone. -/
  imports : SourceFile → IO (Except (Array Diagnostic) (Array Import))
  /-- The base that holds at least the linked modules named, grown from the
  base given, or made when none is given: with none given and no module
  named, the base config starts on. Throws when it cannot be made. -/
  base : Option β → Array String → IO β
  /-- Whether the module called exactly this is linked into the editor, so
  that a config file may import it: one the base holds, or one the base can
  grow to hold. Misspelt when no module of that name is linked and one is
  whose name differs from it only in case. -/
  linked : β → String → IO (Lookup Unit)
  /-- Elaborates a config file other than the root as a module on the base,
  over the handles of the config files it imports, all of them, the ones
  it reaches through others too, each after the ones it imports. -/
  file : β → Array σ → SourceFile → IO (FileResult σ)
  /-- Elaborates the root, as `file` does a config file: nothing imports
  it, and its handle is the one `setup` is asked of. -/
  root : β → Array σ → SourceFile → IO (FileResult σ)
  /-- The `setup` program the root with this handle itself declares, or why
  there is none. -/
  setup : σ → IO (Except (Array Diagnostic) (SetupM Unit))

/-- The port the config directory is read through as a Lake package ("The
package ports", in the module docs). -/
structure PackageFiles where
  /-- The text of the file of the config directory called this, or none
  when there is no such file. -/
  read : String → IO (Option String)
  /-- The names of the packages a lakefile with this text requires, or why
  the text cannot be read. -/
  requires : String → IO (Except String (Array String))

/-- The package port of a host with no config directory to read: it holds
no file. -/
def PackageFiles.none : PackageFiles :=
  { read := fun _ => pure Option.none, requires := fun _ => pure (.ok #[]) }

/-- The port the config directory's generated files are written through,
with what they are written from ("The package ports", in the module
docs). -/
structure Generator where
  /-- Creates the file of the config directory called by the first with
  the second as its text. It never overwrites: a file that is there stays
  as it is. -/
  create : String → String → IO Unit
  /-- The editor's toolchain pin: the text of its `lean-toolchain`. -/
  pin : String
  /-- The package set the editor was built from, when it knows the set's
  directory. -/
  set : Option LakePackage.Set

/-- A file of a config that was built: its source, and its handle. -/
structure LoadedFile (σ : Type) where
  /-- The file as the source held it. -/
  file : SourceFile
  /-- The handle of the module it elaborated to. -/
  handle : σ

/-- A file of a config and the config files its header imports, in the
header's order. -/
structure Node where
  /-- The file. -/
  file : SourceFile
  /-- Its imports of config files that are there. -/
  imports : Array Import
  deriving DecidableEq, Repr

/-- The diagnostic that `source` failed with `message`, about no place in
particular. -/
def failure (source message : String) : Diagnostic :=
  { source, severity := .error, message }

/-- The diagnostic that the import `wanted` of the file at `path` is
refused with `message`, at the import. -/
def refusal (path : String) (wanted : Import) (message : String) : Diagnostic :=
  { source := path, line := wanted.line, column := wanted.column, severity := .error, message }

/-- What is said of an import of `module`, which is not linked into the
editor, when `owner` is the package of the config's lakefile it belongs
to, if any: with one, that the package set needs a rebuild. -/
def notLinked (module : String) (owner : Option String) : String :=
  match owner with
  | some package =>
    s!"module `{module}` is not linked into this editor: it is a module of the package `{package}`, which the config's lakefile requires, so the editor's package set needs a rebuild with that package in it"
  | none =>
    s!"module `{module}` is not linked into this editor: config may import a config file (`Config.<Name>`), a module of the editor's package set, or a module of `Init`, `Std` or `Lean`"

/-- What is said of an import of `module` when no module has exactly that
name and the module `spelling`, whose file is `file`, differs from it only
in the case of its letters: the file found, and the spelling to use. -/
def misspelt (module spelling file : String) : String :=
  s!"the import of `{module}` finds {file}, the file of the module `{spelling}`: a module's name is exact about the case of its letters, on every file system, so write `import {spelling}`"

/-- What is said of an import of the config file `module` when there is no
such file. -/
def noSuchFile (module : String) : String :=
  s!"there is no config file {pathOf module} for the import of `{module}`"

/-- What is said of an import cycle among config files, `cycle` being its
modules in order, the first again at the end. -/
def cyclic (cycle : Array String) : String :=
  s!"the config files import each other in a cycle: {" imports ".intercalate cycle.toList}"

/-- The command that converts a config in the old form. -/
def migrate : String :=
  "mise run config-migrate"

/-- The diagnostic that rejects a config in the old form: a directory with
no root that holds the files `stray` directly in it. It is one line, and
names the files and the command that converts them. -/
def oldForm (stray : Array String) : Diagnostic :=
  failure "config"
    s!"the config directory holds {", ".intercalate stray.toList} and no {rootPath}: config is a root, {rootPath}, and the modules under Config/ it imports, each with its own header, and files in byte order with no header are no longer loaded; run `{migrate}` to convert the directory"

/-- Visits the node of `module` after the nodes it imports, with `fuel` to
spend, `path` the modules being visited, innermost first, and `done` the
nodes visited so far. The cycle, when `module` is on `path`. -/
def visit (nodes : Array Node) :
    Nat → List String → String → Array Node → Except (Array String) (Array Node)
  | 0, _, _, done => .ok done
  | fuel + 1, path, module, done =>
    if done.any (·.file.module == module) then .ok done
    else
      if path.contains module then
        .error (#[module] ++ (path.takeWhile (· != module)).reverse.toArray ++ #[module])
      else
        match nodes.find? (·.file.module == module) with
        | none => .ok done
        | some node => do
          let mut done := done
          for wanted in node.imports do
            done ← visit nodes fuel (module :: path) wanted.module done
          return done.push node

/-- The nodes reached from the module `root`, each after the nodes it
imports, depth first in the order of each header, so `root` is last; or,
when the imports make a cycle, the cycle: its modules in order, the first
again at the end. A node that imports a module with no node is ordered as
if it did not. -/
def order (nodes : Array Node) (root : String) : Except (Array String) (Array Node) :=
  visit nodes (nodes.size + 1) [] root #[]

/-- The modules `module` reaches by imports among `ordered`, nodes each
after the ones it imports (`order`), in that order and without `module`
itself: the config files whose handles its elaboration is handed. -/
def reach (ordered : Array Node) (module : String) : Array String :=
  let wanted :=
    ordered.foldr
      (fun node wanted =>
        if wanted.contains node.file.module then wanted ++ node.imports.map (·.module) else wanted)
      #[module]
  (ordered.map (·.file.module)).filter fun other => other != module && wanted.contains other

/-- One file of what a reload does: the file, and its handle when the
loaded one is kept. -/
structure Step (σ : Type) where
  /-- The file, with its imports of config files. -/
  node : Node
  /-- The handle the file has loaded, when it is kept as it is; `none`
  when it is to be elaborated. -/
  kept : Option σ

/-- What a reload does, given the files that are `loaded` and the nodes the
source now holds, `ordered` each after the ones it imports: a file is kept
when one of its module is loaded with the same text and every config file
it imports is kept, and elaborated otherwise. -/
def plan {σ : Type} (loaded : Array (LoadedFile σ)) (ordered : Array Node) : Array (Step σ) :=
  ordered.foldl
    (fun steps node =>
      let unchanged :=
        loaded.find? fun file =>
          file.file.module == node.file.module && file.file.text == node.file.text
      let importsKept :=
        node.imports.all fun wanted =>
          steps.any fun step => step.node.file.module == wanted.module && step.kept.isSome
      steps.push { node, kept := if importsKept then unchanged.map (·.handle) else none })
    #[]

/-- A config that a reload built. -/
structure Built (σ : Type) where
  /-- Its files, each after the ones it imports, the root last, each with
  its handle; none for an empty config. -/
  files : Array (LoadedFile σ)
  /-- What its `setup` registers. -/
  registrations : Registrations

/-- What one reload came to. -/
structure Outcome (β σ : Type) where
  /-- The base, if the reload was given it or made it. -/
  base : Option β
  /-- What the reload has to say: the errors that rejected it, warnings and
  information. -/
  diagnostics : Array Diagnostic
  /-- The config, if every file elaborated and its `setup` was accepted;
  `none` when the reload is rejected. -/
  built : Option (Built σ)

/-- An outcome exists for any types: a promise of one can be made before
there is a base. -/
instance {β σ : Type} : Nonempty (Outcome β σ) :=
  ⟨{ base := none, diagnostics := #[], built := none }⟩

/-- A rejected outcome that hands back `base` and says `diagnostics`. -/
def rejectedWith {β σ : Type} (base : Option β) (diagnostics : Array Diagnostic) : Outcome β σ :=
  { base, diagnostics, built := none }

/-- The headers of a config, read from its root outward. -/
structure Headers where
  /-- Each file read, with its imports of config files that are there. -/
  nodes : Array Node := #[]
  /-- The linked modules the files import, each once, in the order they
  were met. -/
  linked : Array String := #[]
  /-- What is wrong with an import or a header. -/
  problems : Array Diagnostic := #[]

/-- What is said of an import of `module`, which is not linked: the
package of the config's lakefile it belongs to is looked for, through
`package`, in a `lakefile.toml`. A directory with no such file, or one
whose text cannot be read, says nothing of the module. -/
def refusedImport (package : PackageFiles) (module : String) : IO String := do
  let owner ←
    try
      match ← package.read LakePackage.lakefileName with
      | some text =>
        match ← package.requires text with
        | .ok required =>
          pure (Lakefile.owner? required module)
        | .error _ =>
          pure none
      | none =>
        pure none
    catch _ =>
      pure none
  return notLinked module owner

/-- Reads the headers of the config whose root is `root`, from the root
outward: each file's imports through `elaborator`, on `base`, and each
config file an import names through `source`. Nothing is elaborated. A
port that throws is a problem at the import, or of the file whose header
was being read. -/
def readHeaders {β σ : Type} (elaborator : Elaborator β σ) (source : Source)
    (package : PackageFiles) (base : β) (root : SourceFile) : IO Headers := do
  let mut headers : Headers := {}
  let mut pending := #[root]
  let mut met := #[root.module]
  let mut next := 0
  while next < pending.size do
    let some file := pending[next]? | break
    next := next + 1
    let found ←
      try
        elaborator.imports file
      catch error =>
        pure (.error #[failure file.path (toString error)])
    match found with
    | .error problems =>
      headers :=
        { headers with
          problems := headers.problems ++ problems,
          nodes := headers.nodes.push { file, imports := #[] } }
    | .ok imports =>
      let mut configImports := #[]
      for wanted in imports do
        let refuse (headers : Headers) (message : String) : Headers :=
          { headers with problems := headers.problems.push (refusal file.path wanted message) }
        if isConfigModule wanted.module then
          if met.contains wanted.module then
            if (pending.any (·.module == wanted.module)) then
              configImports := configImports.push wanted
          else
            met := met.push wanted.module
            let read ←
              try
                Except.ok <$> source.file wanted.module
              catch error =>
                pure (Except.error (toString error))
            match read with
            | .ok (.found imported) =>
              pending := pending.push imported
              configImports := configImports.push wanted
            | .ok .absent =>
              headers := refuse headers (noSuchFile wanted.module)
            | .ok (.misspelt spelling found) =>
              headers := refuse headers (misspelt wanted.module spelling found)
            | .error reason =>
              headers := refuse headers reason
        else
          -- An elaborator that throws has not said the module is linked.
          let linked ←
            try
              elaborator.linked base wanted.module
            catch _ =>
              pure .absent
          match linked with
          | .found () =>
            unless headers.linked.contains wanted.module do
              headers := { headers with linked := headers.linked.push wanted.module }
          | .absent =>
            headers := refuse headers (← refusedImport package wanted.module)
          | .misspelt spelling found =>
            headers := refuse headers (misspelt wanted.module spelling found)
      headers := { headers with nodes := headers.nodes.push { file, imports := configImports } }
  return headers

/-- The diagnostic of the import cycle `cycle` among `nodes` (`order`): at
the import that closes it, the last file's of the first. -/
def cycleProblem (nodes : Array Node) (cycle : Array String) : Diagnostic :=
  let closing : Option (Node × Import) := do
    let last ← cycle[cycle.size - 2]?
    let first ← cycle.back?
    let node ← nodes.find? (·.file.module == last)
    let wanted ← node.imports.find? (·.module == first)
    pure (node, wanted)
  match closing with
  | some (node, wanted) => refusal node.file.path wanted (cyclic cycle)
  | none => failure "config" (cyclic cycle)

/-- Does about the config directory's generated files what
`LakePackage.actions` says, reading what the directory holds through
`package` and writing through `generator`, and returns what there is to
say: its warnings, a file that could not be written as a warning, and its
information. The information, that no lakefile is generated, is said by
every reload that gets here and finds the directory without one: nothing
remembers that it was said, so a reload rejected before this step cannot
swallow it. -/
def generate (package : PackageFiles) (generator : Generator) : IO (Array Diagnostic) := do
  let said (severity : Severity) (message : String) : Diagnostic :=
    { source := "config", severity, message }
  try
    let lakefile :=
      (← package.read LakePackage.lakefileName).isSome ||
        (← package.read LakePackage.leanLakefileName).isSome
    let toolchain ← package.read LakePackage.toolchainName
    let mut diagnostics := #[]
    for action in LakePackage.actions generator.pin generator.set { lakefile, toolchain } do
      match action with
      | .create name text =>
        try
          generator.create name text
        catch error =>
          diagnostics :=
            diagnostics.push
              (said .warning
                s!"{name} could not be written in the config directory: {(toString error).splitOn "\n" |>.headD ""}")
      | .warn message =>
        diagnostics := diagnostics.push (said .warning message)
      | .inform message =>
        diagnostics := diagnostics.push (said .information message)
    return diagnostics
  catch error =>
    return #[said .warning
          s!"the config directory's lakefile and toolchain file could not be read: {(toString error).splitOn "\n" |>.headD ""}"]

/-- One reload: reads the source, refuses what a file may not import,
generates the config directory's lakefile and toolchain file when
`generator` is there and they are not, elaborates the files that changed
and the files that import them, and runs the new config's `setup`, for the
input scheme `scheme`, whose leaders are in force where the config sets
none. `base` is the base if an earlier reload made it, and `loaded` the
files of the config that is installed. -/
def build {β σ : Type} (scheme : InputScheme) (elaborator : Elaborator β σ) (source : Source)
    (package : PackageFiles) (generator : Option Generator) (base : Option β)
    (loaded : Array (LoadedFile σ)) : IO (Outcome β σ) := do
  let base ←
    match base with
    | some base =>
      pure base
    | none =>
      try
        elaborator.base none #[]
      catch error =>
        return rejectedWith none #[failure "base" (toString error)]
  let rejected (diagnostics : Array Diagnostic) : Outcome β σ :=
    rejectedWith (some base) diagnostics
  let root ←
    try
      source.root
    catch error =>
      return rejected #[failure "config" (toString error)]
  let some root := root
    |
    let stray ←
      try
        source.stray
      catch error =>
        return rejected #[failure "config" (toString error)]
    if stray.isEmpty then
      return { base := some base, diagnostics := #[],
               built := some { files := #[], registrations := {} } }
    return rejected #[oldForm stray]
  let headers ← readHeaders elaborator source package base root
  let ordered ←
    match order headers.nodes root.module with
    | .ok ordered =>
      pure ordered
    | .error cycle =>
      return rejected (headers.problems.push (cycleProblem headers.nodes cycle))
  unless headers.problems.isEmpty do
    return rejected headers.problems
  let mut diagnostics ←
    match generator with
    | some generator =>
      generate package generator
    | none =>
      pure #[]
  let grown ←
    if headers.linked.isEmpty then
      pure base
    else
      try
        elaborator.base (some base) headers.linked
      catch error =>
        return rejected (diagnostics.push (failure "base" (toString error)))
  let rejected (diagnostics : Array Diagnostic) : Outcome β σ :=
    rejectedWith (some grown) diagnostics
  let mut files : Array (LoadedFile σ) := #[]
  for step in plan loaded ordered do
    let file := step.node.file
    match step.kept with
    | some handle =>
      files := files.push { file, handle }
    | none =>
      let wanted := reach ordered file.module
      let handles := (files.filter fun other => wanted.contains other.file.module).map (·.handle)
      let result ←
        try
          if file.module == root.module then
            elaborator.root grown handles file
          else
            elaborator.file grown handles file
        catch error =>
          pure { diagnostics := #[failure file.path (toString error)], handle := none }
      diagnostics := diagnostics ++ result.diagnostics
      match result.handle with
      | none =>
        return rejected diagnostics
      | some handle =>
        files := files.push { file, handle }
  let some last :=
    files.back? | return rejected (diagnostics.push (failure "config" "the root was not elaborated"))
  let program ←
    try
      elaborator.setup last.handle
    catch error =>
      pure (.error #[failure "setup" (toString error)])
  match program with
  | .error problems =>
    return rejected (diagnostics ++ problems)
  | .ok setup =>
    match Registrations.ofSetup setup with
    | .error message =>
      return rejected (diagnostics.push (failure "setup" message))
    | .ok registrations =>
      match registrations.problemUnder? scheme with
      | some message =>
        return rejected (diagnostics.push (failure "setup" message))
      | none =>
        return { base := some grown, diagnostics, built := some { files, registrations } }

end Editor.Config
