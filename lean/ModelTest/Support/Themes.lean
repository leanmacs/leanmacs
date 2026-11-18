import Editor.Face

/-!
# Model tests: support: Themes

The badge faces both shipped themes' checks read. Shared by several test modules
under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The badge faces of the shipped Vim scheme's states, each bold in every
shipped theme. -/
def badgeFaces : List String :=
  Theme.cursorStates.toList.map (s!"mode-line.state.{·}")

end ModelTest
