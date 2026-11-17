import Editor.Scene

/-!
# The tab bar

The strip that lists the frame's tabs, with the tab in view in its own
face: a text view over generated text, as the buffer list and the
minibuffer's candidates are, and neither a buffer nor a window.

- **Where it goes.** A strip one text row tall, cut off the frame directly
  above the minibuffer's strip and below the tiled area
  (`EditorState.tabBarRect?`, `Editor/State.lean`): tmux's default
  `status-position bottom`. It is not at the top, where it would sit under
  the title bar the window draws over the frame, whose height Lean knows
  only in points. Floats stay out of it: the tiled area is the frame less
  both strips. Layout draws the echo in the frame's bottom row, below it.
- **When it is shown** (`Shown`): `never`; `several`, the default, while
  there are two tabs or more, as Vim's `showtabline=1`, so a frame with one
  tab looks as it did before tabs; and `always`. Config chooses with
  `tabBar` (`Editor/Setup.lean`).
- **What it shows** (`line`): each tab as a chip, `" {n} {label}"` and a
  space, numbered from 1, the chips joined by one space. Each chip's bytes
  are in `face` (`tab-bar`), and the tab in view's in `selectedFace`
  (`tab-bar.selected`); the joining spaces are in neither. A line wider
  than the frame is clipped by the view's rectangle.
- **What it is** (`Drawn`): a text of the text store, an anchor marker at
  its start and a view id taken once from the state's next one, so never a
  window's. The publish makes them the first time the bar is drawn and
  keeps them for the editor's life (`Loop.publish`, `Editor/Loop.lean`),
  replacing the text's content when the line changes. It is in no buffer
  list and is not focusable: no window, no key and no follow.

Deferred: selecting a tab by clicking its chip, keeping the selected chip
in view when the chips overflow the strip, and a background across the
whole strip.

Pinned by `ModelTest.tabBarChecks` and `ModelTest.faceVocabularyChecks`.
-/

namespace Editor.TabBar

/-- The face of a tab's chip in the bar. -/
def face : FaceName :=
  ⟨"tab-bar"⟩

/-- The face of the chip of the tab in view. -/
def selectedFace : FaceName :=
  ⟨"tab-bar.selected"⟩

/-- When the tab bar is shown. -/
inductive Shown where
  /-- Never. -/
  | never
  /-- While there are two tabs or more: Vim's `showtabline=1`. -/
  | several
  /-- Always, with one tab too. -/
  | always
  deriving DecidableEq, Repr

/-- Whether the bar is shown over `count` tabs. -/
def Shown.shows (shown : Shown) (count : Nat) : Bool :=
  match shown with
  | .never => false
  | .several => 2 ≤ count
  | .always => true

/-- The tab bar once it has been drawn: the view it is drawn in, the text it
shows, that text's scroll anchor, and the line the text holds. -/
structure Drawn where
  /-- Its view's id, taken once from the state's next one. -/
  view : ViewId
  /-- The text of the text store that holds its line. -/
  text : TextId
  /-- An anchor marker of that text, at its start. -/
  scroll : MarkerId
  /-- The line the text holds. -/
  line : String
  deriving DecidableEq, Repr

/-- The bar's line over the tabs' `labels`, the tab at `selected` in view,
and its decorations: each chip `" {n} {label} "`, numbered from 1, joined by
one space, its byte range in `face`, or in `selectedFace` for the selected
tab. -/
def line (labels : Array String) (selected : Nat) : String × Array Decoration :=
  labels.zipIdx.foldl
    (fun (text, decorations) (label, index) =>
      let text := if index == 0 then text else text ++ " "
      let chip := s!" {index + 1} {label} "
      let start := text.utf8ByteSize
      (text ++ chip,
        decorations.push
          { start, stop := start + chip.utf8ByteSize
            face := if index == selected then selectedFace else face }))
    ("", #[])

end Editor.TabBar
