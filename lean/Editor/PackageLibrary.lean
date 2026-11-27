/-!
# A package's native library, as the core reads it

A package that ships native code ships it as a library of its own, which
the package's glue asks the core to load when the editor starts (the
package's `builtin_initialize`, through `editor_ffi_package_load`;
docs/design/packages.md, "A package's library, staged and loaded, as
built"). The core answers a status, 0 when it loaded or a refusal's tag, 1
to 8, in the order the core asks (`editor_package_library::load`), and for
a newer runtime or another interface the two numbers it compared. This
module reads that answer back (`LoadRefusal.of?`) and says each refusal as
a sentence of its own that names the package and the library
(`LoadRefusal.describe`), the text a refused load ends the editor's start
with: every package with a library reads the core's tags here, naming
itself. It is pure, so the model tests pin it with no Rust
(`ModelTest.packageLibraryChecks`).
-/

namespace Editor.PackageLibrary

/-- Why a package's library was not loaded, in the core's order. -/
inductive LoadRefusal where
  /-- The path is not absolute, or nothing is at it. -/
  | missing
  /-- The file will not open as a library. -/
  | notALibrary
  /-- The library does not export `editor_package_init`. -/
  | noInit
  /-- The library's init found the core's runtime smaller than it requires. -/
  | runtimeTooSmall
  /-- The library's init answered a status no library answers, or no table. -/
  | initFailed
  /-- The library exports no `editor_package_declaration`, or one that ends
  before its interface version. -/
  | noDeclaration
  /-- The library declares it needs `needs` bytes of runtime, more than the
  core's `has`. -/
  | newerRuntime (needs has : Nat)
  /-- The library declares the interface version `declared`, and the
  package's glue expects `expected`. -/
  | otherInterface (declared expected : Nat)
  deriving DecidableEq, Repr

/-- The refusal the core's status `status` says, with the two numbers the
load wrote, `first` and `second`, or none for 0, a load. A newer runtime
(7) carries what the library needs and what the core has, another interface
(8) the library's version and the glue's, in that order. A status past 8 is
none the core answers, read as a failed init. -/
def LoadRefusal.of? (status : UInt32) (first second : UInt64) : Option LoadRefusal :=
  match status with
  | 0 => none
  | 1 => some .missing
  | 2 => some .notALibrary
  | 3 => some .noInit
  | 4 => some .runtimeTooSmall
  | 5 => some .initFailed
  | 6 => some .noDeclaration
  | 7 => some (.newerRuntime first.toNat second.toNat)
  | 8 => some (.otherInterface first.toNat second.toNat)
  | _ => some .initFailed

/-- The refusal as a sentence naming the package `package` and its library
`library`. -/
def LoadRefusal.describe (refusal : LoadRefusal) (package library : String) : String :=
  match refusal with
  | .missing => s!"{package}: its library {library} is missing; rebuild the package set (:reload)"
  | .notALibrary => s!"{package}: {library} is not a library this platform can load"
  | .noInit => s!"{package}: the library {library} exports no editor_package_init"
  | .runtimeTooSmall =>
    s!"{package}: the library {library} needs a newer package runtime than this editor's"
  | .initFailed => s!"{package}: the library {library} failed its init"
  | .noDeclaration =>
    s!"{package}: the library {library} exports no editor_package_declaration, so it says neither the runtime nor the interface it was built for; rebuild it against this editor's package runtime"
  | .newerRuntime needs has =>
    s!"{package}: the library {library} was built for a newer package runtime than this editor's: it needs {needs} bytes of runtime, and this editor's is {has}; update the editor, or use a build of {package} for this one"
  | .otherInterface declared expected =>
    s!"{package}: the library {library} has interface version {declared}, and this editor's {package} expects {expected}; rebuild the package set so the library and its package match"

end Editor.PackageLibrary
