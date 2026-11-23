import Lint.Wait

/-!
# The fixture library `UnlintedLint`

It imports the build's linters, so it has them by import, and loading them
as a plugin as well would register them twice: the lint plugins check
refuses nothing of it (`tools/lint-plugins-check.sh`). It is never built.
-/
