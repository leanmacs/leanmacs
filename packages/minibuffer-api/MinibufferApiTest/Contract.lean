import Editor.Config.Packages
import MinibufferApi

/-!
# The contract check of `minibuffer-api`

What every implementation of the interface runs over its package: it
registers a command under each name the interface declares, so whatever
reaches one of those names finds it: the Vim scheme's minibuffer table and
its motions that ask, a source's job posting a batch, and the keys a test
binds; and it registers a mode under the name the interface declares for
it, the one the minibuffer's buffer is made with. It collects the
package's `setup` with the pure collector (`Package.registered`), so
nothing is registered in an editor.

It is a list of sentences, each with whether it holds, the shape the
fixture interface package `greeting-api` gives its own
(`tests/packages/greeting-api`), so that it needs nothing of an
implementation's test driver: a driver whose checks are of another type
turns each pair into one of its checks.
-/

namespace MinibufferApiTest

open Editor

/-- The checks of the contract over `package`, one for each command name
the interface declares, then one for the mode, each with what must hold as
a sentence. -/
def contractChecks (package : Package) : List (String × Bool) :=
  let registered := Package.registered package
  let commands := registered.commands.map (·.name)
  let modes := registered.modes.map (·.name)
  MinibufferApi.names.toList.map
      (fun name =>
        (s!"`{package.name}` registers a command under `{name}`, a name `minibuffer-api` declares",
          commands.contains name)) ++
    [(s!"`{package.name}` registers a mode under `{MinibufferApi.modeName}`, the mode name `minibuffer-api` declares",
        modes.contains MinibufferApi.modeName)]

end MinibufferApiTest
