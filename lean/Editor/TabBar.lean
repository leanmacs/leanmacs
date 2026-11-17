import Editor.Scene

/-!
# The tab bar

The strip that lists the frame's tabs, with the tab in view in its own
face.

Pinned by `ModelTest.faceVocabularyChecks`.
-/

namespace Editor.TabBar

/-- The face of a tab's chip in the bar. -/
def face : FaceName :=
  ⟨"tab-bar"⟩

/-- The face of the chip of the tab in view. -/
def selectedFace : FaceName :=
  ⟨"tab-bar.selected"⟩

end Editor.TabBar
