import Editor.ProjectMode
import Editor.Value
import Editor.Workspace
import ModelTest.Check

/-!
# Model tests: `Editor/ProjectMode.lean`

The model tests of `Editor/ProjectMode.lean`: `contributionChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of what a minor mode contributes, as data
(`Editor/ProjectMode.lean`): pure, on values written here. How `setup`
registers a contribution and the registry holds it are
`ModelTest.setupChecks` and `ModelTest.registryChecks`. -/
def contributionChecks : List Check :=
  let remote : Project.Identity := .remote "github.com/o/r"
  let other : Project.Identity := .remote "github.com/o/other"
  [{  name :=
        "a contribution given a mode and its markers alone has no command, no format and no listing, and its root is its nearest marker"
      run :=
        let contribution : Compile.Contribution := { mode := "m-mode", markers := #["m.toml"] }
        pure
          (contribution.commands.isEmpty && contribution.formats.isEmpty &&
            contribution.listing.isNone &&
            !contribution.outermost) },
    { name :=
        "a contribution's marker mode carries its mode, its markers in order and whether its root is its outermost marker"
      run :=
        let contribution : Compile.Contribution :=
          { mode := "m-mode", markers := #["m.toml", "n.toml"], outermost := true }
        pure
          (contribution.markerMode ==
              { mode := "m-mode", markers := #["m.toml", "n.toml"], outermost := true } &&
            ({ contribution with outermost := false }).markerMode.outermost == false) },
    { name :=
        "a hook's project commands for a project are the ones config gave its identity, in config's order, and none for another project"
      run :=
        let first : Compile.ProjectCommands :=
          { project := remote, mode := "a-mode",
            commands := #[{ name := "lint", line := "a-lint" }] }
        let second : Compile.ProjectCommands :=
          { project := other, mode := "a-mode",
            commands := #[{ name := "lint", line := "o-lint" }] }
        let third : Compile.ProjectCommands :=
          { project := remote, mode := "b-mode", settings := [("profile", .str "dev")] }
        let hook : Compile.Hook := { projects := #[first, second, third] }
        pure
          (hook.projectsOf remote == #[first, third] && hook.projectsOf other == #[second] &&
            (hook.projectsOf (.remote "github.com/o/none")).isEmpty) },
    { name :=
        "a hook's settings for a project and a mode are those of config's first entry for both, and none for a mode or a project config gave none"
      run :=
        let hook : Compile.Hook :=
          {
            projects :=
              #[{ project := remote, mode := "a-mode", settings := [("profile", .str "dev")] },
                { project := remote, mode := "a-mode", settings := [("profile", .str "late")] },
                { project := other, mode := "b-mode", settings := [("jobs", .nat 4)] }] }
        pure
          (hook.settingsOf remote "a-mode" == [("profile", .str "dev")] &&
            hook.settingsOf other "b-mode" == [("jobs", .nat 4)] &&
            (hook.settingsOf remote "b-mode").isEmpty &&
            (hook.settingsOf other "a-mode").isEmpty) }]

end ModelTest
