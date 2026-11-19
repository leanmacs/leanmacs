import Editor.Api
import Editor.Clipboard.Model
import Editor.Command
import Editor.Command.Call
import Editor.Command.Model
import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Event
import Editor.Evil.Clipboard
import Editor.Evil.Registers
import Editor.Evil.Repeat
import Editor.InputScheme
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Loop
import Editor.Loop.Driver
import Editor.Menu
import Editor.Menu.Compiled
import Editor.Minibuffer.Compiled
import Editor.Process.Environment
import Editor.Program
import Editor.ProjectMode
import Editor.Scene
import Editor.State
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Text
import Editor.Watch.Model
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Evil
import ModelTest.Support.Vim

/-!
# Model tests: `Editor/Evil/Clipboard.lean`

The model tests of `Editor/Evil/Clipboard.lean`: `clipboardCommandChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The registry of the clipboard command checks: the `menu` package's
bindings, for the owner `compiled`, an owner that is not config, and
`config` as config's bindings. -/
def clipRegistry (config : Array Config.KeyBinding := #[]) : Config.Registry :=
  (({} : Config.Registry).replaceBindings .compiled
        Menu.package.registered.bindings).replaceBindings
    .config config

/-- What a step of the clipboard command checks is handed: evil's commands
and the minibuffer's, then `commands`, with the active keymaps and the menu
bar `clipRegistry config` makes, as a host's are. -/
def clipHanded (config : Array Config.KeyBinding := #[])
    (commands : List (String × Dispatched) := []) : Loop.Keys Vim.Default.scheme :=
  let registry := clipRegistry config
  { evilHanded Minibuffer.package.registered.commands
      commands with
    maps := registry.activeMaps Vim.Default.scheme
    menu := some (registry.menuOf Menu.standard) }

/-- A driver of the clipboard command checks over the text and cursor
`fixture` says, with the unnamed register holding `evilSentinel`, on the
editor's models with the clipboard model `clipboard`, each step handed
`handed`. -/
def clipDriver (fixture : String) (clipboard : ClipboardModel := {})
    (handed : Loop.Keys Vim.Default.scheme := clipHanded) : Option EvilDriver :=
  let (contents, head) := barred fixture
  (Loop.Driver.over handed (fun _ => none)
      (do
        return (← evilState contents head).setRegister Evil.unnamed evilSentinel)
      { editorModel with clipboard }).toOption

/-- `driver` once the command `name` was chosen: by pressing the key string
`chord` when `byKey`, and from its menu item otherwise. -/
def clipRan (byKey : Bool) (name chord : String) (driver : EvilDriver) : EvilDriver :=
  if byKey then evilFed driver chord else (driver.feed { event := .menu name, stamp := 0 }).1

/-- What the scheme reports of the focused view of `driver`. -/
def clipReport (driver : EvilDriver) : InputScheme.Report :=
  Vim.Default.scheme.report driver.loop.input driver.loop.state.frame.focused

/-- The keys `typed` pressed from the text and cursor `fixture` says, on the
clipboard model `clipboard`, and then the command `name` chosen by `chord`
when `byKey` and by its menu item otherwise: what they left, the text the
clipboard model then holds, and the scheme's report of the focused
view. -/
def clipLeft (byKey : Bool) (name chord fixture typed : String) (clipboard : ClipboardModel) :
    Option (EvilEdited × Option String × InputScheme.Report) :=
  (clipDriver fixture clipboard).map fun driver =>
    let after := clipRan byKey name chord (evilFed driver typed)
    (evilLeft after, after.model.clipboard.held, clipReport after)

/-- A prompt opened over `a|b` and `A` typed in it, on the clipboard model
`clipboard`, and then the command `name` chosen by `chord` when `byKey` and
by its menu item otherwise: what the minibuffer's view shows, what the asking
view shows, what the echo area says, the text the clipboard model holds,
and whether the prompt is still open. -/
def clipInPrompt (byKey : Bool) (name chord : String) (clipboard : ClipboardModel := {}) :
    Option (String × String × String × Option String × Bool) :=
  let ask : Dispatched := fun _ => do
    discard <| prompt "Name: " { command := "greet" }
    return none
  (clipDriver "a|b" clipboard (clipHanded (commands := [("ask", ask)]))).map fun driver =>
    let (asking, _) := driver.stepped (driver.loop.runNamed driver.handed "ask")
    let after := clipRan byKey name chord (evilFed asking "A")
    (evilShown after ⟨1⟩, evilShown after, after.loop.state.echo, after.model.clipboard.held,
      after.loop.state.prompt.isSome)

/-- Whether `holds` of a command chosen by its chord and of one chosen by
its menu item. -/
def bothWays (holds : Bool → Bool) : Bool :=
  holds true && holds false

/-- What a command that gave up with `reason` says in the echo area, after
its name. -/
def gaveUpSaying (name reason : String) : String :=
  s!"{name}: {reason}"

/-- The checks of the Edit menu's clipboard commands
(`Editor/Evil/Clipboard.lean`): Cut, Copy, Paste and Select All, each by
its chord and by its menu item, in each Vim state, on the loop's driver over
the editor's models with the registry's active keymaps and the clipboard
model. -/
def clipboardCommandChecks : List Check :=
  [{  name :=
        "Copy in visual over part of a line leaves that text in the clipboard model and the view in normal state; in visual-line it leaves the lines, line-wise; in normal state it gives up with nothingSelected in the echo area and the clipboard model holds what it held"
      run :=
        pure <|
          !Evil.nothingSelected.isEmpty &&
            bothWays fun byKey =>
              let copy := clipLeft byKey Evil.copyName "s-c"
              let normal := vimDefaultReport ""
              copy "foo |bar baz" "v l l" { held := some "before" } ==
                  some (⟨"foo |bar baz", charwise "bar", false, ""⟩, some "bar", normal) &&
                copy "ab\nc|d\nef" "V" { held := some "before" } ==
                  some (⟨"ab\n|cd\nef", linewise "cd\n", false, ""⟩, some "cd\n", normal) &&
                copy "foo |bar" "" { held := some "before" } ==
                  some
                    (⟨"foo |bar", asItWas, false, gaveUpSaying Evil.copyName Evil.nothingSelected⟩,
                      some "before", normal) },
    { name :=
        "Cut in visual and visual-line removes the selection, leaves it in the clipboard model, and one u gives back the text; it is one step of the history; in normal state it gives up with nothingSelected and the buffer and the clipboard model are as they were; with a clipboard not available it deletes, keeps the text in the unnamed register and says so"
      run :=
        pure <|
          bothWays fun byKey =>
            let cut := clipLeft byKey Evil.cutName "s-x"
            let normal := vimDefaultReport ""
            let undone (fixture typed : String) : Option (Option (Nat × Bool) × Option String) :=
              (clipDriver fixture).map fun driver =>
                let ran := clipRan byKey Evil.cutName "s-x" (evilFed driver typed)
                (evilHistory ran, evilText (evilFed ran "u"))
            cut "foo |bar baz" "v l l" { held := some "before" } ==
                some (⟨"foo | baz", charwise "bar", false, ""⟩, some "bar", normal) &&
              cut "ab\nc|d\nef" "V" { held := some "before" } ==
                some (⟨"ab\n|ef", linewise "cd\n", false, ""⟩, some "cd\n", normal) &&
              undone "foo |bar baz" "v l l" == some (some (2, false), some "foo bar baz") &&
              undone "ab\nc|d\nef" "V" == some (some (2, false), some "ab\ncd\nef") &&
              cut "foo |bar" "" { held := some "before" } ==
                some
                  (⟨"foo |bar", asItWas, false, gaveUpSaying Evil.cutName Evil.nothingSelected⟩,
                    some "before", normal) &&
              cut "foo |bar baz" "v l l" { available := false } ==
                some
                  (⟨"foo | baz", charwise "bar", false, Evil.clipboardUnavailable⟩, none, normal) },
    { name :=
        "Cut in visual replaces the last change, as \" + d does: after an x, a . after it leaves what a . after \" + d leaves (a change over a selection, not repeated), not a second x; a . after a Copy repeats the x, as a . after \" + y does"
      run :=
        pure <|
          bothWays fun byKey =>
            let repeated (chord name : String) : Option (EvilEdited × Option String) :=
              (clipDriver "foo |bar bar bar").map fun driver =>
                let after := evilFed (clipRan byKey name chord (evilFed driver "x v l l")) "."
                (evilLeft after, after.model.clipboard.held)
            let cut := repeated "s-x" Evil.cutName
            let copied := repeated "s-c" Evil.copyName
            cut.isSome && cut == evilClipped "foo |bar bar bar" "x v l l \" + d ." &&
              (cut.map fun left =>
                  (left.1.shown, left.1.echo.endsWith (Evil.notRepeated Evil.overSelection))) ==
                some ("foo |bar bar", true) &&
              copied.isSome &&
              copied == evilClipped "foo |bar bar bar" "x v l l \" + y ." &&
              (copied.map (·.1.shown)) == some "foo |r bar bar" },
    { name :=
        "Paste called with a report that is not exclusive, in no state whose run table has an entry for it, puts the clipboard's text before the cursor, as \" + P does, and leaves the clipboard model as it was"
      run :=
        pure <|
          let pasting : Dispatched := fun call => do
            Evil.paste { call with report := { call.report with shape := .inclusive } }
            return none
          let pasted (fixture : String) (held : String) : Option (EvilEdited × Option String) :=
            (clipDriver fixture { held := some held }
                  (clipHanded (commands := [("t-paste", pasting)]))).map
              fun driver =>
              let (after, _) := driver.stepped (driver.loop.runNamed driver.handed "t-paste")
              (evilLeft after, after.model.clipboard.held)
          pasted "a|b" "XY" == evilClipped "a|b" "\" + P" { held := some "XY" } &&
            (pasted "a|b" "XY").map (fun left => (left.1.shown, left.2)) ==
              some ("aX|Yb", some "XY") &&
            (pasted "a|b\n" "cd\n").map (fun left => (left.1.shown, left.2)) ==
              some ("|cd\nab\n", some "cd\n") },
    { name :=
        "Paste puts the clipboard's text before the cursor in normal state (as \" + P), in place of the selection in visual and visual-line, and at the bar as typed text in insert state and in the minibuffer"
      run :=
        pure <|
          bothWays fun byKey =>
            let paste := clipLeft byKey Evil.pasteName "s-v"
            let held : ClipboardModel := { held := some "XY" }
            (paste "a|b" "" held).map (·.1) == (evilClipped "a|b" "\" + P" held).map (·.1) &&
              (paste "a|b" "" held).map (·.1.shown) == some "aX|Yb" &&
              (paste "a|bcd" "v l" held).map (·.1.shown) == some "aX|Yd" &&
              (paste "ab\nc|d\nef" "V" held).map (·.1.shown) == some "ab\n|XY\nef" &&
              paste "a|b" "i" held ==
                some (⟨"aXY|b", asItWas, true, ""⟩, some "XY", vimDefaultReport "i") &&
              clipInPrompt byKey Evil.pasteName "s-v" held ==
                some ("AXY|", "a|b", "", some "XY", true) },
    { name :=
        "after a Paste in each of normal, visual, visual-line, insert and minibuffer the clipboard model holds what it held before, and in the visual states the replaced text is in the unnamed register and not the clipboard, and the view is in normal state"
      run :=
        pure <|
          bothWays fun byKey =>
            let paste := clipLeft byKey Evil.pasteName "s-v"
            let held : ClipboardModel := { held := some "XY" }
            let normal := vimDefaultReport ""
            (paste "a|b" "" held).map (fun left => (left.1.register, left.2)) ==
                some (asItWas, (some "XY", normal)) &&
              (paste "a|bcd" "v l" held).map (fun left => (left.1.register, left.2)) ==
                some (charwise "bc", (some "XY", normal)) &&
              (paste "ab\nc|d\nef" "V" held).map (fun left => (left.1.register, left.2)) ==
                some (linewise "cd\n", (some "XY", normal)) &&
              (paste "a|b" "i" held).map (·.2.1) == some (some "XY") &&
              (clipInPrompt byKey Evil.pasteName "s-v" held).map (·.2.2.2.1) == some (some "XY") },
    { name :=
        "Paste with a clipboard model holding no text gives up with nothingToPut, and with one not available with clipboardUnavailable, in normal, a visual state and insert state, and leaves the buffer as it was"
      run :=
        pure <|
          bothWays fun byKey =>
            let refused (fixture typed shown : String) (clipboard : ClipboardModel)
              (reason : String) : Bool :=
              match clipLeft byKey Evil.pasteName "s-v" fixture typed clipboard with
              | some (left, _, _) =>
                left.shown == shown && left.register == none && left.echo.endsWith reason &&
                  (left.echo.splitOn "refused").length == 1
              | none => false
            [("a|b", "", "a|b"), ("a|bcd", "v l", "ab|cd"), ("a|b", "i", "a|b")].all
              fun (fixture, typed, shown) =>
              refused fixture typed shown {} Evil.nothingToPut &&
                refused fixture typed shown { available := false } Evil.clipboardUnavailable },
    { name :=
        "Select All from normal and from insert state leaves the view in visual-line with one range from offset 0 to the first non-blank of the last line, the cursor on the last line; from visual too"
      run :=
        pure <|
          bothWays fun byKey =>
            let all (fixture typed : String) :
              Option (Option Selection × InputScheme.Report × String) :=
              (clipDriver fixture).map fun driver =>
                let after := clipRan byKey Evil.selectAllName "s-a" (evilFed driver typed)
                (evilSelection after, clipReport after, after.loop.state.echo)
            let lines (anchor head : Nat) :
              Option (Option Selection × InputScheme.Report × String) :=
              some (some { ranges := #[⟨anchor, head⟩], shape := .line }, vimDefaultReport "V", "")
            all "a|b\ncd\n  ef" "" == lines 0 8 && all "a|b\ncd\n  ef" "i" == lines 0 8 &&
              all "ab\nc|d\n" "" == lines 0 3 &&
              all "a|b\ncd" "v" == lines 0 3 &&
              all "a|b\ncd" "V" == lines 0 3 },
    { name :=
        "s-x, s-c, s-v and s-a run the four commands in normal, insert, visual, visual-line and the minibuffer (each leaves what that command leaves there, or its refusal names it), and config's binding of s-c to another command runs that command instead, with the clipboard model as it was"
      run :=
        pure <|
          let greet : Dispatched := fun _ => do
            message "hello"
            return none
          let rebound := clipHanded #[.ofKeys (keys "s-c") "greet"] [("greet", greet)]
          let overridden :=
            (clipDriver "foo |bar baz" { held := some "before" } rebound).map fun driver =>
              let after := evilFed driver "v l l s-c"
              (evilLeft after, after.model.clipboard.held, clipReport after)
          overridden ==
              some
                (⟨"foo ba|r baz", asItWas, false, "hello"⟩, some "before", vimDefaultReport "v") &&
            bothWays fun byKey =>
              let insertRefused (name chord reason : String) : Bool :=
                (clipLeft byKey name chord "a|b" "i" { held := some "before" }).map
                    (fun left => (left.1.shown, left.1.echo, left.2.1)) ==
                  some ("a|b", gaveUpSaying name reason, some "before")
              insertRefused Evil.copyName "s-c" Evil.nothingSelected &&
                insertRefused Evil.cutName "s-x" Evil.nothingSelected &&
                clipInPrompt byKey Evil.copyName "s-c" { held := some "before" } ==
                  some
                    ("A|", "a|b", gaveUpSaying Evil.copyName Evil.nothingSelected, some "before",
                      true) &&
                clipInPrompt byKey Evil.cutName "s-x" { held := some "before" } ==
                  some
                    ("A|", "a|b", gaveUpSaying Evil.cutName Evil.nothingSelected, some "before",
                      true) &&
                clipInPrompt byKey Evil.selectAllName "s-a" ==
                  some
                    ("A|", "a|b", gaveUpSaying Evil.selectAllName Evil.noLineSelection, none,
                      true) &&
                (clipLeft byKey Evil.copyName "s-c" "a|b\ncd" "V j" {}).map (·.2.1) ==
                  some (some "ab\ncd\n") },
    { name :=
        "a Cut or Copy refused (nothing selected) or stopped by the interrupt before any one of its requests leaves the clipboard model as it was, and a refused or stopped Cut leaves the buffer as it was"
      run :=
        pure <|
          let swept (byKey : Bool) (name chord : String) (whole : EvilEdited × Option String) :
            Bool :=
            match clipDriver "foo |bar baz" { held := some "before" } with
            | none => false
            | some driver =>
              let selected := evilFed driver "v l l"
              let ran (asks : Option Nat) : EvilEdited × Option String :=
                let after :=
                  clipRan byKey name chord
                    { selected with
                      model :=
                        { selected.model with
                          watch := { selected.model.watch with arrivesAfter := asks } } }
                (evilLeft after, after.model.clipboard.held)
              let stopped : EvilEdited × Option String :=
                (⟨"foo ba|r baz", asItWas, false, s!"{Vim.operateCommand}: interrupted"⟩,
                  some "before")
              let runs := (List.range 80).map fun asks => ran (some asks)
              ran none == whole && runs.all (fun run => run == stopped || run == whole) &&
                (runs.filter (· == stopped)).length > 4 &&
                runs.getLast? == some whole
          swept true Evil.cutName "s-x" (⟨"foo | baz", charwise "bar", false, ""⟩, some "bar") &&
            swept false Evil.copyName "s-c"
              (⟨"foo |bar baz", charwise "bar", false, ""⟩, some "bar") &&
            bothWays fun byKey =>
              [(Evil.cutName, "s-x"), (Evil.copyName, "s-c")].all fun (name, chord) =>
                (clipLeft byKey name chord "foo |bar" "" { held := some "before" }).map
                    (fun left => (left.1.shown, left.2.1)) ==
                  some ("foo |bar", some "before") }]

end ModelTest
