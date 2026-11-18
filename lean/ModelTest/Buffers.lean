import Editor.Buffers.Compiled
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Config.Reload
import Editor.Display.Model
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.Face
import Editor.File.Cases
import Editor.FileWatch.Model
import Editor.Files.Compiled
import Editor.Floating
import Editor.Fuzzy.Model
import Editor.InputScheme.Test
import Editor.Job.Contract
import Editor.Job.Model
import Editor.Language
import Editor.Layout
import Editor.Loop.Driver
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Themes.Compiled
import Editor.Themes.FairyFloss
import Editor.Themes.Solarized
import Editor.Window
import ModelTest.Driver

/-!
# Model tests: buffers and appearance

The checks of buffer commands, display rules, appearance and themes.

Its lists of checks: `bufferCommandChecks`, `displayRuleChecks`,
`appearanceChecks`, `themeChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- What a step of the buffer command checks is handed. The commands are the
ones compiled code registers for files, the minibuffer, the buffers and the
ex line (`Files.commands`, `Minibuffer.commands`, `Buffers.commands`,
`Ex.commands`), each under the name it is registered under, told of the ex
names that ship (`Ex.bindings`), and five written here: `split`, which
splits the window it is called with and leaves the focus,
`edit-then-close`, which inserts `x` at its window's cursors and then runs
`close-buffer` inside itself, so the edit and the close are one command,
`dock-others`, which docks every other window of the tiled list at the
left edge, `focus-main`, which focuses the first window of the tiled list,
and `make-notes`, which makes a buffer called `notes`, or a free name made
from it, holding `a note`, adds the minor mode `notes` to it and displays
it for the command `make-notes` (`BufferId.display`).

One keymap, the same for every view: `C-e e` runs the ex command, `C-e y`
and `C-e t` the minibuffer's accept command and its command that moves to
the next candidate, `C-b b` runs `switch-buffer` with the arguments the Vim
scheme gives a command a key is bound to, a count and a register, `C-b n`
runs it with `note.txt`, `C-b s` runs `split`, `C-b x` runs
`edit-then-close`, `C-b d` runs `close-buffer` with no argument, `C-b m`
runs it with the name the minibuffer's buffer has (`Prompt.bufferName`),
`C-b h` runs `dock-others`, `C-b f` runs `focus-main`, `C-b o` runs
`make-notes` and `C-b t` runs `new-tab`, which opens a tab after the one in
view on the call's window's buffer (`ViewId.newTab`). -/
def bufferKeys : Loop.Keys TestScheme.scheme :=
  let registrations := Files.commands ++ Minibuffer.commands ++ Buffers.commands ++ Ex.commands
  let compiled : List (String × Dispatched) :=
    registrations.toList.filterMap fun registration =>
      match registration.action with
      | .call run =>
        some
          (registration.name, fun call => do
            run call
            return none)
      | _ => none
  let written : List (String × Dispatched) :=
    [("split", fun call => do
        discard <| call.target.window.id.split
        return none),
      ("edit-then-close", fun call => do
        discard <| call.target.window.id.insertAtSelections "x"
        discard <| runCommand Buffers.closeName { call with arguments := [] }
        return none),
      ("dock-others", fun call => do
        for view in (← editorState).frame.windows do
          if view != call.target.window.id then
            discard <| view.arrange (.edge .left)
        return none),
      ("focus-main", fun _ => do
        if let some main := (← editorState).frame.windows[0]? then
          discard <| main.focus
        return none),
      ("new-tab", fun call => do
        discard <| call.target.window.id.newTab
        return none),
      ("make-notes", fun call => do
        let name := (← editorState).freeName "notes"
        let .ok notes ← createBuffer name "a note" | giveUp "making notes was refused"
        discard <| notes.addMinorMode "notes"
        discard <| notes.display call.target.window.id "make-notes"
        return none)]
  {
    dispatchKeys
      [("C-e e", invoke Ex.name), ("C-e y", invoke Minibuffer.acceptName),
        ("C-e t", invoke Minibuffer.nextName),
        ("C-b b", { command := Buffers.switchName, arguments := [.nat 0, .str ""] }),
        ("C-b n", { command := Buffers.switchName, arguments := [.str "note.txt"] }),
        ("C-b s", invoke "split"), ("C-b x", invoke "edit-then-close"),
        ("C-b d", invoke Buffers.closeName),
        ("C-b m", { command := Buffers.closeName, arguments := [.str Prompt.bufferName] }),
        ("C-b h", invoke "dock-others"), ("C-b f", invoke "focus-main"),
        ("C-b o", invoke "make-notes"), ("C-b t", invoke "new-tab")]
      (compiled ++ written) with
    registered :=
      { ex := fun name => Ex.bindings.findRev? (·.name == name),
        exNames := exNamesOf Ex.bindings } }

/-- A driver of the buffer command checks over the initial state, with the
file commands' jobs and the files of the file command checks; `none` if
making the state was refused. -/
def buffersDriver : Option TestDriver :=
  (Loop.Driver.over bufferKeys fileJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

/-- `driver` with `note.txt`, `crlf.txt` and `lf.txt` opened in view 0, in
that order, each by the ex line `e` and its path, and each load finished
before the next: the loads are jobs 1, 2 and 3. The open buffers are then
`scratch`, `note.txt`, `crlf.txt` and `lf.txt`, and `lf.txt` is the most
recently used. -/
def threeOpen (driver : TestDriver) : TestDriver :=
  [("note.txt", 1), ("crlf.txt", 2), ("lf.txt", 3)].foldl
    (fun driver (name, job) => ((fedTo driver (exLine s!"e {inFiles name}")).1.finish job).1) driver

/-- `buffersDriver` with `threeOpen`'s three files open. -/
def buffersOpen : Option TestDriver :=
  buffersDriver.map threeOpen

/-- The name of the buffer view `view` of `driver` shows. -/
def shownName (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option String :=
  (showing driver view).map (·.buffer.name)

/-- The buffer called `name` in `driver`'s state. -/
def bufferNamed (driver : TestDriver) (name : String) : Option BufferId :=
  driver.loop.state.findBuffer name

/-- The checks of the buffer commands (`Editor/Buffers.lean`,
`Editor/Buffers/Compiled.lean`) and the ex names `b`, `ls` and `bd`, on the
loop's driver over the editor's models, the model of files and the test
scheme. Each message is read from the function that makes it, and an order
the fuzzy matcher decides is computed with its model. -/
def bufferCommandChecks : List Check :=
  [{  name :=
        "closing a buffer shown only in a hidden tab's window shows the fallback there and removes the buffer; the tab in view stays in view"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (tabbed, _) := fedTo opened (presses "C-b t" ++ exLine "b scratch")
            let hidden := tabbed.loop.state.frame.tabsAfter.flatMap (·.windows)
            let (closed, _) := fedTo tabbed (exLine "bd lf.txt")
            let state := closed.loop.state
            hidden.size == 1 && (hidden.all fun view => shownName tabbed view == some "lf.txt") &&
              shownName tabbed == some "scratch" &&
              state.findBuffer "lf.txt" == none &&
              state.frame.tabIndex == 0 &&
              (hidden.all fun view => (shownName closed view).any (· != "lf.txt")) &&
              state.wellFormed },
    { name :=
        "b with no argument opens a prompt labelled with the switch prompt's label, whose continuation is switch-buffer, and whose candidates are the open buffers' names, most recently used first and the asking window's buffer last, without the minibuffer's; called with a count and a register, as a key under the Vim scheme calls it, it asks the same"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let asked (events : List Event) : Bool :=
              let (asking, _) := fedTo opened events
              let state := asking.loop.state
              let minibuffer := (state.minibufferBuffer?.bind state.buffer?).map (·.name)
              state.prompt.map (fun asked => (asked.label, asked.continuation)) ==
                  some (Buffers.switchPrompt, { command := Buffers.switchName }) &&
                (candidatesOf asking).map (·.all) ==
                  some #["crlf.txt", "note.txt", "scratch", "lf.txt"] &&
                minibuffer.isSome &&
                !((candidatesOf asking).any fun candidates =>
                    minibuffer.any candidates.all.contains)
            asked (exLine "b") && asked (presses "C-b b") },
    { name :=
        "a pattern typed after b and accepted with nothing chosen shows the best match in the window: its status line names it and it is the most recently used; where more than one buffer matches, the one the fuzzy model ranks first"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (switched, _) := fedTo opened (exLine "b nte")
            let state := opened.loop.state
            let names := state.openBuffers.filterMap fun id => (state.buffer? id).map (·.name)
            let best := (FuzzyModel.rank "txt" names)[0]?.bind (names[·]?)
            let (several, _) := fedTo opened (exLine "b txt")
            shownName switched == some "note.txt" && statusOf switched == some (named "note.txt") &&
              switched.loop.state.recent[0]? == bufferNamed switched "note.txt" &&
              switched.loop.state.prompt == none &&
              best.isSome &&
              shownName several == best },
    { name :=
        "a candidate chosen with the minibuffer's next command and accepted is the buffer shown"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (chosen, _) := fedTo opened (exLine "b" ++ presses "C-e t")
            let (switched, _) := fedTo chosen (presses "C-e y")
            let expected := (candidatesOf chosen).bind (·.listed[0]?)
            expected.isSome && (candidatesOf chosen).bind (·.chosen) == some 0 &&
              shownName switched == expected &&
              switched.loop.state.prompt == none },
    { name :=
        "b with an exact name switches with no prompt; b with a pattern nothing matches leaves the window as it was and says so by the switch command's message"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (exact, _) := fedTo opened (exLine "b scratch")
            let (missed, _) := fedTo opened (exLine "b zzz")
            shownName exact == some "scratch" && exact.loop.state.prompt == none &&
              shownName missed == some "lf.txt" &&
              promptEcho missed == Buffers.noMatch "zzz" &&
              missed.loop.state.wellFormed },
    { name :=
        "switch-buffer called with a name from the minibuffer's view shows the buffer in the window the prompt was asked from, and the prompt stays open"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (asking, _) := fedTo opened (presses "C-e e")
            let (switched, _) := fedTo asking (presses "C-b n")
            asking.loop.state.minibufferView? == some asking.loop.state.frame.focused &&
              shownName switched == some "note.txt" &&
              switched.loop.state.prompt.isSome &&
              switched.loop.state.wellFormed },
    { name :=
        "ls shows, in a new window at the end of the list, focused, a buffer called buffer-list with no file, whose text is one line per open buffer, most recently used first, + for unsaved changes and the path of a buffer with a file; the minibuffer and the list itself are not in it, and the modified scratch buffer, which holds no file, has no +; the window it was called in keeps its buffer"
      run :=
        pure <|
          match buffersDriver with
          | none => false
          | some driver =>
            let opened := threeOpen (fedTo driver [.commit "typed"]).1
            let (listed, _) := fedTo opened (exLine "b note.txt" ++ [.commit "x"] ++ exLine "ls")
            let path (name : String) : String := (inFiles name).toString
            let expected :=
              s!"+ note.txt  {path "note.txt"}\n  lf.txt  {path "lf.txt"}\n  crlf.txt  {path "crlf.txt"}\n  scratch\n"
            let state := listed.loop.state
            let list := showing listed state.frame.focused
            (list.map fun shown => (shown.buffer.name, shown.buffer.file.isNone)) ==
                some (Buffers.listBuffer, true) &&
              list.bind (·.text) == some expected &&
              state.frame.windows.size == 2 &&
              state.frame.windows.back? == some state.frame.focused &&
              state.frame.focused != ⟨0⟩ &&
              shownName listed ⟨0⟩ == some "note.txt" &&
              state.wellFormed },
    { name :=
        "ls again replaces the list's text and makes no second buffer: after note.txt is saved its line has no +"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (first, _) := fedTo opened (exLine "b note.txt" ++ [.commit "x"] ++ exLine "ls")
            let (saved, _) := fedTo first (exLine "b note.txt" ++ exLine "w")
            let (saved, _) := saved.finish 4
            let (again, _) := fedTo saved (exLine "ls")
            let path (name : String) : String := (inFiles name).toString
            let expected :=
              s!"  note.txt  {path "note.txt"}\n  lf.txt  {path "lf.txt"}\n  crlf.txt  {path "crlf.txt"}\n  scratch\n"
            let focused := again.loop.state.frame.focused
            bufferNamed first Buffers.listBuffer != none &&
              bufferNamed again Buffers.listBuffer == bufferNamed first Buffers.listBuffer &&
              shownName again focused == some Buffers.listBuffer &&
              (showing again focused).bind (·.text) == some expected &&
              (again.loop.state.buffers.filter
                    (·.any (·.name.startsWith Buffers.listBuffer))).size ==
                1 },
    { name :=
        "ls with a file called buffer-list open leaves that buffer's text as it was and unmodified, lists it, and shows the list in a buffer of its own with no file, under a free name; ls again makes no third"
      run :=
        pure <|
          match buffersDriver with
          | none => false
          | some driver =>
            let path := inFiles Buffers.listBuffer
            let contents := "kept\n"
            let withFile := rewritten driver path contents.toUTF8
            let (opened, _) := fedTo withFile (exLine s!"e {path}")
            let (opened, _) := opened.finish 1
            let (listed, _) := fedTo opened (exLine "ls")
            let (again, _) := fedTo listed (exLine "ls")
            let (back, _) := fedTo again (exLine s!"b {Buffers.listBuffer}")
            let expected := s!"  {Buffers.listBuffer}  {path}\n  scratch\n"
            let state := again.loop.state
            let list := listed.loop.state.frame.focused
            (showing opened).bind (·.text) == some contents &&
              ((showing listed list).map fun shown => (shown.buffer.file.isNone, shown.text)) ==
                some (true, some expected) &&
              shownName listed list == some (opened.loop.state.freeName Buffers.listBuffer) &&
              again.loop.state.frame.focused == list &&
              (showing again list).bind (·.text) == some expected &&
              state.openBuffers.size == 3 &&
              state.findFile path == bufferNamed opened Buffers.listBuffer &&
              (heldFile back).map (·.path) == some path &&
              (showing back).bind (·.text) == some contents &&
              (showing back).map (·.buffer.isModified) == some false &&
              state.wellFormed },
    { name :=
        "bd closes an unmodified file buffer shown in two windows: it is gone, no buffer holds its file, both windows show crlf.txt, the buffer used before it, and their status lines name it, the order of use lacks it, the state is well formed, and its text is released; a second bd falls back to note.txt"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (split, _) := fedTo opened (presses "C-b s")
            let before := split.loop.state
            let other := (before.frame.windows.filter (· != ⟨0⟩))[0]?.getD ⟨0⟩
            let closed := bufferNamed split "lf.txt"
            let text := (closed.bind before.buffer?).map (·.text)
            let (after, _) := fedTo split (exLine "bd")
            let state := after.loop.state
            let (second, _) := fedTo after (exLine "bd")
            other != ⟨0⟩ && shownName split other == some "lf.txt" && closed.isSome &&
              (closed.bind state.buffer?).isNone &&
              state.findFile (inFiles "lf.txt") == none &&
              shownName after == some "crlf.txt" &&
              shownName after other == some "crlf.txt" &&
              (closed.bind before.mostRecent) == bufferNamed after "crlf.txt" &&
              statusOf after == some (named "crlf.txt") &&
              inactiveStatusOf after other "crlf.txt" ==
                some #[{ ModeLine.field "crlf.txt" ModeLine.inactiveFace with side := .left }] &&
              closed.all (!state.recent.contains ·) &&
              state.wellFormed &&
              (text.bind fun text => (after.model.texts.texts[text.index]?).join).isNone &&
              text.isSome &&
              shownName second == some "note.txt" &&
              shownName second other == some "note.txt" &&
              second.loop.state.wellFormed },
    { name :=
        "bd with a name closes the named buffer, not the window's; bd with a name no buffer has says so by the close command's message and closes nothing"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (named', _) := fedTo opened (exLine "bd note.txt")
            let (missed, _) := fedTo opened (exLine "bd nope")
            bufferNamed named' "note.txt" == none && shownName named' == some "lf.txt" &&
              named'.loop.state.wellFormed &&
              promptEcho missed == Buffers.noBuffer "nope" &&
              missed.loop.state.openBuffers == opened.loop.state.openBuffers },
    { name :=
        "a modified buffer with no file closes, by q's rule: bd on the scratch buffer with text typed in it closes it and the window shows the buffer used before it"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (closed, _) := fedTo opened (exLine "b scratch" ++ [.commit "typed"] ++ exLine "bd")
            bufferNamed closed "scratch" == none && shownName closed == some "lf.txt" &&
              closed.loop.state.wellFormed },
    { name :=
        "bd on a buffer with a save in flight leaves it open and shown, with its text, and the echo area says why by the close command's message; once the save is delivered and says the file was written, bd closes it"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (saving, _) := fedTo opened ([.commit "x"] ++ exLine "w")
            let (refused, _) := fedTo saving (exLine "bd")
            let (delivered, _) := refused.finish 4
            let (closed, _) := fedTo delivered (exLine "bd")
            (heldFile saving).bind (·.saving) != none &&
              refused.loop.state.findFile (inFiles "lf.txt") != none &&
              shownName refused == some "lf.txt" &&
              (showing refused).bind (·.text) == (showing saving).bind (·.text) &&
              echoOf refused == some (Buffers.beingSaved "lf.txt") &&
              refused.loop.state.wellFormed &&
              echoOf delivered == some (Files.wrote (inFiles "lf.txt")) &&
              closed.loop.state.findFile (inFiles "lf.txt") == none &&
              shownName closed == some "crlf.txt" },
    { name :=
        "bd on a buffer whose save in flight is then refused, the file having changed behind the editor: the buffer is still open and shown, with its edit, and still modified, and the echo area has the save's refusal"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let path := inFiles "lf.txt"
            let changed := rewritten opened path JobContract.otherFile
            let (saving, _) := fedTo changed ([.commit "x"] ++ exLine "w")
            let (closing, _) := fedTo saving (exLine "bd")
            let (refused, _) := closing.finish 4
            refused.loop.state.findFile path != none && shownName refused == some "lf.txt" &&
              (showing refused).bind (·.text) == (showing saving).bind (·.text) &&
              ((showing saving).bind (·.text)).any (·.startsWith "x") &&
              (showing refused).map (·.buffer.isModified) == some true &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
              refused.loop.state.wellFormed },
    { name :=
        "close-buffer run from the minibuffer's view, and run with the name of the minibuffer's buffer, closes nothing and says so by the close command's message; the prompt stays open and the state is well formed"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (asking, _) := fedTo opened (presses "C-e e")
            let minibuffer := asking.loop.state.minibufferBuffer?
            [presses "C-b d", presses "C-b m"].all fun keys =>
              let (refused, _) := fedTo asking keys
              let state := refused.loop.state
              (minibuffer.bind asking.loop.state.buffer?).map (·.name) == some Prompt.bufferName &&
                promptEcho refused == Buffers.ofMinibuffer &&
                state.openBuffers == asking.loop.state.openBuffers &&
                state.minibufferBuffer? == minibuffer &&
                state.prompt == asking.loop.state.prompt &&
                state.wellFormed },
    { name :=
        "switch-buffer with no buffer named while a prompt is open asks for none: the echo area says the prompt's refusal by the switch command's message, and the open prompt is as it was"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (asking, _) := fedTo opened (presses "C-e e")
            let (refused, _) := fedTo asking (presses "C-b b")
            match asking.loop.state.minibufferView? with
            | none => false
            | some view =>
              promptEcho refused == Buffers.notAsking (.alreadyOpen view) &&
                refused.loop.state.prompt == asking.loop.state.prompt &&
                refused.loop.state.minibufferView? == some view &&
                refused.loop.state.wellFormed },
    { name :=
        "bd on the only buffer, the initial scratch with text typed in it: the window shows a buffer called scratch with no file, whose text is empty; the old slot is empty, one buffer is open, and the state is well formed"
      run :=
        pure <|
          match buffersDriver with
          | none => false
          | some driver =>
            let (closed, _) := fedTo driver ([.commit "typed"] ++ exLine "bd")
            let state := closed.loop.state
            driverText driver == some "" &&
              ((showing closed).map fun shown =>
                  (shown.buffer.name, shown.buffer.file.isNone, shown.text, shown.id != ⟨0⟩)) ==
                some (EditorState.scratchName, true, some "", true) &&
              state.buffers[0]? == some none &&
              state.openBuffers.size == 1 &&
              state.wellFormed },
    { name :=
        "bd on each of threeOpen's buffers in turn leaves, after the last, an empty buffer called scratch with no file, the one open buffer"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (closed, _) :=
              fedTo opened (exLine "bd" ++ exLine "bd" ++ exLine "bd" ++ exLine "bd")
            let state := closed.loop.state
            ((showing closed).map fun shown =>
                  (shown.buffer.name, shown.buffer.file.isNone, shown.text)) ==
                some (EditorState.scratchName, true, some "") &&
              state.openBuffers.size == 1 &&
              ["note.txt", "crlf.txt", "lf.txt"].all (bufferNamed closed · == none) &&
              state.wellFormed },
    { name :=
        "bd on note.txt with an edit committed leaves the buffer open and shown, with the edit, and the echo area says why by the close command's message; and so when the edit and the close are one command"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let text := "x" ++ FileCases.noteText
            let (refused, _) := fedTo opened (exLine "b note.txt" ++ [.commit "x"] ++ exLine "bd")
            let (onePass, _) := fedTo opened (exLine "b note.txt" ++ presses "C-b x")
            [refused, onePass].all fun driver =>
              bufferNamed driver "note.txt" != none && shownName driver == some "note.txt" &&
                (showing driver).bind (·.text) == some text &&
                echoOf driver == some (Buffers.notClosing "note.txt") &&
                driver.loop.state.wellFormed },
    { name :=
        "bd on a buffer shown only in a window docked at an edge closes it: the docked window shows the buffer used before it, and stays docked"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let state := opened.loop.state
            let edged :=
              { opened with
                loop :=
                  { opened.loop with
                    state :=
                      { state with
                        frame := { state.frame with layout := .edge .left 25 Layout.default } } } }
            let (docked, _) := fedTo edged (presses "C-b s" ++ presses "C-b h")
            let (closed, _) := fedTo docked (exLine "b note.txt" ++ exLine "bd lf.txt")
            match docked.loop.state.frame.docked.toList with
            | [(sidebar, .left)] =>
              shownName docked sidebar == some "lf.txt" && bufferNamed closed "lf.txt" == none &&
                shownName closed sidebar == some "note.txt" &&
                closed.loop.state.frame.docked == #[(sidebar, .left)] &&
                closed.loop.state.wellFormed
            | _ => false }]

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
              Files.shownIn fromSidebar (minibuffer fromSidebar) == ⟨2⟩ &&
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

/-- The command `other` of the theme command's checks: it says `other`. -/
def saysOther : Dispatched := fun _ => do
  message "other"
  return none

/-- What a step of the theme command's checks is handed: the commands
compiled code registers for loading a theme and for the minibuffer
(`Themes.commands`, `Minibuffer.commands`), and `other`, which says
`other`; told that the themes `default` and `second` are registered. `C-t
t` runs the theme command with nothing, `C-t s` with the name `second`,
`C-t n` with the name `nope`, `C-e y` runs the minibuffer's accept and `C-e
o` runs `other`. -/
def themeKeys : Loop.Keys TestScheme.scheme :=
  let compiled : List (String × Dispatched) :=
    (Themes.commands ++ Minibuffer.commands).toList.filterMap fun registration =>
      match registration.action with
      | .call run =>
        some
          (registration.name, fun call => do
            run call
            return none)
      | _ => none
  {
    dispatchKeys
      [("C-t t", invoke Themes.loadName),
        ("C-t s", { command := Themes.loadName, arguments := [.str "second"] }),
        ("C-t n", { command := Themes.loadName, arguments := [.str "nope"] }),
        ("C-e y", invoke Minibuffer.acceptName), ("C-e o", invoke "other")]
      (compiled ++ [("other", saysOther)]) with
    registered := { themeNames := #[Theme.defaultName, "second"] } }

/-- The reload reducer's state with the shipped themes registered, the
built-in theme in force, and nothing loaded. -/
def shippedThemes : Config.State Elaborated :=
  { registry := ({} : Config.Registry).replaceThemes .compiled Themes.shipped }

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

/-- The checks of the command that loads a theme (`Editor/Themes.lean`,
`Editor/Themes/Compiled.lean`), on the loop's driver over the editor's
models and the test scheme: it asks for a name among the registered ones,
and a step that loads one hands the name back. -/
def themeChecks : List Check :=
  let driver? : Option TestDriver :=
    (Loop.Driver.over themeKeys (fun _ => none) (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption
  [{  name :=
        "the theme command with no name opens a prompt labelled with its label, whose continuation is the command itself and whose candidates are the registered themes' names"
      run :=
        pure <|
          match driver? with
          | none => false
          | some driver =>
            let (asking, steps) := fedTo driver (presses "C-t t")
            asking.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                some (Themes.label, { command := Themes.loadName }) &&
              (candidatesOf asking).map (·.all) == some #[Theme.defaultName, "second"] &&
              steps.map (·.map (·.theme)) == #[some none, some none] },
    { name :=
        "the theme command with a registered name hands the name back with its step and says nothing; accepting its prompt with a name loads that one"
      run :=
        pure <|
          match driver? with
          | none => false
          | some driver =>
            let (loaded, steps) := fedTo driver (presses "C-t s")
            let (typed, _) := fedTo driver (presses "C-t t" ++ [.commit "second"])
            let (accepted, _) := fedTo typed (presses "C-e y")
            steps.map (·.map (·.theme)) == #[some none, some (some "second")] &&
              promptEcho loaded == "" &&
              loaded.themes == #["second"] &&
              accepted.themes == #["second"] &&
              accepted.loop.state.prompt == none },
    { name :=
        "the theme command with a name nobody registered says so in the echo area, by its name and the theme's, and loads none; the editor goes on"
      run :=
        pure <|
          match driver? with
          | none => false
          | some driver =>
            let (unknown, _) := fedTo driver (presses "C-t n")
            let (after, _) := fedTo unknown (presses "C-e o")
            promptEcho unknown == "load-theme: no theme is registered as `nope`" &&
              promptEcho unknown == Themes.notLoaded (.noSuchTheme "nope") &&
              unknown.themes == #[] &&
              promptEcho after == "other" },
    { name :=
        "the theme command while a prompt is open says the refusal after its own name and leaves that prompt open"
      run :=
        pure <|
          match driver? with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-t t")
            let (again, _) := fedTo asking (presses "C-t t")
            promptEcho again == Themes.notAsking (.alreadyOpen ⟨1⟩) &&
              promptEcho again == "load-theme: a prompt is open already" &&
              again.loop.state.prompt.isSome }]

end ModelTest
