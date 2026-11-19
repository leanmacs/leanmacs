import Editor.Language
import Editor.Package

/-!
# The `languages` package: the `code` mode and the languages that ship

What a host registers so that a file of a shipped language opens
highlighted: the package `languages` (`Language.package`,
`Editor/Package.lean`), for the owner `languages`, when its loop starts,
before any config (`Editor/Config/Packages.lean`).

- **The mode** `code` (`Language.modes`, `Editor/Language.lean`), the one
  major mode of every buffer with a language.
- **The languages** that ship (`Language.shipped`): `rust`, `json`,
  `markdown`, `toml` and `lean`, in order. Config's `defineLanguage` of a
  shipped name replaces that one whole, and config's entries are matched
  first (`Config.Registry.languageTable`).

The data stays in `Editor/Language.lean`, which names no package; this
module is what a host is handed.

Pinned by `ModelTest.languagePackageChecks`.
-/

namespace Editor.Language

/-- The package `languages`: the `code` mode, then the languages that ship,
in order. -/
def package : Package :=
  { name := "languages"
    setup := do
      for mode in modes do
        defineMode mode
      for language in shipped do
        defineLanguage language }

end Editor.Language
