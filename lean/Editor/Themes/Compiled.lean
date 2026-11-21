import Editor.Package
import Editor.Themes
import Editor.Themes.Check

/-!
# The `themes` package: the command that loads a theme, and the theme `default`

What a host registers so that it has themes (`Editor/Themes.lean`): the
package `themes` (`Themes.package`, `Editor/Package.lean`), whose `setup`
registers the command that loads a theme, the theme `default` and the
theme source. A host registers it for the owner `themes` when its loop
starts, before any config (`Editor/Config/Packages.lean`;
`Editor/Config/Registry.lean`, "Themes"), so they hold when config fails to
load, a reload does not replace them, and config's theme of the name
`default` is used in its place until a reload drops it.

- **The command**: `load-theme`, a command that is given what it was
  called with (`commandWith`), which loads the theme it is given or asks for
  one among the registered ones (`Themes.loadThemeCommand`). A host must be
  handed the minibuffer's package too (`packages/minibuffer/Minibuffer/Compiled.lean`)
  for that prompt to be answered.
- **`Themes.defaultTheme`**: the theme `default`, the built-in theme
  (`Theme.builtin`, `Editor/Face.lean`), the one in force when no config
  names a theme. It is the one theme this package defines (`defineTheme`).
- **The source**: the theme completion source, so config can ask for it by
  name.

The palettes that ship, `solarized-dark`, `solarized-light` and
`fairy-floss`, are a package of their own outside the core,
`shipped-themes` (`packages/shipped-themes/`, a Lake package the default
package set requires), which registers after every package of the core.
This module is a core module and imports no palette
(`docs/design/packages.md`), and a set without that package still has
`load-theme` and `default`.

The mode line's shipped segments are a package of their own, the default
package `mode-line` (`packages/mode-line/`).

This module is apart from `Editor/Themes.lean` because it is what a host is
handed, not what config calls: `Editor.lean` imports the command, so that
config can call it, and not this.

Pinned by `ModelTest.themeChecks`, `ModelTest.faceVocabularyChecks`,
`ConfigTest.shippedChecks` and `ConfigTest.cursorResolutionChecks`.
-/

namespace Editor.Themes

/-- The theme `default`, as the `themes` package defines it: the built-in
theme under the name of the theme in force when config names none. -/
def defaultTheme : NamedTheme :=
  { name := Theme.defaultName, theme := Theme.builtin }

/-- The package `themes`: the command that loads a theme, the theme
`default` (`defaultTheme`) and the theme completion source. -/
def package : Package :=
  { name := "themes"
    setup := do
      commandWith loadName loadThemeCommand
      defineTheme defaultTheme.name defaultTheme.theme
      defineSource source }

end Editor.Themes
