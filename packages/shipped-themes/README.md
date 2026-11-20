# shipped-themes

A default package: the themes `solarized-dark`, `solarized-light` and
`fairy-floss`, beside the core's own `default`. Name one in your config
with `useTheme "solarized-dark"`, or pick one with `:load-theme`.

It is also a small, real package to read before writing one
([writing-a-package.md](../../docs/packages/writing-a-package.md)). Its
design record is in [packages.md](../../docs/design/packages.md), "The
first default package: `shipped-themes`".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `shipped-themes`. It
   requires the core, `editor-core`, by path (`../../lean`), declares the
   library `ShippedThemes`, the test library `ShippedThemesTest` and the
   test driver `shipped-themes-test`, and turns every Lean linter on with
   warnings as errors. The library is declared by its name alone: its root
   imports every module but the entry module, and the entry module imports
   no core module.
2. [`ShippedThemes/EditorPackage.lean`](ShippedThemes/EditorPackage.lean):
   the entry module, which the build that links the editor reads.

   ```lean
   def packages : Array Editor.Package :=
     #[ShippedThemes.package]
   ```
3. [`ShippedThemes.lean`](ShippedThemes.lean): the library's root.
   `ShippedThemes.themes` is the list of the three themes, and
   `ShippedThemes.package` is the `Package` value, named `shipped-themes`,
   whose `setup` calls `defineTheme` for each of them and registers nothing
   else. It imports `Editor.Package` and the two palettes.
4. The palettes, each a `Palette` turned into a theme with the core's
   `Palette.theme`, plus that theme's own faces, with its licence beside it:
   - [`ShippedThemes/Solarized.lean`](ShippedThemes/Solarized.lean):
     `Solarized.dark` and `Solarized.light`
     ([`Solarized-LICENSE.txt`](ShippedThemes/Solarized-LICENSE.txt));
   - [`ShippedThemes/FairyFloss.lean`](ShippedThemes/FairyFloss.lean):
     `FairyFloss.fairyFloss`
     ([`FairyFloss-LICENSE.txt`](ShippedThemes/FairyFloss-LICENSE.txt)).

   Both import `Editor.Face` alone.

## Its tests

- **The test driver**, [`ShippedThemesTest/Model.lean`](ShippedThemesTest/Model.lean),
  run by `lake test`. It runs `ShippedThemesTest.shippedThemesChecks`
  ([`ShippedThemesTest/ShippedThemes.lean`](ShippedThemesTest/ShippedThemes.lean)):
  the package is accepted alone and defines the three themes, and each
  passes the core's completeness check (`Themes.problems`); and
  `solarizedChecks` and `fairyFlossChecks`, under
  [`ShippedThemesTest/ShippedThemes/`](ShippedThemesTest/ShippedThemes/),
  which hold each palette's published colour values. The test modules
  mirror the library's, and share
  [`ShippedThemesTest/Check.lean`](ShippedThemesTest/Check.lean) and
  [`ShippedThemesTest/Support/Themes.lean`](ShippedThemesTest/Support/Themes.lean).
- **The linked test**, [`ShippedThemesTest/Linked.lean`](ShippedThemesTest/Linked.lean),
  an executable linked as the editor is. It runs
  [`ShippedThemesTest/Linked/ShippedThemes.lean`](ShippedThemesTest/Linked/ShippedThemes.lean),
  which draws a picture in each theme and compares it with its reference
  image in [`tests/render/`](tests/render/README.md).
- **The headless fixtures**, under [`tests/headless/`](tests/headless/),
  each a config, a script and the output it must print: `themes` switches
  from a theme of config's to two of these; `shipped-themes` starts in the
  `solarized-light` its config names; `load-theme` lists the theme prompt's
  candidates; and `package-names` is a config that names the package's
  declaration `ShippedThemes.themes`.

The gate runs all three kinds over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove shipped-themes` rebuilds your editor without it; the
theme `default` stays
([installing-packages.md](../../docs/packages/installing-packages.md)).
