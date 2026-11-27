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
face, a theme, a segment, a language, a grammar declaration, a completion
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
      defineGrammar name s!"/grammars/{name}/libtree-sitter-{name}.so"
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

/-- The libraries the package `ini-grammar` declares for its grammar `ini`,
by platform, relative to its grammars directory. -/
def iniLibraries : List (String × System.FilePath) :=
  [("darwin-aarch64", "darwin-aarch64/libtree-sitter-ini.dylib"),
    ("linux-x86_64", "linux-x86_64/libtree-sitter-ini.so")]

/-- A package called `name`, of the Lake package `ini-grammar`, that
declares the grammar `ini` per platform with `libraries` and the query
directory `queries`, both relative to its grammars directory, and the
language `ini` of `*.ini` naming it. -/
def shippingIni (name : String := "ini-grammar") (libraries := iniLibraries)
    (queries : System.FilePath := "queries") : Package :=
  { name
    setup :=
      defineLanguage
        { name := "ini", patterns := [.extension "ini"], syntaxTree := { grammar := "ini" } }
    grammars := #[Language.Grammar.declarePerPlatform "ini" libraries queries]
    lakePackage := some "ini-grammar" }

/-- The directory the checks' set stages `ini-grammar`'s grammars directory
in. -/
def iniStaged : System.FilePath :=
  "/s/.lake/build/grammars/ini-grammar"

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
    (processEnvironment .inherited, "processEnvironment"), (autoReload true, "autoReload"),
    (workspace "/w", "workspace"), (workspaceLister "/w" "fd", "workspaceLister"),
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
            state.registry.ownersByKind.size == 19 &&
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
        "a package of the Lake package ini-grammar declaring the grammar ini per platform relative to its grammars directory, handed the staged directory /s/.lake/build/grammars/ini-grammar, registers ini under its owner with each platform's library and the query directory under that directory, and its source on darwin-aarch64 is /s/.lake/build/grammars/ini-grammar/darwin-aarch64/libtree-sitter-ini.dylib"
      run :=
        let (state, refused) :=
          (Config.State.ofPackages #[shippingIni] [("ini-grammar", iniStaged)] :
            ModelState × Array String)
        let table := state.registry.grammarTable
        pure
          (refused.isEmpty &&
            state.registry.grammars.map (fun entry => (entry.owner.name, entry.grammar.name)) ==
              #[("ini-grammar", "ini")] &&
            table ==
              [Language.Grammar.declarePerPlatform "ini"
                  [("darwin-aarch64",
                      "/s/.lake/build/grammars/ini-grammar/darwin-aarch64/libtree-sitter-ini.dylib"),
                    ("linux-x86_64",
                      "/s/.lake/build/grammars/ini-grammar/linux-x86_64/libtree-sitter-ini.so")]
                  "/s/.lake/build/grammars/ini-grammar/queries"] &&
            (table.head?.bind (·.sourceOn "darwin-aarch64")).map (·.library) ==
              some "/s/.lake/build/grammars/ini-grammar/darwin-aarch64/libtree-sitter-ini.dylib" &&
            state.registry.languageTable.any (·.name == "ini")) },
    { name :=
        "a package whose grammar path is ../outside.dylib, or absolute, or whose query directory leaves its grammars directory, is refused with a message naming the package and that path, and the packages after it register"
      run :=
        let climbing := shippingIni "climbing" [("darwin-aarch64", "../outside.dylib")]
        let absolute := shippingIni "absolute" [("darwin-aarch64", "/abs/libini.dylib")]
        let queries := shippingIni "queries" (queries := "a/../../queries")
        let (state, refused) :=
          (Config.State.ofPackages #[climbing, absolute, queries, commanding "after" [("a", "a")]]
              [("ini-grammar", iniStaged)] :
            ModelState × Array String)
        pure
          (refused ==
              #["the package `climbing` is refused: its grammar `ini`'s path `../outside.dylib` leaves its grammars directory",
                "the package `absolute` is refused: its grammar `ini`'s path `/abs/libini.dylib` leaves its grammars directory",
                "the package `queries` is refused: its grammar `ini`'s path `a/../../queries` leaves its grammars directory"] &&
            state.packages == #["after"] &&
            state.registry.grammars.isEmpty) },
    { name :=
        "a package whose grammar, resolved under its staged directory, has a problem is refused with the package and that problem named, and the packages after it register: a per-platform list that is empty, one that lists a platform twice, and a symbol that registers another grammar"
      run :=
        let empty := shippingIni "empty" []
        let twice :=
          shippingIni "twice"
            [("darwin-aarch64", "darwin-aarch64/a.dylib"),
              ("darwin-aarch64", "darwin-aarch64/b.dylib")]
        let other :=
          { shippingIni "other" with
            grammars :=
              #[Language.Grammar.declarePerPlatform "ini" iniLibraries "queries" (symbol :=
                  some "tree_sitter_toml")] }
        let (state, refused) :=
          (Config.State.ofPackages #[empty, twice, other, commanding "after" [("a", "a")]]
              [("ini-grammar", iniStaged)] :
            ModelState × Array String)
        pure
          (refused ==
              #["the package `empty` is refused: the grammar `ini` declares a library for no platform",
                "the package `twice` is refused: the grammar `ini` declares a library for the platform `darwin-aarch64` twice",
                "the package `other` is refused: the grammar `ini`'s symbol `tree_sitter_toml` registers the grammar `toml`: a grammar is declared under the name its symbol registers"] &&
            state.packages == #["after"] &&
            state.registry.grammars.isEmpty) },
    { name :=
        "a package of the Lake package ini-grammar declaring the grammar ini with one library for every platform, relative to its grammars directory, and the default query directory, registers ini with that library and queries/ under the staged directory, its source on any platform that library"
      run :=
        let single :=
          { shippingIni "single" with
            grammars := #[Language.Grammar.declare "ini" "libtree-sitter-ini.so"] }
        let (state, refused) :=
          (Config.State.ofPackages #[single] [("ini-grammar", iniStaged)] :
            ModelState × Array String)
        let table := state.registry.grammarTable
        let library := "/s/.lake/build/grammars/ini-grammar/libtree-sitter-ini.so"
        pure
          (refused.isEmpty &&
            state.registry.grammars.map (fun entry => (entry.owner.name, entry.grammar.name)) ==
              #[("single", "ini")] &&
            table ==
              [Language.Grammar.declare "ini" library (queries :=
                  some "/s/.lake/build/grammars/ini-grammar/queries")] &&
            ["darwin-aarch64", "linux-x86_64"].all fun platform =>
              (table.head?.bind (·.sourceOn platform)).map (·.library) == some library) },
    { name :=
        "a package that declares grammars with no staged directory of its Lake package, or with no Lake package tagged, is refused with a message naming it and the keyword"
      run :=
        let untagged := { shippingIni "untagged" with lakePackage := none }
        let (_, refused) :=
          (Config.State.ofPackages #[shippingIni "unstaged", untagged] [("other", iniStaged)] :
            ModelState × Array String)
        pure
          (refused ==
            #["the package `unstaged` is refused: it declares grammars, and no grammars directory of its Lake package is staged beside this editor: a Lake package that ships grammars carries the keyword `editor-grammars`",
              "the package `untagged` is refused: it declares grammars, and no grammars directory of its Lake package is staged beside this editor: a Lake package that ships grammars carries the keyword `editor-grammars`"]) },
    { name :=
        "after the package's ini registers, an installed config declaring the grammar ini with its own library puts config's declaration in the grammar table in the package's place, and the install's registerGrammars effect carries config's ini alone"
      run :=
        let (state, _) :=
          (Config.State.ofPackages #[shippingIni] [("ini-grammar", iniStaged)] :
            ModelState × Array String)
        let (installed, effects) :=
          reduceFrom state
            [.requested, .finished (accepted ["a"] (defineGrammar "ini" "/mine/libini.so"))]
        pure
          (installed.registry.grammarTable == [Language.Grammar.declare "ini" "/mine/libini.so"] &&
            effects.contains (.registerGrammars 1 #["ini"]) &&
            installed.registry.grammars.any (·.owner.name == "ini-grammar")) },
    { name :=
        "Package.shipping tags every package of the array with the Lake package and changes nothing else"
      run :=
        let packages := #[{ shippingIni with lakePackage := none }, commanding "other" []]
        let shipped := Package.shipping "ini-grammar" packages
        pure
          (shipped.map (·.lakePackage) == #[some "ini-grammar", some "ini-grammar"] &&
            shipped.map (·.name) == packages.map (·.name) &&
            shipped.map (·.grammars) == packages.map (·.grammars)) },
    { name :=
        "a host handed no package starts from a registry that holds no command, binding, mode, ex name, job, source, menu or extension value: no entry of any of the nineteen kinds a package of every kind fills, no menu bar, no theme, no store's cell, no package's name, and nothing refused"
      run :=
        let (state, refused) := packaged #[]
        let (full, _) := packaged #[everyKind "one"]
        pure
          (refused.isEmpty && state.packages == #[] && state.registry.ownersByKind.size == 19 &&
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
