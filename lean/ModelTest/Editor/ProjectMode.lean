import Editor.Package
import Editor.ProjectMode
import Editor.Test.Hosted
import Editor.Value
import Editor.Workspace
import ModelTest.Check

/-!
# Model tests: `Editor/ProjectMode.lean`

The model tests of `Editor/ProjectMode.lean`: `contributionChecks`. The root
module `ModelTest` runs them; its module doc says what each shows. The
checks of the two extension points and of the hook that reads them run on
the kit's hosted registry (`Editor/Test/Hosted.lean`): packages installed as
a host installs them, and a config installed as a reload installs what
config owns.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A package called `name` that contributes `modes`, each a mode and its
one marker, in order. -/
def contributing (name : String) (modes : List (String × String)) : Package :=
  { name
    setup :=
      for (mode, marker) in modes do
        compileContribution { mode, markers := #[marker] } }

/-- The contributions of the hook a loop told of `registry` answers, each as
its mode, markers, commands and formats' names. -/
def hookShape (registry : Config.Registry) :
    Option (Array (String × Array String × Array Compile.NamedCommand × Array String)) :=
  (hostedAsked registry Compile.hook).map fun hook =>
    hook.contributions.map fun contribution =>
      (contribution.mode, contribution.markers, contribution.commands,
        contribution.formats.map (·.name))

/-- The modes and markers of the hook's contributions, as a loop told of
`registry` answers them. -/
def hookModes (registry : Config.Registry) : Option (Array (String × Array String)) :=
  (hookShape registry).map fun shapes => shapes.map fun (mode, markers, _, _) => (mode, markers)

/-- The hook's project commands, as a loop told of `registry` answers them:
each as its mode and its commands' lines. -/
def hookProjects (registry : Config.Registry) : Option (Array (String × Array String)) :=
  (hostedAsked registry Compile.hook).map fun hook =>
    hook.projects.map fun entry => (entry.mode, entry.commands.map (·.line))

/-- The checks of what a minor mode contributes (`Editor/ProjectMode.lean`):
on values written here, and of the two extension points and the hook that
reads them, on the kit's hosted registry. -/
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
            (hook.settingsOf other "a-mode").isEmpty) },
    { name :=
        "the hook holds config's contributions first, in config's order, then the packages' whose modes config does not give, each mode once as its latest: config's a-mode replaces a package's a-mode whole, in config's place, and a reload of config to nothing brings the package's back; with nothing registered, and run bare, the hook is empty"
      run :=
        let packageA : Compile.Contribution :=
          { mode := "a-mode", markers := #["a.toml"]
            commands :=
              #[{ name := "build", line := "compiled-build" },
                { name := "lint", line := "compiled-lint" }]
            formats := #[Compile.Format.general] }
        let packageC : Compile.Contribution := { mode := "c-mode", markers := #["c.toml"] }
        let configB : Compile.Contribution := { mode := "b-mode", markers := #["b.toml"] }
        let configA : Compile.Contribution :=
          { mode := "a-mode", markers := #["x.toml"]
            commands := #[{ name := "build", line := "config-build" }] }
        let shipping : Package :=
          { name := "shipping"
            setup := do
              compileContribution packageA
              compileContribution packageC }
        let packaged := hostedRegistry #[shipping]
        let both :=
          hostedReloaded packaged do
            compileContribution configB
            compileContribution configA
        let dropped := hostedReloaded both (pure ())
        let shape (contributions : Array Compile.Contribution) :=
          contributions.map fun contribution =>
            (contribution.mode, contribution.markers, contribution.commands,
              contribution.formats.map (·.name))
        let bare := (Compile.hook.runModel editorModel).1.toOption
        pure
          (hookShape packaged == some (shape #[packageA, packageC]) &&
            hookShape both == some (shape #[configB, configA, packageC]) &&
            hookShape dropped == some (shape #[packageA, packageC]) &&
            hookShape (hostedRegistry #[]) == some #[] &&
            hookProjects (hostedRegistry #[]) == some #[] &&
            bare.map (·.contributions.size) == some 0 &&
            bare.map (·.projects.size) == some 0) },
    { name :=
        "a reload replaces config's contributions and project commands and keeps a package's: the hook holds config's b-mode before the package's a-mode and config's project commands, and after a reload of config to nothing the package's alone"
      run :=
        let packaged := hostedRegistry #[contributing "shipping" [("a-mode", "a.toml")]]
        let loaded :=
          hostedReloaded packaged do
            compileContribution { mode := "b-mode", markers := #["b.toml"] }
            projectCommands remote "b-mode" [("lint", "b-lint")]
        let again :=
          hostedReloaded loaded do
            compileContribution { mode := "c-mode", markers := #["c.toml"] }
        let bare := hostedReloaded again (pure ())
        pure
          (hookModes packaged == some #[("a-mode", #["a.toml"])] &&
            hookProjects packaged == some #[] &&
            hookModes loaded == some #[("b-mode", #["b.toml"]), ("a-mode", #["a.toml"])] &&
            hookProjects loaded == some #[("b-mode", #["b-lint"])] &&
            hookModes again == some #[("c-mode", #["c.toml"]), ("a-mode", #["a.toml"])] &&
            hookProjects again == some #[] &&
            hookModes bare == some #[("a-mode", #["a.toml"])] &&
            hookProjects bare == some #[]) },
    { name :=
        "a contribution with no marker, a contribution that names a command twice, and project commands that name a command twice each refuse the setup, config's and a package's alike, and a refused setup registers nothing at either point"
      run :=
        let unmarked : SetupM Unit := compileContribution { mode := "a-mode", markers := #[] }
        let twice : SetupM Unit :=
          compileContribution
            { mode := "a-mode", markers := #["a.toml"]
              commands := #[{ name := "build", line := "a" }, { name := "build", line := "b" }] }
        let projectTwice : SetupM Unit :=
          projectCommands remote "a-mode" [("lint", "a"), ("lint", "b")]
        let after (refused : SetupM Unit) : SetupM Unit := do
          compileContribution { mode := "b-mode", markers := #["b.toml"] }
          projectCommands remote "b-mode" [("lint", "b-lint")]
          refused
        pure
          (hostedRefusal unmarked == some "the compile contribution `a-mode` has no marker" &&
            hostedRefusal twice ==
              some "the compile contribution `a-mode` names the command `build` twice" &&
            hostedRefusal projectTwice ==
              some
                "the project commands of `a-mode` for remote github.com/o/r name the command `lint` twice" &&
            hostedRefusal (compileContribution { mode := "a-mode", markers := #["a.toml"] }) ==
              none &&
            [unmarked, twice, projectTwice].all
              (fun refused =>
                hookModes (hostedRegistry #[] (after refused)) == some #[] &&
                  hookProjects (hostedRegistry #[] (after refused)) == some #[] &&
                  hookModes (hostedRegistry #[{ name := "refused", setup := after refused }]) ==
                    some #[])) },
    { name :=
        "of two contributions of one mode in one setup the later is used, at the place the mode was first registered, and of two project commands for one project and mode the later, while another project's and another mode's stay"
      run :=
        let registry :=
          hostedRegistry #[] do
            compileContribution { mode := "a-mode", markers := #["a.toml"] }
            compileContribution { mode := "b-mode", markers := #["b.toml"] }
            compileContribution { mode := "a-mode", markers := #["other.toml"] }
            projectCommands remote "a-mode" []
            projectCommands other "a-mode" [("lint", "other lint")]
            projectCommands remote "b-mode" [("lint", "b lint")]
            projectCommands remote "a-mode" [("lint", "make lint")]
        let projects :=
          (hostedAsked registry Compile.hook).map fun hook =>
            hook.projects.map fun entry => (entry.project, entry.mode, entry.commands.map (·.line))
        pure
          (hookModes registry == some #[("a-mode", #["other.toml"]), ("b-mode", #["b.toml"])] &&
            projects ==
              some
                #[(remote, "a-mode", #["make lint"]), (other, "a-mode", #["other lint"]),
                  (remote, "b-mode", #["b lint"])]) },
    { name :=
        "a package may give project commands, which come after config's: the settings of a project and a mode both give are config's, and the package's are read once a reload drops config's"
      run :=
        let giving : Package :=
          { name := "giving"
            setup :=
              projectCommands remote "a-mode" [("lint", "package lint")]
                [("profile", .str "package")] }
        let (_, refused) : Config.State Unit Unit × Array String :=
          Config.State.ofPackages #[giving]
        let packaged := hostedRegistry #[giving]
        let both :=
          hostedReloaded packaged
            (projectCommands remote "a-mode" [("lint", "config lint")] [("profile", .str "config")])
        let settings (registry : Config.Registry) :=
          (hostedAsked registry Compile.hook).map (·.settingsOf remote "a-mode")
        pure
          (refused.isEmpty && hookProjects packaged == some #[("a-mode", #["package lint"])] &&
            hookProjects both ==
              some #[("a-mode", #["config lint"]), ("a-mode", #["package lint"])] &&
            settings both == some [("profile", .str "config")] &&
            settings packaged == some [("profile", .str "package")] &&
            settings (hostedReloaded both (pure ())) == some [("profile", .str "package")]) },
    { name :=
        "of two packages that contribute one mode the later package's is used, listed once, at the place the mode was first registered; config's contribution of that mode replaces both, in config's place, until a reload drops it"
      run :=
        let packaged :=
          hostedRegistry
            #[contributing "first" [("make-mode", "Makefile"), ("other-mode", "other")],
              contributing "second" [("third-mode", "third"), ("make-mode", "GNUmakefile")]]
        let installed :=
          hostedReloaded packaged
            (compileContribution { mode := "make-mode", markers := #["config.mk"] })
        let dropped := hostedReloaded installed (pure ())
        pure
          (hookModes packaged ==
              some
                #[("make-mode", #["GNUmakefile"]), ("other-mode", #["other"]),
                  ("third-mode", #["third"])] &&
            hookModes installed ==
              some
                #[("make-mode", #["config.mk"]), ("other-mode", #["other"]),
                  ("third-mode", #["third"])] &&
            hookModes dropped == hookModes packaged) }]

end ModelTest
