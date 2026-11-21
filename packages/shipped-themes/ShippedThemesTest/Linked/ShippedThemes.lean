import Editor.Face
import Editor.Theme.Picture
import ShippedThemes.FairyFloss
import ShippedThemes.Solarized

/-!
# The linked tests of `ShippedThemes.lean`

The tests of the shipped palettes that need the Rust library: their
pictures. `themePictures` hands the core's theme picture check
(`Themes.Picture.themePicturesScenario`, the core's
`Editor/Theme/Picture.lean`, a test double a package's tests may import)
the three themes with their roles (`shippedRoles`), so each palette's
picture of the fixture `tests/render/source.lean`, drawn by the CPU
renderer through the display's real binding, is held to its reference
image in `tests/render/` (`tests/render/README.md`). Each theme's colours
are written from its published record (`ShippedThemes.Solarized.published`,
`ShippedThemes.FairyFloss.published`, pinned by
`ShippedThemesTest.solarizedChecks` and
`ShippedThemesTest.fairyFlossChecks`), not read from the theme.

The root of the linked test, `ShippedThemesTest/Linked.lean`, runs it. This
module is under `ShippedThemesTest/Linked/` because it links the Rust
library: the test driver, which must not, imports nothing here.
-/

namespace ShippedThemesTest.Linked

open Editor.Themes.Picture

/-- Solarized dark's and light's roles: base0 on base03, its cursor
base0; base00 on base3, its cursor base00. -/
def solarizedRoles : List ThemeRoles :=
  let c := ShippedThemes.Solarized.published
  [{ name := ShippedThemes.Solarized.dark.name, theme := ShippedThemes.Solarized.dark.theme,
     paper := c.base03, ink := c.base0, cursor := c.base0 },
    { name := ShippedThemes.Solarized.light.name, theme := ShippedThemes.Solarized.light.theme,
      paper := c.base3, ink := c.base00, cursor := c.base00 }]

/-- Fairy Floss's roles: the tmTheme's foreground on its background, its
cursor the caret. -/
def fairyFlossRoles : ThemeRoles :=
  let c := ShippedThemes.FairyFloss.published
  { name := ShippedThemes.FairyFloss.fairyFloss.name,
    theme := ShippedThemes.FairyFloss.fairyFloss.theme, paper := c.background, ink := c.foreground,
    cursor := c.caret }

/-- The roles of every shipped theme, each of which has a reference
image. -/
def shippedRoles : List ThemeRoles :=
  solarizedRoles ++ [fairyFlossRoles]

/-- The directory of the reference images and their fixture file, from the
package's directory, where the gate runs the linked test. -/
def pictureDirectory : String :=
  "tests/render"

/-- The one font the pictures are laid out in: the package's copy of the
core's fixture font. -/
def pictureFont : String :=
  "tests/render/NotoSansMono-Regular.subset.ttf"

/-- The pictures of the three shipped themes against their reference
images, by the core's theme picture check, guarding that the light
palette's picture is not the dark one's reference; with `write`, it writes
the references instead. The status is 0 when everything held. -/
def themePictures (write : Bool) : IO UInt8 :=
  themePicturesScenario "shipped-themes linked test" pictureDirectory pictureFont write shippedRoles
    (some (ShippedThemes.Solarized.light.name, ShippedThemes.Solarized.dark.name))

end ShippedThemesTest.Linked
