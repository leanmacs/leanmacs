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

/-- The heading faces, levels 1 to 6, each bold in an accent in every
shipped theme. -/
def markupHeadings : List String :=
  (List.range 6).map (s!"text.heading.{· + 1}")

/-- Whether `face` gives the markup faces what the shared mapping gives
them and each shipped theme keeps: emphasis and a quote italic, a link
underlined once in its foreground, the code faces in the monospace family
and the prose face in the prose family. -/
def markupKept (face : String → Face) : Bool :=
  (face "text.emphasis").slant == some .italic && (face "text.quote").slant == some .italic &&
    (face "text.link").underline == some { style := .single } &&
    (face "text.code-span").family == some Face.monospaceFamily &&
    (face "text.code-block").family == some Face.monospaceFamily &&
    face "text.prose" == { family := some Face.proseFamily }

end ShippedThemesTest
