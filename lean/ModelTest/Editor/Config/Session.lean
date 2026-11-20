import Editor.Config.Diagnostic
import Editor.Config.Elaborator.Model
import Editor.Config.LakePackage
import Editor.Config.Registry
import Editor.Config.Session
import Editor.InputScheme.Test
import Editor.Program
import Editor.Setup
import Editor.Test.Models
import ModelTest.Check
import ModelTest.Support.Elaborator

/-!
# Model tests: `Editor/Config/Session.lean`

The model tests of `Editor/Config/Session.lean`: `sessionChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test
open Editor.Config

/-- The modules of an outcome's files, in order, if it built any. -/
def builtModules (outcome : Outcome ModelBase ModelHandle) : Option (Array String) :=
  outcome.built.map (·.files.map (·.file.module))

/-- The sources and severities of an outcome's diagnostics. -/
def said (outcome : Outcome ModelBase ModelHandle) : Array (String × Config.Severity) :=
  outcome.diagnostics.map fun diagnostic => (diagnostic.source, diagnostic.severity)

/-- A root that defines `setup` and nothing else. -/
def plainRoot : String × List String :=
  ("init", ["define setup"])

/-- A config of four files: the root imports `Config.A` and `Config.B`,
and `Config.B` imports `Config.C`. `changed` names the modules whose text
is another than in the config with none changed. -/
def fourFiles (changed : List String := []) : Source :=
  let extra (module : String) : List String :=
    if changed.contains module then ["define changed"] else []
  configOf
    [("init", ["import Config.A", "import Config.B", "define setup"] ++ extra "init"),
      ("Config.A", ["define a"] ++ extra "Config.A"),
      ("Config.B", ["import Config.C", "define b"] ++ extra "Config.B"),
      ("Config.C", ["define c"] ++ extra "Config.C")]

/-- Builds `first` with no package port, then `second` over what the first
built, and returns the calls the elaborator received for the second. -/
def reloadCalls (first second : Source) : IO (Array SessionCall) := do
  let calls ← IO.mkRef #[]
  let elaborator := recording calls
  let outcome ← build TestScheme.scheme elaborator first PackageFiles.none none none #[]
  let some built := outcome.built | throw (IO.userError "the first config was not built")
  calls.set #[]
  discard <|
      build TestScheme.scheme elaborator second PackageFiles.none none outcome.base built.files
  calls.get

/-- Builds `source` once, with no base given and nothing loaded, on the
model with `setup` as the root's program, with a package port over
`holds` and, when `set` or `generate` asks for one, a generator. Returns
the outcome, the calls and what the directory then holds. -/
def firstBuild (source : Source) (holds : List (String × String) := []) (generate : Bool := false)
    (set : Option LakePackage.Set := none) (setup : SetupM Unit := pure ())
    (broken : Bool := false) :
    IO (Outcome ModelBase ModelHandle × Array SessionCall × Array (String × String)) := do
  let calls ← IO.mkRef #[]
  let files ← IO.mkRef holds.toArray
  let generator :=
    if generate then some (fakeGenerator calls files set (broken := broken)) else none
  let outcome ←
    build TestScheme.scheme (recording calls (Elaborator.Model.elaborator { setup })) source
        (fakePackage calls files) generator none #[]
  return (outcome, ← calls.get, ← files.get)

/-- The calls of `calls` that are not reads of the config directory. -/
def withoutReads (calls : Array SessionCall) : Array SessionCall :=
  calls.filter fun call => !(call matches .read _)

/-- The checks of the graph a config's imports make
(`Editor/Config/Session.lean`): the order its files are elaborated in, what
each is handed, a cycle, and which loaded files a reload keeps. -/
def moduleGraphChecks : List Check :=
  let node (module : String) (imports : List String) (text : String := "") : Node :=
    { file := { module, path := pathOf module, text },
      imports := imports.toArray.map fun wanted => { module := wanted, line := 1, column := 0 } }
  let diamond :=
    #[node "init" ["Config.A", "Config.B"], node "Config.A" ["Config.D"],
      node "Config.B" ["Config.D"], node "Config.D" []]
  let modules (ordered : Except (Array String) (Array Node)) : Option (Array String) :=
    ordered.toOption.map (·.map (·.file.module))
  [{  name :=
        "a config file is a module under Config: Config.Keys and Config.Evil.Keys are, and Config, Configured.Keys, init and Lean are not"
      run :=
        pure
          (isConfigModule "Config.Keys" && isConfigModule "Config.Evil.Keys" &&
            !isConfigModule "Config" &&
            !isConfigModule "Configured.Keys" &&
            !isConfigModule "init" &&
            !isConfigModule "Lean") },
    { name := "a config file's path is its module name with a slash for each dot, and .lean"
      run :=
        pure
          (pathOf "Config.Keys" == "Config/Keys.lean" &&
            pathOf "Config.Evil.Keys" == "Config/Evil/Keys.lean") },
    { name :=
        "the files are ordered each after the files it imports, depth first in header order, the root last, and a file two files import once"
      run :=
        pure
          (modules (order diamond "init") == some #["Config.D", "Config.A", "Config.B", "init"]) },
    { name := "a file nothing reaches from the root is not in the order"
      run :=
        pure
          (modules (order (diamond.push (node "Config.Unused" ["Config.D"])) "init") ==
            some #["Config.D", "Config.A", "Config.B", "init"]) },
    { name :=
        "files that import each other in a cycle have no order: the cycle is given, its modules in order and the first again at the end"
      run :=
        let cycle (ordered : Except (Array String) (Array Node)) : Option (Array String) :=
          match ordered with
          | .ok _ => none
          | .error cycle => some cycle
        pure
          (cycle
                (order
                  #[node "init" ["Config.A"], node "Config.A" ["Config.B"],
                    node "Config.B" ["Config.C"], node "Config.C" ["Config.A"]]
                  "init") ==
              some #["Config.A", "Config.B", "Config.C", "Config.A"] &&
            cycle (order #[node "init" ["Config.A"], node "Config.A" ["Config.A"]] "init") ==
              some #["Config.A", "Config.A"]) },
    { name :=
        "a file reaches the files it imports and the ones they import, in the order they are elaborated, and not itself or a file that imports it"
      run :=
        pure
          (match order diamond "init" with
          | .ok ordered =>
            reach ordered "init" == #["Config.D", "Config.A", "Config.B"] &&
              reach ordered "Config.A" == #["Config.D"] &&
              reach ordered "Config.D" == #[]
          | .error _ => false) },
    { name :=
        "a reload keeps a loaded file whose text is unchanged and whose imports are all kept, and elaborates a changed file and every file that reaches it"
      run :=
        pure
          (match order diamond "init" with
          | .ok ordered =>
            let loaded : Array (LoadedFile Nat) :=
              ordered.mapIdx fun index node => { file := node.file, handle := index }
            let changed :=
              ordered.map fun node =>
                if node.file.module == "Config.A" then { node with file.text := "changed" }
                else node
            let kept (steps : Array (Step Nat)) : Array (String × Option Nat) :=
              steps.map fun step => (step.node.file.module, step.kept)
            kept (plan loaded ordered) ==
                #[("Config.D", some 0), ("Config.A", some 1), ("Config.B", some 2),
                  ("init", some 3)] &&
              kept (plan loaded changed) ==
                #[("Config.D", some 0), ("Config.A", none), ("Config.B", some 2), ("init", none)] &&
              kept (plan #[] ordered) ==
                #[("Config.D", none), ("Config.A", none), ("Config.B", none), ("init", none)]
          | .error _ => false) }]

/-- The checks of the session core
(`Editor/Config/Session.lean`): which files a reload elaborates, over which
handles and on which base, what it refuses before it elaborates anything,
what it does about the config directory's generated files, and what it
gives back. -/
def moduleSessionChecks : List Check :=
  let set : LakePackage.Set := { name := "default-set", directory := "/w/packages" }
  [{  name :=
        "a first load makes the base, elaborates the root and asks for its setup, and the outcome hands the base back"
      run := do
        let (outcome, calls, _) ← firstBuild (configOf [plainRoot])
        return calls == #[.base false #[], .root #[], .setup] &&
            outcome.base == some { modules := #["Editor"] } &&
            builtModules outcome == some #["init"] &&
            outcome.diagnostics.isEmpty },
    { name := "with the base given, it is not made again, and the outcome hands it back"
      run := do
        let calls ← IO.mkRef #[]
        let given : ModelBase := { modules := #["Editor", "Given"] }
        let outcome ←
          build TestScheme.scheme (recording calls) (configOf [plainRoot]) PackageFiles.none none
              (some given) #[]
        return (← calls.get) == #[.root #[], .setup] && outcome.base == some given },
    { name :=
        "a root that imports config files has each elaborated after the files it imports, depth first in header order, each handed the handles of every file it reaches, and the root last"
      run := do
        let (outcome, calls, _) ← firstBuild fourFiles
        return calls ==
              #[.base false #[], .file "Config.A" #[], .file "Config.C" #[],
                .file "Config.B" #["Config.C"], .root #["Config.A", "Config.C", "Config.B"],
                .setup] &&
            builtModules outcome == some #["Config.A", "Config.C", "Config.B", "init"] },
    { name :=
        "after a change to a file the root imports, a reload elaborates that file and the root, and no other"
      run := do
        let calls ← reloadCalls fourFiles (fourFiles ["Config.A"])
        return calls ==
            #[.file "Config.A" #[], .root #["Config.A", "Config.C", "Config.B"], .setup] },
    { name :=
        "after a change to a file another file imports, a reload elaborates that file, the file that imports it and the root, and no other"
      run := do
        let calls ← reloadCalls fourFiles (fourFiles ["Config.C"])
        return calls ==
            #[.file "Config.C" #[], .file "Config.B" #["Config.C"],
              .root #["Config.A", "Config.C", "Config.B"], .setup] },
    { name := "after a change to the root, a reload elaborates the root alone"
      run := do
        let calls ← reloadCalls fourFiles (fourFiles ["init"])
        return calls == #[.root #["Config.A", "Config.C", "Config.B"], .setup] },
    { name := "a reload with nothing changed elaborates no file, and still asks for setup"
      run := do
        let calls ← reloadCalls fourFiles fourFiles
        return calls == #[.setup] },
    { name :=
        "a file the root no longer imports is no part of the config, and the root, whose text changed, is elaborated again"
      run := do
        let without :=
          configOf
            [("init", ["import Config.B", "define setup"]), ("Config.A", ["define a"]),
              ("Config.B", ["import Config.C", "define b"]), ("Config.C", ["define c"])]
        let calls ← IO.mkRef #[]
        let elaborator := recording calls
        let first ← build TestScheme.scheme elaborator fourFiles PackageFiles.none none none #[]
        calls.set #[]
        let second ←
          build TestScheme.scheme elaborator without PackageFiles.none none first.base
              ((first.built.map (·.files)).getD #[])
        return (← calls.get) == #[.root #["Config.C", "Config.B"], .setup] &&
            builtModules second == some #["Config.C", "Config.B", "init"] },
    { name :=
        "a file under Config that nothing imports is not elaborated and is no part of the config"
      run := do
        let (outcome, calls, _) ← firstBuild (configOf [plainRoot, ("Config.Unused", ["fail"])])
        return calls == #[.base false #[], .root #[], .setup] &&
            builtModules outcome == some #["init"] },
    { name :=
        "a file that imports linked modules is elaborated on a base grown to hold them, which the outcome hands back, and the files that were kept stay"
      run := do
        let calls ← IO.mkRef #[]
        let elaborator := recording calls
        let first ← build TestScheme.scheme elaborator fourFiles PackageFiles.none none none #[]
        calls.set #[]
        let withLean :=
          configOf
            [("init",
                ["import Lean", "import Config.A", "import Config.B", "define setup",
                  "use Lean.thing"]),
              ("Config.A", ["define a"]), ("Config.B", ["import Config.C", "define b"]),
              ("Config.C", ["define c"])]
        let second ←
          build TestScheme.scheme elaborator withLean PackageFiles.none none first.base
              ((first.built.map (·.files)).getD #[])
        return (← calls.get) ==
              #[.base true #["Lean"], .root #["Config.A", "Config.C", "Config.B"], .setup] &&
            second.base == some { modules := #["Editor", "Lean"] } &&
            second.built.isSome },
    { name :=
        "an import of a module that is not linked rejects the reload with one diagnostic at the import that names the module, and nothing is elaborated"
      run := do
        let source := configOf [("init", ["import Editor", "import Lake", "define setup"])]
        let (outcome, calls, _) ← firstBuild source
        return withoutReads calls == #[.base false #[]] && outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "init.lean", line := 2, column := 0, severity := .error,
                  message := notLinked "Lake" none }] &&
            (notLinked "Lake" none).startsWith "module `Lake` is not linked into this editor" },
    { name :=
        "a host with no package port gives the plain diagnostic for a module that is not linked: it reads no lakefile"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          build TestScheme.scheme (recording calls)
              (configOf [("init", ["import Greeting", "define setup"])]) PackageFiles.none none none
              #[]
        return outcome.built.isNone &&
            outcome.diagnostics.map (·.message) == #[notLinked "Greeting" none] },
    { name :=
        "when the module that is not linked belongs to a package the config's lakefile requires, the diagnostic names the package and says the package set needs a rebuild, in a host with no generator too"
      run := do
        let source := configOf [("init", ["import Greeting.Loud", "import Lake", "define setup"])]
        let (outcome, calls, files) ←
          firstBuild source [("lakefile.toml", "require default-set\nrequire greeting")]
        let message := notLinked "Greeting.Loud" (some "greeting")
        return outcome.built.isNone &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.line, diagnostic.message)) ==
              #[(1, message), (2, notLinked "Lake" none)] &&
            (message.splitOn "needs a rebuild").length == 2 &&
            (message.splitOn "`greeting`").length == 2 &&
            (message.splitOn "\n").length == 1 &&
            (calls.filter (· matches .create _)).isEmpty &&
            files.size == 1 },
    { name :=
        "a lakefile that cannot be read says nothing of a module that is not linked: the plain diagnostic is given"
      run := do
        let (outcome, _, _) ←
          firstBuild (configOf [("init", ["import Greeting", "define setup"])])
              [("lakefile.toml", "broken")]
        return outcome.diagnostics.map (·.message) == #[notLinked "Greeting" none] },
    { name :=
        "an import of a config file that is not there rejects the reload with a diagnostic at the import that names the file"
      run := do
        let source :=
          configOf [("init", ["import Config.A", "import Config.Missing"]), ("Config.A", [])]
        let (outcome, calls, _) ← firstBuild source
        return withoutReads calls == #[.base false #[]] && outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "init.lean", line := 2, column := 0, severity := .error,
                  message := noSuchFile "Config.Missing" }] &&
            ((noSuchFile "Config.Missing").splitOn "Config/Missing.lean").length == 2 },
    { name :=
        "an import whose name differs from a config file's, or from a linked module's, only in the case of its letters is refused at the import with a diagnostic that names the file found and the spelling to use, and nothing is elaborated"
      run := do
        let source :=
          configOf
            [("init", ["import Config.keys", "import lean.Data", "import editor", "define setup"]),
              ("Config.Keys", ["define a"])]
        let (outcome, calls, _) ← firstBuild source
        let message := misspelt "Config.keys" "Config.Keys" "Config/Keys.lean"
        return withoutReads calls == #[.base false #[]] && outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "init.lean", line := 1, column := 0, severity := .error, message },
                { source := "init.lean", line := 2, column := 0, severity := .error,
                  message := misspelt "lean.Data" "Lean.Data" "Lean/Data.olean" },
                { source := "init.lean", line := 3, column := 0, severity := .error,
                  message := misspelt "editor" "Editor" "Editor.olean" }] &&
            (message.splitOn "Config/Keys.lean").length == 2 &&
            (message.splitOn "`import Config.Keys`").length == 2 &&
            (message.splitOn "\n").length == 1 },
    { name :=
        "config files that import each other in a cycle reject the reload with a diagnostic that names the cycle, at the import that closes it"
      run := do
        let source :=
          configOf
            [("init", ["import Config.A", "define setup"]),
              ("Config.A", ["import Config.B", "define a"]), ("Config.B", ["import Config.A"])]
        let (outcome, calls, _) ← firstBuild source
        return withoutReads calls == #[.base false #[]] && outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "Config/B.lean", line := 1, column := 0, severity := .error,
                  message := cyclic #["Config.A", "Config.B", "Config.A"] }] },
    { name :=
        "every header is read and every problem of an import found before anything is elaborated: two files with a problem each give both"
      run := do
        let source :=
          configOf
            [("init", ["import Config.A", "import Lake", "define setup"]),
              ("Config.A", ["import Config.Missing"])]
        let (outcome, calls, _) ← firstBuild source
        return withoutReads calls == #[.base false #[]] &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.message)) ==
              #[("init.lean", notLinked "Lake" none),
                ("Config/A.lean", noSuchFile "Config.Missing")] },
    { name :=
        "a header that cannot be read rejects the reload with the elaborator's diagnostics, and nothing is elaborated"
      run := do
        let calls ← IO.mkRef #[]
        let problem : Config.Diagnostic :=
          { source := "init.lean", line := 1, severity := .error, message := "no header" }
        let elaborator := { recording calls with imports := fun _ => pure (.error #[problem]) }
        let outcome ←
          build TestScheme.scheme elaborator (configOf [plainRoot]) PackageFiles.none none none #[]
        return (← calls.get) == #[.base false #[]] && outcome.built.isNone &&
            outcome.diagnostics == #[problem] },
    { name :=
        "a directory with no root that holds .lean files is a config in the old form: the reload is rejected with one diagnostic tagged config that names the files and the command that converts them, and nothing is elaborated or generated"
      run := do
        let (outcome, calls, files) ←
          firstBuild (configOf [] ["05-leader.lean", "90-setup.lean"]) (generate := true) (set :=
              some set)
        let message := ((outcome.diagnostics.map (·.message))[0]?).getD ""
        return calls == #[.base false #[]] && outcome.built.isNone && files.isEmpty &&
            said outcome == #[("config", .error)] &&
            outcome.diagnostics == #[oldForm #["05-leader.lean", "90-setup.lean"]] &&
            (message.splitOn "05-leader.lean, 90-setup.lean").length == 2 &&
            (message.splitOn "mise run config-migrate").length == 2 &&
            (message.splitOn "\n").length == 1 },
    { name :=
        "a directory with no root that holds init.lean spelt in another case is a misspelt root, not the old form: the reload is rejected with one diagnostic tagged config that names the file found and says to rename it to init.lean, and nothing is elaborated or generated"
      run := do
        let (outcome, calls, files) ←
          firstBuild (configOf [] ["Init.lean"]) (generate := true) (set := some set)
        let message := ((outcome.diagnostics.map (·.message))[0]?).getD ""
        return calls == #[.base false #[]] && outcome.built.isNone && files.isEmpty &&
            said outcome == #[("config", .error)] &&
            outcome.diagnostics == #[misspeltRoot "Init.lean"] &&
            (message.splitOn "rename Init.lean to init.lean").length == 2 &&
            (message.splitOn "config-migrate").length == 1 &&
            (message.splitOn "\n").length == 1 },
    { name :=
        "a root spelt in another case beside other .lean files directly in the directory is still a misspelt root, and of two such spellings the first in byte order is named"
      run := do
        let (beside, _, _) ← firstBuild (configOf [] ["05-leader.lean", "INIT.lean"])
        let (two, _, _) ← firstBuild (configOf [] ["INIT.lean", "Init.lean"])
        return beside.built.isNone && beside.diagnostics == #[misspeltRoot "INIT.lean"] &&
            two.built.isNone &&
            two.diagnostics == #[misspeltRoot "INIT.lean"] },
    { name :=
        "a directory with no root and no .lean file is an empty config: it is built with nothing registered, no setup is asked for, and nothing is generated"
      run := do
        let (outcome, calls, files) ←
          firstBuild (configOf [("Config.Unused", ["define a"])]) (generate := true) (set :=
              some set)
        return calls == #[.base false #[]] && builtModules outcome == some #[] && files.isEmpty &&
            (outcome.built.map (·.registrations.commands.size)) == some 0 &&
            outcome.diagnostics.isEmpty },
    { name :=
        "a build with a root and a generator creates the lakefile for the set and the toolchain file holding the pin when the directory holds neither, before it elaborates anything"
      run := do
        let (outcome, calls, files) ←
          firstBuild (configOf [plainRoot]) (generate := true) (set := some set)
        return withoutReads calls ==
              #[.base false #[], .create "lakefile.toml", .create "lean-toolchain", .root #[],
                .setup] &&
            files ==
              #[("lakefile.toml", LakePackage.lakefile set),
                ("lean-toolchain", "leanprover/lean4:v1\n")] &&
            outcome.built.isSome &&
            outcome.diagnostics.isEmpty },
    { name :=
        "a host with no generator writes nothing: the directory is left without the two files, and the config loads"
      run := do
        let (outcome, calls, files) ← firstBuild (configOf [plainRoot])
        return calls == #[.base false #[], .root #[], .setup] && files.isEmpty &&
            outcome.built.isSome },
    { name :=
        "files that are there are left as they are, a lakefile written in Lean as one in TOML, and a toolchain file that names another toolchain is a warning tagged config with the config still built"
      run := do
        let holds := [("lakefile.lean", "mine"), ("lean-toolchain", "leanprover/lean4:v0\n")]
        let (outcome, calls, files) ←
          firstBuild (configOf [plainRoot]) holds (generate := true) (set := some set)
        return (calls.filter (· matches .create _)).isEmpty && files == holds.toArray &&
            outcome.built.isSome &&
            said outcome == #[("config", .warning)] },
    { name :=
        "an editor that knows no set directory creates the toolchain file alone, and says as information that no lakefile is generated, in every reload that finds the directory without one"
      run := do
        let (outcome, calls, files) ← firstBuild (configOf [plainRoot]) (generate := true)
        let later ← IO.mkRef #[]
        let held ← IO.mkRef files
        let second ←
          build TestScheme.scheme (recording later) (configOf [plainRoot]) (fakePackage later held)
              (some (fakeGenerator later held none)) outcome.base #[]
        return (calls.filter (· matches .create _)) == #[.create "lean-toolchain"] &&
            files.map (·.1) == #["lean-toolchain"] &&
            outcome.built.isSome &&
            said outcome == #[("config", .information)] &&
            second.built.isSome &&
            ((← later.get).filter (· matches .create _)).isEmpty &&
            second.diagnostics == outcome.diagnostics },
    { name :=
        "a first reload rejected at the headers says nothing of the lakefile, and the reload after it, which installs on the base the first made, with a generator that knows no set directory, says that none is generated"
      run := do
        let calls ← IO.mkRef #[]
        let files ← IO.mkRef #[]
        let elaborator := recording calls
        let generator := some (fakeGenerator calls files none)
        let first ←
          build TestScheme.scheme elaborator (configOf [("init", ["import Nope", "define setup"])])
              (fakePackage calls files) generator none #[]
        let second ←
          build TestScheme.scheme elaborator (configOf [plainRoot]) (fakePackage calls files)
              generator first.base #[]
        let message := ((second.diagnostics.map (·.message))[0]?).getD ""
        return first.built.isNone && said first == #[("init.lean", .error)] && first.base.isSome &&
            second.built.isSome &&
            said second == #[("config", .information)] &&
            (message.splitOn "no lakefile.toml is generated").length == 2 &&
            (← files.get).map (·.1) == #["lean-toolchain"] },
    { name :=
        "a generated file that cannot be written is a warning tagged config, and the config is still built"
      run := do
        let (outcome, _, files) ←
          firstBuild (configOf [plainRoot]) (generate := true) (set := some set) (broken := true)
        return files.isEmpty && outcome.built.isSome &&
            said outcome == #[("config", .warning), ("config", .warning)] },
    { name :=
        "a file that fails gives a rejected outcome with its diagnostics, tagged with its path, and no later file and no setup is elaborated"
      run := do
        let source :=
          configOf
            [("init", ["import Config.A", "import Config.B", "define setup"]),
              ("Config.A", ["define a", "fail"]), ("Config.B", ["define b"])]
        let (outcome, calls, _) ← firstBuild source
        return calls == #[.base false #[], .file "Config.A" #[]] && outcome.built.isNone &&
            outcome.diagnostics.map
                (fun diagnostic => (diagnostic.source, diagnostic.line, diagnostic.severity)) ==
              #[("Config/A.lean", 2, .error)] },
    { name := "a file with only a warning is built, and the outcome carries the warning"
      run := do
        let source :=
          configOf [("init", ["import Config.A", "define setup"]), ("Config.A", ["warn"])]
        let (outcome, _, _) ← firstBuild source
        return builtModules outcome == some #["Config.A", "init"] &&
            said outcome == #[("Config/A.lean", .warning)] },
    { name := "what setup registers is in the outcome"
      run := do
        let (outcome, _, _) ←
          firstBuild (configOf [plainRoot]) (setup := command "greet" (makes "hello"))
        return (outcome.built.map (·.registrations.commands.map (·.name))) == some #["greet"] },
    { name :=
        "a setup that throws gives a rejected outcome whose diagnostic's source is setup and whose message is the one thrown"
      run := do
        let setup : SetupM Unit := do
          command "greet" (makes "hello")
          throw "no thanks"
        let (outcome, _, _) ← firstBuild (configOf [plainRoot]) (setup := setup)
        return outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "setup", severity := .error, message := "no thanks" }] },
    { name :=
        "a setup that registers a command name twice gives a rejected outcome whose diagnostic's source is setup and names the command"
      run := do
        let setup : SetupM Unit := do
          command "greet" (makes "hello")
          command "greet" (makes "again")
        let (outcome, _, _) ← firstBuild (configOf [plainRoot]) (setup := setup)
        return outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "setup", severity := .error,
                  message := "the command `greet` is registered twice" }] },
    { name :=
        "a setup whose bindings are one sequence under the leaders in force of the scheme it is built for gives a rejected outcome whose diagnostic's source is setup and names both ways the keys are written"
      run := do
        let setup : SetupM Unit := do
          bindKey "<leader> f" "find"
          bindKey "C-c f" "fill"
        let (outcome, _, _) ← firstBuild (configOf [plainRoot]) (setup := setup)
        return outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "setup", severity := .error,
                  message :=
                    "the keys `C-c f` are bound twice: as `<leader> f` and as `C-c f`" }] },
    { name :=
        "a root that defines no setup gives a rejected outcome with the elaborator's diagnostics, also when a file it imports defines one"
      run := do
        let source :=
          configOf [("init", ["import Config.A", "define other"]), ("Config.A", ["define setup"])]
        let (outcome, calls, _) ← firstBuild source
        return calls == #[.base false #[], .file "Config.A" #[], .root #["Config.A"], .setup] &&
            outcome.built.isNone &&
            said outcome == #[("setup", .error)] },
    { name :=
        "a source that cannot be read gives a rejected outcome, which still hands back the base"
      run := do
        let calls ← IO.mkRef #[]
        let source : Source := { configOf [] with root := throw (IO.userError "no such directory") }
        let outcome ←
          build TestScheme.scheme (recording calls) source PackageFiles.none none none #[]
        return (← calls.get) == #[.base false #[]] && outcome.built.isNone &&
            outcome.base == some { modules := #["Editor"] } &&
            said outcome == #[("config", .error)] },
    { name :=
        "a directory whose stray files cannot be listed, with no root, gives a rejected outcome with one diagnostic tagged config, which hands back the base: nothing is thrown"
      run := do
        let calls ← IO.mkRef #[]
        let source : Source := { configOf [] with stray := throw (IO.userError "cannot list") }
        let outcome ←
          build TestScheme.scheme (recording calls) source PackageFiles.none none none #[]
        return (← calls.get) == #[.base false #[]] && outcome.built.isNone &&
            outcome.base == some { modules := #["Editor"] } &&
            outcome.diagnostics ==
              #[{ source := "config", severity := .error, message := "cannot list" }] },
    { name :=
        "a config directory whose files cannot be read as a package, with a generator, is one warning tagged config that says so, nothing is created, and the config is still built"
      run := do
        let calls ← IO.mkRef #[]
        let files ← IO.mkRef #[]
        let package : PackageFiles :=
          { fakePackage calls files with read := fun _ => throw (IO.userError "no permission") }
        let outcome ←
          build TestScheme.scheme (recording calls) (configOf [plainRoot]) package
              (some (fakeGenerator calls files (some set))) none #[]
        let message := ((outcome.diagnostics.map (·.message))[0]?).getD ""
        return outcome.built.isSome && (← files.get).isEmpty &&
            ((← calls.get).filter (· matches .create _)).isEmpty &&
            said outcome == #[("config", .warning)] &&
            (message.splitOn "could not be read").length == 2 &&
            (message.splitOn "no permission").length == 2 },
    { name :=
        "an elaborator that throws when asked whether a module is linked refuses the import as one that is not linked, and nothing is elaborated"
      run := do
        let calls ← IO.mkRef #[]
        let elaborator :=
          { recording calls with linked := fun _ _ => throw (IO.userError "cannot tell") }
        let outcome ←
          build TestScheme.scheme elaborator
              (configOf [("init", ["import Editor", "define setup"])]) PackageFiles.none none none
              #[]
        return (← calls.get) == #[.base false #[]] && outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "init.lean", line := 1, column := 0, severity := .error,
                  message := notLinked "Editor" none }] },
    { name :=
        "a config file that cannot be read gives a rejected outcome with a diagnostic at the import of it"
      run := do
        let calls ← IO.mkRef #[]
        let source : Source :=
          { configOf [("init", ["import Config.A", "define setup"])] with
            file := fun _ => throw (IO.userError "it is not UTF-8") }
        let outcome ←
          build TestScheme.scheme (recording calls) source PackageFiles.none none none #[]
        return (← calls.get) == #[.base false #[]] && outcome.built.isNone &&
            outcome.diagnostics.map
                (fun diagnostic => (diagnostic.source, diagnostic.line, diagnostic.message)) ==
              #[("init.lean", 1, "it is not UTF-8")] },
    { name := "an elaborator that throws gives a rejected outcome that names the file"
      run := do
        let calls ← IO.mkRef #[]
        let elaborator :=
          { recording calls with file := fun _ _ _ => throw (IO.userError "the elaborator broke") }
        let outcome ← build TestScheme.scheme elaborator fourFiles PackageFiles.none none none #[]
        return outcome.built.isNone && said outcome == #[("Config/A.lean", .error)] },
    { name :=
        "a base that cannot be made gives a rejected outcome with no base and one diagnostic from the base, and nothing is read or elaborated"
      run := do
        let calls ← IO.mkRef #[]
        let elaborator :=
          { recording calls with base := fun _ _ => throw (IO.userError "the base broke") }
        let outcome ←
          build TestScheme.scheme elaborator (configOf [plainRoot]) PackageFiles.none none none #[]
        return (← calls.get).isEmpty && outcome.built.isNone && outcome.base == none &&
            said outcome == #[("base", .error)] },
    { name :=
        "a base that cannot be grown gives a rejected outcome with one diagnostic from the base, which hands back the base it had, and nothing is elaborated"
      run := do
        let calls ← IO.mkRef #[]
        let model := recording calls
        let elaborator :=
          { model with
            base := fun given modules =>
              if given.isSome then throw (IO.userError "the base broke")
              else model.base given modules }
        let outcome ←
          build TestScheme.scheme elaborator (configOf [("init", ["import Lean", "define setup"])])
              PackageFiles.none none none #[]
        return (← calls.get) == #[.base false #[]] && outcome.built.isNone &&
            outcome.base == some { modules := #["Editor"] } &&
            said outcome == #[("base", .error)] },
    { name :=
        "an elaborator that throws when asked for setup gives a rejected outcome with a diagnostic from setup, and hands back the base"
      run := do
        let calls ← IO.mkRef #[]
        let elaborator :=
          { recording calls with setup := fun _ => throw (IO.userError "setup broke") }
        let outcome ←
          build TestScheme.scheme elaborator (configOf [plainRoot]) PackageFiles.none none none #[]
        return outcome.built.isNone && outcome.base == some { modules := #["Editor"] } &&
            said outcome == #[("setup", .error)] }]

/-- A fake package port over `files`, whose lakefile's lines
`require <name> <path>` are path requires, and whose shipped set is
`default-set`, read from the directory `/s` as two requires. -/
def factsPackage (files : List (String × String)) : PackageFiles :=
  { read := fun name => pure ((files.find? (·.1 == name)).map (·.2))
    requires := fun _ => pure (.ok #[])
    requireEntries := fun text =>
      if text == "broken" then pure (.error "the fake lakefile is broken")
      else
        pure
          (.ok
            ((text.splitOn "\n").filterMap fun line =>
                match line.splitOn " " with
                | ["require", name, path] => some { name, source := .path path }
                | _ => none).toArray)
    directory := "/c", setName := some "default-set"
    setRequires := fun directory =>
      if directory == "/s" then
        pure
          (.ok
            #[{ name := "editor-core", source := .path "../lean" },
              { name := "compile", source := .path "compile" }])
      else pure (.error "no such set") }

/-- The checks of what a reload reads of the config directory as a package
set (`packageFacts`, `reload`): every outcome carries it, installed or
refused; a `lakefile.toml`'s requires, a `lakefile.lean`'s text, none, or
one that cannot be read; the manifest; and the shipped set's own requires
when the lakefile requires that set by path. -/
def packageFactsChecks : List Check :=
  [{  name :=
        "every reload's outcome carries what the config directory holds as a package set, an installed one and one refused for an import alike"
      run := do
        let files :=
          [("lakefile.toml", "require default-set /s\nrequire hello /h"),
            ("lake-manifest.json", "{}")]
        let installed ←
          reload TestScheme.scheme (recording (← IO.mkRef #[])) (configOf [plainRoot])
              (factsPackage files) none none #[]
        let refused ←
          reload TestScheme.scheme (recording (← IO.mkRef #[]))
              (configOf [("init", ["import Hello", "define setup"])]) (factsPackage files) none none
              #[]
        let expected : PackageSet.Facts :=
          { lakefile :=
              .toml (files.head!.2)
                #[{ name := "default-set", source := .path "/s" },
                  { name := "hello", source := .path "/h" }]
            manifest := some "{}"
            setRequires :=
              #[{ name := "editor-core", source := .path "../lean" },
                { name := "compile", source := .path "compile" }] }
        return installed.built.isSome && installed.facts == expected && refused.built.isNone &&
            refused.facts == expected },
    { name :=
        "a lakefile.lean is kept as its text, no lakefile is absent, one that cannot be read says why, and the shipped set is read only when it is required by path"
      run := do
        let lean ← packageFacts (factsPackage [("lakefile.lean", "import Lake")])
        let none_ ← packageFacts (factsPackage [])
        let broken ← packageFacts (factsPackage [("lakefile.toml", "broken")])
        let other ← packageFacts (factsPackage [("lakefile.toml", "require hello /h")])
        return lean.lakefile == .lean "import Lake" && none_.lakefile == .absent &&
            broken.lakefile == .unreadable "the fake lakefile is broken" &&
            other.setRequires.isEmpty &&
            lean.manifest.isNone }]

/-- The checks of the config session: the graph's, then the session
core's, then what a reload reads of the package set. -/
def sessionChecks : List Check :=
  moduleGraphChecks ++ moduleSessionChecks ++ packageFactsChecks

end ModelTest
