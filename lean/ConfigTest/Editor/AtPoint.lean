import ConfigTest.Check
import ConfigTest.Support.Shipped
import Editor.File.Model
import Editor.Headless
import Editor.InputScheme.Test
import Editor.Job.Fake
import Editor.Job.Runner
import Editor.Scene
import Editor.Test.Editing
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Listings
import Editor.Test.Linked.Shipped

/-!
# Config tests: completion at point

The tests of completion at point through the headless host:
`atPointChecks`. Completion at point's commands are the default package
`at-point`'s (`packages/at-point/AtPoint.lean`); these test what the core
does with an at-point package's commands and config's sources.
The root module `ConfigTest` runs them; its module doc says what each shows.

They complete at point through the core's test kit's at-point package
(`Editor/Test/AtPoint.lean`, by `withKitAtPoint`) and the sources config
defines, so nothing of the package that ships is asked: what its `words`
answers is pinned by that package's `AtPointTest.wordsChecks`, and its
commands by its `AtPointTest.atPointChecks` and its headless fixture
`at-point`. Their hosts run the test scheme, on keys of the checks' own
(`atPointTyping`): which keys a shipped scheme puts those commands on is
that scheme's.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- What the source `listed` of `listedText` answers, whatever it is
asked. -/
def listedTexts : Array String :=
  #["alpha", "beta", "almond", "alpaca"]

/-- A config whose `setup` defines the source `listed`, of the category
`listed`, which answers later, from its job `listed`, the texts of
`listedTexts` in one batch, is asked once and reads the open buffers'
texts; the at-point source `typed`, the run of letters before the cursor on
its line completed from `listed`, asked by itself after a pause of 240 ms,
when on a pause that run holds two letters or more; and uses `typed` in
every buffer. -/
def listedText : String :=
  "def setup : SetupM Unit := do
  sourceJob \"listed\" fun _ deliver =>
    deliver #[.ofText \"alpha\", .ofText \"beta\", .ofText \"almond\", .ofText \"alpaca\"]
  defineSource
    { name := \"listed\", category := \"listed\", candidates := fun _ => pure #[]
      later := some { job := \"listed\", reask := .never, readsTexts := true } }
  defineAtPoint
    { name := \"typed\", pause := some 240
      ask := fun spot => do
        let .ok target ← spot.view.target | return none
        let text := target.buffer.text
        let lineStart ← text.motion .lineStart spot.offset
        let line ← text.slice lineStart spot.offset
        let word := String.ofList (line.toList.reverse.takeWhile Char.isAlpha).reverse
        if spot.occasion matches .pause _ && word.length < 2 then
          return none
        return some
          { start := spot.offset - word.utf8ByteSize, stop := spot.offset
            sources := [.source \"listed\"] } }
  useAtPoint \"typed\"
"

/-- A config whose `setup` defines the source `members`, of the category
`member`, listing `field` and `method`; the at-point source `dots`, an empty
region at the cursor completed from `members`, asked by itself when `.` is
typed; and uses `dots` in every buffer. -/
def dotsText : String :=
  "def setup : SetupM Unit := do
  defineSource (Completion.Source.ofTexts \"members\" \"member\" #[\"field\", \"method\"])
  defineAtPoint
    { name := \"dots\", triggers := ['.']
      ask := fun spot =>
        pure (some { start := spot.offset, stop := spot.offset, sources := [.source \"members\"] }) }
  useAtPoint \"dots\"
"

/-- Whether no decoration line of `lines` draws a row in the face of a
chosen candidate: nothing is chosen in the candidate list. -/
def noneChosen (lines : Array String) : Bool :=
  !lines.any fun line =>
      line.startsWith "decorations " && (line.splitOn listedChosenFace.name).length > 1

/-- The keys the checks type, as a package that comes last: the kit's
editing commands (`Test.editingCommands`), so a printable key types its
character under the test scheme, on the kit's editing keys but `RET`; the
keys of completion at point, each on the kit's at-point command a scheme's
table of the state where typing is text binds it to
(`Editor/Test/AtPoint.lean`): `C-n` on `at-point-next`, `RET` on
`at-point-return` and `C-g` on `at-point-quit`; and a stand-in for
`insert-newline`, which the kit's `at-point-return` runs by name with no
session open and a scheme's package registers. -/
def atPointTyping : Package :=
  { name := "at-point-typing"
    setup := do
      for (name, run) in Test.editingCommands do
        commandWith name run
      commandWith "insert-newline" fun call => call.target.insertLineBreak
      for (text, name) in Test.editingKeys.filter (·.1 != "RET") do
        bindKey text name
      bindKey "C-n" Test.AtPoint.nextName
      bindKey "RET" Test.AtPoint.returnName
      bindKey "C-g" Test.AtPoint.quitName }

/-- Runs `check` against a host of the test scheme made as the executable's
hosts are made (`withShippedHost TestScheme.scheme`), handed the packages
the config tests host with the kit's at-point package
(`withKitAtPoint shippedPackages`) and then the checks' keys
(`atPointTyping`), over a stepped stage (`Stage.stepped`): its jobs run on
the check's steps. -/
def withAtPointHost (context : Context) (files : List (String × String))
    (check : Session → IO Bool) : IO Bool :=
  withShippedHost TestScheme.scheme context files check (packages :=
    withKitAtPoint shippedPackages ++ #[atPointTyping])

/-- A check of `atPointChecks`, a declaration of its own. -/
def keyPointNextTypingCheck (context : Context) : Check :=
  { name :=
      "the key of at-point-next, where typing is text, lists what config's source that answers later answers that matches the word before the cursor, its job started"
    run :=
      withAtPointHost context [("init.lean", listedText)] fun session => do
        session.ask [.reload]
        session.resize 640 480
        session.commit "alpha beta al"
        session.typed "C-n"
        session.step
        let lines ← session.sceneLines
        let rows ← realOrder "al" listedTexts
        let some listId := listViewId lines | return false
        let some (_, listY, _, listHeight) := printedRect lines listId | return false
        let some (_, windowY, _, windowHeight) := printedRect lines 0 | return false
        let output ← session.lines
        return rows.length == 3 && listViewShows lines rows && noneChosen lines &&
            windowY + windowHeight == listY &&
            listY + listHeight < 480 &&
            listHeight > 0 &&
            (lines.filter (·.startsWith "view ")).size == 2 &&
            output.any (fun line => line.startsWith "job " && line.endsWith " listed: started") &&
            !output.any (·.startsWith "loop: refused") }

/-- A check of `atPointChecks`, a declaration of its own. -/
def pausingTypingTwoCharactersCheck (context : Context) : Check :=
  { name :=
      "pausing after typing two characters of a word opens a session of config's source that pauses, with nothing chosen, and after one character it answers nothing and nothing opens"
    run := do
      let first ←
        withAtPointHost context [("init.lean", listedText)] fun session => do
            session.ask [.reload]
            session.resize 640 480
            session.commit "alpha alpine"
            session.typed "RET a l"
            let armed ← session.clock.waiting
            let before ← session.sceneLines
            let started := (← session.lines).filter (·.startsWith "job ")
            session.clock.advance 240
            session.step
            let lines ← session.sceneLines
            let rows ← realOrder "al" listedTexts
            return armed == 1 && started.isEmpty && (listViewId before).isNone &&
                rows.length == 3 &&
                listViewShows lines rows &&
                noneChosen lines
      let second ←
        withAtPointHost context [("init.lean", listedText)] fun session => do
            session.ask [.reload]
            session.resize 640 480
            session.commit "beta"
            session.typed "RET a"
            session.clock.advance 240
            session.step
            return (listViewId (← session.sceneLines)).isNone
      return first && second }

/-- A check of `atPointChecks`, a declaration of its own. -/
def typedKeyArmsPauseCheck (context : Context) : Check :=
  { name :=
      "a typed key arms one pause wait and starts no job: after a b the clock holds one wait and has withdrawn one, the table of waits holds one, no job line is printed, and the fake scheduler holds no job's code"
    run :=
      withAtPointHost context [("init.lean", listedText)] fun session => do
        session.ask [.reload]
        session.typed "a b"
        let waiting ← session.clock.waiting
        let withdrawn := (← session.clock.withdrawn).size
        session.typed "c d e"
        let afterMore ← session.clock.waiting
        let withdrawnMore := (← session.clock.withdrawn).size
        let some fakes := session.fakes | return false
        let held ← fakes.services.scheduler.size
        let jobLines := (← session.lines).filter (·.startsWith "job ")
        let table ← session.clock.completions.waiting
        return waiting == 1 && withdrawn == 1 && afterMore == 1 && withdrawnMore == 4 &&
            table == 1 &&
            held == 0 &&
            jobLines.isEmpty }

/-- A check of `atPointChecks`, a declaration of its own. -/
def pauseEventQueuedClockCheck (context : Context) : Check :=
  { name :=
      "the pause's event is queued before the clock's move returns: advance then a drain that steps nothing, five times over, each time finds the session the pause opened started, and a step then lists it"
    run :=
      withAtPointHost context [("init.lean", listedText)] fun session => do
        session.ask [.reload]
        session.resize 640 480
        session.commit "alpha alpine"
        let mut held := true
        for _ in [0:5] do
          session.typed "RET a l"
          let before := (← session.output.get).size
          -- No settle between the move and the drain: the drain, which
          -- steps no job, must find the pause's event queued, and the
          -- session it opens started.
          session.clock.advance 240
          unless ← session.handled do
            return false
          let after ← session.output.get
          let opened :=
            (after.extract before after.size).any fun line =>
              line.startsWith "job " && line.endsWith " listed: started"
          session.step
          let lines ← session.sceneLines
          held := held && opened && (listViewId lines).isSome
          session.typed "C-g"
        return held }

/-- The checks of completion at point through the headless host of the
test scheme (`withAtPointHost`), with the real elaborator, the real text
binding, the recorder and the stage's fake clock
(`docs/design/keymaps-and-modes.md`, "Completion at point"), on the kit's
at-point package and keys of the checks' own (`atPointTyping`). -/
def atPointChecks (context : Context) : List Check :=
  [keyPointNextTypingCheck context,
    { name :=
        "a source that declares a trigger character opens a session when that character is typed, and no other character does"
      run :=
        withAtPointHost context [("init.lean", dotsText)] fun session => do
          session.ask [.reload]
          session.resize 640 480
          session.typed "a x"
          let before ← session.sceneLines
          session.typed "."
          let dotted ← session.sceneLines
          session.typed "C-g"
          let closed ← session.sceneLines
          let rows ← realOrder "" #["field", "method"]
          return (listViewId before).isNone && listViewShows dotted rows && noneChosen dotted &&
              rows.length == 2 &&
              (listViewId closed).isNone },
    pausingTypingTwoCharactersCheck context, typedKeyArmsPauseCheck context,
    pauseEventQueuedClockCheck context]

end ConfigTest
