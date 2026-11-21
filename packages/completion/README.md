# completion

A default package: the completion styles and the completion display that
ship. The styles `fuzzy`, the default, `orderless` and `path` decide which
of a prompt's candidates the typed text matches and in what order; the
display `minibuffer` draws the candidate list above the minibuffer's
input, vertico-style. Config chooses them by name (`useStyle`,
`useStyleFor`, `useDisplay`) and defines the display again to set its rows
(`defineDisplay (Completion.Displays.minibuffer (rows := 15))`).

It implements the interface package
[`completion-api`](../completion-api/), which declares the name of the
path style, the one name of it another package reaches: the core's files
package gives the file prompt's category the style `path`. Its design
record is in [packages.md](../../docs/design/packages.md), "The default
packages of the features-as-packages roadmap's phase 4".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `completion`. It
   requires the core, `editor-core`, by path (`../../lean`), and the
   interface package `completion-api` (`../completion-api`), declares the
   library `Completion`, the test library `CompletionTest` and the test
   driver `completion-test`, and turns every Lean linter on with warnings
   as errors.
2. [`Completion/EditorPackage.lean`](Completion/EditorPackage.lean): the
   entry module. It imports `Completion.Compiled`, and so the whole
   library, which is what config sees of the package.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Completion.package]
   ```
3. [`Completion/Compiled.lean`](Completion/Compiled.lean): the `Package`
   value, `Editor.Completion.package`, named `completion`. Its `setup`
   registers each shipped style with `defineStyle`, then each shipped
   display with `defineDisplay`.
4. [`Completion/Styles.lean`](Completion/Styles.lean): the styles, each a
   program over the fuzzy port. The path style's name is
   `CompletionApi.pathStyleName`.
5. [`Completion/Displays.lean`](Completion/Displays.lean): the minibuffer
   display, its rows, faces, annotation column, group headers and window.

Every declaration is in the namespace `Editor.Completion`, where it was in
the core, so config names them as `Completion.Styles.orderless` under
`open Editor`, with `import Completion.Styles` and
`import Completion.Displays`. The library imports the core's completion
interfaces (`Editor.Completion.Style`, `Editor.Completion.Display`), the
core's API alone, and the interface package.

## Its tests

- **The test driver**, [`CompletionTest/Model.lean`](CompletionTest/Model.lean),
  run by `lake test`: `shippedStyleChecks`
  ([`CompletionTest/Completion/Styles.lean`](CompletionTest/Completion/Styles.lean)),
  over the fuzzy model, `minibufferDisplayChecks`
  ([`CompletionTest/Completion/Displays.lean`](CompletionTest/Completion/Displays.lean)),
  and `completionPackageChecks`
  ([`CompletionTest/Completion/Compiled.lean`](CompletionTest/Completion/Compiled.lean)),
  the interface's contract check over the `Package` value.
- **The linked test**, [`CompletionTest/Linked.lean`](CompletionTest/Linked.lean),
  an executable linked as the editor is. It holds the fuzzy style and the
  path style to the completion styles' contract over the library's matcher
  ([`CompletionTest/Linked/Completion/Styles.lean`](CompletionTest/Linked/Completion/Styles.lean)).
- **The headless fixture**, [`tests/headless/completion-choices`](tests/headless/completion-choices/):
  config defines the shipped display again with two rows and chooses
  orderless for a category of its own. It was written on the editor with
  completion still in the core and moved here with two lines changed, its
  config's imports.

The gate runs all three kinds over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove completion` rebuilds your editor without it. A prompt is
then matched by the core's own style, the fuzzy matcher's ranking with no
match ranges, and its candidates are drawn by the core's own display, one
row each with no faces, `> ` before the chosen one; config's choice of `fuzzy`, `orderless` or `path` names no
style, which the install report says
([installing-packages.md](../../docs/packages/installing-packages.md)).
