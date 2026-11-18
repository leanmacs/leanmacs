import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Completion
import Editor.Completion.Candidate
import Editor.Completion.Style
import Editor.Config.Registry
import Editor.Event
import Editor.ExecuteCommand
import Editor.ExecuteCommand.Compiled
import Editor.Face
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Loop
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.Minibuffer.Compiled
import Editor.State
import Editor.Themes
import Editor.Themes.Compiled
import Editor.Value
import ModelTest.Check
import ModelTest.Support.Driver
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models
import ModelTest.Support.Prompts

/-!
# Model tests: `Editor/ExecuteCommand.lean`

The model tests of `Editor/ExecuteCommand.lean`: `executeCommandChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The command `marked` of the command prompt's checks: it says `marked`. -/
def saysMarked : Dispatched := fun _ => do
  message "marked"
  return none

/-- The commands of the command prompt's checks, by name, in the order they
are registered: the commands compiled code registers for the command prompt,
for loading a theme and for the minibuffer (`ExecuteCommand.commands`,
`Themes.commands`, `Minibuffer.commands`), then `marked`, which says
`marked`. -/
def executeCommands : List (String × Dispatched) :=
  let compiled : List (String × Dispatched) :=
    (ExecuteCommand.commands ++ Themes.commands ++ Minibuffer.commands).toList.filterMap
      fun registration =>
      match registration.action with
      | .call run =>
        some
          (registration.name, fun call => do
            run call
            return none)
      | _ => none
  compiled ++ [("marked", saysMarked)]

/-- What a step of the command prompt's checks is handed: the commands of
`executeCommands`, the loop told their names, in order, as the registered
commands' and the themes `default` and `second` as the registered ones; a
style that keeps the candidates a text starts, in order, for every
category. No key is bound to `execute-command` or to `load-theme`, as in a
config that binds nothing: `C-e y` runs the minibuffer's accept alone. -/
def executeKeys : Loop.Keys TestScheme.scheme :=
  { dispatchKeys [("C-e y", invoke Minibuffer.acceptName)]
      executeCommands with
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

/-- The checks of the command prompt (`Editor/ExecuteCommand.lean`,
`Editor/ExecuteCommand/Compiled.lean`), on the loop's driver over the
editor's models and the test scheme: it lists every registered command,
runs the one accepted as a step of its own, so one that asks asks in turn,
and the style chosen for the category `command` decides the order. -/
def executeCommandChecks : List Check :=
  let names := executeKeys.registered.commandNames
  [{  name :=
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
                    { command := ExecuteCommand.name, arguments := [.nat 3] }).loop.state.prompt.map
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
                  promptEcho driver != "marked" }]

end ModelTest
