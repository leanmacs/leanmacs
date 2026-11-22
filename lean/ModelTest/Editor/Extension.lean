import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Extension
import Editor.Package
import Editor.Setup
import Editor.Test.Config
import Editor.Test.Models
import ModelTest.Check
import ModelTest.Editor.Config.Reload
import ModelTest.Support.Elaborator

/-!
# Model tests: `Editor/Extension.lean`

`extensionChecks`. The module is laid out as the three layers would be in
separate Lake packages (`docs/design/extension-points.md`, "Three layers"):
an interface package that declares a protocol, whose type is its extension
point; two implementation packages that register at it; and a consumer
that reads it and names neither implementation.
-/

namespace ModelTest.ExtensionExample

open Editor
open Editor.Test

/-! ## The interface package: `project` -/

/-- What finds the project a path is in: the protocol a project backend
implements, and so the extension point backends register at. -/
structure Finder where
  /-- The backend's name, which a choice finds one by. -/
  name : String
  /-- The root of the project `path` is in, or `none`. It may read the state
  and make requests, as any `EditorM` program. -/
  find : String → EditorM (Option String)
  deriving TypeName

/-! ## Two implementation packages -/

/-- A backend that takes a path under `/repo` to the root `/repo`, and makes
a text saying what it was asked. -/
def gitPackage : Package :=
  { name := "project-git"
    setup :=
      Extension.add
        ({  name := "git"
            find := fun path => do
              makes s!"git asked {path}"
              return if path.startsWith "/repo/" then some "/repo" else none } :
          Finder) }

/-- A backend that takes any path to `/`. -/
def everywherePackage : Package :=
  { name := "project-everywhere"
    setup := Extension.add ({ name := "everywhere", find := fun _ => pure (some "/") } : Finder) }

/-! ## A consumer: the files feature -/

/-- The root of the project `path` is in: the first backend, in registration
order, that finds one. It names no backend. -/
def projectRoot (path : String) : EditorM (Option String) := do
  for finder in ← Extension.values Finder do
    if let some root← finder.find path then
      return some root
  return none

/-- A consumer that reads the point in a job: `finder-names`, whose work,
made when it is started, finishes with a command that makes a text of the
names of the finders registered, in order, joined with `, `. It names no
backend. -/
def namesJobPackage : Package :=
  { name := "project-names"
    setup :=
      Extension.workJob Finder "finder-names" fun finders _ =>
        Work.of (fun _ => pure (finders.map (·.name))) fun names =>
          makes (", ".intercalate names.toList) }

end ExtensionExample

open Editor
open Editor.Test
open ExtensionExample

/-- Another type that derives `TypeName`: its own extension point, not
`Finder`'s. -/
structure Impostor where
  /-- Anything. -/
  n : Nat
  deriving TypeName

/-- What `command` returns when the loop dispatches it with what `state`'s
registry says, or `none` if it does not finish. -/
def askedOf {α : Type} (state : ModelState) (command : EditorM α) : Option α :=
  match
    ((command.dispatched state.registry.registered EditorState.none).runModel editorModel).1 with
  | .ok (.finished answer, _) => some answer
  | _ => none

/-- The names of the finders registered, as `state`'s loop sees them. -/
def finderNames (state : ModelState) : Option (Array String) :=
  askedOf state do
    return (← Extension.values Finder).map (·.name)

/-- The names of the finders config registered, as `state`'s loop sees
them. -/
def configFinderNames (state : ModelState) : Option (Array String) :=
  askedOf state do
    return (← Extension.configValues Finder).map (·.name)

/-- A `setup`, config's, that registers a finder called `name`, which finds
the root `root` for every path. -/
def findingAs (name root : String) : SetupM Unit :=
  Extension.add ({ name, find := fun _ => pure (some root) } : Finder)

/-- The state a reload of config to `setup` leaves `state` in, built by hand
with no elaborator. -/
def reloadedTo (state : ModelState) (setup : SetupM Unit) : ModelState :=
  (reduceFrom state [.requested, .finished (accepted ["init"] setup)]).1

/-- What the finder `named` finds called `name` answers for `/repo/x`, as
`state`'s loop sees it: `some none` when no finder has that name. -/
def chosen (state : ModelState) (name : String) : Option (Option String) :=
  askedOf state do
    let some finder ← Extension.named Finder (·.name) name | return none
    finder.find "/repo/x"

/-- How the job `finder-names` ends when `state` starts it
(`Config.State.work?`), run against the job model: the texts its command
makes. -/
def finderJobNames (state : ModelState) : Option (Job.Outcome (Array String)) :=
  (state.work? "finder-names").map fun (_, work) => worked work

/-- The checks of extension points (`Editor/Extension.lean`). -/
def extensionChecks : List Check :=
  [{  name :=
        "values two packages register at an extension point come back typed, in registration order, to a consumer that names neither package; swapping the packages swaps which answers first"
      run :=
        let (state, refused) := Config.State.ofPackages #[gitPackage, everywherePackage]
        let (swapped, _) := Config.State.ofPackages #[everywherePackage, gitPackage]
        pure
          (refused.isEmpty && finderNames state == some #["git", "everywhere"] &&
            askedOf state (projectRoot "/repo/src/a.lean") == some (some "/repo") &&
            askedOf state (projectRoot "/tmp/b") == some (some "/") &&
            finderNames swapped == some #["everywhere", "git"] &&
            askedOf swapped (projectRoot "/repo/src/a.lean") == some (some "/")) },
    { name :=
        "a value's fields are programs over the editor's port: the requests a consumer's call makes are the editor's"
      run :=
        let (state, _) : ModelState × Array String := Config.State.ofPackages #[gitPackage]
        let program := (projectRoot "/repo/x").dispatched state.registry.registered EditorState.none
        pure ((program.runModel editorModel).2.texts.contents == #["git asked /repo/x"]) },
    { name :=
        "with nothing registered, and run bare where no loop dispatched the command, an extension point holds no value"
      run :=
        let (state, _) : ModelState × Array String := Config.State.ofPackages #[]
        pure
          (finderNames state == some #[] &&
            ((Extension.values Finder).runModel editorModel).1.toOption.map (·.size) == some 0) },
    { name :=
        "a value is registered at its own type's extension point: another type's value does not come back from `Finder`'s, and does from its own"
      run :=
        let impostor : Package :=
          { name := "impostor", setup := Extension.add ({ n := 3 } : Impostor) }
        let (state, refused) := Config.State.ofPackages #[gitPackage, impostor]
        pure
          (refused.isEmpty && finderNames state == some #["git"] &&
            askedOf state
                (do
                  return (← Extension.values Impostor).map (·.n)) ==
              some #[3]) },
    { name :=
        "a reload replaces config's values at an extension point and keeps a package's, which come first"
      run :=
        let (state, _) : ModelState × Array String := Config.State.ofPackages #[gitPackage]
        let a := reloadedTo state (findingAs "a" "/a")
        let b := reloadedTo a (findingAs "b" "/b")
        let cleared := reloadedTo b (pure ())
        pure
          (finderNames a == some #["git", "a"] && finderNames b == some #["git", "b"] &&
            finderNames cleared == some #["git"]) },
    { name :=
        "with two packages' values and config's two at a point, `configValues` gives config's alone, in order, and `values` the packages' and then config's; before config registers, after a reload without them, and run bare, it gives none"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages #[gitPackage, everywherePackage]
        let both :=
          reloadedTo state do
            findingAs "a" "/a"
            findingAs "b" "/b"
        let cleared := reloadedTo both (pure ())
        pure
          (configFinderNames state == some #[] && configFinderNames both == some #["a", "b"] &&
            finderNames both == some #["git", "everywhere", "a", "b"] &&
            configFinderNames cleared == some #[] &&
            finderNames cleared == some #["git", "everywhere"] &&
            ((Extension.configValues Finder).runModel editorModel).1.toOption.map (·.size) ==
              some 0) },
    { name :=
        "config's value of another type does not come back from `Finder`'s `configValues`, and does from its own"
      run :=
        let (state, _) : ModelState × Array String := Config.State.ofPackages #[gitPackage]
        let installed := reloadedTo state (Extension.add ({ n := 3 } : Impostor))
        pure
          (configFinderNames installed == some #[] &&
            askedOf installed
                (do
                  return (← Extension.configValues Impostor).map (·.n)) ==
              some #[3]) },
    { name :=
        "a choice: `named` finds config's value of a package's name, the package's again after a reload without it, and nothing of a name nobody registered"
      run :=
        let (state, _) : ModelState × Array String := Config.State.ofPackages #[gitPackage]
        let installed := reloadedTo state (findingAs "git" "config's")
        let emptied := reloadedTo installed (pure ())
        pure
          (chosen installed "git" == some (some "config's") &&
            chosen emptied "git" == some (some "/repo") &&
            chosen emptied "nobody" == some none) },
    { name :=
        "a job over an extension point is made, when it is started, from the values two packages registered there, in registration order"
      run :=
        let (state, refused) :=
          Config.State.ofPackages #[gitPackage, everywherePackage, namesJobPackage]
        let (swapped, _) :=
          Config.State.ofPackages #[everywherePackage, gitPackage, namesJobPackage]
        pure
          (refused.isEmpty && finderJobNames state == some (.finished #["git, everywhere"]) &&
            finderJobNames swapped == some (.finished #["everywhere, git"])) },
    { name := "with no value registered at its point, a job over it is made from none"
      run :=
        let (state, _) : ModelState × Array String := Config.State.ofPackages #[namesJobPackage]
        pure (finderJobNames state == some (.finished #[""])) },
    { name :=
        "a job over an extension point sees config's value once a reload installs it, and the package's alone after a reload that drops config's"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages #[gitPackage, namesJobPackage]
        let installed := reloadedTo state (findingAs "a" "/a")
        let dropped := reloadedTo installed (pure ())
        pure
          (finderJobNames installed == some (.finished #["git, a"]) &&
            finderJobNames dropped == some (.finished #["git"])) },
    { name :=
        "a value of another type, registered at its own point, does not reach a job over `Finder`'s"
      run :=
        let impostor : Package :=
          { name := "impostor", setup := Extension.add ({ n := 3 } : Impostor) }
        let (state, refused) := Config.State.ofPackages #[impostor, gitPackage, namesJobPackage]
        pure (refused.isEmpty && finderJobNames state == some (.finished #["git"])) }]

end ModelTest
