import Editor.Config.Session

/-!
# The elaborator port's model

A pure model of the elaborator port (`Config.Elaborator`,
`Editor/Config/Session.lean`): what turning a config file into a module
comes to, with no elaborator in it. The session core's tests run on it
(`ModelTest.sessionChecks`), and the contract
(`Editor/Config/Elaborator/Contract.lean`) holds it and the real adapter
(`Editor/Config/Elaborate.lean`) to the same properties, so the model
cannot drift from Lean's elaborator in what the core rests on.

## The language

A file of the model is lines, and each line is one of these; a blank line
is nothing:

- `import <module>`: an import of the header. The header is the imports at
  the start of the file; an `import` after any other line is an error.
- `define <name>`: declares a name.
- `use <name>`: an error unless the name is visible.
- `fail`: an error.
- `warn`: a warning. The file still elaborates.

Any other line is an error. A diagnostic is tagged with the file's path,
at the line it is about and column 0.

## What a file sees

A name is visible on a line when an earlier line of the file defines it,
when a config file whose handle the elaboration was handed defines it, or
when it is under a module the base holds: `Lean.thing` on a base that
holds `Lean`. A file does not see what a config file defines unless it is
handed that file's handle, whatever its header says: the session core
hands a file the handles of the config files it imports, and that is what
makes a file that imports nothing changed safe to keep.

## The base

A base is the modules it holds. It starts as `Settings.held`, and grows by
the modules it is asked to hold. A module is linked when the base holds it
or when its first component is one of `Settings.linkable`; asking for a
base to hold a module that is not linked throws.

## `setup`

A root has a `setup` program when the root itself defines `setup`, and the
program is `Settings.setup`. A `setup` a config file it imports defines is
not the root's.
-/

namespace Editor.Config.Elaborator.Model

open Editor.Config

/-- The model's base: the linked modules it holds, in the order they were
asked for. -/
structure Base where
  /-- The modules. -/
  modules : Array String
  deriving DecidableEq, Repr

/-- The model's handle of a config file that elaborated. -/
structure Handle where
  /-- The file's module name. -/
  module : String
  /-- The names the file defines, in order. -/
  defines : Array String
  deriving DecidableEq, Repr

/-- What the model is made of. -/
structure Settings where
  /-- The modules the base holds to start with. -/
  held : Array String := #["Editor"]
  /-- The first components of the modules a base can grow to hold. -/
  linkable : Array String := #["Init", "Std", "Lean"]
  /-- The program a root that defines `setup` has. -/
  setup : SetupM Unit := pure ()

/-- One line of a file of the model. -/
inductive Line where
  /-- An import of the module. -/
  | «import» (module : String)
  /-- A definition of the name. -/
  | define (name : String)
  /-- A use of the name. -/
  | use (name : String)
  /-- An error. -/
  | fail
  /-- A warning. -/
  | warn
  /-- Nothing: a blank line. -/
  | blank
  /-- A line the language does not have. -/
  | unknown
  deriving DecidableEq, Repr

/-- The line `text` is. -/
def Line.read (text : String) : Line :=
  match (text.splitOn " ").filter (!·.isEmpty) with
  | [] => .blank
  | ["import", module] => .import module
  | ["define", name] => .define name
  | ["use", name] => .use name
  | ["fail"] => .fail
  | ["warn"] => .warn
  | _ => .unknown

/-- The lines of `text`, each with its number, from 1. -/
def numbered (text : String) : List (Nat × Line) :=
  ((text.splitOn "\n").map Line.read).zipIdx.map fun (line, index) => (index + 1, line)

/-- The diagnostic of the model about line `line` of `file`. -/
def diagnostic (file : SourceFile) (line : Nat) (severity : Severity) (message : String) :
    Diagnostic :=
  { source := file.path, line, severity, message }

/-- The imports of `file`'s header: the `import` lines before any other
line that is not blank. -/
def header (file : SourceFile) : Array Import :=
  let lines := (numbered file.text).filter (·.2 != .blank)
  (lines.takeWhile fun (_, line) => line matches .import _).toArray.filterMap fun (number, line) =>
    match line with
    | .import module => some { module, line := number, column := 0 }
    | _ => none

/-- Whether `module` is linked: `base` holds it, or its first component is
one of `settings.linkable`. -/
def isLinked (settings : Settings) (base : Base) (module : String) : Bool :=
  base.modules.contains module || settings.linkable.contains (Lakefile.rootOf module)

/-- Whether `name` is visible on `base`: it is under a module the base
holds. -/
def Base.declares (base : Base) (name : String) : Bool :=
  base.modules.any fun module => name.startsWith (module ++ ".")

/-- Elaborates `file` on `base` over the handles `handles`: its
diagnostics, and its handle unless one of them is an error. -/
def elaborate (base : Base) (handles : Array Handle) (file : SourceFile) : FileResult Handle :=
  let (diagnostics, defines, _) :=
    (numbered file.text).foldl
      (fun (diagnostics, defines, inHeader) (number, line) =>
        let problem (message : String) : Array Diagnostic :=
          diagnostics.push (diagnostic file number .error message)
        match line with
        | .blank => (diagnostics, defines, inHeader)
        | .import _ =>
          if inHeader then (diagnostics, defines, true)
          else (problem "an import after the header", defines, false)
        | .define name => (diagnostics, defines.push name, false)
        | .use name =>
          let visible :=
            defines.contains name || handles.any (·.defines.contains name) || base.declares name
          if visible then (diagnostics, defines, false)
          else (problem s!"unknown name `{name}`", defines, false)
        | .fail => (problem "the file was told to fail", defines, false)
        | .warn =>
          (diagnostics.push (diagnostic file number .warning "the file was told to warn"), defines,
            false)
        | .unknown => (problem "a line the model does not have", defines, false))
      ((#[] : Array Diagnostic), (#[] : Array String), true)
  let failed := diagnostics.any (·.severity == .error)
  { diagnostics, handle := if failed then none else some { module := file.module, defines } }

/-- The model as an elaborator. -/
def elaborator (settings : Settings := {}) : Elaborator Base Handle :=
  { imports := fun file => pure (.ok (header file)),
    base := fun given modules => do
      let base : Base := given.getD { modules := settings.held }
      for module in modules do
        unless isLinked settings base module do
          throw (IO.userError s!"module `{module}` is not linked")
      return {
          modules :=
            modules.foldl
              (fun held module => if held.contains module then held else held.push module)
              base.modules },
    linked := fun base module => pure (isLinked settings base module),
    file := fun base handles file => pure (elaborate base handles file),
    root := fun base handles file => pure (elaborate base handles file),
    setup := fun handle =>
      if handle.defines.contains "setup" then pure (.ok settings.setup)
      else
        pure
          (.error
            #[failure "setup"
                "the root defines no `setup`: the editor runs the `setup` the root itself defines, and no other"]) }

end Editor.Config.Elaborator.Model
