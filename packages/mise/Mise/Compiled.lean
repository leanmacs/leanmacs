import Editor.Extension
import Editor.Package
import Mise

/-!
# The `mise` package: mise as a child's directory environment source

What a host registers so that a child's environment carries what mise sets
for its directory (`Mise.lean`): the package `mise` (`Mise.package`,
`Editor/Package.lean`). A host of a set that holds this Lake package
registers it for the owner `mise` when its loop starts, before any config
(`Editor/Config/Packages.lean`), last of the default packages.

- **Its value at `EnvironmentApi.DirectorySource`**: `Mise.directorySource`,
  named `mise`, which config's `Mise.executable` replaces in its place.

It registers no command, no job and no base, and chooses no base.

This module is apart from `Mise.lean` because it is what a host is handed,
not what config calls.

Pinned by `MiseTest.miseChecks`, on the models, which also hold the package
to `environment-api`'s contract (`EnvironmentApiTest.directoryContract`).
-/

namespace Mise

/-- The package `mise`: mise as a directory source. -/
def package : Editor.Package :=
  { name := "mise", setup := Editor.Extension.add directorySource }

end Mise
