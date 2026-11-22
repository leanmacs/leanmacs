/-!
# Owners

Everything that is registered or started on someone's behalf has an *owner*:
an entry of the registry (`Editor/Config/Registry.lean`), a cell of a store
(`Editor/Config/Stores.lean`), a running job (`Editor/Job/Table.lean`). What
an owner registered is replaced as a set, and when an owner goes away its
jobs are cancelled. One owner type serves them all, so that an owner's
registry entries and its jobs go together.

There are three kinds of owner:

- **`config`** (`Owner.config`): everything the user's config registers.
  An install replaces its entries and cancels its jobs
  (`Editor/Config/Reload.lean`).
- **A package's** (`Package.owner`, `Editor/Config/Packages.lean`): named
  after the package, the owner of everything that package registers when
  the host starts. A reload never replaces a package's entries or cancels
  its jobs. No package is named `config` or `compiled`, and no two share a
  name, so an owner's name says whose it is.
- **`compiled`** (`Owner.compiled`): the owner of what the core falls back
  to when nothing was registered for it. No host registers anything under
  it.

It is a module of its own because the registry and the job table both need
it and neither needs the other.
-/

namespace Editor.Config

/-- Who registered or started something. What an owner registered is replaced
as a set, and its jobs are cancelled when it goes. -/
structure Owner where
  /-- The owner's name. -/
  name : String
  deriving DecidableEq, Repr

/-- The owner of everything the user's config registers. -/
def Owner.config : Owner :=
  { name := "config" }

/-- The owner of what the core falls back to when no package registered it:
the core's own style and display of a registry that holds none
(`Completion.Style.unregistered`, `Completion.Display.unregistered`;
`Registry.styleEntry`, `Registry.displayEntry`), and the default owner of a
job the loop starts for itself (`Loop.Spawn.owner`) and of a style's match
(`Completion.Matching.ownerFor`). No host registers anything under it: what
a feature registers belongs to its package's owner (`Package.owner`,
`Editor/Config/Packages.lean`). A reload never touches it. -/
def Owner.compiled : Owner :=
  { name := "compiled" }

end Editor.Config
