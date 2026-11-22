import Editor.Package
import ShippedThemes.FairyFloss
import ShippedThemes.Solarized

/-!
# The `shipped-themes` package: the palettes that ship

The themes that ship beside the built-in one, as a package of their own,
outside the core: `shipped-themes` (`ShippedThemes.package`, an
`Editor.Package`, the core's `Editor/Package.lean`), whose `setup` defines
each theme of `ShippedThemes.themes` in order (`defineTheme`) and registers
nothing else: `solarized-dark` and `solarized-light`
(`ShippedThemes/Solarized.lean`), then `fairy-floss`
(`ShippedThemes/FairyFloss.lean`).

This is the library of the Lake package `shipped-themes`
(`lakefile.toml`), a default package: the default package set requires it
(`packages/lakefile.toml`), and the package-set build registers it after
the core's packages, through its entry module
(`ShippedThemes/EditorPackage.lean`; `docs/design/packages.md`). The
default package `themes` (`packages/themes/Themes/Compiled.lean`), which
the default set requires before this one, registers the
command that loads a theme, the theme `default` and the theme source, and
no package between them defines a theme, so the theme names read
`default`, then these. A set without this package still has `load-theme`
and `default`.

It imports modules of the core's API alone (`Editor.Face`,
`Editor.Package`), which the package imports check holds it to
(`tools/package-imports-check.sh`). A path that starts `Editor/` is a
module of the core, under `lean/`.

A new shipped theme is a palette's theme (`Palette.theme`,
`Editor/Face.lean`), plus that theme's own definitions after it, appended to
`themes`, and must pass the core's completeness check (`Themes.problems`,
`Editor/Theme/Check.lean`), which `ShippedThemesTest.shippedThemesChecks`
runs on every theme in the list; its picture gets a reference image
(`tests/render/README.md`).

Pinned by `ShippedThemesTest.shippedThemesChecks`,
`ShippedThemesTest.solarizedChecks` and
`ShippedThemesTest.fairyFlossChecks`, by the package's linked test
(`ShippedThemesTest/Linked.lean`) and by its headless fixtures
(`tests/headless/`).
-/

namespace ShippedThemes

open Editor

/-- The palettes that ship, as the `shipped-themes` package defines them:
Solarized dark and light, then Fairy Floss. -/
def themes : Array NamedTheme :=
  #[Solarized.dark, Solarized.light, FairyFloss.fairyFloss]

/-- The package `shipped-themes`: the palettes that ship (`themes`), and
nothing else. -/
def package : Package :=
  { name := "shipped-themes"
    setup := do
      for named in themes do
        defineTheme named.name named.theme }

end ShippedThemes
