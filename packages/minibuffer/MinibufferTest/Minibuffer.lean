import Editor.Command
import Editor.Command.Model
import Editor.Completion.Later
import Editor.Config.Packages
import Editor.Display.Model
import Editor.Event
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Loop.Driver
import Editor.Mode
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Test.Prompts
import Editor.Test.States
import Editor.Text
import Editor.Text.Model
import Minibuffer.Compiled
import MinibufferTest.Check

/-!
# Model tests: `Minibuffer.lean`

The model tests of `Minibuffer.lean` and `Minibuffer/Compiled.lean`:
`promptModeChecks`. The test driver's root, `MinibufferTest/Model.lean`,
runs them; its module doc says what each shows. They were the core's
(`ModelTest.promptModeChecks`) while the minibuffer was modules of the
core, and moved here with their sentences as they were. They run on the
core's test kit (`Editor.Test.…`: the prompt driver, the keys, the states)
and the models, which a package's tests may import (`docs/design/packages.md`,
"What a package may import").
-/

namespace MinibufferTest

open Editor
open Editor.Test

/-- What reading the text `text` comes to on `driver`'s models. -/
def readOn (driver : TestDriver) (text : TextId) : TextError ⊕ String :=
  let read : EditorM String := text.read
  resulted (read.runModel driver.model).1

/-- What the last scene `driver`'s display recorded shows of the open
prompt: the text and the status line of the minibuffer's view, whether it
is the focused view, and the status line of view 0. `none` when no prompt
is open or the scene lacks either view. -/
def promptScene (driver : TestDriver) :
    Option (Option String × Array StatusField × Bool × Array StatusField) := do
  let scene ← driver.model.display.scenes.back?
  let view ← driver.loop.state.minibufferView?
  let minibuffer ← scene.views.find? (·.id == view)
  let window ← scene.views.find? (·.id == ⟨0⟩)
  return (shownText driver.model minibuffer, minibuffer.status, scene.focused == some view,
      window.status)

/-- A driver of the minibuffer checks (`minibufferDriver`,
the core's `lean/Editor/Test/Prompts.lean`) over the state `start` makes, with the
minibuffer that ships (`Editor.Minibuffer.package`) where the kit's
drivers have the kit's: these checks are of that package's own commands. -/
def shippedMinibufferDriver (start : TextM EditorState := EditorState.initial ⟨640, 480⟩) :
    Option TestDriver :=
  minibufferDriver start (package := Editor.Minibuffer.package)

/-- The checks of the minibuffer's commands and its mode
(`Minibuffer.lean`, `Minibuffer/Compiled.lean`), on the
loop's driver over the editor's models and the test scheme, with the
registry's active keymaps (`shippedMinibufferDriver`): the phase's acceptance
criteria on the models, the rules of the shipped commands the kit's
minibuffer does not share (`<Backspace>` on an empty minibuffer, a malformed
batch), and that the shipped package registers what the kit's does
(the core's `lean/Editor/Test/Minibuffer.lean`). The accept key and the cancel key are the test scheme's keys for the roles
the mode fills (`InputScheme.roleKey`), so no check names a key of
either. -/
def promptModeChecks : List Check :=
  let accept := rolePresses Role.activate
  let cancel := rolePresses Role.quit
  let answer (text : String) : List Argument := [.str text, .nat 7]
  let closed (driver : TestDriver) (view : ViewId := ⟨0⟩) : Bool :=
    let state := driver.loop.state
    state.prompt == none && state.frame.focused == view && state.outbox.answered.isEmpty &&
      state.wellFormed
  [{  name :=
        "criterion 1: a command prompts, keys are typed and the accept key is pressed: the continuation's command receives the typed string, with the asking view as its target, and the minibuffer's window is closed; the state has no prompt, one window, the tree it had and the focus on the asking view, the minibuffer's buffer slot is empty and its text refuses noSuchText, and the scene has one view"
      run :=
        pure <|
          match shippedMinibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            let (accepted, _) := fedTo typed accept
            !accept.isEmpty && minibufferText typed == some "hi" &&
              typed.loop.state.minibufferBuffer? == some ⟨1⟩ &&
              (minibufferTextId typed).map (readOn typed) == some (.inr "hi") &&
              promptEcho accepted == greeted (answer "hi") &&
              closed accepted &&
              accepted.loop.state.windows.map (·.id) == #[⟨0⟩] &&
              accepted.loop.state.frame.windows == driver.loop.state.frame.windows &&
              accepted.loop.state.buffers[1]? == some none &&
              (minibufferTextId typed).map (readOn accepted) == some (.inl .noSuchText) &&
              (accepted.model.display.scenes.back?.map (·.views.map (·.id))) == some #[⟨0⟩] },
    { name :=
        "criterion 2: a prompt given an initial value and accepted with no key typed: the continuation's command receives the initial value"
      run :=
        pure <|
          match shippedMinibufferDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c i")
            let (accepted, _) := fedTo asking accept
            minibufferText asking == some "Ada" && promptEcho accepted == greeted (answer "Ada") &&
              closed accepted },
    { name :=
        "criterion 3: the prompt is cancelled: the continuation's command does not run, nothing is answered, the focus returns to the view that had it, and the minibuffer's text is released; the same keys with the accept key in place of the cancel key do run it"
      run :=
        pure <|
          match shippedMinibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            let (cancelled, steps) := fedTo typed cancel
            let (accepted, _) := fedTo typed accept
            !cancel.isEmpty && cancel != accept && typed.loop.state.frame.focused == ⟨1⟩ &&
              promptEcho cancelled == "" &&
              steps.all (·.all (·.answered.isEmpty)) &&
              closed cancelled &&
              cancelled.loop.state.windows.map (·.id) == #[⟨0⟩] &&
              (minibufferTextId typed).map (readOn cancelled) == some (.inl .noSuchText) &&
              cancelled.model.display.scenes.all (·.echo != greeted (answer "hi")) &&
              promptEcho accepted == greeted (answer "hi") },
    { name :=
        "criterion 4: a job completes while a prompt is open: its result's command runs, to its end, before the prompt is answered, and inserts in the window's buffer; the prompt is still open, with its text and the focus, and the keys typed afterwards and the accept key answer it with everything typed"
      run :=
        pure <|
          match shippedMinibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c s C-c a h")
            let (delivered, step) := typed.finish 1
            let (accepted, _) := fedTo delivered (presses "i" ++ accept)
            typed.pending.map (·.id) == #[1] && driverText typed == some "" &&
              (step.map (·.ended)) == some (some .finished) &&
              driverText delivered == some "[42]" &&
              delivered.loop.state.prompt == typed.loop.state.prompt &&
              delivered.loop.state.prompt.isSome &&
              delivered.loop.state.frame.focused == ⟨1⟩ &&
              minibufferText delivered == some "h" &&
              promptEcho accepted == greeted (answer "hi") &&
              closed accepted &&
              driverText accepted == some "[42]" },
    { name :=
        "criterion 5: while a prompt is open the scene shows the prompt text and the input typed so far in the minibuffer's view: after the prompt is asked for and after each key that prints, the last scene has that view with the text so far, the label alone as its status line, in the prompt's face, and the focus, and view 0 with its own status line"
      run :=
        pure <|
          match shippedMinibufferDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (one, _) := fedTo asking (presses "h")
            let (two, _) := fedTo one (presses "i")
            let showing (text : String) :=
              some
                (some text, #[({ text := "Name: ", face := Loop.promptFace } : StatusField)], true,
                  modeLineOf)
            promptScene driver == none && promptScene asking == showing "" &&
              promptScene one == showing "h" &&
              promptScene two == showing "hi" },
    { name :=
        "with no prompt open the minibuffer's accept command and its cancel command, each run by a key of the global keymap, say that no prompt is open and change nothing else; and the keys of the two roles, typed in a view whose buffer does not have the minibuffer's mode, run no command"
      run :=
        pure <|
          match shippedMinibufferDriver with
          | none => false
          | some driver =>
            let said (typed : String) : Bool :=
              let (after, _) := fedTo driver (presses typed)
              after.loop.state == { driver.loop.state with echo := Editor.Minibuffer.notOpen }
            let (unbound, steps) := fedTo driver (accept ++ cancel)
            !Editor.Minibuffer.notOpen.isEmpty && said "C-c 1" && said "C-c 2" &&
              steps.all (·.all (·.ended.isNone)) &&
              unbound.loop.state == driver.loop.state },
    { name :=
        "a second prompt asked for while one is open, by a key of the global keymap typed in the minibuffer: the command says the refusal, the first prompt is still open with its text, and no text was made"
      run :=
        pure <|
          match shippedMinibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h")
            let (again, _) := fedTo typed (presses "C-c a")
            promptEcho again == s!"not asked: {(PromptRefusal.alreadyOpen ⟨1⟩).describe}" &&
              again.loop.state.prompt == typed.loop.state.prompt &&
              again.loop.state.prompt.isSome &&
              minibufferText again == some "h" &&
              again.model.texts.texts.size == typed.model.texts.texts.size },
    { name :=
        "a prompt does not capture the keyboard: with the focus moved to the window while the prompt is open, a key that prints goes to the window's buffer and the prompt waits; with the focus moved back, the accept key answers with what the minibuffer held"
      run :=
        pure <|
          match shippedMinibufferDriver with
          | none => false
          | some driver =>
            let (away, _) := fedTo driver (presses "C-c a h C-c w x")
            let (back, _) := fedTo away (presses "C-c v")
            let (accepted, _) := fedTo back accept
            away.loop.state.frame.focused == ⟨0⟩ && away.loop.state.prompt.isSome &&
              driverText away == some "x" &&
              minibufferText away == some "h" &&
              back.loop.state.frame.focused == ⟨1⟩ &&
              promptEcho accepted == greeted (answer "h") &&
              closed accepted &&
              driverText accepted == some "x" },
    { name :=
        "with the asking view closed while the prompt is open: the prompt stays open, and after the accept key the focus is on the first window of the list, which is the target of the continuation's command"
      run :=
        pure <|
          match shippedMinibufferDriver twoBuffers with
          | none => false
          | some driver =>
            let (closing, _) := fedTo driver (presses "C-c a h C-c k")
            let (accepted, _) := fedTo closing accept
            closing.loop.state.prompt.map (·.asker) == some ⟨0⟩ &&
              closing.loop.state.windows.map (·.id) == #[⟨1⟩, ⟨2⟩] &&
              closing.loop.state.frame.focused == ⟨2⟩ &&
              promptEcho accepted == greeted (answer "h") 1 &&
              closed accepted ⟨1⟩ &&
              accepted.loop.state.windows.map (·.id) == #[⟨1⟩] },
    { name :=
        "the minibuffer's command that deletes backward, run on an empty minibuffer, closes the prompt as the cancel command does, and the command the prompt named is not run; the command that deletes to the input's start, run there, leaves the prompt open; each, run by name with no prompt open, says that no prompt is open in the echo area"
      run :=
        pure <|
          match shippedMinibufferDriver with
          | none => false
          | some driver =>
            let ran (on : TestDriver) (name : String) : TestDriver :=
              (on.stepped (on.loop.runNamed on.handed name)).1
            let (typed, _) := fedTo driver (presses "C-c a h")
            let erased := ran typed Editor.Minibuffer.deleteBackwardName
            let kept := ran erased Editor.Minibuffer.deleteToStartName
            let emptied := ran kept Editor.Minibuffer.deleteBackwardName
            minibufferText erased == some "" && erased.loop.state.prompt.isSome &&
              minibufferText kept == some "" &&
              kept.loop.state.prompt.isSome &&
              closed emptied &&
              promptEcho emptied == "" &&
              !Editor.Minibuffer.notOpen.isEmpty &&
              [Editor.Minibuffer.deleteBackwardName, Editor.Minibuffer.deleteToStartName].all
                fun name => promptEcho (ran driver name) == Editor.Minibuffer.notOpen },
    { name :=
        "the minibuffer's command that takes a batch, delivered as a job's post with arguments that are no batch, says minibuffer-candidates: malformed batch in the echo area, and the open prompt's asking source takes nothing"
      run :=
        pure <|
          match shippedMinibufferDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let source : Completion.Asking :=
              { source := "later", later := { job := "j" }, askedFor := "", generation := 1 }
            let set :=
              { asking with
                loop :=
                  { asking.loop with
                    state := (asking.loop.state.setCandidates { asking := #[source] }).2 } }
            let bad :=
              (set.stepped
                  (set.loop.deliver set.handed "job 1 later"
                    (runPosted
                      { command := Editor.Minibuffer.candidatesName, arguments := [.str "x"] }))).1
            asking.loop.state.prompt.isSome &&
              bad.model.display.scenes.back?.map (·.echo) ==
                some s!"{Completion.candidatesCommand}: malformed batch" &&
              (candidatesOf bad).map (·.asking) == (candidatesOf set).map (·.asking) },
    { name :=
        "the minibuffer that ships registers its commands under the kit's minibuffer names, in order, and its one mode under the name and with the roles of the kit's"
      run :=
        pure
          (Editor.Minibuffer.package.registered.commands.map (·.name) == Test.Minibuffer.names &&
            Editor.Minibuffer.package.registered.modes.map (fun mode => (mode.name, mode.roles)) ==
              Test.Minibuffer.package.registered.modes.map fun mode => (mode.name, mode.roles)) },
    { name :=
        "the minibuffer's commands are registered under their nine names, each another, the one that asks for the input scheme under the name the core's test kit's minibuffer registers its own, which a scheme yields, and the one that takes a batch under the name a source's job posts; its one mode is called by the name the minibuffer's buffer is made with, fills four roles, to accept, to cancel and to move to the next and the previous candidate, each with its command, and has no problem under the test scheme"
      run :=
        pure
          (Editor.Minibuffer.package.registered.commands.map (·.name) ==
              #[Editor.Minibuffer.acceptName, Editor.Minibuffer.cancelName,
                Editor.Minibuffer.nextName, Editor.Minibuffer.previousName,
                Editor.Minibuffer.insertName, Editor.Minibuffer.deleteBackwardName,
                Editor.Minibuffer.deleteToStartName, Editor.Minibuffer.askName,
                Editor.Minibuffer.candidatesName] &&
            (Editor.Minibuffer.package.registered.commands.map (·.name)).toList.eraseDups.length ==
              9 &&
            Editor.Minibuffer.askName == Test.Minibuffer.askName &&
            Editor.Minibuffer.candidatesName == Completion.candidatesCommand &&
            Editor.Minibuffer.package.registered.modes.map (·.name) == #[Prompt.mode] &&
            Editor.Minibuffer.package.registered.modes.map (·.roles) ==
              #[[(Role.activate, Editor.Minibuffer.acceptName),
                  (Role.quit, Editor.Minibuffer.cancelName),
                  (Role.nextItem, Editor.Minibuffer.nextName),
                  (Role.previousItem, Editor.Minibuffer.previousName)]] &&
            Editor.Minibuffer.package.registered.modes.all fun mode =>
              mode.check TestScheme.scheme == []) }]

end MinibufferTest
