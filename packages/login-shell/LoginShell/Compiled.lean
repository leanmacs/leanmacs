import Editor.Extension
import Editor.Package
import Editor.Setup
import LoginShell

/-!
# The `login-shell` package: the login shell as the base of a child's environment

What a host registers so that a child's environment carries what the user's
login shell sets (`LoginShell.lean`): the package `login-shell`
(`LoginShell.package`, `Editor/Package.lean`). A host of a set that holds
this Lake package registers it for the owner `login-shell` when its loop
starts, before any config (`Editor/Config/Packages.lean`), last of the
default packages.

- **Its value at `EnvironmentApi.BaseSource`**: `LoginShell.baseSource`,
  named `login-shell`, which config's `LoginShell.timeLimit` replaces.
- **Its default base**: `environmentBase "login-shell"`, which config's
  `environmentBase` overrides (`Config.Registry.baseName`).

It registers no command, no job and no directory source.

This module is apart from `LoginShell.lean` because it is what a host is
handed, not what config calls.

Pinned by `LoginShellTest.loginShellChecks`, on the models, which also hold
the package to `environment-api`'s contract
(`EnvironmentApiTest.baseContract`).
-/

namespace LoginShell

/-- The package `login-shell`: the login shell as the default base. -/
def package : Editor.Package :=
  { name := "login-shell"
    setup := do
      Editor.Extension.add (baseSource defaultLimit)
      Editor.environmentBase name }

end LoginShell
