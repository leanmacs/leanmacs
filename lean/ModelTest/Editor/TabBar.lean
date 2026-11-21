import Editor.Command.Model
import Editor.Display
import Editor.Display.Model
import Editor.Floating
import Editor.GeneratedView
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Keymap
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.States
import Editor.Test.Views
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Windows

/-!
# Model tests: `Editor/TabBar.lean`

The model tests of `Editor/TabBar.lean`: `tabBarChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of the tab bar (`Editor/TabBar.lean`): the line it shows,
its strip above the minibuffer's (`EditorState.tabBarRect?`), and, on the
loop's driver over the editor's models, the view a publish draws it in. -/
def tabBarChecks : List Check :=
  let rect (x y width height : Nat) : Rect := { x, y, width, height }
  let chip (start stop : Nat) (selected : Bool := false) : Decoration :=
    { start, stop, face := if selected then TabBar.selectedFace else TabBar.face }
  let withTabs (state : EditorState) (count : Nat) : EditorState :=
    { state with
      frame :=
        { state.frame with
          tabsAfter :=
            (Array.range (count - 1)).map fun _ => { windows := #[⟨0⟩], focused := ⟨0⟩ } } }
  [{  name :=
        "the line lists every tab as a chip of its number and label, joined by a space, each chip's bytes in the tab bar's face and the selected one's in its own; a label of several bytes a character is counted in bytes"
      run :=
        pure <|
          TabBar.line #["scratch"] 0 == (" 1 scratch ", #[chip 0 11 true]) &&
            TabBar.line #["scratch", "scratch"] 1 ==
              (" 1 scratch   2 scratch ", #[chip 0 11, chip 12 23 true]) &&
            TabBar.line #["scratch", "scratch"] 0 ==
              (" 1 scratch   2 scratch ", #[chip 0 11 true, chip 12 23]) &&
            TabBar.line #["a", "b", "c"] 0 ==
              (" 1 a   2 b   3 c ", #[chip 0 5 true, chip 6 11, chip 12 17]) &&
            TabBar.line #["a", "b", "c"] 1 ==
              (" 1 a   2 b   3 c ", #[chip 0 5, chip 6 11 true, chip 12 17]) &&
            TabBar.line #["a", "b", "c"] 2 ==
              (" 1 a   2 b   3 c ", #[chip 0 5, chip 6 11, chip 12 17 true]) &&
            TabBar.line #["é", "b"] 0 == (" 1 é   2 b ", #[chip 0 6 true, chip 7 12]) },
    { name :=
        "the tab bar's strip is a text row above the minibuffer's, cut from the tiled area, shown with two tabs or more by default: at 640 by 480 the tiled area is 640 by 448 and the bar 0,448 640 by 16; with a prompt open it sits above the minibuffer's taller strip; with one tab there is none and the tiled area is 640 by 464; always shows it with one tab, and never shows none with three"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some one =>
            let two := withTabs one 2
            let (_, asking) := prompted two
            let three := withTabs one 3
            two.tiled == rect 0 0 640 448 && two.tabBarRect? == some (rect 0 448 640 16) &&
              two.cutFrame.2 == rect 0 464 640 16 &&
              asking.tabBarRect? == some (rect 0 432 640 16) &&
              asking.cutFrame.2 == rect 0 448 640 32 &&
              asking.tiled == rect 0 0 640 432 &&
              one.tabBarRect? == none &&
              one.tiled == rect 0 0 640 464 &&
              { one with tabBarShown := .always }.tabBarRect? == some (rect 0 448 640 16) &&
              { three with tabBarShown := .never }.tabBarRect? == none &&
              { three with tabBarShown := .never }.tiled == rect 0 0 640 464 },
    { name :=
        "with a prompt that lists candidates and two tabs, the tab bar's strip lies directly above the list's, and the list's directly above the minibuffer's view"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some one =>
            let (_, asking) := prompted (withTabs one 2)
            let listing := (listingIn asking #["a", "b", "c"] #[0, 1, 2]).displayed .unregistered
            match listing.tabBarRect?, listing.candidateListRect?,
              listing.minibufferView?.bind listing.rect? with
            | some bar, some list, some minibuffer =>
              bar.y + bar.height == list.y && list.y + list.height == minibuffer.y &&
                list.height == 3 * listing.heights.text &&
                listing.tiled.y + listing.tiled.height == bar.y
            | _, _, _ => false },
    { name :=
        "a frame shorter than the two strips is clamped: the minibuffer's strip first, then the bar in what is left, and none when nothing is"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 20⟩),
            onTextModel (EditorState.initial ⟨640, 10⟩) with
          | some short, some shorter =>
            let short := withTabs short 2
            let shorter := withTabs shorter 2
            short.tiled.height == 0 && short.tabBarRect? == some (rect 0 0 640 4) &&
              short.cutFrame.2 == rect 0 4 640 16 &&
              shorter.tabBarRect? == none &&
              shorter.tiled.height == 0
          | _, _ => false },
    { name :=
        "a float anchored to the frame is centred in the tiled area the bar leaves, and no float meets the bar's strip"
      run :=
        pure <|
          match
            onTextModel do
              let state ← EditorState.initial ⟨640, 480⟩
              withFloats state [(.frame, false)] with
          | none => false
          | some state =>
            let two := withTabs state 2
            two.rect? ⟨1⟩ == some (Floating.centred {} (rect 0 0 640 448)) &&
              (two.rect? ⟨1⟩).any (fun float => float.y + float.height ≤ 448) },
    { name :=
        "criterion 5, in the loop: after C-w c the last view of the scene is the tab bar, its text the line of both tabs with the second's chip selected, in the bar's strip, padded across by the frame padding and not down, with no selection and no status field; after C-w p the chips' faces swap, the bar keeps its view, and the snapshot of the old line is released; it is never the focused view; after C-w & there is no bar and the tiled area is whole again"
      run :=
        pure <|
          let handed : Loop.Keys Vim.Default.scheme :=
            { tabHanded Layout.default with padding := 8 }
          match (windowDriver 1 Layout.default (handed := handed)).map (evilFed · "C-w c") with
          | none => false
          | some tabbed =>
            let back := evilFed tabbed "C-w p"
            let closed := evilFed back "C-w &"
            let barOf (driver : EvilDriver) : Option View :=
              driver.model.display.scenes.back?.bind fun scene =>
                scene.views.back?.bind fun view =>
                  if driver.loop.state.tabBar.any (·.view == view.id) then some view else none
            let focused (driver : EvilDriver) : Option ViewId :=
              driver.model.display.scenes.back?.bind (·.focused)
            match barOf tabbed, barOf back with
            | some bar, some again =>
              shownText tabbed.model bar == some " 1 scratch   2 scratch " &&
                bar.decorations == #[chip 0 11, chip 12 23 true] &&
                bar.rect == rect 0 448 640 16 &&
                bar.padding == { across := 8, down := 0 } &&
                bar.selections.isEmpty &&
                bar.status.isEmpty &&
                focused tabbed == some ⟨1⟩ &&
                again.id == bar.id &&
                again.decorations == #[chip 0 11 true, chip 12 23] &&
                shownText back.model again == some " 1 scratch   2 scratch " &&
                focused back == some ⟨0⟩ &&
                (bar.snapshot == again.snapshot || releasedSnapshot back bar.snapshot) &&
                barOf closed == none &&
                closed.loop.state.tiled == rect 0 0 640 464 &&
                [tabbed, back, closed].all (·.loop.state.wellFormed)
            | _, _ => false },
    { name :=
        "renaming a tab changes the bar's line, and the snapshot of the line before is released"
      run :=
        pure <|
          match tabsAfter "C-w c" with
          | none => false
          | some tabbed =>
            let named := evilFed tabbed "C-c r n RET"
            let barOf (driver : EvilDriver) : Option View :=
              driver.model.display.scenes.back?.bind (·.views.back?)
            match barOf tabbed, barOf named with
            | some bar, some again =>
              shownText named.model again == some " 1 scratch   2 n " && again.id == bar.id &&
                bar.snapshot != again.snapshot &&
                releasedSnapshot named bar.snapshot
            | _, _ => false },
    { name :=
        "a loop handed never shows no bar with two tabs, and the tiled area is whole; handed always it shows one with one tab; handed none it keeps the state's, never or always as an earlier publish left it"
      run :=
        pure <|
          let handed (shown : Option TabBar.Shown) : Loop.Keys Vim.Default.scheme :=
            { tabHanded Layout.default with tabBar := shown }
          let barredDriver (shown : Option TabBar.Shown) (typed : String) : Option EvilDriver :=
            (windowDriver 1 Layout.default (handed := handed shown)).map (evilFed · typed)
          let barred (shown : Option TabBar.Shown) (typed : String) : Option EditorState :=
            (barredDriver shown typed).map (·.loop.state)
          -- Published once handed `shown`, then handed none.
          let kept (shown : TabBar.Shown) (typed : String) : Option EditorState :=
            (barredDriver (some shown) typed).map fun driver =>
              (evilFed { driver with keys := handed none } "<Escape>").loop.state
          match barred (some .never) "C-w c", barred (some .always) "<Escape>", kept .never "C-w c",
            kept .always "<Escape>" with
          | some never, some always, some keptNever, some keptAlways =>
            never.tabBarShown == .never && never.tabBarRect? == none &&
              never.tiled == rect 0 0 640 464 &&
              always.tabBarRect? == some (rect 0 448 640 16) &&
              keptNever.tabBarShown == .never &&
              keptNever.frame.tabs.size == 2 &&
              keptNever.tabBarRect? == none &&
              keptAlways.tabBarShown == .always &&
              keptAlways.frame.tabs.size == 1 &&
              keptAlways.tabBarRect? == some (rect 0 448 640 16)
          | _, _, _, _ => false }]

end ModelTest
