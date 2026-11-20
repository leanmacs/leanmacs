import Echo.Real
import Editor.Package

/-!
# The packages of the Lake package `echo`

None: no command uses the service, since a package cannot yet add a
service to the job runner. The module imports the Rust-backed binding,
`Echo.Real`, so that the editor of a set that holds this package, whose
root imports the entry module and so this module, links the binding, the
package's glue and the crate, and its link fails if the Rust archive does
not hold the crate.
-/

namespace Echo

/-- The packages of the Lake package `echo`: none. -/
def packages : Array Editor.Package :=
  #[]

end Echo
