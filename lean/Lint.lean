import Lint.Wait

/-!
# The build's linters

The root of the library `Lint` (`lean/lakefile.lean`): the linters our
builds add to Lean's, which the build loads as a Lean plugin as it
elaborates each module of the core's libraries and of every package, so no
module imports them (`Lint/Wait.lean` says why). A plugin is initialized
through its library's root, so this module imports every module of the
library.
-/
