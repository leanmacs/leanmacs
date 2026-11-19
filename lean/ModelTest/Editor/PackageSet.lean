import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Package
import Editor.PackageSet
import ModelTest.Check
import ModelTest.Support.Elaborator

/-!
# Model tests: `Editor/PackageSet.lean`

The model tests of `Editor/PackageSet.lean`: `packageSetChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The names of the packages that ship, in the order they register. -/
def shippedPackageNames : Array String :=
  #["completion", "mode-line", "files", "minibuffer", "evil", "ex", "buffers", "frame-commands",
    "menu", "window-commands", "tab-commands", "themes", "execute-command", "binding-search",
    "workspace", "shell", "compile", "at-point", "version-control", "version-control-gutter",
    "languages"]

/-- The checks of the packages that ship (`Editor/PackageSet.lean`): the
list a host is handed is whole, every package of it is accepted, and what
it registers is all theirs. -/
def packageSetChecks : List Check :=
  [{  name :=
        "every package of the shipped set is accepted, and their names are the 21 of the package table, each once, in its order"
      run :=
        let (state, refused) : Config.State Elaborated × Array String :=
          Config.State.ofPackages PackageSet.shipped
        pure
          (refused == #[] && PackageSet.shipped.map (·.name) == shippedPackageNames &&
            shippedPackageNames.size == 21 &&
            shippedPackageNames.toList.eraseDups.length == 21 &&
            state.packages == shippedPackageNames &&
            PackageSet.shipped.all fun package => package.collected.toOption.isSome) },
    { name :=
        "in the state the shipped set makes, every entry's owner is a package of the set: of every kind there is an entry, and none is config's or the owner compiled's"
      run :=
        let (state, _) : Config.State Elaborated × Array String :=
          Config.State.ofPackages PackageSet.shipped
        let owners := state.registry.ownersByKind.flatten
        pure
          (owners.all (fun owner => shippedPackageNames.contains owner.name) &&
            !owners.contains .config &&
            !owners.contains .compiled &&
            state.registry.entries.size > 100 &&
            (state.registry.menuBar?).isSome &&
            state.cells.cells.all fun cell => shippedPackageNames.contains cell.owner.name) }]

end ModelTest
