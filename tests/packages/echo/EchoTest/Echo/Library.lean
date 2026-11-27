import Echo.Library
import Editor.PackageSet.Build

/-!
# Model tests: `Echo/Library.lean`

How a load of echo's library is read back: status 0 is a load, 1 to 5 the
five refusals in the core's order, and each refusal's sentence is its own
and names the library's path. And, for each refusal, that its sentence is
what the package-set build's failure line carries, through the build's own
judgement of its probe (`Editor.PackageSet.probeFailed`): an editor whose
echo initialiser threw it exits 1 with `uncaught exception: <sentence>` on
standard error, as Lean's generated `main` prints an initialiser's error
(`Echo.Real`'s module docs), and the build fails with
`the new editor did not start: it exited with status 1; uncaught exception:
<sentence>`. That the build's failure line is that judgement's text, the
staging directory removed and nothing published, is the core's
(`ModelTest.packageSetBuildChecks`); that the initialiser throws the
sentence over the real glue and loader is the linked test's
(`EchoTest.Linked.echoLoadChecks`). The test driver's root,
`EchoTest/Model.lean`, runs them.
-/

namespace EchoTest

/-- Each refusal, in the core's order (`editor_package_library::load`). -/
private def refusals : List Echo.LoadRefusal :=
  [.missing, .notALibrary, .noInit, .runtimeTooSmall, .initFailed]

/-- The checks of the reading of a load, each with what must hold as a
sentence. -/
def echoLibraryChecks : List (String × Bool) :=
  let texts := refusals.map (·.describe "/x/libecho_service.so")
  [("status 0 is a load, with no refusal", Echo.LoadRefusal.ofStatus? 0 == none),
      ("statuses 1 to 5 are the five refusals, in the core's order",
        [1, 2, 3, 4, 5].map Echo.LoadRefusal.ofStatus? == refusals.map some),
      ("a status past 5 is a refusal the load did not expect, read as a failed init",
        Echo.LoadRefusal.ofStatus? 6 == some .initFailed),
      ("each refusal's sentence is distinct", texts.eraseDups.length == refusals.length),
      ("each refusal's sentence names echo and the library's path",
        texts.all fun text =>
          text.startsWith "echo: " && (text.splitOn "/x/libecho_service.so").length == 2)] ++
    refusals.map fun refusal =>
      let text := refusal.describe "/x/libecho_service.so"
      let probe : Editor.Process.Ran :=
        { exit := .code 1, stdout := .empty, stderr := s!"uncaught exception: {text}\n".toUTF8 }
      (s!"a probe whose echo initialiser threw the refusal {repr refusal} fails the package build with its sentence",
        Editor.PackageSet.probeFailed (.ok probe) ==
          some
            s!"the new editor did not start: it exited with status 1; uncaught exception: {text}")

end EchoTest
