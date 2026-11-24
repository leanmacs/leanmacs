import Lint.RealHost
import Lint.Wait
import Lint.Wiring

/-!
# The build's linters

The root of the library `Lint` (`lean/lakefile.lean`): the linters our
builds add to Lean's, which the build loads as a Lean plugin as it
elaborates each module of the core's libraries and of every package, so no
module imports them (`Lint/Wait.lean` says why): the wait linters
(`Lint/Wait.lean`), the real-host linter (`Lint/RealHost.lean`) and the
wiring-set linter (`Lint/Wiring.lean`), over what they share
(`Lint/Marks.lean`). A plugin is initialized through its
library's root, so this module imports every module of the library.
-/
