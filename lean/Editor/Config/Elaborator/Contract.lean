import Editor.Config.Session

/-!
# The contract of the elaborator port

What every implementation of the elaborator port (`Config.Elaborator`,
`Editor/Config/Session.lean`) answers, as one list of properties. The
model (`Editor/Config/Elaborator/Model.lean`) is held to it by
`model-test`, and the real adapter over Lean's elaborator
(`Editor/Config/Elaborate.lean`) runs the same list in `config-test`, so
neither can drift from the other. This module imports only the port, so
the contract never depends on an implementation.

## A file, written for either side

The two sides do not read one language: the model reads its own lines and
the adapter reads Lean. So a property writes a file as `Line`s, and each
side says how a file of those lines is written (`Subject.write`), one
line of text for each, so the line a diagnostic is at is the line's place
in the list. A side also names the modules a property needs: one its
starting base holds and a name that module declares, one that is linked
and that the starting base does not hold, with a name of it, and one that
is not linked.

## What it asks

- **The header.** `imports` gives a header's imports in order, each with
  the line it is on.
- **A file is elaborated like a file.** A name is visible after its
  definition; a use of a name nothing declares is an error tagged with the
  file's path at the line of the use, and leaves no handle; a warning
  leaves a handle.
- **The base.** A file sees what a module the base holds declares. A
  module the base holds is linked, one it can grow to hold is linked, and
  another is not. A name is exact about case: a linked module's name
  written in another case is not linked, and is found to be that module
  misspelt. A side names its modules with a capital in each, so the small
  letters are another name. A base grown to hold a module lets a file see
  what that module declares, and the base it grew from still elaborates a
  file.
- **Isolation.** A file handed the handle of a config file sees what that
  file defines, and a file not handed it does not, the root as any other.
  A file handed the handles of the files it reaches through others sees
  each. This is what makes it sound for the session core to keep a file
  that imports nothing changed.
- **A handle is one version.** Of two handles of one module made from two
  texts, a file sees the definitions of the one it is handed.
- **`setup` is the root's.** A root that defines `setup` has a program; a
  root that defines none has diagnostics instead, also when a config file
  it imports defines one.

## What it does not ask

What a diagnostic says, and its column. What a file handed some of the
handles it needs, and not all, comes to: the core hands all of them.
-/

namespace Editor.Config.Elaborator.Contract

open Editor.Config

/-- One line of a file a property writes. -/
inductive Line where
  /-- An import of the module. -/
  | «import» (module : String)
  /-- A definition of the name. -/
  | define (name : String)
  /-- A use of the name: an error unless it is visible. -/
  | use (name : String)
  /-- A line that is an error. -/
  | fail
  /-- A line that is a warning. -/
  | warn
  /-- A definition of `setup`, at the type the editor runs. -/
  | setup
  deriving DecidableEq, Repr

/-- An implementation of the port, and how the properties are written for
it. -/
structure Subject (β σ : Type) where
  /-- The implementation. -/
  elaborator : Elaborator β σ
  /-- The text of a file of these lines, one line of text for each. -/
  write : Array Line → String
  /-- A module the starting base holds, and a name it declares, as a `use`
  line names it. -/
  held : String × String
  /-- A linked module the starting base does not hold, and a name it
  declares. -/
  grown : String × String
  /-- A module that is not linked. -/
  unlinked : String

/-- One property of the elaborator port. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the property; `true` when it holds. -/
  holds : IO Bool

namespace Subject

variable {β σ : Type}

/-- The config file `Config.<name>` of `lines`, as the subject writes it. -/
def file (subject : Subject β σ) (name : String) (lines : Array Line) : SourceFile :=
  let module := s!"Config.{name}"
  { module, path := pathOf module, text := subject.write lines }

/-- The root of `lines`, as the subject writes it. -/
def rootFile (subject : Subject β σ) (lines : Array Line) : SourceFile :=
  { module := rootModule, path := rootPath, text := subject.write lines }

/-- The starting base. -/
def start (subject : Subject β σ) : IO β :=
  subject.elaborator.base none #[]

end Subject

/-- Whether `result` elaborated: it has a handle and no error. -/
def elaborated {σ : Type} (result : FileResult σ) : Bool :=
  result.handle.isSome && result.diagnostics.all (·.severity != .error)

/-- Whether `result` failed at `line` of the file at `path`: it has no
handle, and an error tagged with the path at that line. -/
def failedAt {σ : Type} (result : FileResult σ) (path : String) (line : Nat) : Bool :=
  result.handle.isNone &&
    result.diagnostics.any fun diagnostic =>
      diagnostic.severity == .error && diagnostic.source == path && diagnostic.line == line

/-- The handle of `result`, or an error that says the file `what` did not
elaborate. -/
def handleOf {σ : Type} (what : String) (result : FileResult σ) : IO σ :=
  match result.handle with
  | some handle => pure handle
  | none =>
    throw
      (IO.userError
        s!"{what} did not elaborate: {"; ".intercalate (result.diagnostics.map (·.message)).toList}")

/-- The properties of the elaborator port, of `subject`. -/
def properties {β σ : Type} (subject : Subject β σ) : List Property :=
  let elaborator := subject.elaborator
  [{  name := "the imports of a header are its imports in order, each with the line it is on"
      holds := do
        let file :=
          subject.file "Header" #[.import subject.held.1, .import "Config.Other", .define "after"]
        let found ← elaborator.imports file
        return (found.toOption.map (·.map fun wanted => (wanted.module, wanted.line))) ==
            some #[(subject.held.1, 1), ("Config.Other", 2)] },
    { name := "a file with no import has no imports"
      holds := do
        let found ← elaborator.imports (subject.file "Plain" #[.define "alone"])
        return (found.toOption.map (·.size)) == some 0 },
    { name := "a file that defines a name and then uses it elaborates"
      holds := do
        let base ← subject.start
        let result ← elaborator.file base #[] (subject.file "Uses" #[.define "made", .use "made"])
        return elaborated result },
    { name :=
        "a use of a name nothing declares is an error tagged with the file's path at the line of the use, and leaves no handle"
      holds := do
        let base ← subject.start
        let file := subject.file "Unknown" #[.define "made", .use "neverMade"]
        return failedAt (← elaborator.file base #[] file) file.path 2 },
    { name := "a line that fails is an error at its line, and leaves no handle"
      holds := do
        let base ← subject.start
        let file := subject.file "Fails" #[.define "made", .define "other", .fail]
        return failedAt (← elaborator.file base #[] file) file.path 3 },
    { name := "a line that warns is a warning tagged with the file's path, and leaves a handle"
      holds := do
        let base ← subject.start
        let file := subject.file "Warns" #[.warn]
        let result ← elaborator.file base #[] file
        return result.handle.isSome &&
            result.diagnostics.any fun diagnostic =>
              diagnostic.severity == .warning && diagnostic.source == file.path &&
                diagnostic.line == 1 },
    { name := "a file sees what a module the base holds declares"
      holds := do
        let base ← subject.start
        let file := subject.file "Held" #[.import subject.held.1, .use subject.held.2]
        return elaborated (← elaborator.file base #[] file) },
    { name :=
        "a module the base holds is linked, one it can grow to hold is linked, and another is not"
      holds := do
        let base ← subject.start
        return (← elaborator.linked base subject.held.1).isFound &&
            (← elaborator.linked base subject.grown.1).isFound &&
            (← elaborator.linked base subject.unlinked) == .absent },
    { name :=
        "a module's name is exact about case: the name of a module the base holds, and of one it can grow to hold, written with small letters alone is not linked, and is found to be that module misspelt"
      holds := do
        let base ← subject.start
        let spelt (module : String) : IO (Option String) := do
          match ← elaborator.linked base (module.map Char.toLower) with
          | .misspelt spelling _ =>
            return some spelling
          | _ =>
            return none
        return (← spelt subject.held.1) == some subject.held.1 &&
            (← spelt subject.grown.1) == some subject.grown.1 },
    { name :=
        "a base grown to hold a linked module lets a file see what that module declares, and the base it grew from still elaborates a file"
      holds := do
        let base ← subject.start
        let grown ← elaborator.base (some base) #[subject.grown.1]
        let file := subject.file "Grown" #[.import subject.grown.1, .use subject.grown.2]
        let onGrown ← elaborator.file grown #[] file
        let onOld ← elaborator.file base #[] (subject.file "Old" #[.define "made", .use "made"])
        return elaborated onGrown && elaborated onOld },
    { name :=
        "a file handed the handle of a config file sees what that file defines, and a file not handed it does not"
      holds := do
        let base ← subject.start
        let lower ←
          handleOf "the imported file"
              (← elaborator.file base #[] (subject.file "Lower" #[.define "lowerMade"]))
        let upper := subject.file "Upper" #[.import "Config.Lower", .use "lowerMade"]
        return elaborated (← elaborator.file base #[lower] upper) &&
            failedAt (← elaborator.file base #[] upper) upper.path 2 },
    { name :=
        "the root is handed handles as a file is: it sees what a config file it is handed defines, and not what one it is not handed defines"
      holds := do
        let base ← subject.start
        let lower ←
          handleOf "the imported file"
              (← elaborator.file base #[] (subject.file "Lower" #[.define "lowerMade"]))
        let root := subject.rootFile #[.import "Config.Lower", .use "lowerMade"]
        return elaborated (← elaborator.root base #[lower] root) &&
            failedAt (← elaborator.root base #[] root) root.path 2 },
    { name := "a file handed the handles of the files it reaches through others sees each"
      holds := do
        let base ← subject.start
        let lowest ←
          handleOf "the file imported through another"
              (← elaborator.file base #[] (subject.file "Lowest" #[.define "lowestMade"]))
        let middle ←
          handleOf "the file imported"
              (←
                elaborator.file base #[lowest]
                    (subject.file "Middle"
                      #[.import "Config.Lowest", .define "middleMade", .use "lowestMade"]))
        let root :=
          subject.rootFile #[.import "Config.Middle", .use "middleMade", .use "lowestMade"]
        return elaborated (← elaborator.root base #[lowest, middle] root) },
    { name :=
        "a handle is one version of a file: of two handles of one module, a file sees the definitions of the one it is handed"
      holds := do
        let base ← subject.start
        let first ←
          handleOf "the first version"
              (← elaborator.file base #[] (subject.file "Versioned" #[.define "firstMade"]))
        let second ←
          handleOf "the second version"
              (← elaborator.file base #[] (subject.file "Versioned" #[.define "secondMade"]))
        let usesFirst := subject.file "UsesFirst" #[.import "Config.Versioned", .use "firstMade"]
        let usesSecond := subject.file "UsesSecond" #[.import "Config.Versioned", .use "secondMade"]
        return elaborated (← elaborator.file base #[first] usesFirst) &&
            failedAt (← elaborator.file base #[first] usesSecond) usesSecond.path 2 &&
            elaborated (← elaborator.file base #[second] usesSecond) &&
            failedAt (← elaborator.file base #[second] usesFirst) usesFirst.path 2 },
    { name := "a root that defines setup has a setup program"
      holds := do
        let base ← subject.start
        let root ← handleOf "the root" (← elaborator.root base #[] (subject.rootFile #[.setup]))
        return (← elaborator.setup root).toBool },
    { name := "a root that defines no setup has diagnostics in place of a program"
      holds := do
        let base ← subject.start
        let root ←
          handleOf "the root" (← elaborator.root base #[] (subject.rootFile #[.define "other"]))
        match ← elaborator.setup root with
        | .ok _ =>
          return false
        | .error problems =>
          return problems.any (·.severity == .error) },
    { name :=
        "a root that defines no setup has none though a config file it imports defines one: setup is the root's own"
      holds := do
        let base ← subject.start
        let lower ←
          handleOf "the imported file" (← elaborator.file base #[] (subject.file "Sets" #[.setup]))
        let root ←
          handleOf "the root"
              (←
                elaborator.root base #[lower]
                    (subject.rootFile #[.import "Config.Sets", .define "other"]))
        match ← elaborator.setup root with
        | .ok _ =>
          return false
        | .error problems =>
          return problems.any (·.severity == .error) }]

end Editor.Config.Elaborator.Contract
