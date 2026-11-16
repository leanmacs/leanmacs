import Editor.Face
import Editor.Face.Vocabulary
import Editor.InputScheme.Vim.Default

/-!
# The completeness check of a theme

What a shipped theme must hold (`problems`): it defines every face of the
vocabulary (`Face.vocabulary`, `Editor/Face/Vocabulary.lean`), its default
face states the paper and the ink, and it gives every cursor the editor
draws a face that can be seen on the paper. The check is pure: it reads a
theme and no port.

- **The paper** is the background of the theme's `default` face, its
  definitions of `default` merged in order (`Theme.merged`); **the ink** is
  its foreground. A theme with neither set has the problem `noPaper` or
  `noInk`, not layout's base black on white: a shipped theme states its own
  paper, and the check restates no value layout owns.
- **A cursor face's colours** (`effective`) are its merged face over the
  merged default face, as layout paints a cursor
  (`crates/editor-layout/src/face.rs`, "The precedence"). So a cursor face
  that sets no background has the paper's, and one that sets no foreground
  has the ink. `ConfigTest.cursorResolutionChecks` holds this to the real
  layout.
- **The cursor faces** (`cursorFaces`) are `cursor`, which a scheme that
  names no face draws in, and the shipped Vim scheme's face of each of its
  states (`Vim.cursorFace`, over `Vim.Default.states` itself). A state added
  to the shipped scheme is checked with no edit here, and fails on a theme
  that does not define its face.
- For each: `noCursor` when the theme does not define it; else
  `cursorOnPaper` when its background is the paper, and `cursorInkOnItself`
  when its foreground is its background, which hides a block's glyph.

Problems are listed `noPaper` and `noInk` first, then the undefined faces in
the vocabulary's order, then each cursor face's in `cursorFaces`' order.

The check is applied to a theme as it ships (`Themes.shipped`), not to the
theme with config's definitions after it: those are the user's. A theme
config defines is not checked.

Pinned by `ModelTest.faceVocabularyChecks`, which runs it on every shipped
theme.
-/

namespace Editor.Themes

/-- What the check finds wrong with a theme. -/
inductive Problem where
  /-- A face of the vocabulary with no definition. -/
  | undefined (face : FaceName)
  /-- The default face has no background. -/
  | noPaper
  /-- The default face has no foreground. -/
  | noInk
  /-- A cursor face the editor draws with no definition. -/
  | noCursor (face : FaceName)
  /-- A cursor face whose background is the paper. -/
  | cursorOnPaper (face : FaceName)
  /-- A cursor face whose foreground is its own background. -/
  | cursorInkOnItself (face : FaceName)
  deriving DecidableEq, Repr

/-- One sentence of what is wrong. -/
def Problem.describe : Problem → String
  | .undefined face => s!"the face `{face.name}` of the vocabulary is not defined"
  | .noPaper => "the face `default` sets no background, the paper"
  | .noInk => "the face `default` sets no foreground, the ink"
  | .noCursor face => s!"the cursor face `{face.name}` is not defined"
  | .cursorOnPaper face => s!"the cursor face `{face.name}` has the paper as its background"
  | .cursorInkOnItself face =>
    s!"the cursor face `{face.name}` has its background as its foreground"

/-- The cursor faces the editor draws: `cursor`, then the shipped Vim
scheme's face of each of its states, the initial one first. -/
def cursorFaces : Array FaceName :=
  #[⟨"cursor"⟩] ++
    (Vim.Default.states.initial :: Vim.Default.states.others).toArray.map (Vim.cursorFace ·.name)

/-- The foreground and the background `theme` paints the face `face` in,
over its default face, as layout paints a cursor. -/
def effective (theme : Theme) (face : FaceName) : Option Color × Option Color :=
  let painted := (theme.merged face).over (theme.merged ⟨"default"⟩)
  (painted.foreground, painted.background)

/-- What is wrong with `theme`, in the order the module docs give; none for
a complete theme. -/
def problems (theme : Theme) : Array Problem :=
  let base := theme.merged ⟨"default"⟩
  let paper := base.background
  let colours : Array Problem :=
    (if paper.isNone then #[.noPaper] else #[]) ++ if base.foreground.isNone then #[.noInk] else #[]
  let undefined : Array Problem := (Face.vocabularyNames.filter (!theme.defines ·)).map .undefined
  let cursors : Array Problem :=
    cursorFaces.flatMap fun face =>
      if !theme.defines face then #[.noCursor face]
      else
        let (foreground, background) := effective theme face
        (if background == paper then #[.cursorOnPaper face] else #[]) ++
          if foreground == background then #[.cursorInkOnItself face] else #[]
  colours ++ undefined ++ cursors

end Editor.Themes
