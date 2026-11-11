/-!
# Bindings to the Rust library

The functions `editor-ffi` (`crates/editor-ffi`) exposes, as Lean
declarations. A pure function over plain numbers binds straight to its Rust
symbol. An `IO` function binds to a wrapper in `ffi/glue.c`, which calls the
Rust function and builds the `IO` result with `lean.h`.

Nothing here runs at initialisation: call these from `main` or later.
-/

namespace Editor.Ffi

/-- The sum of `a` and `b`, wrapping on overflow, computed by the Rust library.
The trivial function that shows a call crossing the boundary. -/
@[extern "editor_ffi_add"]
opaque add (a b : UInt32) : UInt32

end Editor.Ffi
