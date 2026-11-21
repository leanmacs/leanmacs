import ConfigTest.Check
import ConfigTest.Support.Candidates
import ConfigTest.Support.Configs
import ConfigTest.Support.Keys
import ConfigTest.Support.Lines
import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Completion.Later
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Display
import Editor.Event
import Editor.Event.Queue
import Editor.Face
import Editor.Fuzzy
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.Invocation
import Editor.Job
import Editor.Job.Fake
import Editor.Loop
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Linked.Host
import Editor.Test.Linked.Listings
import Editor.Test.Minibuffer
import Editor.Text
import Editor.Themes.Compiled

/-!
# Config tests: `Editor/Minibuffer.lean`

The tests of prompts through the headless host: `promptChecks`, the core's
prompts answered through the kit's minibuffer (`Editor/Test/Minibuffer.lean`),
so that none depends on the minibuffer that ships, the default package
`minibuffer` (`packages/minibuffer/`), whose own tests pin it
(`MinibufferTest.promptModeChecks`). The module keeps the name it had while
the minibuffer was the core's `Editor/Minibuffer.lean`. The root module
`ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- What compiled code hands the hosts of the prompt checks that load no
config: the minibuffer's commands and its mode, and commands written here.

- `ask` asks `Name: ` with the initial value `Ada` and the continuation
  `greet`.
- `greet` is given its call: it inserts its first argument at the cursor of
  the window it is called with and says `hello ` and that argument in the
  echo area.
- `other`, on `C-c o`, says `other`.
- `rest-and-ask` starts the job `nap` of `nappingCompiled`, whose command
  inserts `napped` in view 0, and then asks as `ask` does. -/
def promptCompiled : Compiled :=
  let asks : EditorM Unit := discard <| prompt "Name: " { command := "greet" } "Ada"
  { minibufferCompiled with
    commands :=
      Test.Minibuffer.package.registered.commands ++
        #[{ name := "ask", action := .plain asks },
          { name := "greet"
            action :=
              .call fun call => do
                let name :=
                  match call.arguments with
                  | .str name :: _ => name
                  | _ => "nobody"
                call.target.insertAtSelections name
                message s!"hello {name}" },
          { name := "other", action := .plain (message "other") },
          { name := "rest-and-ask"
            action :=
              .plain do
                discard <| startJob "nap"
                asks }]
    jobs := nappingCompiled.jobs
    bindings := #[bound "C-c o" "other"] }

/-- A config whose `setup` registers `greet` as a command that is given its
call, which says `label` and its first argument in the echo area, and
`ask`, which asks `Name: ` with the initial value `Ada` and the continuation
`greet`. -/
def greetWithText (label : String) : String :=
  "def setup : SetupM Unit := do
  commandWith \"greet\" fun call =>
    match call.arguments with
    | .str name :: _ => message s!\"" ++
    label ++
    " {name}\"
    | _ => message \"" ++
    label ++
    "\"
  command \"ask\" (discard <| prompt \"Name: \" { command := \"greet\" } \"Ada\")
"

/-- A config whose `setup` registers `ask` as in `greetWithText`, and no
`greet`. -/
def askOnlyText : String :=
  "def setup : SetupM Unit := do
  command \"ask\" (discard <| prompt \"Name: \" { command := \"greet\" } \"Ada\")
"

/-- A config with a store of one number and three commands: `bump`, over the
store, adds one; `bump-accept`, over the store, accepts the open prompt and
adds one; and `ask` asks `Name: ` with the continuation `bump`. -/
def bumpAcceptText : String :=
  "def counter : Store Nat :=
  { name := \"counter\", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

def setup : SetupM Unit := do
  counter.declare
  counter.command \"bump\" fun n => pure (n + 1)
  counter.command \"bump-accept\" fun n => do
    discard acceptPrompt
    pure (n + 1)
  command \"ask\" (discard <| prompt \"Name: \" { command := \"bump\" })
"

/-- A config whose `setup` registers `pick`, which asks `Pick: ` with the
completion source registered under `picks`, by name, and, when `defines`,
that source: `wq`, `edit` and `w`. -/
def sourceText (defines : Bool) : String :=
  let source := "  defineSource (.ofTexts \"picks\" \"pick\" #[\"wq\", \"edit\", \"w\"])\n"
  "def setup : SetupM Unit := do\n" ++ (if defines then source else "") ++
    "  command \"pick\" (discard <| prompt \"Pick: \" { command := \"picked\" }\n" ++
    "    (sources := [.named \"picks\"]))\n"

/-- A config whose `setup` registers `pick-theme`, which asks `Theme: ` with
the completion source registered under `themes`, by name, one the
executable's hosts ship (`Themes.source`), and, when `overrides`, a source
of config's own under that name, whose one candidate is `mine`. -/
def shippedSourceText (overrides : Bool) : String :=
  let source := "  defineSource (.ofTexts \"themes\" \"theme\" #[\"mine\"])\n"
  "def setup : SetupM Unit := do\n" ++ (if overrides then source else "") ++
    "  command \"pick-theme\" (discard <| prompt \"Theme: \" { command := \"picked\" }\n" ++
    "    (sources := [.named \"themes\"]))\n"

/-- A config whose `setup` makes the choices of completion style `choices`
(lines of `setup`, each indented) and registers two commands, `pick` and
`other`, that ask `Pick: ` with a source given as a value, of the category
`pick` and of `other`, each over `wq`, `edit`, `rewrite` and `w`. -/
def styleText (choices : List String) : String :=
  let asks (command category : String) : String :=
    s!"  command \"{command}\" (discard <| prompt \"Pick: \" \{ command := \"picked\" }\n" ++
      s!"    (sources := [.given (.ofTexts \"{command}s\" \"{category}\" " ++
      "#[\"wq\", \"edit\", \"rewrite\", \"w\"])]))\n"
  "def setup : SetupM Unit := do\n" ++ String.join (choices.map (s!"  {·}\n")) ++
    asks "pick" "pick" ++
    asks "other" "other"

/-- A compiled command of the checks of a category's sources, `pick-buffer`,
the stand-in for a prompt over the buffers such as `switch-buffer`'s: it
asks `Buffer: ` for the category `buffer`, with a source called `buffers`
of that category as its default, which lists `alpha`, `beta` and the
scratch buffer's name, in that order. -/
def pickBuffer : Config.Registration :=
  { name := "pick-buffer"
    action :=
      .call fun _ => do
        discard <|
            prompt "Buffer: " { command := "picked" } (sources :=
              [.category "buffer"
                  [.ofTexts "buffers" "buffer" #["alpha", "beta", EditorState.scratchName]]]) }

/-- A config whose `setup` chooses the hosts' style `parts` for the category
`buffer`, so `pick-buffer` lists its candidates in their own order, and
registers the sources `defines` (lines of `setup`, each indented). -/
def bufferStyleText (defines : List String) : String :=
  "def setup : SetupM Unit := do\n  useStyleFor \"buffer\" \"parts\"\n" ++
    String.join (defines.map (s!"  {·}\n"))

/-- What compiled code hands the hosts of the checks of a source that
answers later: the minibuffer's commands and its mode; `ask-later`, which
asks `Pick: ` with a source that answers later from the job `later-pick`;
and that job, which delivers `wq` and `edit`, sleeps 10 ms on the stage's
clock, and delivers `rewrite` and `w`. -/
def laterCompiled : Compiled :=
  { minibufferCompiled with
    commands :=
      Test.Minibuffer.package.registered.commands ++
        #[{ name := "ask-later"
            action :=
              .plain
                (discard <|
                  prompt "Pick: " { command := "picked" } ""
                    [.given (.answeringLater "later" "pick" "later-pick")]) }]
    jobs :=
      #[{ name := "later-pick"
          work :=
            Completion.answering fun _ deliver => do
              deliver #[.ofText "wq", .ofText "edit"]
              sleep 10
              deliver #[.ofText "rewrite", .ofText "w"] }] }

/-- What compiled code hands the hosts of the checks of long prompts: the
minibuffer's commands and its mode, and `ask-many`, which asks `Pick: ` with
a source given as a value over `manyPaths count`. -/
def manyCompiled (count : Nat) : Compiled :=
  { minibufferCompiled with
    commands :=
      Test.Minibuffer.package.registered.commands ++
        #[{ name := "ask-many"
            action :=
              .plain
                (discard <|
                  prompt "Pick: " { command := "picked" } ""
                    [.given (.ofTexts "many" "pick" (manyPaths count))]) }] }

/-- The candidates `ask-annotated` asks among: `alpha`, annotated `one`,
`palace`, annotated `two`, and `zz`, with no annotation. -/
def annotatedCandidates : Array Completion.Candidate :=
  #[{ text := "alpha", annotation := some "one" }, { text := "palace", annotation := some "two" },
    .ofText "zz"]

/-- What compiled code hands the hosts of the check of annotations: the
minibuffer's commands and its mode, and `ask-annotated`, which asks
`Pick: ` with a source given as a value over `annotatedCandidates`. -/
def annotatedCompiled : Compiled :=
  { minibufferCompiled with
    commands :=
      Test.Minibuffer.package.registered.commands ++
        #[{ name := "ask-annotated"
            action :=
              .plain
                (discard <|
                  prompt "Pick: " { command := "picked" } ""
                    [.given (.fixed "annotated" "pick" annotatedCandidates)]) }] }

/-- The candidates the prompt of `rowsText` asks among: five. -/
def fiveTexts : Array String :=
  #["wq", "edit", "rewrite", "w", "we"]

/-- A config whose `setup` defines a display of its own under the hosts'
display's name, `rows`, in its place: the first three candidates, each a
row in `test.row`, or `test.chosen` for the chosen one; and `pick`, which
asks `Pick: ` with a source given as a value over `fiveTexts`. -/
def rowsText : String :=
  "def three : Completion.Display :=\n" ++ "  { name := \"rows\"\n" ++
    "    sheet := fun showing =>\n" ++
    "      { rows := (showing.listed.extract 0 3).mapIdx fun index listed =>\n" ++
    "          { text := listed.text\n" ++
    "            decorations := #[{ start := 0, stop := listed.text.utf8ByteSize\n" ++
    "                               face := if showing.chosen == some index then ⟨\"test.chosen\"⟩ else ⟨\"test.row\"⟩ }] } } }\n\n" ++
    "def setup : SetupM Unit := do\n" ++
    "  defineDisplay three\n" ++
    "  command \"pick\" (discard <| prompt \"Pick: \" { command := \"picked\" }\n" ++
    s!"    (sources := [.given (.ofTexts \"picks\" \"pick\" #[{", ".intercalate (fiveTexts.toList.map (·.quote))}])]))\n"

/-- The id of the focused view of `lines`, a printed scene. -/
def focusedId (lines : Array String) : Option Nat := do
  let line ← lines.find? (·.startsWith "scene ")
  let after ← (line.splitOn "focused ")[1]?
  (after.splitOn ",")[0]?.bind (·.toNat?)

/-- The library's matcher, held: each request waits until `gate` is
resolved, and is then answered by the library (`Fuzzy.real`). What a check
gives a host's jobs to hold a match in flight. -/
def heldMatcher (gate : IO.Promise Unit) : FuzzyHandler := fun request => do
  discard <| IO.wait gate.result?
  Fuzzy.real request

/-- The ids of the match jobs the host printed `job <id> completion-match:
<what>` of, in order. -/
def matchJobs (lines : Array String) (what : String) : Array String :=
  lines.filterMap fun line =>
    match line.splitOn " " with
    | ["job", id, label, said] =>
      if label == s!"{Loop.matchLabel}:" && said == what then some id else none
    | _ => none

/-- A config whose `setup` defines the style `slow`, which asks the matcher
and then keeps the candidates that hold the text, in their order, and
chooses `chosen` as the default style. -/
def slowStyleText (chosen : String) : String :=
  "def slow : Completion.Style :=
  { name := \"slow\"
    hits := fun text candidates => do
      discard <| Fuzzy.rank text candidates
      (Completion.Style.keeping \"kept\" fun text candidate =>
          text.isEmpty || (candidate.splitOn text).length > 1).hits text candidates }

def setup : SetupM Unit := do
  defineStyle slow
  useStyle " ++
    chosen.quote ++
    "
"

/-- A config whose `setup` registers a source's job `echo`, which answers
the text it is asked with, `!` after it; a source `echo` of the category
`pick` that it answers, asked again 20 ms after the text changes; and
`pick`, which asks `Pick: ` with that source by name. -/
def echoSourceText : String :=
  "def setup : SetupM Unit := do
  sourceJob \"echo\" fun query deliver => deliver #[.ofText (query.text ++ \"!\")]
  defineSource (.answeringLater \"echo\" \"pick\" \"echo\" (reask := .afterPause 20))
  command \"pick\" (discard <| prompt \"Pick: \" { command := \"picked\" }
    (sources := [.named \"echo\"]))
"

/-- The checks of prompts through the headless host (`Editor/Headless.lean`),
on the real queue, the real text binding and the real elaborator, with the
test scheme: the host is handed the kit's minibuffer's commands and its
mode (`Test.Minibuffer.package`, `Editor/Test/Minibuffer.lean`), and runs the answer's command of an
accepted prompt before its next event. The accept key and the cancel key
are the test scheme's keys for the roles the minibuffer's mode fills, so no
check names a scheme's key. -/
def promptChecks (context : Context) : List Check :=
  [{  name :=
        "a command asks for a prompt and a text is committed: the scene has the window's view and the minibuffer's, whose line holds the initial value and the committed text and whose status line is the prompt text, the minibuffer's view is the focused one, and show lists the minibuffer's text; after the accept key the echo area is the continuation's with the answer, which it inserted in the asking window, there is one view, with the focus, and the minibuffer's text is listed no more"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "ask"]
            unless ← Event.post (.commit "!") do
              return false
            let asking ← session.sceneLines
            let listed ← session.shown
            session.pressKeys acceptKeys
            let accepted ← session.sceneLines
            let after ← session.shown
            return !acceptKeys.isEmpty && (asking[0]?.map (focuses · 1)) == some true &&
                asking.extract 1 ==
                  #[viewLine "" 0, statusOf, minibufferLine "Ada!" 4, promptStatus] &&
                listed.contains "text 1: \"Ada!\"" &&
                (accepted[0]?.map fun line =>
                    focuses line 0 &&
                      (line.splitOn s!", echo {"hello Ada!".quote}, ").length == 2) ==
                  some true &&
                accepted.extract 1 ==
                  #[viewLine "Ada!" 4, statusOf (modified := true) (cursor := ⟨0, 4⟩)] &&
                !after.any (·.startsWith "text 1: ") &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          promptCompiled },
    { name :=
        "the cancel key in place of the accept key: the continuation's command does not run, the echo area is empty, there is one view, the window's, as it was and with the focus, and the minibuffer's text is listed no more; the scene published after that one has an empty echo area too, so the library refused neither the release of the minibuffer's text nor, after it, that of the snapshot the last scene named"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "ask"]
            unless ← Event.post (.commit "!") do
              return false
            session.pressKeys cancelKeys
            let cancelled ← session.sceneLines
            -- The scene request was followed by a scene of its own: a
            -- release the cancel's publish was refused would be in its
            -- echo area.
            let later ← session.sceneLines
            let after ← session.shown
            let quiet (line : String) : Bool :=
              focuses line 0 && (line.splitOn s!", echo {"".quote}, ").length == 2
            return !cancelKeys.isEmpty && cancelKeys != acceptKeys &&
                cancelled[0]?.map quiet == some true &&
                later[0]?.map quiet == some true &&
                later.extract 1 == cancelled.extract 1 &&
                cancelled.extract 1 == #[viewLine "" 0, statusOf] &&
                !after.any (·.startsWith "text 1: ") &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          promptCompiled },
    { name :=
        "a job completes while a prompt is open, on the fake clock: once the clock lets it go the host prints that its command ran, the window shows what that command inserted, and the scene still has the minibuffer's view, with the focus; the accept key afterwards runs the continuation's command"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "rest-and-ask"]
            unless ← eventually (return (← session.clock.waiting) == 1) do
              return false
            let before ← session.output.get
            session.clock.advance 10
            let joined ← session.host.join patience
            let delivered := (← session.output.get).extract before.size
            let waiting ← session.sceneLines
            session.pressKeys acceptKeys
            let (echo, views) ← session.scene
            return before == #["run rest-and-ask: ok", "job 1 nap: started"] &&
                joined == .settled &&
                delivered == #["job 1 nap: ok"] &&
                (waiting[0]?.map (focuses · 1)) == some true &&
                waiting.extract 1 ==
                  #[viewLine "napped" 6, statusOf (modified := true) (cursor := ⟨0, 6⟩),
                    minibufferLine "Ada" 3, promptStatus] &&
                echo == "hello Ada".quote &&
                views == #[viewLine "nappedAda" 9])
          promptCompiled },
    { name :=
        "the continuation is looked up when the answer arrives: config registers it as a command that is given its call, a prompt is asked for, config is reloaded with another command of the name, and the accept key runs the new one with the answer; asked for again and reloaded with a config that registers none, the accept key leaves no such command in the echo area, by the continuation's name, and the prompt closed"
      run :=
        withHost context [("init.lean", greetWithText "one")]
          (fun session => do
            session.ask [.reload]
            session.ask [.run "ask"]
            session.write "init.lean" (greetWithText "two")
            session.ask [.reload]
            let asking ← session.scene
            session.pressKeys acceptKeys
            let renamed ← session.scene
            session.ask [.run "ask"]
            session.write "init.lean" askOnlyText
            session.ask [.reload]
            session.pressKeys acceptKeys
            let dropped ← session.scene
            return asking == ("".quote, #[viewLine "" 0, minibufferLine "Ada" 3]) &&
                renamed == ("two Ada".quote, #[viewLine "" 0]) &&
                dropped == ("greet: no such command".quote, #[viewLine "" 0]))
          minibufferCompiled },
    { name :=
        "the accept key and a key bound to another command, sent one after the other with no wait between: the continuation's command ran, since the window holds what it inserted, and it ran before the second key was handled, since the echo area is the other command's"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "ask"]
            for key in acceptKeys do
              session.host.press key
            session.type "C-c o"
            session.ask []
            return (← session.scene) == ("other".quote, #[viewLine "Ada" 3]))
          promptCompiled },
    { name :=
        "the answer's command is a step of its own, looked up after the accepting command's write was written back: with a store, a command over it that accepts the open prompt and adds one, and a continuation over it that adds one, the store holds two after the accept"
      run :=
        withHost context [("init.lean", bumpAcceptText)]
          (fun session => do
            session.ask [.reload]
            session.ask [.run "ask", .run "bump-accept"]
            let shown ← session.shown
            return shown.contains "store counter v1: 2" &&
                (← session.scene) == ("".quote, #[viewLine "" 0]))
          minibufferCompiled },
    { name :=
        "a completion source config registers supplies the candidates of a prompt that asks for it by name: after `w` is committed the minibuffer's status line is the label and the candidate list `w` and `wq`, the candidates the library's matcher lists; reloaded with a config that registers no such source, the same ask opens no prompt, leaves one view and refuses no step"
      run :=
        withHost context [("init.lean", sourceText true)]
          (fun session => do
            session.ask [.reload]
            session.ask [.run "pick"]
            unless ← Event.post (.commit "w") do
              return false
            let asking ← session.sceneLines
            session.pressKeys cancelKeys
            session.write "init.lean" (sourceText false)
            session.ask [.reload]
            session.ask [.run "pick"]
            let (_, views) ← session.scene
            return listsAfter asking "Pick: " ["w", "wq"] && views == #[viewLine "" 0] &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          minibufferCompiled },
    { name :=
        "config asks for a source the executable's hosts ship by name: on a host handed the `themes` package, which the executable's hosts are, a prompt asking for `themes` lists the theme default's name once it is committed; with config's own source of that name it lists config's candidate instead, and reloaded with a config that defines none, the shipped source's again"
      run := do
        let theme := Themes.defaultTheme
        -- Each prompt opens a minibuffer view of its own, so the lines are
        -- compared from their fields on, whichever view they are of.
        let lists (asking : Array String) (candidate : String) : Bool :=
          listsAfter asking "Theme: " [candidate]
        withHost context [("init.lean", shippedSourceText false)]
            (fun session => do
              let asked (query : String) : IO (Array String) := do
                session.ask [.reload]
                session.ask [.run "pick-theme"]
                unless ← Event.post (.commit query) do
                  return #[]
                let asking ← session.sceneLines
                session.pressKeys cancelKeys
                return asking
              let shippedFirst ← asked theme.name
              session.write "init.lean" (shippedSourceText true)
              let overridden ← asked "mine"
              session.write "init.lean" (shippedSourceText false)
              let restored ← asked theme.name
              return lists shippedFirst theme.name && lists overridden "mine" &&
                  lists restored theme.name &&
                  !(← session.output.get).any (·.startsWith "loop: refused"))
            { minibufferCompiled with packages := #[Themes.package] } },
    { name :=
        "criterion 3: a config that chooses the hosts' style parts for the category pick lists a pick prompt by it and every other by the default: after `w` is committed the pick prompt lists `wq`, `rewrite` and `w`, the candidates' own order, and a prompt of another category lists the same three with `w` first, the library's matcher's; reloaded with a config that chooses no style, the pick prompt lists `w` first too"
      run :=
        withHost context [("init.lean", styleText ["useStyleFor \"pick\" \"parts\""])]
          (fun session => do
            let asked (command : String) : IO (Array String) := do
              session.ask [.reload]
              session.ask [.run command]
              unless ← Event.post (.commit "w") do
                return #[]
              let asking ← session.sceneLines
              session.pressKeys cancelKeys
              return asking
            let exactFirst (lines : Array String) : Bool :=
              listsAfter lines "Pick: " ["w", "wq", "rewrite"] ||
                listsAfter lines "Pick: " ["w", "rewrite", "wq"]
            let pick ← asked "pick"
            let other ← asked "other"
            session.write "init.lean" (styleText [])
            let unchosen ← asked "pick"
            return listsAfter pick "Pick: " ["wq", "rewrite", "w"] && exactFirst other &&
                exactFirst unchosen &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          minibufferCompiled },
    { name :=
        "a category's compiled default sits between config's two choices, through the real elaborator: with compiled code giving pick the style parts and config choosing nothing, the pick prompt lists `wq`, `rewrite` and `w` and another prompt `w` first; config's `useStyle \"library\"` leaves pick on parts; config's `useStyleFor \"pick\" \"library\"` lists `w` first"
      run :=
        withHost context [("init.lean", styleText [])]
          (fun session => do
            let asked (command : String) : IO (Array String) := do
              session.ask [.reload]
              session.ask [.run command]
              unless ← Event.post (.commit "w") do
                return #[]
              let asking ← session.sceneLines
              session.pressKeys cancelKeys
              return asking
            let exactFirst (lines : Array String) : Bool :=
              listsAfter lines "Pick: " ["w", "wq", "rewrite"] ||
                listsAfter lines "Pick: " ["w", "rewrite", "wq"]
            let pick ← asked "pick"
            let other ← asked "other"
            session.write "init.lean" (styleText ["useStyle \"library\""])
            let defaulted ← asked "pick"
            session.write "init.lean" (styleText ["useStyleFor \"pick\" \"library\""])
            let chosen ← asked "pick"
            return listsAfter pick "Pick: " ["wq", "rewrite", "w"] && exactFirst other &&
                listsAfter defaulted "Pick: " ["wq", "rewrite", "w"] &&
                exactFirst chosen &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          { minibufferCompiled with styleDefaults := #[("pick", partsStyle.name)] } },
    { name :=
        "a style config defines and chooses as the default lists every prompt: after `w` both prompts list `wq` and `w`, the candidates that begin with it; a config that also chooses a style nobody registered for pick says so in the echo area and on a report line, and pick falls to the default"
      run :=
        let defines :=
          "defineStyle (.keeping \"starts\" fun text candidate => candidate.startsWith text)"
        withHost context [("init.lean", styleText [defines, "useStyle \"starts\""])]
          (fun session => do
            let asked (command : String) : IO (Array String) := do
              session.ask [.run command]
              unless ← Event.post (.commit "w") do
                return #[]
              let asking ← session.sceneLines
              session.pressKeys cancelKeys
              return asking
            session.ask [.reload]
            let pick ← asked "pick"
            let other ← asked "other"
            session.write "init.lean"
                (styleText [defines, "useStyle \"starts\"", "useStyleFor \"pick\" \"nope\""])
            session.ask [.reload]
            let (echo, _) ← session.scene
            let fallen ← asked "pick"
            return listsAfter pick "Pick: " ["wq", "w"] && listsAfter other "Pick: " ["wq", "w"] &&
                echo == s!"reload: {Completion.Style.unknown "nope"}".quote &&
                (← session.output.get).contains s!"style: {Completion.Style.unknown "nope"}" &&
                listsAfter fallen "Pick: " ["wq", "w"] &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          minibufferCompiled },
    { name :=
        "a config that chooses a style and a display nobody registered says so on a report line each, the display's after the style's"
      run :=
        withHost context [("init.lean", styleText [])]
          (fun session => do
            session.ask [.reload]
            session.write "init.lean"
                (styleText ["useStyleFor \"pick\" \"gone\"", "useDisplay \"nope\""])
            session.ask [.reload]
            let lines ← session.output.get
            let style := lines.findIdx? (· == s!"style: {Completion.Style.unknown "gone"}")
            let display := lines.findIdx? (· == s!"display: {Completion.Display.unknown "nope"}")
            return match style, display with
              | some style, some display => style < display
              | _, _ => false)
          minibufferCompiled },
    { name :=
        "criterion 5: a source config registers in the category buffer adds its candidates to the list of a prompt that asks for that category with a shipped source as its default, after the shipped source's names; one registered under the shipped source's name replaces it; with neither the shipped names alone are listed (config chooses the hosts' style parts for buffer, so the empty text lists the candidates in their own order and not by the library's scores)"
      run :=
        let more := "defineSource (.ofTexts \"more\" \"buffer\" #[\"zz-extra\"])"
        let mine := "defineSource (.ofTexts \"buffers\" \"buffer\" #[\"mine\"])"
        withHost context [("init.lean", bufferStyleText [more])]
          (fun session => do
            let asked : IO (Array String) := do
              session.ask [.reload]
              session.ask [.run "pick-buffer"]
              let asking ← session.sceneLines
              session.pressKeys cancelKeys
              return asking
            let added ← asked
            session.write "init.lean" (bufferStyleText [mine])
            let replaced ← asked
            session.write "init.lean" (bufferStyleText [])
            let shipped ← asked
            let names := ["alpha", "beta", EditorState.scratchName]
            -- The hosts' display draws no group header.
            return listsAfter shipped "Buffer: " names &&
                listsAfter added "Buffer: " (names ++ ["zz-extra"]) &&
                listsAfter replaced "Buffer: " ["mine"] &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          { minibufferCompiled with
            commands := Test.Minibuffer.package.registered.commands.push pickBuffer } },
    { name :=
        "criterion 1 over the recorder: a prompt asked with a source that answers later, from a compiled job that delivers two batches 10 ms apart on the fake clock, lists the first batch once it has arrived, in the library's order, and both once the job has ended; no step is refused"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "ask-later"]
            -- The job has posted its first batch, whose event is queued, and
            -- is in its sleep.
            unless ← eventually (return (← session.clock.waiting) == 1) do
              return false
            let first ← session.sceneLines
            session.clock.advance 10
            unless (← session.host.join patience) == .settled do
              return false
            let both ← session.sceneLines
            return listsAfter first "Pick: " (← realOrder "" #["wq", "edit"]) &&
                listsAfter both "Pick: " (← realOrder "" #["wq", "edit", "rewrite", "w"]) &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          laterCompiled },
    { name :=
        "a source that answers later, from a job config registers with sourceJob, on the real elaborator: its prompt lists the job's answer for the initial text; after a key the job is asked again, after the source's pause, and the prompt lists its answer for the typed text"
      run :=
        withHost context [("init.lean", echoSourceText)]
          (fun session => do
            session.ask [.reload]
            session.ask [.run "pick"]
            unless (← session.host.join patience) == .settled do
              return false
            let asked ← session.sceneLines
            unless ← Event.post (.commit "w") do
              return false
            -- The job started again for the typed text sleeps its pause.
            unless ← eventually (return (← session.clock.waiting) == 1) do
              return false
            session.clock.advance 20
            unless (← session.host.join patience) == .settled do
              return false
            let typed ← session.sceneLines
            return listsAfter asked "Pick: " ["!"] && listsAfter typed "Pick: " ["w!"] &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          minibufferCompiled },
    { name :=
        "criterion 4 on the host: in a prompt over 100,000 candidates, with the matcher held, each of five keys committed one after another is handled and its scene shows the minibuffer with it, while the one match started at the ask is held; once the matcher answers, the listing is the library's first ten for the whole typed text, from a second match started for it"
      run := do
        let gate ← IO.Promise.new
        withHost context []
            (fun session => do
              try
                session.ask [.run "ask-many"]
                let mut typed := ""
                let mut handled := true
                for key in ["f", "i", "l", "e", "7"] do
                  session.host.commit key
                  typed := typed ++ key
                  unless ← session.host.settle patience do
                    handled := false
                  unless (← session.sceneLines).contains (minibufferLine typed typed.length) do
                    handled := false
                let held := matchJobs (← session.output.get) "started"
                gate.resolve ()
                unless (← session.host.join patience) == .settled do
                  return false
                let listed ← session.sceneLines
                let expected := (← realOrder typed (manyPaths 100000)).take listedRows
                return handled && held.size == 1 &&
                    (matchJobs (← session.output.get) "started").size == 2 &&
                    listsAfter listed "Pick: " expected &&
                    !(← session.output.get).any (·.startsWith "loop: refused")
              finally
                gate.resolve ())
            (manyCompiled 100000) (heldMatcher gate) },
    { name :=
        "a reload that installs while a match of config's style is held cancels that match before the reload is reported, and the scene after the install, with no key typed, starts a match with the new config's style; once the matcher answers, the listing is the new style's, and the first match never delivered"
      run := do
        let gate ← IO.Promise.new
        withHost context [("init.lean", slowStyleText "slow")]
            (fun session => do
              try
                session.ask [.reload]
                session.ask [.run "ask-many"]
                unless
                  ← eventually (return (matchJobs (← session.output.get) "started").size == 1) do
                  return false
                session.write "init.lean" (slowStyleText "parts")
                session.ask [.reload]
                let reloaded ← session.output.get
                gate.resolve ()
                unless (← session.host.join patience) == .settled do
                  return false
                let listed ← session.sceneLines
                let output ← session.output.get
                let started := matchJobs output "started"
                let cancelledAt :=
                  reloaded.findIdx? fun line => matchJobs #[line] "cancelled" == started.extract 0 1
                let reportedAt := reloaded.findIdx? (·.startsWith "reload 2: installed")
                return started.size == 2 && matchJobs reloaded "started" == started &&
                    (match cancelledAt, reportedAt with
                    | some cancelled, some reported => cancelled < reported
                    | _, _ => false) &&
                    matchJobs output "ok" == started.extract 1 2 &&
                    listsAfter listed "Pick: " ((manyPaths 2000).toList.take listedRows) &&
                    !output.any (·.startsWith "loop: refused")
              finally
                gate.resolve ())
            (manyCompiled 2000) (heldMatcher gate) },
    { name :=
        "criterion 1: a prompt lists its candidates one a row in a view of their own, up to the rows config's display sets, the chosen one in its face: at 640 by 480, with config's display of three rows in the hosts' one's place, a prompt of five lists the library's first three, each row in the candidate face config's display draws, the minibuffer's status line the label alone; after the next-item key the first row is in its chosen face"
      run :=
        withHost context [("init.lean", rowsText)]
          (fun session => do
            session.host.resize 640 480
            session.ask [.reload]
            session.ask [.run "pick"]
            let asking ← session.sceneLines
            session.pressKeys nextItemKeys
            session.ask []
            let chosen ← session.sceneLines
            let rows := (← realOrder "" fiveTexts).take 3
            let faced (first : FaceName) : String :=
              let (spans, _) :=
                rows.foldl
                  (fun (spans, offset) row =>
                    let face := if offset == 0 then first else listedRowFace
                    (spans ++ [s!"{face.name} {offset}..{offset + row.utf8ByteSize}"],
                      offset + row.utf8ByteSize + 1))
                  (([] : List String), 0)
              s!"decorations 0: {" ".intercalate spans}"
            let decorated (lines : Array String) (line : String) : Bool :=
              lines.any fun printed =>
                printed.startsWith "decorations " && afterId printed == afterId line
            return nextItemKeys.length > 0 && listsAfter asking "Pick: " rows &&
                decorated asking (faced listedRowFace) &&
                listsAfter chosen "Pick: " rows &&
                decorated chosen (faced listedChosenFace) &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          minibufferCompiled },
    { name :=
        "criterion 3: closing a prompt gives the windows above back the height its list took: at 640 by 480, with config's display of three rows, the window is the frame less the bottom row before the prompt, less the input and three rows too while it lists three, with the list's view directly above the minibuffer's, and stays so once a text cuts the matches to one, which the list then shows alone; after the cancel key, and after accepting, the window has its height back and no list view is in the scene"
      run :=
        withHost context [("init.lean", rowsText)]
          (fun session => do
            session.host.resize 640 480
            session.ask [.reload]
            session.ask []
            let before ← session.sceneLines
            session.ask [.run "pick"]
            let asking ← session.sceneLines
            unless ← Event.post (.commit "ed") do
              return false
            let cut ← session.sceneLines
            session.pressKeys cancelKeys
            session.ask []
            let cancelled ← session.sceneLines
            session.ask [.run "pick"]
            session.pressKeys acceptKeys
            session.ask []
            let accepted ← session.sceneLines
            let heights := Headless.cells.heights
            let heightOf (lines : Array String) : Option Nat :=
              (printedRect lines 0).map fun (_, _, _, height) => height
            let listed := 480 - heights.message - heights.text - 3 * heights.text
            let above (lines : Array String) : Bool :=
              match (listViewId lines).bind (printedRect lines ·),
                (focusedId lines).bind (printedRect lines ·) with
              | some (_, y, _, height), some (_, below, _, _) =>
                y + height == below && height == 3 * heights.text
              | _, _ => false
            let matched ← realOrder "ed" fiveTexts
            return heightOf before == some (480 - heights.message) &&
                heightOf asking == some listed &&
                above asking &&
                matched.length == 1 &&
                heightOf cut == some listed &&
                above cut &&
                listViewShows cut matched &&
                heightOf cancelled == some (480 - heights.message) &&
                (listViewId cancelled).isNone &&
                heightOf accepted == some (480 - heights.message) &&
                (listViewId accepted).isNone &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          minibufferCompiled },
    { name :=
        "criterion 5: a display config chooses for one category shows that category's prompts, the default the others', and a reload that drops the choice redraws the open prompt with the default at the install's scene: after `w` the pick prompt's list is the plain display's rows, built from the model, and the other prompt's the hosts' display's; with the pick prompt open, a reload of a config without the choice, with no key typed, draws the hosts' display's rows"
      run :=
        let choosing :=
          styleText
            ["defineDisplay (Completion.Display.plain \"plain\")",
              "useDisplayFor \"pick\" \"plain\""]
        withHost context [("init.lean", choosing)]
          (fun session => do
            let asked (command : String) : IO (Array String) := do
              session.ask [.run command]
              unless ← Event.post (.commit "w") do
                return #[]
              session.sceneLines
            session.ask [.reload]
            let pick ← asked "pick"
            session.pressKeys cancelKeys
            let other ← asked "other"
            session.pressKeys cancelKeys
            let reopened ← asked "pick"
            session.write "init.lean" (styleText [])
            session.ask [.reload]
            let reloaded ← session.sceneLines
            let listed ← realOrder "w" #["wq", "edit", "rewrite", "w"]
            let listing : Array Completion.Listed :=
              listed.toArray.map fun text => .of (.ofText text)
            let plainRows :=
              ((Completion.Display.plain "plain").sheet { listed := listing }).rows.toList.map
                (·.text)
            return plainRows.length == listed.length && listsAfter pick "Pick: " plainRows &&
                listsAfter other "Pick: " listed &&
                listsAfter reopened "Pick: " plainRows &&
                listsAfter reloaded "Pick: " listed &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          minibufferCompiled },
    { name :=
        "criterion 4: a candidate's annotation reaches the display, which draws it: after `al` is committed the list shows the library's order of the candidates it matches, each with its annotation two spaces after it, as the hosts' display writes it, `zz` not among them, and each row in that display's face"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "ask-annotated"]
            unless ← Event.post (.commit "al") do
              return false
            let lines ← session.sceneLines
            let listed ← realOrder "al" (annotatedCandidates.map (·.text))
            let annotationOf (text : String) : String :=
              ((annotatedCandidates.find? (·.text == text)).bind (·.annotation)).getD ""
            let rows := listed.map fun text => s!"{text}  {annotationOf text}"
            let spans :=
              (rows.foldl
                  (fun (spans, offset) row =>
                    (spans ++ [s!"{listedRowFace.name} {offset}..{offset + row.utf8ByteSize}"],
                      offset + row.utf8ByteSize + 1))
                  (([] : List String), 0)).1
            let decorations := s!"decorations 0: {" ".intercalate spans}"
            return !listed.contains "zz" && listed.length == 2 && listsAfter lines "Pick: " rows &&
                lines.any
                  (fun line =>
                    line.startsWith "decorations " && afterId line == afterId decorations) &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          annotatedCompiled }]

end ConfigTest
