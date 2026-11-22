import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Face
import Editor.Package
import EditorCore.EditorPackage
import ModelTest.Check
import ModelTest.Support.Elaborator

/-!
# Model tests: `EditorCore/EditorPackage.lean`

The model tests of `EditorCore/EditorPackage.lean`, the core's entry
module: `packageSetChecks`. The root module `ModelTest` runs them; its
module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The names of the packages of the core's Lake package, in the order they
register. -/
def shippedPackageNames : Array String :=
  #["ex", "frame-commands", "menu", "window-commands", "tab-commands", "restore", "package-set"]

/-- The checks of the packages of the core's Lake package
(`EditorCore/EditorPackage.lean`): the list a host is handed is whole,
every package of it is accepted, and what it registers is all theirs. -/
def packageSetChecks : List Check :=
  [{  name :=
        "the shipped set keeps no store across a restart, reports exactly the job a person waits on, the package-set build, and leaves exactly the jobs their owner starts again to it: the restore's six"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure <|
          state.registry.codecs.isEmpty &&
            (state.registry.jobs.filter (·.registration.reported)).map (·.registration.name) ==
              #["package-build"] &&
            (state.registry.jobs.filter (·.registration.restarted)).map (·.registration.name) ==
              #["restore", "restore-files", "restore-write", "restore-save", "restart-probe",
                "restart-save"] },
    { name :=
        "every package of the shipped set is accepted, and their names are the 7 of the package table, each once, in its order, with no package of the shipped palettes and none of evil, the themes, the file commands, the buffer commands, the workspaces, project search, the working sets, the shell, version control and its gutter, the compile mode, the languages, the mode line, the command prompt, the binding search, the completion styles and displays, completion at point or the minibuffer among them"
      run :=
        let (state, refused) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure
          (refused == #[] &&
            EditorCore.EditorPackage.packages.map (·.name) == shippedPackageNames &&
            shippedPackageNames.size == 7 &&
            shippedPackageNames.toList.eraseDups.length == 7 &&
            !shippedPackageNames.contains "evil" &&
            !shippedPackageNames.contains "themes" &&
            !shippedPackageNames.contains "files" &&
            !shippedPackageNames.contains "buffers" &&
            !shippedPackageNames.contains "workspace" &&
            !shippedPackageNames.contains "project-search" &&
            !shippedPackageNames.contains "working-set" &&
            !shippedPackageNames.contains "shell" &&
            !shippedPackageNames.contains "version-control" &&
            !shippedPackageNames.contains "version-control-gutter" &&
            !shippedPackageNames.contains "shipped-themes" &&
            !shippedPackageNames.contains "compile" &&
            !shippedPackageNames.contains "languages" &&
            !shippedPackageNames.contains "mode-line" &&
            !shippedPackageNames.contains "execute-command" &&
            !shippedPackageNames.contains "binding-search" &&
            !shippedPackageNames.contains "completion" &&
            !shippedPackageNames.contains "at-point" &&
            !shippedPackageNames.contains "minibuffer" &&
            state.packages == shippedPackageNames &&
            EditorCore.EditorPackage.packages.all fun package =>
              package.collected.toOption.isSome) },
    { name :=
        "in the state the shipped set makes, every entry's owner is a package of the set: of every kind there is an entry, and none is config's or the owner compiled's"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        let owners := state.registry.ownersByKind.flatten
        pure
          (owners.all (fun owner => shippedPackageNames.contains owner.name) &&
            !owners.contains .config &&
            !owners.contains .compiled &&
            state.registry.entries.size > 60 &&
            (state.registry.menuBar?).isSome &&
            state.cells.cells.all fun cell => shippedPackageNames.contains cell.owner.name) },
    { name :=
        "the shipped set binds the ex names in this order: the files', the ex line's and the buffers', the restore's restart, then the package set's three; version control's twelve and the compile mode's six are bound by packages outside the core's Lake package"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure
          (state.registry.exNames ==
            #["w", "w!", "e", "e!", "autoread", "noautoread", "q", "wq", "reload", "b", "ls", "bd",
              "restart", "package-install", "package-remove", "package-update"]) },
    { name :=
        "the shipped set registers no theme: the themes are a package outside the core's Lake package, as the palettes that ship are, and the theme in force with none registered is named `default`"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure (state.registry.themeNames == #[] && Theme.defaultName == "default") }]

end ModelTest
