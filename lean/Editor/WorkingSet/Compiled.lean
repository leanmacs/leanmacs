import Editor.Package
import Editor.WorkingSet.Run

/-!
# The `working-set` package: the working sets' commands, mode and jobs

What a host registers, as the package `working-set` (`WorkingSet.package`,
`Editor/Package.lean`), so that a selection can be added to a named working
set and a set opened as an excerpt buffer of its ranges
(`Editor/WorkingSet/Run.lean`). A host registers it for the owner
`working-set` when its loop starts, before any config
(`Editor/Config/Packages.lean`).

- **The commands**: `working-set-add`, `working-set-open`,
  `working-set-visit`, `working-set-remove`, `working-set-note` and
  `working-set-refresh`.
- **The mode**: `working-set`, a set's buffer's mode, whose
  activate key (`RET` in the Vim scheme's normal state) runs
  `working-set-visit`, whose refresh key runs `working-set-refresh`, and
  whose locals `d` and `n` run `working-set-remove` and
  `working-set-note`.
- **The jobs**: `working-set-files`, which loads the files of a
  set's ranges that no buffer holds, keyed by the set's buffer's name; and
  `working-set-load`, `working-set-write` and `working-set-save`, which
  read a workspace's sets from the state directory and write them back
  (`Editor/WorkingSet/Disk.lean`).

Pinned by `ModelTest.workingSetRunChecks`, on the models, and by
`ConfigTest.shippedChecks` over the hosts' registry.
-/

namespace Editor.WorkingSet

/-- The package `working-set`: the working sets' commands, a set's
buffer's mode, and the jobs that load a set's files and read and write a
workspace's sets in the state directory. -/
def package : Package :=
  { name := "working-set"
    setup := do
      commandWith addName addCommand
      commandWith openName openCommand
      commandWith visitName visitCommand
      commandWith removeName removeCommand
      commandWith noteName noteCommand
      commandWith refreshName refreshCommand
      defineMode mode
      workJob filesJob filesWork
      workJob loadJob loadWork
      workJob writeJob writeWork
      workJob saveJob saveWork }

end Editor.WorkingSet
