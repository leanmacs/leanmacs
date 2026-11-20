import Editor.ModeLine
import Editor.Package

/-!
# The `mode-line` package: the segments of the mode line that ship

What a host registers so that it draws the shipped mode line: the package
`mode-line` (`ModeLine.package`, the core's `lean/Editor/Package.lean`),
for the owner `mode-line`, when its loop starts, before any config (the
core's `lean/Editor/Config/Packages.lean`). It is the library of the
default package `mode-line`, a Lake package outside the core
(`packages/mode-line/`), which the entry module
`ModeLine/EditorPackage.lean` lists. It registers the shipped segments
(`ModeLine.shipped`, the core's `lean/Editor/ModeLine.lean`), in order, so the default
listing (`ModeLine.Order.standard`) and config's `modeLine` find them by
name, and config's segment of a shipped name is drawn in its place.

A host that is not handed it has no segment to list, and draws an empty
mode line. `review`, which the default listing names too, is version
control's (the core's `lean/Editor/VersionControl/Compiled.lean`).

The data stays in the core's `lean/Editor/ModeLine.lean`, which names no
package: the core's loop lists it by default and its picture draws it.
This module is what a host is handed. It imports the core's API alone.

Pinned by `ModeLineTest.modeLinePackageChecks`
(`ModeLineTest/ModeLine/Compiled.lean`) and by the headless fixture
`tests/headless/mode-line`.
-/

namespace Editor.ModeLine

/-- The package `mode-line`: the shipped segments of the mode line, in
order. -/
def package : Package :=
  { name := "mode-line"
    setup :=
      for segment in shipped do
        defineSegment segment.name segment.fields }

end Editor.ModeLine
