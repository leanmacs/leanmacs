import Editor.Package
import Editor.Themes.FairyFloss
import Editor.Themes.Solarized

/-!
# The `shipped-themes` package: the palettes that ship

The themes that ship beside the built-in one, as a package of their own:
`shipped-themes` (`Themes.Shipped.package`, `Editor/Package.lean`), whose
`setup` defines each theme of `Themes.Shipped.themes` in order
(`defineTheme`) and registers nothing else: `solarized-dark` and
`solarized-light` (`Editor/Themes/Solarized.lean`), then `fairy-floss`
(`Editor/Themes/FairyFloss.lean`).

It is apart from the `themes` package (`Editor/Themes/Compiled.lean`), which
is the core's and registers the command that loads a theme, the theme
`default` and the theme source: this module and the two palettes are not
core modules, and no core module imports them
(`docs/design/packages.md`; `tools/core-imports-check.sh`). The list of the
packages that ship names this package directly after `themes`
(`PackageSet.lean`), so the theme names read `default`, then these.

A new shipped theme is a palette's theme (`Palette.theme`,
`Editor/Face.lean`), plus that theme's own definitions after it, appended to
`themes`, and must pass the completeness check (`Themes.problems`,
`Editor/Themes/Check.lean`), which `ModelTest.shippedThemesChecks` runs on
every theme in the list.

Pinned by `ModelTest.shippedThemesChecks`, `ModelTest.solarizedChecks`,
`ModelTest.fairyFlossChecks` and `ConfigTest.shippedChecks`.
-/

namespace Editor.Themes.Shipped

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

end Editor.Themes.Shipped
