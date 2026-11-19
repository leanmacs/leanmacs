import Editor.Package
import Editor.Themes
import Editor.Themes.Check
import Editor.Themes.FairyFloss
import Editor.Themes.Solarized

/-!
# The `themes` package: the command that loads a theme, and the themes that ship

What a host registers so that it has themes (`Editor/Themes.lean`): the
package `themes` (`Themes.package`, `Editor/Package.lean`), whose `setup`
registers the command that loads a theme, the themes that ship and the
theme source. A host registers it for the owner `themes` when its loop
starts, before any config (`Editor/Config/Packages.lean`;
`Editor/Config/Registry.lean`, "Themes"), so they hold when config fails to
load, a reload does not replace them, and config's theme of a shipped
theme's name is used in its place until a reload drops it.

- **The command**: `load-theme`, a command that is given what it was
  called with (`commandWith`), which loads the theme it is given or asks for
  one among the registered ones (`Themes.loadThemeCommand`). A host must be
  handed the minibuffer's package too (`Editor/Minibuffer/Compiled.lean`)
  for that prompt to be answered.
- **`Themes.shipped`**: the themes that ship, which the package defines in
  order (`defineTheme`). `default` is the built-in
  theme (`Theme.builtin`, `Editor/Face.lean`), the one in force when no
  config names a theme; then `solarized-dark` and `solarized-light`
  (`Editor/Themes/Solarized.lean`), and `fairy-floss`
  (`Editor/Themes/FairyFloss.lean`). A new shipped theme is a palette's
  theme (`Palette.theme`, `Editor/Face.lean`), plus that theme's own
  definitions after it, appended here, and must pass the completeness check
  (`Themes.problems`, `Editor/Themes/Check.lean`), which
  `ModelTest.faceVocabularyChecks` runs on every theme in this list.

- **The source**: the theme completion source, so config can ask for it by
  name.

The mode line's shipped segments are a package of their own, `mode-line`
(`Editor/ModeLine/Compiled.lean`).

This module is apart from `Editor/Themes.lean` because it is what a host is
handed, not what config calls: `Editor.lean` imports the command, so that
config can call it, and not this.

Pinned by `ModelTest.themeChecks`, `ModelTest.faceVocabularyChecks`,
`ModelTest.solarizedChecks`, `ModelTest.fairyFlossChecks`,
`ConfigTest.shippedChecks` and `ConfigTest.cursorResolutionChecks`.
-/

namespace Editor.Themes

/-- The themes that ship, as the `themes` package defines them: `default`,
the built-in theme, then Solarized dark and light, then Fairy Floss. -/
def shipped : Array NamedTheme :=
  #[{ name := Theme.defaultName, theme := Theme.builtin }, Solarized.dark, Solarized.light,
    FairyFloss.fairyFloss]

/-- The package `themes`: the command that loads a theme, the themes that
ship (`shipped`) and the theme completion source. -/
def package : Package :=
  { name := "themes"
    setup := do
      commandWith loadName loadThemeCommand
      for named in shipped do
        defineTheme named.name named.theme
      defineSource source }

end Editor.Themes
