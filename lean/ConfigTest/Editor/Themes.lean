import ConfigTest.Check
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import Editor.Completion
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Registry
import Editor.Display.Real
import Editor.Event
import Editor.Event.Queue
import Editor.Ex.Line
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Window
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.InputScheme.Test
import Editor.Job.Runner
import Editor.Language
import Editor.Loop
import Editor.Minibuffer.Compiled
import Editor.Scene
import Editor.Text.Real
import Editor.Themes
import Editor.Themes.Compiled

/-!
# Config tests: `Editor/Themes.lean`

The tests of `Editor/Themes.lean`: `themeChecks`, through the headless host. The
root module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- What compiled code hands the hosts of the theme checks: the command that
loads a theme and the themes that ship (`Editor/Themes/Compiled.lean`), and
the minibuffer's commands and its mode, which its prompt is answered with. -/
def themeCompiled : Compiled :=
  { commands := Themes.commands ++ Minibuffer.commands, modes := Minibuffer.modes
    themes := Themes.shipped }

/-- The face `default` of the theme `second` the theme checks' config
defines: a background of its own. -/
def secondDefault : Face :=
  { background := some (Color.rgb 0 90 0) }

/-- The face `keyword` the theme checks' config sets. -/
def keywordFace : Face :=
  { foreground := some (Color.rgb 200 0 0) }

/-- The checks of named themes through a host: a config directory of real
files, the real elaborator, the display's real binding and the library's
layout. As in `faceChecks`, a frame is compared with the frame a second
display, handed the same themes in the same order, lays out of the same
scene in a theme written here. -/
def themeChecks (context : Context) : List Check :=
  [{  name :=
        "criteria 3 and 4: the theme command switches the theme the display draws in with no reload, to the frame the chosen theme followed by config's own face gives, and the scene line names the theme it was drawn in"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory
              [("10-themes.lean",
                  "def setup : SetupM Unit := do\n  defineTheme \"second\" #[{ name := ⟨\"default\"⟩, face := { background := some (Color.rgb 0 90 0) } }]\n  face \"keyword\" { foreground := some (Color.rgb 200 0 0) }\n")]
          let configured : Theme := #[{ name := ⟨"keyword"⟩, face := keywordFace }]
          let stage ←
            Stage.new context context.elaborator (Config.Directory.source directory) themeCompiled
          let library ← Ffi.Display.newCells 8 16
          let made ← IO.mkRef (none : Option Headless.Host.Display)
          let collaborators :=
            { stage.collaborators with
              display := fun snapshots => do
                let display ←
                  Headless.Host.Display.real (← RealDisplay.over library snapshots Theme.builtin)
                made.set (some display)
                return display }
          let mirror ←
            RealDisplay.over (← Ffi.Display.newCells 8 16) collaborators.published.reader
                Theme.builtin
          onStage { stage with collaborators } fun host _ => do
              let holds (parts : List (String × Bool)) : IO Unit := do
                if let some (part, _) := parts.find? (!·.2) then
                  throw (IO.userError part)
              let settled : IO Unit := do
                unless ← host.settle patience do
                  throw (IO.userError "the editor thread did not settle")
              let frames (theme : Theme) : IO (String × String) := do
                let some display ← made.get | throw (IO.userError "the host made no display")
                let some scene ← display.last? | throw (IO.userError "the host published no scene")
                mirror.setTheme theme
                mirror.publish scene
                return (← library.frameText, ← mirror.display.frameText)
              let sceneLine : IO String := do
                host.send .scene
                settled
                return ((← stage.output.get).filter (·.startsWith "scene ")).back?.getD ""
              host.send .reload
              settled
              host.resize 160 96
              unless ← Event.post (.commit "let x = 1") do
                return false
              settled
              let (plain, plainMirror) ← frames (Theme.builtin ++ configured)
              let before ← sceneLine
              host.send (.run Themes.loadName)
              settled
              unless ← Event.post (.commit "second") do
                return false
              for key in acceptKeys do
                host.press key
              settled
              let (switched, switchedMirror) ←
                frames (#[{ name := ⟨"default"⟩, face := secondDefault }] ++ configured)
              let after ← sceneLine
              let lines ← stage.output.get
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
                        #["reload 1: installed, 1 chunks, 0 commands"])]
              return true },
    { name :=
        "criterion 6: a config that names a theme nobody registered says so in the echo area, naming the theme, before the frame is made and after, and its report says so; the theme in force stays"
      run :=
        withHost context
          [("10-themes.lean", "def setup : SetupM Unit := do\n  useTheme \"nope\"\n")] (compiled :=
          themeCompiled) fun session => do
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
              scene.endsWith ", theme \"default\"" }]

end ConfigTest
