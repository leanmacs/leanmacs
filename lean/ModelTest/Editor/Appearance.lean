import Editor.Appearance
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Config.Session
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Face
import Editor.Layout
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Program
import Editor.ProjectMode
import Editor.Setup
import Editor.TabBar
import Editor.Themes.Compiled
import Editor.Window
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Elaborator

/-!
# Model tests: `Editor/Appearance.lean`

The model tests of `Editor/Appearance.lean`: `appearanceChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The colour `0xRRGGBB`, opaque. -/
def hex (word : UInt32) : Color :=
  { word := word <<< 8 ||| 0xFF }

/-- A fixture theme named `name` whose one definition is the default
face's, with the paper `paper`: all the appearance reads of a theme. -/
def paperTheme (name : String) (paper : Color) : NamedTheme :=
  { name, theme := #[{ name := ⟨"default"⟩, face := { background := some paper } }] }

/-- The fixture themes of the appearance checks, under names no package
registers: `fixture-dark` and `fixture-dusk`, whose papers are dark, and
`fixture-light`, whose paper is light. -/
def appearanceThemes : Array NamedTheme :=
  #[paperTheme "fixture-dark" (hex 0x14181C), paperTheme "fixture-light" (hex 0xFAF8F0),
    paperTheme "fixture-dusk" (hex 0x3A3048)]

/-- The reload reducer's state with the built-in theme and the fixture
themes (`appearanceThemes`) registered, the built-in theme in force, and
nothing loaded. -/
def themedState : Config.State Elaborated :=
  {
    registry :=
      ({} : Config.Registry).replaceThemes .compiled (#[Themes.defaultTheme] ++ appearanceThemes) }

/-- The effects of each of `events` from `state`, one array an event, and the
state reached. -/
def effectsOf (state : Config.State Elaborated) (events : List (Config.Event Elaborated)) :
    Config.State Elaborated × List (Array Seen) :=
  events.foldl
    (fun (state, effects) event =>
      let (state, more) := Config.step state event
      (state, effects ++ [more.map seen]))
    (state, [])

/-- The checks of the window's appearance (`Editor/Appearance.lean`, and the
reload reducer's `State.ask`, `Editor/Config/Reload.lean`): which papers
are light and which dark, and when the reducer asks the window for one. -/
def appearanceChecks : List Check :=
  [{  name :=
        "a paper is dark exactly when white text contrasts with it more than black: white and fixture-light's paper are light, black, the built-in paper, fixture-dark's and fixture-dusk's are dark, and #757575 is dark and #767676 light, either side of the crossover"
      run :=
        let paper (theme : Theme) : Option Appearance := theme.paper.map Appearance.ofPaper
        pure
          (Appearance.ofPaper (hex 0xFFFFFF) == .light &&
            Appearance.ofPaper (hex 0x000000) == .dark &&
            paper Theme.builtin == some .dark &&
            appearanceThemes.map (fun named => paper named.theme) ==
              #[some .dark, some .light, some .dark] &&
            Appearance.ofPaper (hex 0x757575) == .dark &&
            Appearance.ofPaper (hex 0x767676) == .light &&
            (hex 0x757575).luminance < 0.1791 &&
            (hex 0x767676).luminance > 0.1791 &&
            (hex 0xFFFFFF).luminance > 0.999 &&
            (hex 0x000000).luminance == 0 &&
            (Theme.paper #[]).isNone) },
    { name :=
        "criterion 2: the window is asked for the paper's appearance when it opens, and then once per change: choosing fixture-light asks light, again asks nothing, fixture-dark asks dark, fixture-dusk nothing (dark again), fixture-light light; a choice before the window opened asks nothing, and a window that opens again is asked afresh"
      run :=
        let (_, before) := effectsOf themedState [.choose "fixture-light"]
        let (_, effects) :=
          effectsOf themedState
            [.windowOpened, .choose "fixture-light", .choose "fixture-light",
              .choose "fixture-dark", .choose "fixture-dusk", .choose "fixture-light",
              .windowOpened]
        pure
          (before == [#[.themed]] &&
            effects ==
              [#[.appearance .dark], #[.themed, .appearance .light], #[.themed],
                #[.themed, .appearance .dark], #[.themed], #[.themed, .appearance .light],
                #[.appearance .light]]) },
    { name :=
        "criterion 3: with fixture-light in force and the window open, a reload whose config sets the default face's paper to #101418 keeps fixture-light in force and asks for dark after its report; the same reload again asks nothing; and from fixture-light, a reload that sets only the default face's ink, one that sets nothing, and a refused one ask nothing"
      run :=
        let (light, opened) := effectsOf themedState [.windowOpened, .choose "fixture-light"]
        let darkPaper : SetupM Unit := face "default" { background := some (hex 0x101418) }
        let inkOnly : SetupM Unit := face "default" { foreground := some (hex 0x101418) }
        let (overridden, reloads) :=
          effectsOf light
            [.requested, .finished (accepted ["a"] darkPaper), .requested,
              .finished (accepted ["a"] darkPaper)]
        let reloadOf (setup : SetupM Unit) : List (Array Seen) :=
          (effectsOf light [.requested, .finished (accepted ["a"] setup)]).2
        let (_, refused) := effectsOf light [.requested, .finished (rejected "a")]
        pure
          (opened == [#[.appearance .dark], #[.themed, .appearance .light]] &&
            overridden.themeName == "fixture-light" &&
            reloads ==
              [#[.start none #[]],
                #[.cancelJobs "config", .report 1 true #[] 1 0, .appearance .dark],
                #[.start (some #[]) #["a"]], #[.cancelJobs "config", .report 2 true #[] 1 0]] &&
            reloadOf inkOnly ==
              [#[.start none #[]], #[.cancelJobs "config", .report 1 true #[] 1 0]] &&
            reloadOf (pure ()) ==
              [#[.start none #[]], #[.cancelJobs "config", .report 1 true #[] 1 0]] &&
            refused == [#[.start none #[]], #[.report 1 false #["a"] 0 0]]) }]

end ModelTest
