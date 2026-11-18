import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Compile.Contribution
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.Face
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Language
import Editor.Loop
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Themes
import Editor.Themes.Compiled
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Driver
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models
import ModelTest.Support.Prompts

/-!
# Model tests: `Editor/Themes.lean`

The model tests of `Editor/Themes.lean`: `themeChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The command `other` of the theme command's checks: it says `other`. -/
def saysOther : Dispatched := fun _ => do
  message "other"
  return none

/-- What a step of the theme command's checks is handed: the commands
compiled code registers for loading a theme and for the minibuffer
(`Themes.commands`, `Minibuffer.commands`), and `other`, which says
`other`; told that the themes `default` and `second` are registered. `C-t
t` runs the theme command with nothing, `C-t s` with the name `second`,
`C-t n` with the name `nope`, `C-e y` runs the minibuffer's accept and `C-e
o` runs `other`. -/
def themeKeys : Loop.Keys TestScheme.scheme :=
  let compiled : List (String × Dispatched) :=
    (Themes.commands ++ Minibuffer.commands).toList.filterMap fun registration =>
      match registration.action with
      | .call run =>
        some
          (registration.name, fun call => do
            run call
            return none)
      | _ => none
  {
    dispatchKeys
      [("C-t t", invoke Themes.loadName),
        ("C-t s", { command := Themes.loadName, arguments := [.str "second"] }),
        ("C-t n", { command := Themes.loadName, arguments := [.str "nope"] }),
        ("C-e y", invoke Minibuffer.acceptName), ("C-e o", invoke "other")]
      (compiled ++ [("other", saysOther)]) with
    registered := { themeNames := #[Theme.defaultName, "second"] } }

/-- The checks of the command that loads a theme (`Editor/Themes.lean`,
`Editor/Themes/Compiled.lean`), on the loop's driver over the editor's
models and the test scheme: it asks for a name among the registered ones,
and a step that loads one hands the name back. -/
def themeChecks : List Check :=
  let driver? : Option TestDriver :=
    (Loop.Driver.over themeKeys (fun _ => none) (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption
  [{  name :=
        "the theme command with no name opens a prompt labelled with its label, whose continuation is the command itself and whose candidates are the registered themes' names"
      run :=
        pure <|
          match driver? with
          | none => false
          | some driver =>
            let (asking, steps) := fedTo driver (presses "C-t t")
            asking.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                some (Themes.label, { command := Themes.loadName }) &&
              (candidatesOf asking).map (·.all) == some #[Theme.defaultName, "second"] &&
              steps.map (·.map (·.theme)) == #[some none, some none] },
    { name :=
        "the theme command with a registered name hands the name back with its step and says nothing; accepting its prompt with a name loads that one"
      run :=
        pure <|
          match driver? with
          | none => false
          | some driver =>
            let (loaded, steps) := fedTo driver (presses "C-t s")
            let (typed, _) := fedTo driver (presses "C-t t" ++ [.commit "second"])
            let (accepted, _) := fedTo typed (presses "C-e y")
            steps.map (·.map (·.theme)) == #[some none, some (some "second")] &&
              promptEcho loaded == "" &&
              loaded.themes == #["second"] &&
              accepted.themes == #["second"] &&
              accepted.loop.state.prompt == none },
    { name :=
        "the theme command with a name nobody registered says so in the echo area, by its name and the theme's, and loads none; the editor goes on"
      run :=
        pure <|
          match driver? with
          | none => false
          | some driver =>
            let (unknown, _) := fedTo driver (presses "C-t n")
            let (after, _) := fedTo unknown (presses "C-e o")
            promptEcho unknown == "load-theme: no theme is registered as `nope`" &&
              promptEcho unknown == Themes.notLoaded (.noSuchTheme "nope") &&
              unknown.themes == #[] &&
              promptEcho after == "other" },
    { name :=
        "the theme command while a prompt is open says the refusal after its own name and leaves that prompt open"
      run :=
        pure <|
          match driver? with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-t t")
            let (again, _) := fedTo asking (presses "C-t t")
            promptEcho again == Themes.notAsking (.alreadyOpen ⟨1⟩) &&
              promptEcho again == "load-theme: a prompt is open already" &&
              again.loop.state.prompt.isSome }]

end ModelTest
