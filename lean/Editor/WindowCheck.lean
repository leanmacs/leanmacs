/-!
# The keyboard check

`editor window-check` opens a window and reports what of the keyboard reached
a Lean loop: how many keys, what they typed, how long each took from its
arrival in Rust to its handling in Lean, and whether dead keys and an input
method's composition arrived at all. A person runs it and reads the report
(`README.md`, "The keyboard check"). It decides nothing about what a key
means: that is the display pipeline's.

This module is the check's core, and it does not import the bindings:

- what the check tells apart (`Input`), what it counts (`Tally`,
  `Tally.step`), the percentiles of the latencies (`spread`), and the report
  (`Run`, `report`), which are pure;
- the check itself (`check`), written against a record of the things it
  needs (`Window`), so the model tests drive it with a hand-written fake;
- what the command line's arguments ask for (`parse`), and the check as the
  command line runs it (`withArguments`).

`Editor/WindowCheck/Real.lean` is that record over the bindings.

## How the check runs

`check` asks whether the main-thread service is on the process's main thread,
before the window: while the window runs, the service answers nothing else.
It then starts the loop on a dedicated task and runs the window on the
calling thread, which blocks until the window has closed.

The loop pulls one input at a time and reads the clock as soon as it has one:
that reading is when the input was handled. When the window says the user
asked for it to be closed, the loop closes it, once. A second task closes the
window when the time limit has passed, and asks again until the window's run
has ended: a window forgets a close that comes before its run has begun, as
one does when the limit is shorter than the window takes to start.

When the window has closed, `check` posts a stop to the loop, which ends at
it with every input before it counted, those that arrived after the close was
asked for among them. Then it prints the report.

## The report

Eight lines, always, in one fixed form (`report`). A window that could not
be opened gives the same eight lines, with the reason in the second, and the
exit status 1.

The latency of a key is the time from the instant the window's loop was
handed the key, read in Rust on the main thread, to the instant the Lean loop
had pulled the event and read the same clock. Every key event is a sample:
presses, repeats and releases. The percentiles are nearest-rank over the
sorted samples: the median is sample ⌈n / 2⌉ and the 99th percentile sample
⌈0.99 n⌉.

## Tests

`ModelTest.windowTallyChecks`, `windowLoopChecks` and `windowArgumentChecks`,
in `lake test`: the tally, the percentiles, each line of the report, the
check on a fake window, and the command line's arguments. `ffi-test` runs the
check over the real bindings on the library's scripted platform
(`FfiTest.windowChecks`). Neither opens a window.
-/

namespace Editor.WindowCheck

/-- What the check tells apart among the things that reach its loop. -/
inductive Input where
  /-- The window is open, on the platform of this name. -/
  | opened (platform : String)
  /-- The window gained the keyboard focus, or lost it. -/
  | focus (gained : Bool)
  /-- A key was pressed or released. `repeated` marks a press the platform
  repeated because the key is held, and `dead` a dead key; `text` is what the
  key produced. -/
  | key (pressed repeated dead : Bool) (text : String)
  /-- An input method became available to the window. -/
  | compositionEnabled
  /-- The text an input method is composing changed. -/
  | preedit (text : String)
  /-- A composition ended with this text. -/
  | commit (text : String)
  /-- The input method is no longer available to the window. -/
  | compositionDisabled
  /-- A pointer button was pressed in the window. -/
  | pointerPressed
  /-- The user asked for the window to be closed. -/
  | closeRequested
  /-- The check's own message: the window has closed, and the loop ends. -/
  | stop
  /-- Anything else. -/
  | other
  deriving DecidableEq, Repr

/-- One input as the loop saw it. Both instants are in nanoseconds on one
clock. -/
structure Arrival where
  /-- What arrived. -/
  input : Input
  /-- When the window's loop was handed it, in Rust; 0 when the source did
  not say. -/
  arrived : Nat
  /-- When the Lean loop had pulled it and read the clock. -/
  handled : Nat
  deriving DecidableEq, Repr

/-- How many characters of typed and of committed text the report shows. -/
def shown : Nat :=
  60

/-- The first `shown` characters of `text`. -/
def cut (text : String) : String :=
  String.ofList (text.toList.take shown)

/-- What the loop has seen so far. -/
structure Tally where
  /-- The platform's name, once the window has said that it opened. -/
  platform : Option String := none
  /-- When the window opened. -/
  openedAt : Option Nat := none
  /-- When the window first gained the focus. -/
  focusedAt : Option Nat := none
  /-- When a pointer button was first pressed in the window. -/
  pointerAt : Option Nat := none
  /-- How many key events arrived that were presses, repeats among them. -/
  presses : Nat := 0
  /-- How many of the presses were repeats. -/
  repeats : Nat := 0
  /-- How many key events arrived that were releases. -/
  releases : Nat := 0
  /-- How many key events were marked dead. -/
  dead : Nat := 0
  /-- The first `shown` characters the presses produced. -/
  text : String := ""
  /-- The latency of every key event, in nanoseconds, in the order they
  arrived. -/
  latencies : Array Nat := #[]
  /-- Whether an input method became available. -/
  composing : Bool := false
  /-- How many preedit events arrived. -/
  preedits : Nat := 0
  /-- How many commit events arrived. -/
  commits : Nat := 0
  /-- The first `shown` characters the commits carried. -/
  committed : String := ""
  /-- Whether the user asked for the window to be closed. -/
  closeRequested : Bool := false
  deriving Repr

namespace Tally

/-- How many key events arrived. -/
def keys (tally : Tally) : Nat :=
  tally.presses + tally.releases

/-- The tally with one more arrival counted. -/
def step (tally : Tally) (arrival : Arrival) : Tally :=
  match arrival.input with
  | .opened platform =>
    { tally with
      platform := some platform, openedAt := some arrival.arrived }
  | .focus true => { tally with focusedAt := tally.focusedAt <|> some arrival.arrived }
  | .focus false => tally
  | .key pressed repeated dead text =>
    { tally with
      presses := tally.presses + (if pressed then 1 else 0)
      repeats := tally.repeats + (if pressed && repeated then 1 else 0)
      releases := tally.releases + (if pressed then 0 else 1)
      dead := tally.dead + (if dead then 1 else 0)
      text := if pressed then cut (tally.text ++ text) else tally.text
      latencies := tally.latencies.push (arrival.handled - arrival.arrived) }
  | .compositionEnabled => { tally with composing := true }
  | .preedit _ => { tally with preedits := tally.preedits + 1 }
  | .commit text =>
    { tally with
      commits := tally.commits + 1, committed := cut (tally.committed ++ text) }
  | .pointerPressed => { tally with pointerAt := tally.pointerAt <|> some arrival.arrived }
  | .closeRequested => { tally with closeRequested := true }
  | .compositionDisabled | .stop | .other => tally

end Tally

/-- The median, the 99th percentile and the maximum of `samples`, by nearest
rank over the sorted samples: the median is sample ⌈n / 2⌉ and the 99th
percentile sample ⌈0.99 n⌉. `none` when there is no sample. -/
def spread (samples : Array Nat) : Option (Nat × Nat × Nat) := do
  let sorted := samples.qsort (· < ·)
  let count := sorted.size
  -- ⌈count / 2⌉ and ⌈99 count / 100⌉, as ranks that start at 1.
  let median ← sorted[(count + 1) / 2 - 1]?
  let high ← sorted[(99 * count + 99) / 100 - 1]?
  let maximum ← sorted.back?
  return (median, high, maximum)

/-- `value` in units of `unit`, to one decimal place, rounded down: 2500000
in units of 1000000 is `2.5`. -/
def tenths (value unit : Nat) : String :=
  s!"{value / unit}.{value % unit * 10 / unit}"

/-- Nanoseconds as milliseconds, to one decimal place. -/
def millis (nanoseconds : Nat) : String :=
  tenths nanoseconds 1000000

/-- Nanoseconds as microseconds, to one decimal place. -/
def micros (nanoseconds : Nat) : String :=
  tenths nanoseconds 1000

/-- What the person who runs the check may choose. -/
structure Options where
  /-- Whether an input method may compose in the window. Without it a dead
  key arrives as a key. -/
  composition : Bool := true
  /-- How many seconds the window stays open if nobody closes it. -/
  seconds : Nat := 120
  deriving DecidableEq, Repr

/-- How a check ended. -/
inductive Ending where
  /-- The user closed the window. -/
  | closed
  /-- The time limit passed, and the check closed the window. -/
  | limit
  /-- No window could be opened. -/
  | neverOpened
  deriving DecidableEq, Repr

/-- Everything the report is made of. -/
structure Run where
  /-- What was asked for. -/
  options : Options
  /-- Whether the main-thread service is on the process's main thread. -/
  serviceOnMain : Bool
  /-- The clock's reading just before the window was asked for. -/
  askedAt : Nat
  /-- Why no window could be opened, when none could. -/
  failure : Option String
  /-- What reached the loop. -/
  tally : Tally
  /-- How the check ended. -/
  ending : Ending
  deriving Repr

/-- The report: eight lines, in this order and this form, whatever happened.

```
window-check: composition <on|off>, limit <n> s; the main-thread service is on the process's main thread: <yes|no>
window: <opened by <platform> <ms> ms after it was asked for|could not open: <reason>>
focus: <gained <ms> ms after the window opened|never gained>; first pointer press in the window: <<ms> ms after it opened|none>
keys: <n> key events reached the Lean loop (<p> presses, <t> of them repeats, <r> releases); text: "<the first 60 characters the presses produced>"
latency from a key's arrival in Rust to its handling in Lean, in µs: <median <m> / 99th percentile <p> / maximum <x> (<n> samples)|no samples>
dead keys: <n> key events marked dead
composition: <enabled|not enabled>; <a> preedit and <b> commit events; committed: "<the first 60 characters>"
ended: <the window was closed|the time limit|the window never opened>
```

The first line holds what is known without a window: the two options and
where the main-thread service is. `composition on` there is what was asked
for; the `composition:` line is what arrived. The focus line gives both
instants and judges nothing: a pointer press before the focus was gained says
the window was clicked into focus. -/
def report (run : Run) : List String :=
  let tally := run.tally
  let since (start : Nat) (instant : Nat) : String := millis (instant - start)
  let asked :=
    s!"window-check: composition {if run.options.composition then "on" else "off"}, limit {run.options.seconds} s; the main-thread service is on the process's main thread: {if run.serviceOnMain then "yes" else "no"}"
  let window :=
    match run.failure, tally.platform, tally.openedAt with
    | some reason, _, _ => s!"could not open: {reason}"
    | none, some platform, some openedAt =>
      s!"opened by {platform} {since run.askedAt openedAt} ms after it was asked for"
    | none, _, _ => "could not open: the window ran and did not say that it opened"
  let openedAt := tally.openedAt.getD run.askedAt
  let focus :=
    match tally.focusedAt with
    | some focusedAt => s!"gained {since openedAt focusedAt} ms after the window opened"
    | none => "never gained"
  let pointer :=
    match tally.pointerAt with
    | some pointerAt => s!"{since openedAt pointerAt} ms after it opened"
    | none => "none"
  let latency :=
    match spread tally.latencies with
    | some (median, high, maximum) =>
      s!"median {micros median} / 99th percentile {micros high} / maximum {micros maximum} ({tally.latencies.size} samples)"
    | none => "no samples"
  let ended :=
    match run.ending with
    | .closed => "the window was closed"
    | .limit => "the time limit"
    | .neverOpened => "the window never opened"
  [asked, s!"window: {window}", s!"focus: {focus}; first pointer press in the window: {pointer}",
    s!"keys: {tally.keys} key events reached the Lean loop ({tally.presses} presses, {tally.repeats} of them repeats, {tally.releases} releases); text: {tally.text.quote}",
    s!"latency from a key's arrival in Rust to its handling in Lean, in µs: {latency}",
    s!"dead keys: {tally.dead} key events marked dead",
    s!"composition: {if tally.composing then "enabled" else "not enabled"}; {tally.preedits} preedit and {tally.commits} commit events; committed: {tally.committed.quote}",
    s!"ended: {ended}"]

/-- What the check needs of the world: the window, its events, a clock and
somewhere to print. `Editor/WindowCheck/Real.lean` is this over the
bindings, and the model tests write a fake. -/
structure Window where
  /-- The next input and the instant it arrived, in nanoseconds on `clock`,
  or 0 when its source does not say. Blocks until there is one. -/
  next : IO (Input × Nat)
  /-- The clock's reading, in nanoseconds. -/
  clock : IO Nat
  /-- Whether the main-thread service is on the process's main thread. It
  cannot be asked while the window runs. -/
  serviceOnMain : IO Bool
  /-- Runs the window, with an input method allowed to compose or not, and
  returns when the window has closed, or the reason it could not be opened. -/
  run : Bool → IO (Except String Unit)
  /-- Asks the running window to close. -/
  close : IO Unit
  /-- Has `next` give `Input.stop` once everything before it has been given. -/
  stop : IO Unit
  /-- Prints one line of the report. -/
  emit : String → IO Unit

/-- How often, in milliseconds, the task that enforces the time limit looks
at the clock. -/
def limitPoll : UInt32 :=
  50

/-- The exit status of a check: 0 when the window ran and closed, 1 when it
could not be opened. Whether keys arrived is for the reader of the report. -/
def status (run : Run) : UInt32 :=
  if run.failure.isSome then 1 else 0

/-- Runs the check on `window` and prints the report; see the module docs.
Returns the exit status. It blocks until the window has closed, so call it
from Lean's main thread or a dedicated task. -/
def check (window : Window) (options : Options) : IO UInt32 := do
  -- Before the window: the service answers nothing else while it runs.
  let serviceOnMain ← window.serviceOnMain
  let askedAt ← window.clock
  -- The loop: one input at a time, the clock read as soon as it is in hand.
  let loop ←
    IO.asTask (prio := .dedicated) do
        let mut tally : Tally := {}
        repeat
          let (input, arrived) ← window.next
          let handled ← window.clock
          if input == .stop then
            break
          if input == .closeRequested && !tally.closeRequested then
            window.close
          tally := tally.step { input, arrived, handled }
        return tally
  -- The time limit: closes the window if the check is still running when it
  -- has passed. It looks at the clock now and then, so that it ends soon
  -- after the check does and never sleeps the whole limit. Once the limit
  -- has passed it asks again at every look until the run has ended: a
  -- window forgets a close that comes before its run has begun, and a limit
  -- shorter than the window takes to start comes that early.
  let over ← IO.mkRef false
  let limited ← IO.mkRef false
  discard <|
      IO.asTask (prio := .dedicated) do
        while !(← over.get) do
          if (← window.clock) - askedAt >= options.seconds * 1000000000 then
            limited.set true
            window.close
          IO.sleep limitPoll
  let outcome ← window.run options.composition
  over.set true
  -- The loop ends at the stop, with everything before it counted.
  window.stop
  let tally ← IO.ofExcept (← IO.wait loop)
  let failure :=
    match outcome with
    | .ok () => none
    | .error reason => some reason
  let timedOut ← limited.get
  let ending :=
    if failure.isSome then Ending.neverOpened
    else if timedOut && !tally.closeRequested then .limit else .closed
  let run : Run := { options, serviceOnMain, askedAt, failure, tally, ending }
  for line in report run do
    window.emit line
  return status run

/-- The usage of `editor window-check`. -/
def usage : String :=
  "usage: editor window-check [--seconds <n>] [--no-ime]"

/-- What `editor window-check` tells the person at the terminal before it
opens the window. -/
def instructions : String :=
  "window-check: type in the window (click it first if it is not in front), then close it to finish"

/-- The options `arguments` ask for; `none` when they are not understood.
`--seconds <n>` sets the time limit and `--no-ime` runs the window with
composition not allowed. -/
def parse (arguments : List String) (options : Options := {}) : Option Options :=
  match arguments with
  | [] => some options
  | "--no-ime" :: rest => parse rest { options with composition := false }
  | "--seconds" :: seconds :: rest => do
    parse rest { options with seconds := ← seconds.toNat? }
  | _ => none

/-- The check as `editor window-check` runs it: on `window`, with the options
the command line's `arguments` ask for. It says on `say` what to do with the
window, runs the check, which prints the report, and returns its exit status.
When the arguments are not understood it says the usage, asks nothing of the
window and returns 2. -/
def withArguments (window : Window) (arguments : List String) (say : String → IO Unit) :
    IO UInt32 := do
  let some options := parse arguments
    |
    do
      say usage
      return 2
  say instructions
  check window options

end Editor.WindowCheck
