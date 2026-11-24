import ConfigTest.Check
import ConfigTest.Support.Shipped
import Editor.Completion.Keys
import Editor.ModeLine
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Listings

/-!
# Config tests: `Editor/Completion/Keys.lean`

The tests of `Editor/Completion/Keys.lean`: `keyHintChecks`, when and where
the key hints' source is shown after its delay, and the pending keys drawn,
through a host of the test scheme, under its leader (`schemeLeader`). The root
module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- A config whose `setup` registers `leader-find`, which says `leader find`
in the echo area, binds `<leader> f f` to it described as `Find file` and
`<leader> s` described as `Save`, and names the prefix `<leader> f` `file`;
with `keyHintDelay` and `delay` when one is given, and, with `display`,
defines `Display.plain "plain"` and chooses it for the category `key`. -/
def delayText (delay : Option String) (display : Bool := false) : String :=
  "def setup : SetupM Unit := do
  command \"leader-find\" (message \"leader find\")
  bindKey \"<leader> f f\" \"leader-find\" (desc := \"Find file\")
  bindKey \"<leader> s\" \"leader-find\" (desc := \"Save\")
  prefixName \"<leader> f\" \"file\"
" ++
    (delay.map (s!"  keyHintDelay {·}\n")).getD "" ++
    if display then
      "  defineDisplay (Completion.Display.plain \"plain\")\n  useDisplayFor \"key\" \"plain\"\n"
    else ""

/-- The hints `delayText` gives after the leader, in the scheme's order. -/
def leaderHints : Array KeyHint :=
  #[{ key := "f", leads := .prefix (some "file") 1 },
    { key := "s", leads := .binding (some "Save") }]

/-- The rows `display` draws of `hints` as the key hints' list: a listing of
their candidates (`Completion.Keys.candidates`) of the category `key`, with
nothing chosen. -/
def hintSheetRows (hints : Array KeyHint) (display : Completion.Display := rowsDisplay) :
    List String :=
  (display.sheet
        { listed := (Completion.Keys.candidates hints).map (Completion.Listed.of ·)
          category := some Completion.Keys.category }).rows.toList.map
    (·.text)

/-- Whether a status line of `lines` holds `text` as the first field on its
right side, in `mode-line.secondary`: the pending keys' segment. -/
def pendingDrawn (lines : Array String) (text : String) : Bool :=
  lines.any fun line =>
    line.startsWith "status " &&
      (line.splitOn s!" | {ModeLine.secondaryFace.name} {text.quote} +{ModeLine.padding}").length ==
        2

/-- Whether no status line of `lines` draws pending keys under the leader:
none holds a field in `mode-line.secondary` that starts with the scheme's
leader. -/
def noPendingDrawn (lines : Array String) : Bool :=
  !lines.any fun line =>
      line.startsWith "status " &&
        (line.splitOn s!"{ModeLine.secondaryFace.name} \"{schemeLeader}").length > 1

/-- A check of `keyHintChecks`, a declaration of its own. -/
def ac1SchemeLeaderDefaultCheck (context : Context) : Check :=
  { name :=
      "AC1: after the scheme's leader and the default delay on the fake clock, the scene lists the keys that can follow it with their descriptions and prefix names, drawn by the minibuffer display directly above the bottom row; none before the delay has passed"
    run :=
      withTestHost context [("init.lean", delayText none)] (stepped := true) fun session => do
        session.resize 640 480
        session.ask [.reload]
        session.typed schemeLeader
        let pending ← session.sceneLines
        let armed := (← session.clock.waiting) == 1
        session.clock.advance 499
        session.step
        let before ← session.sceneLines
        session.clock.advance 1
        session.step
        let after ← session.sceneLines
        let heights := Headless.cells.heights
        let listed := hintSheetRows leaderHints
        let rect := (listViewId after).bind (printedRect after)
        return armed && (listViewId pending).isNone && !pending.any (·.startsWith "hint ") &&
            (listViewId before).isNone &&
            !before.any (·.startsWith "hint ") &&
            after.filter (·.startsWith "hint ") ==
              #["hint f: prefix \"file\" 1", "hint s: binding \"Save\""] &&
            listViewShows after listed &&
            rect.map (fun (_, y, _, height) => y + height) == some (480 - heights.message) }

/-- A check of `keyHintChecks`, a declaration of its own. -/
def configSetsDelayNeverCheck (context : Context) : Check :=
  { name :=
      "a config that sets the delay to .never arms no wait and shows no hints however long the prefix is pending, and the pending keys are still drawn"
    run :=
      withTestHost context [("init.lean", delayText (some ".never"))] (stepped := true)
        fun session => do
        session.ask [.reload]
        session.typed schemeLeader
        let armed ← session.clock.waiting
        session.clock.advance 10000
        session.step
        let lines ← session.sceneLines
        return armed == 0 && (listViewId lines).isNone && !lines.any (·.startsWith "hint ") &&
            pendingDrawn lines schemeLeader }

/-- A check of `keyHintChecks`, a declaration of its own. -/
def reloadDefaultDelayPassedCheck (context : Context) : Check :=
  { name :=
      "a reload before the default delay has passed keeps its wait when the delay is still wanted, so the hints are shown 500 ms after the scheme's leader; one that sets .never withdraws the wait, and one that then sets the delay again arms a new wait of the whole delay, all with the leader still pending"
    run :=
      withTestHost context [("init.lean", delayText none)] (stepped := true) fun session => do
        session.ask [.reload]
        session.typed schemeLeader
        let armed := (← session.clock.waiting) == 1
        let withdrawnArmed := (← session.clock.withdrawn).size
        session.clock.advance 200
        session.step
        -- A reload that leaves the delay as it was: the wait is kept.
        session.ask [.reload]
        let kept :=
          (← session.clock.waiting) == 1 && (← session.clock.withdrawn).size == withdrawnArmed
        session.clock.advance 299
        session.step
        let early ← session.sceneLines
        session.clock.advance 1
        session.step
        let due ← session.sceneLines
        session.typed "<Escape>"
        session.typed schemeLeader
        let withdrawnPending := (← session.clock.withdrawn).size
        -- A reload that sets `.never`: the wait is withdrawn.
        session.write "init.lean" (delayText (some ".never"))
        session.ask [.reload]
        let closed :=
          (← session.clock.waiting) == 0 && (← session.clock.withdrawn).size == withdrawnPending + 1
        -- A reload that sets the delay again: a new wait of the whole delay.
        session.write "init.lean" (delayText none)
        session.ask [.reload]
        let rearmed := (← session.clock.waiting) == 1
        session.clock.advance 499
        session.step
        let rearmedEarly ← session.sceneLines
        session.clock.advance 1
        session.step
        let rearmedDue ← session.sceneLines
        return armed && kept && !early.any (·.startsWith "hint ") &&
            due.filter (·.startsWith "hint ") ==
              #["hint f: prefix \"file\" 1", "hint s: binding \"Save\""] &&
            closed &&
            rearmed &&
            !rearmedEarly.any (·.startsWith "hint ") &&
            pendingDrawn rearmedEarly schemeLeader &&
            rearmedDue.filter (·.startsWith "hint ") ==
              #["hint f: prefix \"file\" 1", "hint s: binding \"Save\""] }

/-- The checks of when and where the key hints are shown, and of the pending
keys drawn, through a host of the test scheme (`withTestHost`),
with the real elaborator, the fake clock the host's waits are on and the
recorder: the phase's five criteria, a delay of `.never`, a reload while a
prefix is pending (the publish after an install, `Headless.Running.publish`),
and the delays a reload refuses. What the hints list is `hintChecks`'; how the delay is
armed and the list placed, `ModelTest`'s. -/
def keyHintChecks (context : Context) : List Check :=
  [ac1SchemeLeaderDefaultCheck context,
    { name :=
        "AC2: completing the sequence, or resetting it with an unbound key, before the delay passes withdraws the delay and leaves no hints in the scene after it"
      run :=
        withTestHost context [("init.lean", delayText none)] (stepped := true) fun session => do
          session.ask [.reload]
          let withdrawnBefore := (← session.clock.withdrawn).size
          session.typed s!"{schemeLeader} f f"
          let completed := (← session.echo) == "leader find".quote
          let afterCompleting := (← session.clock.waiting) == 0
          let withdrawnOnce := (← session.clock.withdrawn).size == withdrawnBefore + 1
          session.clock.advance 500
          let completedLines ← session.sceneLines
          session.typed s!"{schemeLeader} z"
          let afterReset := (← session.clock.waiting) == 0
          session.clock.advance 500
          let resetLines ← session.sceneLines
          return completed && afterCompleting && withdrawnOnce && afterReset &&
              (listViewId completedLines).isNone &&
              !completedLines.any (·.startsWith "hint ") &&
              (listViewId resetLines).isNone &&
              !resetLines.any (·.startsWith "hint ") },
    { name :=
        "AC3: a config that sets the delay to 0 shows the hints in the first scene after the prefix, with no wait on the clock"
      run :=
        withTestHost context [("init.lean", delayText (some "0"))] fun session => do
          session.ask [.reload]
          session.typed schemeLeader
          let lines ← session.sceneLines
          return (← session.clock.waiting) == 0 &&
              lines.filter (·.startsWith "hint ") ==
                #["hint f: prefix \"file\" 1", "hint s: binding \"Save\""] &&
              listViewShows lines (hintSheetRows leaderHints) },
    { name :=
        "AC4: the pending prefix is drawn in the selected window's status line while a sequence is pending, the scheme's leader then the leader and f, and cleared when it completes"
      run :=
        withTestHost context [("init.lean", delayText none)] (stepped := true) fun session => do
          session.ask [.reload]
          let rest ← session.sceneLines
          session.typed schemeLeader
          let leader ← session.sceneLines
          session.typed "f"
          let prefixed ← session.sceneLines
          session.typed "f"
          let completed ← session.sceneLines
          return noPendingDrawn rest && pendingDrawn leader schemeLeader &&
              pendingDrawn prefixed s!"{schemeLeader} f" &&
              noPendingDrawn completed &&
              (← session.echo) == "leader find".quote },
    { name :=
        "AC5: a display config sets for the key category draws the hints: the fake display's rows, not the minibuffer display's"
      run :=
        withTestHost context [("init.lean", delayText (some "0") (display := true))] fun session =>
          do
          session.ask [.reload]
          session.typed schemeLeader
          let lines ← session.sceneLines
          let plain := hintSheetRows leaderHints (Completion.Display.plain "plain")
          return plain == ["  f", "  s"] && listViewShows lines plain &&
              !listViewShows lines (hintSheetRows leaderHints) },
    configSetsDelayNeverCheck context,
    { name :=
        "a reload that sets the delay to .never while the scheme's leader is pending with its hints shown closes them: the scene after it lists no hints and draws no list, and the leader is still drawn pending"
      run :=
        withTestHost context [("init.lean", delayText (some "0"))] fun session => do
          session.ask [.reload]
          session.typed schemeLeader
          let shown ← session.sceneLines
          session.write "init.lean" (delayText (some ".never"))
          session.ask [.reload]
          let lines ← session.sceneLines
          return shown.any (·.startsWith "hint ") && (listViewId shown).isSome &&
              (listViewId lines).isNone &&
              !lines.any (·.startsWith "hint ") &&
              pendingDrawn lines schemeLeader },
    reloadDefaultDelayPassedCheck context,
    { name :=
        "a reload refuses a delay over a minute, saying keyHintDelayTooLong's sentence, a delay that is not one, and a delay set twice; the previous config's bindings keep working"
      run :=
        withTestHost context [("init.lean", delayText (some "0"))] fun session => do
          session.ask [.reload]
          -- The frame is made, so each refusal is said in its echo area.
          session.typed "<Escape>"
          let refusedWith (delay : String) : IO (Bool × String) := do
            session.write "init.lean" (delayText (some delay))
            let before := (← session.output.get).size
            session.ask [.reload]
            let printed := (← session.output.get).extract before
            return (printed.any fun line => line.startsWith "reload " && line.endsWith ": rejected",
                ← session.echo)
          let (tooLong, tooLongEcho) ← refusedWith "60001"
          let (notADelay, _) ← refusedWith "0.5"
          let (twice, twiceEcho) ← refusedWith "0\n  keyHintDelay 250"
          session.typed s!"{schemeLeader} f f"
          return tooLong &&
              (tooLongEcho.splitOn (Completion.Keys.keyHintDelayTooLong 60001)).length == 2 &&
              notADelay &&
              twice &&
              (twiceEcho.splitOn Config.Registrations.keyHintDelayTwice).length == 2 &&
              (← session.echo) == "leader find".quote }]

end ConfigTest
