import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Face
import Editor.Package
import Editor.TabBar
import Editor.Themes.Check
import Editor.Themes.Shipped
import ModelTest.Check
import ModelTest.Support.Elaborator

/-!
# Model tests: `Editor/Themes/Shipped.lean`

The model tests of `Editor/Themes/Shipped.lean`: `shippedThemesChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the `shipped-themes` package
(`Editor/Themes/Shipped.lean`): it registers its themes and nothing else,
and each of them is whole. Which names a host finds them under, and that
this package owns them there, is `ConfigTest.shippedChecks`'. -/
def shippedThemesChecks : List Check :=
  [{  name :=
        "the package shipped-themes is accepted alone and registers its three themes, in order, and nothing of any other kind"
      run :=
        let (state, refused) : Config.State Elaborated × Array String :=
          Config.State.ofPackages #[Themes.Shipped.package]
        pure
          (refused == #[] && Themes.Shipped.themes.size == 3 &&
            state.registry.themes.map (·.named) == Themes.Shipped.themes &&
            state.registry.ownersByKind.flatten.size == 3 &&
            state.cells.cells.isEmpty) },
    { name := "every theme of shipped-themes has no problem the completeness check finds"
      run := pure (Themes.Shipped.themes.all (Themes.problems ·.theme == #[])) },
    { name :=
        "every theme of shipped-themes pads the mode line and the echo area 3 points above and below, and its default face sets no padding"
      run :=
        pure
          (Themes.Shipped.themes.all fun named =>
            (named.theme.merged ⟨"mode-line"⟩).verticalPadding == some 3 &&
              (named.theme.merged ⟨"echo-area"⟩).verticalPadding == some 3 &&
              (named.theme.merged ⟨"default"⟩).verticalPadding == some 0) },
    { name := "every theme of shipped-themes defines the tab bar's faces"
      run :=
        pure
          (Themes.Shipped.themes.all fun named =>
            [TabBar.face, TabBar.selectedFace].all fun name => named.theme.any (·.name == name)) }]

end ModelTest
