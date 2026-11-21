import BuffersApi
import Editor.Extension
import Editor.Package
import WorkingSet.Run

/-!
# The `working-set` package: the working sets' commands, mode and jobs

What a host registers, as the package `working-set` (`WorkingSet.package`,
`Editor/Package.lean`), so that a selection can be added to a named working
set and a set opened as an excerpt buffer of its ranges
(`WorkingSet/Run.lean`). A host of a set that holds this Lake package
registers it for the owner `working-set` when its loop starts, before any
config (`Editor/Config/Packages.lean`), after the `workspace` package.

- **The commands**: `working-set-add` and `working-set-open`, under the
  names of the interface package `working-set-api`
  (`WorkingSetApi.addName`, `WorkingSetApi.openName`), which a reacher
  names,
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
  (`WorkingSet/Disk.lean`); `working-set-write` is registered over
  the version-control backend point (`VcApi.Backend`), which it asks for
  the commit `HEAD` is at.
- **The hooks** of the interface library `files-api`: at `FilesApi.Opened`
  the working sets place a file's ranges once a buffer holds it
  (`WorkingSet.attach`), and at `FilesApi.Saved` they write the sets that
  hold ranges of a file written (`WorkingSet.fileSaved`), so neither the
  files feature nor this one names the other; and at `buffers-api`'s
  `BuffersApi.Closing` they detach the ranges a closing buffer holds and
  free a set's buffer's drifted quotes.

Pinned by `WorkingSetTest.workingSetRunChecks`, on the models, and by
`WorkingSetTest.workingSetPackageChecks`: `working-set-api`'s contract over
the package, and what it registers, over the registry it makes alone.
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
      Extension.add
          ({ name := "working-set", opened := fun id path => attach id path } : FilesApi.Opened)
      Extension.add ({ name := "working-set", saved := fileSaved } : FilesApi.Saved)
      Extension.add
          ({  name := "working-set"
              closing := fun id => do
                discard <| detach id
                freeDrifted id } :
            BuffersApi.Closing)
      Extension.workJob VcApi.Backend writeJob fun backends => writeWork (VcApi.connect? backends)
      workJob saveJob saveWork }

end Editor.WorkingSet
