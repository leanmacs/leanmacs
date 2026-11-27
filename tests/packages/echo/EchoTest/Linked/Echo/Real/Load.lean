import Echo.Real
import EchoTest.Check
import Editor.PackageLibrary

/-!
# Linked tests: loading echo's library

The glue's load (`Echo.Real.loadFrom`) over the core's real loader and
package runtime (`editor_ffi_package_load`), each status and the two
numbers beside it read back through the core's
`Editor.PackageLibrary.LoadRefusal.of?`, which pins that the Lean side's
reading and the core's tags agree over the real glue and loader:

- the library the build staged beside this executable
  (`Echo.Real.stagedLibrary`, from `EchoTest-Linked.libraries`), which the
  module's initialiser loaded before `main`, loads again for the glue's interface
  (`Echo.Real.interface`): the core finds `editor_package_init` and the
  declaration `package! { interface 1; … }` exported in the built
  library, and its init answers 0;
- the same library, loaded for another interface than its glue's
  (`Echo.Real.loadExpecting`), is refused with both versions, and the
  initialiser's body throws the sentence naming echo, the library's
  version and the glue's;
- a path beside it that is never made is missing;
- the package's own `ffi/glue.c`, absolute, is not a library;
- and the initialiser's body (`Echo.Real.load`), handed that missing path
  or the glue's source, throws that refusal's sentence, the text Lean's
  generated `main` prints for an initialiser's error before it exits 1
  (`ModelTest.packageLibraryChecks` pins that the build's judgement of its
  probe carries each refusal's sentence, and
  `ModelTest.packageSetBuildChecks` that the build's failure line is that
  judgement's text).

A library without `editor_package_init`, one with no declaration, one
built for a newer runtime, and the two refusals only an init answers (a
runtime too small, a failed init), have no file this test can reach:
their tags cross the same C function in `editor-ffi`'s
`tests/package_load.rs`, on the fixture grammar library and the fixture
package libraries.

The linked test runs in the package's directory (`tools/package-set.sh`),
so the glue's source is found there. It starts no thread and uses no
service: a plain group.
-/

namespace EchoTest.Linked

/-- A path beside echo's library, of its kind, that is never made. -/
private def absentBeside (library : String) : String :=
  let path : System.FilePath := library
  (path.withFileName s!"libecho_absent.{path.extension.getD "so"}").toString

/-- The refusal the core answers for a load of `path` for the glue's
interface, read back. -/
private def refusalOf (path : String) : IO (Option Editor.PackageLibrary.LoadRefusal) := do
  let (status, first, second) ← Echo.Real.loadFrom path (← Echo.Real.interface)
  return Editor.PackageLibrary.LoadRefusal.of? status first second

/-- What `load` threw, if it threw. -/
private def thrownOf (load : IO Unit) : IO (Option String) := do
  try
    load
    pure none
  catch error =>
    pure (some (toString error))

/-- What the initialiser's load (`Echo.Real.load`) of `path` threw, if it
threw. -/
private def thrownBy (path : String) : IO (Option String) :=
  thrownOf (Echo.Real.load path)

/-- The checks of the load of echo's library through its glue. -/
def echoLoadChecks : List Check :=
  [{  name :=
        "the library the build staged beside this executable loads through the glue: the core finds its editor_package_init and its declaration, and its init answers 0"
      run := do
        let library ← Echo.Real.stagedLibrary
        let refusal ← refusalOf library
        saw (refusal == none) s!"{repr refusal} for {library}" },
    { name :=
        "echo's staged library, loaded for another interface than its glue's, is refused naming echo, its version and the glue's, and the initialiser's body throws that sentence"
      run := do
        let library ← Echo.Real.stagedLibrary
        let glue ← Echo.Real.interface
        let other := glue + 1
        let thrown ← thrownOf (Echo.Real.loadExpecting library other)
        let refusal := Editor.PackageLibrary.LoadRefusal.otherInterface glue.toNat other.toNat
        saw (thrown == some (refusal.describe "echo" library)) s!"{repr thrown}" },
    { name := "a path beside the library that is never made is refused as missing"
      run := do
        let absent := absentBeside (← Echo.Real.stagedLibrary)
        let refusal ← refusalOf absent
        saw (refusal == some .missing) s!"{repr refusal} for {absent}" },
    { name := "the package's ffi/glue.c, absolute, is refused as not a library"
      run := do
        let glue ← IO.FS.realPath ("ffi" / "glue.c")
        let refusal ← refusalOf glue.toString
        saw (refusal == some .notALibrary) s!"{repr refusal} for {glue}" },
    { name :=
        "the initialiser's load, handed a missing library, throws the refusal's sentence naming the path"
      run := do
        let absent := absentBeside (← Echo.Real.stagedLibrary)
        let thrown ← thrownBy absent
        saw (thrown == some (Editor.PackageLibrary.LoadRefusal.missing.describe "echo" absent))
            s!"{repr thrown}" },
    { name :=
        "the initialiser's load, handed the package's ffi/glue.c, throws the not-a-library sentence naming the path"
      run := do
        let glue := (← IO.FS.realPath ("ffi" / "glue.c")).toString
        let thrown ← thrownBy glue
        saw (thrown == some (Editor.PackageLibrary.LoadRefusal.notALibrary.describe "echo" glue))
            s!"{repr thrown}" }]

end EchoTest.Linked
