import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Config.Packages
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.Face
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Language
import Editor.Loop.Driver
import Editor.Mode
import Editor.Program
import Editor.ProjectMode
import Editor.Scene
import Editor.State
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Test.Prompts
import Editor.Test.Sources
import Editor.Text
import Editor.Value
import Editor.Workspace
import Themes
import Themes.Compiled
import ThemesApiTest.Contract
import ThemesTest.Check

/-!
# Model tests: `Themes.lean`

The model tests of `Themes.lean` and `Themes/Compiled.lean`: `themeChecks`.
The test driver's root, `ThemesTest/Model.lean`, runs them; its module doc
says what each shows.
-/

namespace ThemesTest

open Editor
open Editor.Test

/-- The command `other` of the theme command's checks: it says `other`. -/
def saysOther : Dispatched := fun _ => do
  message "other"
  return none

/-- What a step of the theme command's checks is handed: the commands
compiled code registers for loading a theme (`Themes.package.registered.commands`),
the kit's minibuffer's (`Test.Minibuffer.package.registered.commands`,
`Editor/Test/Minibuffer.lean`), and `other`, which says
`other`; told that the themes `default` and `second` are registered. `C-t
t` runs the theme command with nothing, `C-t s` with the name `second`,
`C-t n` with the name `nope`, `C-e y` runs the minibuffer's accept and `C-e
o` runs `other`. -/
def themeKeys : Loop.Keys TestScheme.scheme :=
  let compiled : List (String × Dispatched) :=
    (Themes.package.registered.commands ++
          Test.Minibuffer.package.registered.commands).toList.filterMap
      fun registration =>
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
        ("C-e y", invoke Test.Minibuffer.acceptName), ("C-e o", invoke "other")]
      (compiled ++ [("other", saysOther)]) with
    registered := { themeNames := #[Theme.defaultName, "second"] } }

/-- The checks of the command that loads a theme (`Themes.lean`,
`Themes/Compiled.lean`), on the loop's driver over the editor's
models and the test scheme: it asks for a name among the registered ones,
and a step that loads one hands the name back. And its completion source
(`Themes.source`) held to the completion sources' contract, on the kit's
runner (`Editor.Test.sourceHolds`, `Editor/Test/Sources.lean`). And the
`Package` value held to the contract of the interface package `themes-api`
(`ThemesApiTest.contractChecks`), with a check that it bites, and what it
registers, in the registry it makes alone. -/
def themeChecks : List Check :=
  let driver? : Option TestDriver :=
    (Loop.Driver.over themeKeys (fun _ => none) (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption
  [{        name :=
              "the theme command with no name opens a prompt labelled with its label, whose continuation is the command itself and whose candidates are the registered themes' names"
            run :=
              pure <|
                match driver? with
                | none => false
                | some driver =>
                  let (asking, steps) := fedTo driver (presses "C-t t")
                  asking.loop.state.prompt.map
                        (fun asking => (asking.label, asking.continuation)) ==
                      some (Themes.label, { command := Themes.loadName }) &&
                    (candidatesOf asking).map (·.all.map (·.text)) ==
                      some #[Theme.defaultName, "second"] &&
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
                    again.loop.state.prompt.isSome }] ++
        ((sourceHolds Themes.source).map fun (name, held) => { name, run := pure held }) ++
      -- The contract of `themes-api`, which themes implements, over its
      -- package, each of its sentences one check.
      ((ThemesApiTest.contractChecks Themes.package).map fun (name, held) =>
        { name, run := pure held }) ++
    [{  name :=
          "the contract of themes-api this list runs bites: over a package of the themes package's name that registers nothing, every check of it fails"
        run :=
          let broken : Package := { name := Themes.package.name, setup := pure () }
          pure ((ThemesApiTest.contractChecks broken).all (!·.2)) },
      { name :=
          "the themes package registers the command load-theme, one theme, default, the built-in one, and the source themes, its own and the one source of the category theme, so config can ask for it by name"
        run :=
          let (state, refused) : Config.State Unit Unit × Array String :=
            Config.State.ofPackages #[Themes.package]
          let registry := state.registry
          pure
            (refused.isEmpty &&
              (registry.find? "load-theme").any (·.owner == Themes.package.owner) &&
              registry.themes.map (fun entry => (entry.named.name, entry.owner.name)) ==
                #[("default", "themes")] &&
              registry.theme? Theme.defaultName ==
                some { name := "default", theme := Theme.builtin } &&
              (registry.source? "themes").isSome &&
              registry.sources.any
                (fun entry =>
                  entry.source.name == "themes" && entry.owner == Themes.package.owner) &&
              registry.sourcesIn "theme" == #["themes"]) }]

end ThemesTest
