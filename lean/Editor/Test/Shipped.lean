import Editor.Language
import Editor.ModeLine
import Editor.Package

/-!
# The test kit: Shipped

Stand-ins for two default packages, for the core's own tests: `modeLine`,
named `mode-line`, which registers the shipped segments of the mode line
(`ModeLine.shipped`, `Editor/ModeLine.lean`), in order; and `languages`,
named `languages`, which registers the `code` mode (`Language.modes`) and
then the shipped languages (`Language.shipped`, `Editor/Language.lean`), in
order. `packages` is both, in that order.

The data and its names are the core's: the segments, the mode and the
languages stay in core modules, which the core's loop, its picture and its
tests read. The Lake packages `mode-line` and `languages` (`packages/`)
register exactly this, which their own tests pin; the core cannot import
them, so a core test that hosts the core's list and is to show what the
default editor draws appends these (`EditorCore.EditorPackage.packages ++
Test.Shipped.packages`). A package's test that hosts the core's list and
prints what the default editor prints, as the compile mode's linked test
does, appends the one it needs, without requiring that package. They are
no fake of another package's behaviour.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test.Shipped

open Editor

/-- The stand-in `mode-line`: the shipped segments of the mode line, in
order. -/
def modeLine : Package :=
  { name := "mode-line"
    setup :=
      for segment in ModeLine.shipped do
        defineSegment segment.name segment.fields }

/-- The stand-in `languages`: the `code` mode, then the shipped languages,
in order. -/
def languages : Package :=
  { name := "languages"
    setup := do
      for mode in Language.modes do
        defineMode mode
      for language in Language.shipped do
        defineLanguage language }

/-- Both stand-ins: `modeLine`, then `languages`. -/
def packages : Array Package :=
  #[modeLine, languages]

end Editor.Test.Shipped
