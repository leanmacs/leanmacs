import Editor.Face
import Editor.Scene
import ShippedThemes
import ShippedThemes.FairyFloss
import ShippedThemesTest.Check
import ShippedThemesTest.Support.Themes

/-!
# The tests of `ShippedThemes/FairyFloss.lean`

The tests of `ShippedThemes/FairyFloss.lean`: `fairyFlossChecks`. The test
driver's root, `ShippedThemesTest/Model.lean`, runs them; its module doc says
what each shows.
-/

namespace ShippedThemesTest

open Editor

/-- The faces whose colours the Fairy Floss module's table of choices
records (`ShippedThemes/FairyFloss.lean`): each face's foreground and
background as the table gives them, read from `c`. -/
def fairyFlossChoices (c : ShippedThemes.FairyFloss.Colours) :
    List (String × Option Color × Option Color) :=
  let cursors :=
    ["cursor", "cursor.normal", "cursor.insert", "cursor.visual", "cursor.visual-line",
      "cursor.minibuffer"]
  [("default", some c.foreground, some c.background), ("selection", none, some c.selection)] ++
    cursors.map (·, some c.background, some c.caret) ++
    [("mode-line", some c.foreground, some c.lineHighlight),
      ("mode-line.active", some c.foreground, some c.selection),
      ("mode-line.inactive", some c.lavender, some c.background),
      ("window-divider", some c.lavender, none), ("echo-area", some c.foreground, none),
      ("mode-line.state.normal", some c.background, some c.pink),
      ("mode-line.state.insert", some c.background, some c.added),
      ("mode-line.state.visual", some c.background, some c.lavender),
      ("mode-line.state.visual-line", some c.background, some c.lavender),
      ("mode-line.state.minibuffer", some c.background, some c.mint),
      ("mode-line.buffer", some c.foreground, none), ("mode-line.modified", some c.peach, none),
      ("mode-line.secondary", some c.lavender, none), ("minibuffer.prompt", some c.mint, none),
      ("minibuffer.candidate", some c.lavender, none),
      ("minibuffer.chosen", some c.background, some c.mint),
      ("syntax.attribute", some c.lemon, none), ("syntax.comment", some c.gold, none),
      ("syntax.constant", some c.lavender, none), ("syntax.constructor", some c.lemon, none),
      ("syntax.embedded", some c.foreground, none), ("syntax.function", some c.lemon, none),
      ("syntax.keyword", some c.pink, none), ("syntax.module", some c.lemon, none),
      ("syntax.number", some c.lavender, none), ("syntax.operator", some c.pink, none),
      ("syntax.property", some c.foreground, none), ("syntax.punctuation", some c.foreground, none),
      ("syntax.string", some c.yellow, none), ("syntax.tag", some c.pink, none),
      ("syntax.type", some c.mint, none), ("syntax.variable", some c.foreground, none),
      ("diff.added", some c.added, none), ("diff.removed", some c.removed, none),
      ("diff.changed", some c.modified, none), ("gutter", some c.foreground, some c.background),
      ("search-match", some c.background, some c.lemon), ("review-unexamined", none, none),
      ("block-header", some c.foreground, some c.lineHighlight),
      ("compilation.error", some c.removed, none), ("compilation.warning", some c.peach, none),
      ("compilation.note", some c.added, none)]

/-- Whether `theme` gives each face of `fairyFlossChoices c` the colours
listed, and the weight, slant and underline the table records. -/
def fairyFlossChosen (theme : Theme) (c : ShippedThemes.FairyFloss.Colours) : Bool :=
  let face (name : String) : Face := theme.merged ⟨name⟩
  (fairyFlossChoices c).all
      (fun (name, foreground, background) =>
        (face name).foreground == foreground && (face name).background == background) &&
    (badgeFaces ++
          ["mode-line.buffer", "minibuffer.prompt", "block-header", "compilation.error",
            "compilation.warning", "compilation.note"]).all
      (fun name => (face name).weight == some 700) &&
    (face "syntax.comment").slant == some .upright &&
    (face "syntax.type").slant == some .italic &&
    (face "review-unexamined").underline == some { style := .single, color := some c.peach }

/-- The checks of the Fairy Floss theme (`ShippedThemes/FairyFloss.lean`):
the nineteen colours are sailorhg's published values, the source's commit
is recorded, the faces are the choices the module's table records, and the
theme is shipped. That it passes the completeness check is
`shippedThemesChecks`', over every shipped theme. -/
def fairyFlossChecks : List Check :=
  let c := ShippedThemes.FairyFloss.published
  [{  name := "each of Fairy Floss's nineteen colours is its published value"
      run :=
        pure
          ([c.background, c.foreground, c.caret, c.invisibles, c.lineHighlight, c.selection, c.gold,
                  c.yellow, c.lavender, c.pink, c.mint, c.lemon, c.peach, c.invalid, c.deprecated,
                  c.renamed, c.added, c.modified, c.removed].map
              (·.word) ==
            [0x5a5475ff, 0xf8f8f2ff, 0xf8f8f0ff, 0x3b3a32ff, 0x3e3d32ff, 0x49483eff, 0xe6c000ff,
              0xffea00ff, 0xc5a3ffff, 0xffb8d1ff, 0xc2ffdfff, 0xfff352ff, 0xff857fff, 0xf92672ff,
              0xae81ffff, 0x96cbfeff, 0xa8ff60ff, 0xe9c062ff, 0xcc6666ff]) },
    { name := "the source's commit is recorded"
      run := pure (ShippedThemes.FairyFloss.commit == "982e64a9e36160350125c0a82a7981dca6200150") },
    { name := "the faces are the choices recorded in the module's table"
      run := pure (fairyFlossChosen ShippedThemes.FairyFloss.fairyFloss.theme c) },
    { name := "the default is foreground on background"
      run :=
        let face := ShippedThemes.FairyFloss.fairyFloss.theme.merged ⟨"default"⟩
        pure (face.foreground == some c.foreground && face.background == some c.background) },
    { name := "fairy-floss is shipped"
      run :=
        pure
          (ShippedThemes.themes.contains ShippedThemes.FairyFloss.fairyFloss &&
            ShippedThemes.FairyFloss.fairyFloss.name == "fairy-floss") }]

end ShippedThemesTest
