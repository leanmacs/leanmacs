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
  #[]

/-- The packages of the core's Lake package (`EditorCore.EditorPackage.packages`),
as an array of packages. -/
def shippedPackages : Array Package :=
  EditorCore.EditorPackage.packages

/-- The checks of the packages of the core's Lake package
(`EditorCore/EditorPackage.lean`): the list a host is handed is empty, and
a host handed it starts from a registry that holds nothing. -/
def packageSetChecks : List Check :=
  [{  name :=
        "the shipped set keeps no store across a restart, reports no job (the one a person waits on, the package-set build, is registered by the package `package-set`, outside the core's Lake package), and leaves no job to its owner to start again (the restore's six are registered by the package `restore`, outside it too)"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure <|
          state.registry.codecs.isEmpty &&
            (state.registry.jobs.filter (·.registration.reported)).map (·.registration.name) ==
              #[] &&
            (state.registry.jobs.filter (·.registration.restarted)).map (·.registration.name) ==
              #[] },
    { name :=
        "every package of the shipped set is accepted, and their names are the 0 of the package table: the core's Lake package registers no package, none of the shipped palettes and none of the ex line, the frame commands, the menu, the window commands, the tab commands, session restore, the package-set commands, evil, the themes, the file commands, the buffer commands, the workspaces, project search, the working sets, the shell, version control and its gutter, the compile mode, the languages, the mode line, the command prompt, the binding search, the completion styles and displays, completion at point or the minibuffer among them"
      run :=
        let (state, refused) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure
          (refused == #[] && shippedPackages.map (·.name) == shippedPackageNames &&
            shippedPackages.isEmpty &&
            shippedPackageNames.size == 0 &&
            !shippedPackageNames.contains "ex" &&
            !shippedPackageNames.contains "frame-commands" &&
            !shippedPackageNames.contains "menu" &&
            !shippedPackageNames.contains "window-commands" &&
            !shippedPackageNames.contains "tab-commands" &&
            !shippedPackageNames.contains "restore" &&
            !shippedPackageNames.contains "package-set" &&
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
            shippedPackages.all fun package => package.collected.toOption.isSome) },
    { name :=
        "the state the shipped set makes holds no command and no entry of any owner, config's and the owner compiled's among them; it defines no menu: the menu bar that ships is the package `menu`'s, outside the core's Lake package"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        let owners := state.registry.ownersByKind.flatten
        pure
          (owners.all (fun owner => shippedPackageNames.contains owner.name) &&
            !owners.contains .config &&
            !owners.contains .compiled &&
            owners.isEmpty &&
            state.registry.entries.isEmpty &&
            state.registry.menuBar? == none &&
            state.cells.cells.all fun cell => shippedPackageNames.contains cell.owner.name) },
    { name :=
        "the shipped set binds no ex name: the files', the ex line's and the buffers' are bound by the package `ex`, and the restore's restart, the package set's three, version control's twelve and the compile mode's six by theirs, each outside the core's Lake package"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure (state.registry.exNames == #[]) },
    { name :=
        "the shipped set registers no theme: the themes are a package outside the core's Lake package, as the palettes that ship are, and the theme in force with none registered is named `default`"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure (state.registry.themeNames == #[] && Theme.defaultName == "default") }]

end ModelTest
