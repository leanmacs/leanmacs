/-!
# Loading echo's library: what a refusal says

Echo's crate ships as a library of its own, which the package's glue asks
the core to load when the editor starts (`Echo.Real`'s initialiser,
`ffi/glue.c`; docs/design/packages.md, "A library loaded when the editor
runs, as built"). The core answers a status: 0 when it loaded, or a refusal,
1 to 5, in the order the core asks (`editor_package_library::load`). This
module reads that status back (`LoadRefusal.ofStatus?`) and says each
refusal as a sentence of its own that names the library
(`LoadRefusal.describe`), the text a refused load ends the editor's start
with. It is pure, so the model tests pin it with no Rust.
-/

namespace Echo

/-- Why echo's library was not loaded, in the core's order. -/
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
  deriving DecidableEq, Repr

/-- The refusal the core's status `status` says, or none for 0, a load. A
status past 5 is none the core answers, read as a failed init. -/
def LoadRefusal.ofStatus? (status : UInt32) : Option LoadRefusal :=
  match status with
  | 0 => none
  | 1 => some .missing
  | 2 => some .notALibrary
  | 3 => some .noInit
  | 4 => some .runtimeTooSmall
  | _ => some .initFailed

/-- The refusal as a sentence naming echo and its library `library`. -/
def LoadRefusal.describe (refusal : LoadRefusal) (library : String) : String :=
  match refusal with
  | .missing =>
    s!"echo: its library {library} is missing; build the package echo (lake build EchoReal)"
  | .notALibrary => s!"echo: {library} is not a library this platform can load"
  | .noInit => s!"echo: the library {library} exports no editor_package_init"
  | .runtimeTooSmall =>
    s!"echo: the library {library} needs a newer package runtime than this editor's"
  | .initFailed => s!"echo: the library {library} failed its init"

end Echo
