import Editor.Test.Jobs
import Editor.WindowCheck
import ModelTest.Check

/-!
# Model tests: `Editor/WindowCheck.lean`

The model tests of `Editor/WindowCheck.lean`: `windowTallyChecks`,
`windowLoopChecks` and `windowArgumentChecks`. The root module `ModelTest` runs
them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A key press that produced `text`. -/
def pressed (text : String) : WindowCheck.Input :=
  .key true false false text

/-- A key release, which produces no text. -/
def released : WindowCheck.Input :=
  .key false false false ""

/-- The tally of `arrivals`, counted in order from nothing. -/
def counted (arrivals : List WindowCheck.Arrival) : WindowCheck.Tally :=
  arrivals.foldl WindowCheck.Tally.step {}

/-- The tally of `inputs`, each arriving and handled at the instant 0. -/
def tallied (inputs : List WindowCheck.Input) : WindowCheck.Tally :=
  counted (inputs.map fun input => { input, arrived := 0, handled := 0 })

/-- `text` as often as `count` says. -/
def repeated (text : String) (count : Nat) : String :=
  String.join (List.replicate count text)

/-- A run whose window opened on the platform `fake` 2.5 ms after it was
asked for, and reported `inputs` after that, each arriving and handled at the
instant the window opened. -/
def opened (inputs : List WindowCheck.Input) (options : WindowCheck.Options := {})
    (ending : WindowCheck.Ending := .closed) : WindowCheck.Run :=
  { options, serviceOnMain := true, askedAt := 1000000, failure := none, ending
    tally :=
      counted
        ((.opened "fake" :: inputs).map fun input =>
          { input, arrived := 3500000, handled := 3500000 }) }

/-- A run whose window could not be opened, for the reason `reason`. Its
ending is what the check gives a run nothing ended. -/
def unopened (reason : String) : WindowCheck.Run :=
  { options := {}, serviceOnMain := true, askedAt := 1000000, failure := some reason, tally := {}
    ending := .closed }

/-- The report of a run with no window, after its second line: the forms
every line takes when nothing arrived. -/
def nothingArrived : List String :=
  ["focus: never gained; first pointer press in the window: none",
    "keys: 0 key events reached the Lean loop (0 presses, 0 of them repeats, 0 releases); text: \"\"",
    "latency from a key's arrival in Rust to its handling in Lean, in µs: no samples",
    "dead keys: 0 key events marked dead",
    "composition: not enabled; 0 preedit and 0 commit events; committed: \"\"",
    "ended: the window never opened"]

/-- What a fake window does in one check: the inputs it reports once it is
run, each with the instant it arrived and the instant the fake's clock reads
when the loop has pulled it. -/
structure FakeWindow where
  /-- What the window reports once it runs, in order. -/
  arrivals : List WindowCheck.Arrival := []
  /-- Why the window cannot be opened, if it cannot. -/
  cannotOpen : Option String := none
  /-- What the fake answers when asked where the main-thread service is. -/
  serviceOnMain : Bool := true
  /-- The clock's reading until the first input is pulled. -/
  askedAt : Nat := 0
  /-- What the clock reads once the window runs and every input has been
  pulled: a time limit passes when this is far enough on. -/
  idleAt : Option Nat := none
  /-- Whether the window, once it is run, takes until a close has been asked
  of it to begin: a close that came too early, which it forgets as every
  window does. -/
  slowToBegin : Bool := false

/-- What a fake window has been asked and has said. -/
structure FakeWindowState where
  /-- The clock's reading. -/
  now : Nat
  /-- The inputs the window has reported that the loop has not pulled. -/
  pending : List WindowCheck.Arrival := []
  /-- Whether the window is running. -/
  running : Bool := false
  /-- Whether the loop has been told to stop once `pending` is empty. -/
  stopped : Bool := false
  /-- The calls made of the window, in order: `probe`, `run true` or
  `run false`, `close`, `stop`. -/
  calls : Array String := #[]
  /-- The lines printed. -/
  lines : Array String := #[]
  /-- The lines said to the person at the terminal, apart from the report. -/
  said : Array String := #[]
  /-- How many closes were asked for while the window was not running, and
  so forgotten. -/
  forgotten : Nat := 0

/-- The fake as the record the check runs on. `closed` is resolved by a
close asked for while the window is running, and ends the run. A close asked
for at any other time is forgotten, as the window port's contract has it. -/
def FakeWindow.window (fake : FakeWindow) (state : IO.Ref FakeWindowState)
    (closed : IO.Promise Unit) : WindowCheck.Window :=
  let called (call : String) : IO Unit :=
    state.modify fun state => { state with calls := state.calls.push call }
  { next := do
      repeat
        let pulled ←
          state.modifyGet fun state =>
              match state.pending with
              | arrival :: rest =>
                (some (arrival.input, arrival.arrived),
                  { state with
                    pending := rest, now := arrival.handled })
              | [] =>
                if state.stopped then (some (.stop, 0), state)
                else
                  if state.running then (none, { state with now := fake.idleAt.getD state.now })
                  else (none, state)
        if let some input := pulled then
          return input
        IO.sleep 1
      return (.stop, 0)
    clock := return (← state.get).now
    serviceOnMain := do
      called "probe"
      return fake.serviceOnMain
    run := fun composition => do
      called s!"run {composition}"
      if let some reason := fake.cannotOpen then
        return .error reason
      if fake.slowToBegin then
        while (← state.get).forgotten == 0 && !(← closed.isResolved) do
          IO.sleep 1
      state.modify fun state =>
          { state with
            pending := fake.arrivals, running := true }
      while !(← closed.isResolved) do
        IO.sleep 1
      state.modify fun state => { state with running := false }
      return .ok ()
    close := do
      called "close"
      let running ←
        state.modifyGet fun state =>
            (state.running,
              if state.running then state else { state with forgotten := state.forgotten + 1 })
      if running then
        closed.resolve ()
    stop := do
      called "stop"
      state.modify fun state => { state with stopped := true }
    emit := fun line => state.modify fun state => { state with lines := state.lines.push line } }

/-- What one check on a fake window showed. -/
structure Checked where
  /-- The lines the check printed. -/
  lines : List String
  /-- The calls it made of the window, in order. -/
  calls : List String
  /-- Its exit status; `none` if it did not end in time. -/
  status : Option UInt32
  /-- What it said to the person at the terminal, apart from the report. -/
  said : List String
  /-- How many closes it asked for while the window was not running. -/
  forgotten : Nat

/-- Runs `act` on `fake`'s window and on somewhere to say a line, and returns
what it did. It runs on a dedicated task that this polls, so one that never
ends fails here instead of hanging the executable, and the fake's window is
closed whatever happened, so its run is not left behind. -/
def FakeWindow.drive (fake : FakeWindow)
    (act : WindowCheck.Window → (String → IO Unit) → IO UInt32) : IO Checked := do
  let state ← IO.mkRef { now := fake.askedAt }
  let closed ← IO.Promise.new
  let say (line : String) : IO Unit :=
    state.modify fun state => { state with said := state.said.push line }
  let task ← IO.asTask (prio := .dedicated) (act (fake.window state closed) say)
  let status ←
    if ← eventually (IO.hasFinished task) then
      some <$> IO.ofExcept task.get
    else
      pure none
  closed.resolve ()
  let state ← state.get
  return {
      lines := state.lines.toList, calls := state.calls.toList, status
      said := state.said.toList, forgotten := state.forgotten }

/-- Runs the keyboard check on `fake`, with `options`. -/
def FakeWindow.check (fake : FakeWindow) (options : WindowCheck.Options := {}) : IO Checked :=
  fake.drive fun window _ => WindowCheck.check window options

/-- Runs the keyboard check on `fake` as `editor window-check` runs it, with
the command line's `arguments`. -/
def FakeWindow.withArguments (fake : FakeWindow) (arguments : List String) : IO Checked :=
  fake.drive fun window say => WindowCheck.withArguments window arguments say

/-- A window that opens 2.5 ms after it is asked for, at the instant
1 000 000 on the clock, and then reports each thing the check tells apart:
the focus, a pointer press, five key events with latencies of 10, 30, 20,
100 and 40.5 µs, a composition, a request to close, and one more key 50 µs
after that. -/
def typed : FakeWindow :=
  { askedAt := 1000000
    arrivals :=
      [{ input := .opened "fake", arrived := 3500000, handled := 3520000 },
        { input := .focus true, arrived := 5500000, handled := 5510000 },
        { input := .pointerPressed, arrived := 9500000, handled := 9510000 },
        { input := pressed "h", arrived := 10000000, handled := 10010000 },
        { input := released, arrived := 10100000, handled := 10130000 },
        { input := .key true true false "h", arrived := 10200000, handled := 10220000 },
        { input := .key true false true "", arrived := 10300000, handled := 10400000 },
        { input := pressed "é", arrived := 10500000, handled := 10540500 },
        { input := .compositionEnabled, arrived := 10600000, handled := 10600000 },
        { input := .preedit "´", arrived := 10700000, handled := 10700000 },
        { input := .commit "é", arrived := 10800000, handled := 10800000 },
        { input := .closeRequested, arrived := 10900000, handled := 10900000 },
        { input := pressed "z", arrived := 11000000, handled := 11050000 }] }

/-- The report of the check on `typed`. -/
def typedReport : List String :=
  ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
    "window: opened by fake 2.5 ms after it was asked for",
    "focus: gained 2.0 ms after the window opened; first pointer press in the window: 6.0 ms after it opened",
    "keys: 6 key events reached the Lean loop (5 presses, 1 of them repeats, 1 releases); text: \"hhéz\"",
    "latency from a key's arrival in Rust to its handling in Lean, in µs: median 30.0 / 99th percentile 100.0 / maximum 100.0 (6 samples)",
    "dead keys: 1 key events marked dead",
    "composition: enabled; 1 preedit and 1 commit events; committed: \"é\"",
    "ended: the window was closed"]

/-- The checks of the keyboard check's pure core (`Editor/WindowCheck.lean`):
what it counts, the percentiles, and each line of the report. -/
def windowTallyChecks : List Check :=
  [{
      name :=
        "the tally counts key presses, the repeats among them, releases, dead keys, preedits and commits",
      run := do
        let tally :=
          tallied
            [pressed "a", released, .key true true false "a", .key true false true "",
              .key false false true "", .preedit "´", .preedit "", .commit "é", .compositionEnabled,
              .focus true, .other]
        return tally.keys == 5 && tally.presses == 3 && tally.repeats == 1 && tally.releases == 2 &&
            tally.dead == 2 &&
            tally.preedits == 2 &&
            tally.commits == 1 &&
            tally.composing &&
            !(tallied [pressed "a"]).composing },
    { name := "the tally's text is what the presses produced, in order, and a release adds nothing"
      run :=
        pure
          ((tallied
                [pressed "a", .key false false false "x", pressed "é", pressed "",
                  pressed "b"]).text ==
            "aéb") },
    { name := "the typed text and the committed text are cut at 60 characters"
      run := do
        let typed := tallied ((List.replicate 70 (pressed "é")) ++ [pressed "z"])
        let committed := tallied [.commit (repeated "ab" 31), .commit "z"]
        return typed.text == repeated "é" 60 && typed.presses == 71 &&
            committed.committed == repeated "ab" 30 &&
            committed.commits == 2 },
    { name :=
        "every key event is a latency sample, the time from its arrival to its handling, and nothing else is"
      run := do
        let tally :=
          counted
            [{ input := pressed "a", arrived := 100, handled := 350 },
              { input := .focus true, arrived := 400, handled := 900 },
              { input := released, arrived := 1000, handled := 1001 },
              { input := .key true true false "a", arrived := 2000, handled := 2000 },
              { input := .commit "é", arrived := 3000, handled := 4000 }]
        return tally.latencies == #[250, 1, 0] },
    { name :=
        "the tally keeps when the window opened, when it first gained the focus and when a pointer was first pressed in it"
      run := do
        let tally :=
          counted
            [{ input := .opened "fake", arrived := 10, handled := 11 },
              { input := .focus false, arrived := 20, handled := 21 },
              { input := .focus true, arrived := 30, handled := 31 },
              { input := .pointerPressed, arrived := 40, handled := 41 },
              { input := .focus true, arrived := 50, handled := 51 },
              { input := .pointerPressed, arrived := 60, handled := 61 }]
        let none : WindowCheck.Tally := {}
        return tally.platform == some "fake" && tally.openedAt == some 10 &&
            tally.focusedAt == some 30 &&
            tally.pointerAt == some 40 &&
            none.platform.isNone &&
            none.focusedAt.isNone &&
            none.pointerAt.isNone },
    { name :=
        "the median, the 99th percentile and the maximum are nearest-rank over the sorted samples: of 1, 2, 100 and 101 samples, and none of none"
      run := do
        let upTo (count : Nat) : Array Nat := ((List.range count).map (· + 1)).reverse.toArray
        return WindowCheck.spread #[] == none && WindowCheck.spread #[5] == some (5, 5, 5) &&
            WindowCheck.spread #[2, 1] == some (1, 2, 2) &&
            WindowCheck.spread (upTo 100) == some (50, 99, 100) &&
            WindowCheck.spread (upTo 101) == some (51, 100, 101) },
    { name := "an instant is printed to one decimal place, rounded down"
      run :=
        pure
          (WindowCheck.millis 2500000 == "2.5" && WindowCheck.millis 0 == "0.0" &&
            WindowCheck.micros 40500 == "40.5" &&
            WindowCheck.micros 999 == "0.9" &&
            WindowCheck.micros 123456789 == "123456.7") },
    { name := "the report of a window that opened is its eight lines, exactly"
      run := do
        let run : WindowCheck.Run :=
          { options := {}, serviceOnMain := true, askedAt := 1000000, failure := none
            tally := counted typed.arrivals, ending := .closed }
        return WindowCheck.report run == typedReport },
    { name :=
        "the report of a window that could not open is eight lines too: the reason in the second, once, and the others as when nothing arrived"
      run :=
        pure
          (WindowCheck.report (unopened "no display") ==
            ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
                "window: could not open: no display"] ++
              nothingArrived) },
    { name :=
        "a window that ran and never said that it opened is reported as one that could not open, however its run was ended: that reason in the second line, the last line that the window never opened, and status 1"
      run := do
        let silent (ending : WindowCheck.Ending) (inputs : List WindowCheck.Input := []) :
          WindowCheck.Run :=
          { options := {}, serviceOnMain := true, askedAt := 1000000, failure := none
            tally := tallied inputs, ending }
        let expected :=
          ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
              "window: could not open: the window ran and did not say that it opened"] ++
            nothingArrived
        -- What did arrive is still counted.
        let typedInto := WindowCheck.report (silent .closed [pressed "a"])
        return WindowCheck.report (silent .closed) == expected &&
            WindowCheck.report (silent .limit) == expected &&
            WindowCheck.status (silent .closed) == 1 &&
            WindowCheck.status (silent .limit) == 1 &&
            typedInto[1]? == expected[1]? &&
            typedInto[3]? ==
              some
                "keys: 1 key events reached the Lean loop (1 presses, 0 of them repeats, 0 releases); text: \"a\"" &&
            typedInto.getLast? == some "ended: the window never opened" &&
            WindowCheck.status (silent .closed [pressed "a"]) == 1 },
    { name :=
        "the focus line gives the gain and the first pointer press, each or neither, and judges nothing"
      run := do
        let line (inputs : List WindowCheck.Arrival) : Option String :=
          (WindowCheck.report
              { opened [] with
                tally :=
                  counted
                    ({ input := .opened "fake", arrived := 1000000, handled := 0 } :: inputs) })[2]?
        let gain : WindowCheck.Arrival := { input := .focus true, arrived := 3000000, handled := 0 }
        let press : WindowCheck.Arrival :=
          { input := .pointerPressed, arrived := 2500000, handled := 0 }
        return line [] == some "focus: never gained; first pointer press in the window: none" &&
            line [gain] ==
              some
                "focus: gained 2.0 ms after the window opened; first pointer press in the window: none" &&
            line [press] ==
              some
                "focus: never gained; first pointer press in the window: 1.5 ms after it opened" &&
            line [press, gain] ==
              some
                "focus: gained 2.0 ms after the window opened; first pointer press in the window: 1.5 ms after it opened" },
    { name := "the last line says how the check ended, in one of three ways"
      run := do
        let last (run : WindowCheck.Run) : Option String := (WindowCheck.report run).getLast?
        return last (opened []) == some "ended: the window was closed" &&
            last (opened [] {} .limit) == some "ended: the time limit" &&
            last (unopened "no display") == some "ended: the window never opened" },
    { name :=
        "the first line says what was asked for and where the main-thread service is, for each value of both"
      run := do
        let first (composition serviceOnMain : Bool) (seconds : Nat) : Option String :=
          (WindowCheck.report { opened [] { composition, seconds } with serviceOnMain }).head?
        return first true true 120 ==
              some
                "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes" &&
            first false true 3 ==
              some
                "window-check: composition off, limit 3 s; the main-thread service is on the process's main thread: yes" &&
            first true false 120 ==
              some
                "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: no" },
    { name :=
        "with no key the latency line says there are no samples, and the report is still eight lines"
      run := do
        let lines := WindowCheck.report (opened [.focus true])
        return lines.length == 8 &&
            lines[4]? ==
              some
                "latency from a key's arrival in Rust to its handling in Lean, in µs: no samples" },
    { name :=
        "typed text is printed quoted, so a key that produced a control character keeps the line whole"
      run :=
        pure
          ((WindowCheck.report
                (opened [pressed "a", pressed "\r", pressed "\"", pressed "b"]))[3]? ==
            some
              "keys: 4 key events reached the Lean loop (4 presses, 0 of them repeats, 0 releases); text: \"a\\x0d\\\"b\"") },
    { name := "the exit status is 0 for a window that ran and 1 for one that could not open"
      run :=
        pure
          (WindowCheck.status (opened []) == 0 &&
            WindowCheck.status (unopened "no display") == 1) }]

/-- The checks of the keyboard check itself (`WindowCheck.check`), on a fake
window written by hand: what it asks of the window and in what order, and
the report it prints. -/
def windowLoopChecks : List Check :=
  [{
      name :=
        "the check on a window that reports each thing prints the report of what arrived, and ends with status 0",
      run := do
        let checked ← typed.check
        return checked.lines == typedReport && checked.status == some 0 },
    { name :=
        "the check asks where the main-thread service is before it runs the window and never again, closes the window once when it is asked to close, and stops the loop when the window has closed"
      run := return (← typed.check).calls == ["probe", "run true", "close", "stop"] },
    { name := "a second request to close does not close the window again"
      run := do
        let twice : FakeWindow :=
          {
            arrivals :=
              [{ input := .opened "fake", arrived := 1, handled := 1 },
                { input := .closeRequested, arrived := 2, handled := 2 },
                { input := .closeRequested, arrived := 3, handled := 3 }] }
        return (← twice.check).calls == ["probe", "run true", "close", "stop"] },
    { name :=
        "an input that arrives after the close was asked for and before the stop is still counted"
      run := do
        let late : FakeWindow :=
          {
            arrivals :=
              [{ input := .opened "fake", arrived := 1, handled := 1 },
                { input := .closeRequested, arrived := 2, handled := 2 },
                { input := pressed "a", arrived := 3, handled := 4 },
                { input := pressed "b", arrived := 5, handled := 6 }] }
        return (← late.check).lines[3]? ==
            some
              "keys: 2 key events reached the Lean loop (2 presses, 0 of them repeats, 0 releases); text: \"ab\"" },
    { name :=
        "the window is run with composition allowed, and with it not allowed when the options say so, which the first line then says"
      run := do
        let allowed ← typed.check
        let refused ← typed.check { composition := false }
        return allowed.calls[1]? == some "run true" && refused.calls[1]? == some "run false" &&
            refused.lines.head? ==
              some
                "window-check: composition off, limit 120 s; the main-thread service is on the process's main thread: yes" },
    { name :=
        "the window line's time is from the clock's reading before the window was run to the instant the window opened"
      run := do
        let slow : FakeWindow :=
          { askedAt := 7000000
            arrivals :=
              [{ input := .opened "fake", arrived := 19300000, handled := 99000000 },
                { input := .closeRequested, arrived := 99000001, handled := 99000002 }] }
        return (← slow.check).lines[1]? ==
            some "window: opened by fake 12.3 ms after it was asked for" },
    { name :=
        "a window that cannot open gives the eight lines of that case, with the reason in the second, and status 1; nothing is closed, and the loop is still stopped"
      run := do
        let checked ← ({ cannotOpen := some "no display" } : FakeWindow).check
        return checked.lines ==
              ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
                  "window: could not open: no display"] ++
                nothingArrived &&
            checked.status == some 1 &&
            checked.calls == ["probe", "run true", "stop"] },
    { name :=
        "a window that runs and never says that it opened is closed by the time limit, and gives the eight lines of a window that could not open, with that reason in the second, and status 1"
      run := do
        let silent : FakeWindow := { arrivals := [], idleAt := some 3000000000 }
        let checked ← silent.check { seconds := 2 }
        return checked.lines ==
              ["window-check: composition on, limit 2 s; the main-thread service is on the process's main thread: yes",
                  "window: could not open: the window ran and did not say that it opened"] ++
                nothingArrived &&
            checked.status == some 1 &&
            checked.calls.eraseReps == ["probe", "run true", "close", "stop"] },
    { name := "what the fake says of the main-thread service is what the first line says"
      run := do
        let checked ← ({ typed with serviceOnMain := false } : FakeWindow).check
        return checked.lines.head? ==
            some
              "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: no" },
    { name :=
        "a window nobody closes is closed by the check once the time limit has passed on the clock, and the report says so"
      run := do
        let idle : FakeWindow :=
          { askedAt := 1000000000
            arrivals := [{ input := .opened "fake", arrived := 1000000001, handled := 1000000002 }]
            idleAt := some 3000000000 }
        let checked ← idle.check { seconds := 2 }
        -- The limit asks again at every look until the run has ended, so
        -- there is one close or several in a row.
        return checked.calls.eraseReps == ["probe", "run true", "close", "stop"] &&
            checked.lines.getLast? == some "ended: the time limit" &&
            checked.status == some 0 },
    { name :=
        "a time limit that has passed before the window's run has begun still ends the run: the close that came too early is forgotten, and the check asks again"
      run := do
        let slow : FakeWindow :=
          { arrivals := [{ input := .opened "fake", arrived := 1, handled := 2 }]
            slowToBegin := true }
        let checked ← slow.check { seconds := 0 }
        return checked.forgotten >= 1 && checked.status == some 0 &&
            checked.lines[1]?.any (·.startsWith "window: opened by fake ") &&
            checked.lines.getLast? == some "ended: the time limit" },
    { name := "a window that is closed before the time limit is not said to have reached it"
      run := do
        let checked ← ({ typed with idleAt := some 1000000 } : FakeWindow).check { seconds := 2 }
        return checked.lines.getLast? == some "ended: the window was closed" }]

/-- The checks of the keyboard check's command line: what its arguments ask
for (`WindowCheck.parse`), and what the check does with them
(`WindowCheck.withArguments`), on the fake window. -/
def windowArgumentChecks : List Check :=
  [{ name := "no arguments ask for composition allowed and a limit of 120 seconds",
     run := pure (WindowCheck.parse [] == some { composition := true, seconds := 120 }) },
    { name := "`--no-ime` asks for composition not allowed, and leaves the limit"
      run :=
        pure (WindowCheck.parse ["--no-ime"] == some { composition := false, seconds := 120 }) },
    { name := "`--seconds <n>` sets the limit, and leaves composition allowed"
      run :=
        pure (WindowCheck.parse ["--seconds", "3"] == some { composition := true, seconds := 3 }) },
    { name := "both options are understood together, in either order"
      run := do
        let both : Option WindowCheck.Options := some { composition := false, seconds := 3 }
        return WindowCheck.parse ["--no-ime", "--seconds", "3"] == both &&
            WindowCheck.parse ["--seconds", "3", "--no-ime"] == both },
    { name :=
        "`--seconds` with nothing after it, or with something that is not a number, is not understood"
      run :=
        pure
          (WindowCheck.parse ["--seconds"] == none &&
            WindowCheck.parse ["--seconds", "x"] == none &&
            WindowCheck.parse ["--no-ime", "--seconds"] == none &&
            WindowCheck.parse ["--seconds", "--no-ime"] == none) },
    { name := "an argument that is not an option is not understood, wherever it is"
      run :=
        pure
          (WindowCheck.parse ["--bogus"] == none && WindowCheck.parse ["3"] == none &&
            WindowCheck.parse ["--no-ime", "--bogus"] == none &&
            WindowCheck.parse ["--seconds", "3", "--bogus"] == none) },
    { name :=
        "with arguments that are not understood, the check says the usage, ends with status 2, and asks nothing of the window"
      run := do
        let checked ← typed.withArguments ["--bogus"]
        return checked.said == [WindowCheck.usage] && checked.status == some 2 &&
            checked.calls.isEmpty &&
            checked.lines.isEmpty },
    { name :=
        "with arguments that are understood, the check says what to do with the window and runs it as they ask: `--no-ime` runs the window with composition not allowed, and `--seconds` is the limit the report gives"
      run := do
        let checked ← typed.withArguments ["--no-ime", "--seconds", "3"]
        return checked.said == [WindowCheck.instructions] &&
            checked.calls == ["probe", "run false", "close", "stop"] &&
            checked.lines.head? ==
              some
                "window-check: composition off, limit 3 s; the main-thread service is on the process's main thread: yes" &&
            checked.status == some 0 },
    { name := "with no arguments, the check runs the window with composition allowed"
      run := do
        let checked ← typed.withArguments []
        return checked.lines == typedReport && checked.calls[1]? == some "run true" &&
            checked.status == some 0 }]

end ModelTest
