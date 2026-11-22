import Editor.Completion
import Editor.Config.Packages
import Editor.Event
import Editor.Face
import Editor.Scene
import Editor.Test.Linked.Frames
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Minibuffer
import Themes
import Themes.Compiled
import ThemesTest.Check

/-!
# Linked tests: `Themes.lean`

The tests of `Themes.lean`: `themeChecks`, through the headless host. The
root module `ThemesTest.Linked` runs them; its module doc says what each shows.
-/

namespace ThemesTest.Linked

open Editor
open Editor.Test.Linked

/-- What compiled code hands the hosts of the theme checks: the command that
loads a theme and the theme `default` (`Themes/Compiled.lean`), and
the kit's minibuffer's commands and its mode (`Editor/Test/Minibuffer.lean`),
which its prompt is answered with. -/
def themeCompiled : Compiled :=
  { commands := Themes.package.registered.commands ++ Test.Minibuffer.package.registered.commands,
    modes := Test.Minibuffer.package.registered.modes
    themes := #[Themes.defaultTheme] }

/-- A config whose `setup` registers `pick-theme`, which asks `Theme: ` with
the completion source registered under `themes`, by name, the one the
themes package ships (`Themes.source`), and, when `overrides`, a source of
config's own under that name, whose one candidate is `mine`. -/
def themeSourceText (overrides : Bool) : String :=
  let source := "  defineSource (.ofTexts \"themes\" \"theme\" #[\"mine\"])\n"
  "def setup : SetupM Unit := do\n" ++ (if overrides then source else "") ++
    "  command \"pick-theme\" (discard <| prompt \"Theme: \" { command := \"picked\" }\n" ++
    "    (sources := [.named \"themes\"]))\n"

/-- The face `default` of the theme `second` the theme checks' config
defines: a background of its own. -/
def secondDefault : Face :=
  { background := some (Color.rgb 0 90 0) }

/-- The face `keyword` the theme checks' config sets. -/
def keywordFace : Face :=
  { foreground := some (Color.rgb 200 0 0) }

/-- The checks of named themes through a host: a config directory of real
files, the real elaborator, the display's real binding and the library's
layout (`withFramedHost`, `Editor/Test/Linked/Frames.lean`). A frame is
compared with the frame a second display, handed the same scene, lays out
in a theme written here. And the themes' completion source asked by
config, by name. -/
def themeChecks (context : HostContext) : List Check :=
  [{  name :=
        "criteria 3 and 4: the theme command switches the theme the display draws in with no reload, to the frame the chosen theme followed by config's own face gives, and the scene line names the theme it was drawn in"
      run :=
        withFramedHost context
          [("init.lean",
              "def setup : SetupM Unit := do\n  defineTheme \"second\" #[{ name := ⟨\"default\"⟩, face := { background := some (Color.rgb 0 90 0) } }]\n  face \"keyword\" { foreground := some (Color.rgb 200 0 0) }\n")]
          (fun session frames => do
            let configured : Theme := #[{ name := ⟨"keyword"⟩, face := keywordFace }]
            let holds (parts : List (String × Bool)) : IO Unit := do
              if let some (part, _) := parts.find? (!·.2) then
                throw (IO.userError part)
            let sceneLine : IO String := do
              session.ask [.scene]
              return ((← session.output.get).filter (·.startsWith "scene ")).back?.getD ""
            session.ask [.reload]
            session.host.resize 160 96
            unless ← Event.post (.commit "let x = 1") do
              return false
            session.ask []
            let (plain, plainMirror) ← frames (Theme.builtin ++ configured)
            let before ← sceneLine
            session.ask [.run Themes.loadName]
            unless ← Event.post (.commit "second") do
              return false
            session.pressKeys acceptKeys
            let (switched, switchedMirror) ←
              frames (#[{ name := ⟨"default"⟩, face := secondDefault }] ++ configured)
            let after ← sceneLine
            let lines ← session.output.get
            holds
                [("the frame after the reload is the default theme's with config's face",
                    plain == plainMirror),
                  ("the frame after the switch differs", switched != plain),
                  ("and is the one the second theme with config's face gives",
                    switched == switchedMirror),
                  (s!"the scene before names the default theme: {before}",
                    before.endsWith ", theme \"default\""),
                  (s!"the scene after names the second theme: {after}",
                    after.endsWith ", theme \"second\""),
                  ("there was one reload",
                    (lines.filter (·.startsWith "reload ")) ==
                      #["reload 1: installed, 1 files, 0 commands"])]
            return true)
          themeCompiled },
    { name :=
        "criterion 6: a config that names a theme nobody registered says so in the echo area, naming the theme, before the frame is made and after, and its report says so; the theme in force stays"
      run :=
        withHost context [("init.lean", "def setup : SetupM Unit := do\n  useTheme \"nope\"\n")]
          (compiled := themeCompiled) fun session => do
          session.ask [.reload]
          session.host.resize 80 64
          session.ask []
          let made ← session.echo
          session.ask [.say "cleared"]
          let cleared ← session.echo
          session.ask [.reload]
          let again ← session.echo
          let lines ← session.lines
          let said := "reload: no theme is registered as `nope`".quote
          let scene := (lines.filter (·.startsWith "scene ")).back?.getD ""
          return made == said && cleared == "cleared".quote && again == said &&
              (lines.filter (· == "theme: no theme is registered as `nope`")).size == 2 &&
              scene.endsWith ", theme \"default\"" },
    { name :=
        "config asks for a source the executable's hosts ship by name: on a host handed the `themes` package, which the executable's hosts are, a prompt asking for `themes` lists the theme default's name once it is committed; with config's own source of that name it lists config's candidate instead, and reloaded with a config that defines none, the shipped source's again"
      run := do
        let theme := Themes.defaultTheme
        -- Each prompt opens a minibuffer view of its own, so the lines are
        -- compared from their fields on, whichever view they are of.
        let lists (asking : Array String) (candidate : String) : Bool :=
          listsAfter asking "Theme: " [candidate]
        withHost context [("init.lean", themeSourceText false)]
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
              session.write "init.lean" (themeSourceText true)
              let overridden ← asked "mine"
              session.write "init.lean" (themeSourceText false)
              let restored ← asked theme.name
              return lists shippedFirst theme.name && lists overridden "mine" &&
                  lists restored theme.name &&
                  !(← session.output.get).any (·.startsWith "loop: refused"))
            { commands := Test.Minibuffer.package.registered.commands
              modes := Test.Minibuffer.package.registered.modes, packages := #[Themes.package] } }]

end ThemesTest.Linked
