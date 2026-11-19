import Editor.Face

/-!
# Config tests: support: Themes

Fixture themes: a dark and a light one, each a palette's theme
(`Palette.theme`, `Editor/Face.lean`) of colours written here, under names
no package registers. The checks that need a theme beside the built-in one
take these, so no test of a core module names a palette a package ships.
Shared by several test modules; it holds no checks of its own.
-/

namespace ConfigTest

open Editor

/-- The dark fixture theme's palette: greys, with accents of its own. -/
def fixtureDarkPalette : Palette where
  paper := Color.rgb 20 24 28
  ink := Color.rgb 200 204 208
  raised := Color.rgb 40 46 52
  selected := Color.rgb 60 68 76
  faint := Color.rgb 110 116 122
  strong := Color.rgb 236 238 240
  red := Color.rgb 220 80 80
  orange := Color.rgb 220 140 70
  yellow := Color.rgb 220 200 90
  green := Color.rgb 110 190 110
  cyan := Color.rgb 90 190 200
  blue := Color.rgb 100 150 230
  violet := Color.rgb 160 130 220
  magenta := Color.rgb 210 110 190

/-- The light fixture theme's palette, whose cursor is a colour of its own
and not the ink. -/
def fixtureLightPalette : Palette where
  paper := Color.rgb 250 248 240
  ink := Color.rgb 60 64 70
  raised := Color.rgb 232 228 216
  selected := Color.rgb 214 210 196
  faint := Color.rgb 140 144 150
  strong := Color.rgb 20 24 30
  cursor := Color.rgb 190 60 110
  red := Color.rgb 190 40 40
  orange := Color.rgb 190 100 20
  yellow := Color.rgb 160 130 0
  green := Color.rgb 50 130 50
  cyan := Color.rgb 20 130 140
  blue := Color.rgb 40 90 190
  violet := Color.rgb 110 80 180
  magenta := Color.rgb 170 50 140

/-- The dark fixture theme, `fixture-dark`. -/
def fixtureDark : NamedTheme :=
  { name := "fixture-dark", theme := fixtureDarkPalette.theme }

/-- The light fixture theme, `fixture-light`. -/
def fixtureLight : NamedTheme :=
  { name := "fixture-light", theme := fixtureLightPalette.theme }

/-- The fixture themes, in the order a host is handed them: the dark one,
then the light one. -/
def fixtureThemes : Array NamedTheme :=
  #[fixtureDark, fixtureLight]

end ConfigTest
