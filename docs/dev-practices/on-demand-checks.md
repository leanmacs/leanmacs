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

**The second of its two programs, the window that draws, has not been run
on any desktop**, and the first has not been run since the contract gained
its rules about the drawer. Both ran in the container, under Xvfb, as parts
1 and 4 of `linux-window`, below. On macOS nothing of the window that draws
has run at all: a surface on Metal, made on the main thread and drawn on
from the render thread, is read and compiled, never run. These are the
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
thread stands in for the editor: when it learns the window's size it lays
out a fixture frame with the real shaper over the fixture fonts and
publishes it. The window stays for 20 seconds once it is ready, or until
it is closed.

The steps:

1. Start `mise run window-contract` from a terminal that is in front.
2. A window opens and closes within a second. Expected:
   `window-contract: the winit platform keeps the window port's contract`.
3. A second window opens. Look at it: two rows of text on a light
   background, `fine שלום 日` with part of it selected and `the window
   draws this`, and a dark status row at the bottom. The text is legible
   and upright.
4. Leave it alone until the terminal prints `window: ready for input`.
5. In the window: press `a`, Escape and Control-A; click, drag and scroll;
   resize it. Each is printed on a line beginning `input:`, as it read
   back from its event: check each line against what was done.
6. Close the window, or wait for it to close. Expected, in order:
   - `window: the renderer is on <the adapter> (<the back end>), blending
     by a coverage for each channel: <true or false>`;
   - `window: <n> frames presented, each with a journal entry; …`;
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
   - `window: idle: over 1 s in which nothing was published, 0 frames
     were drawn and the window asked for 0` (a system that uncovers the
     window in that second may ask for a frame or two, and as many are
     then drawn);
   - `window: over the whole run, <d> draws for <a> things that asked for
     one`, with `<d>` no more than `<a>`;
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

What the example makes of what it saw (how these options are read, and
which findings of a picture fail which run) is tested in the gate, by the
example's own unit tests, which open no window.

What to write down here when it has been run on a desktop: the machine,
its GPU and the back end; the lines of step 6; and, on macOS, what the
window looked like while it was resized and whether anything was drawn
while it was covered.

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
the image, the cache and the volume of `linux-ci`, and runs six things
under Xvfb, a display that needs no screen and no person, failing if any
fails:

1. the window adapter's example, as `window-contract` runs it first;
2. `editor window-check --seconds 5`, with xdotool giving the window the
   focus and typing a sentence and a dead key into it;
3. the same with `--no-ime`;
4. the window that draws, as `window-contract` runs it second
   (`crates/editor-ffi/examples/window.rs`), on Mesa's software Vulkan
   driver, llvmpipe, and with `--require-picture`, which that task does
   not give. Once it says it is ready, xdotool gives it `a`, Escape,
   Control-Shift-A, a press, a drag, a release, a turn of the wheel and
   a resize. The part fails if the example fails (no frame presented; a
   frame whose picture was not read back from the surface and compared,
   whatever the reason; a picture more than 3 of 255 from the headless
   renderer's; a frame drawn that nothing asked for; no input), and if
   any of those eight inputs did not come off the queue as the port
   documents it;
5. the clipboard adapter's example, as `clipboard-contract` runs it: that
   display's clipboard held to the clipboard port's contract, in one
   process;
6. a text written to the clipboard by one process and read by another,
   while the first is still alive. One process cannot show this: on X11
   the text is served by the process that wrote it.

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
(270139 asked for); an input's line, with Escape named `Esc`; and the
input itself, with nothing sent. Before the example failed a picture
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
came off the queue as documented. It has not been run on x86_64, and
nothing here runs a Wayland compositor.

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
   second. The fixture has no colour glyph, so a colour image is drawn by
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

## The present mode, measured on a window

**Nothing in this section has been run, and no figure exists yet.** These
are the steps by which the display pipeline's phase 6 measures the present
mode on a window. They are written down now because the decision was
taken first, by reading: `Fifo` at a frame latency of 1 on every platform
([`rendering-prior-art.md`](../design/rendering-prior-art.md), "Present
mode and pacing"). A measurement needs a window on a display. A window
that draws exists since the display pipeline's phase 5, and has run only
under Xvfb, which has no display to pace against; these steps are how
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

What phase 6 must still build first:

- a way to ask for another present mode and another frame latency for
  one run, which the editor does not otherwise offer: a flag of the
  measuring command, not a setting;
- frames published from Lean reaching the window, so that a key typed
  draws a frame; and a way to read the journal from the measuring
  command.

The steps, for each platform:

1. Note what the surface reports: its formats and its present modes.
   Compare them with the table in `rendering-prior-art.md`, of which the
   Vulkan row has been seen on a surface (llvmpipe, under Xvfb) and the
   others only read in wgpu's source, and correct the table where they
   differ.
2. For each of these that the surface offers, one run each: `Fifo` at a
   frame latency of 1; `Fifo` at 2; `Immediate`; `Mailbox`;
   `FifoRelaxed`.
3. In each run, open a fixture file checked in for the purpose, and type
   a fixed run of keys: the same keys, at the same pace, every run (typed
   by a script where the platform allows one, and by hand otherwise, with
   which it was written down).
4. Read the frame journal. Over the entries of the run, take
   `present_ns − input_ns`, the time from a key's arrival to its frame's
   presentation, as a median and a 99th percentile; and count the
   entries, to see that each key drew a frame and that nothing drew while
   idle.
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
