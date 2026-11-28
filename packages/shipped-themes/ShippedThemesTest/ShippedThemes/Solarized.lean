import Editor.Face
import Editor.Scene
import ShippedThemes
import ShippedThemes.Solarized
import ShippedThemesTest.Check
import ShippedThemesTest.Support.Themes

/-!
# The tests of `ShippedThemes/Solarized.lean`

The tests of `ShippedThemes/Solarized.lean`: `solarizedChecks`. The test
driver's root, `ShippedThemesTest/Model.lean`, runs them; its module doc says
what each shows.
-/

namespace ShippedThemesTest

open Editor

/-- The faces whose colours the Solarized module's table of choices records
(`ShippedThemes/Solarized.lean`), in dark names: each face's foreground and
background as the table gives them, read from `c`, so that the same list
read from the light colours is the light theme's. -/
def solarizedChoices (c : ShippedThemes.Solarized.Colours) :
    List (String × Option Color × Option Color) :=
  let cursors :=
    ["cursor", "cursor.normal", "cursor.insert", "cursor.visual", "cursor.visual-line",
      "cursor.minibuffer"]
  [("default", some c.base0, some c.base03), ("selection", none, some c.base02)] ++
    cursors.map (·, some c.base03, some c.base0) ++
    [("mode-line", some c.base1, some c.base02), ("mode-line.active", some c.base1, some c.base02),
      ("mode-line.inactive", some c.base0, some c.base03), ("window-divider", some c.base01, none),
      ("echo-area", some c.base0, none), ("mode-line.state.normal", some c.base03, some c.blue),
      ("mode-line.state.insert", some c.base03, some c.green),
      ("mode-line.state.visual", some c.base03, some c.magenta),
      ("mode-line.state.visual-line", some c.base03, some c.magenta),
      ("mode-line.state.minibuffer", some c.base03, some c.cyan),
      ("mode-line.buffer", some c.base1, none), ("mode-line.modified", some c.orange, none),
      ("mode-line.secondary", some c.base01, none), ("minibuffer.prompt", some c.blue, none),
      ("minibuffer.candidate", some c.base1, none),
      ("minibuffer.chosen", some c.base02, some c.base2), ("syntax.attribute", some c.orange, none),
      ("syntax.comment", some c.base01, none), ("syntax.constant", some c.cyan, none),
      ("syntax.constructor", some c.yellow, none), ("syntax.embedded", some c.base0, none),
      ("syntax.function", some c.blue, none), ("syntax.keyword", some c.green, none),
      ("syntax.module", some c.orange, none), ("syntax.number", some c.cyan, none),
      ("syntax.operator", some c.green, none), ("syntax.property", some c.blue, none),
      ("syntax.punctuation", some c.red, none), ("syntax.string", some c.cyan, none),
      ("syntax.tag", some c.red, none), ("syntax.type", some c.yellow, none),
      ("syntax.variable", some c.blue, none), ("diff.added", some c.green, some c.base02),
      ("diff.removed", some c.red, some c.base02), ("diff.changed", some c.yellow, some c.base02),
      ("gutter", some c.base01, some c.base02), ("search-match", some c.base03, some c.yellow),
      ("review-unexamined", none, none), ("block-header", some c.base1, some c.base02),
      ("compilation.error", some c.red, none), ("compilation.warning", some c.orange, none),
      ("compilation.note", some c.green, none)] ++
    markupHeadings.map (·, some c.blue, none) ++
    [("text.emphasis", none, none), ("text.strong", none, none),
      ("text.code-span", some c.green, none), ("text.code-block", none, some c.base02),
      ("text.link", some c.cyan, none), ("text.quote", some c.base01, none),
      ("text.list-marker", some c.orange, none), ("text.table-header", none, none),
      ("text.prose", none, none)]

/-- Whether `theme` gives each face of `solarizedChoices c` the colours
listed, and keeps the weight, slant and underline the table keeps. -/
def solarizedChosen (theme : Theme) (c : ShippedThemes.Solarized.Colours) : Bool :=
  let face (name : String) : Face := theme.merged ⟨name⟩
  (solarizedChoices c).all
      (fun (name, foreground, background) =>
        (face name).foreground == foreground && (face name).background == background) &&
    (badgeFaces ++
          ["mode-line.buffer", "minibuffer.prompt", "block-header", "compilation.error",
            "compilation.warning", "compilation.note", "text.strong", "text.table-header"] ++
          markupHeadings).all
      (fun name => (face name).weight == some 700) &&
    markupKept face &&
    (face "syntax.comment").slant == some .italic &&
    (face "review-unexamined").underline == some { style := .single, color := some c.orange }

/-- The checks of the Solarized themes (`ShippedThemes/Solarized.lean`):
the sixteen colours are Solarized's published values, the light colours
swap the four base pairs, each variant's faces are the choices the module's
table records, and both variants are shipped. That they pass the
completeness check is `shippedThemesChecks`', over every shipped theme. -/
def solarizedChecks : List Check :=
  let c := ShippedThemes.Solarized.published
  [{  name := "each of Solarized's sixteen colours is its published value"
      run :=
        pure
          ([c.base03, c.base02, c.base01, c.base00, c.base0, c.base1, c.base2, c.base3, c.yellow,
                  c.orange, c.red, c.magenta, c.violet, c.blue, c.cyan, c.green].map
              (·.word) ==
            [0x002b36ff, 0x073642ff, 0x586e75ff, 0x657b83ff, 0x839496ff, 0x93a1a1ff, 0xeee8d5ff,
              0xfdf6e3ff, 0xb58900ff, 0xcb4b16ff, 0xdc322fff, 0xd33682ff, 0x6c71c4ff, 0x268bd2ff,
              0x2aa198ff, 0x859900ff]) },
    { name := "light swaps the four base pairs and keeps the accents"
      run :=
        let l := c.light
        pure
          (l.base03 == c.base3 && l.base3 == c.base03 && l.base02 == c.base2 &&
            l.base2 == c.base02 &&
            l.base01 == c.base1 &&
            l.base1 == c.base01 &&
            l.base00 == c.base0 &&
            l.base0 == c.base00 &&
            [l.yellow, l.orange, l.red, l.magenta, l.violet, l.blue, l.cyan, l.green] ==
              [c.yellow, c.orange, c.red, c.magenta, c.violet, c.blue, c.cyan, c.green] &&
            l.light == c &&
            l != c) },
    { name := "each variant's faces are the choices recorded in the module's table"
      run :=
        pure
          (solarizedChosen ShippedThemes.Solarized.dark.theme c &&
            solarizedChosen ShippedThemes.Solarized.light.theme c.light) },
    { name := "each variant's default is the specification's pair: base0 on base03, base00 on base3"
      run :=
        let dark := ShippedThemes.Solarized.dark.theme.merged ⟨"default"⟩
        let light := ShippedThemes.Solarized.light.theme.merged ⟨"default"⟩
        pure
          (dark.background == some c.base03 && dark.foreground == some c.base0 &&
            light.background == some c.base3 &&
            light.foreground == some c.base00) },
    { name := "the two variants define the same names in the same order, and are not the same theme"
      run :=
        let dark := ShippedThemes.Solarized.dark.theme
        let light := ShippedThemes.Solarized.light.theme
        pure (dark.map (·.name) == light.map (·.name) && dark != light) },
    { name := "solarized-dark and solarized-light are shipped"
      run :=
        pure
          ([ShippedThemes.Solarized.dark, ShippedThemes.Solarized.light].all
              ShippedThemes.themes.contains &&
            ShippedThemes.Solarized.dark.name == "solarized-dark" &&
            ShippedThemes.Solarized.light.name == "solarized-light") }]

end ShippedThemesTest
