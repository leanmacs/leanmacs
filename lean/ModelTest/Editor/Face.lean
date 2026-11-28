import Editor.Face
import Editor.Face.Vocabulary
import Editor.Scene
import ModelTest.Check

/-!
# Model tests: `Editor/Face.lean`

The model tests of `Editor/Face.lean`: `faceChecks`. The root module `ModelTest`
runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of faces and of the built-in theme, which are plain data
(`Editor/Face.lean`). What a face looks like in a frame is layout's rule,
pinned in `crates/editor-layout`; these pin what Lean itself defines. -/
def faceChecks : List Check :=
  [{
      name :=
        "the built-in theme defines default first, then each other face of the vocabulary, each once and nothing else",
      run :=
        let names := Theme.builtin.map (·.name)
        pure
          (names[0]? == some ⟨"default"⟩ && names.size == Face.vocabularyNames.size &&
            Face.vocabularyNames.all names.contains) },
    { name :=
        "the built-in search-match face sets a background that is not the default face's, and a foreground"
      run :=
        let face := (Theme.builtin.find? (·.name == ⟨"search-match"⟩)).map (·.face)
        let paper := (Theme.builtin.find? (·.name == ⟨"default"⟩)).bind (·.face.background)
        pure
          (match face with
          | some face =>
            face.background.isSome && face.background != paper && face.foreground.isSome
          | none => false) },
    { name := "the built-in prose face sets the prose family and nothing else"
      run :=
        pure
          (Theme.builtin.merged ⟨"text.prose"⟩ == { family := some Face.proseFamily } &&
            Face.proseFamily != Face.monospaceFamily) },
    { name :=
        "the built-in code span and code block faces set the monospace family, so either over the prose face over default has the monospace family"
      run :=
        let face := Theme.builtin.merged
        let prose := (face ⟨"text.prose"⟩).over (face ⟨"default"⟩)
        pure
          (prose.family == some Face.proseFamily &&
            [⟨"text.code-span"⟩, ⟨"text.code-block"⟩].all fun (code : FaceName) =>
              (face code).family == some Face.monospaceFamily &&
                ((face code).over prose).family == some Face.monospaceFamily) },
    { name :=
        "the built-in heading faces of levels 1, 2 and 3 are 24, 20 and 18 points, each larger than the default face, and those of levels 4 to 6 set no size"
      run :=
        let face := Theme.builtin.merged
        let body := ((face ⟨"default"⟩).size.map (·.sixtyFourths)).getD 0
        let sizes := (List.range 6).map fun level => (face ⟨s!"text.heading.{level + 1}"⟩).size
        pure
          (sizes == [some 24, some 20, some 18, none, none, none] &&
            (sizes.take 3).all fun size => (size.map (·.sixtyFourths)).getD 0 > body) },
    { name := "the built-in default face's family is the monospace family"
      run := pure ((Theme.builtin.merged ⟨"default"⟩).family == some Face.monospaceFamily) },
    { name :=
        "the built-in heading faces are bold, emphasis is italic, strong is bold and the link is underlined"
      run :=
        let face := Theme.builtin.merged
        pure
          ((List.range 6).all
              (fun level => (face ⟨s!"text.heading.{level + 1}"⟩).weight == some 700) &&
            (face ⟨"text.emphasis"⟩).slant == some .italic &&
            (face ⟨"text.strong"⟩).weight == some 700 &&
            (face ⟨"text.link"⟩).underline.any (·.style == .single)) },
    { name := "the built-in default face sets every attribute, and no other built-in face does"
      run :=
        let complete (face : Face) : Bool :=
          face.family.isSome && face.size.isSome && face.weight.isSome && face.slant.isSome &&
            face.foreground.isSome &&
            face.background.isSome &&
            face.underline.isSome &&
            face.strikeThrough.isSome &&
            face.lineHeight.isSome &&
            face.verticalPadding.isSome
        pure ((Theme.builtin.filter (complete ·.face)).map (·.name.name) == #["default"]) },
    { name :=
        "a face over another takes each attribute from the upper where it sets it and from the lower where it does not"
      run :=
        let upper : Face := { foreground := some (Color.rgb 1 0 0), weight := some 700 }
        let lower : Face :=
          { foreground := some (Color.rgb 2 0 0), background := some (Color.rgb 3 0 0)
            size := some 12 }
        pure
          (upper.over lower ==
              { foreground := some (Color.rgb 1 0 0), weight := some 700
                background := some (Color.rgb 3 0 0), size := some 12 } &&
            ({} : Face).over lower == lower &&
            upper.over {} == upper &&
            ({ verticalPadding := some 3 } : Face).over { verticalPadding := some 5 } ==
              { verticalPadding := some 3 } &&
            ({} : Face).over { verticalPadding := some 5 } == { verticalPadding := some 5 }) },
    { name :=
        "a theme's merged face of a name defined twice is the later definition's set attributes over the earlier's, ignores other names, and is the empty face for a name it does not define"
      run :=
        let theme : Theme :=
          #[{ name := ⟨"a"⟩, face := { foreground := some (Color.rgb 1 0 0), size := some 10 } },
            { name := ⟨"b"⟩, face := { background := some (Color.rgb 9 9 9) } },
            { name := ⟨"a"⟩, face := { foreground := some (Color.rgb 2 0 0) } }]
        pure
          (theme.merged ⟨"a"⟩ == { foreground := some (Color.rgb 2 0 0), size := some 10 } &&
            theme.merged ⟨"b"⟩ == { background := some (Color.rgb 9 9 9) } &&
            theme.merged ⟨"c"⟩ == {}) },
    { name := "a theme defines a name it gives an empty definition, and not a name it gives none"
      run :=
        let theme : Theme := #[{ name := ⟨"plain"⟩, face := {} }]
        pure (theme.defines ⟨"plain"⟩ && !theme.defines ⟨"other"⟩) },
    { name := "a colour is its four bytes, red first, and one made of three is opaque"
      run :=
        pure
          (Color.rgba 0x12 0x34 0x56 0x78 == { word := 0x12345678 } &&
            Color.rgb 0x12 0x34 0x56 == { word := 0x123456ff }) },
    { name :=
        "a length's literal is whole pixels, in 64ths, and one longer than a length holds is the longest"
      run :=
        pure
          ((14 : Pixels) == { sixtyFourths := 896 } && (0 : Pixels) == { sixtyFourths := 0 } &&
            Pixels.whole (2 ^ 40) == { sixtyFourths := 0xffffffff }) },
    { name :=
        "a face sets nothing it was not told to, and two faces are equal exactly when their attributes are"
      run :=
        let plain : Face := {}
        let red : Face := { foreground := some (Color.rgb 200 0 0) }
        pure
          (plain.family.isNone && plain.size.isNone && plain.weight.isNone && plain.slant.isNone &&
            plain.foreground.isNone &&
            plain.background.isNone &&
            plain.underline.isNone &&
            plain.strikeThrough.isNone &&
            plain.lineHeight.isNone &&
            red != plain &&
            red == { foreground := some (Color.rgb 200 0 0) }) }]

end ModelTest
