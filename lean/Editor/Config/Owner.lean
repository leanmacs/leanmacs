/-!
# Owners

Everything that is registered or started on someone's behalf has an *owner*:
an entry of the registry (`Editor/Config/Registry.lean`), a cell of a store
(`Editor/Config/Stores.lean`), a running job (`Editor/Job/Table.lean`). What
an owner registered is replaced as a set, and when an owner goes away its
jobs are cancelled. One owner type serves them all, so that an owner's
registry entries and its jobs go together.

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

/-- The owner of everything compiled code registers: the commands and the
bindings a host is handed when it starts, before any config. A reload never
replaces them. -/
def Owner.compiled : Owner :=
  { name := "compiled" }

end Editor.Config
