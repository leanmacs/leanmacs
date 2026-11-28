import Editor.Language
import Editor.Package

/-!
# The `languages` package: the `code` mode and the languages that ship

What a host registers so that a file of a shipped language opens
highlighted: the package `languages` (`Language.package`, the core's
`lean/Editor/Package.lean`), for the owner `languages`, when its loop
starts, before any config (the core's `lean/Editor/Config/Packages.lean`).
It is the library of the default package `languages`, a Lake package
outside the core (`packages/languages/`), which the entry module
`Languages/EditorPackage.lean` lists.

- **The mode** `code` (`Language.modes`, the core's
  `lean/Editor/Language.lean`), the one major mode of every buffer with a
  language.
- **The languages** that ship (`Language.shipped`): `rust`, `json`,
  `markdown`, `toml` and `lean`, in order. Config's `defineLanguage` of a
  shipped name replaces that one whole, and config's entries are matched
  first (`Config.Registry.languageTable`). Each names its grammar alone,
  with no query: the grammars and their queries come from the package
  `languages-grammars` (`Languages/Grammars.lean`), since the library
  compiles in no grammar, so a shipped language's file is highlighted once
  that package's grammars have registered. That package also defines the
  languages beyond the core's table: `yaml`, `java`, `swift`, `ruby`,
  `python`, `javascript`, `typescript`, `tsx`, `c`, `cpp` and `clojure`.

The data stays in the core's `lean/Editor/Language.lean`, which names no
package: the core's file commands, its loop and its tests read it. This
module is what a host is handed. It imports the core's API alone.

Pinned by `LanguagesTest.languagePackageChecks`
(`LanguagesTest/Languages/Compiled.lean`).
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
