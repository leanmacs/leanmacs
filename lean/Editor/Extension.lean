import Editor.Api
import Editor.Setup

/-!
# Extension points

An *extension point* is a slot any Lake package can declare, not only the
core: a **type**. An interface package declares a record of functions, its
protocol, and derives `TypeName` for it. Implementation packages register
values of it from `setup`, and the packages that use the protocol read the
values, so neither imports the other. Why, and how this keeps every
implementation replaceable, is in `docs/design/extension-points.md`.

```lean
-- An interface package declares the point: its type.
structure Finder where
  name : String
  find : System.FilePath → EditorM (Option System.FilePath)
  deriving TypeName

-- An implementation package registers a value from its `setup`.
def setup : SetupM Unit :=
  Extension.add ({ name := "git", find := gitRoot } : Finder)

-- A consumer reads every value registered, in a command.
def projectRoot (path : System.FilePath) : EditorM (Option System.FilePath) := do
  for finder in ← Extension.values Finder do
    if let some root ← finder.find path then return some root
  return none
```

Because the point is the type, a value of the wrong type cannot be
registered at it and a misspelt point is an unknown identifier: both are
build errors.

## A hook, or a choice

The interface package says which each of its points is:

- **A hook** uses every value, in order (`values`): a package's before
  config's, packages in the order they register.
- **A choice** uses one value, by name (`named`): the latest registered of
  that name, so config's value of a package's name replaces the
  package's.

No value registered is an ordinary case: a hook nobody registered at is
empty, and a choice of a name nobody registered is `none`.

## How the values travel

`add` makes one generic setup request, `SetupRequest.extend`, keyed by the
type's declared name (`TypeName.typeName`), with the value as a `Dynamic`,
so the core holds values of types it has never seen. The registry keeps
each value with its owner (`Config.Registry.replaceExtensions`), so a
reload of config replaces config's values and leaves a package's. A command
asks for the values at a key (`RegistryRequest.extensions`) and gets them
back typed by `Dynamic.get?`.
-/

namespace Editor.Extension

/-- Registers `value` at the extension point of its type, `α`, for whoever
runs this `setup`: a package or config. -/
def add {α : Type} [TypeName α] (value : α) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.extend (TypeName.typeName α) (.mk value)))

/-- Every value registered at the extension point `α`, in registration
order. -/
def values (α : Type) [TypeName α] : EditorM (Array α) := do
  return (← RegistryRequest.ask (.extensions (TypeName.typeName α))).filterMap (·.get? α)

/-- The latest value registered at the extension point `α` whose name, as
`name` reads it, is `wanted`, or `none` when no value has that name. -/
def named (α : Type) [TypeName α] (name : α → String) (wanted : String) : EditorM (Option α) := do
  return (← values α).findRev? (name · == wanted)

end Editor.Extension
