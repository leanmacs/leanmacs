import Editor.Face
import Editor.Themes.FairyFloss
import Editor.Themes.Picture
import Editor.Themes.Solarized

/-!
# FFI tests: `Editor/Themes/Shipped.lean`

The tests of `Editor/Themes/Shipped.lean`: the shipped palettes' roles
(`shippedRoles`), which the `theme-pictures` scenario of the root module
`FfiTest` hands the theme picture check (`Editor/Themes/Picture.lean`)
beside the core's own theme, so each palette's picture is held to its
reference image. Each theme's colours are written from its published record
(`Themes.Solarized.published`, `Themes.FairyFloss.published`, pinned by
`ModelTest.solarizedChecks` and `ModelTest.fairyFlossChecks`), not read
from the theme.
-/

namespace FfiTest

open Editor.Themes.Picture

/-- Solarized dark's and light's roles: base0 on base03, its cursor
base0; base00 on base3, its cursor base00. -/
def solarizedRoles : List ThemeRoles :=
  let c := Editor.Themes.Solarized.published
  [{ name := Editor.Themes.Solarized.dark.name, theme := Editor.Themes.Solarized.dark.theme,
     paper := c.base03, ink := c.base0, cursor := c.base0 },
    { name := Editor.Themes.Solarized.light.name, theme := Editor.Themes.Solarized.light.theme,
      paper := c.base3, ink := c.base00, cursor := c.base00 }]

/-- Fairy Floss's roles: the tmTheme's foreground on its background, its
cursor the caret. -/
def fairyFlossRoles : ThemeRoles :=
  let c := Editor.Themes.FairyFloss.published
  { name := Editor.Themes.FairyFloss.fairyFloss.name,
    theme := Editor.Themes.FairyFloss.fairyFloss.theme, paper := c.background, ink := c.foreground,
    cursor := c.caret }

/-- The roles of every shipped theme that has a reference image. -/
def shippedRoles : List ThemeRoles :=
  solarizedRoles ++ [fairyFlossRoles]

end FfiTest
