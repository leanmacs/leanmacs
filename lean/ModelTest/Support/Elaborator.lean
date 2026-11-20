import Editor.Appearance
import Editor.Config.Diagnostic
import Editor.Config.Elaborator.Contract
import Editor.Config.Elaborator.Model
import Editor.Config.LakePackage
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Config.Session
import Editor.Program
import Editor.Setup

/-!
# Model tests: support: Elaborator

The config session on the elaborator's model: the model as the contract's
subject, a config written as modules and their lines, a call log every
fake port of a check writes to, an elaborator that records its calls,
hand-written fakes of the package ports, and what the checks of the reload
reducer are written with: outcomes built by hand and an effect as a check
compares it. Shared by several test modules under `ModelTest/Editor/`; it
holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Config

/-- The elaborator's model as the subject of the port's contract: a file is
the model's lines, `setup` is a definition of that name, the base holds
`Editor`, which declares what is under it, and can grow to hold `Lean`. -/
def modelSubject : Elaborator.Contract.Subject Elaborator.Model.Base Elaborator.Model.Handle :=
  { elaborator := Elaborator.Model.elaborator,
    write := fun lines =>
      "\n".intercalate
        (lines.map fun line =>
            match line with
            | .import module => s!"import {module}"
            | .define name => s!"define {name}"
            | .use name => s!"use {name}"
            | .fail => "fail"
            | .warn => "warn"
            | .setup => "define setup").toList,
    held := ("Editor", "Editor.thing"), grown := ("Lean", "Lean.thing"), unlinked := "Lake" }

/-- A call a fake port of a check received. -/
inductive SessionCall where
  /-- A base was asked for, to hold `modules`: made, or `grown` from one
  that was handed in. -/
  | base (grown : Bool) (modules : Array String)
  /-- The config file `module` was elaborated over the handles of
  `handles`. -/
  | file (module : String) (handles : Array String)
  /-- The root was elaborated over the handles of `handles`. -/
  | root (handles : Array String)
  /-- The `setup` program was asked for. -/
  | setup
  /-- The file of the config directory called `name` was read. -/
  | read (name : String)
  /-- The file of the config directory called `name` was created. -/
  | create (name : String)
  deriving DecidableEq, Repr

/-- The base of the model. -/
abbrev ModelBase :=
  Elaborator.Model.Base

/-- The handle of the model. -/
abbrev ModelHandle :=
  Elaborator.Model.Handle

/-- `elaborator`, recording each call that makes a base, elaborates or
asks for `setup` in `calls`. Reading a header and asking whether a module
is linked are not recorded: they change nothing. -/
def recording (calls : IO.Ref (Array SessionCall))
    (elaborator : Elaborator ModelBase ModelHandle := Elaborator.Model.elaborator) :
    Elaborator ModelBase ModelHandle :=
  { elaborator with
    base := fun given modules => do
      calls.modify (·.push (.base given.isSome modules))
      elaborator.base given modules,
    file := fun base handles file => do
      calls.modify (·.push (.file file.module (handles.map (·.module))))
      elaborator.file base handles file,
    root := fun base handles file => do
      calls.modify (·.push (.root (handles.map (·.module))))
      elaborator.root base handles file,
    setup := fun handle => do
      calls.modify (·.push .setup)
      elaborator.setup handle }

/-- A source over `files`, each a module name and the lines of its text,
the root being the module `init`, with `stray` as the `.lean` files beside
it. A config file is found by exactly its module name; a name that differs
from a file's only in the case of its letters is that file misspelt. -/
def configOf (files : List (String × List String)) (stray : List String := []) : Source :=
  let find (module : String) : Option SourceFile :=
    (files.find? (·.1 == module)).map fun (_, lines) =>
      { module, path := if module == rootModule then rootPath else pathOf module,
        text := "\n".intercalate lines }
  { root := pure (find rootModule),
    file := fun module =>
      match find module with
      | some file => pure (.found file)
      | none =>
        match files.find? fun (other, _) => other.map Char.toLower == module.map Char.toLower with
        | some (other, _) => pure (.misspelt other (pathOf other))
        | none => pure .absent,
    stray := pure stray.toArray }

/-- A hand-written fake of the package port over `files`, the names and
texts a config directory holds, recording each read in `calls`. A
lakefile's text is read as lines: `require <name>` is a require, and a
text that is `broken` cannot be read. -/
def fakePackage (calls : IO.Ref (Array SessionCall)) (files : IO.Ref (Array (String × String))) :
    PackageFiles :=
  {
    read := fun name => do
      calls.modify (·.push (.read name))
      return ((← files.get).find? (·.1 == name)).map (·.2),
    requires := fun text =>
      if text == "broken" then pure (.error "the fake lakefile is broken")
      else
        pure
          (.ok
            ((text.splitOn "\n").filterMap fun line =>
                match line.splitOn " " with
                | ["require", name] => some name
                | _ => none).toArray) }

/-- A hand-written fake of the generator port over `files`, for an editor
whose pin is `pin` and which was built from `set`: it adds a file that is
not there to `files` and leaves one that is, recording each call in
`calls`. With `broken` it throws in place of creating. -/
def fakeGenerator (calls : IO.Ref (Array SessionCall)) (files : IO.Ref (Array (String × String)))
    (set : Option LakePackage.Set) (pin : String := "leanprover/lean4:v1\n")
    (broken : Bool := false) : Generator :=
  {
    create := fun name text => do
      calls.modify (·.push (.create name))
      if broken then
        throw (IO.userError "the fake directory cannot be written")
      files.modify fun files => if files.any (·.1 == name) then files else files.push (name, text),
    pin, set }

/-- The config half of the editor's state over the model's base and
handle: what the checks of the reload reducer reduce. -/
abbrev ModelState :=
  Config.State ModelBase ModelHandle

/-- An event of the reload reducer over the model's base and handle. -/
abbrev ModelEvent :=
  Config.Event ModelBase ModelHandle

/-- What one reload came to, over the model's base and handle. -/
abbrev ModelOutcome :=
  Config.Outcome ModelBase ModelHandle

/-- The diagnostic a check says the elaborator gave for `source`. -/
def told (source : String) (severity : Config.Severity) : Config.Diagnostic :=
  { source, line := 1, severity, message := "the fake was told to" }

/-- The files a config has loaded once the files called `names` are, each
with its name as its module, its path and its text, and a handle that
defines nothing. Built by hand: no elaborator ran. -/
def loaded (names : List String) : Array (LoadedFile ModelHandle) :=
  names.toArray.map fun name =>
    { file := { module := name, path := name, text := name },
      handle := { module := name, defines := #[] } }

/-- An effect of the reload reducer, as a check compares it: a start with
the modules of the base and the modules of the files it carries, the
cancelling of an owner's jobs with the owner's name, a report with its
number, whether it installed, the sources of its diagnostics, and its
counts of files and commands, a switch of theme, an appearance asked, or
the start of a package-set build or what was said of one. -/
inductive Seen where
  /-- A job was started. -/
  | start (base : Option (Array String)) (files : Array String)
  /-- The jobs of the owner called `owner` were cancelled. -/
  | cancelJobs (owner : String)
  /-- A reload was reported. -/
  | report (number : Nat) (installed : Bool) (sources : Array String) (files commands : Nat)
  /-- The theme in force was switched. -/
  | themed
  /-- The window was asked for this appearance. -/
  | appearance (appearance : Appearance)
  /-- The package-set build was started with this order. -/
  | buildPackages (order : PackageSet.Order)
  /-- This was said of the package set. -/
  | say (text : String)
  deriving DecidableEq, Repr

/-- `effect` as a check compares it. -/
def seen : Config.Effect ModelBase ModelHandle → Seen
  | .start base files => .start (base.map (·.modules)) (files.map (·.file.module))
  | .cancelJobs owner => .cancelJobs owner.name
  | .report report =>
    .report report.number report.installed (report.diagnostics.map (·.source)) report.files
      report.commands
  | .themed => .themed
  | .appearance appearance => .appearance appearance
  | .buildPackages order => .buildPackages order
  | .say text => .say text

/-- The outcome of a reload that built the files called `names`, whose
`setup` is `setup`, on a base that holds no module. Built by hand: no
elaborator ran. -/
def accepted (names : List String) (setup : SetupM Unit) : ModelOutcome :=
  { base := some { modules := #[] }, diagnostics := #[],
    built :=
      (Config.Registrations.ofSetup setup).toOption.map fun registrations =>
        { files := loaded names, registrations } }

/-- The outcome of a reload that was rejected with one error from `source`. -/
def rejected (source : String) : ModelOutcome :=
  { base := some { modules := #[] }, diagnostics := #[told source .error], built := none }

end ModelTest
