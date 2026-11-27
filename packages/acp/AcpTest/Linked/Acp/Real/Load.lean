import Acp.Real
import AcpTest.Check
import Editor.PackageLibrary

/-!
# Linked tests: loading acp's library

The glue's load of acp's library (`Acp.Real.loadLibraryFrom`) over the
core's real loader and package runtime (`editor_ffi_package_load`), each
status and the two numbers beside it read back through the core's
`Editor.PackageLibrary.LoadRefusal.of?`:

- the library the build staged beside this executable, found through the
  core's edge (`Editor.PackageLibrary.staged "acp" "acp"`, from
  `AcpTest-Linked.libraries`), which `Acp.Real`'s initialiser loaded before
  `main`, loads again for the glue's interface (`Acp.Real.interface`): the
  core finds `editor_package_init` and the declaration
  `package! { interface 1; … }` exported in the built library, and its init
  answers 0;
- the same library, loaded for another interface than its glue's
  (`Acp.Real.loadLibraryExpecting`), is refused with both versions, and the
  initialiser's body throws the sentence naming acp, the library's version
  and the glue's.

The session's own load (`Acp.Real.load`, the glue's `acp_glue_load`, which
forwards through the table's `load` entry) keeps its name beside these: the
library's load takes names of its own (`…_load_library` in C,
`loadLibrary…` in Lean). It is reached through the table by `agents-api`'s
contract property "a load answers the session asked for, with its mode and
modes, its first events are the agent's history in order, and nothing is
parked", which `AcpTest.Linked.contractChecks` runs over `Acp.Real.service`.

The other refusals (a missing path, a file that is no library, a library
with no init, no declaration or a newer runtime) are the core's loader's,
pinned by echo's `EchoTest.Linked.echoLoadChecks` over the same loader and by
`editor-ffi`'s `tests/package_load.rs`.

It starts no thread and uses no service: a plain group.
-/

namespace AcpTest.Linked

/-- What `load` threw, if it threw. -/
private def thrownOf (load : IO Unit) : IO (Option String) := do
  try
    load
    pure none
  catch error =>
    pure (some (toString error))

/-- The checks of the load of acp's library through its glue. -/
def acpLoadChecks : List Check :=
  [{  name :=
        "acp's library the build staged beside this executable loads again through the glue: the core finds its editor_package_init and its declaration, and its init answers 0"
      run := do
        let library ← Editor.PackageLibrary.staged "acp" "acp"
        let (status, first, second) ← Acp.Real.loadLibraryFrom library (← Acp.Real.interface)
        let refusal := Editor.PackageLibrary.LoadRefusal.of? status first second
        saw (refusal == none) s!"{repr refusal} for {library}" },
    { name :=
        "acp's staged library, loaded for another interface than its glue's, is refused naming acp, its version and the glue's, and the initialiser's body throws that sentence"
      run := do
        let library ← Editor.PackageLibrary.staged "acp" "acp"
        let glue ← Acp.Real.interface
        let other := glue + 1
        let thrown ← thrownOf (Acp.Real.loadLibraryExpecting library other)
        let refusal := Editor.PackageLibrary.LoadRefusal.otherInterface glue.toNat other.toNat
        saw (thrown == some (refusal.describe "acp" library)) s!"{repr thrown}" }]

end AcpTest.Linked
