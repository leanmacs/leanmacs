import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Config.Display
import Editor.Config.Reload
import Editor.Ex.Line
import Editor.Executable
import Editor.Face
import Editor.File.Model
import Editor.FileWatch.Model
import Editor.Floating
import Editor.Headless.CommandLine
import Editor.InputScheme.Test
import Editor.Job.Model
import Editor.Key.Notation
import Editor.Language
import Editor.Layout
import Editor.Mode
import Editor.ModeLine
import Editor.ModuleLookup
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Version
import Editor.Window
import Editor.WindowCheck
import ModelTest.Jobs

/-!
# Model tests: configuration and start-up

The checks of the user's setup and configuration, the registry, the store
and the session, reloading, the window's tally, loop and arguments, module
lookup, the headless command line, the executable's mode and version, and
the window's options and report.

Its lists of checks: `setupChecks`, `registryChecks`, `storeChecks`,
`sessionChecks`, `reloadChecks`, `windowTallyChecks`, `windowLoopChecks`,
`windowArgumentChecks`, `moduleLookupChecks`, `headlessCommandLineChecks`,
`executableModeChecks`, `versionChecks`, `windowOptionChecks`,
`windowReportChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- The keys the key string `text` names, for a fixture; none when it is
refused, which `schemeChecks` checks of no fixture string. -/
def keys (text : String) : List Key :=
  match Key.parse text with
  | .ok named => named
  | .error _ => []

/-- The invocation of the command `name` with no arguments. -/
def invoke (name : String) : Invocation :=
  { command := name }

/-- The texts a registered command leaves when it is a plain command, run
against a text model with none; `none` for a command over a store and for
one that is given its call. -/
def plainTexts : Config.Action → Option (Array String)
  | .plain run => some (textsOf run)
  | .store .. => none
  | .call _ => none

/-- How `work` ends when it runs against the job model from a clock at 0 that
nothing cancels, as a check compares it. -/
def worked (work : Work) : Job.Outcome (Array String) :=
  texts ((work ()).runModel {}).1

/-- A store of one number, at version 1. -/
def counter : Store Nat :=
  { name := "counter", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

/-- A face that sets a foreground of the red `red` and nothing else. -/
def coloured (red : UInt8) : Face :=
  { foreground := some (Color.rgb red 0 0) }

/-- The definition of the face `name` as `attributes`. -/
def defined (name : String) (attributes : Face) : FaceDefinition :=
  { name := ⟨name⟩, face := attributes }

/-- A theme of one definition: the face `default` in the red `red`. -/
def oneFace (red : UInt8) : Theme :=
  #[defined "default" (coloured red)]

/-- The theme called `name`, of one definition in the red `red`
(`oneFace`). -/
def namedTheme (name : String) (red : UInt8) : NamedTheme :=
  { name, theme := oneFace red }

/-- The buffer the mode line checks show: `Loop.lean`, opened as
`lean/Editor/Loop.lean`, in the major mode `lean`, modified when `modified`
says. -/
def loopLean (modified : Bool := true) (path : String := "lean/Editor/Loop.lean") : Buffer :=
  let history := UndoTree.new ⟨0⟩ 0
  { name := "Loop.lean", text := ⟨0⟩, history := if modified then history.record 1 else history
    major := some "lean",
    file := some { path, stamp := { seconds := 0, nanoseconds := 0, size := 0 } } }

/-- The context of a window on `buffer` in normal state, its cursor on row
958 at column 4 of 2338 rows, selected when `selected` says. -/
def loopContext (buffer : Buffer := loopLean) (selected : Bool := true) : ModeLine.Context :=
  { buffer, reported := #[{ text := "NORMAL", face := Vim.stateFace "normal" }]
    cursor := some ⟨958, 4⟩, lines := 2338, selected }

/-- The message a `setup` was refused with, if it was. -/
def refusal (setup : SetupM Unit) : Option String :=
  match Config.Registrations.ofSetup setup with
  | .error message => some message
  | .ok _ => none

/-- The checks of `setup`: a program over the setup port (`Editor/Setup.lean`),
run against the handler that collects what it registers
(`Editor/Config/Registry.lean`). -/
def setupChecks : List Check :=
  [{
      name :=
        "running a setup against the collecting handler returns its commands and store declarations, in order",
      run :=
        let setup : SetupM Unit := do
          command "first" (makes "1")
          counter.declare
          counter.command "bump" fun n => pure (n + 1)
          command "second" (makes "2")
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.commands.map (·.name) == #["first", "bump", "second"] &&
              collected.commands.map (plainTexts ·.action) == #[some #["1"], none, some #["2"]] &&
              collected.stores.map (fun store => (store.name, store.version, store.initial)) ==
                #[("counter", 1, .nat 0)]) },
    { name := "a setup that throws after registering returns its message and nothing else"
      run :=
        let setup : SetupM Unit := do
          command "first" (makes "1")
          throw "no thanks"
        pure (refusal setup == some "no thanks") },
    { name := "a setup that declares a store name twice is refused"
      run :=
        let setup : SetupM Unit := do
          counter.declare
          counter.declare
        pure (refusal setup).isSome },
    { name := "a setup that registers a command over a store it does not declare is refused"
      run :=
        let setup : SetupM Unit := counter.command "bump" fun n => pure (n + 1)
        pure (refusal setup).isSome },
    { name :=
        "a setup that registers a command name twice is refused with a message that names the command, whether the two are plain commands or one is over a store"
      run :=
        let plain : SetupM Unit := do
          command "first" (makes "1")
          command "greet" (makes "2")
          command "greet" (makes "3")
        let mixed : SetupM Unit := do
          counter.declare
          command "bump" (makes "1")
          counter.command "bump" fun n => pure (n + 1)
        pure
          (refusal plain == some "the command `greet` is registered twice" &&
            refusal mixed == some "the command `bump` is registered twice") },
    { name :=
        "a setup registers a command that is given its call under its name, beside its other commands, in order; a name registered as a plain command and as one given its call is refused as registered twice"
      run :=
        let setup : SetupM Unit := do
          command "first" (makes "1")
          commandWith "greet" fun _ => makes "2"
          command "second" (makes "3")
        let twice : SetupM Unit := do
          command "greet" (makes "1")
          commandWith "greet" fun _ => makes "2"
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.commands.map (·.name) == #["first", "greet", "second"] &&
              collected.commands.map (·.action matches .call _) == #[false, true, false] &&
              collected.commands.map (plainTexts ·.action) == #[some #["1"], none, some #["3"]] &&
              refusal twice == some "the command `greet` is registered twice") },
    { name := "a store step decodes the tree, runs the command and encodes the result"
      run :=
        let step :=
          counter.step fun n => do
            discard <| createText s!"was {n}"
            return n + 5
        match (step (.nat 2)).runModel editorModel with
        | (.ok tree, model) => pure (tree == .nat 7 && model.texts.contents == #["was 2"])
        | (.error _, _) => pure false },
    { name :=
        "a setup that registers jobs collects each with its name, in order, beside its commands, and a job is not a command"
      run :=
        let setup : SetupM Unit := do
          command "first" (makes "1")
          job "count"
              (fun _ => do
                sleep 5
                return 42)
              fun n => makes s!"counted {n}"
          job "name" (fun _ => pure "x") makes
          command "second" (makes "2")
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.commands.map (·.name) == #["first", "second"] &&
              collected.jobs.map (·.name) == #["count", "name"] &&
              collected.jobs.map (fun job => worked (job.work [])) ==
                #[.finished #["counted 42"], .finished #["x"]]) },
    { name :=
        "a setup that registers a job that takes arguments collects it under its name beside the others, and the job computes from the arguments it is started with; a job registered without them is the same whatever it is started with"
      run :=
        let setup : SetupM Unit := do
          jobWith "double"
              (fun arguments => do
                let [.nat n] := arguments | throw "double takes one number"
                sleep 5
                return 2 * n)
              fun n => makes s!"doubled to {n}"
          job "fixed" (fun _ => pure "x") makes
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          let started (name : String) (arguments : List Argument) :=
            (collected.jobs.find? (·.name == name)).map fun job => worked (job.work arguments)
          pure
            (collected.jobs.map (·.name) == #["double", "fixed"] && collected.commands.isEmpty &&
              started "double" [.nat 21] == some (.finished #["doubled to 42"]) &&
              started "double" [.nat 4] == some (.finished #["doubled to 8"]) &&
              started "double" [] == some (.failed "double takes one number") &&
              started "fixed" [.nat 1] == some (.finished #["x"]) &&
              started "fixed" [] == some (.finished #["x"])) },
    { name :=
        "a job that takes arguments registered under the name of another job is refused with a message that names the job, whichever of the two was first"
      run :=
        let doubling (name : String) : SetupM Unit :=
          jobWith name (fun _ => pure 1) fun n => makes (toString n)
        let twice : SetupM Unit := do
          doubling "count"
          job "count" (fun _ => pure 3) fun n => makes (toString n)
        let again : SetupM Unit := do
          job "count" (fun _ => pure 3) fun n => makes (toString n)
          doubling "other"
          doubling "count"
        pure
          (refusal twice == some "the job `count` is registered twice" &&
            refusal again == some "the job `count` is registered twice") },
    { name :=
        "a setup that registers a job name twice is refused with a message that names the job, and a job may have the name of a command"
      run :=
        let twice : SetupM Unit := do
          job "count" (fun _ => pure 1) fun n => makes (toString n)
          job "other" (fun _ => pure 2) fun n => makes (toString n)
          job "count" (fun _ => pure 3) fun n => makes (toString n)
        let shared : SetupM Unit := do
          command "count" (makes "1")
          job "count" (fun _ => pure 1) fun n => makes (toString n)
        pure
          (refusal twice == some "the job `count` is registered twice" && refusal shared == none) },
    { name :=
        "a setup that binds key strings to command names collects each as its chords and the name, in order, and registers no command"
      run :=
        let setup : SetupM Unit := do
          bindKey "C-x C-s" "save"
          bindKey "<Escape>" "quit"
          bindKey "A" "save"
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.bindings.map (fun binding => (binding.keys, binding.command)) ==
                #[(keys "C-x C-s", "save"), (keys "<Escape>", "quit"), (keys "A", "save")] &&
              collected.commands.isEmpty) },
    { name :=
        "a setup that binds a key string that is not keys is refused with the key parser's message, which names the stroke, and one that names no keys with a message that names the command"
      run :=
        let unreadable : SetupM Unit := do
          command "save" (makes "1")
          bindKey "C-x nope" "save"
        let parsed : Option String :=
          match Key.parse "C-x nope" with
          | .error message => some message
          | .ok _ => none
        pure
          (parsed.isSome && refusal unreadable == parsed &&
            refusal (bindKey "" "save") == some "the command `save` is bound to no keys" &&
            refusal (bindKey "  " "save") == some "the command `save` is bound to no keys") },
    { name :=
        "a setup that binds one key sequence twice is refused with a message that names the keys, whether to one command or to two; two sequences to one command are not"
      run :=
        let twice : SetupM Unit := do
          bindKey "C-x C-s" "save"
          bindKey "C-q" "quit"
          bindKey "C-x C-s" "save-as"
        let same : SetupM Unit := do
          bindKey "C-q" "quit"
          bindKey "C-q" "quit"
        let apart : SetupM Unit := do
          bindKey "C-x C-s" "save"
          bindKey "C-x s" "save"
        pure
          (refusal twice == some "the keys `C-x C-s` are bound twice" &&
            refusal same == some "the keys `C-q` are bound twice" &&
            refusal apart == none) },
    { name :=
        "a setup that binds ex names collects each binding, in order, with what it takes, nothing unless it says, and registers no command"
      run :=
        let setup : SetupM Unit := do
          exCommand "greet" "greet-named" (takes := .text)
          exCommand "w" "write"
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.ex ==
                #[{ name := "greet", command := "greet-named", takes := .text },
                  { name := "w", command := "write" }] &&
              collected.commands.isEmpty) },
    { name :=
        "a setup that binds one ex name twice is refused with a message that names it, whether to one command or to two; two names for one command are not"
      run :=
        let twice : SetupM Unit := do
          exCommand "greet" "one"
          exCommand "w" "write"
          exCommand "greet" "two"
        let same : SetupM Unit := do
          exCommand "w" "write"
          exCommand "w" "write"
        let apart : SetupM Unit := do
          exCommand "w" "write"
          exCommand "write" "write"
        pure
          (refusal twice == some "the ex name `greet` is bound twice" &&
            refusal same == some "the ex name `w` is bound twice" &&
            refusal apart == none) },
    { name :=
        "a setup that binds an ex name that is empty or holds white space is refused, with a message that names it and the command: it could not be typed on the ex line"
      run :=
        let after (name : String) : SetupM Unit := do
          command "write" (makes "1")
          exCommand name "write"
        pure
          (["", "w q", " w", "w\t"].all
              (fun name => refusal (after name) == some (unusableExName name "write")) &&
            refusal (after "w-q!") == none) },
    { name :=
        "a setup that binds an ex name the ex line cannot read back as that name, one that starts with `!`, `%`, `.`, `$`, `,` or a digit, is refused as one that cannot be typed; `w!` and a name with a digit after its first character are taken"
      run :=
        let after (name : String) : SetupM Unit := do
          command "write" (makes "1")
          exCommand name "write"
        pure
          (["!x", "%s", ".x", "$x", ",x", "3x", "!"].all
              (fun name => refusal (after name) == some (unusableExName name "write")) &&
            ["w!", "e2", "w-q!"].all (fun name => refusal (after name) == none)) },
    { name := "defineMode registers the mode, in order, beside the commands"
      run :=
        let setup : SetupM Unit := do
          defineMode { name := "listing", roles := [(Role.nextItem, "listing-next")] }
          command "listing-next" (makes "1")
          defineMode { name := "derived", parent := some "listing" }
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.modes.map (·.name) == #["listing", "derived"] &&
              collected.modes.map (·.parent) == #[none, some "listing"] &&
              collected.modes.map (·.roles) == #[[(Role.nextItem, "listing-next")], []] &&
              collected.commands.map (·.name) == #["listing-next"]) },
    { name := "a setup that defines a mode name twice is refused with a message that names the mode"
      run :=
        let setup : SetupM Unit := do
          defineMode { name := "listing" }
          defineMode { name := "other" }
          defineMode { name := "listing", parent := some "other" }
        pure (refusal setup == some "the mode `listing` is defined twice") },
    { name :=
        "a setup that defines a mode with an unregistered role, a suffix used twice or a suffix that is not keys is refused, naming the mode and the problem"
      run :=
        let refused (mode : Mode) (problem : Mode.Problem) : Bool :=
          refusal (defineMode mode) ==
            some s!"the mode `{mode.name}` cannot be meant: {problem.describe}"
        pure
          (refused { name := "roles", roles := [(Role.mk "frobnicate", "f")] }
              (.unregisteredRole (Role.mk "frobnicate")) &&
            refused { name := "twice", locals := [("x", "a"), ("x", "b")] }
              (.duplicateSuffix (keys "x")) &&
            refused { name := "unreadable", locals := [("S-a", "a")] } (.unreadableSuffix "S-a") &&
            refusal (defineMode { name := "fine", locals := [("x", "a")] }) == none) },
    { name :=
        "a setup's faces are collected in the order it set them, each with what it sets, beside its commands"
      run :=
        let setup : SetupM Unit := do
          command "first" (makes "1")
          face "keyword" (coloured 200)
          face "default" { size := some 14, weight := some 500 }
          command "second" (makes "2")
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.faces ==
                #[defined "keyword" (coloured 200),
                  defined "default" { size := some 14, weight := some 500 }] &&
              collected.commands.map (·.name) == #["first", "second"]) },
    { name :=
        "a setup that sets a face twice is refused with a message that names the face, and a face may have the name of a command"
      run :=
        let twice : SetupM Unit := do
          face "keyword" (coloured 1)
          face "comment" (coloured 2)
          face "keyword" (coloured 3)
        let shared : SetupM Unit := do
          command "keyword" (makes "1")
          face "keyword" (coloured 1)
        pure (refusal twice == some "the face `keyword` is set twice" && refusal shared == none) },
    { name :=
        "a setup that sets auto-reload twice is refused; once is collected, and it is off when the setup says nothing"
      run :=
        let twice : SetupM Unit := do
          autoReload
          autoReload false
        let once : SetupM Unit := autoReload
        pure
          (refusal twice == some Config.Registrations.autoReloadTwice && refusal once == none &&
            (match Config.Registrations.ofSetup once with
            | .ok collected => collected.autoReload == #[true]
            | .error _ => false) &&
            match Config.Registrations.ofSetup (pure ()) with
            | .ok collected => collected.autoReload.isEmpty
            | .error _ => false) },
    { name :=
        "a setup's themes are collected in the order it defined them, each with its definitions, with the theme it names; a setup that defines and names none has none"
      run :=
        let setup : SetupM Unit := do
          defineTheme "first" (oneFace 1)
          useTheme "second"
          command "greet" (makes "1")
          defineTheme "second" (oneFace 2)
        match Config.Registrations.ofSetup setup,
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure
            (collected.themes == #[namedTheme "first" 1, namedTheme "second" 2] &&
              collected.theme == some "second" &&
              collected.commands.map (·.name) == #["greet"] &&
              plain.themes.isEmpty &&
              plain.theme == none)
        | _, _ => pure false },
    { name :=
        "a setup that defines a theme twice is refused with a message that names the theme, one that names a theme twice with a message that names both, and naming a theme nobody defined is not refused"
      run :=
        let twice : SetupM Unit := do
          defineTheme "first" (oneFace 1)
          defineTheme "other" (oneFace 2)
          defineTheme "first" (oneFace 3)
        let named : SetupM Unit := do
          useTheme "a"
          useTheme "b"
        pure
          (refusal twice == some "the theme `first` is defined twice" &&
            refusal named == some "the theme is named twice: `a`, then `b`" &&
            refusal (useTheme "nope") == none) },
    { name :=
        "a setup's segments are collected in the order it defined them, with the mode line it lists; a setup that defines and lists none has none"
      run :=
        let setup : SetupM Unit := do
          defineSegment "greeting" fun _ => #[{ text := "hi", face := ⟨"mode-line.secondary"⟩ }]
          modeLine ["state", "greeting"] ["position"]
          defineSegment "other" fun _ => #[]
        match Config.Registrations.ofSetup setup,
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure
            (collected.segments.map (·.name) == #["greeting", "other"] &&
              (collected.segments[0]?.map fun segment =>
                  (segment.fields loopContext).map (·.text)) ==
                some #["hi"] &&
              collected.modeLine ==
                some { left := #["state", "greeting"], right := #["position"] } &&
              plain.segments.isEmpty &&
              plain.modeLine == none)
        | _, _ => pure false },
    { name :=
        "a setup that defines a segment twice is refused with a message that names the segment, and one that lists the mode line twice with a message that says so; listing a segment nobody defined is not refused"
      run :=
        let twice : SetupM Unit := do
          defineSegment "greeting" fun _ => #[]
          defineSegment "greeting" fun _ => #[]
        let listed : SetupM Unit := do
          modeLine ["state"] []
          modeLine [] ["position"]
        pure
          (refusal twice == some "the segment `greeting` is defined twice" &&
            refusal listed == some "the mode line is listed twice" &&
            refusal (modeLine ["nope"] []) == none) },
    { name :=
        "a setup's frame padding is collected, a setup that sets none has none, and one that sets it twice is refused with a message that says so"
      run :=
        let twice : SetupM Unit := do
          framePadding 12
          framePadding 4
        match Config.Registrations.ofSetup (framePadding 12),
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure
            (collected.framePadding == some 12 && plain.framePadding == none &&
              refusal twice == some "the frame padding is set twice" &&
              refusal (framePadding 0) == none)
        | _, _ => pure false },
    { name :=
        "a setup's layout is collected, a setup that chooses none has none, one that chooses it twice is refused with a message that says so, and a master-and-stack share above 100 is refused with a message that names it"
      run :=
        let twice : SetupM Unit := do
          layout .monocle
          layout Layout.default
        let chosen := Layout.masterStack { share := 60, side := .right }
        match Config.Registrations.ofSetup (layout chosen),
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure
            (collected.layout == some chosen && plain.layout == none &&
              refusal twice == some "the layout is chosen twice" &&
              refusal (layout (.masterStack { share := 101 })) == some (Layout.shareTooLarge 101) &&
              (Layout.shareTooLarge 101).contains "101" &&
              refusal (layout (.masterStack { share := 100 })) == none &&
              refusal (layout .monocle) == none)
        | _, _ => pure false },
    { name :=
        "a setup's tab bar is collected, a setup that chooses none has none, and one that chooses it twice is refused with a message that says so"
      run :=
        let twice : SetupM Unit := do
          tabBar .never
          tabBar .always
        match Config.Registrations.ofSetup (tabBar .always),
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure
            (collected.tabBar == some .always && plain.tabBar == none &&
              refusal twice == some "the tab bar is chosen twice")
        | _, _ => pure false },
    { name :=
        "a setup's edge layout is collected; an edge above 100 percent, a side given twice and a share above 100 inside an edge are each refused with their message"
      run :=
        let edged := Layout.edge .left 25 (.edge .bottom 30 Layout.manual)
        match Config.Registrations.ofSetup (layout edged) with
        | .ok collected =>
          pure
            (collected.layout == some edged &&
              refusal (layout (.edge .left 101 Layout.default)) == some (Layout.edgeTooLarge 101) &&
              refusal (layout (.edge .left 20 (.edge .left 30 Layout.default))) ==
                some (Layout.edgeTwice .left) &&
              refusal (layout (.edge .top 20 (.masterStack { share := 150 }))) ==
                some (Layout.shareTooLarge 150) &&
              refusal (layout (.edge .left 100 Layout.default)) == none)
        | _ => pure false },
    { name :=
        "a setup's display rules are collected in the order it made them, and a setup that makes none has none; a rule is refused nothing, whatever its target"
      run :=
        let rules : Array DisplayRule :=
          #[{ opener := some "a", target := .float }, { name := some "b", target := .edge .left },
            { target := .newTab, focus := false }]
        match Config.Registrations.ofSetup (rules.forM displayRule),
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure (collected.displayRules == rules && plain.displayRules == #[])
        | _, _ => pure false },
    { name :=
        "a setup's shell time limit is collected, a setup that sets none has none, and one that sets it twice is refused with a message that says so"
      run :=
        let twice : SetupM Unit := do
          shellTimeLimit 5000
          shellTimeLimit 100
        match Config.Registrations.ofSetup (shellTimeLimit 5000),
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure
            (collected.shellTimeLimit == some 5000 && plain.shellTimeLimit == none &&
              refusal twice == some Config.Registrations.shellTimeLimitTwice)
        | _, _ => pure false },
    { name :=
        "a setup's languages are collected in order; a setup that defines a language name twice, or a language with a pattern no file name can be meant by, is refused with a message that names it"
      run :=
        let toml : Language :=
          { name := "toml", patterns := [.extension "toml"], syntaxTree := { grammar := "toml" } }
        let both : SetupM Unit := do
          defineLanguage toml
          defineLanguage Language.rust
        let twice : SetupM Unit := do
          defineLanguage toml
          defineLanguage { toml with patterns := [.name "Cargo.lock"] }
        match Config.Registrations.ofSetup both,
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure
            (collected.languages.map (·.name) == #["toml", "rust"] && plain.languages.isEmpty &&
              refusal twice == some "the language `toml` is defined twice" &&
              refusal (defineLanguage { toml with patterns := [.extension ""] }) ==
                some "the language `toml` cannot be meant: its extension pattern is empty" &&
              refusal (defineLanguage { toml with patterns := [.extension "rs", .name "a/b"] }) ==
                some "the language `toml` cannot be meant: its file name pattern `a/b` holds `/`" &&
              refusal (defineLanguage { toml with patterns := [] }) == none)
        | _, _ => pure false },
    { name :=
        "a setup's syntax refresh delay is collected, a setup that sets none has none, and one that sets it twice is refused with a message that says so"
      run :=
        let twice : SetupM Unit := do
          syntaxRefreshDelay 250
          syntaxRefreshDelay 100
        match Config.Registrations.ofSetup (syntaxRefreshDelay 250),
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure
            (collected.syntaxRefreshDelay == some 250 && plain.syntaxRefreshDelay == none &&
              refusal twice == some Config.Registrations.syntaxRefreshDelayTwice)
        | _, _ => pure false },
    { name :=
        "a setup's compile contributions and project commands are collected in the order it registered them; a setup that registers none collects none"
      run :=
        let setup : SetupM Unit := do
          compileContribution
              { mode := "b-mode", markers := #["b.toml"]
                commands := #[{ name := "build", line := "b-build" }] }
          projectCommands (.remote "github.com/o/r") "cargo-mode" [("lint", "cargo clippy")]
              [("profile", .str "dev")]
          compileContribution
              { mode := "a-mode", markers := #["a.toml"], formats := #[Compile.Format.general] }
        let lint : Compile.ProjectCommands :=
          { project := .remote "github.com/o/r", mode := "cargo-mode"
            commands := #[{ name := "lint", line := "cargo clippy" }]
            settings := [("profile", .str "dev")] }
        match Config.Registrations.ofSetup setup,
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure
            (collected.contributions.map (·.mode) == #["b-mode", "a-mode"] &&
              collected.contributions.map (·.markers) == #[#["b.toml"], #["a.toml"]] &&
              collected.contributions.map (·.commands) ==
                #[#[{ name := "build", line := "b-build" }], #[]] &&
              (collected.contributions.map fun contribution => contribution.formats.map (·.name)) ==
                #[#[], #["general"]] &&
              collected.projectCommands == #[lint] &&
              plain.contributions.isEmpty &&
              plain.projectCommands.isEmpty)
        | _, _ => pure false },
    { name :=
        "a setup that registers a compile contribution with no marker, one twice, one that names a command twice, or project commands for one project and mode twice or naming a command twice, is refused with a message that says so"
      run :=
        let a : Compile.Contribution := { mode := "a-mode", markers := #["a.toml"] }
        let remote : Project.Identity := .remote "github.com/o/r"
        let twice : SetupM Unit := do
          compileContribution a
          compileContribution { a with markers := #["other.toml"] }
        let given : SetupM Unit := do
          projectCommands remote "a-mode" []
          projectCommands remote "a-mode" [("lint", "make lint")]
        let apart : SetupM Unit := do
          compileContribution a
          compileContribution { mode := "b-mode", markers := #["a.toml"] }
          projectCommands remote "a-mode" []
          projectCommands (.remote "github.com/o/other") "a-mode" []
          projectCommands remote "b-mode" []
        pure
          (refusal (compileContribution { mode := "a-mode", markers := #[] }) ==
              some "the compile contribution `a-mode` has no marker" &&
            refusal twice == some "the compile contribution `a-mode` is registered twice" &&
            refusal
                (compileContribution
                  { a with
                    commands :=
                      #[{ name := "build", line := "x" }, { name := "build", line := "y" }] }) ==
              some "the compile contribution `a-mode` names the command `build` twice" &&
            refusal given ==
              some "the project commands of `a-mode` for remote github.com/o/r are given twice" &&
            refusal (projectCommands remote "a-mode" [("lint", "a"), ("lint", "b")]) ==
              some
                "the project commands of `a-mode` for remote github.com/o/r name the command `lint` twice" &&
            refusal apart == none) },
    { name :=
        "a setup's title bar is collected, a setup that chooses none has none, and one that chooses it twice is refused with a message that says so"
      run :=
        let twice : SetupM Unit := do
          titleBar .standard
          titleBar .themed
        match Config.Registrations.ofSetup (titleBar .standard),
          Config.Registrations.ofSetup (command "x" (makes "1")) with
        | .ok collected, .ok plain =>
          pure
            (collected.titleBar == some .standard && plain.titleBar == none &&
              refusal twice == some "the title bar is chosen twice" &&
              refusal (titleBar .themed) == none)
        | _, _ => pure false },
    { name :=
        "a setup's process environment is collected as it set it: inherited, mise with no path and mise with an absolute path; a setup that does not set it collects none"
      run :=
        let collected (setup : SetupM Unit) : Option (Option Process.Setting) :=
          match Config.Registrations.ofSetup setup with
          | .ok registrations => some registrations.environment
          | .error _ => none
        pure
          (collected (processEnvironment .inherited) == some (some .inherited) &&
            collected (processEnvironment (.mise none)) == some (some (.mise none)) &&
            collected (processEnvironment (.mise (some "/opt/homebrew/bin/mise"))) ==
              some (some (.mise (some "/opt/homebrew/bin/mise"))) &&
            collected (command "first" (makes "1")) == some none) },
    { name :=
        "a setup that gives mise a relative path, or sets the process environment twice, is refused with a message that says so"
      run :=
        let twice : SetupM Unit := do
          processEnvironment .inherited
          processEnvironment (.mise none)
        pure
          (refusal (processEnvironment (.mise (some "bin/mise"))) ==
              some "the path to mise must be absolute: bin/mise" &&
            refusal twice == some "the process environment is set twice") },
    { name :=
        "a setup's workspace roots are collected in the order it declared them, each with the project it names, if any; a setup that declares none collects none"
      run :=
        let setup : SetupM Unit := do
          workspace "/r/tools" (some "tools")
          workspace "/notes"
        pure
          (match Config.Registrations.ofSetup setup,
            Config.Registrations.ofSetup (command "first" (makes "1")) with
          | .ok collected, .ok bare =>
            collected.workspaceRoots ==
                #[{ root := "/r/tools", project := some "tools" }, { root := "/notes" }] &&
              bare.workspaceRoots.isEmpty
          | _, _ => false) },
    { name :=
        "a setup that declares a workspace root that is not absolute, or one root twice, is refused with a message that says so"
      run :=
        let twice : SetupM Unit := do
          workspace "/r/tools" (some "tools")
          workspace "/r/tools/"
        pure
          (refusal (workspace "tools") == some (relativeWorkspace "tools") &&
            refusal twice == some (Config.Registrations.workspaceTwice "/r/tools")) }]

/-- A registration of the plain command `name`, which makes the text `text`. -/
def registration (name text : String) : Config.Registration :=
  { name, action := .plain (makes text) }

/-- A registration of the job `name`, which finishes with a command that
makes the text `text`. -/
def jobRegistration (name text : String) : Config.JobRegistration :=
  { name, work := fun _ _ => pure (makes text) }

/-- How the job `registry` holds under `name` ends, started with `arguments`
and run against the job model; `none` if there is no such job. -/
def registeredWork (registry : Config.Registry) (name : String) (arguments : List Argument := []) :
    Option (Job.Outcome (Array String)) :=
  (registry.findJob? name).map fun entry => worked (entry.registration.work arguments)

/-- An owner that is not the config. -/
def other : Config.Owner :=
  { name := "other" }

/-- The texts the command `registry` holds under `name` leaves, run against a
text model with none; `none` if there is no such plain command. -/
def registeredTexts (registry : Config.Registry) (name : String) : Option (Array String) :=
  (registry.find? name).bind (plainTexts ·.registration.action)

/-- The binding of the keys the key string `text` names to the command
`command`. -/
def binding (text command : String) : Config.KeyBinding :=
  { keys := keys text, command }

/-- What the keys the key string `text` names are bound to in the keymap
`registry` makes for the test scheme, whose binding is an invocation. -/
def boundTo (registry : Config.Registry) (text : String) : Option Invocation :=
  (registry.keymap TestScheme.scheme).find? (keys text)

/-- The checks of the registry (`Editor/Config/Registry.lean`). -/
def registryChecks : List Check :=
  [{  name :=
        "the registry's compile contributions are config's in config's order, then the compiled ones config does not register; config's a-mode replaces the compiled a-mode whole, and replacing config's with none brings the compiled one back"
      run :=
        let compiledA : Compile.Contribution :=
          { mode := "a-mode", markers := #["a.toml"]
            commands :=
              #[{ name := "build", line := "compiled-build" },
                { name := "lint", line := "compiled-lint" }]
            formats := #[Compile.Format.general] }
        let compiledC : Compile.Contribution := { mode := "c-mode", markers := #["c.toml"] }
        let configB : Compile.Contribution := { mode := "b-mode", markers := #["b.toml"] }
        let configA : Compile.Contribution :=
          { mode := "a-mode", markers := #["x.toml"]
            commands := #[{ name := "build", line := "config-build" }] }
        let compiled :=
          ({} : Config.Registry).replaceContributions .compiled #[compiledA, compiledC]
        let both := compiled.replaceContributions .config #[configB, configA]
        let dropped := both.replaceContributions .config #[]
        let shape (contributions : Array Compile.Contribution) :=
          contributions.map fun contribution =>
            (contribution.mode, contribution.markers, contribution.commands,
              contribution.formats.map (·.name))
        pure
          (shape compiled.compileContributions == shape #[compiledA, compiledC] &&
            shape both.compileContributions == shape #[configB, configA, compiledC] &&
            shape dropped.compileContributions == shape #[compiledA, compiledC] &&
            shape both.compileHook.contributions == shape #[configB, configA, compiledC]) },
    {
      name :=
        "replace for an owner leaves exactly the new commands of that owner, and a second replace does not add to the first",
      run :=
        let once : Config.Registry :=
          ({} : Config.Registry).replace .config
            #[registration "greet" "1", registration "part" "1"]
        let twice := once.replace .config #[registration "greet" "2"]
        pure
          (once.names == #["greet", "part"] && twice.names == #["greet"] &&
            twice.entries.size == 1 &&
            registeredTexts twice "greet" == some #["2"]) },
    { name := "replace leaves another owner's entries alone"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replace other #[registration "theirs" "t"]).replace .config
            #[registration "greet" "1"]
        let replaced := registry.replace .config #[]
        pure
          (registry.names == #["theirs", "greet"] && replaced.names == #["theirs"] &&
            registeredTexts replaced "theirs" == some #["t"]) },
    { name := "a lookup returns the latest entry of a name, and none for a name nobody registered"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replace other #[registration "greet" "theirs"]).replace .config
            #[registration "greet" "ours"]
        pure
          (registeredTexts registry "greet" == some #["ours"] && registry.names == #["greet"] &&
            (registry.find? "missing").isNone) },
    { name :=
        "an owner's jobs are replaced as a set, and another owner's are left: a lookup finds the latest job of a name, and the commands are untouched"
      run :=
        let registry : Config.Registry :=
          ((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceJobs other
                #[jobRegistration "theirs" "t"]).replaceJobs
            .config #[jobRegistration "count" "1", jobRegistration "old" "1"]
        let replaced := registry.replaceJobs .config #[jobRegistration "count" "2"]
        pure
          (registry.jobs.map (·.registration.name) == #["theirs", "count", "old"] &&
            replaced.jobs.map (·.registration.name) == #["theirs", "count"] &&
            registeredWork replaced "count" == some (.finished #["2"]) &&
            registeredWork replaced "theirs" == some (.finished #["t"]) &&
            registeredWork replaced "old" == none &&
            replaced.names == #["greet"] &&
            (replaced.find? "count").isNone) },
    { name :=
        "a job is held with what it takes: the work a lookup hands back for the arguments the job is started with computes from them, and so does the work the editor would start for an installed config"
      run :=
        let doubling : Config.JobRegistration :=
          { name := "double"
            work := fun arguments =>
              Work.of
                (fun _ =>
                  match arguments with
                  | [.nat n] => pure (2 * n)
                  | _ => throw "no number")
                fun n => makes (toString n) }
        let registry := ({} : Config.Registry).replaceJobs .config #[doubling]
        let state : Config.State Unit := { registry }
        let starting (arguments : List Argument) :=
          (state.work? "double" arguments).map fun (owner, work) => (owner.name, worked work)
        pure
          (registeredWork registry "double" [.nat 21] == some (.finished #["42"]) &&
            registeredWork registry "double" == some (.failed "no number") &&
            starting [.nat 4] == some ("config", .finished #["8"]) &&
            starting [] == some ("config", .failed "no number") &&
            (state.work? "missing" [.nat 4]).isNone) },
    { name :=
        "compiled code is an owner of its own: config's entry of a name a compiled entry has is the one a lookup finds, and once config no longer registers it the compiled one is found again"
      run :=
        let compiled : Config.Registry :=
          ({} : Config.Registry).replace .compiled
            #[registration "stamp" "compiled", registration "only" "compiled"]
        let overridden := compiled.replace .config #[registration "stamp" "config"]
        let dropped := overridden.replace .config #[]
        pure
          (Config.Owner.compiled != Config.Owner.config &&
            registeredTexts compiled "stamp" == some #["compiled"] &&
            registeredTexts overridden "stamp" == some #["config"] &&
            registeredTexts overridden "only" == some #["compiled"] &&
            overridden.names == #["stamp", "only"] &&
            registeredTexts dropped "stamp" == some #["compiled"] &&
            dropped.entries.all (·.owner == .compiled)) },
    { name :=
        "replacing an owner's bindings removes its old ones and leaves another owner's, and touches no command"
      run :=
        let registry : Config.Registry :=
          ((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceBindings
                .compiled #[binding "C-c a" "theirs"]).replaceBindings
            .config #[binding "C-c b" "one", binding "C-c c" "old"]
        let replaced := registry.replaceBindings .config #[binding "C-c b" "two"]
        pure
          (boundTo registry "C-c a" == some (invoke "theirs") &&
            boundTo registry "C-c b" == some (invoke "one") &&
            boundTo registry "C-c c" == some (invoke "old") &&
            boundTo replaced "C-c a" == some (invoke "theirs") &&
            boundTo replaced "C-c b" == some (invoke "two") &&
            boundTo replaced "C-c c" == none &&
            replaced.bindings.size == 2 &&
            replaced.names == #["greet"]) },
    { name :=
        "of two owners' bindings of one key sequence, the registry's keymap gives the later owner's, and the earlier's again once the later owner binds nothing"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceBindings .compiled
                #[binding "C-c t" "compiled", binding "C-c u" "kept"]).replaceBindings
            .config #[binding "C-c t" "config"]
        pure
          (boundTo registry "C-c t" == some (invoke "config") &&
            boundTo registry "C-c u" == some (invoke "kept") &&
            boundTo (registry.replaceBindings .config #[]) "C-c t" == some (invoke "compiled") &&
            (registry.keymap TestScheme.scheme).continues (keys "C-c")) },
    { name :=
        "replacing an owner's modes leaves the others', and the latest mode of a name is the one found"
      run :=
        let named (name parent : String) : Mode := { name, parent := some parent }
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceModes .compiled
                #[named "listing" "compiled", named "kept" "compiled"]).replaceModes
            .config #[named "listing" "config", named "gone" "config"]
        let replaced := registry.replaceModes .config #[named "new" "config"]
        let parentOf (registry : Config.Registry) (name : String) : Option String :=
          (registry.mode? name).bind (·.parent)
        pure
          (parentOf registry "listing" == some "config" &&
            parentOf registry "kept" == some "compiled" &&
            parentOf registry "gone" == some "config" &&
            parentOf replaced "listing" == some "compiled" &&
            (replaced.mode? "gone").isNone &&
            parentOf replaced "new" == some "config" &&
            replaced.modes.map (·.mode.name) == #["listing", "kept", "new"] &&
            (registry.mode? "none").isNone) },
    { name :=
        "replacing an owner's ex bindings removes its old ones and adds the new, and leaves another owner's; a name nobody bound is not found"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "theirs" }]).replaceEx
            .config
            #[{ name := "greet", command := "one", takes := .text },
              { name := "old", command := "gone" }]
        let replaced := registry.replaceEx .config #[{ name := "greet", command := "two" }]
        pure
          (registry.ex? "w" == some { name := "w", command := "theirs" } &&
            registry.ex? "greet" == some { name := "greet", command := "one", takes := .text } &&
            registry.ex? "old" == some { name := "old", command := "gone" } &&
            replaced.ex? "w" == some { name := "w", command := "theirs" } &&
            replaced.ex? "greet" == some { name := "greet", command := "two" } &&
            replaced.ex? "old" == none &&
            replaced.ex.size == 2 &&
            registry.ex? "missing" == none) },
    { name :=
        "of two owners' ex bindings of one name the latest entry is the one found: config's while it is there, and the compiled one again once config binds nothing"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" },
                  { name := "q", command := "kept" }]).replaceEx
            .config #[{ name := "w", command := "config" }]
        pure
          ((registry.ex? "w").map (·.command) == some "config" &&
            (registry.ex? "q").map (·.command) == some "kept" &&
            ((registry.replaceEx .config #[]).ex? "w").map (·.command) == some "compiled") },
    { name :=
        "what the loop is told of a registry's ex names is each bound name once, in the order they were first bound: a name config binds over a compiled one is listed once, at the compiled one's place, a name of config's alone comes after, and a registry with no ex binding has none"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" },
                  { name := "q", command := "kept" }]).replaceEx
            .config
            #[{ name := "greet", command := "greet-named" }, { name := "w", command := "config" }]
        pure
          (registry.registered.exNames == #["w", "q", "greet"] &&
            registry.registered.exNames.all (fun name => (registry.registered.ex name).isSome) &&
            ({} : Config.Registry).registered.exNames == #[] &&
            (registry.replaceEx .config #[]).registered.exNames == #["w", "q"]) },
    { name :=
        "themes are held by owner and replaced as a set: the latest entry of a name is the one found, config's theme of a compiled theme's name while config registers it and the compiled one again once it does not; the theme names are each listed once, in the order first registered, and are what the loop is told; the commands and the faces are left as they were"
      run :=
        let registry : Config.Registry :=
          ((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceThemes
                .compiled #[namedTheme "default" 1, namedTheme "second" 2]).replaceThemes
            .config #[namedTheme "mine" 3, namedTheme "second" 4]
        let replaced := registry.replaceThemes .config #[namedTheme "other" 5]
        pure
          (registry.theme? "second" == some (namedTheme "second" 4) &&
            registry.theme? "default" == some (namedTheme "default" 1) &&
            registry.theme? "nope" == none &&
            registry.themeNames == #["default", "second", "mine"] &&
            registry.registered.themeNames == registry.themeNames &&
            { registry with displayRules := #[{ target := .main }] }.registered.displayRules ==
              #[{ target := .main }] &&
            registry.registered.displayRules == #[] &&
            replaced.theme? "second" == some (namedTheme "second" 2) &&
            replaced.theme? "mine" == none &&
            replaced.themeNames == #["default", "second", "other"] &&
            replaced.themes.size == 3 &&
            replaced.names == #["greet"] &&
            replaced.definitions.isEmpty &&
            ({} : Config.Registry).registered.themeNames == #[]) },
    { name :=
        "segments are held by owner and replaced as a set: the latest entry of a name is the one found; a mode line resolves in its listing's order, with the names nobody registered listed in order, each once"
      run :=
        let mine : Segment :=
          { name := "buffer", fields := fun _ => #[{ text := "mine", face := ⟨"x"⟩ }] }
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceSegments .compiled ModeLine.shipped).replaceSegments
            .config #[mine]
        let replaced := registry.replaceSegments .config #[]
        let texts (registry : Config.Registry) (order : ModeLine.Order) : Array String :=
          ((registry.resolve order).1.fields loopContext).map (·.text)
        let (_, unknown) :=
          registry.resolve { left := #["nope", "buffer", "nope"], right := #["gone", "position"] }
        pure
          ((registry.segment? "buffer").map (·.name) == some "buffer" &&
            texts registry { left := #["buffer"], right := #[] } == #["mine"] &&
            texts replaced { left := #["buffer"], right := #[] } == #["Loop.lean"] &&
            replaced.segments.size == ModeLine.shipped.size &&
            (registry.segment? "nope").isNone &&
            unknown == #["nope", "gone"] &&
            texts registry ModeLine.Order.standard ==
              #["NORMAL", "mine", "●", "lean/Editor", "lean", "959:5", "41%"]) },
    { name :=
        "replacing an owner's ex bindings leaves the commands, the jobs, the key bindings and the modes as they were"
      run :=
        let registry : Config.Registry :=
          (((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceJobs .config
                    #[jobRegistration "count" "1"]).replaceBindings
                .config #[binding "C-c b" "one"]).replaceModes
            .config #[{ name := "listing" }]
        let replaced := registry.replaceEx .config #[{ name := "w", command := "write" }]
        pure
          (replaced.names == #["greet"] && registeredTexts replaced "greet" == some #["1"] &&
            replaced.jobs.map (·.registration.name) == #["count"] &&
            boundTo replaced "C-c b" == some (invoke "one") &&
            replaced.modes.map (·.mode.name) == #["listing"] &&
            (replaced.ex? "w").isSome) },
    { name :=
        "an owner's faces are replaced as a set, in their order, and another owner's are left: the definitions are every owner's, oldest first, and the commands are untouched"
      run :=
        let theirs := defined "keyword" (coloured 1)
        let registry : Config.Registry :=
          ((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceFaces other
                #[theirs]).replaceFaces
            .config #[defined "keyword" (coloured 2), defined "comment" (coloured 3)]
        let replaced := registry.replaceFaces .config #[defined "string" (coloured 4)]
        pure
          (registry.definitions ==
              #[theirs, defined "keyword" (coloured 2), defined "comment" (coloured 3)] &&
            replaced.definitions == #[theirs, defined "string" (coloured 4)] &&
            (replaced.replaceFaces .config #[]).definitions == #[theirs] &&
            replaced.names == #["greet"]) }]

/-- A declaration of the store `name` at `version`, which starts at the
number 0 and accepts any number. It migrates a number written at version 1 by
adding 100 to it, and, wrongly, anything written at version 5 to a string,
which it does not accept. -/
def numbers (name : String) (version : Nat) : StoreDeclaration :=
  { name, version, initial := .nat 0,
    accepts := fun
      | .nat _ => true
      | _ => false,
    migrate := fun
      | 1, .nat n => some (.nat (n + 100))
      | 5, _ => some (.str "not a number")
      | _, _ => none }

/-- A cell of the config's. -/
def cell (name : String) (version : Nat) (value : Value) : Config.Cell :=
  { owner := .config, name, version, value }

/-- Installs `declarations` for the config over `cells`, and returns the
cells after it and the source and severity of each diagnostic. -/
def installed (cells : Array Config.Cell) (declarations : Array StoreDeclaration) :
    Array Config.Cell × Array (String × Config.Severity) :=
  let (after, diagnostics) := ({ cells } : Config.Cells).install .config declarations
  (after.cells, diagnostics.map fun diagnostic => (diagnostic.source, diagnostic.severity))

/-- The checks of the rule that meets a new config's stores with the cells
there are (`Editor/Config/Stores.lean`), one for each case. -/
def storeChecks : List Check :=
  [{ name := "installing a store with no cell makes one from its initial value",
     run := pure (installed #[] #[numbers "counter" 1] == (#[cell "counter" 1 (.nat 0)], #[])) },
    { name := "a cell at the declared version that the store accepts is kept"
      run :=
        pure
          (installed #[cell "counter" 1 (.nat 7)] #[numbers "counter" 1] ==
            (#[cell "counter" 1 (.nat 7)], #[])) },
    { name :=
        "a cell the store does not accept is reset to the initial value, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "counter" 1 (.str "seven")] #[numbers "counter" 1] ==
            (#[cell "counter" 1 (.nat 0)], #[("store counter", .warning)])) },
    { name :=
        "a cell at another version becomes the store's migration of it, at the declared version"
      run :=
        pure
          (installed #[cell "counter" 1 (.nat 7)] #[numbers "counter" 2] ==
            (#[cell "counter" 2 (.nat 107)], #[])) },
    { name :=
        "a cell the store's migration drops is reset to the initial value, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "counter" 3 (.nat 7)] #[numbers "counter" 2] ==
            (#[cell "counter" 2 (.nat 0)], #[("store counter", .warning)])) },
    { name :=
        "a cell migrated to a tree the store does not accept is reset to the initial value, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "counter" 5 (.nat 7)] #[numbers "counter" 2] ==
            (#[cell "counter" 2 (.nat 0)], #[("store counter", .warning)])) },
    { name := "a cell of the owner that is no longer declared is removed, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "old" 1 (.nat 7), cell "counter" 1 (.nat 1)] #[numbers "counter" 1] ==
            (#[cell "counter" 1 (.nat 1)], #[("store old", .warning)])) },
    { name := "another owner's cell is left alone, whatever its name"
      run :=
        let theirs : Config.Cell :=
          { owner := other, name := "counter", version := 9, value := .str "theirs" }
        pure
          (installed #[theirs] #[numbers "counter" 1] ==
              (#[theirs, cell "counter" 1 (.nat 0)], #[]) &&
            installed #[theirs] #[] == (#[theirs], #[])) }]

/-- The state of the fake elaborator: the names of the chunks elaborated so
far, oldest first. Its base is the state with none. -/
abbrev Elaborated :=
  Array String

/-- A call the fake elaborator received. -/
inductive ElaboratorCall where
  /-- The base was imported. -/
  | base
  /-- The chunk called `name` was elaborated on the state `before`. -/
  | chunk (before : Elaborated) (name : String)
  /-- The `setup` program was asked for, of a config that left `state`. -/
  | setup (state : Elaborated)
  deriving DecidableEq, Repr

/-- The diagnostic the fake elaborator gives for the chunk called `name` when
the chunk's text tells it to. -/
def told (name : String) (severity : Config.Severity) : Config.Diagnostic :=
  { source := name, line := 1, severity, message := "the fake was told to" }

/-- A hand-written fake of the elaborator port. It records every call in
`calls`. A chunk whose text is "fails" fails with an error; one whose text is
"warns" elaborates with a warning; one whose text is "throws" makes the port
itself throw. `setup` is the program it says the config defines, or the
diagnostics it has instead. With `baseThrows` the port throws when it is
asked to import the base, and with `setupThrows` when it is asked for the
`setup` program. -/
def fakeElaborator (calls : IO.Ref (Array ElaboratorCall))
    (setup : Except (Array Config.Diagnostic) (SetupM Unit) := .ok (pure ()))
    (baseThrows setupThrows : Bool := false) : Config.Elaborator Elaborated :=
  {
    base := do
      calls.modify (·.push .base)
      if baseThrows then
        throw (IO.userError "the fake elaborator's base broke")
      return #[],
    chunk := fun before chunk => do
      calls.modify (·.push (.chunk before chunk.name))
      match chunk.text with
      | "fails" =>
        return { diagnostics := #[told chunk.name .error], state := none }
      | "warns" =>
        return { diagnostics := #[told chunk.name .warning],
                 state := some (before.push chunk.name) }
      | "throws" =>
        throw (IO.userError "the fake elaborator broke")
      | _ =>
        return { diagnostics := #[], state := some (before.push chunk.name) },
    setup := fun state => do
      calls.modify (·.push (.setup state))
      if setupThrows then
        throw (IO.userError "the fake elaborator's setup broke")
      return setup }

/-- A hand-written fake of the source port: the chunks called `names`, each
with its own name as its text unless `texts` gives it another. -/
def fakeSource (names : List String) (texts : List (String × String) := []) : Config.Source :=
  {
    chunks :=
      pure
        (names.toArray.map fun name =>
          { name, text := ((texts.find? (·.1 == name)).map (·.2)).getD name }) }

/-- The chunks a config of the fake elaborator has once the chunks called
`names` are loaded, each with its name as its text. -/
def loaded (names : List String) : Array (Config.Chunk Elaborated) :=
  (List.range names.length).toArray.map fun index =>
    { name := names.getD index "", text := names.getD index "",
      after := (names.take (index + 1)).toArray }

/-- The names and the states of an outcome's chunks, if it built any. -/
def builtChunks (outcome : Config.Outcome Elaborated) : Option (Array (String × Elaborated)) :=
  outcome.built.map (·.chunks.map fun chunk => (chunk.name, chunk.after))

/-- Builds `source` over `chunks` with a fake elaborator whose base is already
imported, and returns the calls the elaborator received. -/
def rebuildCalls (chunks : List String) (source : Config.Source) : IO (Array ElaboratorCall) := do
  let calls ← IO.mkRef #[]
  discard <| Config.build (fakeElaborator calls) source (some #[]) (loaded chunks)
  calls.get

/-- The checks of the session core (`Editor/Config/Session.lean`): which
chunks a reload elaborates, from which state, and what it gives back. -/
def sessionChecks : List Check :=
  [{
      name :=
        "a first load imports the base, then elaborates every chunk in the source's order, each on the state after the one before it, then asks for setup on the last state",
      run := do
        let calls ← IO.mkRef #[]
        let outcome ← Config.build (fakeElaborator calls) (fakeSource ["a", "b", "c"]) none #[]
        return (← calls.get) ==
              #[.base, .chunk #[] "a", .chunk #["a"] "b", .chunk #["a", "b"] "c",
                .setup #["a", "b", "c"]] &&
            outcome.base == some #[] &&
            builtChunks outcome ==
              some #[("a", #["a"]), ("b", #["a", "b"]), ("c", #["a", "b", "c"])] &&
            outcome.diagnostics.isEmpty },
    { name := "with the base given, it is not imported again, and the outcome hands it back"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ← Config.build (fakeElaborator calls) (fakeSource ["a"]) (some #["given"]) #[]
        return (← calls.get) == #[.chunk #["given"] "a", .setup #["given", "a"]] &&
            outcome.base == some #["given"] },
    { name :=
        "changing a chunk elaborates it and the chunks after it, from the cached state before it"
      run := do
        let calls ← rebuildCalls ["a", "b", "c"] (fakeSource ["a", "b", "c"] [("b", "changed")])
        return calls == #[.chunk #["a"] "b", .chunk #["a", "b"] "c", .setup #["a", "b", "c"]] },
    { name := "removing a chunk elaborates the chunks after it, from the state before it"
      run := do
        let calls ← rebuildCalls ["a", "b", "c"] (fakeSource ["a", "c"])
        return calls == #[.chunk #["a"] "c", .setup #["a", "c"]] },
    { name := "adding a chunk at the end elaborates it alone"
      run := do
        let calls ← rebuildCalls ["a", "b"] (fakeSource ["a", "b", "c"])
        return calls == #[.chunk #["a", "b"] "c", .setup #["a", "b", "c"]] },
    { name := "renaming a chunk elaborates it and the chunks after it"
      run := do
        let calls ← rebuildCalls ["a", "b", "c"] (fakeSource ["a", "b2", "c"] [("b2", "b")])
        return calls == #[.chunk #["a"] "b2", .chunk #["a", "b2"] "c", .setup #["a", "b2", "c"]] },
    { name := "a reload with nothing changed elaborates no chunk, and still asks for setup"
      run := do
        let calls ← rebuildCalls ["a", "b"] (fakeSource ["a", "b"])
        return calls == #[.setup #["a", "b"]] },
    { name :=
        "a chunk that fails gives a rejected outcome with its diagnostics, and no later chunk and no setup is elaborated"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls) (fakeSource ["a", "b", "c"] [("b", "fails")])
              (some #[]) #[]
        return (← calls.get) == #[.chunk #[] "a", .chunk #["a"] "b"] && outcome.built.isNone &&
            outcome.diagnostics == #[told "b" .error] },
    { name := "a chunk with only a warning is built, and the outcome carries the warning"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls) (fakeSource ["a", "b"] [("a", "warns")]) (some #[])
              #[]
        return builtChunks outcome == some #[("a", #["a"]), ("b", #["a", "b"])] &&
            outcome.diagnostics == #[told "a" .warning] },
    { name := "what setup registers is in the outcome"
      run := do
        let calls ← IO.mkRef #[]
        let setup : SetupM Unit := command "greet" (makes "hello")
        let outcome ←
          Config.build (fakeElaborator calls (.ok setup)) (fakeSource ["a"]) (some #[]) #[]
        return (outcome.built.map (·.registrations.commands.map (·.name))) == some #["greet"] },
    { name :=
        "a setup that throws gives a rejected outcome whose diagnostic's source is setup and whose message is the one thrown"
      run := do
        let calls ← IO.mkRef #[]
        let setup : SetupM Unit := do
          command "greet" (makes "hello")
          throw "no thanks"
        let outcome ←
          Config.build (fakeElaborator calls (.ok setup)) (fakeSource ["a"]) (some #[]) #[]
        return outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "setup", severity := .error, message := "no thanks" }] },
    { name :=
        "a setup that registers a command name twice gives a rejected outcome whose diagnostic's source is setup and names the command"
      run := do
        let calls ← IO.mkRef #[]
        let setup : SetupM Unit := do
          command "greet" (makes "hello")
          command "greet" (makes "again")
        let outcome ←
          Config.build (fakeElaborator calls (.ok setup)) (fakeSource ["a"]) (some #[]) #[]
        return outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "setup", severity := .error,
                  message := "the command `greet` is registered twice" }] },
    { name :=
        "a config whose setup cannot be produced gives a rejected outcome with the diagnostics"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls (.error #[told "setup" .error])) (fakeSource ["a"])
              (some #[]) #[]
        return outcome.built.isNone && outcome.diagnostics == #[told "setup" .error] },
    { name := "a config with no chunks is built with nothing registered, and no setup is asked for"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ← Config.build (fakeElaborator calls) (fakeSource []) (some #[]) (loaded ["a"])
        return (← calls.get).isEmpty && builtChunks outcome == some #[] &&
            (outcome.built.map (·.registrations.commands.size)) == some 0 },
    { name :=
        "a source that cannot be read gives a rejected outcome, which still hands back the base"
      run := do
        let calls ← IO.mkRef #[]
        let source : Config.Source := { chunks := throw (IO.userError "no such directory") }
        let outcome ← Config.build (fakeElaborator calls) source none #[]
        return (← calls.get) == #[.base] && outcome.built.isNone && outcome.base == some #[] &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("config", .error)] },
    { name := "an elaborator that throws gives a rejected outcome that names the chunk"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls) (fakeSource ["a", "b"] [("a", "throws")]) (some #[])
              #[]
        return (← calls.get) == #[.chunk #[] "a"] && outcome.built.isNone &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("a", .error)] },
    { name :=
        "a base that cannot be imported gives a rejected outcome with no base and one diagnostic from the base, and no chunk is elaborated"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls (baseThrows := true)) (fakeSource ["a"]) none #[]
        return (← calls.get) == #[.base] && outcome.built.isNone && outcome.base == none &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("base", .error)] },
    { name :=
        "an elaborator that throws when asked for setup gives a rejected outcome with a diagnostic from setup, and hands back the base"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls (setupThrows := true)) (fakeSource ["a"]) (some #[])
              #[]
        return (← calls.get) == #[.chunk #[] "a", .setup #["a"]] && outcome.built.isNone &&
            outcome.base == some #[] &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("setup", .error)] }]

/-- An effect of the reload reducer, as a check compares it: a start with the
base and the names of the chunks it carries, the cancelling of an owner's
jobs with the owner's name, or a report with its number, whether it
installed, the sources of its diagnostics, and its counts of chunks and
commands. -/
inductive Seen where
  /-- A job was started. -/
  | start (base : Option Elaborated) (chunks : Array String)
  /-- The jobs of the owner called `owner` were cancelled. -/
  | cancelJobs (owner : String)
  /-- A reload was reported. -/
  | report (number : Nat) (installed : Bool) (sources : Array String) (chunks commands : Nat)
  /-- The theme in force was switched. -/
  | themed
  /-- The window was asked for this appearance. -/
  | appearance (appearance : Appearance)
  deriving DecidableEq, Repr

/-- `effect` as a check compares it. -/
def seen : Config.Effect Elaborated → Seen
  | .start base chunks => .start base (chunks.map (·.name))
  | .cancelJobs owner => .cancelJobs owner.name
  | .report report =>
    .report report.number report.installed (report.diagnostics.map (·.source)) report.chunks
      report.commands
  | .themed => .themed
  | .appearance appearance => .appearance appearance

/-- The state the reducer reaches from `state` through `events`, and every
effect on the way. -/
def reduceFrom (state : Config.State Elaborated) (events : List (Config.Event Elaborated)) :
    Config.State Elaborated × Array Seen :=
  events.foldl
    (fun (state, effects) event =>
      let (state, more) := Config.step state event
      (state, effects ++ more.map seen))
    (state, #[])

/-- The state the reducer reaches through `events` from nothing loaded, and
every effect on the way. -/
def reduce (events : List (Config.Event Elaborated)) : Config.State Elaborated × Array Seen :=
  reduceFrom {} events

/-- The outcome of a reload that built the chunks called `names`, whose
`setup` is `setup`. Built by hand: no elaborator ran. -/
def accepted (names : List String) (setup : SetupM Unit) : Config.Outcome Elaborated :=
  { base := some #[], diagnostics := #[],
    built :=
      (Config.Registrations.ofSetup setup).toOption.map fun registrations =>
        { chunks := loaded names, registrations } }

/-- The outcome of a reload that was rejected with one error from `source`. -/
def rejected (source : String) : Config.Outcome Elaborated :=
  { base := some #[], diagnostics := #[told source .error], built := none }

/-- A `setup` that registers `greet`, which makes the text `text`. -/
def greets (text : String) : SetupM Unit :=
  command "greet" (makes text)

/-- A `setup` that registers the command `greet` and the job `count`, each of
which makes the text `text`. -/
def counts (text : String) : SetupM Unit := do
  command "greet" (makes text)
  job "count" (fun _ => pure text) makes

/-- The job the editor would start for `name`: its owner's name, and how the
job ends when it runs against the job model; `none` if there is no such job. -/
def startable (state : Config.State Elaborated) (name : String) :
    Option (String × Job.Outcome (Array String)) :=
  (state.work? name).map fun (owner, work) => (owner.name, worked work)

/-- A `setup` that declares `counter` and registers `bump` over it, which
adds `step`. -/
def bumps (step : Nat) : SetupM Unit := do
  counter.declare
  counter.command "bump" fun n => pure (n + step)

/-- Runs the command called `name` the way the editor does, against the
editor's models `model`: the state once what the command wrote is written
back, and the models after it. `none` if there is no such command or it was
refused. -/
def runs (state : Config.State Elaborated) (name : String) (model : EditorModel := editorModel) :
    Option (Config.State Elaborated × EditorModel) :=
  (state.program? name).bind fun program =>
    match program.runModel model with
    | (.ok write, model) => some (state.written write, model)
    | (.error _, _) => none

/-- The texts the command called `name` leaves when the editor runs it. -/
def runTexts (state : Config.State Elaborated) (name : String) : Option (Array String) :=
  (runs state name).map (·.2.texts.contents)

/-- The value of the config's store called `name`. -/
def stored (state : Config.State Elaborated) (name : String) : Option Value :=
  (state.cells.find? .config name).map (·.value)

/-- An argument as a check's command writes it. -/
def argumentText : Argument → String
  | .nat value => toString value
  | .int value => toString value
  | .str value => value
  | .bool value => toString value

/-- What a command that is given its call was called with, as one line: its
label, its arguments, and its keys as a key string. -/
def callText (label : String) (call : Call) : String :=
  " ".intercalate (label :: call.arguments.map argumentText ++ [Key.notations call.keys])

/-- A registration of the command `name` that is given its call, and makes a
text of `label` and what it was called with (`callText`). -/
def callRegistration (name label : String) : Config.Registration :=
  { name, action := .call fun call => makes (callText label call) }

/-- Runs the command called `name` the way an invocation does
(`Config.State.command?`), against the editor's models, with a call for the
focused window of a new editor state, `arguments` and the keys `typed`: what
the command asks to write, and the texts after it, the scratch buffer's
first. `none` if there is no such command or it was refused. -/
def calls (state : Config.State Elaborated) (name : String) (arguments : List Argument := [])
    (typed : List Key := []) : Option (Option Config.Write × Array String) :=
  (state.command? name).bind fun run =>
    let program : EditorM (Option Config.Write) := do
      let editor ← EditorState.initial ⟨640, 480⟩
      let some target := editor.focusedTarget? | throw .noSuchText
      run { target, arguments, keys := typed }
    match program.runModel editorModel with
    | (.ok write, model) => some (write, model.texts.contents)
    | (.error _, _) => none

/-- A config state in which compiled code has registered `registrations`,
before any config. -/
def compiledWith (registrations : Array Config.Registration) : Config.State Elaborated :=
  { registry := ({} : Config.Registry).replace .compiled registrations }

/-- The theme `second` of the reducer's checks: one definition of its own. -/
def secondTheme : Theme :=
  oneFace 7

/-- A config state in which compiled code has registered two themes, before
any config: `default`, the built-in one, and `second` (`secondTheme`). -/
def themed : Config.State Elaborated :=
  {
    registry :=
      ({} : Config.Registry).replaceThemes .compiled
        #[{ name := Theme.defaultName, theme := Theme.builtin },
          { name := "second", theme := secondTheme }] }

/-- The report of the reload that finishes with `outcome` from `state`. -/
def reportFrom (state : Config.State Elaborated) (outcome : Config.Outcome Elaborated) :
    Config.Report :=
  (state.install outcome).2

/-- The checks of the reload reducer (`Editor/Config/Reload.lean`), with
outcomes built by hand. -/
def reloadChecks : List Check :=
  [{  name :=
        "an install sets the title bar config chooses, a later install that chooses none goes back to none, the themed one, and a rejected one changes nothing"
      run :=
        let (state, _) :=
          reduceFrom themed [.requested, .finished (accepted ["a"] (titleBar .standard))]
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (themed.titleBar == none && state.titleBar == some .standard &&
            dropped.titleBar == none &&
            kept.titleBar == some .standard) },
    { name :=
        "the window opens with the title bar the start-up config chose once its reload has finished, themed when it chose none, and themed when the wait ran out before the reload finished, whatever was installed by then"
      run :=
        pure
          (Window.titleBarAtOpen true (some .standard) == .standard &&
            Window.titleBarAtOpen true (some .themed) == .themed &&
            Window.titleBarAtOpen true none == .themed &&
            Window.titleBarAtOpen false (some .standard) == .themed &&
            Window.titleBarAtOpen false none == .themed) },
    { name :=
        "an install sets the frame padding config sets, a later install that sets none goes back to none, the editor's own, and a rejected one changes nothing"
      run :=
        let (state, _) :=
          reduceFrom themed [.requested, .finished (accepted ["a"] (framePadding 12))]
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (themed.framePadding == none && state.framePadding == some 12 &&
            dropped.framePadding == none &&
            kept.framePadding == some 12) },
    { name :=
        "an install sets when the tab bar is shown as config chooses, a later install that chooses none goes back to none, the editor's own, and a rejected one changes nothing"
      run :=
        let (state, _) := reduceFrom themed [.requested, .finished (accepted ["a"] (tabBar .never))]
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (themed.tabBar == none && state.tabBar == some .never && dropped.tabBar == none &&
            kept.tabBar == some .never) },
    { name :=
        "an install sets the layout config chooses, a later install that chooses none goes back to none, the editor's own, and a rejected one changes nothing"
      run :=
        let (state, _) :=
          reduceFrom themed [.requested, .finished (accepted ["a"] (layout .monocle))]
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (themed.layout == none && state.layout == some .monocle && dropped.layout == none &&
            kept.layout == some .monocle) },
    { name :=
        "criterion 4, in the model: an install whose display rules name a float, a left edge the default layout lacks, a new tab and a right edge it lacks too is installed and keeps the float's and the new tab's, its report says each rule left out, by its place in the setup, and the echo area says them; under a layout with a left edge the float's, the left edge's and the new tab's rules are kept; a later install with no rule clears them, and a rejected one changes nothing"
      run :=
        let rules : Array DisplayRule :=
          #[{ opener := some "a", target := .float }, { name := some "b", target := .edge .left },
            { target := .newTab }, { target := .edge .right }]
        let ruled : SetupM Unit := rules.forM displayRule
        let edged : SetupM Unit := do
          layout (.edge .left 25 Layout.default)
          ruled
        let report := reportFrom themed (accepted ["a"] ruled)
        let (state, _) := reduceFrom themed [.requested, .finished (accepted ["a"] ruled)]
        let (left, _) := reduceFrom themed [.requested, .finished (accepted ["a"] edged)]
        let (dropped, _) := reduceFrom left [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom left [.requested, .finished (rejected "a")]
        let both : SetupM Unit := do
          useTheme "gone"
          displayRule { target := .edge .right }
        pure
          (report.installed &&
            state.registry.displayRules ==
              #[{ opener := some "a", target := .float }, { target := .newTab }] &&
            report.unusableRules ==
              #[Config.Report.leftOut 2 (Layout.noEdge .left),
                Config.Report.leftOut 4 (Layout.noEdge .right)] &&
            report.echo ==
              some
                "reload: display rule 2 is left out: the layout has no left edge; display rule 4 is left out: the layout has no right edge" &&
            left.registry.displayRules ==
              #[{ opener := some "a", target := .float },
                { name := some "b", target := .edge .left }, { target := .newTab }] &&
            (reportFrom themed (accepted ["a"] edged)).unusableRules ==
              #[Config.Report.leftOut 4 (Layout.noEdge .right)] &&
            left.registry.registered.displayRules == left.registry.displayRules &&
            dropped.registry.displayRules == #[] &&
            kept.registry.displayRules == left.registry.displayRules &&
            (reportFrom themed (accepted ["a"] both)).echo ==
              some
                "reload: no theme is registered as `gone`; display rule 1 is left out: the layout has no right edge" &&
            (reportFrom themed (accepted ["a"] (displayRule { target := .stack }))).echo == none) },
    { name :=
        "an install sets the mode line config lists, and its report names each segment nobody registered, which the echo area says after the unknown theme's sentence; a later install that lists none goes back to the default, and a rejected one changes nothing"
      run :=
        let listed : SetupM Unit := modeLine ["state", "nope"] ["position"]
        let both : SetupM Unit := do
          useTheme "gone"
          modeLine ["state", "nope", "nope"] ["lost"]
        let segmented : Config.State Elaborated :=
          { themed with registry := themed.registry.replaceSegments .compiled ModeLine.shipped }
        let (state, _) := reduceFrom segmented [.requested, .finished (accepted ["a"] listed)]
        let report := reportFrom segmented (accepted ["a"] listed)
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (state.modeLine == some { left := #["state", "nope"], right := #["position"] } &&
            report.unknownSegments == #["nope"] &&
            report.echo == some "reload: no segment is registered as `nope`" &&
            (reportFrom segmented (accepted ["a"] both)).echo ==
              some
                "reload: no theme is registered as `gone`; no segment is registered as `nope`; no segment is registered as `lost`" &&
            (reportFrom segmented (accepted ["a"] (modeLine ["state"] []))).echo == none &&
            dropped.modeLine == none &&
            kept.modeLine == state.modeLine &&
            (reportFrom segmented (accepted ["a"] (pure ()))).unknownSegments == #[]) },
    { name :=
        "a config's segments are replaced at every install: one it defines can be listed, and is gone once a reload no longer defines it"
      run :=
        let own : SetupM Unit := do
          defineSegment "greeting" fun _ => #[{ text := "hi", face := ⟨"mode-line.secondary"⟩ }]
          modeLine ["greeting"] []
        let (state, _) := reduceFrom themed [.requested, .finished (accepted ["a"] own)]
        let (dropped, _) :=
          reduceFrom state [.requested, .finished (accepted ["a"] (modeLine ["greeting"] []))]
        pure
          ((state.registry.segment? "greeting").isSome &&
            (reportFrom themed (accepted ["a"] own)).unknownSegments.isEmpty &&
            (dropped.registry.segment? "greeting").isNone &&
            (reportFrom state (accepted ["a"] (modeLine ["greeting"] []))).unknownSegments ==
              #["greeting"]) },
    { name :=
        "criterion 1: a config that names a registered theme starts in it, with config's faces over it; so does one that names a theme it defines itself, and the report says nothing in the echo area"
      run :=
        let named : SetupM Unit := do
          useTheme "second"
          face "keyword" (coloured 1)
        let own : SetupM Unit := do
          defineTheme "mine" (oneFace 9)
          useTheme "mine"
        let (state, effects) := reduceFrom themed [.requested, .finished (accepted ["a"] named)]
        let (mine, _) := reduceFrom themed [.requested, .finished (accepted ["a"] own)]
        pure
          (state.themeName == "second" &&
            state.theme == secondTheme ++ #[defined "keyword" (coloured 1)] &&
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 0] &&
            (reportFrom themed (accepted ["a"] named)).echo == none &&
            mine.themeName == "mine" &&
            mine.theme == oneFace 9) },
    { name :=
        "a theme config defines replaces the built-in theme wholesale: one of `default` alone, in force, defines no `cursor.normal`; one built as `Theme.builtin ++ #[…]` keeps it"
      run :=
        let definesCursor (theme : Theme) : Bool := theme.any (·.name == ⟨"cursor.normal"⟩)
        let bare : SetupM Unit := do
          defineTheme "bare" (oneFace 9)
          useTheme "bare"
        let over : SetupM Unit := do
          defineTheme "over" (Theme.builtin ++ oneFace 9)
          useTheme "over"
        let (bareState, _) := reduceFrom themed [.requested, .finished (accepted ["a"] bare)]
        let (overState, _) := reduceFrom themed [.requested, .finished (accepted ["a"] over)]
        pure
          (definesCursor Theme.builtin && bareState.themeName == "bare" &&
            !definesCursor bareState.theme &&
            overState.themeName == "over" &&
            definesCursor overState.theme) },
    { name :=
        "criterion 2: a config that names no theme starts in default, the built-in theme, with config's faces over it; a state before any config is in default"
      run :=
        let (state, _) :=
          reduceFrom themed [.requested, .finished (accepted ["a"] (face "keyword" (coloured 1)))]
        pure
          (({} : Config.State Elaborated).themeName == Theme.defaultName &&
            themed.themeName == Theme.defaultName &&
            state.themeName == Theme.defaultName &&
            state.theme == Theme.builtin ++ #[defined "keyword" (coloured 1)]) },
    { name :=
        "criterion 2: choosing a registered theme switches to it with the effect that says so, and a reload whose config names no theme keeps the theme in force"
      run :=
        let (chosen, effects) := Config.step themed (.choose "second")
        let (reloaded, _) :=
          reduceFrom chosen [.requested, .finished (accepted ["a"] (face "keyword" (coloured 1)))]
        pure
          (chosen.themeName == "second" && effects.map seen == #[.themed] &&
            reloaded.themeName == "second" &&
            reloaded.theme == secondTheme ++ #[defined "keyword" (coloured 1)]) },
    { name :=
        "criterion 4: after a switch, config's own faces still apply over the new theme, in their order"
      run :=
        let setup : SetupM Unit := do
          face "keyword" (coloured 1)
          face "default" (coloured 2)
        let (loaded, _) := reduceFrom themed [.requested, .finished (accepted ["a"] setup)]
        let (switched, _) := Config.step loaded (.choose "second")
        pure
          (loaded.theme ==
              Theme.builtin ++ #[defined "keyword" (coloured 1), defined "default" (coloured 2)] &&
            switched.theme ==
              secondTheme ++ #[defined "keyword" (coloured 1), defined "default" (coloured 2)]) },
    { name :=
        "criteria 5 and 6: a config that names a theme nobody registered is installed, leaves the theme in force as it was, and its report names the unknown theme in the echo area"
      run :=
        let (chosen, _) := Config.step themed (.choose "second")
        let unknown : SetupM Unit := do
          useTheme "nope"
          face "keyword" (coloured 1)
        let (state, effects) := reduceFrom chosen [.requested, .finished (accepted ["a"] unknown)]
        let report := reportFrom chosen (accepted ["a"] unknown)
        pure
          (state.themeName == "second" &&
            state.theme == secondTheme ++ #[defined "keyword" (coloured 1)] &&
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 0] &&
            report.unknownTheme == some "nope" &&
            report.echo == some s!"reload: {Theme.unknown "nope"}" &&
            report.echo == some "reload: no theme is registered as `nope`" &&
            (reportFrom chosen (accepted ["a"] (useTheme "second"))).unknownTheme == none) },
    { name :=
        "a rejected reload leaves the theme in force; choosing a theme nobody registered leaves the state and has no effect; a theme of config's in force that the next reload drops falls back to default"
      run :=
        let (chosen, _) := Config.step themed (.choose "second")
        let (kept, _) := reduceFrom chosen [.requested, .finished (rejected "a")]
        let (unknown, nothing) := Config.step chosen (.choose "nope")
        let own : SetupM Unit := do
          defineTheme "mine" (oneFace 9)
          useTheme "mine"
        let (mine, _) := reduceFrom themed [.requested, .finished (accepted ["a"] own)]
        let (dropped, _) := reduceFrom mine [.requested, .finished (accepted ["a"] (pure ()))]
        pure
          (kept.themeName == "second" && unknown.themeName == "second" &&
            unknown.theme == chosen.theme &&
            nothing.isEmpty &&
            mine.themeName == "mine" &&
            dropped.themeName == Theme.defaultName &&
            dropped.theme == Theme.builtin) },
    { name :=
        "the display is handed the theme in force, with its name, after a reload that installs and after a choice that switched the theme, and not after a rejected reload or a choice of a theme nobody registered"
      run := do
        let handed ← IO.mkRef (#[] : Array (String × Theme))
        let setTheme (name : String) (theme : Theme) : BaseIO Unit :=
          handed.modify (·.push (name, theme))
        let steps : List (Config.Event Elaborated) :=
          [.requested, .finished (accepted ["a"] (face "keyword" (coloured 1))), .choose "second",
            .requested, .finished (rejected "a"), .choose "nope"]
        let mut state := themed
        for event in steps do
          let (next, effects) := Config.step state event
          Config.retheme setTheme next effects
          state := next
        return (← handed.get) ==
            #[(Theme.defaultName, Theme.builtin ++ #[defined "keyword" (coloured 1)]),
              ("second", secondTheme ++ #[defined "keyword" (coloured 1)])] },
    { name :=
        "a state whose registry holds no theme of the name in force is drawn in the built-in theme"
      run :=
        pure
          (({ themeName := "second" } : Config.State Elaborated).theme == Theme.builtin &&
            ({} : Config.State Elaborated).theme == Theme.builtin) },
    { name := "a request with no job running starts one, carrying the base and the loaded chunks"
      run :=
        let first := reduce [.requested]
        let later := reduce [.requested, .finished (accepted ["a", "b"] (greets "1")), .requested]
        pure
          (first.2 == #[.start none #[]] &&
            later.2 ==
              #[.start none #[], .cancelJobs "config", .report 1 true #[] 2 1,
                .start (some #[]) #["a", "b"]]) },
    { name :=
        "requests while a job runs start nothing, and the finish then starts exactly one more job"
      run :=
        let (running, effects) := reduce [.requested, .requested, .requested, .requested]
        let (after, more) := reduceFrom running [.finished (accepted ["a"] (greets "1"))]
        let (_, last) := reduceFrom after [.finished (accepted ["a"] (greets "1"))]
        pure
          (effects == #[.start none #[]] &&
            more == #[.cancelJobs "config", .report 1 true #[] 1 1, .start (some #[]) #["a"]] &&
            last == #[.cancelJobs "config", .report 2 true #[] 1 1]) },
    { name :=
        "an accepted outcome installs its chunks and exactly its commands, and the report says installed"
      run :=
        let (state, effects) := reduce [.requested, .finished (accepted ["a", "b"] (greets "1"))]
        pure
          (state.chunks.map (·.name) == #["a", "b"] && state.registry.names == #["greet"] &&
            state.registry.entries.all (·.owner == .config) &&
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 2 1]) },
    { name :=
        "a rejected outcome leaves the registry, the chunks and the cells as they were, and the report carries its diagnostics"
      run :=
        let setup : SetupM Unit := do
          greets "1"
          bumps 1
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] setup)]
        let bumped := ((runs loaded "bump").map (·.1)).getD loaded
        let (state, effects) :=
          reduceFrom bumped
            [.requested, .finished (rejected "a"), .requested, .finished (rejected "setup")]
        pure
          (state.chunks.map (·.name) == #["a"] && state.registry.names == #["greet", "bump"] &&
            runTexts state "greet" == some #["1"] &&
            stored state "counter" == some (.nat 1) &&
            effects ==
              #[.start (some #[]) #["a"], .report 2 false #["a"] 1 2, .start (some #[]) #["a"],
                .report 3 false #["setup"] 1 2]) },
    { name := "a rejected first load keeps the base it imported for the next job"
      run :=
        pure
          ((reduce [.requested, .finished (rejected "a"), .requested]).2 ==
            #[.start none #[], .report 1 false #["a"] 0 0, .start (some #[]) #[]]) },
    { name :=
        "the theme is the built-in one then the installed config's definitions, in the order its setup made them, and the built-in one alone before any config"
      run :=
        let setup : SetupM Unit := do
          face "keyword" (coloured 1)
          greets "1"
          face "default" (coloured 2)
        let (state, effects) := reduce [.requested, .finished (accepted ["a"] setup)]
        pure
          ((reduce []).1.theme == Theme.builtin &&
            state.theme ==
              Theme.builtin ++ #[defined "keyword" (coloured 1), defined "default" (coloured 2)] &&
            -- The report's line is what it was: faces are no commands.
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 1]) },
    { name :=
        "an install replaces config's faces as a set: a face the new config does not set is the theme's again, one it sets again is there once, and a config that sets none leaves the built-in theme"
      run :=
        let first : SetupM Unit := do
          face "keyword" (coloured 1)
          face "comment" (coloured 2)
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] first)]
        let (again, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (face "keyword" (coloured 3)))]
        let (bare, _) := reduceFrom again [.requested, .finished (accepted ["a"] (greets "1"))]
        pure
          (again.theme == Theme.builtin ++ #[defined "keyword" (coloured 3)] &&
            bare.theme == Theme.builtin) },
    { name := "a rejected reload keeps config's faces, and the theme with them"
      run :=
        let (loaded, _) :=
          reduce [.requested, .finished (accepted ["a"] (face "keyword" (coloured 1)))]
        let (state, _) :=
          reduceFrom loaded
            [.requested, .finished (rejected "a"), .requested, .finished (rejected "setup")]
        pure
          (state.theme == Theme.builtin ++ #[defined "keyword" (coloured 1)] &&
            state.theme == loaded.theme) },
    { name :=
        "an installed reload puts config's process environment in the registry, a rejected one leaves the one that was there, and a config that sets none gives none"
      run :=
        let (loaded, _) :=
          reduce [.requested, .finished (accepted ["a"] (processEnvironment .inherited))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        pure
          ((reduce []).1.registry.environment == none &&
            loaded.registry.environment == some .inherited &&
            kept.registry.environment == some .inherited &&
            bare.registry.environment == none) },
    { name :=
        "an installed reload puts config's workspace roots in the registry, which tells the loop of them with the config generation; every install bumps the generation, a rejected reload changes neither, and with nothing installed the generation is 0"
      run :=
        let roots : Array Workspace.ConfigRoot := #[{ root := "/r/tools", project := some "tools" }]
        let (loaded, _) :=
          reduce [.requested, .finished (accepted ["a"] (workspace "/r/tools" (some "tools")))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let told (state : Config.State Elaborated) : Array Workspace.ConfigRoot × Nat :=
          let registered := state.registry.registered
          (registered.workspaceRoots, registered.generation)
        pure
          (told (reduce []).1 == (#[], 0) && told loaded == (roots, 1) && told kept == (roots, 1) &&
            told bare == (#[], 2)) },
    { name :=
        "an installed reload puts config's shell time limit in the registry, which tells the loop of it; a rejected reload leaves it, and a config that sets none goes back to none"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (shellTimeLimit 5000))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let told (state : Config.State Elaborated) : Option Nat :=
          state.registry.registered.shellTimeLimit
        pure
          (told (reduce []).1 == none && told loaded == some 5000 && told kept == some 5000 &&
            told bare == none) },
    { name :=
        "an installed reload puts config's languages in the registry over the compiled ones, so the loop is told config's rust in place of the shipped one; a rejected reload keeps them, and a config that defines none brings the shipped one back"
      run :=
        let mine :=
          { Language.rust with
            syntaxTree := { grammar := "rust", highlights := some "(identifier) @variable" } }
        let start : Config.State Elaborated :=
          { registry := ({} : Config.Registry).replaceLanguages .compiled Language.shipped }
        let (loaded, _) :=
          reduceFrom start [.requested, .finished (accepted ["a"] (defineLanguage mine))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let rustOf (state : Config.State Elaborated) : Option Language :=
          state.registry.registered.languages.find? (·.name == "rust")
        pure
          (rustOf start == some Language.rust && rustOf loaded == some mine &&
            loaded.registry.registered.languages.map (·.name) ==
              ["rust", "json", "markdown", "toml", "lean"] &&
            rustOf kept == some mine &&
            rustOf bare == some Language.rust) },
    { name :=
        "an installed reload puts config's syntax refresh delay in the registry, which tells the loop of it; a rejected reload leaves it, and a config that sets none goes back to none"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (syntaxRefreshDelay 250))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let told (state : Config.State Elaborated) : Option Nat :=
          state.registry.registered.syntaxRefreshDelay
        pure
          (told (reduce []).1 == none && told loaded == some 250 && told kept == some 250 &&
            told bare == none) },
    { name :=
        "an installed reload puts config's compile contributions and project commands in the registry, which tells the loop of them; a rejected reload leaves them, and a config that registers none leaves the compiled ones alone"
      run :=
        let start : Config.State Elaborated :=
          {
            registry :=
              ({} : Config.Registry).replaceContributions .compiled
                #[{ mode := "a-mode", markers := #["a.toml"] }] }
        let setup : SetupM Unit := do
          compileContribution { mode := "b-mode", markers := #["b.toml"] }
          projectCommands (.remote "github.com/o/r") "b-mode" [("lint", "b-lint")]
        let (loaded, _) := reduceFrom start [.requested, .finished (accepted ["a"] setup)]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let told (state : Config.State Elaborated) : Array String × Array String :=
          let hook := state.registry.registered.compile
          (hook.contributions.map (·.mode), hook.projects.map (·.mode))
        pure
          (told start == (#["a-mode"], #[]) &&
            told loaded == (#["b-mode", "a-mode"], #["b-mode"]) &&
            told kept == told loaded &&
            told bare == (#["a-mode"], #[])) },
    { name :=
        "an outcome with no base leaves the base as it was: with none known the next job imports again, and a known one is not forgotten"
      run :=
        let baseless : Config.Outcome Elaborated :=
          { base := none, diagnostics := #[told "base" .error], built := none }
        pure
          ((reduce [.requested, .finished baseless, .requested]).2 ==
              #[.start none #[], .report 1 false #["base"] 0 0, .start none #[]] &&
            (reduce
                  [.requested, .finished (rejected "a"), .requested, .finished baseless,
                    .requested]).2 ==
              #[.start none #[], .report 1 false #["a"] 0 0, .start (some #[]) #[],
                .report 2 false #["base"] 0 0, .start (some #[]) #[]]) },
    { name := "reload replaces a command"
      run :=
        let first : SetupM Unit := do
          greets "v1"
          command "old" (makes "old")
        let (state, _) :=
          reduce
            [.requested, .finished (accepted ["a"] first), .requested,
              .finished (accepted ["a"] (greets "v2"))]
        pure
          (runTexts state "greet" == some #["v2"] && state.registry.names == #["greet"] &&
            (state.program? "old").isNone) },
    { name := "a reload does not double-register"
      run :=
        let (state, _) :=
          reduce
            [.requested, .finished (accepted ["a"] (greets "v1")), .requested,
              .finished (accepted ["a"] (greets "v1")), .requested,
              .finished (accepted ["a"] (greets "v1"))]
        pure (state.registry.entries.size == 1 && runTexts state "greet" == some #["v1"]) },
    { name :=
        "a config that registers a command name twice is not installed, so the commands a report counts are the names that can be run"
      run := do
        let setup : SetupM Unit := do
          greets "v1"
          bumps 1
        let twice : SetupM Unit := do
          greets "v2"
          greets "v3"
        let (loaded, first) := reduce [.requested, .finished (accepted ["a"] setup)]
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls (.ok twice)) (fakeSource ["a"]) loaded.base
              loaded.chunks
        let (state, effects) := reduceFrom loaded [.requested, .finished outcome]
        return first == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 2] &&
            effects == #[.start (some #[]) #["a"], .report 2 false #["setup"] 1 2] &&
            state.registry.names == #["greet", "bump"] &&
            state.registry.entries.size == 2 &&
            runTexts state "greet" == some #["v1"] },
    { name := "a store value survives a reload"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (bumps 1))]
        let once := ((runs loaded "bump").map (·.1)).getD loaded
        let twice := ((runs once "bump").map (·.1)).getD once
        let (reloaded, _) := reduceFrom twice [.requested, .finished (accepted ["a"] (bumps 10))]
        let again := ((runs reloaded "bump").map (·.1)).getD reloaded
        pure
          (stored loaded "counter" == some (.nat 0) && stored twice "counter" == some (.nat 2) &&
            stored reloaded "counter" == some (.nat 2) &&
            stored again "counter" == some (.nat 12)) },
    { name :=
        "an installed reload's report carries the config's warnings, then a diagnostic for each store value that was lost"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (bumps 1))]
        let bumped := ((runs loaded "bump").map (·.1)).getD loaded
        -- An accepted outcome whose one chunk elaborated with a warning.
        let warned (setup : SetupM Unit) : Config.Outcome Elaborated :=
          { accepted ["a"] setup with diagnostics := #[told "a" .warning] }
        -- The counter at a version its store does not migrate to: the value
        -- is reset. And a config that no longer declares it: the cell goes.
        let unmigrated : SetupM Unit := ({ counter with version := 2 } : Store Nat).declare
        let (reset, resetEffects) := reduceFrom bumped [.requested, .finished (warned unmigrated)]
        let (removed, removedEffects) :=
          reduceFrom bumped [.requested, .finished (warned (greets "v1"))]
        pure
          (stored bumped "counter" == some (.nat 1) &&
            resetEffects ==
              #[.start (some #[]) #["a"], .cancelJobs "config",
                .report 2 true #["a", "store counter"] 1 0] &&
            ((reset.cells.find? .config "counter").map fun cell => (cell.version, cell.value)) ==
              some (2, .nat 0) &&
            removedEffects ==
              #[.start (some #[]) #["a"], .cancelJobs "config",
                .report 2 true #["a", "store counter"] 1 1] &&
            stored removed "counter" == none) },
    { name :=
        "a command over a store that is refused writes nothing, and a name nobody registered runs nothing"
      run :=
        let setup : SetupM Unit := do
          counter.declare
          counter.command "broken" fun n => do
              (⟨7⟩ : TextId).insert 0 "x"
              return n + 1
        let (state, _) := reduce [.requested, .finished (accepted ["a"] setup)]
        pure
          ((state.program? "broken").isSome && (runs state "broken").isNone &&
            (state.program? "missing").isNone) },
    { name :=
        "a job is not counted as a command: the report of a config that registers one command and one job says one command"
      run :=
        let (state, effects) := reduce [.requested, .finished (accepted ["a"] (counts "v1"))]
        pure
          (effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 1] &&
            state.commands == 1 &&
            state.registry.names == #["greet"]) },
    { name :=
        "an accepted outcome cancels the config's jobs before it is reported, and before the follow-up job starts; a rejected outcome cancels nothing"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (counts "v1"))]
        -- A reload asked for while one runs: the follow-up starts last.
        let (_, acceptedEffects) :=
          reduceFrom loaded [.requested, .requested, .finished (accepted ["a"] (counts "v2"))]
        -- The same source again: every accepted reload cancels.
        let (_, unchanged) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (counts "v1"))]
        let (_, rejectedEffects) :=
          reduceFrom loaded [.requested, .requested, .finished (rejected "a")]
        pure
          (acceptedEffects ==
              #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 1,
                .start (some #[]) #["a"]] &&
            unchanged ==
              #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 1] &&
            rejectedEffects ==
              #[.start (some #[]) #["a"], .report 2 false #["a"] 1 1, .start (some #[]) #["a"]]) },
    { name :=
        "a reload replaces the config's jobs: the registry finds the new config's job and not the old one's, and a rejected reload keeps the old one's"
      run :=
        let first : SetupM Unit := do
          counts "v1"
          job "old" (fun _ => pure "old") makes
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] first)]
        let (reloaded, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (counts "v2"))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        pure
          (startable loaded "count" == some ("config", .finished #["v1"]) &&
            startable loaded "old" == some ("config", .finished #["old"]) &&
            startable reloaded "count" == some ("config", .finished #["v2"]) &&
            startable reloaded "old" == none &&
            reloaded.registry.jobs.size == 1 &&
            startable kept "count" == some ("config", .finished #["v1"]) &&
            startable kept "old" == some ("config", .finished #["old"]) &&
            startable loaded "missing" == none) },
    { name :=
        "config registers a command under a compiled command's name: an invocation of the name runs config's, the report counts config's commands alone, and after a reload without the registration the invocation runs the compiled one"
      run :=
        let compiled := compiledWith #[registration "stamp" "compiled"]
        let (overridden, effects) :=
          reduceFrom compiled
            [.requested, .finished (accepted ["a"] (command "stamp" (makes "config")))]
        let (dropped, later) :=
          reduceFrom overridden [.requested, .finished (accepted ["a"] (greets "hello"))]
        pure
          ((calls compiled "stamp").map (·.2) == some #["", "compiled"] &&
            (calls overridden "stamp").map (·.2) == some #["", "config"] &&
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 1] &&
            (calls dropped "stamp").map (·.2) == some #["", "compiled"] &&
            later == #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 1] &&
            (calls dropped "missing").isNone) },
    { name :=
        "a command that is given its call is handed the call an invocation runs it with: its arguments and its keys"
      run :=
        let state := compiledWith #[callRegistration "stamp" "stamp"]
        pure
          ((calls state "stamp" [.nat 3, .str "w"] (keys "C-x i")).map (·.2) ==
              some #["", "stamp 3 w C-x i"] &&
            ((calls state "stamp").bind (·.1)).isNone) },
    { name :=
        "a command config registers as one given its call is handed the call an invocation runs it with: it acts on the call's target and reads its arguments and its keys; an install replaces it with config's other commands, and a config that no longer registers it drops it"
      run :=
        let greets (label : String) : SetupM Unit :=
          commandWith "greet" fun call => Loop.insert call.target (callText label call)
        let called (state : Config.State Elaborated) : Option (Array String) :=
          (calls state "greet" [.nat 3, .str "w"] (keys "C-x i")).map (·.2)
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (greets "one"))]
        let (reloaded, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (greets "two"))]
        let (dropped, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (command "other" (makes "o")))]
        pure
          (called loaded == some #["one 3 w C-x i"] && called reloaded == some #["two 3 w C-x i"] &&
            (called dropped).isNone &&
            loaded.registry.names == #["greet"]) },
    { name :=
        "a command over a store, run as an invocation runs it, hands back what to write: the owner, the store and the new tree, which the state then holds"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (bumps 4))]
        pure <|
          match calls loaded "bump" with
          | some (some write, _) =>
            write.owner == .config && write.store == "counter" && write.value == .nat 4 &&
              stored (loaded.written (some write)) "counter" == some (.nat 4)
          | _ => false },
    { name :=
        "the driver's run of a command that is given its call runs it with the target it is handed and nothing else, and runs nothing when it is handed none"
      run :=
        let state := compiledWith #[callRegistration "stamp" "stamp", registration "plain" "p"]
        let program : EditorM (Option Bool) := do
          let editor ← EditorState.initial ⟨640, 480⟩
          let some target := editor.focusedTarget? | throw .noSuchText
          let some run := state.program? "stamp" (some target) | return none
          return some (← run).isNone
        pure
          ((state.program? "stamp").isNone &&
            (match program.runModel editorModel with
            | (.ok (some true), model) => model.texts.contents == #["", "stamp "]
            | _ => false) &&
            runTexts state "plain" == some #["p"]) },
    { name :=
        "an accepted outcome replaces the config's key bindings and leaves compiled ones: a key the new config binds to another command is bound to that one alone, and one it no longer binds is unbound; a rejected outcome keeps them"
      run :=
        let compiled : Config.State Elaborated :=
          { registry := ({} : Config.Registry).replaceBindings .compiled #[binding "C-c k" "kept"] }
        let first : SetupM Unit := do
          bindKey "C-c t" "one"
          bindKey "C-c o" "old"
        let (loaded, _) := reduceFrom compiled [.requested, .finished (accepted ["a"] first)]
        let (reloaded, effects) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (bindKey "C-c t" "two"))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        pure
          (boundTo loaded.registry "C-c t" == some (invoke "one") &&
            boundTo loaded.registry "C-c o" == some (invoke "old") &&
            boundTo reloaded.registry "C-c t" == some (invoke "two") &&
            boundTo reloaded.registry "C-c o" == none &&
            boundTo reloaded.registry "C-c k" == some (invoke "kept") &&
            reloaded.registry.bindings.size == 2 &&
            effects == #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 0] &&
            boundTo kept.registry "C-c t" == some (invoke "one") &&
            boundTo kept.registry "C-c o" == some (invoke "old")) },
    { name :=
        "an accepted outcome replaces the config's modes and leaves compiled ones; a rejected outcome keeps config's"
      run :=
        let compiled : Config.State Elaborated :=
          { registry := ({} : Config.Registry).replaceModes .compiled #[{ name := "kept" }] }
        let first : SetupM Unit := do
          defineMode { name := "listing", parent := some "first" }
          defineMode { name := "gone" }
        let (loaded, _) := reduceFrom compiled [.requested, .finished (accepted ["a"] first)]
        let (reloaded, _) :=
          reduceFrom loaded
            [.requested,
              .finished
                (accepted ["a"] (defineMode { name := "listing", parent := some "second" }))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let names (state : Config.State Elaborated) : Array String :=
          state.registry.modes.map (·.mode.name)
        let parentOf (state : Config.State Elaborated) : Option String :=
          (state.registry.mode? "listing").bind (·.parent)
        pure
          (names loaded == #["kept", "listing", "gone"] && parentOf loaded == some "first" &&
            names reloaded == #["kept", "listing"] &&
            parentOf reloaded == some "second" &&
            names kept == names loaded &&
            parentOf kept == some "first") },
    { name :=
        "an accepted outcome replaces the config's ex bindings and leaves compiled ones: a name the new config binds to another command runs that one, one it no longer binds is found no more, and a compiled name it bound is the compiled one again; a rejected outcome keeps them; an ex binding is not counted as a command"
      run :=
        let compiled : Config.State Elaborated :=
          {
            registry :=
              ({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" }, { name := "q", command := "kept" }] }
        let first : SetupM Unit := do
          exCommand "greet" "one" (takes := .text)
          exCommand "old" "gone"
          exCommand "w" "config"
        let (loaded, _) := reduceFrom compiled [.requested, .finished (accepted ["a"] first)]
        let (reloaded, effects) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (exCommand "greet" "two"))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let runs (state : Config.State Elaborated) (name : String) : Option String :=
          (state.registry.ex? name).map (·.command)
        pure
          (runs loaded "greet" == some "one" && runs loaded "old" == some "gone" &&
            runs loaded "w" == some "config" &&
            runs loaded "q" == some "kept" &&
            reloaded.registry.ex? "greet" == some { name := "greet", command := "two" } &&
            runs reloaded "old" == none &&
            runs reloaded "w" == some "compiled" &&
            runs reloaded "q" == some "kept" &&
            reloaded.registry.ex.size == 3 &&
            effects == #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 0] &&
            kept.registry.ex == loaded.registry.ex) },
    { name :=
        "a rejected reload's echo is its first error with its place and the first line of its message, and says how many more errors there are"
      run :=
        let error (source : String) (line column : Nat) (message : String) : Config.Diagnostic :=
          { source, line, column, severity := .error, message }
        let warning : Config.Diagnostic :=
          { source := "a.lean", line := 1, severity := .warning, message := "unused" }
        let report (installed : Bool) (diagnostics : Array Config.Diagnostic) : Config.Report :=
          { number := 2, installed, diagnostics, chunks := 1, commands := 1 }
        let one := report false #[warning, error "30-broken.lean" 1 20 "type mismatch\n  \"x\""]
        let three :=
          report false
            #[error "b.lean" 3 4 "unknown identifier 'x'", warning, error "b.lean" 5 0 "second",
              error "setup" 0 0 "third"]
        pure
          (one.echo == some "reload: 30-broken.lean:1:20: error: type mismatch" &&
            three.echo == some "reload: b.lean:3:4: error: unknown identifier 'x' (and 2 more)" &&
            (report true #[warning]).echo == none &&
            (report true #[]).echo == none) }]

/-- A key press that produced `text`. -/
def pressed (text : String) : WindowCheck.Input :=
  .key true false false text

/-- A key release, which produces no text. -/
def released : WindowCheck.Input :=
  .key false false false ""

/-- The tally of `arrivals`, counted in order from nothing. -/
def counted (arrivals : List WindowCheck.Arrival) : WindowCheck.Tally :=
  arrivals.foldl WindowCheck.Tally.step {}

/-- The tally of `inputs`, each arriving and handled at the instant 0. -/
def tallied (inputs : List WindowCheck.Input) : WindowCheck.Tally :=
  counted (inputs.map fun input => { input, arrived := 0, handled := 0 })

/-- `text` as often as `count` says. -/
def repeated (text : String) (count : Nat) : String :=
  String.join (List.replicate count text)

/-- A run whose window opened on the platform `fake` 2.5 ms after it was
asked for, and reported `inputs` after that, each arriving and handled at the
instant the window opened. -/
def opened (inputs : List WindowCheck.Input) (options : WindowCheck.Options := {})
    (ending : WindowCheck.Ending := .closed) : WindowCheck.Run :=
  { options, serviceOnMain := true, askedAt := 1000000, failure := none, ending
    tally :=
      counted
        ((.opened "fake" :: inputs).map fun input =>
          { input, arrived := 3500000, handled := 3500000 }) }

/-- A run whose window could not be opened, for the reason `reason`. Its
ending is what the check gives a run nothing ended. -/
def unopened (reason : String) : WindowCheck.Run :=
  { options := {}, serviceOnMain := true, askedAt := 1000000, failure := some reason, tally := {}
    ending := .closed }

/-- The report of a run with no window, after its second line: the forms
every line takes when nothing arrived. -/
def nothingArrived : List String :=
  ["focus: never gained; first pointer press in the window: none",
    "keys: 0 key events reached the Lean loop (0 presses, 0 of them repeats, 0 releases); text: \"\"",
    "latency from a key's arrival in Rust to its handling in Lean, in µs: no samples",
    "dead keys: 0 key events marked dead",
    "composition: not enabled; 0 preedit and 0 commit events; committed: \"\"",
    "ended: the window never opened"]

/-- What a fake window does in one check: the inputs it reports once it is
run, each with the instant it arrived and the instant the fake's clock reads
when the loop has pulled it. -/
structure FakeWindow where
  /-- What the window reports once it runs, in order. -/
  arrivals : List WindowCheck.Arrival := []
  /-- Why the window cannot be opened, if it cannot. -/
  cannotOpen : Option String := none
  /-- What the fake answers when asked where the main-thread service is. -/
  serviceOnMain : Bool := true
  /-- The clock's reading until the first input is pulled. -/
  askedAt : Nat := 0
  /-- What the clock reads once the window runs and every input has been
  pulled: a time limit passes when this is far enough on. -/
  idleAt : Option Nat := none
  /-- Whether the window, once it is run, takes until a close has been asked
  of it to begin: a close that came too early, which it forgets as every
  window does. -/
  slowToBegin : Bool := false

/-- What a fake window has been asked and has said. -/
structure FakeWindowState where
  /-- The clock's reading. -/
  now : Nat
  /-- The inputs the window has reported that the loop has not pulled. -/
  pending : List WindowCheck.Arrival := []
  /-- Whether the window is running. -/
  running : Bool := false
  /-- Whether the loop has been told to stop once `pending` is empty. -/
  stopped : Bool := false
  /-- The calls made of the window, in order: `probe`, `run true` or
  `run false`, `close`, `stop`. -/
  calls : Array String := #[]
  /-- The lines printed. -/
  lines : Array String := #[]
  /-- The lines said to the person at the terminal, apart from the report. -/
  said : Array String := #[]
  /-- How many closes were asked for while the window was not running, and
  so forgotten. -/
  forgotten : Nat := 0

/-- The fake as the record the check runs on. `closed` is resolved by a
close asked for while the window is running, and ends the run. A close asked
for at any other time is forgotten, as the window port's contract has it. -/
def FakeWindow.window (fake : FakeWindow) (state : IO.Ref FakeWindowState)
    (closed : IO.Promise Unit) : WindowCheck.Window :=
  let called (call : String) : IO Unit :=
    state.modify fun state => { state with calls := state.calls.push call }
  { next := do
      repeat
        let pulled ←
          state.modifyGet fun state =>
              match state.pending with
              | arrival :: rest =>
                (some (arrival.input, arrival.arrived),
                  { state with
                    pending := rest, now := arrival.handled })
              | [] =>
                if state.stopped then (some (.stop, 0), state)
                else
                  if state.running then (none, { state with now := fake.idleAt.getD state.now })
                  else (none, state)
        if let some input := pulled then
          return input
        IO.sleep 1
      return (.stop, 0)
    clock := return (← state.get).now
    serviceOnMain := do
      called "probe"
      return fake.serviceOnMain
    run := fun composition => do
      called s!"run {composition}"
      if let some reason := fake.cannotOpen then
        return .error reason
      if fake.slowToBegin then
        while (← state.get).forgotten == 0 && !(← closed.isResolved) do
          IO.sleep 1
      state.modify fun state =>
          { state with
            pending := fake.arrivals, running := true }
      while !(← closed.isResolved) do
        IO.sleep 1
      state.modify fun state => { state with running := false }
      return .ok ()
    close := do
      called "close"
      let running ←
        state.modifyGet fun state =>
            (state.running,
              if state.running then state else { state with forgotten := state.forgotten + 1 })
      if running then
        closed.resolve ()
    stop := do
      called "stop"
      state.modify fun state => { state with stopped := true }
    emit := fun line => state.modify fun state => { state with lines := state.lines.push line } }

/-- What one check on a fake window showed. -/
structure Checked where
  /-- The lines the check printed. -/
  lines : List String
  /-- The calls it made of the window, in order. -/
  calls : List String
  /-- Its exit status; `none` if it did not end in time. -/
  status : Option UInt32
  /-- What it said to the person at the terminal, apart from the report. -/
  said : List String
  /-- How many closes it asked for while the window was not running. -/
  forgotten : Nat

/-- Runs `act` on `fake`'s window and on somewhere to say a line, and returns
what it did. It runs on a dedicated task that this polls, so one that never
ends fails here instead of hanging the executable, and the fake's window is
closed whatever happened, so its run is not left behind. -/
def FakeWindow.drive (fake : FakeWindow)
    (act : WindowCheck.Window → (String → IO Unit) → IO UInt32) : IO Checked := do
  let state ← IO.mkRef { now := fake.askedAt }
  let closed ← IO.Promise.new
  let say (line : String) : IO Unit :=
    state.modify fun state => { state with said := state.said.push line }
  let task ← IO.asTask (prio := .dedicated) (act (fake.window state closed) say)
  let status ←
    if ← eventually (IO.hasFinished task) then
      some <$> IO.ofExcept task.get
    else
      pure none
  closed.resolve ()
  let state ← state.get
  return {
      lines := state.lines.toList, calls := state.calls.toList, status
      said := state.said.toList, forgotten := state.forgotten }

/-- Runs the keyboard check on `fake`, with `options`. -/
def FakeWindow.check (fake : FakeWindow) (options : WindowCheck.Options := {}) : IO Checked :=
  fake.drive fun window _ => WindowCheck.check window options

/-- Runs the keyboard check on `fake` as `editor window-check` runs it, with
the command line's `arguments`. -/
def FakeWindow.withArguments (fake : FakeWindow) (arguments : List String) : IO Checked :=
  fake.drive fun window say => WindowCheck.withArguments window arguments say

/-- A window that opens 2.5 ms after it is asked for, at the instant
1 000 000 on the clock, and then reports each thing the check tells apart:
the focus, a pointer press, five key events with latencies of 10, 30, 20,
100 and 40.5 µs, a composition, a request to close, and one more key 50 µs
after that. -/
def typed : FakeWindow :=
  { askedAt := 1000000
    arrivals :=
      [{ input := .opened "fake", arrived := 3500000, handled := 3520000 },
        { input := .focus true, arrived := 5500000, handled := 5510000 },
        { input := .pointerPressed, arrived := 9500000, handled := 9510000 },
        { input := pressed "h", arrived := 10000000, handled := 10010000 },
        { input := released, arrived := 10100000, handled := 10130000 },
        { input := .key true true false "h", arrived := 10200000, handled := 10220000 },
        { input := .key true false true "", arrived := 10300000, handled := 10400000 },
        { input := pressed "é", arrived := 10500000, handled := 10540500 },
        { input := .compositionEnabled, arrived := 10600000, handled := 10600000 },
        { input := .preedit "´", arrived := 10700000, handled := 10700000 },
        { input := .commit "é", arrived := 10800000, handled := 10800000 },
        { input := .closeRequested, arrived := 10900000, handled := 10900000 },
        { input := pressed "z", arrived := 11000000, handled := 11050000 }] }

/-- The report of the check on `typed`. -/
def typedReport : List String :=
  ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
    "window: opened by fake 2.5 ms after it was asked for",
    "focus: gained 2.0 ms after the window opened; first pointer press in the window: 6.0 ms after it opened",
    "keys: 6 key events reached the Lean loop (5 presses, 1 of them repeats, 1 releases); text: \"hhéz\"",
    "latency from a key's arrival in Rust to its handling in Lean, in µs: median 30.0 / 99th percentile 100.0 / maximum 100.0 (6 samples)",
    "dead keys: 1 key events marked dead",
    "composition: enabled; 1 preedit and 1 commit events; committed: \"é\"",
    "ended: the window was closed"]

/-- The checks of the keyboard check's pure core (`Editor/WindowCheck.lean`):
what it counts, the percentiles, and each line of the report. -/
def windowTallyChecks : List Check :=
  [{
      name :=
        "the tally counts key presses, the repeats among them, releases, dead keys, preedits and commits",
      run := do
        let tally :=
          tallied
            [pressed "a", released, .key true true false "a", .key true false true "",
              .key false false true "", .preedit "´", .preedit "", .commit "é", .compositionEnabled,
              .focus true, .other]
        return tally.keys == 5 && tally.presses == 3 && tally.repeats == 1 && tally.releases == 2 &&
            tally.dead == 2 &&
            tally.preedits == 2 &&
            tally.commits == 1 &&
            tally.composing &&
            !(tallied [pressed "a"]).composing },
    { name := "the tally's text is what the presses produced, in order, and a release adds nothing"
      run :=
        pure
          ((tallied
                [pressed "a", .key false false false "x", pressed "é", pressed "",
                  pressed "b"]).text ==
            "aéb") },
    { name := "the typed text and the committed text are cut at 60 characters"
      run := do
        let typed := tallied ((List.replicate 70 (pressed "é")) ++ [pressed "z"])
        let committed := tallied [.commit (repeated "ab" 31), .commit "z"]
        return typed.text == repeated "é" 60 && typed.presses == 71 &&
            committed.committed == repeated "ab" 30 &&
            committed.commits == 2 },
    { name :=
        "every key event is a latency sample, the time from its arrival to its handling, and nothing else is"
      run := do
        let tally :=
          counted
            [{ input := pressed "a", arrived := 100, handled := 350 },
              { input := .focus true, arrived := 400, handled := 900 },
              { input := released, arrived := 1000, handled := 1001 },
              { input := .key true true false "a", arrived := 2000, handled := 2000 },
              { input := .commit "é", arrived := 3000, handled := 4000 }]
        return tally.latencies == #[250, 1, 0] },
    { name :=
        "the tally keeps when the window opened, when it first gained the focus and when a pointer was first pressed in it"
      run := do
        let tally :=
          counted
            [{ input := .opened "fake", arrived := 10, handled := 11 },
              { input := .focus false, arrived := 20, handled := 21 },
              { input := .focus true, arrived := 30, handled := 31 },
              { input := .pointerPressed, arrived := 40, handled := 41 },
              { input := .focus true, arrived := 50, handled := 51 },
              { input := .pointerPressed, arrived := 60, handled := 61 }]
        let none : WindowCheck.Tally := {}
        return tally.platform == some "fake" && tally.openedAt == some 10 &&
            tally.focusedAt == some 30 &&
            tally.pointerAt == some 40 &&
            none.platform.isNone &&
            none.focusedAt.isNone &&
            none.pointerAt.isNone },
    { name :=
        "the median, the 99th percentile and the maximum are nearest-rank over the sorted samples: of 1, 2, 100 and 101 samples, and none of none"
      run := do
        let upTo (count : Nat) : Array Nat := ((List.range count).map (· + 1)).reverse.toArray
        return WindowCheck.spread #[] == none && WindowCheck.spread #[5] == some (5, 5, 5) &&
            WindowCheck.spread #[2, 1] == some (1, 2, 2) &&
            WindowCheck.spread (upTo 100) == some (50, 99, 100) &&
            WindowCheck.spread (upTo 101) == some (51, 100, 101) },
    { name := "an instant is printed to one decimal place, rounded down"
      run :=
        pure
          (WindowCheck.millis 2500000 == "2.5" && WindowCheck.millis 0 == "0.0" &&
            WindowCheck.micros 40500 == "40.5" &&
            WindowCheck.micros 999 == "0.9" &&
            WindowCheck.micros 123456789 == "123456.7") },
    { name := "the report of a window that opened is its eight lines, exactly"
      run := do
        let run : WindowCheck.Run :=
          { options := {}, serviceOnMain := true, askedAt := 1000000, failure := none
            tally := counted typed.arrivals, ending := .closed }
        return WindowCheck.report run == typedReport },
    { name :=
        "the report of a window that could not open is eight lines too: the reason in the second, once, and the others as when nothing arrived"
      run :=
        pure
          (WindowCheck.report (unopened "no display") ==
            ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
                "window: could not open: no display"] ++
              nothingArrived) },
    { name :=
        "a window that ran and never said that it opened is reported as one that could not open, however its run was ended: that reason in the second line, the last line that the window never opened, and status 1"
      run := do
        let silent (ending : WindowCheck.Ending) (inputs : List WindowCheck.Input := []) :
          WindowCheck.Run :=
          { options := {}, serviceOnMain := true, askedAt := 1000000, failure := none
            tally := tallied inputs, ending }
        let expected :=
          ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
              "window: could not open: the window ran and did not say that it opened"] ++
            nothingArrived
        -- What did arrive is still counted.
        let typedInto := WindowCheck.report (silent .closed [pressed "a"])
        return WindowCheck.report (silent .closed) == expected &&
            WindowCheck.report (silent .limit) == expected &&
            WindowCheck.status (silent .closed) == 1 &&
            WindowCheck.status (silent .limit) == 1 &&
            typedInto[1]? == expected[1]? &&
            typedInto[3]? ==
              some
                "keys: 1 key events reached the Lean loop (1 presses, 0 of them repeats, 0 releases); text: \"a\"" &&
            typedInto.getLast? == some "ended: the window never opened" &&
            WindowCheck.status (silent .closed [pressed "a"]) == 1 },
    { name :=
        "the focus line gives the gain and the first pointer press, each or neither, and judges nothing"
      run := do
        let line (inputs : List WindowCheck.Arrival) : Option String :=
          (WindowCheck.report
              { opened [] with
                tally :=
                  counted
                    ({ input := .opened "fake", arrived := 1000000, handled := 0 } :: inputs) })[2]?
        let gain : WindowCheck.Arrival := { input := .focus true, arrived := 3000000, handled := 0 }
        let press : WindowCheck.Arrival :=
          { input := .pointerPressed, arrived := 2500000, handled := 0 }
        return line [] == some "focus: never gained; first pointer press in the window: none" &&
            line [gain] ==
              some
                "focus: gained 2.0 ms after the window opened; first pointer press in the window: none" &&
            line [press] ==
              some
                "focus: never gained; first pointer press in the window: 1.5 ms after it opened" &&
            line [press, gain] ==
              some
                "focus: gained 2.0 ms after the window opened; first pointer press in the window: 1.5 ms after it opened" },
    { name := "the last line says how the check ended, in one of three ways"
      run := do
        let last (run : WindowCheck.Run) : Option String := (WindowCheck.report run).getLast?
        return last (opened []) == some "ended: the window was closed" &&
            last (opened [] {} .limit) == some "ended: the time limit" &&
            last (unopened "no display") == some "ended: the window never opened" },
    { name :=
        "the first line says what was asked for and where the main-thread service is, for each value of both"
      run := do
        let first (composition serviceOnMain : Bool) (seconds : Nat) : Option String :=
          (WindowCheck.report { opened [] { composition, seconds } with serviceOnMain }).head?
        return first true true 120 ==
              some
                "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes" &&
            first false true 3 ==
              some
                "window-check: composition off, limit 3 s; the main-thread service is on the process's main thread: yes" &&
            first true false 120 ==
              some
                "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: no" },
    { name :=
        "with no key the latency line says there are no samples, and the report is still eight lines"
      run := do
        let lines := WindowCheck.report (opened [.focus true])
        return lines.length == 8 &&
            lines[4]? ==
              some
                "latency from a key's arrival in Rust to its handling in Lean, in µs: no samples" },
    { name :=
        "typed text is printed quoted, so a key that produced a control character keeps the line whole"
      run :=
        pure
          ((WindowCheck.report
                (opened [pressed "a", pressed "\r", pressed "\"", pressed "b"]))[3]? ==
            some
              "keys: 4 key events reached the Lean loop (4 presses, 0 of them repeats, 0 releases); text: \"a\\x0d\\\"b\"") },
    { name := "the exit status is 0 for a window that ran and 1 for one that could not open"
      run :=
        pure
          (WindowCheck.status (opened []) == 0 &&
            WindowCheck.status (unopened "no display") == 1) }]

/-- The checks of the keyboard check itself (`WindowCheck.check`), on a fake
window written by hand: what it asks of the window and in what order, and
the report it prints. -/
def windowLoopChecks : List Check :=
  [{
      name :=
        "the check on a window that reports each thing prints the report of what arrived, and ends with status 0",
      run := do
        let checked ← typed.check
        return checked.lines == typedReport && checked.status == some 0 },
    { name :=
        "the check asks where the main-thread service is before it runs the window and never again, closes the window once when it is asked to close, and stops the loop when the window has closed"
      run := return (← typed.check).calls == ["probe", "run true", "close", "stop"] },
    { name := "a second request to close does not close the window again"
      run := do
        let twice : FakeWindow :=
          {
            arrivals :=
              [{ input := .opened "fake", arrived := 1, handled := 1 },
                { input := .closeRequested, arrived := 2, handled := 2 },
                { input := .closeRequested, arrived := 3, handled := 3 }] }
        return (← twice.check).calls == ["probe", "run true", "close", "stop"] },
    { name :=
        "an input that arrives after the close was asked for and before the stop is still counted"
      run := do
        let late : FakeWindow :=
          {
            arrivals :=
              [{ input := .opened "fake", arrived := 1, handled := 1 },
                { input := .closeRequested, arrived := 2, handled := 2 },
                { input := pressed "a", arrived := 3, handled := 4 },
                { input := pressed "b", arrived := 5, handled := 6 }] }
        return (← late.check).lines[3]? ==
            some
              "keys: 2 key events reached the Lean loop (2 presses, 0 of them repeats, 0 releases); text: \"ab\"" },
    { name :=
        "the window is run with composition allowed, and with it not allowed when the options say so, which the first line then says"
      run := do
        let allowed ← typed.check
        let refused ← typed.check { composition := false }
        return allowed.calls[1]? == some "run true" && refused.calls[1]? == some "run false" &&
            refused.lines.head? ==
              some
                "window-check: composition off, limit 120 s; the main-thread service is on the process's main thread: yes" },
    { name :=
        "the window line's time is from the clock's reading before the window was run to the instant the window opened"
      run := do
        let slow : FakeWindow :=
          { askedAt := 7000000
            arrivals :=
              [{ input := .opened "fake", arrived := 19300000, handled := 99000000 },
                { input := .closeRequested, arrived := 99000001, handled := 99000002 }] }
        return (← slow.check).lines[1]? ==
            some "window: opened by fake 12.3 ms after it was asked for" },
    { name :=
        "a window that cannot open gives the eight lines of that case, with the reason in the second, and status 1; nothing is closed, and the loop is still stopped"
      run := do
        let checked ← ({ cannotOpen := some "no display" } : FakeWindow).check
        return checked.lines ==
              ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
                  "window: could not open: no display"] ++
                nothingArrived &&
            checked.status == some 1 &&
            checked.calls == ["probe", "run true", "stop"] },
    { name :=
        "a window that runs and never says that it opened is closed by the time limit, and gives the eight lines of a window that could not open, with that reason in the second, and status 1"
      run := do
        let silent : FakeWindow := { arrivals := [], idleAt := some 3000000000 }
        let checked ← silent.check { seconds := 2 }
        return checked.lines ==
              ["window-check: composition on, limit 2 s; the main-thread service is on the process's main thread: yes",
                  "window: could not open: the window ran and did not say that it opened"] ++
                nothingArrived &&
            checked.status == some 1 &&
            checked.calls.eraseReps == ["probe", "run true", "close", "stop"] },
    { name := "what the fake says of the main-thread service is what the first line says"
      run := do
        let checked ← ({ typed with serviceOnMain := false } : FakeWindow).check
        return checked.lines.head? ==
            some
              "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: no" },
    { name :=
        "a window nobody closes is closed by the check once the time limit has passed on the clock, and the report says so"
      run := do
        let idle : FakeWindow :=
          { askedAt := 1000000000
            arrivals := [{ input := .opened "fake", arrived := 1000000001, handled := 1000000002 }]
            idleAt := some 3000000000 }
        let checked ← idle.check { seconds := 2 }
        -- The limit asks again at every look until the run has ended, so
        -- there is one close or several in a row.
        return checked.calls.eraseReps == ["probe", "run true", "close", "stop"] &&
            checked.lines.getLast? == some "ended: the time limit" &&
            checked.status == some 0 },
    { name :=
        "a time limit that has passed before the window's run has begun still ends the run: the close that came too early is forgotten, and the check asks again"
      run := do
        let slow : FakeWindow :=
          { arrivals := [{ input := .opened "fake", arrived := 1, handled := 2 }]
            slowToBegin := true }
        let checked ← slow.check { seconds := 0 }
        return checked.forgotten >= 1 && checked.status == some 0 &&
            checked.lines[1]?.any (·.startsWith "window: opened by fake ") &&
            checked.lines.getLast? == some "ended: the time limit" },
    { name := "a window that is closed before the time limit is not said to have reached it"
      run := do
        let checked ← ({ typed with idleAt := some 1000000 } : FakeWindow).check { seconds := 2 }
        return checked.lines.getLast? == some "ended: the window was closed" }]

/-- The checks of the keyboard check's command line: what its arguments ask
for (`WindowCheck.parse`), and what the check does with them
(`WindowCheck.withArguments`), on the fake window. -/
def windowArgumentChecks : List Check :=
  [{ name := "no arguments ask for composition allowed and a limit of 120 seconds",
     run := pure (WindowCheck.parse [] == some { composition := true, seconds := 120 }) },
    { name := "`--no-ime` asks for composition not allowed, and leaves the limit"
      run :=
        pure (WindowCheck.parse ["--no-ime"] == some { composition := false, seconds := 120 }) },
    { name := "`--seconds <n>` sets the limit, and leaves composition allowed"
      run :=
        pure (WindowCheck.parse ["--seconds", "3"] == some { composition := true, seconds := 3 }) },
    { name := "both options are understood together, in either order"
      run := do
        let both : Option WindowCheck.Options := some { composition := false, seconds := 3 }
        return WindowCheck.parse ["--no-ime", "--seconds", "3"] == both &&
            WindowCheck.parse ["--seconds", "3", "--no-ime"] == both },
    { name :=
        "`--seconds` with nothing after it, or with something that is not a number, is not understood"
      run :=
        pure
          (WindowCheck.parse ["--seconds"] == none &&
            WindowCheck.parse ["--seconds", "x"] == none &&
            WindowCheck.parse ["--no-ime", "--seconds"] == none &&
            WindowCheck.parse ["--seconds", "--no-ime"] == none) },
    { name := "an argument that is not an option is not understood, wherever it is"
      run :=
        pure
          (WindowCheck.parse ["--bogus"] == none && WindowCheck.parse ["3"] == none &&
            WindowCheck.parse ["--no-ime", "--bogus"] == none &&
            WindowCheck.parse ["--seconds", "3", "--bogus"] == none) },
    { name :=
        "with arguments that are not understood, the check says the usage, ends with status 2, and asks nothing of the window"
      run := do
        let checked ← typed.withArguments ["--bogus"]
        return checked.said == [WindowCheck.usage] && checked.status == some 2 &&
            checked.calls.isEmpty &&
            checked.lines.isEmpty },
    { name :=
        "with arguments that are understood, the check says what to do with the window and runs it as they ask: `--no-ime` runs the window with composition not allowed, and `--seconds` is the limit the report gives"
      run := do
        let checked ← typed.withArguments ["--no-ime", "--seconds", "3"]
        return checked.said == [WindowCheck.instructions] &&
            checked.calls == ["probe", "run false", "close", "stop"] &&
            checked.lines.head? ==
              some
                "window-check: composition off, limit 3 s; the main-thread service is on the process's main thread: yes" &&
            checked.status == some 0 },
    { name := "with no arguments, the check runs the window with composition allowed"
      run := do
        let checked ← typed.withArguments []
        return checked.lines == typedReport && checked.calls[1]? == some "run true" &&
            checked.status == some 0 }]

/-- The checks of where the editor's Lean modules are
(`Editor/ModuleLookup.lean`): the bundle's two directories from an executable
in a bundle, no toolchain and `../lib/lean` outside one, and explicit
directories over either. -/
def moduleLookupChecks : List Check :=
  let bundled (bundle : String) : ModuleLookup.Directories :=
    { sysroot := some s!"{bundle}/Contents/Resources/lean/toolchain"
      oleans := s!"{bundle}/Contents/Resources/lean/editor" }
  let installed := "/Applications/Leanmacs.app/Contents/MacOS/editor"
  [{  name :=
        "an executable at <bundle>/Contents/MacOS/<name> finds the toolchain at Contents/Resources/lean/toolchain and its .olean files at Contents/Resources/lean/editor, in a renamed bundle and in one with no .app suffix too"
      run :=
        pure
          (ModuleLookup.resolve installed {} == bundled "/Applications/Leanmacs.app" &&
            ModuleLookup.resolve "/Users/ada/Apps/My Editor.app/Contents/MacOS/editor" {} ==
              bundled "/Users/ada/Apps/My Editor.app" &&
            ModuleLookup.resolve "/tmp/staged/Contents/MacOS/leanmacs" {} ==
              bundled "/tmp/staged") },
    { name :=
        "an executable outside a bundle has no toolchain, and its .olean files are <directory of the executable>/../lib/lean"
      run :=
        let outside (appPath directory : String) : Bool :=
          ModuleLookup.resolve appPath {} ==
            { sysroot := none, oleans := s!"{directory}/../lib/lean" }
        pure
          (outside "/opt/leanmacs/bin/editor" "/opt/leanmacs/bin" &&
            outside "/x/Contents/bin/editor" "/x/Contents/bin" &&
            outside "/x/MacOS/editor" "/x/MacOS" &&
            outside "/x/Contents/MacOS/sub/editor" "/x/Contents/MacOS/sub") },
    { name :=
        "directories given explicitly are used wherever the executable is, and each given alone overrides only its own"
      run :=
        let both : ModuleLookup.Given := { sysroot := some "/s", oleans := some "/o" }
        let given : ModuleLookup.Directories := { sysroot := some "/s", oleans := "/o" }
        pure
          (ModuleLookup.resolve installed both == given &&
            ModuleLookup.resolve "/opt/leanmacs/bin/editor" both == given &&
            ModuleLookup.resolve installed { sysroot := some "/s" } ==
              { bundled "/Applications/Leanmacs.app" with sysroot := some "/s" } &&
            ModuleLookup.resolve installed { oleans := some "/o" } ==
              { bundled "/Applications/Leanmacs.app" with oleans := "/o" } &&
            ModuleLookup.resolve "/opt/leanmacs/bin/editor" { sysroot := some "/s" } ==
              { sysroot := some "/s", oleans := "/opt/leanmacs/bin/../lib/lean" } &&
            ModuleLookup.resolve "/opt/leanmacs/bin/editor" { oleans := some "/o" } ==
              { sysroot := none, oleans := "/o" }) }]

/-- The checks of the headless mode's command line
(`Editor/Headless/CommandLine.lean`): four paths anywhere, two in a bundle,
and what is refused. -/
def headlessCommandLineChecks : List Check :=
  let installed := "/Applications/Leanmacs.app/Contents/MacOS/editor"
  let outside := "/opt/leanmacs/bin/editor"
  let read (appPath : String) (arguments : List String) : Option Headless.Arguments :=
    (Headless.read appPath arguments).toOption
  let refusal (appPath : String) (arguments : List String) : Option String :=
    match Headless.read appPath arguments with
    | .error reason => some reason
    | .ok _ => none
  -- Refused with the empty reason: the usage line alone says why.
  let refused (appPath : String) (arguments : List String) : Bool :=
    refusal appPath arguments == some ""
  let explicit (render : Bool) : Headless.Arguments :=
    { render, sysroot := "/s", oleans := "/o", config := "/c", script := "/t" }
  let bundled (render : Bool) : Headless.Arguments :=
    { render, sysroot := "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain"
      oleans := "/Applications/Leanmacs.app/Contents/Resources/lean/editor", config := "/c"
      script := "/t" }
  [{  name :=
        "four paths are the toolchain, the .olean directory, the config directory and the script, wherever the executable is"
      run :=
        pure
          (read outside ["/s", "/o", "/c", "/t"] == some (explicit false) &&
            read installed ["/s", "/o", "/c", "/t"] == some (explicit false)) },
    { name :=
        "two paths are the config directory and the script, and an executable in a bundle imports from the bundle's two directories"
      run := pure (read installed ["/c", "/t"] == some (bundled false)) },
    { name := "two paths outside a bundle are refused, because there is no toolchain, and say so"
      run :=
        pure
          (refusal outside ["/c", "/t"] == some Headless.noToolchain &&
            refusal outside ["--render", "/c", "/t"] == some Headless.noToolchain) },
    { name := "--render is read before two paths and before four"
      run :=
        pure
          (read installed ["--render", "/c", "/t"] == some (bundled true) &&
            read outside ["--render", "/s", "/o", "/c", "/t"] == some (explicit true)) },
    { name :=
        "no path, one, three and five, and an option it does not know, are refused with no reason beyond the usage line, inside a bundle and outside one"
      run :=
        pure
          ([installed, outside].all fun appPath =>
            refused appPath [] && refused appPath ["/c"] && refused appPath ["/o", "/c", "/t"] &&
              refused appPath ["/x", "/s", "/o", "/c", "/t"] &&
              refused appPath ["--render", "/o", "/c", "/t"] &&
              refused appPath ["--bogus", "/c", "/t"] &&
              refused appPath ["--bogus", "/s", "/o", "/c"] &&
              refused appPath ["--render", "--bogus", "/c"]) }]

/-- The checks of the executable's top-level dispatch
(`Editor/Executable.lean`): which mode a command line selects. -/
def executableModeChecks : List Check :=
  [{  name := "no arguments select the window mode, with an empty command line"
      run := pure (Executable.mode [] == .window []) },
    { name := "demo selects the demonstration"
      run := pure (Executable.mode ["demo"] == .demo) },
    { name :=
        "any command line but demo, headless and window-check is the window mode's, a file or an option alike"
      run :=
        pure
          (Executable.mode ["notes.txt"] == .window ["notes.txt"] &&
            Executable.mode ["--no-ime"] == .window ["--no-ime"] &&
            Executable.mode ["demo", "x"] == .window ["demo", "x"] &&
            Executable.mode ["headless", "/c", "/t"] == .headless ["/c", "/t"] &&
            Executable.mode ["window-check", "--no-ime"] == .windowCheck ["--no-ime"]) },
    { name := "--version alone selects the version, and with anything else is the window mode's"
      run :=
        pure
          (Executable.mode ["--version"] == .version &&
            Executable.mode ["--version", "x"] == .window ["--version", "x"] &&
            Executable.mode ["x", "--version"] == .window ["x", "--version"]) }]

/-- A plist text in the shape lakefile `appInfoPlist` writes, document types
nested above the stamp, with `stamp` spliced in where it writes the three
keys; `extra` goes just before the closing `</dict>`. -/
def versionPlist (stamp : String) (extra : String := "") : String :=
  s!"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
\t<key>CFBundleDocumentTypes</key>
\t<array>
\t\t<dict>
\t\t\t<key>CFBundleTypeName</key>
\t\t\t<string>Text</string>
\t\t\t<key>LSItemContentTypes</key>
\t\t\t<array>
\t\t\t\t<string>public.text</string>
\t\t\t</array>
\t\t</dict>
\t</array>
\t<key>CFBundleExecutable</key>
\t<string>editor</string>
{stamp}\t<key>LSMinimumSystemVersion</key>
\t<string>26.0</string>
\t<key>NSHighResolutionCapable</key>
\t<true/>
{extra}</dict>
</plist>
"

/-- The three keys of a stamp as `appInfoPlist` writes them. -/
def versionStampKeys (version build commit : String) : String :=
  s!"\t<key>CFBundleShortVersionString</key>
\t<string>{version}</string>
\t<key>CFBundleVersion</key>
\t<string>{build}</string>
\t<key>LeanmacsCommit</key>
\t<string>{commit}</string>
"

/-- The checks of `editor --version` (`Editor/Version.lean`): what it prints
for a stamp, a development build and an unreadable plist; the plist reader
on the shape `editorApp` writes, and each text it refuses; and what it
reads, through a fake file read. -/
def versionChecks : List Check :=
  let sha := String.ofList (List.replicate 40 'a')
  let stamp : Version.Stamp := { version := "0.0.1", build := "20010203040506", commit := sha }
  let good := versionPlist (versionStampKeys "0.0.1" "20010203040506" sha)
  let refusal (plist : String) : Option String :=
    match Version.ofInfoPlist plist with
    | .error reason => some reason
    | .ok _ => none
  let names (key : String) (plist : String) : Bool :=
    match refusal plist with
    | some reason => reason.startsWith key
    | none => false
  -- A fake file read: records each path asked, and answers `answer`.
  let fake (answer : Except String String) (path : System.FilePath) :
    StateM (Array System.FilePath) (Except String String) := do
    modify (·.push path)
    pure answer
  [{  name :=
        "a stamped build reports the version, the build ID and the commit on three lines, with status 0"
      run :=
        pure
          (Version.report (.stamped stamp) ==
            (s!"Leanmacs 0.0.1\nbuild 20010203040506\ncommit {sha}", 0)) },
    { name := "a development build says it has no version, build ID or commit, with status 0"
      run :=
        pure
          (Version.report .development ==
            ("Leanmacs, a development build: not run from an app bundle, so it has no version, build ID or commit",
              0)) },
    { name := "an unreadable plist reports its path and the reason, with status 1"
      run :=
        pure
          (Version.report (.unreadable "/x/Leanmacs.app/Contents/Info.plist" "no such file") ==
            ("Leanmacs: /x/Leanmacs.app/Contents/Info.plist: no such file", 1)) },
    { name :=
        "the plist reader takes the stamp from the shape appInfoPlist writes, document types nested above it"
      run := pure ((Version.ofInfoPlist good).toOption == some stamp) },
    { name :=
        "the plist reader refuses a missing LeanmacsCommit, a key given twice, an <integer>, a binary plist and a value with &, each naming the key"
      run :=
        let noCommit :=
          versionPlist
            "\t<key>CFBundleShortVersionString</key>\n\t<string>0.0.1</string>\n\t<key>CFBundleVersion</key>\n\t<string>20010203040506</string>\n"
        let twice :=
          versionPlist (versionStampKeys "0.0.1" "20010203040506" sha)
            "\t<key>CFBundleVersion</key>\n\t<string>20010203040507</string>\n"
        let integer :=
          versionPlist
            (versionStampKeys "0.0.1" "20010203040506" sha |>.replace
              "<string>20010203040506</string>" "<integer>20010203040506</integer>")
        let entity := versionPlist (versionStampKeys "0.0.1&amp;" "20010203040506" sha)
        pure
          (refusal noCommit == some "LeanmacsCommit is missing" &&
            refusal twice == some "CFBundleVersion is given more than once" &&
            refusal integer == some "CFBundleVersion is not a <string>" &&
            names "CFBundleShortVersionString" ("bplist00" ++ good) &&
            names "CFBundleShortVersionString" entity) },
    { name :=
        "in a bundle it reads exactly Contents/Info.plist, once, and returns the stamp; outside one it reads nothing and is a development build"
      run :=
        let (inBundle, asked) :=
          (Version.read "/x/Leanmacs.app/Contents/MacOS/editor" (fake (.ok good))).run #[]
        let (outside, askedOutside) :=
          (Version.read "/x/.lake/build/bin/editor" (fake (.ok good))).run #[]
        pure
          (inBundle == .stamped stamp &&
            asked == #[System.FilePath.mk "/x/Leanmacs.app/Contents/Info.plist"] &&
            outside == .development &&
            askedOutside.isEmpty) },
    { name :=
        "a read that fails, or a plist with no stamp, is unreadable, with the plist's path and the reason"
      run :=
        let failed : Version.Build :=
          (Version.read "/x/Leanmacs.app/Contents/MacOS/editor" (fake (.error "no such file"))).run'
            #[]
        let empty : Version.Build :=
          (Version.read "/x/Leanmacs.app/Contents/MacOS/editor" (fake (.ok (versionPlist "")))).run'
            #[]
        pure
          (failed == .unreadable "/x/Leanmacs.app/Contents/Info.plist" "no such file" &&
            empty ==
              .unreadable "/x/Leanmacs.app/Contents/Info.plist"
                "CFBundleShortVersionString is missing") }]

/-- What the window mode is told of the world by the checks of its command
line: a working directory, both variables a config directory is found by,
and where the executable is. -/
def windowEnvironment : Window.Environment :=
  { workingDirectory := "/work/project", xdgConfigHome := some "/xdg", home := some "/home/ada"
    appPath := "/opt/leanmacs/bin/editor" }

/-- The checks of the window mode's command line (`Editor/Window.lean`): the
file, the options and their defaults, when config is loaded, and what is
refused. -/
def windowOptionChecks : List Check :=
  let parsed (arguments : List String) (environment := windowEnvironment) : Option Window.Options :=
    (Window.parse environment arguments).toOption
  let refused (arguments : List String) : Bool :=
    match Window.parse windowEnvironment arguments with
    | .error message => message.endsWith Window.usage
    | .ok _ => false
  [{  name :=
        "a relative file is resolved against the working directory, and an absolute one is kept as it is"
      run :=
        pure
          ((parsed ["notes.txt"]).map (·.file) == some (some "/work/project/notes.txt") &&
            (parsed ["src/a.lean"]).map (·.file) == some (some "/work/project/src/a.lean") &&
            (parsed ["/tmp/b.txt"]).map (·.file) == some (some "/tmp/b.txt")) },
    { name := "no file parses to options with no file, with every default as with one"
      run :=
        pure
          (parsed [] ==
              some
                { file := none, config := some "/xdg/leanmacs", configGiven := false,
                  sysroot := none, oleans := "/opt/leanmacs/bin/../lib/lean",
                  composition := true } &&
            (parsed ["--no-ime"]).map (·.file) == some none) },
    { name :=
        "a Finder start: no arguments, / as the working directory, HOME set and XDG_CONFIG_HOME unset, in a bundle: no file, config from ~/.config/leanmacs, and the bundle's toolchain and .olean files"
      run :=
        let finder : Window.Environment :=
          { workingDirectory := "/", xdgConfigHome := none, home := some "/Users/ada"
            appPath := "/Applications/Leanmacs.app/Contents/MacOS/editor" }
        pure <|
          match parsed [] finder with
          | none => false
          | some options =>
            options.file == none && options.config == some "/Users/ada/.config/leanmacs" &&
              options.sysroot ==
                some "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain" &&
              options.oleans == "/Applications/Leanmacs.app/Contents/Resources/lean/editor" &&
              options.configPlan true == .load "/Users/ada/.config/leanmacs" },
    { name :=
        "with no option, config is looked for in the directory leanmacs under XDG_CONFIG_HOME, or under HOME's .config when that is unset; no toolchain is given; the editor's .olean files are beside the executable's directory; and an input method may compose"
      run :=
        let unset := { windowEnvironment with xdgConfigHome := none }
        let empty := { windowEnvironment with xdgConfigHome := some "" }
        let neither :=
          { windowEnvironment with
            xdgConfigHome := none, home := none }
        pure
          (parsed ["f"] ==
              some
                { file := some "/work/project/f", config := some "/xdg/leanmacs",
                  configGiven := false, sysroot := none, oleans := "/opt/leanmacs/bin/../lib/lean",
                  composition := true } &&
            (parsed ["f"] unset).bind (·.config) == some "/home/ada/.config/leanmacs" &&
            (parsed ["f"] empty).bind (·.config) == some "/home/ada/.config/leanmacs" &&
            (parsed ["f"] neither).map (·.config) == some none) },
    { name :=
        "--config, --sysroot, --oleans and --no-ime are read, in any order, before or after the file"
      run :=
        let given : Option Window.Options :=
          some
            { file := some "/work/project/f", config := some "/c", configGiven := true,
              sysroot := some "/s"
              oleans := "/o", composition := false }
        pure
          (parsed ["--config", "/c", "--sysroot", "/s", "--oleans", "/o", "--no-ime", "f"] ==
              given &&
            parsed ["--no-ime", "f", "--oleans", "/o", "--sysroot", "/s", "--config", "/c"] ==
              given) },
    { name :=
        "config is loaded from the default directory only when it exists, from a directory given with --config whether it exists or not, and never with no toolchain, which is said"
      run :=
        let plan (arguments : List String) (exists_ : Bool) : Option Window.ConfigPlan :=
          (parsed arguments).map (·.configPlan exists_)
        pure
          (plan ["--sysroot", "/s", "f"] false == some (.skip none) &&
            plan ["--sysroot", "/s", "f"] true == some (.load "/xdg/leanmacs") &&
            plan ["--sysroot", "/s", "--config", "/c", "f"] false == some (.load "/c") &&
            plan ["f"] true == some (.skip (some Window.noToolchain)) &&
            plan ["--config", "/c", "f"] true == some (.skip (some Window.noToolchain)) &&
            (parsed ["--sysroot", "/s", "f"]
                    { windowEnvironment with
                      xdgConfigHome := none, home := none }).map
                (·.configPlan true) ==
              some (.skip none)) },
    { name :=
        "an executable in a bundle, with no --sysroot or --oleans, loads config from the bundle's toolchain and .olean directories, and --sysroot and --oleans still override them there"
      run :=
        let installed :=
          { windowEnvironment with appPath := "/Applications/Leanmacs.app/Contents/MacOS/editor" }
        let directories (arguments : List String) : Option (Option String × String) :=
          (parsed arguments installed).map fun options => (options.sysroot, options.oleans)
        pure
          (directories ["f"] ==
              some
                (some "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain",
                  "/Applications/Leanmacs.app/Contents/Resources/lean/editor") &&
            (parsed ["f"] installed).map (·.configPlan true) == some (.load "/xdg/leanmacs") &&
            directories ["--sysroot", "/s", "--oleans", "/o", "f"] == some (some "/s", "/o")) },
    { name :=
        "two files, an option it does not know and an option with no value are each refused with the usage"
      run :=
        pure
          (refused ["a", "b"] && refused ["--bogus", "f"] && refused ["f", "--bogus"] &&
            refused ["f", "--config"] &&
            refused ["--sysroot"]) },
    { name :=
        "--present-mode with each of wgpu's names, --frame-latency with a number and --report are read; with none of them the renderer decides and nothing is reported"
      run :=
        let read (arguments : List String) :
          Option (Option Window.PresentMode × Option Nat × Bool) :=
          (parsed arguments).map fun options =>
            (options.presentMode, options.frameLatency, options.report)
        pure
          (read ["f"] == some (none, none, false) &&
            read ["--present-mode", "immediate", "f"] == some (some .immediate, none, false) &&
            read ["--present-mode", "fifo", "f"] == some (some .fifo, none, false) &&
            read ["--present-mode", "fifo-relaxed", "f"] == some (some .fifoRelaxed, none, false) &&
            read ["--present-mode", "mailbox", "f"] == some (some .mailbox, none, false) &&
            read ["f", "--frame-latency", "2"] == some (none, some 2, false) &&
            read ["--report", "f"] == some (none, none, true) &&
            read ["--report", "--present-mode", "immediate", "--frame-latency", "2", "f"] ==
              some (some .immediate, some 2, true)) },
    { name :=
        "a present mode wgpu has no name for, and a frame latency that is no number or is 0, are refused with the usage"
      run :=
        pure
          (refused ["--present-mode", "vsync", "f"] && refused ["--frame-latency", "x", "f"] &&
            refused ["--frame-latency", "0", "f"] &&
            refused ["f", "--present-mode"]) }]

/-- A journal entry of the window report's checks: its `present − input`
is `latency` microseconds, and it was presented `at` microseconds after the
window was asked to open. -/
def reportEntry (at_ latency : Nat) : Window.Report.Entry :=
  { inputNs := (at_ - latency) * 1000, presentNs := at_ * 1000 }

/-- The checks of the window mode's report (`Window.Report`): its figures
over journal entries built by hand. -/
def windowReportChecks : List Check :=
  let entries :=
    #[reportEntry 10000 5000, reportEntry 20000 1000, reportEntry 90000 3000,
      reportEntry 100000 2000, reportEntry 110000 4000]
  [{  name :=
        "the report's latencies are each entry's present - input, in microseconds: the median and the 99th percentile by nearest rank, and the largest"
      run :=
        let summary := Window.Report.summary 0 120000000 entries
        pure
          (summary.frames == 5 && summary.median == 3000 && summary.p99 == 5000 &&
            summary.max == 5000 &&
            (Window.Report.summary 0 1 (entries.extract 0 4)).median == 2000 &&
            (Window.Report.summary 0 1 (entries.extract 0 4)).p99 == 5000) },
    { name :=
        "the longest stretch with no entry is the longest of: from the open to the first entry, between two entries, and from the last entry to the close"
      run :=
        pure
          ((Window.Report.summary 0 120000000 entries).longestGap == 70000 &&
            (Window.Report.summary 0 300000000 entries).longestGap == 190000 &&
            (Window.Report.summary 0 120000000 #[reportEntry 100000 1000]).longestGap == 100000) },
    { name :=
        "an empty journal has no frame, latencies of 0, and one stretch from the open to the close"
      run :=
        let summary := Window.Report.summary 5000000 65000000 #[]
        pure
          (summary.frames == 0 && summary.median == 0 && summary.p99 == 0 && summary.max == 0 &&
            summary.longestGap == 60000) }]

end ModelTest
