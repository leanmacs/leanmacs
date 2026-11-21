import Editor.Completion.Displays
import Editor.Completion.Styles
import Editor.Package

/-!
# The `completion` package: the completion styles and displays that ship

What a host registers so that a prompt is matched and shown with the styles
and displays that ship: the package `completion` (`Completion.package`,
`Editor/Package.lean`), for the owner `completion`, when its loop starts,
before any config (`Editor/Config/Packages.lean`).

- **The styles** that ship (`Completion.Styles.shipped`,
  `Editor/Completion/Styles.lean`): `fuzzy`, `orderless` and `path`, so
  config's `useStyle` and `useStyleFor` can choose them.
- **The displays** that ship (`Completion.Displays.shipped`,
  `Editor/Completion/Displays.lean`): `minibuffer`, which config replaces
  by defining a display of that name, to set its rows.

A host that is not handed it still matches and shows a prompt: with no
style or display registered, the registry falls back to the core's own
(`Completion.Style.unregistered`, `Completion.Display.unregistered`;
`Config.Registry.styleEntry`, `Config.Registry.displayEntry`), and a
config's choice of `fuzzy`, `orderless` or `path` then names no style.

The data stays in the core modules, which name no package; this module is
what a host is handed.

Pinned by `ModelTest.completionPackageChecks`.
-/

namespace Editor.Completion

/-- The package `completion`: the completion styles that ship, then the
completion displays that ship. -/
def package : Package :=
  { name := "completion"
    setup := do
      for style in Styles.shipped do
        defineStyle style
      for display in Displays.shipped do
        defineDisplay display }

end Editor.Completion
