import Editor.Face
import Editor.Face.Vocabulary
import Editor.InputScheme

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
- **The cursor faces** a theme is held to are the vocabulary's
  (`Face.cursorNames`, `Editor/Face/Vocabulary.lean`): `cursor`, which a
  scheme that names no face draws in, and each face the vocabulary marks as
  one a scheme draws a cursor in. `problems` takes them as an argument with
  that default. What one scheme draws is `cursorFaces scheme`: `cursor`,
  then the faces the scheme lists (`InputScheme.cursorFaces`), which the
  scheme contract holds to its reports. The check names no scheme: a
  scheme's own tests hold that every face it draws a cursor in is one of
  the vocabulary's cursor faces, so a state added to a scheme fails there
  until the vocabulary declares its face, and then fails here on a theme
  that does not define it.
- For each: `noCursor` when the theme does not define it; else
  `cursorOnPaper` when its background is the paper, and `cursorInkOnItself`
  when its foreground is its background, which hides a block's glyph.
- **The selected window must stand out**: `modeLinesAlike` when the
  background of `mode-line.active` over `mode-line` is that of
  `mode-line.inactive` over `mode-line` (`effectiveOver`), as layout paints
  a status row's face over `mode-line` over the default face. So the
  selected window's bar differs from the others' in every shipped theme,
  whatever colours each picks.
- **A divider must be seen**: `dividerOnPaper` when `window-divider`'s
  foreground over the default face, the colour layout fills a divider in,
  is the paper.

Problems are listed `noPaper` and `noInk` first, then the undefined faces in
the vocabulary's order, then each cursor face's in the order given,
then `modeLinesAlike` and `dividerOnPaper`.

The check is applied to a theme as it ships (`Theme.builtin` here, and each
of `ShippedThemes.themes` in the tests of the package that ships them,
`packages/shipped-themes/`), not to the
theme with config's definitions after it: those are the user's. A theme
config defines is not checked.

Pinned by `ModelTest.faceVocabularyChecks`, which runs it on the built-in
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
  /-- The selected window's status row has the background of the others'. -/
  | modeLinesAlike
  /-- The window divider is filled in the paper. -/
  | dividerOnPaper
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
  | .modeLinesAlike =>
    "the faces `mode-line.active` and `mode-line.inactive` give a status row the same background"
  | .dividerOnPaper => "the face `window-divider` has the paper as its foreground"

/-- The cursor faces `scheme` draws: `cursor`, the face of a report that
names none, then each other face the scheme lists
(`InputScheme.cursorFaces`), in its order. -/
def cursorFaces (scheme : InputScheme) : Array FaceName :=
  #[⟨"cursor"⟩] ++ (scheme.cursorFaces.filter (· != ⟨"cursor"⟩)).toArray

/-- The foreground and the background `theme` paints the face `face` in,
over its default face, as layout paints a cursor. -/
def effective (theme : Theme) (face : FaceName) : Option Color × Option Color :=
  let painted := (theme.merged face).over (theme.merged ⟨"default"⟩)
  (painted.foreground, painted.background)

/-- The foreground and the background `theme` paints the face `face` in,
over the face `under`, over its default face, as layout paints a status
row's face over `mode-line`. -/
def effectiveOver (theme : Theme) (face under : FaceName) : Option Color × Option Color :=
  let painted := (theme.merged face).over ((theme.merged under).over (theme.merged ⟨"default"⟩))
  (painted.foreground, painted.background)

/-- What is wrong with `theme`, in the order the module docs give; none for
a complete theme. `cursors` are the cursor faces it is held to: the
vocabulary's, unless the caller names others. -/
def problems (theme : Theme) (cursors : Array FaceName := Face.cursorNames) : Array Problem :=
  let base := theme.merged ⟨"default"⟩
  let paper := base.background
  let colours : Array Problem :=
    (if paper.isNone then #[.noPaper] else #[]) ++ if base.foreground.isNone then #[.noInk] else #[]
  let undefined : Array Problem := (Face.vocabularyNames.filter (!theme.defines ·)).map .undefined
  let cursors : Array Problem :=
    cursors.flatMap fun face =>
      if !theme.defines face then #[.noCursor face]
      else
        let (foreground, background) := effective theme face
        (if background == paper then #[.cursorOnPaper face] else #[]) ++
          if foreground == background then #[.cursorInkOnItself face] else #[]
  let row (face : String) := (effectiveOver theme ⟨face⟩ ⟨"mode-line"⟩).2
  let alike : Array Problem :=
    if row "mode-line.active" == row "mode-line.inactive" then #[.modeLinesAlike] else #[]
  let divider : Array Problem :=
    if (effective theme ⟨"window-divider"⟩).1 == paper then #[.dividerOnPaper] else #[]
  colours ++ undefined ++ cursors ++ alike ++ divider

end Editor.Themes
