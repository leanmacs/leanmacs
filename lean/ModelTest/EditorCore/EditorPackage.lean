import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Reload
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
  #["evil", "ex", "frame-commands", "menu", "window-commands", "tab-commands", "themes",
    "project-search", "working-set", "restore", "package-set", "shell", "version-control",
    "version-control-gutter"]

/-- The checks of the packages of the core's Lake package
(`EditorCore/EditorPackage.lean`): the list a host is handed is whole,
every package of it is accepted, and what it registers is all theirs. -/
def packageSetChecks : List Check :=
  [{  name :=
        "the shipped set keeps exactly two stores across a restart, the shell's history and version control's reviews, reports exactly the jobs a person waits on: the search, the package-set build, the shell's run, and version control's apply, hunk apply and commit, and leaves exactly the jobs their owner starts again to it: the restore's six and the gutter's three"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure <|
          state.registry.codecs.map (fun (owner, codec) => (owner.name, codec.name)) ==
              #[("shell", "shell-history"), ("version-control", "vc-review")] &&
            (state.registry.jobs.filter (·.registration.reported)).map (·.registration.name) ==
              #["project-search", "package-build", "shell-run", "vc-status-apply", "vc-hunk-apply",
                "vc-commit-run"] &&
            (state.registry.jobs.filter (·.registration.restarted)).map (·.registration.name) ==
              #["restore", "restore-files", "restore-write", "restore-save", "restart-probe",
                "restart-save", "vc-gutter-head", "vc-gutter-diff", "vc-gutter-refs"] },
    { name :=
        "every package of the shipped set is accepted, and their names are the 14 of the package table, each once, in its order, with no package of the shipped palettes and none of the file commands, the buffer commands, the workspaces, the compile mode, the languages, the mode line, the command prompt, the binding search, the completion styles and displays, completion at point or the minibuffer among them"
      run :=
        let (state, refused) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure
          (refused == #[] &&
            EditorCore.EditorPackage.packages.map (·.name) == shippedPackageNames &&
            shippedPackageNames.size == 14 &&
            shippedPackageNames.toList.eraseDups.length == 14 &&
            !shippedPackageNames.contains "files" &&
            !shippedPackageNames.contains "buffers" &&
            !shippedPackageNames.contains "workspace" &&
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
            state.registry.entries.size > 100 &&
            (state.registry.menuBar?).isSome &&
            state.cells.cells.all fun cell => shippedPackageNames.contains cell.owner.name) },
    { name :=
        "the shipped set binds the ex names in this order: the files', the ex line's and the buffers', the restore's restart, the package set's three, then version control's twelve; the compile mode's six are bound by a package outside the core's Lake package"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure
          (state.registry.exNames ==
            #["w", "w!", "e", "e!", "autoread", "noautoread", "q", "wq", "reload", "b", "ls", "bd",
              "restart", "package-install", "package-remove", "package-update", "vc-status",
              "vc-show", "vc-stage-hunk", "vc-unstage-hunk", "vc-commit", "vc-worktrees",
              "vc-commit-accept", "vc-commit-abort", "vc-review", "vc-review-since", "vc-log",
              "vc-blame"]) },
    { name :=
        "the shipped set registers one theme, `default`: the palettes that ship are a package outside the core's Lake package"
      run :=
        let (state, _) : ModelState × Array String :=
          Config.State.ofPackages EditorCore.EditorPackage.packages
        pure (state.registry.themeNames == #["default"]) }]

end ModelTest
