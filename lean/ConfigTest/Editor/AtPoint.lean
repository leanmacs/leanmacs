import ConfigTest.Check
import ConfigTest.Support.Shipped
import Editor.File.Model
import Editor.Headless
import Editor.Job.Fake
import Editor.Job.Runner
import Editor.Scene
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Listings
import Editor.Test.Linked.Vim

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
`at-point`.
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

/-- The checks of completion at point through the headless host of the Vim
scheme that ships (`withVimHost`), with the real elaborator, the real text
binding, the recorder and the stage's fake clock
(`docs/design/keymaps-and-modes.md`, "Completion at point"), on the kit's
at-point package (`withKitAtPoint`). -/
def atPointChecks (context : Context) : List Check :=
  let packages := withKitAtPoint shippedPackages
  [{  name :=
        "C-n in insert state lists what config's source that answers later answers that matches the word before the cursor, its job started"
      run :=
        withVimHost context [("init.lean", listedText)] (packages := packages) fun session => do
          session.ask [.reload]
          session.host.resize 640 480
          session.typed "i"
          session.host.commit "alpha beta al"
          session.typed "C-n"
          unless (← session.host.join patience) == .settled do
            return false
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
              !output.any (·.startsWith "loop: refused") },
    { name :=
        "a source that declares a trigger character opens a session when that character is typed, and no other character does"
      run :=
        withVimHost context [("init.lean", dotsText)] (packages := packages) fun session => do
          session.ask [.reload]
          session.host.resize 640 480
          session.typed "i a x"
          let before ← session.sceneLines
          session.typed "."
          let dotted ← session.sceneLines
          session.typed "<Escape>"
          let closed ← session.sceneLines
          let rows ← realOrder "" #["field", "method"]
          return (listViewId before).isNone && listViewShows dotted rows && noneChosen dotted &&
              rows.length == 2 &&
              (listViewId closed).isNone },
    { name :=
        "pausing after typing two characters of a word opens a session of config's source that pauses, with nothing chosen, and after one character it answers nothing and nothing opens"
      run := do
        let first ←
          withVimHost context [("init.lean", listedText)] (packages := packages) fun session => do
              session.ask [.reload]
              session.host.resize 640 480
              session.typed "i"
              session.host.commit "alpha alpine"
              session.typed "RET a l"
              let armed ← session.clock.waiting
              let before ← session.sceneLines
              let started := (← session.lines).filter (·.startsWith "job ")
              session.clock.advance 240
              unless (← session.host.join patience) == .settled do
                return false
              let lines ← session.sceneLines
              let rows ← realOrder "al" listedTexts
              return armed == 1 && started.isEmpty && (listViewId before).isNone &&
                  rows.length == 3 &&
                  listViewShows lines rows &&
                  noneChosen lines
        let second ←
          withVimHost context [("init.lean", listedText)] (packages := packages) fun session => do
              session.ask [.reload]
              session.host.resize 640 480
              session.typed "i"
              session.host.commit "beta"
              session.typed "RET a"
              session.clock.advance 240
              unless (← session.host.join patience) == .settled do
                return false
              return (listViewId (← session.sceneLines)).isNone
        return first && second },
    { name :=
        "a typed key in insert state arms one pause wait and starts no job: after i a b the clock holds one wait and has withdrawn one, the table of waits holds one, no job line is printed, and a join returns at once"
      run :=
        withVimHost context [("init.lean", listedText)] (packages := packages) fun session => do
          session.ask [.reload]
          session.typed "i a b"
          let waiting ← session.clock.waiting
          let withdrawn := (← session.clock.withdrawn).size
          session.typed "c d e"
          let afterMore ← session.clock.waiting
          let withdrawnMore := (← session.clock.withdrawn).size
          let joined ← session.host.join patience
          let jobLines := (← session.lines).filter (·.startsWith "job ")
          let table ← session.clock.completions.waiting
          return waiting == 1 && withdrawn == 1 && afterMore == 1 && withdrawnMore == 4 &&
              table == 1 &&
              joined == .settled &&
              jobLines.isEmpty },
    { name :=
        "the pause's event is queued before the clock's move returns: advance then join, five times over, each time finds the session the pause opened listed"
      run :=
        withVimHost context [("init.lean", listedText)] (packages := packages) fun session => do
          session.ask [.reload]
          session.host.resize 640 480
          session.typed "i"
          session.host.commit "alpha alpine"
          let mut held := true
          for _ in [0:5] do
            session.typed "RET a l"
            -- No settle between the move and the join: the join's marker
            -- must find the pause's event ahead of it.
            session.clock.advance 240
            unless (← session.host.join patience) == .settled do
              return false
            let lines ← session.sceneLines
            held := held && (listViewId lines).isSome
            session.typed "C-g"
          return held }]

end ConfigTest
