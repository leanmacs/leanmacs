import Editor.Command.Call
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Display
import Editor.Completion.Style
import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Config.Stores
import Editor.Extension
import Editor.Invocation
import Editor.Language
import Editor.Layout
import Editor.Menu
import Editor.Mode
import Editor.Package
import Editor.Process.Environment
import Editor.Setup
import Editor.TabBar
import Editor.Test.Config
import Editor.Test.Keys
import Editor.Test.Models
import Editor.Value
import Editor.Window
import Editor.Workspace
import ModelTest.Check
import ModelTest.Editor.Config.Reload
import ModelTest.Support.Elaborator

/-!
# Model tests: `Editor/Config/Packages.lean`

The model tests of `Editor/Package.lean` and `Editor/Config/Packages.lean`:
`packageChecks`. The root module `ModelTest` runs them; its module doc says
what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- An extension point declared here for `everyKind`, whose value is named
after the package that registers it. -/
structure Tagged where
  /-- Who registered it. -/
  name : String
  deriving TypeName

/-- A package called `name` that registers one thing of every kind an owner
holds, each named after `name`, and a style default for the category
`<name>-pick`: a plain command `<name>-plain`, which makes the text `name`, a
command given its call, a store with a command over it and its codec
across a restart, a job, a key
binding of `keys` to the plain command, a name for the prefix `C-c`, a mode, an ex name, a
face, a theme, a segment, a language, a completion
source, style and display, an at-point source and a use of it, a menu,
and a value at an extension point (`Tagged`). -/
def everyKind (name : String) (keys : String := "C-c p") : Package :=
  { name
    setup := do
      command s!"{name}-plain" (makes name)
      commandWith s!"{name}-call" fun _ => makes s!"{name} called"
      counter.declare
      counter.command s!"{name}-bump" fun n => pure (n + 1)
      counter.keptAcrossRestart
      job s!"{name}-job" (fun _ => pure name) makes
      bindKey keys s!"{name}-plain"
      prefixName "C-c" name
      defineMode { name := s!"{name}-mode" }
      exCommand s!"{name}-ex" s!"{name}-plain"
      face s!"{name}-face" (coloured 1)
      defineTheme s!"{name}-theme" (oneFace 2)
      defineSegment s!"{name}-segment" fun _ => #[]
      defineLanguage
          { name := s!"{name}-language", patterns := [.extension name]
            syntaxTree := { grammar := name } }
      defineSource (.ofTexts s!"{name}-source" s!"{name}-pick" #["a"])
      defineStyle (.keeping s!"{name}-style" fun _ _ => true)
      defineDisplay (Completion.Display.plain s!"{name}-display")
      defineAtPoint (Completion.AtPoint.silent s!"{name}-at")
      useAtPoint s!"{name}-at"
      defineMenu { title := name }
      Extension.add ({ name } : Tagged)
      useStyleFor s!"{name}-pick" s!"{name}-style" }

/-- The package called `name` that registers the plain commands `commands`,
each a name and the text it makes. -/
def commanding (name : String) (commands : List (String × String)) : Package :=
  { name
    setup :=
      for (command, text) in commands do
        Editor.command command (makes text) }

/-- The state `packages` make, and the messages of those refused. -/
def packaged (packages : Array Package) : ModelState × Array String :=
  Config.State.ofPackages packages

/-- Whether `state` holds what the package `everyKind name` registered: an
entry of every kind for its owner, its three commands among them, its style
default, and the cell of its store. -/
def holdsEveryKind (state : ModelState) (name : String) : Bool :=
  let owner : Config.Owner := { name }
  state.registry.ownersByKind.all (·.contains owner) &&
    (state.registry.entries.filter (·.owner == owner)).size == 3 &&
    state.registry.styleDefaults.contains (s!"{name}-pick", s!"{name}-style") &&
    (state.cells.find? owner "counter").isSome

/-- The settings only config may choose, each as a `setup` that sets it and
the name the refusal gives it. -/
def configOnlySettings : List (SetupM Unit × String) :=
  [(useTheme "default", "useTheme"), (modeLine ["state"] [], "modeLine"),
    (framePadding 4, "framePadding"), (keyHintDelay 250, "keyHintDelay"),
    (layout .monocle, "layout"), (tabBar .never, "tabBar"), (titleBar .standard, "titleBar"),
    (autoReload true, "autoReload"), (workspace "/w", "workspace"),
    (workspaceLister "/w" "fd", "workspaceLister"),
    (projectLister (.remote "github.com/o/r") "fd", "projectLister"),
    (displayRule { target := .newTab }, "displayRule"), (shellTimeLimit 5, "shellTimeLimit"),
    (syntaxRefreshDelay 5, "syntaxRefreshDelay"), (leaderKey "SPC", "leaderKey"),
    (localLeaderKey "<leader> m", "localLeaderKey"), (useStyle "fuzzy", "useStyle"),
    (useDisplay "minibuffer", "useDisplay"), (useDisplayFor "file" "minibuffer", "useDisplayFor")]

/-- The checks of packages (`Editor/Package.lean`) and of registering them
(`Editor/Config/Packages.lean`): the owner of a package's registrations, the
order they register in, what is refused, and what a reload and config do
to them. -/
def packageChecks : List Check :=
  [{  name :=
        "a package's environmentBase is a default, not refused: the registry's base name is the latest package's default, inherited with none"
      run :=
        let base (name base : String) : Package := { name, setup := environmentBase base }
        let (one, refusedOne) := packaged #[base "first" "a"]
        let (two, refusedTwo) := packaged #[base "first" "a", base "second" "b"]
        let (none_, _) := packaged #[]
        pure
          (refusedOne.isEmpty && refusedTwo.isEmpty && one.registry.baseName == "a" &&
            two.registry.baseName == "b" &&
            none_.registry.baseName == Process.inheritedName) },
    { name :=
        "a package's codec across a restart is registered for its owner, and the loop is told it"
      run :=
        let (state, refused) := packaged #[everyKind "one"]
        pure <|
          refused.isEmpty &&
            ((state.registry.codec? "counter").map fun (owner, codec) =>
                (owner.name, codec.name)) ==
              some ("one", "counter") &&
            ((state.registry.registered.codec? "counter").map (·.1)) == some "one" },
    { name :=
        "a package's entries of every kind have the owner named after it, and another package's have another"
      run :=
        let one := everyKind "one"
        let two := everyKind "two" "C-c q"
        let (state, refused) := packaged #[one, two]
        pure
          (refused.isEmpty && one.owner == { name := "one" } && two.owner == { name := "two" } &&
            state.registry.ownersByKind.size == 18 &&
            state.registry.ownersByKind.all
              (fun owners => owners.toList.eraseDups == [one.owner, two.owner]) &&
            state.registry.entries.map (·.owner.name) ==
              #["one", "one", "one", "two", "two", "two"] &&
            state.packages == #["one", "two"]) },
    { name :=
        "a package named `config`, `compiled`, nothing, or as an earlier package is refused and registers nothing, and the others register"
      run :=
        let named (name : String) := commanding name [(s!"{name}-greet", name)]
        let (state, refused) :=
          packaged
            #[named "one", named "config", named "compiled", named "",
              commanding "one" [("again", "again")], named "two"]
        pure
          (state.registry.names == #["one-greet", "two-greet"] &&
            state.packages == #["one", "two"] &&
            state.registry.entries.map (·.owner.name) == #["one", "two"] &&
            refused ==
              #[Package.reservedName "config", Package.reservedName "compiled", Package.nameless,
                Package.namedTwice "one"] &&
            (named "config").registered.commands.isEmpty &&
            (named "").registered.commands.isEmpty &&
            (named "one").registered.commands.map (·.name) == #["one-greet"]) },
    { name :=
        "two packages register in the order of the array: their command names, and of one name the later package's command is found"
      run :=
        let first := commanding "first" [("a", "first's a"), ("shared", "first's")]
        let second := commanding "second" [("shared", "second's"), ("b", "second's b")]
        let (state, refused) := packaged #[first, second]
        let (swapped, _) := packaged #[second, first]
        pure
          (refused.isEmpty && state.registry.names == #["a", "shared", "b"] &&
            state.registry.entries.map (·.owner.name) == #["first", "first", "second", "second"] &&
            runTexts state "shared" == some #["second's"] &&
            swapped.registry.names == #["shared", "b", "a"] &&
            runTexts swapped "shared" == some #["first's"]) },
    { name :=
        "an installed reload leaves a package's entries of every kind, its style default and its store's cell, and so does a reload of an empty config"
      run :=
        let (state, _) := packaged #[everyKind "one"]
        let config : SetupM Unit := do
          (everyKind "mine" "C-c m").setup
          useStyle "mine-style"
        let (bumped, _) := (runs state "one-bump").getD (state, editorModel)
        let (installed, effects) :=
          reduceFrom bumped [.requested, .finished (accepted ["a"] config)]
        let (emptied, _) := reduceFrom installed [.requested, .finished (accepted ["a"] (pure ()))]
        let cell (state : ModelState) :=
          (state.cells.find? { name := "one" } "counter").map (·.value)
        pure
          (holdsEveryKind state "one" && cell bumped == some (.nat 1) &&
            holdsEveryKind installed "one" &&
            installed.registry.ownersByKind.all (·.contains .config) &&
            cell installed == some (.nat 1) &&
            effects.contains (.cancelJobs "config") &&
            !effects.contains (.cancelJobs "one") &&
            holdsEveryKind emptied "one" &&
            emptied.registry.ownersByKind.all (fun owners => owners.all (·.name == "one")) &&
            cell emptied == some (.nat 1) &&
            runTexts emptied "one-plain" == some #["one"]) },
    { name :=
        "config's command of a package's command's name runs in its place and config's binding of a package's keys is the keymap's; a reload without them brings the package's back"
      run :=
        let (state, _) := packaged #[everyKind "one"]
        let config : SetupM Unit := do
          command "one-plain" (makes "config's")
          command "mine" (makes "mine")
          bindKey "C-c p" "mine"
        let (installed, _) := reduceFrom state [.requested, .finished (accepted ["a"] config)]
        let (dropped, _) := reduceFrom installed [.requested, .finished (accepted ["a"] (pure ()))]
        pure
          (runTexts state "one-plain" == some #["one"] &&
            boundTo state.registry "C-c p" == some (invoke "one-plain") &&
            runTexts installed "one-plain" == some #["config's"] &&
            boundTo installed.registry "C-c p" == some (invoke "mine") &&
            installed.registry.names == #["one-plain", "one-call", "one-bump", "mine"] &&
            runTexts dropped "one-plain" == some #["one"] &&
            boundTo dropped.registry "C-c p" == some (invoke "one-plain") &&
            runTexts dropped "mine" == none) },
    { name :=
        "a package's `useStyleFor` is a style default that config's `useStyleFor` overrides and its `useStyle` does not reach; of two packages' defaults for one category the later package's is used"
      run :=
        let styled (name category : String) : Package :=
          { name
            setup := do
              defineStyle (.keeping s!"{name}-style" fun _ _ => true)
              useStyleFor category s!"{name}-style" }
        let (state, refused) := packaged #[styled "one" "pick", styled "two" "pick"]
        let styleOf (state : ModelState) (category : String) : String × String :=
          let entry := state.registry.styleEntry (some category)
          (entry.style.name, entry.owner.name)
        let chooses (setup : SetupM Unit) : ModelState :=
          (reduceFrom state [.requested, .finished (accepted ["a"] setup)]).1
        let defaulted :=
          chooses do
            defineStyle (.keeping "mine" fun _ _ => true)
            useStyle "mine"
        let overridden :=
          chooses do
            defineStyle (.keeping "mine" fun _ _ => true)
            useStyleFor "pick" "mine"
        pure
          (refused.isEmpty &&
            state.registry.styleDefaults == #[("pick", "one-style"), ("pick", "two-style")] &&
            state.registry.styleChoices.isEmpty &&
            styleOf state "pick" == ("two-style", "two") &&
            styleOf state "other" == ("one-style", "one") &&
            styleOf defaulted "pick" == ("two-style", "two") &&
            styleOf defaulted "other" == ("mine", "config") &&
            styleOf overridden "pick" == ("mine", "config") &&
            (chooses (pure ())).registry.styleDefaults == state.registry.styleDefaults) },
    { name :=
        "a package that sets something only config may choose is refused, for each such setting, and the message names the package and the setting"
      run :=
        pure <|
          configOnlySettings.all fun (setting, name) =>
            let package : Package :=
              { name := "eager"
                setup := do
                  command "eager-greet" (makes "hi")
                  setting }
            let (state, refused) := packaged #[package, commanding "other" [("o", "o")]]
            refused == #[Package.refused "eager" (Package.setsConfigOnly name)] &&
              (Package.refused "eager" (Package.setsConfigOnly name)).startsWith
                "the package `eager` is refused: " &&
              ((Package.setsConfigOnly name).splitOn s!"`{name}`").length == 2 &&
              state.registry.names == #["o"] &&
              package.registered.commands.isEmpty },
    { name :=
        "a package whose `setup` throws, or registers a name twice, registers nothing and is reported with its name"
      run :=
        let throwing : Package :=
          { name := "thrower"
            setup := do
              command "t" (makes "t")
              throw "no thanks" }
        let twice := commanding "doubler" [("d", "1"), ("d", "2")]
        let (state, refused) := packaged #[throwing, commanding "fine" [("f", "f")], twice]
        pure
          (refused ==
              #[Package.refused "thrower" "no thanks",
                Package.refused "doubler" "the command `d` is registered twice"] &&
            Package.refused "thrower" "no thanks" ==
              "the package `thrower` is refused: no thanks" &&
            state.registry.names == #["f"] &&
            state.packages == #["fine"] &&
            throwing.registered.commands.isEmpty &&
            twice.registered.commands.isEmpty) },
    { name :=
        "a package's command over its store finds the cell: it runs, its value is written back for the package's owner, and the next run reads it"
      run :=
        let counting : Package :=
          { name := "counting"
            setup := do
              counter.declare
              counter.command "bump" fun n => do
                  discard <| createText s!"was {n}"
                  return n + 5 }
        let (state, refused) := packaged #[counting]
        pure <|
          match runs state "bump" with
          | none => false
          | some (once, model) =>
            refused.isEmpty && model.texts.contents == #["was 0"] &&
              (once.cells.find? counting.owner "counter").map (·.value) == some (.nat 5) &&
              stored once "counter" == none &&
              (runs once "bump").map (·.2.texts.contents) == some #["was 5"] },
    { name :=
        "a host handed no package starts from a registry that holds no command, binding, mode, ex name, job, source, menu or extension value: no entry of any of the eighteen kinds a package of every kind fills, no menu bar, no theme, no store's cell, no package's name, and nothing refused"
      run :=
        let (state, refused) := packaged #[]
        let (full, _) := packaged #[everyKind "one"]
        pure
          (refused.isEmpty && state.packages == #[] && state.registry.ownersByKind.size == 18 &&
            state.registry.ownersByKind.all (·.isEmpty) &&
            full.registry.ownersByKind.all (!·.isEmpty) &&
            state.registry.entries.isEmpty &&
            state.registry.bindings.isEmpty &&
            state.registry.modes.isEmpty &&
            state.registry.exNames == #[] &&
            state.registry.jobs.isEmpty &&
            state.registry.sources.isEmpty &&
            state.registry.menus.isEmpty &&
            state.registry.menuBar? == none &&
            state.registry.extensions.isEmpty &&
            state.registry.themeNames == #[] &&
            state.cells.cells.isEmpty) }]

end ModelTest
