import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.Candidate
import Editor.Completion.Style
import Editor.Config.Packages
import Editor.Event
import Editor.Face
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.State
import Editor.Test.Config
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Prompts
import Editor.Test.Sources
import Editor.Themes
import Editor.Value
import ExecuteCommand
import ExecuteCommand.Compiled
import ExecuteCommandTest.Check

/-!
# Model tests: `ExecuteCommand.lean`

The model tests of `ExecuteCommand.lean`: `executeCommandChecks`. They were
the core's (`ModelTest.executeCommandChecks`) while the command prompt was
a module of the core, and moved here with their sentences as they were.
The test driver's root, `ExecuteCommandTest/Model.lean`, runs them.

They run on the core's test kit: the loop's driver (`Editor.Test.Driver`,
`Editor.Test.Loop`), the minibuffer's package as the kit's prompts bring it
(`Editor.Test.Prompts`), and the source contract's runner
(`Editor.Test.Sources`). The command that loads a theme is registered here
from the editor API (`Themes.loadThemeCommand`), as compiled code
registers it.
-/

namespace ExecuteCommandTest

open Editor
open Editor.Test

/-- The command `marked` of the command prompt's checks: it says `marked`. -/
def saysMarked : Dispatched := fun _ => do
  message "marked"
  return none

/-- The commands of the command prompt's checks, by name, in the order they
are registered: the commands compiled code registers for the command prompt
(`ExecuteCommand.package.registered.commands`), the command that loads a
theme, as the themes package registers it (`Themes.loadName`,
`Themes.loadThemeCommand`), and the minibuffer's commands
(`Minibuffer.package.registered.commands`), then `marked`, which says
`marked`. -/
def executeCommands : List (String × Dispatched) :=
  let called (registrations : Array Config.Registration) : List (String × Dispatched) :=
    registrations.toList.filterMap fun registration =>
      match registration.action with
      | .call run =>
        some
          (registration.name, fun call => do
            run call
            return none)
      | _ => none
  let loadTheme : Dispatched := fun call => do
    Themes.loadThemeCommand call
    return none
  called ExecuteCommand.package.registered.commands ++ [(Themes.loadName, loadTheme)] ++
    called Minibuffer.package.registered.commands ++
    [("marked", saysMarked)]

/-- What a step of the command prompt's checks is handed: the commands of
`executeCommands`, the loop told their names, in order, as the registered
commands' and the themes `default` and `second` as the registered ones; a
style that keeps the candidates a text starts, in order, for every
category. No key is bound to `execute-command` or to `load-theme`, as in a
config that binds nothing: `C-e y` runs the minibuffer's accept alone, and
`C-c m`, described `Mark it`, and `C-c n` run `marked`. -/
def executeKeys : Loop.Keys TestScheme.scheme :=
  { dispatchKeys []
      executeCommands with
    maps := fun _ _ =>
      [Keymap.ofDescribed
          [(keys "C-e y", invoke Minibuffer.acceptName, none),
            (keys "C-c m", invoke "marked", some "Mark it"), (keys "C-c n", invoke "marked", none)]]
    registered :=
      { themeNames := #[Theme.defaultName, "second"]
        commandNames := (executeCommands.map (·.1)).toArray }
    matching :=
      {
        default :=
          Completion.Style.keeping "starts" fun text candidate => candidate.startsWith text } }

/-- A fake style for the command prompt's checks: it keeps every
candidate, in reverse order, with no ranges. -/
def reversing : Completion.Style :=
  { name := "reversing"
    hits := fun _ candidates =>
      pure ((Array.range candidates.size).reverse.map Completion.Hit.ofIndex) }

/-- A driver of the command prompt's checks over the initial state, with
`keys`; `none` if making the state was refused. -/
def executeDriver (keys : Loop.Keys TestScheme.scheme := executeKeys) : Option TestDriver :=
  (Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- `driver` after `invocation` is run as a step of its own, as a host's
driver runs a command it calls by name with no key. -/
def calling (driver : TestDriver) (invocation : Invocation := { command := ExecuteCommand.name }) :
    TestDriver :=
  (driver.stepped (driver.loop.invoke driver.handed invocation)).1

/-- `driver` after the command prompt is called, `typed` is committed into
it and the minibuffer's accept runs. -/
def accepting (driver : TestDriver) (typed : String) : TestDriver :=
  (fedTo (calling driver) (.commit typed :: presses "C-e y")).1

/-- The checks of the command prompt (`ExecuteCommand.lean`,
`ExecuteCommand/Compiled.lean`), on the loop's driver over the
editor's models and the test scheme: it lists every registered command,
runs the one accepted as a step of its own, so one that asks asks in turn,
and the style chosen for the category `command` decides the order. -/
def executeCommandChecks : List Check :=
  let names := executeKeys.registered.commandNames
  [{    name :=
          "from keys that bind neither, calling execute-command opens a prompt labelled with its label whose continuation is the command itself; committing load-theme and accepting opens load-theme's own prompt and loads nothing; committing second and accepting that loads the theme second and closes the prompt"
        run :=
          pure <|
            match executeDriver with
            | none => false
            | some driver =>
              let asking := calling driver
              let themed := accepting driver "load-theme"
              let (loaded, _) := fedTo themed (.commit "second" :: presses "C-e y")
              asking.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                  some (ExecuteCommand.label, { command := ExecuteCommand.name }) &&
                themed.loop.state.prompt.map (·.label) == some Themes.label &&
                themed.themes == #[] &&
                loaded.themes == #["second"] &&
                loaded.loop.state.prompt == none },
      { name :=
          "the command prompt's candidates are the names the loop was told commands are registered under, in that order"
        run :=
          pure <|
            match executeDriver with
            | none => false
            | some driver =>
              (candidatesOf (calling driver)).map (·.all.map (·.text)) == some names &&
                names.contains ExecuteCommand.name &&
                names.contains Themes.loadName &&
                names.back? == some "marked" },
      { name :=
          "the command prompt's candidates are the names of the registry the loop is told of: with zz-mine registered by config they end with it, after compiled code's; once config's commands are replaced with none, as a reload whose config no longer registers zz-mine replaces them, it is no candidate and compiled code's are"
        run :=
          let compiled : Config.Registry :=
            ({} : Config.Registry).replace .compiled
              (executeCommands.map fun (name, _) => registration name name).toArray
          let mine := compiled.replace .config #[registration "zz-mine" "mine"]
          let listed (registry : Config.Registry) : Option (Array String) :=
            (executeDriver { executeKeys with registered := registry.registered }).bind
              fun driver => (candidatesOf (calling driver)).map (·.all.map (·.text))
          pure
            (listed mine == some (names.push "zz-mine") &&
              listed (mine.replace .config #[]) == some names) },
      { name :=
          "each of the command prompt's candidates is annotated with the keys that reach its command in the asking view, joined by commas, and the first description among them: marked with C-c m, C-c n  Mark it, the minibuffer's accept with C-e y, and load-theme, which no key reaches, with none"
        run :=
          pure <|
            match executeDriver with
            | none => false
            | some driver =>
              let annotated (name : String) : Option (Option String) :=
                (candidatesOf (calling driver)).bind fun candidates =>
                  (candidates.all.find? (·.text == name)).map (·.annotation)
              annotated "marked" == some (some "C-c m, C-c n  Mark it") &&
                annotated Minibuffer.acceptName == some (some "C-e y") &&
                annotated Themes.loadName == some none },
      { name :=
          "a command's annotation is none with no binding, the keys of one with no description, and the keys then the description of a described one"
        run :=
          let undescribed : KeyBinding := { keys := keys "SPC f f", command := "open-file" }
          let described : KeyBinding := { undescribed with desc := some "Find file" }
          pure
            (ExecuteCommand.annotation #[] "open-file" == none &&
              ExecuteCommand.annotation #[undescribed] "open-file" == some "SPC f f" &&
              ExecuteCommand.annotation #[described] "open-file" == some "SPC f f  Find file" &&
              ExecuteCommand.annotation #[described] "other" == none) },
      { name :=
          "accepting a typed fragment that is no command's name with nothing chosen runs the first command the style lists for it: load-th runs load-theme, which asks"
        run :=
          pure <|
            match executeDriver with
            | none => false
            | some driver =>
              (accepting driver "load-th").loop.state.prompt.map (·.label) == some Themes.label },
      { name :=
          "accepting a text no command matches says so in the echo area and runs nothing; an empty or blank answer says nothing and runs nothing"
        run :=
          pure <|
            match executeDriver with
            | none => false
            | some driver =>
              let unmatched := accepting driver "zzz"
              let empty := accepting driver ""
              let blank := accepting driver "   "
              promptEcho unmatched == ExecuteCommand.noMatch "zzz" &&
                promptEcho unmatched == "execute-command: no command matches `zzz`" &&
                unmatched.loop.state.prompt == none &&
                [empty, blank].all fun driver =>
                  promptEcho driver == "" && driver.loop.state.prompt == none },
      { name :=
          "calling the command prompt while a prompt is open says the refusal after its own name and leaves that prompt open"
        run :=
          pure <|
            match executeDriver with
            | none => false
            | some driver =>
              let again := calling (calling driver)
              promptEcho again == ExecuteCommand.notAsking (.alreadyOpen ⟨1⟩) &&
                again.loop.state.prompt.map (·.label) == some ExecuteCommand.label },
      { name := "the command prompt called with a count first, as a Vim key hands it, asks"
        run :=
          pure <|
            match executeDriver with
            | none => false
            | some driver =>
              (calling driver
                      { command := ExecuteCommand.name,
                        arguments := [.nat 3] }).loop.state.prompt.map
                  (·.label) ==
                some ExecuteCommand.label },
      { name :=
          "the style the loop is handed for the category command decides the order of the command prompt's candidates, and the order a typed fragment is resolved in: a fake that reverses lists them in reverse and runs the last registered, marked, for a text that is no name, yet runs a command's exact name, load-theme, which asks, with spaces around it or not; a theme prompt from the same keys keeps its own order"
        run :=
          pure <|
            let keys : Loop.Keys TestScheme.scheme :=
              { executeKeys with
                matching :=
                  { default := Completion.Style.keeping "all" fun _ _ => true
                    byCategory := fun category =>
                      if category == ExecuteCommand.category then some reversing else none } }
            match executeDriver keys with
            | none => false
            | some driver =>
              let listed := calling driver
              let themed := calling driver { command := Themes.loadName }
              let ran := accepting driver "x"
              let exact := accepting driver Themes.loadName
              let padded := accepting driver s!"  {Themes.loadName}  "
              (candidatesOf listed).map (·.listed.map (·.candidate.text)) == some names.reverse &&
                (candidatesOf themed).map (·.listed.map (·.candidate.text)) ==
                  some #[Theme.defaultName, "second"] &&
                promptEcho ran == "marked" &&
                [exact, padded].all fun driver =>
                  driver.loop.state.prompt.map (·.label) == some Themes.label &&
                    promptEcho driver != "marked" },
      { name :=
          "pressing C-c x, a key bound to execute-command, or choosing execute-command from the menu, annotates each candidate with its keys as calling it by name does: marked with C-c m, C-c n  Mark it"
        run :=
          let bound (map : List (Keymap TestScheme.Binding)) : List (Keymap TestScheme.Binding) :=
            map ++ [Keymap.ofDescribed [(keys "C-c x", invoke ExecuteCommand.name, none)]]
          pure <|
            match
              executeDriver
                { executeKeys with
                  maps := fun state view => bound (executeKeys.maps state view) } with
            | none => false
            | some driver =>
              let annotations (driver : TestDriver) : Option (Array (String × Option String)) :=
                (candidatesOf driver).map (·.all.map fun c => (c.text, c.annotation))
              let named := calling driver
              let pressed := (fedTo driver (presses "C-c x")).1
              let chosen := (fedTo driver [.menu ExecuteCommand.name]).1
              let marked := (annotations pressed).bind (·.find? (·.1 == "marked"))
              marked == some ("marked", some "C-c m, C-c n  Mark it") &&
                annotations pressed == annotations named &&
                annotations chosen == annotations named }] ++
    (sourceHolds ExecuteCommand.source).map fun (name, held) => { name, run := pure held }

end ExecuteCommandTest
