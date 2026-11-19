import Editor.Face

/-!
# The tests of `shipped-themes`: support: Themes

The badge faces both palettes' checks read. Shared by the test modules under
`ShippedThemesTest/ShippedThemes/`; it holds no checks of its own.
-/

namespace ShippedThemesTest

open Editor

/-- The badge faces of the shipped Vim scheme's states, each bold in every
shipped theme. -/
def badgeFaces : List String :=
  Theme.cursorStates.toList.map (s!"mode-line.state.{·}")

end ShippedThemesTest
