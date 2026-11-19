import Editor.Appearance
import Editor.Compile.Contribution
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
import Editor.Setup
import Editor.TabBar
import Editor.Themes.Compiled
import Editor.Themes.FairyFloss
import Editor.Themes.Shipped
import Editor.Themes.Solarized
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

/-- The reload reducer's state with the shipped themes registered, the
built-in theme in force, and nothing loaded. -/
def shippedThemes : Config.State Elaborated :=
  {
    registry :=
      ({} : Config.Registry).replaceThemes .compiled
        (#[Themes.defaultTheme] ++ Themes.Shipped.themes) }

/-- The effects of each of `events` from `state`, one array an event, and the
state reached. -/
def effectsOf (state : Config.State Elaborated) (events : List (Config.Event Elaborated)) :
    Config.State Elaborated × List (Array Seen) :=
  events.foldl
    (fun (state, effects) event =>
      let (state, more) := Config.step state event
      (state, effects ++ [more.map seen]))
    (state, [])

/-- The colour `0xRRGGBB`, opaque. -/
def hex (word : UInt32) : Color :=
  { word := word <<< 8 ||| 0xFF }

/-- The checks of the window's appearance (`Editor/Appearance.lean`, and the
reload reducer's `State.ask`, `Editor/Config/Reload.lean`): which papers
are light and which dark, and when the reducer asks the window for one. -/
def appearanceChecks : List Check :=
  [{  name :=
        "a paper is dark exactly when white text contrasts with it more than black: white and Solarized light's paper are light, black, the built-in paper, Solarized dark's and fairy-floss's are dark, and #757575 is dark and #767676 light, either side of the crossover"
      run :=
        let paper (theme : Theme) : Option Appearance := theme.paper.map Appearance.ofPaper
        pure
          (Appearance.ofPaper (hex 0xFFFFFF) == .light &&
            Appearance.ofPaper (hex 0x000000) == .dark &&
            paper Theme.builtin == some .dark &&
            paper Themes.Solarized.dark.theme == some .dark &&
            paper Themes.Solarized.light.theme == some .light &&
            paper Themes.FairyFloss.fairyFloss.theme == some .dark &&
            Appearance.ofPaper (hex 0x757575) == .dark &&
            Appearance.ofPaper (hex 0x767676) == .light &&
            (hex 0x757575).luminance < 0.1791 &&
            (hex 0x767676).luminance > 0.1791 &&
            (hex 0xFFFFFF).luminance > 0.999 &&
            (hex 0x000000).luminance == 0 &&
            (Theme.paper #[]).isNone) },
    { name :=
        "criterion 2: the window is asked for the paper's appearance when it opens, and then once per change: choosing solarized-light asks light, again asks nothing, solarized-dark asks dark, fairy-floss nothing (dark again), solarized-light light; a choice before the window opened asks nothing, and a window that opens again is asked afresh"
      run :=
        let (_, before) := effectsOf shippedThemes [.choose "solarized-light"]
        let (_, effects) :=
          effectsOf shippedThemes
            [.windowOpened, .choose "solarized-light", .choose "solarized-light",
              .choose "solarized-dark", .choose "fairy-floss", .choose "solarized-light",
              .windowOpened]
        pure
          (before == [#[.themed]] &&
            effects ==
              [#[.appearance .dark], #[.themed, .appearance .light], #[.themed],
                #[.themed, .appearance .dark], #[.themed], #[.themed, .appearance .light],
                #[.appearance .light]]) },
    { name :=
        "criterion 3: with solarized-light in force and the window open, a reload whose config sets the default face's paper to #002b36 keeps solarized-light in force and asks for dark after its report; the same reload again asks nothing; and from solarized-light, a reload that sets only the default face's ink, one that sets nothing, and a refused one ask nothing"
      run :=
        let (light, opened) := effectsOf shippedThemes [.windowOpened, .choose "solarized-light"]
        let darkPaper : SetupM Unit := face "default" { background := some (hex 0x002b36) }
        let inkOnly : SetupM Unit := face "default" { foreground := some (hex 0x002b36) }
        let (overridden, reloads) :=
          effectsOf light
            [.requested, .finished (accepted ["a"] darkPaper), .requested,
              .finished (accepted ["a"] darkPaper)]
        let reloadOf (setup : SetupM Unit) : List (Array Seen) :=
          (effectsOf light [.requested, .finished (accepted ["a"] setup)]).2
        let (_, refused) := effectsOf light [.requested, .finished (rejected "a")]
        pure
          (opened == [#[.appearance .dark], #[.themed, .appearance .light]] &&
            overridden.themeName == "solarized-light" &&
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
