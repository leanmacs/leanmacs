import Editor.Config.Registry
import Editor.Themes
import Editor.Themes.Check
import Editor.Themes.FairyFloss
import Editor.Themes.Solarized

/-!
# The command that loads a theme, and the themes that ship, as compiled code registers them

What a host is handed so that it has themes (`Editor/Themes.lean`): the
registration of the command that loads one, and the themes that ship. A
host registers both for the owner `compiled` when its loop starts, before
any config (`Editor/Config/Registry.lean`, "Compiled commands", "Themes"),
so they hold when config fails to load, a reload does not replace them, and
config's theme of a shipped theme's name is used in its place until a reload
drops it.

- **`Themes.commands`**: `load-theme`, a command that is given what it was
  called with (`Action.call`), which loads the theme it is given or asks for
  one among the registered ones (`Themes.loadThemeCommand`). A host must be
  handed the minibuffer's commands too (`Editor/Minibuffer/Compiled.lean`)
  for that prompt to be answered.
- **`Themes.shipped`**: the themes that ship. `default` is the built-in
  theme (`Theme.builtin`, `Editor/Face.lean`), the one in force when no
  config names a theme; then `solarized-dark` and `solarized-light`
  (`Editor/Themes/Solarized.lean`), and `fairy-floss`
  (`Editor/Themes/FairyFloss.lean`). A new shipped theme is a palette's
  theme (`Palette.theme`, `Editor/Face.lean`), plus that theme's own
  definitions after it, appended here, and must pass the completeness check
  (`Themes.problems`, `Editor/Themes/Check.lean`), which
  `ModelTest.faceVocabularyChecks` runs on every theme in this list.

This module is apart from `Editor/Themes.lean` because it names the
registry, which is the config session's: `Editor.lean` imports the command,
so that config can call it, and not this.

Pinned by `ModelTest.themeChecks`, `ModelTest.faceVocabularyChecks`,
`ModelTest.solarizedChecks`, `ModelTest.fairyFlossChecks`,
`ConfigTest.shippedChecks` and `ConfigTest.cursorResolutionChecks`.
-/

namespace Editor.Themes

/-- The command that loads a theme, as a host registers it for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := loadName, action := .call loadThemeCommand }]

/-- The themes that ship, as a host registers them for the owner
`compiled`: `default`, the built-in theme, then Solarized dark and light, then Fairy Floss. -/
def shipped : Array NamedTheme :=
  #[{ name := Theme.defaultName, theme := Theme.builtin }, Solarized.dark, Solarized.light,
    FairyFloss.fairyFloss]

end Editor.Themes
