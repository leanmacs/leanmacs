import Editor.Appearance
import Editor.Config.Packages
import Editor.Face
import Editor.Package
import Editor.TabBar
import Editor.Themes.Check
import ShippedThemes
import ShippedThemesTest.Check

/-!
# The tests of `ShippedThemes.lean`

The tests of `ShippedThemes.lean` that need no Rust library:
`shippedThemesChecks`. The test driver's root, `ShippedThemesTest/Model.lean`,
runs them; its module doc says what each shows. They read what the package
registers through the core's test double for that
(`Config.State.ofPackages`, `Editor/Config/Packages.lean`) and run the
core's completeness check (`Themes.problems`, `Editor/Themes/Check.lean`).
-/

namespace ShippedThemesTest

open Editor

/-- The checks of the `shipped-themes` package
(`ShippedThemes.lean`): it registers its themes and nothing else, each of
them is whole, and each paper is light or dark as its theme's name says.
That an editor built from a set with this package offers them from
`load-theme`, after `default`, is the fixture `tests/headless/load-theme`'s. -/
def shippedThemesChecks : List Check :=
  [{  name :=
        "the package shipped-themes is accepted alone and registers its three themes, in order, and nothing of any other kind"
      run :=
        let (state, refused) : Config.State Unit Unit × Array String :=
          Config.State.ofPackages #[ShippedThemes.package]
        pure
          (refused == #[] && ShippedThemes.themes.size == 3 &&
            state.registry.themes.map (·.named) == ShippedThemes.themes &&
            state.registry.ownersByKind.flatten.size == 3 &&
            state.cells.cells.isEmpty) },
    { name := "every theme of shipped-themes has no problem the completeness check finds"
      run := pure (ShippedThemes.themes.all (Themes.problems ·.theme == #[])) },
    { name :=
        "every theme of shipped-themes pads the mode line and the echo area 3 points above and below, and its default face sets no padding"
      run :=
        pure
          (ShippedThemes.themes.all fun named =>
            (named.theme.merged ⟨"mode-line"⟩).verticalPadding == some 3 &&
              (named.theme.merged ⟨"echo-area"⟩).verticalPadding == some 3 &&
              (named.theme.merged ⟨"default"⟩).verticalPadding == some 0) },
    { name := "every theme of shipped-themes defines the tab bar's faces"
      run :=
        pure
          (ShippedThemes.themes.all fun named =>
            [TabBar.face, TabBar.selectedFace].all fun name => named.theme.any (·.name == name)) },
    { name :=
        "the papers of solarized-dark and fairy-floss are dark and solarized-light's is light, so the window is asked for the appearance each name says"
      run :=
        pure
          (ShippedThemes.themes.map
              (fun named => (named.name, named.theme.paper.map Appearance.ofPaper)) ==
            #[("solarized-dark", some .dark), ("solarized-light", some .light),
              ("fairy-floss", some .dark)]) }]

end ShippedThemesTest
