import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.Candidate
import Editor.Completion.Style
import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Event
import Editor.InputScheme
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Keymap
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.TabCommands
import Editor.TabCommands.Compiled
import Editor.Test.Completion
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Windows

/-!
# Model tests: `Editor/TabCommands.lean`

The model tests of `Editor/TabCommands.lean`: `tabCommandChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The windows of each tab of `state`, as indices, in order. -/
def tabOrder (state : EditorState) : List (List Nat) :=
  state.frame.tabs.toList.map fun tab => tab.windows.toList.map (·.index)

/-- A style written for the tab checks, `every-part`, not one that ships:
it keeps the candidates that hold every space-separated part of the text as
a run of their characters, in their order, with no ranges. -/
def everyPart : Completion.Style :=
  .keeping "every-part" fun text candidate =>
    (text.splitOn " ").all fun part => part.isEmpty || (candidate.splitOn part).length > 1

/-- The checks of the tab commands (`Editor/TabCommands.lean`), by key, on
the loop's driver over the editor's models, under the Vim scheme that
ships with the tab commands handed: tmux's keys under `C-w`, the refusals
in the echo area, the prompts of `tab-switch` and `tab-rename`, and that
each command acts on the tab of its call's window. -/
def tabCommandChecks : List Check :=
  let delivered (driver : EvilDriver) (command : EditorM Unit) : EvilDriver :=
    (driver.stepped (driver.loop.deliver driver.handed "tab" command)).1
  let state (driver : Option EvilDriver) : Option EditorState := driver.map (·.loop.state)
  [{  name := "C-w c makes a tab after the one in view, on the same buffer, and selects it"
      run :=
        pure <|
          match state (tabsAfter "C-w c") with
          | some after =>
            after.frame.tabs.size == 2 && after.frame.tabIndex == 1 &&
              tabOrder after == [[0], [1]] &&
              after.frame.focused == ⟨1⟩ &&
              (after.window? ⟨1⟩).map (·.buffer) == some ⟨0⟩ &&
              after.wellFormed
          | none => false },
    { name :=
        "C-w n and C-w p go to the next and the previous tab, wrapping, and with a count C-w n goes to the tab of that number"
      run :=
        pure <|
          match state (tabsAfter "C-w c C-w c C-w n"), state (tabsAfter "C-w c C-w c C-w n C-w p"),
            state (tabsAfter "C-w c C-w c C-w p C-w p"),
            state (tabsAfter "C-w c C-w c C-w n 3 C-w n") with
          | some wrapped, some back, some twice, some counted =>
            wrapped.frame.tabIndex == 0 && back.frame.tabIndex == 2 && twice.frame.tabIndex == 0 &&
              counted.frame.tabIndex == 2
          | _, _, _, _ => false },
    { name := "C-w 2 selects tab 2, and C-w 5 says there is no tab 5"
      run :=
        pure <|
          match state (tabsAfter "C-w c C-w 1 C-w 2"), state (tabsAfter "C-w c C-w 1 C-w 5") with
          | some second, some missing =>
            second.frame.tabIndex == 1 && missing.frame.tabIndex == 0 &&
              missing.echo == s!"{TabCommands.selectName 5}: {(LayoutRefusal.noSuchTab 4).describe}"
          | _, _ => false },
    { name :=
        "criterion 3: C-w & with one tab says the last tab cannot be closed and leaves the state; with two it closes the tab in view and its window"
      run :=
        pure <|
          match tabsAfter "", state (tabsAfter "C-w &"), state (tabsAfter "C-w c C-w &") with
          | some start, some refused, some closed =>
            refused.echo == s!"{TabCommands.closeName}: {LayoutRefusal.onlyTab.describe}" &&
              refused.frame == start.loop.state.frame &&
              refused.windows == start.loop.state.windows &&
              closed.frame.tabs.size == 1 &&
              tabOrder closed == [[0]] &&
              (closed.window? ⟨1⟩).isNone &&
              closed.wellFormed
          | _, _, _ => false },
    { name :=
        "C-w w asks for a tab, labelled Tab:, with a candidate of number and label for every tab; typing 2 and accepting selects tab 2, and a name that matches nothing says so"
      run :=
        pure <|
          match tabsAfter "C-w c C-w p C-w w", state (tabsAfter "C-w c C-w p C-w w 2 RET"),
            state (tabsAfter "C-w c C-w p C-w w z q RET") with
          | some asking, some chosen, some missed =>
            asking.loop.state.prompt.map (·.label) == some TabCommands.switchPrompt &&
              asking.loop.state.prompt.map (·.candidates.all.map (·.text)) ==
                some #["1 scratch", "2 scratch"] &&
              chosen.frame.tabIndex == 1 &&
              chosen.prompt.isNone &&
              missed.frame.tabIndex == 0 &&
              missed.echo == TabCommands.noMatch "zq"
          | _, _, _ => false },
    { name :=
        "C-w w resolves an answer as a candidate exactly, then the first tab whose label it is, then a number of a tab, then the fuzzy matcher's best candidate: from tab 1, a label notes, a candidate 2 scratch, a near miss nots, a label 1 over the number 1, and a candidate 2 scratch over tab 1's label 2 scratch each select tab 2"
      run :=
        pure <|
          -- Each answer is typed in tab 1, so a selection of tab 2 is the
          -- answer's doing; where two branches disagree, the earlier one
          -- names tab 2 and the later one tab 1.
          match state (tabsAfter "C-w c C-c r n o t e s RET C-w p C-w w n o t e s RET"),
            state (tabsAfter "C-w c C-w p C-w w 2 SPC s c r a t c h RET"),
            state (tabsAfter "C-w c C-c r n o t e s RET C-w p C-w w n o t s RET"),
            state (tabsAfter "C-w c C-c r 1 RET C-w p C-w w 1 RET"),
            state
              (tabsAfter
                "C-w c C-w p C-c r 2 SPC s c r a t c h RET C-w w 2 SPC s c r a t c h RET") with
          | some labelled, some exact, some fuzzy, some labelOverNumber, some exactOverLabel =>
            labelled.frame.tabIndex == 1 && exact.frame.tabIndex == 1 &&
              fuzzy.frame.tabIndex == 1 &&
              labelOverNumber.tabLabel 1 == "1" &&
              labelOverNumber.frame.tabIndex == 1 &&
              exactOverLabel.tabLabel 0 == "2 scratch" &&
              exactOverLabel.frame.tabIndex == 1 &&
              [labelled, exact, fuzzy, labelOverNumber, exactOverLabel].all (·.prompt.isNone)
          | _, _, _, _, _ => false },
    { name :=
        "with a style chosen for the category tab that keeps the candidates holding every space-separated part of the text, a typed text that is no candidate, label or number selects the first tab the prompt lists for it: from tab 1, scratch 2, which the fuzzy matcher matches with no candidate, lists 2 scratch alone and selects tab 2"
      run :=
        pure <|
          let handed : Loop.Keys Vim.Default.scheme :=
            { tabHanded with
              matching :=
                { default := .unregistered
                  byCategory := fun category =>
                    if category == TabCommands.source.category then some everyPart else none } }
          let after (typed : String) : Option EvilDriver :=
            (windowDriver 1 Layout.default (handed := handed)).map (evilFed · typed)
          let typed := "C-w c C-w p C-w w s c r a t c h SPC 2"
          match after typed, state (after (typed ++ " RET")) with
          | some asking, some chosen =>
            asking.loop.state.prompt.map (·.candidates.listed.map (·.text)) ==
                some #["2 scratch"] &&
              styled .unregistered "scratch 2" #["1 scratch", "2 scratch"] == #[] &&
              chosen.frame.tabIndex == 1 &&
              chosen.prompt.isNone
          | _, _ => false },
    { name :=
        "tab-rename asks for a name, labelled Rename tab:, and names the tab of its window; an empty answer goes back to the generated label, its focused window's buffer's name"
      run :=
        pure <|
          match tabsAfter "C-c r", state (tabsAfter "C-c r n o t e s RET"),
            state (tabsAfter "C-c r n o t e s RET C-c r C-u RET") with
          | some asking, some named, some back =>
            asking.loop.state.prompt.map (·.label) == some TabCommands.renamePrompt &&
              named.frame.name == some "notes" &&
              named.tabLabel 0 == "notes" &&
              back.frame.name == none &&
              back.tabLabel 0 == "scratch"
          | _, _, _ => false },
    { name :=
        "tab-move-right and tab-move-left move the tab of their window one place, clamped at the ends, and it stays in view"
      run :=
        pure <|
          match state (tabsAfter "C-w c C-w c C-w 1 C-c m"),
            state (tabsAfter "C-w c C-w c C-w 1 C-c m C-c m C-c m"),
            state (tabsAfter "C-w c C-w c C-w 1 C-c M"), state (tabsAfter "C-w c C-w c C-c M") with
          | some right, some clamped, some still, some left =>
            -- The tab bar's view took the id 2 at the publish after the first
            -- C-w c, so the third tab's window is 3.
            tabOrder right == [[1], [0], [3]] && right.frame.tabIndex == 1 &&
              tabOrder clamped == [[1], [3], [0]] &&
              clamped.frame.tabIndex == 2 &&
              tabOrder still == [[0], [1], [3]] &&
              tabOrder left == [[0], [3], [1]] &&
              left.frame.tabIndex == 1
          | _, _, _, _ => false },
    { name :=
        "criterion 1 by key: after C-w s C-w c C-w s C-w z C-w p the first tab's windows, focus and layout are as they were before C-w c, and its rectangles too in the area the tab bar leaves, and after C-w n the second tab is zoomed with its focus where it was left"
      run :=
        pure <|
          match state (tabsAfter "C-w s"), state (tabsAfter "C-w s C-w c C-w s C-w z"),
            state (tabsAfter "C-w s C-w c C-w s C-w z C-w p"),
            state (tabsAfter "C-w s C-w c C-w s C-w z C-w p C-w n") with
          | some split, some zoomed, some first, some second =>
            windowOrder first == windowOrder split && first.frame.toTab == split.frame.toTab &&
              windowRects first == windowRects { split with tabBarShown := .always } &&
              first.frame.tabIndex == 0 &&
              second.frame.tabIndex == 1 &&
              second.frame.layout == .monocle &&
              windowOrder second == windowOrder zoomed &&
              second.frame.toTab == zoomed.frame.toTab
          | _, _, _, _ => false },
    { name :=
        "each tab command acts on the tab of its call's window, not on the tab in view: run on a hidden tab's window, tab-close closes that tab, tab-rename names it, tab-move-left moves it, tab-next selects the tab after it and tab-new opens a tab after it"
      run :=
        pure <|
          match tabsAfter "C-w c C-w c C-w 1" with
          | none => false
          | some driver =>
            let onView (view : Nat) (name : String) (arguments : List Argument := []) :
              EditorM Unit := do
              let some target := (← editorState).target? ⟨view⟩ | giveUp "no window"
              discard <| runCommand name { target, arguments }
            -- The tab bar's view took the id 2 at the publish after the first
            -- C-w c, so the third tab's window is 3, and a new one is 4.
            let closed := delivered driver (onView 3 TabCommands.closeName)
            let renamed := delivered driver (onView 1 TabCommands.renameName [.str "far"])
            let moved := delivered driver (onView 3 TabCommands.moveLeftName)
            let next := delivered driver (onView 1 TabCommands.nextName)
            let made := delivered driver (onView 1 TabCommands.newName)
            tabOrder closed.loop.state == [[0], [1]] && closed.loop.state.frame.tabIndex == 0 &&
              renamed.loop.state.frame.tabs.map (·.name) == #[none, some "far", none] &&
              tabOrder moved.loop.state == [[0], [3], [1]] &&
              moved.loop.state.frame.tabIndex == 0 &&
              next.loop.state.frame.tabIndex == 2 &&
              tabOrder made.loop.state == [[0], [1], [4], [3]] &&
              made.loop.state.frame.tabIndex == 2 &&
              made.loop.state.frame.focused == ⟨4⟩ &&
              [closed, renamed, moved, next, made].all (·.loop.state.wellFormed) },
    { name :=
        "criterion 2 in the loop: a publish handed another layout rearranges the tab in view only; after C-w p a publish handed the same layout keeps the first tab under its own; C-w c then makes a tab under it"
      run :=
        pure <|
          match tabsAfter "C-w s C-w c C-w s" with
          | none => false
          | some driver =>
            let chosen := evilFed { driver with keys := tabHanded .monocle } "<Escape>"
            let back := evilFed chosen "C-w p <Escape>"
            let made := evilFed back "C-w c"
            let before := driver.loop.state.frame
            chosen.loop.state.frame.tabIndex == 1 && chosen.loop.state.frame.layout == .monocle &&
              chosen.loop.state.frame.windows == before.windows &&
              chosen.loop.state.frame.tabsBefore == before.tabsBefore &&
              back.loop.state.frame.tabIndex == 0 &&
              back.loop.state.frame.layout == Layout.default &&
              back.loop.state.frame.windows == before.tabsBefore.flatMap (·.windows) &&
              made.loop.state.frame.tabIndex == 1 &&
              made.loop.state.frame.layout == .monocle &&
              [chosen, back, made].all (·.loop.state.wellFormed) },
    { name :=
        "the tab-commands package registers the commands TabCommands.names lists, in that order, and no other"
      run :=
        pure
          ((TabCommands.package.registered.commands.map (·.name)).toList == TabCommands.names &&
            TabCommands.names.contains (TabCommands.selectName 9)) }]

end ModelTest
