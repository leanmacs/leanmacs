import Echo.Library
import Echo.Real
import EchoTest.Check

/-!
# Linked tests: loading echo's library

The glue's load (`Echo.Real.loadFrom`) over the core's real loader and
package runtime (`editor_ffi_package_load`), each status read back through
`Echo.LoadRefusal.ofStatus?`, which pins that the Lean side's reading and
the core's tags agree over the real glue and loader:

- the library the lakefile built (`Echo.Real.library`), which the module's
  initialiser loaded before `main`, loads again: the core's loader finds
  `editor_package_init` in the built `cdylib` and its init answers 0;
- a path beside it that is never made is missing;
- the package's own `ffi/glue.c`, absolute, is not a library;
- and the initialiser's body (`Echo.Real.load`), handed that missing path,
  throws the refusal's sentence, the text Lean's generated `main` prints
  for an initialiser's error before it exits 1
  (`ModelTest.packageSetBuildChecks` pins that the build's probe carries
  such a text to its failure line).

The linked test runs in the package's directory (`tools/package-set.sh`),
so the glue's source is found there. It starts no thread and uses no
service: a plain group.
-/

namespace EchoTest.Linked

/-- A path beside echo's library, of its kind, that is never made. -/
private def absentBeside (library : String) : String :=
  let path : System.FilePath := library
  (path.withFileName s!"libecho_absent.{path.extension.getD "so"}").toString

/-- The refusal the core answers for a load of `path`, read back. -/
private def refusalOf (path : String) : IO (Option Echo.LoadRefusal) :=
  return Echo.LoadRefusal.ofStatus? (← Echo.Real.loadFrom path)

/-- The checks of the load of echo's library through its glue. -/
def echoLoadChecks : List Check :=
  [{  name :=
        "the library the lakefile built loads through the glue: the core finds its editor_package_init and its init answers 0"
      run := do
        let library ← Echo.Real.library
        let refusal ← refusalOf library
        saw (refusal == none) s!"{repr refusal} for {library}" },
    { name := "a path beside the library that is never made is refused as missing"
      run := do
        let absent := absentBeside (← Echo.Real.library)
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
        let absent := absentBeside (← Echo.Real.library)
        let thrown ←
          try
            Echo.Real.load absent
            pure none
          catch error =>
            pure (some (toString error))
        saw (thrown == some (Echo.LoadRefusal.missing.describe absent)) s!"{repr thrown}" }]

end EchoTest.Linked
