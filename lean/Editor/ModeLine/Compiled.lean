import Editor.ModeLine
import Editor.Package

/-!
# The `mode-line` package: the segments of the mode line that ship

What a host registers so that it draws the shipped mode line: the package
`mode-line` (`ModeLine.package`, `Editor/Package.lean`), for the owner
`mode-line`, when its loop starts, before any config
(`Editor/Config/Packages.lean`). It registers the shipped segments
(`ModeLine.shipped`, `Editor/ModeLine.lean`), in order, so the default
listing (`ModeLine.Order.standard`) and config's `modeLine` find them by
name, and config's segment of a shipped name is drawn in its place.

A host that is not handed it has no segment to list, and draws an empty
mode line. `review`, which the default listing names too, is version
control's (`Editor/VersionControl/Compiled.lean`).

The data stays in `Editor/ModeLine.lean`, which names no package; this
module is what a host is handed.

Pinned by `ModelTest.modeLinePackageChecks`.
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
