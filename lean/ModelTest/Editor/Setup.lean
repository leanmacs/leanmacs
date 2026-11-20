import Editor.Command
import Editor.Command.Call
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Completion.Displays
import Editor.Completion.Keys
import Editor.Completion.Later
import Editor.Completion.Style
import Editor.Config.Registry
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.Face
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Floating
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Key.Notation
import Editor.Language
import Editor.Language.IndentUnit
import Editor.Layout
import Editor.Mode
import Editor.ModeLine
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.ProjectMode
import Editor.ProjectMode.Format
import Editor.Role
import Editor.Scene
import Editor.Setup
import Editor.Store
import Editor.TabBar
import Editor.Test.Config
import Editor.Test.Keys
import Editor.Test.Models
import Editor.Text
import Editor.Text.Model
import Editor.Value
import Editor.Window
import Editor.Workspace
import ModelTest.Check

/-!
# Model tests: `Editor/Setup.lean`

The model tests of `Editor/Setup.lean`: `setupChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The message a `setup` was refused with, if it was. -/
def refusal (setup : SetupM Unit) : Option String :=
  match Config.Registrations.ofSetup setup with
  | .error message => some message
  | .ok _ => none

/-- The checks of `setup`: a program over the setup port (`Editor/Setup.lean`),
run against the handler that collects what it registers
(`Editor/Config/Registry.lean`). -/
def setupChecks : List Check :=
  [{  name :=
        "a setup's codecs across a restart are collected in order, by the store's name, version and keep; one that keeps a store twice is refused; a job registered as reported, and one registered as restarted, is collected with its flag, and every other job without either"
      run :=
        pure <|
          let setup : SetupM Unit := do
            counter.declare
            counter.keptAcrossRestart (keep := fun n => n + 1)
            workJob "waited" (fun _ => Work.of (fun _ => pure ()) fun _ => pure ()) (reported :=
                true)
            workJob "watched" fun _ => Work.of (fun _ => pure ()) fun _ => pure ()
            workJob "rewatched" (fun _ => Work.of (fun _ => pure ()) fun _ => pure ()) (restarted :=
                true)
          let twice : SetupM Unit := do
            counter.keptAcrossRestart
            counter.keptAcrossRestart
          match Config.Registrations.ofSetup setup with
          | .ok collected =>
            collected.codecs.map (fun codec => (codec.name, codec.declaration.version)) ==
                #[("counter", 1)] &&
              (collected.codecs.map (·.keep (.nat 4))) == #[some (.nat 5)] &&
              collected.jobs.map (fun job => (job.name, job.reported, job.restarted)) ==
                #[("waited", true, false), ("watched", false, false), ("rewatched", false, true)] &&
              refusal twice == some "the store `counter` is kept across a restart twice"
          | .error _ => false },
    { name :=
        "a setup's at-point sources and uses are collected in order, a mode's or every buffer's; one that defines an at-point source name twice is refused, after the display checks"
      run :=
        pure <|
          let setup : SetupM Unit := do
            defineAtPoint (Completion.AtPoint.silent "one")
            useAtPoint "one"
            useAtPointIn "lean" "two"
            defineAtPoint (Completion.AtPoint.silent "two")
          let twice : SetupM Unit := do
            defineAtPoint (Completion.AtPoint.silent "one")
            defineAtPoint (Completion.AtPoint.silent "one")
          let both : SetupM Unit := do
            defineAtPoint (Completion.AtPoint.silent "one")
            defineAtPoint (Completion.AtPoint.silent "one")
            defineDisplay (Completion.Display.plain "plain")
            defineDisplay (Completion.Display.plain "plain")
          match Config.Registrations.ofSetup setup with
          | .ok collected =>
            collected.atPoints.map (·.name) == #["one", "two"] &&
              collected.atPointUses == #[(none, "one"), (some "lean", "two")] &&
              refusal twice == some (Config.Registrations.atPointTwice "one") &&
              refusal both == some (Config.Registrations.displayTwice "plain")
          | .error _ => false },
    {
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
        "a setup that registers a source's job collects it as a job of its name, which, started with an order, posts what it answers for the order's query as a batch for the order's prompt and source"
      run :=
        let setup : SetupM Unit :=
          sourceJob "echo" fun query deliver => deliver #[.ofText (query.text ++ "?")]
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure <|
            match collected.jobs.find? (·.name == "echo") with
            | none => false
            | some job =>
              let order : Completion.Order :=
                { view := ⟨3⟩, index := 1, generation := 2, query := { text := "w", view := ⟨0⟩ } }
              let (outcome, model) := (job.work order.arguments ()).runModel {}
              (outcome matches .finished _) &&
                model.posted ==
                  #[{ command := Completion.candidatesCommand
                      arguments := Completion.batchArguments ⟨3⟩ 1 2 #[.ofText "w?"] }] },
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
                #[(strokes "C-x C-s", "save"), (strokes "<Escape>", "quit"),
                  (strokes "A", "save")] &&
              collected.bindings.all (·.states.isEmpty) &&
              collected.commands.isEmpty) },
    { name :=
        "a setup that binds a key string written with <leader> and <localleader> collects its strokes, placeholders in place, and the states a binding is given, none unless it says"
      run :=
        let setup : SetupM Unit := do
          bindKey "<leader> f f" "find"
          bindKey "<localleader> x" "run" (states := [⟨"insert"⟩, ⟨"visual"⟩])
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.bindings ==
              #[{ keys := [.leader, .key (charKey "f"), .key (charKey "f")], command := "find" },
                { keys := [.localLeader, .key (charKey "x")], command := "run"
                  states := ["insert", "visual"] }]) },
    { name :=
        "a setup that binds a key string in a prompt category collects the binding with that category, and one that names none with none"
      run :=
        let setup : SetupM Unit := do
          bindKey "C-o e" "x" (category := some "workspace-file")
          bindKey "C-o f" "y"
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.bindings ==
              #[{ keys := strokes "C-o e", command := "x", category := some "workspace-file" },
                { keys := strokes "C-o f", command := "y" }]) },
    { name :=
        "a setup that sets the leader and the localleader collects them, the localleader as strokes over the leader, and one that sets neither has none"
      run :=
        let setup : SetupM Unit := do
          leaderKey "C-x"
          localLeaderKey "<leader> m"
        match Config.Registrations.ofSetup setup, Config.Registrations.ofSetup (pure ()) with
        | .ok collected, .ok plain =>
          pure
            (collected.leader == some (keys "C-x") &&
              collected.localLeader == some [.leader, .key (charKey "m")] &&
              plain.leader == none &&
              plain.localLeader == none)
        | _, _ => pure false },
    { name :=
        "a setup that sets the leader twice, or the localleader twice, is refused, naming which"
      run :=
        let leaders : SetupM Unit := do
          leaderKey "C-x"
          leaderKey "C-c"
        let locals : SetupM Unit := do
          localLeaderKey "C-l"
          localLeaderKey "<leader> m"
        pure
          (refusal leaders == some Config.Registrations.leaderTwice &&
            refusal locals == some Config.Registrations.localLeaderTwice) },
    { name :=
        "a setup that sets the leader to no keys, or writes it with a placeholder, is refused; one that sets the localleader to no keys, or writes it with <localleader>, is refused, and <leader> in it is not; a key string that is not keys is refused with the parser's reason"
      run :=
        let parsed : Option String :=
          match Key.parseStrokes "C-<leader>" with
          | .error message => some message
          | .ok _ => none
        pure
          (refusal (leaderKey "") == some leaderNoKeys &&
            refusal (leaderKey "<leader> x") == some leaderWrittenWithLeader &&
            refusal (leaderKey "<localleader>") == some leaderWrittenWithLeader &&
            refusal (localLeaderKey " ") == some localLeaderNoKeys &&
            refusal (localLeaderKey "<localleader>") == some localLeaderWrittenWithItself &&
            refusal (localLeaderKey "<leader>") == none &&
            parsed.isSome &&
            refusal (bindKey "C-<leader>" "find") == parsed &&
            refusal (leaderKey "C-<leader>") == parsed &&
            refusal (localLeaderKey "C-<leader>") == parsed) },
    { name :=
        "a setup that binds one key string with <leader> twice is refused, naming the keys as written; the same keys bound once plain and once for some states are bound twice too"
      run :=
        let twice : SetupM Unit := do
          bindKey "<leader> f" "find"
          bindKey "<leader> f" "find-again"
        let stated : SetupM Unit := do
          bindKey "C-a" "start"
          bindKey "C-a" "start" (states := [⟨"insert"⟩])
        pure
          (refusal twice == some "the keys `<leader> f` are bound twice" &&
            refusal stated == some "the keys `C-a` are bound twice") },
    { name :=
        "the order of a setup's calls does not matter: a binding with <leader> made before the leader is set collects as one made after it"
      run :=
        let before : SetupM Unit := do
          bindKey "<leader> f" "find"
          leaderKey "C-x"
        let after : SetupM Unit := do
          leaderKey "C-x"
          bindKey "<leader> f" "find"
        match Config.Registrations.ofSetup before, Config.Registrations.ofSetup after with
        | .ok first, .ok second =>
          pure
            (first.bindings == second.bindings && first.leader == second.leader &&
              first.leader == some (keys "C-x"))
        | _, _ => pure false },
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
        "a setup's completion sources are collected in the order it defined them; one that defines two sources under one name is refused with exactly the reason that names it"
      run :=
        let setup : SetupM Unit := do
          defineSource (.ofTexts "picks" "pick" #["wq"])
          command "greet" (makes "1")
          defineSource (.ofTexts "others" "other" #[])
        let twice : SetupM Unit := do
          defineSource (.ofTexts "picks" "pick" #["wq"])
          defineSource (.ofTexts "picks" "other" #["w"])
        pure
          ((match Config.Registrations.ofSetup setup with
            | .ok collected =>
              collected.sources.map (fun source => (source.name, source.category)) ==
                  #[("picks", "pick"), ("others", "other")] &&
                collected.commands.map (·.name) == #["greet"]
            | .error _ => false) &&
            refusal twice == some (Config.Registrations.sourceTwice "picks") &&
            Config.Registrations.sourceTwice "picks" ==
              "the completion source `picks` is registered twice") },
    { name :=
        "a setup's completion styles and its choices of them are collected in the order it made them; one that defines two styles under one name, or chooses the style of one category or the default twice, is refused with exactly the reason that names it"
      run :=
        let mine : Completion.Style :=
          .keeping "mine" fun text candidate => candidate.startsWith text
        let setup : SetupM Unit := do
          defineStyle mine
          useStyleFor "pick" "orderless"
          useStyle "mine"
          useStyleFor "other" "mine"
        let twice : SetupM Unit := do
          defineStyle mine
          defineStyle (.keeping "mine" fun _ _ => true)
        let pickTwice : SetupM Unit := do
          useStyleFor "pick" "a"
          useStyleFor "pick" "b"
        let defaultTwice : SetupM Unit := do
          useStyle "a"
          useStyle "b"
        let apart : SetupM Unit := do
          useStyleFor "pick" "a"
          useStyle "a"
        pure
          ((match Config.Registrations.ofSetup setup with
            | .ok collected =>
              collected.styles.map (·.name) == #["mine"] &&
                collected.styleChoices ==
                  #[(some "pick", "orderless"), (none, "mine"), (some "other", "mine")]
            | .error _ => false) &&
            refusal twice == some (Config.Registrations.styleTwice "mine") &&
            Config.Registrations.styleTwice "mine" ==
              "the completion style `mine` is registered twice" &&
            refusal pickTwice == some (Config.Registrations.styleChosenTwice (some "pick")) &&
            refusal defaultTwice == some (Config.Registrations.styleChosenTwice none) &&
            Config.Registrations.styleChosenTwice (some "pick") ==
              "the completion style of `pick` is chosen twice" &&
            Config.Registrations.styleChosenTwice none ==
              "the default completion style is chosen twice" &&
            refusal apart == none) },
    { name :=
        "a setup's completion displays and its choices of them are collected in the order it made them; one that defines two displays under one name, or chooses the display of one category or the default twice, is refused with exactly the reason that names it"
      run :=
        let setup : SetupM Unit := do
          defineDisplay (Completion.Display.plain "plain")
          useDisplayFor "pick" "plain"
          useDisplay "minibuffer"
          defineDisplay (Completion.Displays.minibuffer (rows := 3))
        let twice : SetupM Unit := do
          defineDisplay (Completion.Display.plain "plain")
          defineDisplay (Completion.Display.plain "plain")
        let pickTwice : SetupM Unit := do
          useDisplayFor "pick" "a"
          useDisplayFor "pick" "b"
        let defaultTwice : SetupM Unit := do
          useDisplay "a"
          useDisplay "b"
        let apart : SetupM Unit := do
          useDisplayFor "pick" "a"
          useDisplay "a"
        pure
          ((match Config.Registrations.ofSetup setup with
            | .ok collected =>
              collected.displays.map (·.name) == #["plain", "minibuffer"] &&
                collected.displayChoices == #[(some "pick", "plain"), (none, "minibuffer")]
            | .error _ => false) &&
            refusal twice == some (Config.Registrations.displayTwice "plain") &&
            Config.Registrations.displayTwice "plain" ==
              "the completion display `plain` is registered twice" &&
            refusal pickTwice == some (Config.Registrations.displayChosenTwice (some "pick")) &&
            refusal defaultTwice == some (Config.Registrations.displayChosenTwice none) &&
            Config.Registrations.displayChosenTwice (some "pick") ==
              "the completion display of `pick` is chosen twice" &&
            Config.Registrations.displayChosenTwice none ==
              "the default completion display is chosen twice" &&
            refusal apart == none) },
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
        "a setup's key hint delay is collected as milliseconds, 0 or .never; a setup that sets none has none; one longer than a minute is refused with keyHintDelayTooLong, and one that sets it twice is refused with a message that says so"
      run :=
        let collected (setup : SetupM Unit) : Option (Option Completion.Keys.Delay) :=
          (Config.Registrations.ofSetup setup).toOption.map (·.keyHintDelay)
        let twice : SetupM Unit := do
          keyHintDelay 250
          keyHintDelay 0
        pure
          (collected (keyHintDelay 250) == some (some (.after 250)) &&
            collected (keyHintDelay 0) == some (some (.after 0)) &&
            collected (keyHintDelay .never) == some (some .never) &&
            collected (keyHintDelay 60000) == some (some (.after 60000)) &&
            collected (command "x" (makes "1")) == some none &&
            refusal (keyHintDelay 60001) == some (Completion.Keys.keyHintDelayTooLong 60001) &&
            refusal twice == some Config.Registrations.keyHintDelayTwice &&
            Config.Registrations.keyHintDelayTwice == "the key hint delay is set twice") },
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
            refusal twice == some (Config.Registrations.workspaceTwice "/r/tools")) },
    { name :=
        "a setup's workspace listers, for a root and for a project, are collected in the order it declared them, with their arguments and whether their records end in a NUL; a setup that declares none collects none"
      run :=
        let setup : SetupM Unit := do
          workspaceLister "/r" "fd" #["--type", "f", "-0"] (nul := true)
          projectLister (.remote "github.com/o/r") "rg" #["--files"]
          workspaceLister "/w" "/opt/bin/list"
        pure
          (match Config.Registrations.ofSetup setup,
            Config.Registrations.ofSetup (command "first" (makes "1")) with
          | .ok collected, .ok bare =>
            collected.workspaceListers ==
                #[{ scope := .root "/r", program := "fd", arguments := #["--type", "f", "-0"]
                    nul := true },
                  { scope := .project (.remote "github.com/o/r"), program := "rg"
                    arguments := #["--files"] },
                  { scope := .root "/w", program := "/opt/bin/list" }] &&
              bare.workspaceListers.isEmpty
          | _, _ => false) },
    { name :=
        "a setup that declares a lister for a root that is not absolute, one whose program names a relative path, or a lister for one root or one project twice, is refused with a message that says so"
      run :=
        let rootTwice : SetupM Unit := do
          workspaceLister "/r" "fd"
          workspaceLister "/r/" "rg" #["--files"]
        let projectTwice : SetupM Unit := do
          projectLister (.remote "github.com/o/r") "fd"
          projectLister (.remote "github.com/o/r") "rg"
        let both : SetupM Unit := do
          workspaceLister "/r" "fd"
          projectLister (.root "/r") "fd"
        pure
          (refusal (workspaceLister "r" "fd") == some (relativeWorkspace "r") &&
            refusal (workspaceLister "/r" "bin/list") == some (relativeLister "bin/list") &&
            refusal (projectLister (.remote "github.com/o/r") "./list") ==
              some (relativeLister "./list") &&
            (relativeLister "bin/list").startsWith
              "a workspace lister's program must be a bare name or an absolute path: bin/list" &&
            refusal rootTwice == some (Config.Registrations.workspaceListerTwice (.root "/r")) &&
            refusal projectTwice ==
              some
                (Config.Registrations.workspaceListerTwice (.project (.remote "github.com/o/r"))) &&
            refusal both == none) },
    { name :=
        "a setup that registers a job as its work collects it under its name beside the others, and the job is the work it was given, applied to the arguments it is started with"
      run :=
        let work (arguments : List Argument) : Work :=
          Work.of (fun _ => pure (arguments.map argumentText)) fun texts =>
            makes (" ".intercalate texts)
        let setup : SetupM Unit := do
          job "fixed" (fun _ => pure "x") makes
          workJob "said" work
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          let started (arguments : List Argument) :=
            (collected.jobs.find? (·.name == "said")).map fun job => worked (job.work arguments)
          pure
            (collected.jobs.map (·.name) == #["fixed", "said"] && collected.commands.isEmpty &&
              started [.str "a", .nat 2] == some (.finished #["a 2"]) &&
              started [] == some (.finished #[""])) },
    { name :=
        "a setup that binds an ex name with fixed arguments collects the binding with them, none unless it says, and `w!` is taken"
      run :=
        let setup : SetupM Unit := do
          exCommand "w" "write"
          exCommand "w!" "write" (arguments := [.bool true])
          exCommand "e!" "edit" (takes := .text) (arguments := [.bool true])
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.ex ==
              #[{ name := "w", command := "write" },
                { name := "w!", command := "write", arguments := [.bool true] },
                { name := "e!", command := "edit", takes := .text, arguments := [.bool true] }]) },
    { name :=
        "a setup that binds keys given as values collects the binding the same keys written as a key string make, with its states, description and category, and one that binds no keys is refused"
      run :=
        let written : SetupM Unit := do
          bindKey "C-x C-d" "escape" (states := [⟨"insert"⟩]) (desc := "Step out") (category :=
              some "workspace-file")
          bindKey "s-q" "quit"
        let valued : SetupM Unit := do
          bindKeys (keys "C-x C-d") "escape" (states := [⟨"insert"⟩]) (desc := "Step out")
              (category := some "workspace-file")
          bindKeys [charKey "q" { superKey := true }] "quit"
        match Config.Registrations.ofSetup written, Config.Registrations.ofSetup valued with
        | .ok written, .ok valued =>
          pure
            (valued.bindings == written.bindings && valued.bindings.size == 2 &&
              valued.commands.isEmpty &&
              refusal (bindKeys [] "save") == some (boundToNoKeys "save"))
        | _, _ => pure false },
    { name :=
        "a setup that defines menus collects each submenu, in order, and registers no command; one that defines a title twice is refused with a message that names it"
      run :=
        let file : Submenu := { title := "File", items := #[.item "Open…" none (.command "open")] }
        let window : Submenu := { title := "Window", role := some .window }
        let setup : SetupM Unit := do
          defineMenu file
          defineMenu window
        let twice : SetupM Unit := do
          defineMenu file
          defineMenu window
          defineMenu { title := "File" }
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.menus == #[file, window] && collected.commands.isEmpty &&
              refusal twice == some (Config.Registrations.menuTwice "File")) }]

/-- The checks of what a `setup` says for the key hints: a binding's
description (`bindKey`'s `desc`) and a prefix's name (`prefixName`). -/
def setupHintChecks : List Check :=
  [{  name :=
        "a setup that binds a key with a description collects the description, and one without collects none"
      run :=
        let setup : SetupM Unit := do
          bindKey "<leader> f f" "find" (desc := "Find file")
          bindKey "<leader> f g" "grep"
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.bindings.map (·.desc) == #[some "Find file", none] &&
              collected.bindings.map (·.keys) ==
                #[strokes "<leader> f f", strokes "<leader> f g"]) },
    { name :=
        "a setup that names a prefix collects its keys as written, placeholders in place, and its name"
      run :=
        match Config.Registrations.ofSetup (prefixName "<leader> f" "file") with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.prefixNames ==
              #[{ keys := [.leader, .key (charKey "f")], name := "file" }]) },
    { name :=
        "a setup that names a prefix of no keys is refused, one that is not keys with the parser's reason, and one that names one prefix twice as written is refused, naming the prefix"
      run :=
        let parsed : Option String :=
          match Key.parseStrokes "C-<leader>" with
          | .error message => some message
          | .ok _ => none
        let twice : SetupM Unit := do
          prefixName "<leader> f" "file"
          prefixName "<leader> f" "files"
        pure
          (refusal (prefixName "" "x") == some (prefixNamedNoKeys "x") && parsed.isSome &&
            refusal (prefixName "C-<leader>" "x") == parsed &&
            refusal twice == some (Config.Registrations.prefixNamedTwice (strokes "<leader> f"))) }]

end ModelTest
