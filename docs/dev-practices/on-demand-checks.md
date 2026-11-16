# Checks that are not part of the gate

Each of these needs something the gate ([`the-gate.md`](the-gate.md)) must
not need: a display, a person, a container, a quiet machine, the fonts of
one machine, a GPU, or leave to write a crash report or a file of the
repository. Run them by hand, when their section says.

## The overflow check, on demand

```sh
mise run ffi-overflow
```

A stack overflow in interpreted Lean code is not caught: the process aborts.
This task shows it. It runs `ffi-test overflow <sysroot> <olean dir>`, which
has Lean's interpreter run a recursion deeper than its stack, and requires
the process to die of SIGABRT after it has printed the line that says it is
entering the recursion. No core file is written.

It is not part of the gate, and must not be added to it. On macOS every abort
makes the system write a crash report for `ffi-test` under
`~/Library/Logs/DiagnosticReports`, and the gate leaves the machine as it
found it. Run it by hand when the Lean toolchain changes, or the way the
executables are linked and started. The gate still builds the scenario and
its fixture.

The entry point gives every thread Lean creates a 64 MiB stack in place of
Lean's gigabyte, so the overflow takes milliseconds; `ffi-test` checks that
size in the gate, without aborting anything. `LEAN_STACK_SIZE_KB` in the
environment overrides it, and both tasks remove the variable.

## The config benchmark, on demand

```sh
mise run config-bench
```

This measures the config session in the executable as built, and asserts
nothing, so it is not part of the gate either. It runs `config-test`'s three
benchmark subcommands, each in a fresh process under `/usr/bin/time -l`,
which adds the process's real time and its maximum resident set size:

| Subcommand | Measures |
|---|---|
| `bench-start <sysroot> <olean dir> <module>…` | How long importing the base with those modules takes, and the first load of a 20-line config. Run for `Editor`, for `Editor Std` and for `Editor Lean`. |
| `bench-reload <sysroot> <olean dir>` | The median and the maximum of 20 reloads each of a one-line chunk, a 20-line config, and 50 definitions with a `simp` proof. |
| `bench-soak <sysroot> <olean dir> <count>` | The mean time of a reload over that many reloads of the 50-definition config. Run with 100 and with 500: about equal resident set sizes mean replaced configs are freed. |

A time is from the request for a reload to its report. The config is held in
memory, so the benchmark touches no files. Run it on a quiet machine.

## What config may import, measured on demand

```sh
mise run module-bench
```

This measures, on macOS, what each import set config may use costs an app
bundle (`tools/module-bench.sh`), and asserts nothing, so it is not part of
the gate. For `Editor` and for `Editor Lean` it prints the modules the
import reads (`config-test bench-modules <sysroot> <olean dir> <module>…`)
and the bytes of each file kind, of whole top-level directories and of those
modules alone; which file kinds the import needs, by staging the whole
directories in a temporary directory with `tools/stage-bundle.sh` with
`olean`, then `olean olean.server`, then `olean olean.server
olean.private`, then that with `ir ir.sig`, and importing from each; and,
with the closure staged with the kinds it needs, five runs of `bench-start`
under `/usr/bin/time -l` and, for `Editor`, five runs of the staged
bundle's headless mode with an empty environment. Every temporary
directory is removed by a trap. It takes about two minutes and a few GB of
temporary disk. The figures, and what they decided, are in
[`lean-runtime.md`](../design/lean-runtime.md), "What config may import,
measured". Run it again when the Lean toolchain's pin moves.

## The app bundle, on demand

```sh
mise run app-check
```

This builds `Leanmacs.app` (`mise run app`;
[`building.md`](building.md), "The app bundle") and checks it, on macOS on
arm64 only (`tools/app-check.sh`). In a temporary directory removed by a
trap it copies the bundle with `ditto`, so what follows runs on a relocated
copy; verifies the copy's signature with `codesign --verify --strict
--deep`; reads its `Info.plist` with `plutil` (it lints,
`CFBundleExecutable` is an executable file under `Contents/MacOS`,
`LSArchitecturePriority` starts with arm64, `LSMinimumSystemVersion` is no
later than this machine's macOS, and `CFBundleDocumentTypes` is exactly two
types, `public.plain-text` then `public.source-code`, each with
`CFBundleTypeRole` `Editor` and `LSHandlerRank` `Alternate`, read key by key
with `plutil -extract`) and the executable with `lipo` (arm64
alone); reads the icon with ImageIO (`sips`: 16 pixels wide); and runs the
copy's `Contents/MacOS/editor headless` on `tests/headless/bundle` with no
directory argument, an empty environment (`env -i`) and `/` as the working
directory, which must exit 0 and print exactly `expected`. Last, it builds
`editorApp` again and checks that the bundle's executable, its
`CodeResources` and the build's trace file keep their modification times
and inodes: the second build copied and signed nothing. Lake's output is
printed, and holds no `Built editorApp` line. Then, in a clone of the Lean
package in the temporary directory (`cp -c`, so it takes no space), with a
`cargo` that does nothing first on the `PATH`, it swaps the stage script
for one that stages and then fails, builds `editorApp`, which must fail,
puts the script back so the inputs hash to the old trace again, and builds
once more: the bundle must still verify and be the old one, so a failed or
interrupted rebuild leaves no half-built bundle taken as up to date. It
ends `app-check: ok` with the bundle's size, and takes seconds.

It writes nothing outside its temporary directory but that second build,
which is shown to write nothing, opens no window and needs no person. It is
not part of the gate because the gate does not build the bundle, which is
about 600 MB and must be signed, and runs on Linux too. It is the check for
any change to `editorApp`, to `tools/stage-bundle.sh` or to module lookup
(`lean/Editor/ModuleLookup.lean`): such a change is not done until this
ends `app-check: ok`.

## The job benchmark, on demand

```sh
mise run job-bench
```

This measures the latency of the editor loop while background jobs run, in
the executable as built, and asserts nothing, so it is not part of the gate
either. It runs `config-test bench-jobs <sysroot> <olean dir> 10000`. A
sample is the time from posting a request to run a command that does nothing
to the editor thread having run it. It takes 10,000 samples in each of five
rows and prints the median, the 99th percentile and the maximum of each, in
microseconds:

| Row | What runs meanwhile |
|---|---|
| idle | Nothing. |
| 64 jobs each sleeping 1 ms | 64 jobs from config, each sleeping a millisecond in a loop: every wait goes through the timer service and the completion pump. |
| one job a pool thread computing | Interpreted jobs that compute for ever, one for each thread of Lean's task pool. |
| two jobs a pool thread computing | Twice as many: half run and half wait in the pool's queue. |
| idle again | Nothing. |

It then times a million `now` requests in one compiled job, and says which
of the three loaded rows are within bound: a row whose median is at most
twice the larger of the two idle medians and whose 99th percentile is under
100 µs. That is an observation about one run, and the maximum is printed and
not judged. Run it on a quiet machine.

## The keyboard check, at the keyboard

```sh
mise run window-check
```

This opens a window and reports what of the keyboard reached a Lean loop. It
needs a display and a person, so it is not part of the gate. It runs
`editor window-check`: the real window, opened through the entry point on
the process's main thread, and a loop on a dedicated Lean task that pulls the
editor queue, as the command loop will. Start it from a terminal that is in
front; the system may otherwise keep the keyboard from the window until it
is clicked. Type in the window, then close it. The report is eight lines on
stdout:

```
window-check: composition <on|off>, limit <n> s; the main-thread service is on the process's main thread: <yes|no>
window: opened by <platform> <ms> ms after it was asked for        (or "could not open: <reason>")
focus: gained <ms> ms after the window opened; first pointer press in the window: <ms> ms after it opened
                                                                    (or "never gained", and "none")
keys: <n> key events reached the Lean loop (<p> presses, <t> of them repeats, <r> releases); text: "<the first 60 characters typed>"
latency from a key's arrival in Rust to its handling in Lean, in µs: median <m> / 99th percentile <p> / maximum <x> (<n> samples)
                                                                    (or "no samples")
dead keys: <n> key events marked dead
composition: <enabled|not enabled>; <a> preedit and <b> commit events; committed: "<the first 60 characters>"
ended: the window was closed                                        (or "the time limit", or "the window never opened")
```

A key's latency is the time from the instant the window's loop was handed
the key, read in Rust on the main thread, to the instant the Lean loop had
pulled the event and read the same clock. Every key event is a sample. The
check decides nothing about what a key means: it shows that keys, dead keys
and an input method's composition arrive.

| Option | Does |
|---|---|
| `mise run window-check -- --no-ime` | Runs the window with composition not allowed, so a dead key arrives as a key marked dead. Seen on Linux under Xvfb; not yet run on macOS. |
| `mise run window-check -- --seconds <n>` | Closes the window after that many seconds if nobody has (120 by default). |

The exit status is 0 when the window ran, 1 when it could not be opened and
2 when the options are not understood. A window that ran and never reported
that it opened counts as one that could not be opened, in the report and in
the status. The gate runs the same loop on the
scripted platform (`ffi-test`) and on a fake (`lean-test`), with no window,
and checks there what each option asks for.

## The window's contract, on a desktop

```sh
mise run window-contract
```

**Its first run on a desktop failed, and what was changed for it has not
been confirmed by a person at the keyboard.** "What the first desktop run
showed", below, says what failed and why. Both programs also run in the
container, under Xvfb, as parts 1 and 4 of `linux-window`. These are the
steps for the owner.

It opens two windows on this desktop, one after the other, so it is not
part of the gate, which builds both programs and runs neither. Of the
second it runs the unit tests, which open no window.

**The first** holds the real window to the window port's contract
(`crates/editor-platform`, `contract`): it opens, it tells whatever draws
in it that it opened before it reports so to anyone, it reports that it
opened before anything else, it returns when it is asked to close from
another thread and not before, even if it was asked to close before it
opened, and it tells the drawer it is closing, once, last. The window opens
for about a second. It is the example of `crates/editor-platform-winit`,
and it prints one line.

**The second** is the window that draws: the example `window` of
`crates/editor-ffi` (`examples/window.rs`). The real window is run onto a
queue with a render session as its drawer, and the session's renderer is
the wgpu renderer on the window's surface, on this machine's GPU. A second
thread stands in for the editor: when it learns the window's size and
scale it tells its layout the scale, lays out a fixture frame with the
real shaper over the fixture fonts, and publishes it. The fixture's text
is 14 points, so it is 14 physical pixels on a display at scale 1 and 28
at scale 2. The window stays for 20 seconds once it is ready, or until it
is closed.

The steps:

1. Start `mise run window-contract` from a terminal that is in front.
2. A window opens and closes within a second. Expected:
   `window-contract: the winit platform keeps the window port's contract`.
3. A second window opens. Look at it: two rows of text on a light
   background, `fine שלום 日` with part of it selected and `the window
   draws this`, and a dark status row at the bottom. The text is legible
   and upright. Expected in the terminal as it opens, after `input:
   resized <w> by <h> at scale <s>`: `window: frame 1 is laid out for <w>
   by <h> at scale <s>: 14 points are <p> pixels`, with `<p>` 14 times
   `<s>`: 28 on a display at scale 2. The same line is printed for each
   frame published that is not the one before it, so again after a
   resize. Any other `<p>` fails the run (`window: FAILED: frame <n> is
   laid out for a window at scale <s>, where 14 points are <e> pixels,
   and its glyphs are drawn at <p> pixels`).
4. Leave it alone until the terminal prints `window: ready for input`.
5. In the window: press `a`, Escape and Control-A; click, drag and scroll;
   resize it. Each is printed on a line beginning `input:`, as it read
   back from its event: check each line against what was done.
6. Close the window, or wait for it to close. Expected, in order:
   - `window: the renderer is on <the adapter> (<the back end>), blending
     by a coverage for each channel: <true or false>`;
   - `window: <n> frames presented, each with a journal entry; …`;
   - perhaps, once or twice, `window: a draw was not presented: the
     window's surface gave no texture: Occluded`: a window that was not
     yet on the screen when its first frame was drawn. More than a few
     is a finding: a draw refused so is not tried again until the window
     says more;
   - for each frame, `window: frame <n>: read back from the surface, <d>
     of <p> pixels differ from the headless renderer's, the worst by <w>
     of 255`, with `<w>` at most 3; or, on a surface that says it does
     not let its texture be copied from, `window: frame <n>: the surface
     does not let its texture be copied from, so its picture is not
     compared`. That second line is not a failure here, and it means the
     picture was not checked on this machine: write it down as that. A
     picture that could not be read back for any other reason is a
     failure (`window: FAILED: frame <n>'s picture could not be read
     back: …`);
   - the timeline, one line for each thing that asked for a draw and for
     each draw, in the order they happened: `window: at <t> ms: <what>`,
     with `<t>` the time since the window told its drawer it opened.
     `<what>` is one of: `the window told its drawer it opened, <w> by
     <h> at scale <s>, on a display that refreshes <r> thousandths of a
     hertz`; `the window told its drawer it is <w> by <h> at scale <s>`;
     `the window told its drawer it is damaged`; `the window told its
     drawer <Hidden(true), Hidden(false), Refresh(..) or Closing>`;
     `frame <n> was published`, with `again` when it is equal to the one
     before; `draw <n> began, of frame <f> on <w> by <h> at scale <s>,
     for <a frame not yet shown, a size not yet drawn at, damage>`;
     `draw <n> ended, presented, its glyphs as <plain masks, or subpixel
     masks, red first>` or `draw <n> ended, not presented`; `the idle
     second began` and `ended`. No draw may say `for nothing that was
     asked`. The masks are what the renderer says it drew that frame's
     glyphs with: as the settings come, plain ones on a display at scale
     2 and up and subpixel ones below it, on an adapter that blends by a
     coverage for each channel, and plain ones always on one that does
     not;
   - for each frame presented, `window: the journal's frame <n> answers
     something asked <t> ms after the window opened: its draw began at
     <t> ms and it was presented at <t> ms`: the render loop's own
     account, to hold against the timeline;
   - `window: idle: over 1 s in which nothing was published, 0 frames
     were drawn and the window asked for 0` (a system that uncovers the
     window in that second may ask for a frame or two, and as many are
     then drawn). The second begins once the window has drawn what was
     asked of it as it opened; if five seconds pass and it has not, the
     second begins anyway and `window: idle: the second began before the
     window had settled: …` is printed first;
   - `window: over the whole run, <d> draws for <a> things that asked for
     one`, with `<d>` no more than `<a>`;
   - `window: left alone <k> times, and each time the window showed what
     was laid out for it`, with `<k>` at least 1 ("Left alone", below);
   - `window: <n> inputs came off the queue, <k> of them keys or the
     pointer`;
   - `window: the window drew the fixture frame, drew nothing it was not
     asked for, and its input arrived on the queue`; exit status 0.

A line beginning `window: FAILED:` says what did not hold, and the exit
status is then 1. Do not loosen the 3 to make it pass: a difference past
it is a finding. To keep the window longer or shorter, run the example by
hand: `cargo run --locked --package editor-ffi --example window --
--seconds <n>`.

| Option of the example | Does |
|---|---|
| `--seconds <n>` | Closes the window that many seconds after it is ready, if nobody has (20 by default). |
| `--require-picture` | Fails the run unless every frame's picture was read back and compared: a surface that does not let its texture be copied from is then a failure too. `linux-window` gives it; this task does not, since a desktop's surface may be such a one. |
| `--until-closed` | The window stays until a person closes it. Not understood with `--seconds`. The timeline then prints up to 5000 lines, not 300. `window-by-hand` gives it. |
| `--no-picture` | No picture is read back and none is compared: the run prints `window: pictures were not read back (--no-picture): the picture was not checked in this run`, once, and fails for no picture. Not understood with `--require-picture`. `window-by-hand` gives it: reading a picture back and comparing it takes about half a second a draw at 1600 by 1200, which makes every step of a resize look stalled. |
| `--family <name>` | Lays the fixture out in that family of this machine's fonts, in place of the fixture fonts, and prints `window: the fixture is laid out in <name>, of this machine's fonts` first. A family the machine has not fails the run before any window opens (`window: FAILED: this machine has no font family named <name>, of its <n> families`). No task gives it. |

**Left alone.** A window is left alone when a second passes in which it
tells its drawer nothing, no frame is published and no draw begins or
ends; the example's own idle second is the first such time. Each such
time, if the window has not said it is hidden, a frame has been presented
and no draw is in progress, the draw last presented must be of a frame
laid out for the size and the scale the window last said, on that size
and scale. Otherwise the run fails: `window: FAILED: left alone from <t>
ms after it opened, the window showed frame <n>, laid out for <w> by <h>
at scale <s>, on <w> by <h> at scale <s>, when it had last said it is <w>
by <h> at scale <s>`. A window that was never left alone while it showed
a frame prints `window: the window was never left alone for a second
while it showed a frame, so what it shows when it is left alone was not
judged`, which is no failure by itself. What the window shows between two
sizes, while it is not left alone, is not judged.

What the example makes of what it saw (how these options are read, which
of them contradict each other, which findings of a picture fail which
run, which sizes a frame's glyphs are drawn at and which of them fail,
what the timeline says of a draw's masks, and which ledgers show a window
left alone with something not laid out for it) is tested in the gate, by
the example's own unit tests, which open no window.

What to write down here when it has been run on a desktop: the machine,
its GPU and the back end; the lines of step 6; and, on macOS, what the
window looked like while it was resized and whether anything was drawn
while it was covered.

### What the first desktop run showed

The owner ran it on 2026-11-14 on macOS (aarch64, Apple M5 Max, Metal, a
display at scale 2). The first program passed. The second failed:

```
window: 2 frames presented, each with a journal entry; the first 586.7 ms after the size it answers arrived, 3 rows built
window: frame 1: read back from the surface, 31 of 1920000 pixels differ from the headless renderer's, the worst by 1 of 255
window: frame 2: read back from the surface, 31 of 1920000 pixels differ from the headless renderer's, the worst by 1 of 255
window: idle: over 1 s in which nothing was published, 1 frames were drawn and the window asked for 0
window: over the whole run, 2 draws for 8 things that asked for one
window: FAILED: 1 frames were drawn while idle and 0 were asked for
```

The picture held, on Metal, on a surface that lets its texture be copied
from. The failure was the check's, not the window's. Four things were
found, the first three since changed:

- **The idle second was measured wrongly.** On macOS the system asks for
  a window's content a few milliseconds after it opens (`drawRect:`,
  which the adapter tells as damage). The example's first draw had begun
  by then, and it takes hundreds of milliseconds in this check, read back
  and compared as it is; so the damage was answered by a second draw as
  soon as the first ended. The idle second began at that same moment, and
  counted a draw whose asking was before it. Under Xvfb the damage comes
  before the first frame is published, and one draw answers both. The
  example now enters what asks and what is drawn in one ledger and judges
  each draw by what it was for, begins the idle second once what was
  asked as the window opened is drawn, and prints the ledger
  (`crates/editor-ffi/examples/window.rs`, "The ledger").
- **A window that opens is not on the screen at once, and does not say
  so.** Seen when the example was started from a process that was not in
  front: the surface answered `Occluded` for the window's first 140 ms,
  the window told nothing until `Hidden(false)`, and the render loop
  tried the refused draw again every refresh meanwhile, nine times, which
  failed the count over the whole run (10 draws for 8 things that asked).
  A draw refused because nobody can see its target now says so, and the
  loop waits to be told more (`editor-render`'s `render_loop`, "A hidden
  target"). The owner's run did not meet this: its first draw presented.
- **A click arrived as a press, a drag and a release, all at one place.**
  winit on macOS says where the pointer is before every press and every
  release. Being told the pointer is where it already was is no longer a
  drag.
- **The window said its size four times as it opened, the same each
  time**: once from the adapter, straight after `Opened`, and three times
  from winit, which says the size at each step of building the window,
  before it is shown. They are reported as winit says them. Nothing is
  drawn for them: the same size is no demand to the render loop, and a
  frame equal to the one shown is none either (2 draws for 8 things that
  asked). An editor that lays out at every resize lays out four times as
  it opens there.

The second program was then run on that desktop three more times, each
for two seconds and each started by a tool and not from a terminal in
front, so that its window was not on the screen at once. The first, with
the check as it was, failed on the count over the whole run; the second,
with the ledger, showed the nine refused draws; the last, on the tree
with all three changes, exited 0:

```
window: at       0.0 ms: the window told its drawer it opened, 1600 by 1200 at scale 2, on a display that refreshes 120000 thousandths of a hertz
window: at      28.8 ms: frame 1 was published
window: at      28.8 ms: draw 1 began, of frame 1 on 1600 by 1200 at scale 2, for a frame not yet shown
window: at      35.4 ms: the window told its drawer it is damaged
window: at      37.6 ms: the window told its drawer it is 1600 by 1200 at scale 2
window: at      37.7 ms: the window told its drawer it is 1600 by 1200 at scale 2
window: at      37.7 ms: frame 1 was published again
window: at      37.8 ms: frame 1 was published again
window: at      37.8 ms: the window told its drawer it is 1600 by 1200 at scale 2
window: at      37.9 ms: frame 1 was published again
window: at      64.4 ms: draw 1 ended, not presented
window: at      64.4 ms: draw 2 began, of frame 1 on 1600 by 1200 at scale 2, for a frame not yet shown and damage
window: at      64.6 ms: draw 2 ended, not presented
window: at     147.9 ms: the window told its drawer Hidden(false)
window: at     147.9 ms: draw 3 began, of frame 1 on 1600 by 1200 at scale 2, for a frame not yet shown and damage
window: at     721.8 ms: draw 3 ended, presented
window: at     731.6 ms: the idle second began
window: at    1736.6 ms: the idle second ended
window: idle: over 1 s in which nothing was published, 0 frames were drawn and the window asked for 0
window: over the whole run, 3 draws for 8 things that asked for one
```

A click in that run arrived as a press and a release, with no drag
between. **Not seen since the changes**: a run started from a terminal in
front, where the first draw presents and a second answers the damage
(the timeline should then show `draw 2 began, … for damage` before the
idle second begins); the whole task, both programs; input checked line
by line; a resize by hand; the window covered and uncovered.

### The window at the macOS weight, without a person

On 2026-11-14 the agent that implemented the macOS weight ran the second
program alone (`cargo run --locked --package editor-ffi --example
window`), on the same machine, with no person at it. The window was
occluded for its first 30 seconds (three draws not presented: `the
window's surface gave no texture: Occluded`), then shown; one frame was
presented, in plain masks at scale 2, and read back:

```
window: frame 1: read back from the surface, 64 of 1920000 pixels differ from the headless renderer's, the worst by 1 of 255
```

So on Metal the window's picture at the macOS weight is the headless
renderer's at the same settings (`Settings::core_text()` on both). The
run failed, exit status 1, on what needs a person or a shown window: `the
window was never seen idle: no frame was presented` before the idle second
could begin, and `no key and no pointer event came off the queue`. The
first program, the contract, was not run. Nobody looked at the window.

## Scale and fullscreen, by hand

```sh
mise run window-by-hand
```

**These steps have not been run by a person.** They were written for the
owner, who is the one to run them: no program can judge an apparent size,
press the green button, move a window between two displays or switch
Spaces, and nothing below was done in place of a person doing so. What was
run without a person is under "What has been run without a person", at
the end of this section. Until the steps are run and what was seen is
recorded, nobody has seen a window of ours enter fullscreen, move between
displays or change Space.

The task runs the window that draws (the second program of
`window-contract`, above) with `--until-closed --no-picture`: the window
stays until it is closed, and no picture is read back. It needs a Mac
with a display at scale 2 and a second display at scale 1.

**What the program checks for the person at the window**, each decided by
a function that the example's own unit tests run in the gate:

- For each frame it publishes, the scale it was laid out at and the size
  its glyphs are drawn at, printed as it happens: `window: frame <n> is
  laid out for <w> by <h> at scale <s>: 14 points are <p> pixels`. The
  run fails if `<p>` is not 14 times `<s>` to within a 64th: that is the
  path from the window's scale through layout to the shaper, on a real
  window.
- For each draw, the kind of mask the renderer drew its glyphs with, in
  the timeline: `draw <n> ended, presented, its glyphs as plain masks`,
  or `as subpixel masks, red first`. After a move from a display at scale
  2 to one at scale 1 the line changes from the first to the second.
- Left alone, the window shows what was laid out for it. Whenever a
  second passes in which the window tells nothing, nothing is published
  and no draw begins, and the window is not hidden, the last draw
  presented must be of a frame laid out for the size and scale the window
  last told, on that size and scale. It prints `window: left alone <k>
  times, and each time the window showed what was laid out for it`, or
  fails with which frame, laid out for what, was on what. This is "no
  stale frame", after entering fullscreen, after leaving it, after a move
  between displays and after coming back from another Space, for as often
  as the person pauses a second.

**What no program checks**: that 28 pixels looks like 14 points beside
another app; that glyph edges are grey on one display and fringed with
colour on the other; that nothing looked stretched while the system
animated.

The steps:

1. With the terminal in front on the display at scale 2, run `mise run
   window-by-hand`. To compare like with like, run it by hand in a family
   another app has: `cargo run --locked --package editor-ffi --example
   window -- --until-closed --no-picture --family Menlo` (it then prints
   `window: the fixture is laid out in Menlo, of this machine's fonts`
   first). Expected as the window opens: `input: resized <w> by <h> at
   scale 2` and `window: frame 1 is laid out for <w> by <h> at scale 2:
   14 points are 28 pixels`. Wait for `window: ready for input`.
2. **Size.** Open TextEdit, type `the window draws this` in the same
   family, regular, at 14 points, at 100%, and put it beside the window.
   Pass: the letters are the same height and a row is as tall, by eye.
   Before this phase's change the window's text was 16 pixels whatever
   the display, a little over half that size at scale 2. **Weight.**
   Pass: by eye, the window's text is not lighter than TextEdit's in
   the same family and size. Check it in Menlo (`--family Menlo`, as
   above): `mise run window-by-hand` lays the fixture out in Noto Sans,
   which TextEdit shows only where Noto Sans is installed. On macOS the
   window draws to Core Text's weight
   (`Settings::core_text()`, "The renderer, as built" in
   `docs/design/text-and-display.md`); before that change it was known
   to look lighter. Record what was seen under "The weight beside
   TextEdit, by eye", below.
3. **Two displays.** Drag the window to the display at scale 1 and let
   go; wait a second. Expected in the terminal: `input: resized … at
   scale 1`, once for the scale and again for the size (winit sends one
   and then the other: read, and not seen on macOS; on X11, in the
   container, the first came every time and the second most times), and
   `window: frame <n> is laid
   out for <w> by <h> at scale 1: 14 points are 14 pixels`. On screen:
   the text is the size TextEdit's is when its window is dragged over
   too. Take a picture of the window (Command-Shift-4, Space, click) and
   enlarge it in Preview until pixels show: on the display at scale 1 the
   edges of glyphs are fringed with colour, on the display at scale 2
   they are grey only. Drag it back; wait a second: scale 2 and 28 pixels
   again.
4. **Fullscreen.** Click the green button. (The window has no menu, so a
   keyboard shortcut for fullscreen may do nothing: use the button.)
   Watch the animation and write down whether the text looked stretched
   or the window showed a black band at any moment. When it has settled,
   wait a second. Pass: the status row is at the bottom of the screen and
   reads `window  <w> by <h>` with the screen's size in pixels; the rows
   of text are at the top left at the size they were; nothing is blurred
   or stretched.
5. **Spaces.** With the window fullscreen, go to another Space
   (Control-Left or Control-Right, or a three-finger swipe), wait two
   seconds, and come back. Pass: the scene is there at once, as it was;
   not blank, and not at an older size. Wait a second.
6. **Leaving fullscreen.** Move the pointer to the top of the screen and
   click the green button. When it has settled, wait a second. Pass: the
   window is its old size, with the status row at its bottom reading that
   size.
7. Press `a`, then Control-A, then Command-S, and click once in the
   window, then close it with the red button. Expected as the keys are
   pressed, among the lines of the modifiers' own presses and of the
   releases: `input: key press 'a' at KeyA with none, text "a"`, `input:
   key press 'a' at KeyA with control, text ""` and `input: key press
   's' at KeyS with super, text ""`. A key pressed with Control or
   Command held carries no text; winit gives it `a` and `s` there (read,
   not seen), and the adapter drops them. A line that says `with none`
   for the second or the third, or a text that is not empty, is a
   finding: the first would mean macOS says a modifier is held after
   the key it was held for. Expected, after the lines `window-contract`
   already documents:
   in the timeline, `the window told its drawer Hidden(true)` and
   `Hidden(false)` around step 5, with no draw between them; draws at
   scale 2 ending `its glyphs as plain masks` and those at scale 1 `as
   subpixel masks, red first`; no draw `for nothing that was asked`;
   `window: pictures were not read back (--no-picture): the picture was
   not checked in this run`; `window: left alone <k> times, and each time
   the window showed what was laid out for it`, with `<k>` at least 5;
   exit status 0.
8. **What to record in the phase body**: the machine, the two displays
   and their scales; the lines of steps 1, 3 and 7; and what was seen at
   steps 2 to 6, the animation of step 4 among it.

A step that fails is a finding to bring back, not something to adjust the
check for.

Two things the phase asks for cannot be promised by a resize alone, and
step 4 is where they would show. Between a change of the window's size
and the next picture presented at that size, the system stretches the
last picture to the window's new bounds (the default of the Metal layer
wgpu makes: read, not seen). And the render loop's first draw on a new
size is of the frame laid out for the old one, with black where that
frame has no view, until the frame laid out for the new size arrives.
Each lasts until the next draw or two. If either is visible during the
system's animation and matters, the fix is code this phase does not have:
a call on the layer for the first, and who lays out on a resize for the
second ([`concurrency.md`](../design/concurrency.md)).

What a point is, for step 2: a logical point, one physical pixel at scale
1. On macOS that is the same number as the typographic point another app
states. On a Linux desktop it is not: a "14 pt" font in another app is 14
× 96/72 pixels at scale 1, and will not match.

### What has been run without a person

On 2026-11-14, on macOS (aarch64, Apple M5 Max, Metal), with the
display asleep, so that no window could be seen and no draw presented:

- `cargo run --locked --package editor-ffi --example window -- --seconds 2
  --no-picture`: `input: resized 1600 by 1200 at scale 2`, then `window:
  frame 1 is laid out for 1600 by 1200 at scale 2: 14 points are 28
  pixels`. The surface answered `Occluded` to two draws, the window never
  said it was shown, and nothing was drawn in the 31 seconds that
  followed; the run failed, as it must, for no frame presented and no
  input. It printed `window: pictures were not read back (--no-picture):
  the picture was not checked in this run` and `window: the window was
  never left alone for a second while it showed a frame, so what it shows
  when it is left alone was not judged`.
- The same with `--until-closed --no-picture --family Menlo`, stopped by
  a time limit after eight seconds: `window: the fixture is laid out in
  Menlo, of this machine's fonts`, then `window: frame 1 is laid out for
  1600 by 1200 at scale 2: 14 points are 28 pixels`; the window did not
  close by itself.
- In the container (`mise run linux-window`, part 4), at scale 1: `14
  points are 14 pixels` for the frame at 800 by 600 and for the one at
  300 by 120, each of three draws `its glyphs as subpixel masks, red
  first`, and `window: left alone 2 times, and each time the window
  showed what was laid out for it`: the idle second, and the seconds
  after xdotool's resize.

- With the example changed by hand so that it does not tell its layout
  the scale, and changed back: on the same desktop it printed `window:
  frame 1 is laid out for 1600 by 1200 at scale 2: 14 points are 14
  pixels` and failed with `frame 1 is laid out for a window at scale 2,
  where 14 points are 28 pixels, and its glyphs are drawn at 14 pixels`.

- In the container again, with part 4's second run, where winit is told
  a scale of 2 (`WINIT_X11_SCALE_FACTOR=2`): `14 points are 28 pixels`
  for the frame at 800 by 600 and for the one at 300 by 120, each of
  three draws presented and ending `its glyphs as plain masks`, each
  picture compared, and `window: left alone 2 times, and each time the
  window showed what was laid out for it`. With the example changed by
  hand as in the item above, and changed back, that run failed with the
  same line as the desktop's and the run at scale 1 passed.

So the window's scale reaching the shaper through layout is seen at scale
2, on one display and in the container, and seen to fail the run when it
does not. The container's run at scale 1 does not show it: there a
layout told nothing lays out the same. Its run at scale 2 shows it each
time `mise run linux-window` is run, on a window winit was told is at
scale 2, with a draw presented and plain masks said, on llvmpipe. A
change of scale under an open window is seen there too, each time, from
1 to 2, on X11, by the display's settings being changed ("The window on
Linux, on demand", "The change of scale"): the resize at the new scale
comes off the queue, the frame laid out for it has glyphs of 28 pixels,
and the draw after it says plain masks where the draws before said
subpixel ones. **Not seen by anyone**: a draw at scale 2 presented on a
display that is at scale 2, and on Metal; a window moved between two
displays, and a change of scale from 2 to 1; fullscreen; another Space;
the size beside another app.

### What the owner's run showed

Not yet run. Record here, and in the phase body: the machine, the two
displays and their scales; the lines of steps 1, 3 and 7; and what was
seen at steps 2 to 6.

### The weight beside TextEdit, by eye

**For the owner.** This is the check that the window's text, drawn on
macOS to Core Text's weight, no longer looks lighter than TextEdit's
(rdm task `editor-render-text-lighter-than-core-text`). The weight was
fitted to Core Text drawing offscreen; only a person at the display can
say whether it looks right beside TextEdit.

On macOS, at a display of scale 2, run

```sh
cargo run --locked --package editor-ffi --example window -- --until-closed --no-picture --family Menlo
```

and put it beside TextEdit showing `the window draws this` in Menlo
Regular, 14 points, at 100%. Pass: the window's text is not lighter than
TextEdit's. (`mise run window-by-hand` is not this check: it lays the
fixture out in its default family, Noto Sans, and TextEdit shows that
only where Noto Sans is installed.)

Record here, and in the task: the date, the machine and the display's
scale; whether the window's text looked lighter, as heavy, or heavier
than TextEdit's; and, if it helps, a screenshot of the pair.

What the owner saw, on 2026-11-14, on the Mac the checks above ran on
(Apple M5 Max; the display's scale not stated):

- In Menlo, by the command above, beside TextEdit in Menlo Regular 14 pt
  at 100%: the weight looks right, as heavy as TextEdit's and not
  lighter. **Passes.**
- In the fixture's default family: not compared. The first run was `mise
  run window-by-hand`, in Noto Sans, beside TextEdit in Menlo; the owner
  saw the family was wrong. TextEdit shows Noto Sans only where it is
  installed, so that pair was not made like with like.
- Outside this check: "some of the spacing and maybe the 'w' are not
  quite the same" as TextEdit's. That is rdm task
  `editor-render-glyph-spacing-and-shape-vs-core-text`.

## The system's fonts, on demand

```sh
mise run shaper-system
```

This holds the real shaper over the fonts of this machine
(`FontSet::system` in `crates/editor-shape-parley`) to the shaper port's
contract (`crates/editor-layout`, `shaper::contract`). What it finds
depends on the fonts installed, so it is not part of the gate, which only
builds it: every test of the adapter runs on the fixture fonts under
`tests/fonts`, and the crate's `clippy.toml` forbids the system's fonts to
them. It is the example of `crates/editor-shape-parley`
(`examples/system.rs`). It prints the family the default font is shaped in
and how many families the machine has, then either that all the
contract's properties hold or the name of each that fails; its exit status
is the result.

Run it when the pin of Parley or fontique moves, and when
`FontSet::system` changes. It has been run on macOS, where the default
family was Courier of 557 families and every property held. It has not
been run on Linux: the container of `linux-ci` has no fonts installed.

## The gate on Linux, on demand

```sh
mise run linux-ci
```

This runs `mise run ci` on Linux, in a container. It needs Docker and, the
first time, the network, so it is not part of the gate. `tools/linux/run.sh`
builds the image `tools/linux/Dockerfile` describes (Debian 13 with the
system compiler, mise and elan, each pinned), copies the checkout into a work
directory, and runs the gate there. The copy is the tracked files and the
untracked files git does not ignore, so uncommitted work is tested and this
machine's own build output is not touched. The exit status is the gate's.

| Where | What |
|---|---|
| `.linux-ci/home/` | The toolchains: rustup's, elan's, mise's installs. About 4.6 GB. |
| `.linux-ci/work/` | The copy of the source, with Lake's build output. About 1.2 GB. |
| The Docker volume `editor-linux-ci-cargo` | Cargo's home and `target/`. They must not be on a directory mounted from macOS: clean runs failed there. About 1.4 GB. |
| The Docker image `editor-linux-ci` | The system packages, mise and elan. About 0.9 GB. |

`.linux-ci/` is at the root of the checkout and ignored by git; set
`EDITOR_LINUX_CACHE` to put it elsewhere. `mise run linux-ci -- --clean`
empties the copy's build output first and keeps the toolchains and Cargo's
registry: everything is compiled again and nothing is downloaded again.

It runs on the machine's own architecture. It has been run on aarch64, not
on x86_64.

## The window on Linux, on demand

```sh
mise run linux-window
```

This is where the winit adapter is held to the window port's contract
without a desktop, where the window draws, and where the arboard adapter is
held to the clipboard port's. Run it after a change to
`crates/editor-platform-winit`, to `crates/editor-platform-arboard`, to a
contract in `crates/editor-platform`, to the surface code of
`crates/editor-render-wgpu`, or to `render` in `crates/editor-ffi`. It uses
the image, the cache and the volume of `linux-ci`, and runs seven things
under Xvfb, a display that needs no screen and no person, failing if any
fails:

1. the window adapter's example, as `window-contract` runs it first;
2. `editor window-check --seconds 5`, with xdotool giving the window the
   focus and typing a sentence and a dead key into it;
3. the same with `--no-ime`;
4. the window that draws, as `window-contract` runs it second
   (`crates/editor-ffi/examples/window.rs`), on Mesa's software Vulkan
   driver, llvmpipe, and with `--require-picture`, which that task does
   not give. It is run twice: at scale 1, which is what Xvfb's display
   is at, and at scale 2. Each time, once it says it is ready, xdotool
   gives it `a`, Escape, Control-Shift-A, a press, a drag, a release, a
   turn of the wheel and a resize. The key with Control held must come
   off with no text: the X server gives it `A` (seen), and a key pressed
   with Control produced nothing to insert. The first run then ends with
   a change of scale, to 2, while the window is open ("The change of
   scale", below). Each run fails if the
   example fails (a frame whose glyphs are not drawn at 14 points times
   the window's scale; no frame presented; a frame whose picture was not
   read back from the surface and compared, whatever the reason; a
   picture more than 3 of 255 from the headless renderer's; a frame
   drawn that nothing asked for; a window left alone for a second with a
   frame not laid out for the size and scale it last said; no input), if
   any of those eight inputs did not come off the queue as the port
   documents it, the resize at the run's scale, and if no frame printed
   `at scale 1: 14 points are 14 pixels` in the first run and `at scale
   2: 14 points are 28 pixels` in the second.

   **The second run is what shows the window's scale reaching layout.**
   At scale 1 a layout that was told the scale and one that was not lay
   out alike, so the first run's line shows only that the fixture's 14
   points reach the real shaper and come back in the frame's fonts. For
   the second run winit is told the scale in the environment
   (`WINIT_X11_SCALE_FACTOR=2`, which its X11 back end takes in place of
   what the display says: seen at the pin). The window then says scale 2
   as it opens, the example's editor thread reads that off the resize it
   pulls from the queue and tells its layout, and the frame's fonts come
   back at 28 pixels. With the example made not to tell its layout the
   scale, the second run prints `14 points are 14 pixels` and fails with
   `frame 1 is laid out for a window at scale 2, where 14 points are 28
   pixels, and its glyphs are drawn at 14 pixels` (seen in the
   container, on 2026-11-14, and once before that on a desktop at scale
   2). The first run passed under that change for as long as it kept its
   scale of 1 to the end (seen); now that it ends with a change of scale
   it fails there too, on the frame laid out after the change, and the
   task stops before the second (seen). The pictures are read back and
   compared at scale 2 as at scale 1. The timeline ends each presented
   draw `its glyphs as subpixel masks, red first` in the first run, until
   its change of scale, and `its glyphs as plain masks` after that and
   in the second, on llvmpipe, which blends by a coverage for each
   channel; the task requires neither line.
   **What the second run is not**: a display at scale 2. It is winit
   that is told, the window is 800 by 600 pixels as it opens at either
   scale, and nothing shows how large 28 pixels look.

   **The change of scale.** The first run ends with the one change of
   scale the container can make, so that the adapter's line that takes
   winit's event for it apart is run on a real one (`App::window_event`
   in `crates/editor-platform-winit`, the `ScaleFactorChanged` arm: the
   event cannot be built in a test). winit's X11 back end reads the
   scale from the display's settings: `Xft/DPI` of XSETTINGS where a
   daemon serves them, else `Xft.dpi` of the X resources. For that run
   `xsettingsd`, which the image has for this alone, serves 96 dots an
   inch from before the window opens. Once the resize to 300 by 120 has
   come off the queue, and a second and a half more have passed so that
   the frame laid out for that resize is drawn and judged first, its
   file is rewritten to 192 and it is signalled to read it again. winit
   then sends the event, and the run requires
   what the port documents for it, a resize at the size last known and
   the new scale: `input: resized 300 by 120 at scale 2`. The example
   lays a frame out for it, which must say `14 points are 28 pixels` or
   the example fails. winit then asks the X server for the window at
   twice its size, and `input: resized 600 by 240 at scale 2` follows or
   does not (it followed in eighteen runs of twenty, and why not in the
   other two was not looked into): that line is not required. The
   required line came in all twenty. With the arm made to do nothing
   the run prints `input: resized 600 by 240 at scale 1`, the example
   passes, and the task fails with `the change of scale did not come off
   the queue as: input: resized 300 by 120 at scale 2` (seen).

   What was tried first, and does not work here: `xrdb -merge` of
   `Xft.dpi: 192` while the window is open. winit has a handler for a
   change of the root window's `RESOURCE_MANAGER`, but at the pin it
   asks the X server for property changes of its own windows and of the
   settings daemon's, not of the root (read); `xwininfo -root -events`
   listed no event of the core protocol that anybody wants of the root
   while the window was open, a property's change among them (seen);
   and no change of scale arrived, nor after `xrandr --dpi
   192` or `xrandr --fb 1000x700` following it, each of which the window
   answered as hidden, shown and damaged and no more (seen). `xrdb` and
   `xrandr` are not in the image.

   **What the change of scale is not**: a window moved between two
   displays. Here one display changes its settings, on X11. winit sends
   the same event for both, and the adapter's line is the same; what
   macOS sends around it, in which order the scale and the size come,
   and the antialiasing changing on a real display, are still step 3 of
   "Scale and fullscreen, by hand";
5. the clipboard adapter's example, as `clipboard-contract` runs it: that
   display's clipboard held to the clipboard port's contract, in one
   process;
6. a text written to the clipboard by one process and read by another,
   while the first is still alive. One process cannot show this: on X11
   the text is served by the process that wrote it;
7. the editor on a file (since milestone 1): `editor --report` on a copy
   of `tests/window/session.txt`, with no toolchain, so no config, and
   xdotool typing `ihello `, `<Escape>`, `:w`, `<Return>`, `:q` and
   `<Return>`. The editor must exit 0 within 60 seconds, the copy must
   hold the bytes of `tests/window/session-expected`, and the report must
   count at least one frame. The report is printed; its figures are Xvfb's
   and llvmpipe's, not milestone figures. First run 2026-11-15 (Apple M5
   Max host, aarch64 container): all seven passed; the surface offered
   `immediate`, `mailbox`, `fifo` and `fifo-relaxed` and was configured
   with `fifo` at a frame latency of 1; 16 frames, `present - input`
   median 3704 µs, p99 51462 µs. The counters said no glyph was
   rasterised: why (whether the container's fonts give the editor's
   `monospace` anything) was not looked into, and the check does not ask
   for glyphs.

Its input is synthetic. It goes through the X server and the real window
library, so it shows the path a key and the pointer take on Linux, but
nobody typed it: it is not the keyboard check above, and its output says
so. Its clipboard is the container's own: nothing of this machine's is
read or written.

**It is the required confirmation of what the gate cannot hold.** The gate
opens no window, makes no surface and has no clipboard, so the gate being
green says nothing of any of them. Two things are confirmed here and
nowhere in the gate:

- that text written through the clipboard adapter is the text read back
  through it: parts 5 and 6;
- that the window draws a scene supplied by a fixture, and that input
  given to it arrives on the queue: part 4.

A change that touches the window, the surface or the clipboard is not done
until both `mise run ci` and this task exit 0, every part, on the tree that
is to land. Each of its checks was seen to fail once by hand, in the
container: the picture, with the surface drawn through a view that is not
sRGB (every pixel off, by 74 of 255); that a picture is compared at all,
with the surface configured without the use that lets its texture be
copied out, so that wgpu refuses the copy (`frame 1's picture could not
be read back: Validation Error`, for each frame), and with the surface
made to say its texture is not copied from (`frame 1's picture was not
compared, and this run requires it (--require-picture)`, for each
frame); the idle second, with a render loop
that marks its frame dirty after every draw (10 frames drawn, 0 asked for)
and with a window that asks for a redraw whenever it is asked for one
(270139 asked for); an input's line, with Escape named `Esc`; the
input itself, with nothing sent; the scale reaching layout, with the
example made not to tell its layout the scale (a run at scale 2 exits 1,
as quoted under part 4); that a frame was laid out at scale 2 at all,
with winit not told the scale in the second run (`no frame said it is
laid out at scale 2 and its 14 points are 28 pixels`); and the change of
scale, with the adapter's arm for it made to do nothing (`the change of
scale did not come off the queue as: input: resized 300 by 120 at scale
2`). Those two mutations of the idle second
were made again once the example judged each draw by what asked for it,
and each still fails the task: the first with `334 of the 336 draws were
asked for by nothing: the first is draw 2, which began 256.1 ms after
the window opened` and `336 draws were made and 5 were asked for`, each
such draw `for nothing that was asked` in the timeline; the second with
`the window asked to be drawn 273961 times while idle: more than 5 is a
timer`. Before the example failed a picture
that could not be read back, the first of those two mutations left this
task at exit 0 with three frames presented and no picture compared: a
journal entry shows that a present call returned, and only the
comparison shows that what was presented is the fixture.

Under Xvfb there is no clipboard manager, so a text is gone from the
clipboard when the process that wrote it ends. That is X11's rule and not
the adapter's, and part 6 keeps the writer alive for it. Xvfb's display
says no refresh rate either, so the window paces by the render loop's own
interval there, and pacing to a display's refresh is not seen.

It was run on 2026-11-14 (aarch64, Debian 13, Mesa 25.0.7): all six parts
passed. In part 4 the renderer was on llvmpipe through Vulkan, blending by
a coverage for each channel; three frames were presented, of 800 by 600
and, after the resize, of 300 by 120 twice; each was read back from the
surface and differed from the headless renderer's picture by 1 of 255 at
the worst; no frame was drawn in the idle second; and the eight inputs
came off the queue as documented. In the timeline the window said it was
shown and damaged before the first frame was published, so the first
draw was for both; the resize drew the frame shown on the new size and
then the frame laid out for it; and no draw was refused. It has not been
run on x86_64, and nothing here runs a Wayland compositor.

It was run again that day once the fixture's text was 14 points and the
example told its layout the window's scale: all six parts passed. Part 4
printed `window: frame 1 is laid out for 800 by 600 at scale 1: 14 points
are 14 pixels` and, after the resize, `window: frame 2 is laid out for 300
by 120 at scale 1: 14 points are 14 pixels`; three frames were presented
and each was read back and differed from the headless renderer's picture
by 1 of 255 at the worst; each draw ended `presented, its glyphs as
subpixel masks, red first`; and no frame was drawn in the idle second.
And once more with the fifth check: all six parts passed, with the same
lines and `window: left alone 2 times, and each time the window showed
what was laid out for it`. In those runs part 4 ran the window once, at
scale 1.

It was run again that day with part 4's second run, at scale 2: all six
parts passed. The second run printed `input: resized 800 by 600 at scale
2`, `window: frame 1 is laid out for 800 by 600 at scale 2: 14 points are
28 pixels` and, after the resize, `window: frame 2 is laid out for 300 by
120 at scale 2: 14 points are 28 pixels`; three frames were presented and
each was read back and differed from the headless renderer's picture by 1
of 255 at the worst; each draw ended `presented, its glyphs as plain
masks`; no frame was drawn in the idle second; the window was left alone
twice and showed what was laid out for it; and the eight inputs came off
the queue as in the first run, the resize at scale 2. The container has
one display, at scale 1: the scale of 2 is what winit was told.

And again that day, six times, with the change of scale at the end of
part 4's first run: all six parts passed each time. A second and a half
after `input: resized 300 by 120 at scale 1` the first run printed
`input: resized 300 by 120 at scale 2`, `window: frame 3 is laid out for
300 by 120 at scale 2: 14 points are 28 pixels`, `input: resized 600 by
240 at scale 2` and `window: frame 4 is laid out for 600 by 240 at scale
2: 14 points are 28 pixels`. Five frames were presented: three at scale
1, in subpixel masks, as before; then the frame laid out at scale 1 on
300 by 120 at scale 2, which is the one draw a frame of the old scale
gets on the new one; then the frame laid out for 600 by 240 at scale 2;
those two in plain masks. Each picture was compared, the worst by 1 of
255, and the window was left alone three times and showed what was laid
out for it each time. Before that the scale was changed fourteen times
as soon as the resize had arrived, without the wait, seven of them by
hand with no pointer input: the required line came every time, and the
window grew to 600 by 240 in twelve and stayed 300 by 120 at scale 2 in
two, where the run passed as well.

## The clipboard, on demand

**This has not been run on any desktop.** It was written for the owner to
run; on Linux its two halves are parts 5 and 6 of `linux-window`, above,
which ran in the container.

```sh
mise run clipboard-contract
```

**It writes the clipboard of the desktop it is started from.** It holds the
system clipboard (`SystemClipboard` in `crates/editor-platform-arboard`) to
the clipboard port's contract (`crates/editor-platform`,
`clipboard::contract`), so it is not part of the gate, which only builds it:
a real clipboard is the desktop's, and the gate leaves the machine as it
found it. It is the example of `crates/editor-platform-arboard`
(`examples/clipboard.rs`), run with `contract`.

What it does to the clipboard: it keeps the text it finds there, writes
four texts of its own, and puts the text it found back. **Only text is put
back.** An image, a file or anything else that was on the clipboard is
lost, and a clipboard that held no text is left holding the contract's
last text, `a later text`.

The steps:

1. Copy something disposable, as text, so that nothing of value is on the
   clipboard.
2. Run `mise run clipboard-contract`.
3. Expected: one line for each of the contract's four properties, each
   beginning `clipboard-contract: holds:`; then `the text found on the
   clipboard was put back`; then `the system clipboard keeps the clipboard
   port's contract`; exit status 0.
4. Paste somewhere: it is the text copied in step 1.

A property that fails is printed with `FAILS` and the exit status is 1; so
is a clipboard that could not be opened, with the reason.

Not known, and for whoever runs it on macOS to write down here: whether the
empty text written to the clipboard reads back as the empty text or as no
text. The contract does not ask.

## The renderer on a real GPU, on demand

```sh
mise run render-gpu
```

The gate runs the wgpu renderer on wgpu's no-op back end only, which
checks its calls and draws nothing ([`the-gate.md`](the-gate.md)). This is
where the picture it draws is checked. What it finds depends on this
machine's GPU and its driver, and a machine with no GPU has nothing to run
it on, so it is not part of the gate, which only builds it. It opens no
window: it draws to a texture and reads it back.

It is the example `gpu` of `crates/editor-render-wgpu`
(`examples/gpu.rs`). It does three things, and its exit status is whether
the first two held:

1. holds a renderer on this machine's adapter to the renderer port's
   contract (`crates/editor-render`, `contract`);
2. draws the fixture frame of real text, reads it back and compares it
   with what the CPU compositor draws: no channel of any pixel may differ
   by more than 3 of 255. In subpixel masks it is compared with the
   reference image `tests/render/frame.png`; in plain masks, as a display
   of two physical pixels to a logical one gets them, with the headless
   adapter's picture of the same frame drawn the same way. An adapter
   that cannot blend by a coverage for each channel draws only the
   second. Then the same frame at the macOS weight
   (`Settings::core_text()`), in plain masks and, where the adapter can,
   in subpixel masks, each against the headless adapter's picture drawn
   with the same settings: the contrast reaches the shader and the
   dilation the atlas. The fixture has no colour glyph, so a colour image is drawn by
   no GPU here: that path of the shader is validated in the gate and has
   never been seen;
3. prints how long a first frame, a frame with a row edited and a frame
   that differs only in its cursor took, with the rows each built. The
   times are of one run of a debug build: nothing is asserted of them and
   they are no measurement.

Run it after a change to the shader, the wgpu device, the painter or the
blend, and when the pin of wgpu moves. Do not loosen the 3 to make it
pass: a difference past it is a finding.

It was run on 2026-11-14 on macOS (aarch64): Metal on an Apple M5 Max,
blending by a coverage for each channel; all 9 properties of the contract
held; 42 of the frame's 24576 pixels differed from the reference image,
and 14 from the headless adapter's picture in plain masks, the worst by 1
of 255 in each.

It was run again on 2026-11-14 on the same machine (macOS 27.2, Metal on
the Apple M5 Max), with the macOS weight's comparisons: exit status 0;
all 9 properties held; 42 pixels differed from the reference image and 14
from the plain masks, as before; at the macOS weight, 35 differed in plain
masks and 64 in subpixel masks, the worst by 1 of 255 in each. With the
contrast left out of the CPU's side only (a change made for the run and
undone), the macOS weight's comparisons failed, the worst by 5: so the
check sees the shader's contrast.

## The renderer on Linux, on demand

```sh
mise run linux-render
```

The same example, in the container of `linux-ci`, on Mesa's software
Vulkan driver, llvmpipe: a real adapter that needs no GPU. It needs
Docker. The image installs Mesa's Vulkan drivers and the Vulkan loader for
this task alone (`tools/linux/Dockerfile`); they are in the image
`linux-ci` uses too, and the gate there, which asks for no adapter, runs
the same with them.

It was run on 2026-11-14 (aarch64, Debian 13, Mesa 25.0.7): llvmpipe
through Vulkan, blending by a coverage for each channel; all 9 properties
held; 247 pixels differed from the reference image, and 168 from the
headless adapter's picture in plain masks, the worst by 1 of 255 in each.
It has not been run on x86_64.

It was run again on 2026-11-14 (aarch64, on an Apple M5 Max host), with the
macOS weight's comparisons: exit status 0; llvmpipe (LLVM 19.1.7) through
Vulkan; all 9 properties held; 247 and 168 pixels differed, as before; at
the macOS weight, 246 differed in plain masks and 394 in subpixel masks,
the worst by 1 of 255 in each.

## The reference image, on demand

```sh
mise run render-reference
```

This writes `tests/render/frame.png`, the picture the gate compares the
headless renderer's with, by running the example `reference` of
`crates/editor-render-wgpu`. It writes a file of the repository, which no
gate may do, so the gate only builds it. `tests/render/README.md` says
what the image shows, when to make it again, and what to do then: look at
it, enlarged, before committing it.

## The Core Text reference, on demand

```sh
mise run coretext-reference
```

This writes `tests/coretext/sentence.png`: the sentence `the window draws
this` drawn by Core Text from the fixture font Noto Sans Mono at 14 pt on
a bitmap of scale 2, black on white, with font smoothing on. It is the
macOS target the renderer's weight is fitted to and held to
(`crates/editor-render-wgpu/src/weight_tests.rs`). It runs
`tools/coretext/capture.swift` with the system's `swift`, so it needs
macOS. It writes a file of the repository, which no gate may do, so it is
not in the gate, and nothing in the gate runs Swift.

Run it on a new major version of macOS, or when the fixture font changes.
`tests/coretext/README.md` records how the file was last captured and
what to do with a new one: look at it, enlarged, before committing it, and
fit the weight again if it no longer matches.

## The editor on a file, by hand

`mise run edit -- <file>` (`lean/Editor/Window/Real.lean`): the editor on a
file, in a window. The gate runs the same wiring on the library's scripted
platform (`ffi-test window-host`), and `mise run linux-window` runs it on
a real window under Xvfb with xdotool typing (its seventh part); neither
is a person at a window. This is the owner's procedure, for milestone 1's
fourth criterion. Record in the phase body, for each run: the date, the
commit, the machine, the macOS version, the display or displays with their
scale and refresh rate, the command, and what was seen at each step marked
**Record**.

On macOS, in a terminal at the checkout, at the reviewed commit:

1. `mise install`, then `mise run lean`.
2. `cp lean/Editor/Loop.lean /tmp/dp6-session.lean`, so that no tracked
   file is edited, then `mkdir -p /tmp/dp6-config` and
   `cp tests/headless/config/*.lean /tmp/dp6-config/`.
3. `mise run edit -- --report --config /tmp/dp6-config /tmp/dp6-session.lean`.
   **Record**: that the window shows the file's first rows in a monospace
   font at the size of other apps' text, with a status line reading
   `normal` and `dp6-session.lean`, and that the bottom row below it is
   empty.
4. An evil edit, with what is seen after each: `j j j` (the cursor moves
   down), `dw` (a word goes, and the status line shows the modified mark),
   `i`, type `hello `, `<Escape>` (the text appears as typed, once per key
   and not twice, with the bar cursor in insert state and the block after
   `<Escape>`), `u` then `C-r` (the edit goes and comes back), `C-f` then
   `C-b` (the view scrolls a page and back), and `"+yw` (yank a word to the
   clipboard). Then paste into TextEdit. **Record** that the word arrives.
5. `:w` and `<Enter>`. **Record**: that while `:w` is typed it shows in the
   input row above the bottom row, with the prompt in the bottom row; and
   that after `<Enter>` the input row is gone, the modified mark goes, and
   the bottom row says the file was written. In a second terminal,
   `diff lean/Editor/Loop.lean /tmp/dp6-session.lean`. **Record** that the
   diff is the edit.
6. A broken config: `printf 'def broken : Nat := "x"\n' > /tmp/dp6-config/30-broken.lean`,
   then `:reload` and `<Enter>`. **Record**: that the bottom row shows
   `reload: 30-broken.lean:1:…: error: …`, and that `j` and `dw` still
   work. Then `rm /tmp/dp6-config/30-broken.lean`.
7. Idle: note the time and leave the window untouched for 60 s, with no
   pointer over it. In the second terminal, run
   `ps -o time=,rss= -p $(pgrep -n editor)` at the start and at the end.
8. The external change, which no phase builds (task
   `display-pipeline-open-file-reload`): optionally
   `echo '-- external' >> /tmp/dp6-session.lean`. **Record** what the
   window shows. The expected answer is nothing new.
9. `:q` and `<Enter>`. The window closes and the report prints on
   stderr. **Record**: the report's frame count, its `present - input`
   figures, and the longest stretch with no frame, which must cover step
   7's 60 s. That stretch and the CPU time from step 7 are "the journal
   shows no work while idle".

On Linux, on a desktop and not under Xvfb, if there is one: steps 3 to 5
and 9, with a text editor of the desktop in place of TextEdit. If there is
none, record "not measured on Linux: no desktop".

## Milestone 1, measured

Milestone 1's figures: key press to frame submitted (median and 99th
percentile), idle CPU, memory at startup, memory after opening a 10 MiB
file, and scrolling through it. Each figure goes in the phase body with
the command or procedure that gave it, and with what it is: headless
(below) or a window's (the owner's, after it).

**Headless, by an agent or anyone: `mise run milestone-bench`**
(`tools/milestone-bench.sh`), on a quiet machine, twice. It runs five
scripts of `editor headless --render` under `/usr/bin/time -l`, and prints
the machine first. Every figure it gives is labelled "headless: cell
shaper, CPU renderer, no glyphs": what Lean, layout and the loop cost, and
not what a window costs.

| Figure | Script | Line it prints |
|---|---|---|
| Memory at startup | `start`: a frame of 1280 by 800, no file | `start: maximum resident set …`, `start: peak memory footprint …` |
| Memory after opening a 10 MiB file | `open`: `:e` on a generated file of 201,650 lines of 52 bytes (10,485,800 bytes), then `join` | `open: maximum resident set …`, `open: peak memory footprint …` |
| Scrolling through it | `scroll`: 300 `C-f`, each paced by `idle 0`, then `G` | its second `journal` line (the 300 frames' `present - input` and rows rebuilt) and its third (`G`); `scroll: real …` |
| Key press to frame submitted | `type`: 200 `l` and `h` in a 640 by 480 view of a small file, each paced by `idle 0` | its second `journal` line |
| Idle CPU | `idle-30000` against `idle-0`: the same session with `idle 30000` and `idle 0` | the difference of their `user` + `sys`, and `idle 30000: 0 frames drawn, 0 frames submitted` |

`idle 0` paces a key: it waits until the render loop has drawn what the key
asked for and is at rest, so that no key's frame is replaced in the
mailbox before it is drawn.

**In a window, by the owner.** Two sessions, each started with
`mise run edit -- --report <file>`:

- Typing, on a one-line file, `printf 'x\n' > /tmp/dp6-one.txt`:
  1. Memory at startup: once the window shows,
     `ps -o rss= -p $(pgrep -n editor)` and
     `footprint $(pgrep -n editor) | tail -1`.
  2. `A`, then type `the quick brown fox jumps over the lazy dog` three
     times at an even pace, then `<Escape>`, `:w` and `:q`. Record the
     report's median and 99th percentile.
  3. Idle CPU: in another run on the same file, `ps -o time=` 60 s apart,
     untouched.
- The 10 MiB file, written with
  `awk 'BEGIN{for(i=0;i<201650;i++) printf "%07d the quick brown fox jumps over the lazy dog\n", i}' > /tmp/dp6-ten.txt`:
  1. `mise run edit -- --report /tmp/dp6-ten.txt`, and note how long the
     window takes to show the text, by eye or by stopwatch.
  2. Memory once shown: `ps` and `footprint` as above.
  3. Hold `C-f` for 10 s, then `G`, then `gg`.
  4. `:q`. Record the report's figures and the counters' rows rebuilt.

## The present mode, measured on a window

**No figure exists yet: these are the owner's steps, at a real window.**
These are the steps by which the display pipeline's phase 6 measures the
present mode on a window. They are written down now because the decision was
taken first, by reading: `Fifo` at a frame latency of 1 on every platform
([`rendering-prior-art.md`](../design/rendering-prior-art.md), "Present
mode and pacing"). A measurement needs a window on a display. A window
that draws exists since the display pipeline's phase 5, and has run under
Xvfb, which has no display to pace against, and for a few seconds at a
time on one macOS desktop, where nothing was measured; these steps are how
that decision is borne out or overturned.

Who runs it, and when: whoever builds phase 6, at a real window, on a
quiet machine, once on macOS and once on Linux on a desktop (not under
Xvfb, which has no display to pace against).

What is there already, built by phase 5, and so no longer phase 6's to
build first:

- a surface on the window, configured from what `present::choose`
  (`crates/editor-render-wgpu`) gives for the modes the surface offers
  (a surface does not report its range of frame latency: the one asked
  for is held to it by wgpu);
- the render loop running on its thread, on the clock that stamps window
  input (`editor-ffi`'s), so that an entry's input time and its present
  time are on one clock;
- the frame journal, read through the loop's handle at the end of a run,
  in Rust (`crates/editor-ffi/examples/window.rs` reads it so).

What phase 6 built for it:

- `--present-mode fifo|fifo-relaxed|immediate|mailbox` and
  `--frame-latency <n>`, flags of the window mode for one run, not
  settings, each on its own: the renderer gives the mode asked when the
  surface offers it, and the decision's otherwise or when none is asked,
  and the latency asked, or the decision's when none is asked, held to the
  range offered (`present::choose` in `editor-render-wgpu`);
- frames published from Lean reaching the window, stamped with the key
  they answer, so that a key typed draws a frame;
- `--report`, which prints to stderr once the window has closed what the
  surface offered, only what was asked (`asked a frame latency of 2` for
  `--frame-latency 2` alone) and what was configured, the counters,
  each journal entry's present time with its `present - input`, their
  median, 99th percentile (nearest rank) and largest, and the longest
  stretch with no frame.

The steps, for each platform (O3; on Linux, O4, on a desktop and not under
Xvfb):

1. Run `mise run edit -- --report /tmp/dp6-one.txt` once (the one-line
   file of "Milestone 1, measured"), and record the modes the report's
   `presentation:` line says the surface offered. Compare them with the
   table in `rendering-prior-art.md`, of which the Vulkan row has been
   seen on a surface (llvmpipe, under Xvfb) and the others only read in
   wgpu's source, and correct the table where they differ.
2. For each of these that the surface offers, one run each:
   `mise run edit -- --report --present-mode fifo --frame-latency 1 /tmp/dp6-one.txt`,
   then `--present-mode fifo --frame-latency 2`, `--present-mode immediate`,
   `--present-mode mailbox` and `--present-mode fifo-relaxed`.
3. In each run, type the same sentence three times at the same pace, then
   resize the window by dragging its corner, then `:w` and `:q`.
4. Record, from each report: the median and the 99th percentile of
   `present - input`, the entry count, and the longest stretch with no
   frame.
5. Look at the window while it is resized, and write down what is seen:
   whether the content lags the window's edge. That is what presenting
   with the transaction would change on macOS, and it cannot be asked for
   through a surface's configuration.

What to record, in phase 6's body: for each platform and each run, the
figures of step 4; the machine, its GPU and driver, the display and its
refresh rate, and whether the display has a variable refresh; the wgpu
back end; the command that was run; and one sentence that says whether
the figures bear out `Fifo` at a frame latency of 1 or what they favour
instead. If they favour another, the decision in `rendering-prior-art.md`
and `present::PREFERRED` change in the same commit.
