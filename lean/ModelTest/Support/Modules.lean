import Editor.Config.Elaborator.Contract
import Editor.Config.Elaborator.Model
import Editor.Config.Modules

/-!
# Model tests: support: Modules

The session over modules on the elaborator's model: the model as the
contract's subject, a config written as modules and their lines, a call
log every fake port of a check writes to, an elaborator that records its
calls, and hand-written fakes of the package ports. Shared by several test
modules under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Config.Modules

/-- The elaborator's model as the subject of the port's contract: a file is
the model's lines, `setup` is a definition of that name, the base holds
`Editor`, which declares what is under it, and can grow to hold `Lean`. -/
def modelSubject :
    Config.Elaborator.Contract.Subject Config.Elaborator.Model.Base
      Config.Elaborator.Model.Handle :=
  { elaborator := Config.Elaborator.Model.elaborator,
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
  Config.Elaborator.Model.Base

/-- The handle of the model. -/
abbrev ModelHandle :=
  Config.Elaborator.Model.Handle

/-- `elaborator`, recording each call that makes a base, elaborates or
asks for `setup` in `calls`. Reading a header and asking whether a module
is linked are not recorded: they change nothing. -/
def recording (calls : IO.Ref (Array SessionCall))
    (elaborator : Elaborator ModelBase ModelHandle := Config.Elaborator.Model.elaborator) :
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
it. -/
def configOf (files : List (String × List String)) (stray : List String := []) : Source :=
  let find (module : String) : Option SourceFile :=
    (files.find? (·.1 == module)).map fun (_, lines) =>
      { module, path := if module == rootModule then rootPath else pathOf module,
        text := "\n".intercalate lines }
  { root := pure (find rootModule), file := fun module => pure (find module),
    stray := pure stray.toArray }

/-- A hand-written fake of the package port over `files`, the names and
texts a config directory holds, recording each read in `calls`. A
lakefile's text is read as lines: `require <name>` is a require, and a
text that is `broken` cannot be read. -/
def fakePackage (calls : IO.Ref (Array SessionCall)) (files : IO.Ref (Array (String × String))) :
    Package :=
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
    (set : Option Config.LakePackage.Set) (pin : String := "leanprover/lean4:v1\n")
    (broken : Bool := false) : Generator :=
  {
    create := fun name text => do
      calls.modify (·.push (.create name))
      if broken then
        throw (IO.userError "the fake directory cannot be written")
      files.modify fun files => if files.any (·.1 == name) then files else files.push (name, text),
    pin, set }

end ModelTest
