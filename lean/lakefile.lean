import Lake

open Lake DSL

/-- The editor's Lean package.

Every Lean linter is on, and a warning fails the build, so `lake build` is
also the lint gate (the Lean counterpart of `cargo clippy -- -D warnings`).
Silence a linter for one declaration with `set_option linter.<name> false in`. -/
package editor where leanOptions := #[⟨`linter.all, true⟩, ⟨`warningAsError, true⟩]

/-- The Lean formatter (`mise run lean-fmt`, `mise run lean-format`). Its
releases are tagged with the Lean toolchain they are built for, so bump
this together with `lean-toolchain`. -/
require «lean-fmt» from git "https://github.com/jcreinhold/lean-fmt"@"v4.35.0"

/-- One library holding both the user-facing prelude (`Editor`, imported by
user config at runtime) and the embedding API (`EditorHost`, the config
session). -/
@[default_target] lean_lib Editor where roots := #[`Editor, `EditorHost]
