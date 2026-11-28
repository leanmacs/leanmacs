import Editor.Api
import Editor.InputScheme.Test
import Editor.Link
import Editor.Links
import Editor.Loop.Driver
import Editor.Package
import Editor.Test.Driver
import Editor.Test.Hosted
import Editor.Test.Models
import Editor.Test.Prompts
import LinkCommands.Compiled
import LinkCommandsTest.Check

/-!
# The tests of `LinkCommands.lean` and `LinkCommands/Compiled.lean`

The tests of the package that registers the link commands:
`linkCommandsChecks`. The test driver `LinkCommandsTest/Model.lean` runs
them; its module doc says what each shows.
-/

namespace LinkCommandsTest

open Editor
open Editor.Test

/-- A package of the checks' own: `fill` makes a buffer whose text is
`say hello`, with a link over it whose target runs `say` with `hello`, and
shows it; `say` says its string argument. -/
def fillPackage : Package :=
  { name := "link-commands-checks"
    setup := do
      commandWith "fill" fun call => do
          let .ok id ← createBuffer "links" "say hello\n" | return
          discard <|
              id.setLinks
                #[{ start := 0, stop := 9
                    target := .command { command := "say", arguments := [.str "hello"] } }]
          discard <| call.target.window.id.show id
      commandWith "say" fun call =>
          match call.arguments with
          | [.str said] => message said
          | _ => pure () }

/-- A driver over the packages `link-commands` and `fillPackage`, installed
as a host installs them, with the registry's active keymaps; `none` if
making the state was refused. -/
def linkCommandsDriver : Option TestDriver :=
  let registry := hostedRegistry #[LinkCommands.package, fillPackage]
  let keys := hostedKeys registry
  let jobs (name : String) : Option (List Argument → Work) :=
    (registry.findJob? name).map (·.registration.workWith registry.extensionsAt)
  (Loop.Driver.over { keys with maps := registry.activeMaps TestScheme.scheme } jobs
      (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- The checks of the package `link-commands` (`LinkCommands.lean`,
`LinkCommands/Compiled.lean`). -/
def linkCommandsChecks : List Check :=
  [{  name :=
        "the package link-commands registers link-follow, link-next and link-previous, the job url-open and the mode links, under the core's names, and nothing else"
      run :=
        let registered := LinkCommands.package.registered
        pure
          (LinkCommands.package.name == "link-commands" &&
            registered.commands.map (·.name) ==
              #[Links.followName, Links.nextName, Links.previousName] &&
            registered.jobs.map (·.name) == #[Links.openJobName] &&
            registered.modes.map (·.name) == #[Links.modeName] &&
            registered.modes.map (·.roles) == #[Links.mode.roles] &&
            registered.bindings.isEmpty) },
    { name :=
        "on a host with the package, activate's key on a command link runs that command with its argument"
      run :=
        pure <|
          match linkCommandsDriver with
          | none => false
          | some driver =>
            let filled := hostedRan driver { command := "fill" }
            let pressed := (fedTo filled (rolePresses Role.activate)).1
            pressed.loop.state.echo == "hello" }]

end LinkCommandsTest
