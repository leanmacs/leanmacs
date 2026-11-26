import Lake

open Lake DSL System

/-! A package of the Rust bans check's bite fixture `../lakefile.toml`: it
declares a crate, as a package that holds Rust does, and holds no Lean. -/
package «bans-base»

/-- The package's crate: the path of its manifest. -/
target editorRustCrate pkg : FilePath :=
  return Job.pure (pkg.dir / "rust" / "Cargo.toml")
