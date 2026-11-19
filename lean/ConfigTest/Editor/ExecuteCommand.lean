import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import ConfigTest.Support.Lines
import ConfigTest.Support.Themes
import Editor.BindingSearch.Compiled
import Editor.Config.Packages
import Editor.Event
import Editor.ExecuteCommand.Compiled
import Editor.Themes.Compiled

/-!
# Config tests: `Editor/ExecuteCommand.lean`

The tests of `Editor/ExecuteCommand.lean`: `commandPromptChecks`, the command
prompt through the headless host over the real registry, and in the same
host's session the binding search of `Editor/BindingSearch.lean`, which has no
test module of its own here. The root module `ConfigTest` runs them; its module
doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- What compiled code hands the hosts of the command prompt's checks: the
minibuffer's commands and its mode, the command prompt, the binding search
and the command that loads a theme, the theme `default` and the fixture
themes (`ConfigTest/Support/Themes.lean`). -/
def commandCompiled : Compiled :=
  { minibufferCompiled with
    commands :=
      Minibuffer.package.registered.commands ++ ExecuteCommand.package.registered.commands ++
        BindingSearch.package.registered.commands ++
        Themes.package.registered.commands
    themes := #[Themes.defaultTheme] ++ fixtureThemes }

/-- A config whose `setup` defines the style `starts`, which keeps the
candidates a text starts, in their order, chooses it for the categories
`command` and `binding`, registers `zz-other`, which says `other`, bound to
`SPC f f` with no description, `yy-said`, which says `said`, bound to
`SPC y y` and described `Say it`, and, when `mine`, `zz-mine`, which says
`mine`. -/
def commandText (mine : Bool) : String :=
  "def setup : SetupM Unit := do\n" ++
    "  defineStyle (.keeping \"starts\" fun text candidate => candidate.startsWith text)\n" ++
    "  useStyleFor \"command\" \"starts\"\n" ++
    "  useStyleFor \"binding\" \"starts\"\n" ++
    "  command \"zz-other\" (message \"other\")\n" ++
    "  command \"yy-said\" (message \"said\")\n" ++
    "  bindKey \"SPC y y\" \"yy-said\" (desc := \"Say it\")\n" ++
    "  bindKey \"SPC f f\" \"zz-other\"\n" ++
    if mine then "  command \"zz-mine\" (message \"mine\")\n" else ""

/-- The checks of the command prompt (`Editor/ExecuteCommand.lean`) through
a host over the real elaborator and the real registry: its candidates are
the commands compiled code registers and config's, and a reload that drops
one of config's drops it from them, and the command it runs is a step of
its own, so `load-theme` asked through it puts the chosen theme in force
with no key bound to either; a command config binds is shown with its keys.
And of the binding search (`Editor/BindingSearch.lean`) in the same session:
it lists a binding of config's with its keys and description, and accepting
it runs its command. The style `starts`, which config chooses for the
categories `command` and `binding`, keeps each listing short and in the
source's order, so no check pins the library matcher's order. -/
def commandPromptChecks (context : Context) : List Check :=
  [{  name :=
        "criteria 1, 2 and 3: the command prompt lists the commands compiled code registers and config's, config's in the order registered; a reload whose config no longer registers zz-mine drops it from the candidates; from a config that binds neither execute-command nor load-theme, calling execute-command, accepting load-theme and then fixture-dark puts that theme in force, as the scene line names it; a config command bound to SPC f f shows SPC f f as its annotation; the binding search lists SPC y y with its command and description, and accepting it runs yy-said"
      run :=
        withHost context [("init.lean", commandText true)]
          (fun session => do
            let asked (typed : String) : IO (Array String) := do
              session.ask [.run ExecuteCommand.name]
              unless ← Event.post (.commit typed) do
                return #[]
              let asking ← session.sceneLines
              session.pressKeys cancelKeys
              return asking
            let answered (typed : String) : IO Bool := do
              unless ← Event.post (.commit typed) do
                return false
              session.pressKeys acceptKeys
              return true
            let drawnIn : IO String := do
              return ((← session.sceneLines).filter (·.startsWith "scene ")).back?.getD ""
            session.ask [.reload]
            let configs ← asked "zz-"
            let compiled ← asked "load"
            session.write "init.lean" (commandText false)
            session.ask [.reload]
            let dropped ← asked "zz-"
            let before ← drawnIn
            session.ask [.run ExecuteCommand.name]
            unless ← answered Themes.loadName do
              return false
            unless ← answered fixtureDark.name do
              return false
            let after ← drawnIn
            session.ask [.run BindingSearch.name]
            unless ← Event.post (.commit "SPC y") do
              return false
            let searching ← session.sceneLines
            session.pressKeys acceptKeys
            let said := (← session.scene).1
            return listsAfter configs ExecuteCommand.label ["zz-other  SPC f f", "zz-mine"] &&
                listsAfter compiled ExecuteCommand.label [Themes.loadName] &&
                listsAfter dropped ExecuteCommand.label ["zz-other  SPC f f"] &&
                before.endsWith s!", theme {Theme.defaultName.quote}" &&
                after.endsWith s!", theme {fixtureDark.name.quote}" &&
                listsAfter searching BindingSearch.label ["SPC y y  yy-said  Say it"] &&
                said == "said".quote &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          commandCompiled }]

end ConfigTest
