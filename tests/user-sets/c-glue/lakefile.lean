import Lake

open Lake DSL System

/-! A fixture package of a user's package set (docs/design/packages.md,
"Who can build it"): it brings native code through a C FFI, the preferred way a
package brings it,
needing nothing beyond the bundled toolchain. `c/cglue.c` is compiled by the Lean toolchain's
compiler, as the core's glue is, and linked into the editor through the
library's `moreLinkObjs`; `CGlue.answer` is its `@[extern]` binding, and the
command `c-glue` says what it answers. `ffi-test` links a user's set that
requires it, with a `cargo` that always fails first on the PATH, and runs
the command (tests/user-sets/c-glue-script). -/
package «c-glue»

require «editor-core» from ".." / ".." / ".." / "lean"

/-- The package's C source, compiled against the toolchain's `lean.h`. -/
target cglue.o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "cglue.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "cglue.c"
  buildLeanO oFile srcJob #[] #["-O2", "-Wall", "-Werror"]

/-- The package's library, linked with its C object. -/
lean_lib CGlue where
  moreLinkObjs := #[cglue.o]
