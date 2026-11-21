import Completion.Displays
import Completion.Styles
import Editor.Package

/-!
# The `completion` package: the completion styles and displays that ship

What a host registers so that a prompt is matched and shown with the styles
and displays that ship: the package `completion` (`Completion.package`,
the core's `lean/Editor/Package.lean`), which the entry module
`Completion/EditorPackage.lean` lists. A host registers it for the owner
`completion` when its loop starts, before any config (the core's
`lean/Editor/Config/Packages.lean`).

- **The styles** that ship (`Completion.Styles.shipped`,
  `Completion/Styles.lean`): `fuzzy`, `orderless` and `path`, so config's
  `useStyle` and `useStyleFor` can choose them. `path` is the name the
  interface package `completion-api` declares (`CompletionApi.names`),
  which the core's files package reaches.
- **The displays** that ship (`Completion.Displays.shipped`,
  `Completion/Displays.lean`): `minibuffer`, which config replaces
  by defining a display of that name, to set its rows.

A host that is not handed it still matches and shows a prompt: with no
style or display registered, the registry falls back to the core's own
(`Completion.Style.unregistered`, `Completion.Display.unregistered`;
`Config.Registry.styleEntry`, `Config.Registry.displayEntry`), and a
config's choice of `fuzzy`, `orderless` or `path` then names no style.

This module is apart from the styles and displays because it is what a
host is handed, not what config calls.

Pinned by `CompletionTest.completionPackageChecks`, which also runs the
contract check of `completion-api` over it
(`CompletionTest/Completion/Compiled.lean`).
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
