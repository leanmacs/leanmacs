import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Completion.Fake
import Editor.Completion.Later
import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.Fuzzy.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Program
import Editor.ProjectMode
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Test.Completion
import Editor.Test.Config
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Test.Prompts
import Editor.Text
import Editor.Value
import Editor.Workspace
import ModelTest.Support.Listings

/-!
# Model tests: support: Candidates

The fixture of the candidate checks: the prompts they ask, with the sources,
commands, keys and drivers they ask them with, and what a scene shows of an open
prompt and its candidate list. Shared by several test modules under
`ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The candidates the prompts of the candidate checks are asked with. The
one a check types whole, `w`, is last, and two before it hold a `w`. -/
def pickCandidates : Array String :=
  #["wq", "edit", "rewrite", "w"]

/-- The continuation the prompts of the candidate checks are asked with:
the command `picked` and an argument of the asker's own. -/
def pickContinuation : Invocation :=
  { command := "picked", arguments := [.nat 7] }

/-- What the command `picked` of the candidate checks says in the echo
area: the arguments it was called with. -/
def picked (arguments : List Argument) : String :=
  s!"picked {arguments.map argumentText}"

/-- The label of the prompts of the candidate checks. -/
def pickLabel : String :=
  "Pick: "

/-- The source the prompts of the candidate checks are asked with: the
model's, called `pick`, over `pickCandidates`. -/
def pickSource : Completion.Source :=
  .ofTexts "pick" "pick" pickCandidates

/-- The candidates a prompt asked with `pickSource` holds, each in its
group. -/
def pickOffered : Array Completion.Candidate :=
  (offered pickCandidates).map (·.inGroup pickSource.name)

/-- The two sources one command of the candidate checks asks with at once:
`a`, of `wq` and `edit`, then `b`, of `rewrite` and `w`. -/
def pickHalves : List Completion.SourceRef :=
  [.given (.ofTexts "a" "pick" #["wq", "edit"]), .given (.ofTexts "b" "pick" #["rewrite", "w"])]

/-- A source of the candidate checks that declares it has filtered already:
`fixed`, of the category `other`, answering `zz` and `w` whatever it is
asked. -/
def filteredSource : Completion.Source :=
  { Completion.Source.ofTexts "fixed" "other" #["zz", "w"] with filtered := true }

/-- Fifteen candidates' texts, `c0` to `c14`: more than the display written
for the core's tests shows (`windowedRows`). -/
def manyTexts : Array String :=
  (Array.range 15).map (s!"c{·}")

/-- The commands of the candidate checks, by name.

- `ask-pick` asks `Pick: ` with `pickSource`, given as a value, and the
  continuation `pickContinuation`; `ask-pick-w` asks the same with the
  initial value `w`; `ask-plain` asks with no source.
- `ask-two` asks with `pickHalves`; `ask-grouped` with a source `c` whose
  first candidate has a group of its own; `ask-refusing` with a source that
  is refused (`Completion.Fake.refusing`); `ask-echo` with the initial
  value `w` and a source that answers what it was asked
  (`Completion.Fake.echo`).
- `ask-named` asks with the source registered under `pick`, by name, and
  says the refusal in the echo area when the prompt is refused.
- `ask-filtered` asks with `pickSource` and `filteredSource`, a source
  that has filtered already; `ask-only-filtered` asks with
  `filteredSource` alone.
- `ask-category` asks for the sources of the category `pick`, with
  `pickSource` as its default.
- `ask-other` asks with a source of the category `other` over
  `pickCandidates`.
- `ask-many` asks with a source of the category `pick` over `manyTexts`,
  more than the minibuffer display shows.
- `picked` says what it was called with (`picked`).
- `accept` and `cancel` are the API's operations.
- The test scheme's self-insert inserts its argument at its target's
  cursors.
- `still` does nothing, and `edit-then-fail` inserts `x` at its target's
  cursors and is then refused.
- `delete-backward` is the minibuffer's command that deletes the character
  before its cursor (`Test.Minibuffer.deleteBackward`). -/
def candidateCommands : List (String × Dispatched) :=
  let asks (initial : String) (sources : List Completion.SourceRef) : Dispatched := fun _ => do
    discard <| prompt pickLabel pickContinuation initial sources
    return none
  [("ask-pick", asks "" [.given pickSource]), ("ask-pick-w", asks "w" [.given pickSource]),
    ("ask-plain", asks "" []), ("ask-two", asks "" pickHalves),
    ("ask-grouped",
      asks "" [.given (.fixed "c" "pick" #[{ text := "x", group := some "own" }, .ofText "y"])]),
    ("ask-refusing", asks "" [.given (Completion.Fake.refusing "no" "pick")]),
    ("ask-echo", asks "w" [.given (Completion.Fake.echo "echo" "pick")]),
    ("ask-filtered", asks "" [.given pickSource, .given filteredSource]),
    ("ask-only-filtered", asks "" [.given filteredSource]),
    ("ask-category", asks "" [.category "pick" [pickSource]]),
    ("ask-other", asks "" [.given (.ofTexts "other" "other" pickCandidates)]),
    ("ask-many", asks "" [.given (.ofTexts "many" "pick" manyTexts)]),
    ("ask-later", asks "" [.given (.answeringLater "later" "pick" "later-pick")]),
    ("ask-echo-later",
      asks "" [.given (.answeringLater "echo" "pick" "later-echo" (.afterPause 30) true)]),
    ("ask-dir", asks "" [.given (.answeringLater "dir" "pick" "later-dir" (.beforeLast '/'))]),
    ("ask-dir-refusing",
      asks "" [.given (.answeringLater "dir" "pick" "later-refusing" (.beforeLast '/'))]),
    (Test.Minibuffer.candidatesName, fun call => do
      Test.Minibuffer.candidates call
      return none),
    ("ask-named", fun _ => do
      if let .error refusal← prompt pickLabel pickContinuation "" [.named pickSource.name] then
        message refusal.describe
      return none),
    ("picked", fun call => do
      message (picked call.arguments)
      return none),
    ("accept", fun _ => do
      discard acceptPrompt
      return none),
    ("cancel", fun _ => do
      discard cancelPrompt
      return none),
    ((TestScheme.selfInsert "").command, fun call => do
      let [.str text] := call.arguments | throw .badRange
      call.target.insertAtSelections text
      return none),
    ("still", fun _ => return none),
    ("edit-then-fail", failingAfter fun call => call.target.insertAtSelections "x"),
    ("delete-backward", fun call => do
      Test.Minibuffer.deleteBackward call
      return none)]

/-- What a step of the candidate checks is handed: one keymap, the same for
every view, the minibuffer's among them, that binds a key sequence under
`C-c` to each command of `candidateCommands` but the self-insert and
`picked`, which no key runs. No key of it prints, so a key that prints is
a self-insert. Prompts are matched and shown by the style and the display
written for the core's tests (`marking`, `windowed`). -/
def candidateKeys : Loop.Keys TestScheme.scheme :=
  {
    dispatchKeys
      [("C-c a", invoke "ask-pick"), ("C-c w", invoke "ask-pick-w"), ("C-c p", invoke "ask-plain"),
        ("C-c y", invoke "accept"), ("C-c n", invoke "cancel"), ("C-c s", invoke "still"),
        ("C-c f", invoke "edit-then-fail"), ("C-c 2", invoke "ask-two"),
        ("C-c g", invoke "ask-grouped"), ("C-c r", invoke "ask-refusing"),
        ("C-c e", invoke "ask-echo"), ("C-c m", invoke "ask-named"),
        ("C-c 5", invoke "ask-filtered"), ("C-c 7", invoke "ask-category"),
        ("C-c 6", invoke "ask-other"), ("C-c 8", invoke "ask-only-filtered"),
        ("C-c l", invoke "ask-later"), ("C-c t", invoke "ask-echo-later"),
        ("C-c b", invoke "delete-backward"), ("C-c 9", invoke "ask-many"),
        ("C-c d", invoke "ask-dir"), ("C-c x", invoke "ask-dir-refusing")]
      candidateCommands with
    matching := markingMatching, displaying := windowedDisplaying }

/-- A driver over the initial state, with the commands of the candidate
checks and the jobs of the driver checks, on the models `model`; `none` if
making the state was refused. -/
def candidateDriver (model : EditorModel := editorModel) : Option TestDriver :=
  (Loop.Driver.over candidateKeys driverJobs (EditorState.initial ⟨640, 480⟩) model).toOption

/-- The registry of the candidate checks that press the minibuffer's keys:
the kit's minibuffer's commands and its mode (`Editor/Test/Minibuffer.lean`)
registered for the owner `compiled`,
an owner that is not config, as a host registers a package's, and as config's bindings two that ask and two
that run the commands that move through the list by their names, from any
view. -/
def pickRegistry : Config.Registry :=
  ((({} : Config.Registry).replace .compiled
            Test.Minibuffer.package.registered.commands).replaceModes
        .compiled Test.Minibuffer.package.registered.modes).replaceBindings
    .config
    ([("C-c a", "ask-pick"), ("C-c p", "ask-plain"), ("C-c 3", Test.Minibuffer.nextName),
          ("C-c 4", Test.Minibuffer.previousName)].toArray.map
      fun (text, command) => .ofKeys (keys text) command)

/-- What a step of those checks is handed: the active keymaps `pickRegistry`
makes for the test scheme from the loop's state, so the minibuffer's mode
holds in the minibuffer's view and nowhere else; the registry's commands,
each given its call; and, for any other name, the commands of the candidate
checks. -/
def pickKeys : Loop.Keys TestScheme.scheme :=
  { maps := pickRegistry.activeMaps TestScheme.scheme
    command? := fun name =>
      match pickRegistry.find? name with
      | some { registration := { action := .call run, .. }, .. } =>
        some fun call => do
          run call
          return none
      | _ => (candidateCommands.find? (·.1 == name)).map (·.2)
    matching := markingMatching, displaying := windowedDisplaying }

/-- A driver of those checks over the initial state, with the jobs of the
driver checks; `none` if making the state was refused. -/
def pickDriver : Option TestDriver :=
  (Loop.Driver.over pickKeys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- What a prompt asked with `pickCandidates` holds once they are listed
for `pattern`, with `chosen` as its choice: its category is `pick`, and the
listing is what the fuzzy model answers for the pattern, each with the
ranges `marking` gives it, so no order is written out here. -/
def pickListed (pattern : String) (chosen : Option Nat := none) : Candidates :=
  { all := pickOffered, category := some pickSource.category, listedFor := some pattern
    place := rootPlace
    listed :=
      (FuzzyModel.rank pattern pickCandidates).filterMap fun index =>
        (pickOffered[index]?).map fun candidate =>
          .of candidate (markedSpans pattern candidate.text)
    chosen }

/-- What a source's job is started with in the checks of sources that
answer later: the asking source 1 of the prompt in view 3, at its second
generation, asked for `w` from view 0, after a pause of 30 ms. -/
def laterOrder : Completion.Order :=
  { view := ⟨3⟩, index := 1, generation := 2, query := { text := "w", view := ⟨0⟩ }, pause := 30 }

end ModelTest
