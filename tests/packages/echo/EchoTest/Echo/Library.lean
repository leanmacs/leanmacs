import Echo.Library

/-!
# Model tests: `Echo/Library.lean`

How a load of echo's library is read back: status 0 is a load, 1 to 5 the
five refusals in the core's order, and each refusal's sentence is its own
and names the library's path. The test driver's root, `EchoTest/Model.lean`,
runs them.
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
        text.startsWith "echo: " && (text.splitOn "/x/libecho_service.so").length == 2)]

end EchoTest
