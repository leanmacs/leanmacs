import Editor.Api
import Editor.Buffers
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.File
import Editor.Floating
import Editor.InputScheme.Test
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Program
import Editor.ProjectMode
import Editor.Scene
import Editor.State
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Models
import Editor.Test.States
import Editor.Text
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Buffers

/-!
# Model tests: `Editor/DisplayRules.lean`

The model tests of `Editor/DisplayRules.lean`: `displayRuleChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of display rules (`Editor/DisplayRules.lean`): which rule a
buffer's facts choose, and which targets a layout lacks; and where a
buffer is displayed (`EditorState.displaying`). -/
def displayRuleChecks : List Check :=
  let facts : DisplayRule.Facts := { name := "notes", modes := ["text", "notes"], opener := "make" }
  [{  name :=
        "a rule matches when every field it sets holds: a mode is the buffer's major mode or any of its minor modes, a name is the buffer's exactly, and an opener is the command's that asked; a rule that sets none matches every buffer"
      run :=
        pure <|
          let rule (mode name opener : Option String) : DisplayRule :=
            { mode, name, opener, target := .stack }
          (rule (some "text") none none).matches facts &&
            (rule (some "notes") none none).matches facts &&
            !(rule (some "lisp") none none).matches facts &&
            (rule none (some "notes") none).matches facts &&
            !(rule none (some "note") none).matches facts &&
            (rule none none (some "make")).matches facts &&
            !(rule none none (some "list-buffers")).matches facts &&
            (rule (some "notes") (some "notes") (some "make")).matches facts &&
            !(rule (some "notes") (some "notes") (some "other")).matches facts &&
            (rule none none none).matches facts },
    { name :=
        "the first rule that matches is chosen, in order; with none matching the fallback is, which sends the buffer to the stack and focuses it"
      run :=
        pure <|
          let toLeft : DisplayRule := { mode := some "notes", target := .edge .left }
          let toMain : DisplayRule := { opener := some "make", target := .main, focus := false }
          let never : DisplayRule := { name := some "other", target := .focused }
          DisplayRule.choose #[never, toLeft, toMain] facts == toLeft &&
            DisplayRule.choose #[never, toMain, toLeft] facts == toMain &&
            DisplayRule.choose #[never] facts == DisplayRule.fallback &&
            DisplayRule.choose #[] facts == DisplayRule.fallback &&
            DisplayRule.fallback.target == .stack &&
            DisplayRule.fallback.focus },
    { name :=
        "a caller's default focus is the fallback's when no rule matches, and a rule that matches keeps its own focus"
      run :=
        pure <|
          let toMain : DisplayRule := { opener := some "make", target := .main }
          let never : DisplayRule := { name := some "other", target := .focused }
          DisplayRule.choose #[never] facts (focus := false) ==
              { DisplayRule.fallback with focus := false } &&
            DisplayRule.choose #[] facts (focus := false) == { target := .stack, focus := false } &&
            DisplayRule.choose #[never, toMain] facts (focus := false) == toMain &&
            DisplayRule.choose #[never] facts (focus := true) == DisplayRule.fallback },
    { name :=
        "a target is missing when the layout lacks it: an edge the layout has no edge at; the focused window, main, the stack, a float, pinned or not, and a new tab never are"
      run :=
        pure <|
          let edged := Layout.edge .left 25 Layout.default
          [Layout.default, edged, .monocle, Layout.manual].all
              (fun layout =>
                [DisplayTarget.focused, .main, .stack, .float, .float { width := 80 } true,
                      .newTab].all
                  (·.missing? layout == none)) &&
            (DisplayTarget.edge .left).missing? Layout.default == some (Layout.noEdge .left) &&
            (DisplayTarget.edge .left).missing? edged == none &&
            (DisplayTarget.edge .right).missing? edged == some (Layout.noEdge .right) },
    { name :=
        "a window of the frame that shows the buffer is used, a tile or a docked one, whatever the rules say; otherwise the rule's target decides: the focused window, main, a new window in the stack, or at an edge the layout has, else the stack, or a new float centred in the frame, of the rule's share, transient unless the rule pins it, or a new tab; the focus is the rule's"
      run :=
        pure <|
          match onTextModel twoBuffers,
            onTextModel (dockedUnder 1 [.left] (.edge .left 25 Layout.default)) with
          | some two, some docked =>
            let docked : EditorState :=
              { docked with
                buffers := two.buffers
                windows :=
                  docked.windows.map fun window =>
                    if window.id == ⟨1⟩ then { window with buffer := ⟨1⟩ } else window }
            let rule (target : DisplayTarget) (focus : Bool := true) : Array DisplayRule :=
              #[{ target, focus }]
            let fresh : EditorState :=
              { two with
                frame := { two.frame with windows := #[⟨0⟩] }
                windows := two.windows.filter (·.id == ⟨0⟩) }
            two.displaying (rule .main) ⟨1⟩ ⟨0⟩ "make" == (.shown ⟨1⟩, true) &&
              docked.displaying (rule .main false) ⟨1⟩ ⟨0⟩ "make" == (.shown ⟨1⟩, false) &&
              fresh.wellFormed &&
              fresh.displaying #[] ⟨1⟩ ⟨0⟩ "make" == (.opened .stack, true) &&
              fresh.displaying #[] ⟨1⟩ ⟨0⟩ "make" (focus := false) == (.opened .stack, false) &&
              fresh.displaying (rule .focused) ⟨1⟩ ⟨0⟩ "make" (focus := false) ==
                (.showIn ⟨0⟩, true) &&
              two.displaying #[] ⟨1⟩ ⟨0⟩ "make" (focus := false) == (.shown ⟨1⟩, false) &&
              fresh.displaying (rule .focused) ⟨1⟩ ⟨0⟩ "make" == (.showIn ⟨0⟩, true) &&
              fresh.displaying (rule .main false) ⟨1⟩ ⟨0⟩ "make" == (.showIn ⟨0⟩, false) &&
              fresh.displaying (rule .stack) ⟨1⟩ ⟨0⟩ "make" == (.opened .stack, true) &&
              fresh.displaying (rule (.edge .left)) ⟨1⟩ ⟨0⟩ "make" == (.opened .stack, true) &&
              fresh.displaying (rule .float) ⟨1⟩ ⟨0⟩ "make" ==
                (.opened (.float .frame {} false), true) &&
              fresh.displaying (rule (.float { width := 80, height := 70 } true) false) ⟨1⟩ ⟨0⟩
                  "make" ==
                (.opened (.float .frame { width := 80, height := 70 } true), false) &&
              fresh.displaying (rule .newTab) ⟨1⟩ ⟨0⟩ "make" == (.opened .tab, true) &&
              fresh.displaying (rule .newTab false) ⟨1⟩ ⟨0⟩ "make" == (.opened .tab, false) &&
              two.displaying (rule .newTab) ⟨1⟩ ⟨0⟩ "make" == (.shown ⟨1⟩, true) &&
              ({ fresh with
                        frame := { fresh.frame with layout := .edge .left 25 Layout.default } } :
                      EditorState).displaying
                  (rule (.edge .left)) ⟨1⟩ ⟨0⟩ "make" ==
                (.opened (.edge .left), true)
          | _, _ => false },
    { name :=
        "while zoomed, an edge target reads the layout zoom returns to, not monocle: a buffer goes to an edge that layout has, and to the stack at a side it has no edge at, or when it has none"
      run :=
        pure <|
          match onTextModel twoBuffers,
            onTextModel (dockedUnder 1 [.left] (.edge .left 25 Layout.default)),
            onTextModel (windowsUnder 1 Layout.default) with
          | some two, some docked, some plain =>
            -- Buffer 1 is in no window, so the rule decides.
            let zoomed (state : EditorState) : EditorState :=
              ({ state with buffers := two.buffers }.arrange ⟨0⟩ .zoom).2
            let edge (side : Side) : Array DisplayRule := #[{ target := .edge side }]
            (zoomed docked).frame.layout == .monocle && (zoomed docked).wellFormed &&
              (zoomed plain).frame.layout == .monocle &&
              (zoomed docked).displaying (edge .left) ⟨1⟩ ⟨0⟩ "make" ==
                (.opened (.edge .left), true) &&
              (zoomed docked).displaying (edge .right) ⟨1⟩ ⟨0⟩ "make" == (.opened .stack, true) &&
              (zoomed plain).displaying (edge .left) ⟨1⟩ ⟨0⟩ "make" == (.opened .stack, true)
          | _, _, _ => false },
    { name :=
        "the focused target, asked from the minibuffer's view, is the window the prompt was asked from, a tiled one or a docked one; asked from another window, that window"
      run :=
        pure <|
          match onTextModel sidebar with
          | none => false
          | some state =>
            let fromMain := (prompted state).2
            let fromSidebar := (prompted (state.focusWindow ⟨2⟩).2).2
            let minibuffer (asking : EditorState) : ViewId := asking.minibufferView?.getD ⟨9⟩
            let focused : Array DisplayRule := #[{ target := .focused }]
            -- No window shows buffer 9, so the rule decides.
            fromMain.shownIn (minibuffer fromMain) == ⟨0⟩ &&
              fromSidebar.shownIn (minibuffer fromSidebar) == ⟨2⟩ &&
              fromSidebar.shownIn ⟨1⟩ == ⟨1⟩ &&
              fromSidebar.shownIn (minibuffer fromSidebar) == ⟨2⟩ &&
              fromSidebar.displaying focused ⟨9⟩ (minibuffer fromSidebar) "e" ==
                (.showIn ⟨2⟩, true) },
    { name :=
        "displaying a buffer into an existing window by a rule focuses that window when the rule says so, and leaves the focus where it was when it does not: a rule for main, asked from the stack"
      run :=
        let displayed (focus : Bool) : EditorM (Option (Nat × Option BufferId × BufferId)) := do
          let state ← windowsUnder 2 Layout.default
          let (_, state) := state.focusWindow ⟨1⟩
          let program : EditorM (Except LayoutRefusal ViewId × BufferId) := do
            let .ok other ← createBuffer "other" "x" | throw .noSuchText
            return (← other.display ⟨1⟩ "make", other)
          match ← program.dispatched { displayRules := #[{ target := .main, focus }] } state with
          | (.finished (.ok view, other), after) =>
            if view == ⟨0⟩ && after.wellFormed then
              return some (after.frame.focused.index, (after.window? ⟨0⟩).map (·.buffer), other)
            else
              return none
          | _ =>
            return none
        pure <|
          match ((displayed true).runModel editorModel).1,
            ((displayed false).runModel editorModel).1 with
          | .ok (some (focusedTrue, shownTrue, otherTrue)),
            .ok (some (focusedFalse, shownFalse, otherFalse)) =>
            focusedTrue == 0 && shownTrue == some otherTrue && focusedFalse == 1 &&
              shownFalse == some otherFalse
          | _, _ => false },
    { name :=
        "criterion 1, in the model: with no rules, ls from main, which shows a file, leaves main on the file and shows the list in a new window at the end of the list, the stack, focused; ls from main again focuses that window and makes no third; a command that makes a buffer and displays it puts it in a new window at the end of the stack, and main still shows the file"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (listed, _) := fedTo opened (exLine "ls")
            let (again, _) := fedTo listed (presses "C-b f" ++ exLine "ls")
            let (noted, _) := fedTo again (presses "C-b f" ++ presses "C-b o")
            let state := listed.loop.state
            match state.frame.windows.toList, noted.loop.state.frame.windows.toList with
            | [main, list], [_, _, notes] =>
              main == ⟨0⟩ && shownName listed main == some "lf.txt" &&
                state.frame.focused == list &&
                shownName listed list == some Buffers.listBuffer &&
                (state.rect? main).map (·.width) == some 318 &&
                (state.rect? list).map (fun rect => (rect.x, rect.width)) == some (320, 320) &&
                again.loop.state.frame.windows == state.frame.windows &&
                again.loop.state.frame.focused == list &&
                noted.loop.state.frame.windows == state.frame.windows.push notes &&
                noted.loop.state.frame.focused == notes &&
                shownName noted notes == some "notes" &&
                shownName noted main == some "lf.txt" &&
                noted.loop.state.wellFormed
            | _, _ => false },
    { name :=
        "criterion 2, in the model: under a layout with a left edge, a rule that sends a mode's buffers to the left edge docks the buffer a command makes with that minor mode there, in the edge's strip of 25 percent, focused, and main still shows the file"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let ruled :=
              { opened with
                keys :=
                  { opened.keys with
                    layout := some (.edge .left 25 Layout.default)
                    registered :=
                      { opened.keys.registered with
                        displayRules := #[{ mode := some "notes", target := .edge .left }] } } }
            -- The first step publishes the layout config chose, as a reload
            -- does, before the command runs.
            let (noted, _) := fedTo ruled ([.preedit ""] ++ presses "C-b o")
            let state := noted.loop.state
            match state.frame.docked.toList with
            | [(notes, .left)] =>
              state.frame.windows == #[⟨0⟩] && state.frame.focused == notes &&
                shownName noted notes == some "notes" &&
                shownName noted ⟨0⟩ == some "lf.txt" &&
                (state.rect? notes).map (fun rect => (rect.x, rect.y, rect.width)) ==
                  some (0, 0, 158) &&
                (state.rect? ⟨0⟩).map (fun rect => (rect.x, rect.width)) == some (160, 480) &&
                state.wellFormed
            | _ => false },
    { name :=
        "criterion 2, in the model: a rule that sends what a command opens to a float shows the buffer the command makes in a new view, listed after view 0 in the scene, centred in the tiled area at 60 by 50 percent, focused, and main still shows the file"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let ruled :=
              { opened with
                keys :=
                  { opened.keys with
                    registered :=
                      { opened.keys.registered with
                        displayRules := #[{ opener := some "make-notes", target := .float }] } } }
            let (noted, _) := fedTo ruled (presses "C-b o")
            let state := noted.loop.state
            let tiled := state.tiled
            match state.frame.floats.toList, noted.model.display.scenes.back? with
            | [float], some scene =>
              let notes := float.view
              state.frame.windows == #[⟨0⟩] && state.frame.focused == notes &&
                float.anchor == .frame &&
                !float.pinned &&
                shownName noted notes == some "notes" &&
                shownName noted ⟨0⟩ == some "lf.txt" &&
                scene.views.map (·.id) == #[⟨0⟩, notes] &&
                (scene.views.find? (·.id == notes)).map (·.rect) ==
                  some (Floating.centred {} tiled) &&
                scene.focused == some notes &&
                state.wellFormed
            | _, _ => false },
    { name :=
        "criterion 6, in the model: a rule that sends what a command opens to a new tab shows the buffer the command makes in the only window of a second tab, which is in view and focused, and the first tab still shows the file; with the rule's focus off the first tab stays in view and the second is behind it"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let ruled (focus : Bool) : TestDriver :=
              { opened with
                keys :=
                  { opened.keys with
                    registered :=
                      { opened.keys.registered with
                        displayRules :=
                          #[{ opener := some "make-notes", target := .newTab, focus }] } } }
            let (noted, _) := fedTo (ruled true) (presses "C-b o")
            let (behind, _) := fedTo (ruled false) (presses "C-b o")
            let state := noted.loop.state
            let hidden := behind.loop.state
            match state.frame.windows.toList, hidden.frame.tabsAfter.toList with
            | [notes], [tab] =>
              state.frame.tabIndex == 1 && state.frame.focused == notes &&
                shownName noted notes == some "notes" &&
                state.frame.tabsBefore.map (·.windows) == #[#[⟨0⟩]] &&
                shownName noted ⟨0⟩ == some "lf.txt" &&
                hidden.frame.tabIndex == 0 &&
                hidden.frame.focused == ⟨0⟩ &&
                tab.windows.size == 1 &&
                (tab.windows.all fun view => shownName behind view == some "notes") &&
                state.wellFormed &&
                hidden.wellFormed
            | _, _ => false }]

end ModelTest
