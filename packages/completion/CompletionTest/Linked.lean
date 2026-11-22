import CompletionTest.Linked.Completion.Styles
import Editor.Completion.StyleContract
import Editor.Fuzzy.Real

/-!
# The linked test of the package `completion`

The root of an executable linked as the editor is linked, with the glue and
the Rust library (the core's `editorLinked` facet,
`lake build +CompletionTest.Linked:editorLinked`): the tests of the
package that need the real library. The gate builds it in `mise run lean`
and runs it in `mise run ffi-test` (`tools/package-set.sh`), in the
package's directory, with the toolchain's directory and the core's
`.olean` directory as its arguments, which it does not need.

It runs the linked test modules, under `CompletionTest/Linked/`, each of
which mirrors the module it tests:

- `shippedStyleFailures` (`CompletionTest/Linked/Completion/Styles.lean`):
  every property of the completion styles' contract holds of the fuzzy
  style and of the path style over the real fuzzy binding.

It hands those modules the real fuzzy binding (`Fuzzy.real`), which only
the root of a linked test may import (`docs/design/packages.md`, "What a
package may import"). A ranking is one call into the library, so no job
service and no pump is started.
-/

/-- Runs the checks and exits 0 when all hold, 1 after naming on stderr the
ones that do not, and 2 for a command line that is not the two
directories. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [_, _] =>
    let failed ← CompletionTest.shippedStyleFailures Editor.Fuzzy.real
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    if failed.isEmpty then
      IO.println
          s!"completion linked test: {CompletionTest.linkedStyles.length * Editor.Completion.StyleContract.properties.length} checks passed"
    (← IO.getStdout).flush
    return if failed.isEmpty then 0 else 1
  | _ =>
    IO.eprintln "usage: CompletionTest-Linked <sysroot> <core olean dir>"
    return 2
