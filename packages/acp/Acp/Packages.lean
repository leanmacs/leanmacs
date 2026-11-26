import Acp.Real
import Editor.Package

/-!
# The packages of the Lake package `acp`

One, `acp`, which registers nothing at any extension point and runs nothing
at setup: it brings the service `agents` (`agents-api`'s, over the crate,
`Acp.Real.service`), which the program's edge hands the job runner
(`Package.services`, `Headless.shipped`). A consumer reaches it through
`agents-api`'s job wrappers (`AgentsApi.Job`), by the service's name, and
never imports this package (owner decision).

The module imports the Rust-backed binding, `Acp.Real`, so that the editor
of a set that holds this package links the binding, the package's glue and
the crate, and its link fails if the Rust archive does not hold the crate.
-/

namespace Acp

/-- The package `acp`. -/
def package : Editor.Package :=
  { name := "acp", setup := pure (), services := #[Real.service] }

/-- The packages of the Lake package `acp`: `acp`. -/
def packages : Array Editor.Package :=
  #[package]

end Acp
