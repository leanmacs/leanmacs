import ConfigTest.Check
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import ConfigTest.Support.Lines
import ConfigTest.Support.Syntax
import Editor.Completion.Candidate
import Editor.Completion.Displays
import Editor.Completion.Words
import Editor.File.Model
import Editor.Headless
import Editor.Job.Fake
import Editor.Job.Runner
import Editor.Scene

/-!
# Config tests: `Editor/AtPoint.lean`

The tests of `Editor/AtPoint.lean`: `atPointChecks`, through the headless host.
The root module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- A config whose `setup` registers `make-other`, bound to `C-c o`, which
makes a buffer `other` holding `almond alpaca`. -/
def otherBufferText : String :=
  "def setup : SetupM Unit := do
  command \"make-other\" (discard <| createBuffer \"other\" \"almond alpaca\")
  bindKey \"C-c o\" \"make-other\"
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
      line.startsWith "decorations " &&
        (line.splitOn Completion.Displays.chosenFace.name).length > 1

/-- The checks of completion at point through the headless host of the Vim
scheme that ships (`withVimHost`), with the real elaborator, the real text
binding, the recorder and the stage's fake clock (`Editor/AtPoint.lean`,
`docs/design/keymaps-and-modes.md`, "Completion at point"). -/
def atPointChecks (context : Context) : List Check :=
  [{  name :=
        "C-n in insert state lists the words of open buffers that match the word before the cursor"
      run :=
        withVimHost context [("init.lean", otherBufferText)] fun session => do
          session.ask [.reload]
          session.host.resize 640 480
          session.typed "C-c o i"
          session.host.commit "alpha beta al"
          session.typed "C-n"
          unless (← session.host.join patience) == .settled do
            return false
          let lines ← session.sceneLines
          let words :=
            Completion.Words.ordered #["alpha beta al", "almond alpaca"]
              (some { start := 11, stop := 13 })
          let rows ← realOrder "al" words
          let some listId := listViewId lines | return false
          let some (_, listY, _, listHeight) := printedRect lines listId | return false
          let some (_, windowY, _, windowHeight) := printedRect lines 0 | return false
          let output ← session.lines
          return rows.length == 3 && listViewShows lines rows && noneChosen lines &&
              windowY + windowHeight == listY &&
              listY + listHeight < 480 &&
              listHeight > 0 &&
              (lines.filter (·.startsWith "view ")).size == 2 &&
              output.any (fun line => line.startsWith "job " && line.endsWith " words: started") &&
              !output.any (·.startsWith "loop: refused") },
    { name :=
        "a source that declares a trigger character opens a session when that character is typed, and no other character does"
      run :=
        withVimHost context [("init.lean", dotsText)] fun session => do
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
        "pausing after typing two characters of a word opens a session of the words source, with nothing chosen"
      run := do
        let first ←
          withVimHost context [] fun session => do
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
              let rows ←
                realOrder "al"
                    (Completion.Words.ordered #["alpha alpine\nal"]
                      (some { start := 13, stop := 15 }))
              return armed == 1 && started.isEmpty && (listViewId before).isNone &&
                  rows.length == 2 &&
                  listViewShows lines rows &&
                  noneChosen lines
        let second ←
          withVimHost context [] fun session => do
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
        withVimHost context [] fun session => do
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
        withVimHost context [] fun session => do
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
