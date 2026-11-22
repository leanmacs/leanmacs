import AtPoint
import AtPoint.Words
import Editor.Package

/-!
# The `at-point` package: completion at point

What a host registers for completion at point: the package `at-point`
(`AtPoint.package`, the core's `lean/Editor/Package.lean`), which the entry
module `AtPoint/EditorPackage.lean` lists. A host registers it for the
owner `at-point` when its loop starts, before any config (the core's
`lean/Editor/Config/Packages.lean`).

- **The commands** (`AtPoint.lean`), which the Vim scheme's insert
  state binds, under the names the interface package `at-point-api`
  declares (`AtPointApi.names`).
- **The job** of the shipped `words` source (`Completion.Words.job`,
  `AtPoint/Words.lean`): it is the package's, so a reload does
  not cancel it.
- **The shipped source** (`Completion.Words.shipped`) and **the shipped
  at-point source** (`Completion.AtPoint.shipped`), and **the use of
  `words` for every buffer** (`useAtPoint`), so no core code names it.
-/

namespace Editor.AtPoint

/-- The package `at-point`: completion at point's commands, the job of the
source `words`, the shipped source and the shipped at-point source, and the
use of `words` for every buffer. -/
def package : Package :=
  { name := "at-point"
    setup := do
      commandWith completeName complete
      commandWith nextName (stepOrAsk .next)
      commandWith previousName (stepOrAsk .previous)
      commandWith tabName tab
      commandWith backtabName backtab
      commandWith returnName «return»
      commandWith quitName quit
      commandWith triggeredName triggered
      commandWith pausedName paused
      sourceJob Completion.Words.job Completion.Words.gather
      for source in Completion.Words.shipped do
        defineSource source
      for atPoint in Completion.AtPoint.shipped do
        defineAtPoint atPoint
      useAtPoint Completion.Words.source.name }

end Editor.AtPoint
