import CompletionTest.Linked.Completion.Styles
import Editor.Completion.StyleContract
import Editor.Fuzzy.Real
import Editor.RealHost

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

/-- The root's check set (`Editor.CheckGroup`), over the fuzzy binding it is
handed: the completion styles' contract (`shippedStyleFailures`), whose run
names the properties that do not hold, in a plain group, since it holds no
module of the wiring set. -/
def CompletionTest.Linked.checks :
    List (Editor.CheckGroup Editor.FuzzyHandler (IO (List String))) :=
  [.plain fun fuzzy => [CompletionTest.shippedStyleFailures fuzzy]]

/-- The usage, on stderr, and status 2. -/
private def CompletionTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: CompletionTest-Linked <sysroot> <core olean dir> <test grammars dir> [--wiring], or CompletionTest-Linked wiring-modules"
  return 2

/-- Runs the checks and exits 0 when all hold, 1 after naming on stderr the
ones that do not, and 2 for a command line that is not the two
directories, with `--wiring` after them or not. Its check set
(`CompletionTest.Linked.checks`) holds no module of the wiring set, so with
`--wiring` it selects no check and exits 0 (`Editor.CheckGroup.running`),
and `wiring-modules` prints none. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules CompletionTest.Linked.checks do
      IO.println module
    return 0
  | _ :: _ :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      Editor.CheckGroup.running mode CompletionTest.Linked.checks do
          let failed ←
            (Editor.CheckGroup.select mode CompletionTest.Linked.checks Editor.Fuzzy.real).flatMapM
                id
          for name in failed do
            IO.eprintln s!"FAILED: {name}"
          if failed.isEmpty then
            IO.println
                s!"completion linked test: {CompletionTest.linkedStyles.length * Editor.Completion.StyleContract.properties.length} {mode.what} passed"
          (← IO.getStdout).flush
          return if failed.isEmpty then 0 else 1
    | none =>
      CompletionTest.Linked.usage
  | _ =>
    CompletionTest.Linked.usage
