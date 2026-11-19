import Editor.Ffi
import Editor.Fuzzy

/-!
# The fuzzy matching interface's real binding

The fuzzy matching interface (`Editor/Fuzzy.lean`) answered by the Rust
library (`Fuzzy.real`): a ranking is one call of `Ffi.fuzzyRank`, the
library's ranking rule (`crates/editor-fuzzy`) over its matching library's
adapter (`crates/editor-fuzzy-nucleo`); a located pattern is one call of
`Ffi.fuzzyLocate`, the library's locating rule over its searcher's adapter
(`crates/editor-fuzzy-triple-accel`).

The binding keeps nothing: there is no handle to make or free, and the
candidates are borrowed by the library for the length of the call. It needs
nothing a host could hand in, so it is a constant and not a function of
one.

This module adds no decision: the request is one call. It imports
`Editor.Ffi`, so only an executable linked with the library imports it.

`contract-test` holds it to the fuzzy matching interface's contract
(`Editor/Fuzzy/Contract.lean`), the list `model-test` holds the model to.
-/

namespace Editor

/-- The fuzzy port answered by the library's matcher. -/
def Fuzzy.real : FuzzyHandler
  | .rank pattern candidates => Ffi.fuzzyRank pattern candidates
  | .locate pattern text near maxErrors => Ffi.fuzzyLocate pattern text near maxErrors

end Editor
