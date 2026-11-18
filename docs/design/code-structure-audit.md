# Code structure audit (2026-11-17, main at 37b1335)

`lean/ModelTest.lean` reached 38,031 lines, about 15% of the Rust and Lean
source in the repository, and lean-fmt's exact-frontend child ran past its
600-second bound on it on the macOS CI runner (roadmap `ci-flakes`, phase
`phase-3-lean-fmt-modeltest-timeout-ci`). Size usually points at a
structural problem: a file that collects everything of one kind, a state
structure that holds every concern, or a port that grows a method per
question. This audit measures the largest files and judges each, with the
editor state and the widest interfaces, against the working rules in
`AGENTS.md` ("Architecture: ports and adapters", "Testing with hand-written
mocks", "Crate coupling"), the component boundaries in
[overview.md](overview.md), and, for the Lean interfaces, the port, model
and contract rules in [lean-runtime.md](lean-runtime.md).

The audit is a snapshot of main at 37b1335. The verdicts name follow-up
work by its rdm slug; the code they describe changes as that work lands.

## How size was measured

Size is counted in non-test lines. The command below, run from the
repository root, lists every tracked `.rs` and `.lean` file outside
`vendor/` with its non-test lines, its total lines and its path, largest
first, and keeps those over 1,500 non-test lines.

Test code is left out in two ways. A whole file is test code when it is
under a `tests/` or `benches/` directory, is a `tests.rs` or ends in
`_tests.rs`, or is one of the four Lean test-executable roots
(`lean/ModelTest.lean`, `lean/ConfigTest.lean`, `lean/FfiTest.lean`,
`lean/ContractTest.lean`). In any other Rust file, the body of a top-level
`#[cfg(test)] mod … { … }`, up to its closing `}` in column 0, is test code.
Published contracts and fakes (`contract.rs`, `Contract.lean`, `fake.rs`,
`lean/Editor/InputScheme/Test.lean`) count as non-test code, because they
are compiled into their library. Module docs count as code: in Lean they
are a large share of several files.

```sh
git ls-files '*.rs' '*.lean' | grep -v '^vendor/' | while read -r f; do
  case "$f" in
    */tests/*|*/benches/*|*/tests.rs|*_tests.rs|lean/ModelTest.lean|lean/ConfigTest.lean|lean/FfiTest.lean|lean/ContractTest.lean) n=0 ;;
    *.rs) n=$(awk '/^#\[cfg\(test\)\]/{t=1;next} t&&/^(pub(\(crate\))? )?mod [A-Za-z_]+ *\{/{s=1;t=0;next} t{t=0;n++} s&&/^\}/{s=0;next} !s{n++} END{print n+0}' "$f") ;;
    *) n=$(wc -l < "$f") ;;
  esac
  printf '%7d %7d %s\n' "$n" "$(wc -l < "$f")" "$f"
done | sort -rn | awk '$1 > 1500'
```

Its output at 37b1335 (non-test lines, total lines, path):

```
   4300    4300 lean/Editor/Ffi.lean
   3546    3546 lean/Editor/State.lean
   3189    3189 lean/Editor/Text/Contract.lean
   2771    2771 lean/Editor/Text/Model.lean
   2482    2482 lean/Editor/Loop.lean
   2399    2399 lean/Editor/Headless.lean
   1991    1991 lean/Editor/Api.lean
   1844    3502 crates/editor-ffi/examples/window.rs
   1730    1730 lean/Editor/Text.lean
   1651    1663 crates/editor-process/src/contract.rs
```

The command measures 478 tracked files; these 10 are over the line. Four more are audited because the task names
them, though they fall under the line: `crates/editor-process/src/service.rs`
(1,476 of 2,988), `crates/editor-ffi/src/window.rs` (1,364 of 2,913),
`crates/editor-layout/src/frame.rs` (1,356 of 3,715) and
`crates/editor-platform-winit/src/translate.rs` (545 of 2,168). The four
Lean test roots, which the command counts as 0, are 38,031
(`ModelTest`), 5,764 (`ConfigTest`), 4,340 (`FfiTest`) and 3,378
(`ContractTest`) lines.

## Findings

Each finding answers four questions: whether the file holds one concern
(**Cohesion**), whether its ports are small and grown with data
(**Interfaces**), where its tests live (**Test layout**), and what to do
(**Verdict**: *split* along named seams, *narrow the interface*, or
*acceptable as is*, with the reason).

### The model tests: `lean/ModelTest.lean`

**Cohesion**: It is the root of the `model-test` executable, the `lake
test` driver, and it holds every model test of the Lean program: 38,031
lines, 74 imports, 1,032 top-level definitions in one `namespace
ModelTest`, among them 159 check lists, a `checks` aggregator at line
37,743 and `main` at line 38,003. The check lists are already one per
concern (`stateChecks`, `loopChecks`, `stateRequestChecks`,
`autoReloadChecks`, `poolChecks`, `runnerChecks`, …), and those are the
seams. The file has one purpose but holds the tests of every module.

**Interfaces**: None of its own. It drives the editor's ports over their
pure models, which is what AGENTS.md asks of tests above a port.

**Test layout**: This is the outlier the audit started from. Rust's tests
sit beside their modules; Lean's model tests are all here, so lean-fmt
elaborates the whole of them as one file, and any change to any test
rebuilds all of them.

**Verdict**: *split* into one test module per module under test, under
`lean/ModelTest/`, with the root reduced to its imports, `checks` and
`main`. The split is owned by roadmap `ci-flakes`, phase
`phase-3-lean-fmt-modeltest-timeout-ci`, and no new task is filed for it;
that phase now records the layout below ("Test layout"). The check names
are cited widely: `git grep -o 'ModelTest\.[a-zA-Z]*Checks'` finds 256
citations in 112 files, among them `docs/dev-practices/the-gate.md` (which
also names `lean/ModelTest.lean`), `docs/dev-practices/headless-mode.md`,
six documents under `docs/design/` (agent hosting, concurrency, keymaps and
modes, the Lean runtime, the Rust library, text and display) and 104 files
under `lean/`, `lean/Editor/State.lean`'s "Where a new field goes" among
them.
The split keeps every `ModelTest.<name>Checks` name and the
`lean/ModelTest.lean` path cited under `docs/` and `lean/` resolvable, or
updates those citations.

### The config session's tests: `lean/ConfigTest.lean`

**Cohesion**: The root of the `config-test` executable, linked with the
glue and the Rust archive: 5,764 lines, 12 imports, 249 top-level
definitions and 27 check lists. It holds two concerns, the headless host
driven in-process (`hostChecks`, `threadChecks`, `jobChecks`,
`scriptChecks`, `dispatchChecks`, `hostLoopChecks`, `promptChecks`,
`exChecks`, `exScriptChecks`, `fileChecks`) and the config session against
the real elaborator, plus the benchmark `mise run config-bench` runs.

**Interfaces**: None of its own; it is an integration test of wiring, as
AGENTS.md places such tests.

**Test layout**: As ModelTest's, at a seventh of the size. It is not near
lean-fmt's bound.

**Verdict**: *split* by the same rule as ModelTest, into test modules
behind a thin root, as one follow-up with FfiTest and ContractTest:
`split-lean-integration-test-roots`. Its priority is low. `ConfigTest.<name>Checks`
is cited 73 times in 28 files, `docs/dev-practices/the-gate.md` and
`docs/design/lean-runtime.md` among them; the split keeps those names and
the root's path resolvable, or updates the citations.

### The binding's tests: `lean/FfiTest.lean`

**Cohesion**: The root of the `ffi-test` executable, linked exactly like
`editor`: 4,340 lines, 13 imports, 162 definitions and 31 check lists, one
or more per binding family (`handleChecks`, `documentChecks`,
`snapshotChecks`, `fileChecks`, `displayChecks`, `syntaxChecks`, …). The
families are the seams, and they match the modules of
`crates/editor-ffi/src/`.

**Interfaces**: None of its own.

**Test layout**: As ConfigTest's.

**Verdict**: *split* into one test module per binding family behind a thin
root, in `split-lean-integration-test-roots`, low priority.
`FfiTest.<name>Checks` is cited 41 times in 12 files, among them
`lean/Editor/Ffi.lean`'s conventions, `docs/design/lean-runtime.md` and
`docs/dev-practices/the-gate.md`.

**Done** (roadmap `structural-splits`, phase
`phase-2-split-lean-integration-test-roots`): split. `lean/FfiTest.lean`,
4,412 lines at 5f86580, is now 173: its imports, its module doc, `checks`
and `main`. Its lists and scenarios are in 27 test modules under
`lean/FfiTest/Editor/`, each mirroring the module it tests: one per binding
family with a list of its own (`lean/FfiTest/Editor/Ffi/Document.lean` for
`lean/Editor/Ffi/Document.lean`), and the mirror of the module tested for
the lists that test something else (`sceneChecks` in
`lean/FfiTest/Editor/Display/Real.lean`, `paddingChecks` in
`lean/FfiTest/Editor/State.lean`, the window-host scenarios in
`lean/FfiTest/Editor/Window/Real.lean`). The families with no list of their
own (`Log`, `Text`, `Excerpts`, `Diffs`, `Clipboard`, `Words`) have no test
module. The helpers several modules share are in six support modules under
`lean/FfiTest/Support/`, and `Check`, `failures`, `run` and `usage` in
`lean/FfiTest/Check.lean`. Everything stays in `namespace FfiTest`, so every
`FfiTest.<name>Checks` citation resolves unchanged. The run is the same
before and after: `ffi-test: 205 checks passed` and `ffi-test shutdown: 3
checks passed`. The largest new module is
`lean/FfiTest/Editor/Display/Real.lean` (435 lines).

### The contracts against the real bindings: `lean/ContractTest.lean`

**Cohesion**: The root of the `contract-test` executable: 3,378 lines, 37
imports, 136 definitions and 16 check lists. It runs the published
contracts (the text port's, the job port's and others) against their real
bindings. Each contract it runs is a seam.

**Interfaces**: None of its own; the contracts it runs are defined in the
library (`Editor/Text/Contract.lean` and its peers).

**Test layout**: As ConfigTest's.

**Verdict**: *split* into one module per contract run, behind a thin root,
in `split-lean-integration-test-roots`, low priority.
`ContractTest.<name>Checks` is cited 33 times in 13 files.

### The editor state: `structure EditorState` in `lean/Editor/State.lean`

**Cohesion**: The module is 3,546 lines, about 900 of them module docs.
The structure has 27 fields, counted with `awk '/^structure
EditorState/,/^$/' lean/Editor/State.lean | grep -cE '^  [a-zA-Z]+ :'` (the
task's figure of 29 predates this count). The module's placement table
("Where a new field goes") already keeps per-buffer, per-window,
per-prompt and per-workspace state out of it, and that holds. What is left
is grouped only by the row "The whole editor", and several fields belong
together and are read together:

- **A host outbox**: what a command asked for that the loop hands to its
  host once the command has run to its end: `starts`, `cancels`,
  `answered`, `reload`, `theme` and `quitting`. Five of their doc comments
  say "which the loop has not yet handed to its host".
- **Vim session memory**: `registers`, `lastFind`, `lastSearch`.
- **The display's last readings**: `heights`, `padding`, `tabBarShown`,
  `tabBar`.
- **File following**: `autoReload`, `following`.

**Interfaces**: The port over the state is `StateRequest`
(`lean/Editor/State/Request.lean`), with 65 variants. Growing with
variants is what AGENTS.md asks, so the count alone is no fault. But 14
variants are not state operations: the handler, `EditorState.handle`,
answers each with a stand-in, because only the loop that knows the
registry and config can answer them (`Program.dispatched`,
`lean/Editor/Command/Dispatch.lean`). Eleven are questions to the registry
or config (`ex`, `exNames`, `themeNames`, `autoReloadMode`,
`workspaceSettings`, `displayRules`, `shellTimeLimit`,
`syntaxRefreshDelay`, `languageOf`, `indentUnitOf`, `compileHook`), and
three control the running command (`runCommand`, `giveUp`, `breakOff`).
The module's own rules say a question is one read of the state and the
handler reaches nothing outside it; each new config setting a command
reads has instead become another state variant with a stub case.
`EditorRequest` (`lean/Editor/Command.lean`) is already a sum of
sub-ports, so these belong on a sub-port the loop answers.

**Test layout**: Pinned from ModelTest (`stateChecks`,
`stateRequestChecks`, `loopChecks`); it moves with the ModelTest split.

**Verdict**: *split* the structure by grouping at least the host outbox
and the Vim session memory into sub-structures, with the operations and
module-doc sections that own them (`group-editor-state-fields`), and
*narrow the interface* of `StateRequest` by moving the registry and config
questions, and the decision on the three control requests, to a sub-port
of their own (`narrow-state-request-port`). The placement table is what
keeps the structure from becoming a god struct, so the first follow-up
adds a row for the outbox.

### The bindings: `lean/Editor/Ffi.lean`

**Cohesion**: The largest non-test file, 4,300 lines: about 450 lines of
conventions (handles, plain data, event queues, services and completions,
the syntax service, the window, the interrupt flag, shutdown) and then
every binding in one `namespace Editor.Ffi`, 139 `@[extern]`
declarations. By the glue symbol each names, they fall into families:
document 18, syntax 16, display 15, snapshot 14, processes 12, window 7,
watches 6, files 6, events 6, clipboard 6, render 5, timers 4, interrupt
4, diffs 4, excerpts 3, counter 3, picture 2 and a few single ones. The
Rust side already has one module per family in `crates/editor-ffi/src/`.

**Interfaces**: The externs are the boundary itself, not a port the core
defines; each Lean port's real binding (`Editor/Text/Real.lean`,
`Editor/Display/Real.lean`, …) calls into them. Narrowing would remove
capability, so the interface is not the fault, the file's cohesion is.

**Test layout**: Tested from FfiTest and ContractTest, and from
`editor-ffi`'s Rust tests on the other side.

**Verdict**: *split* into one module per family,
`lean/Editor/Ffi/<Family>.lean`, mirroring the Rust module it binds, with
`lean/Editor/Ffi.lean` keeping the conventions and importing every family
so no caller changes (`split-lean-ffi-bindings-by-port`).

**Done** (roadmap `structural-splits`, phase
`phase-1-split-lean-ffi-bindings-by-port`): split. `lean/Editor/Ffi.lean`
holds the conventions, an index of the families and no `@[extern]`; it
imports the 20 families no other family imports, and the rest come in
through those. The 142 externs (139 at 37b1335; three were added before the
split) are in 25 modules `lean/Editor/Ffi/<Family>.lean`, one per Rust
module of `crates/editor-ffi/src/` that defines them, all still in
`namespace Editor.Ffi`, so no name a caller uses changed. With
`Editor.Ffi` defining nothing itself, lean-fmt's FMT004 flags an
`import Editor.Ffi` that another import already brings, so that line was
dropped from the four files where another import already brings it in:
`lean/Editor/Display/Real.lean`, `lean/Editor/Job/Real.lean`,
`lean/Editor/SyntaxTree/Real.lean` and `lean/FfiTest.lean`. The other six
files that import `Editor.Ffi` keep the line. The word codec the families
share is `lean/Editor/Ffi/Words.lean`, under `Editor.Ffi.Words`, the one
place a raw structure is not private to its family. The largest family
module is `Syntax.lean` (490 lines).

### The window example: `crates/editor-ffi/examples/window.rs`

**Cohesion**: 3,502 lines, 1,844 outside its test module, about 220 of
them module docs. It is one on-demand check program, run by `mise run
window-contract`, `mise run window-by-hand` and, under Xvfb in the Linux
container, `mise run linux-window` (the example's module docs and
`mise.toml`). The gate builds it and never runs it. One purpose, several
concerns: its command line (`Options`, `options`, `family_of`), the
judging of pictures and layout (`Picture`, `Verdict`, `judged`,
`laid_out`), the timing tally and its findings (`Tally`, `Findings`,
`on_demand`, `left_alone`, `timeline`), the frame ledger and the wrapping
renderers (`Ledger`, `Entered`, `Checked`, `compare`), the fixture scene
and fonts, the printing of input, and `main`'s wiring.

**Interfaces**: It is wiring: it uses `editor-platform`'s window port,
`editor-render`'s `Renderer` port and the library's session, and defines
no port of its own. Its decisions are pure functions.

**Test layout**: Its decisions are unit-tested in its own `#[cfg(test)]`
module, about 1,650 lines.

**Verdict**: *split* the example into a directory with a module per
concern above, each with its tests, and `main.rs` keeping the wiring, as
`crates/editor-platform-winit/examples/contract/` already is
(`split-window-example-decisions`). The decisions are the harness's, not
the library's, so they stay in the example.

### The frame: `crates/editor-layout/src/frame.rs`

**Cohesion**: 3,715 lines, 1,356 of them non-test, of which about 240 are
module docs. One concern: the frame as plain data and the one walk that
builds it from a scene (`Layout::frame`), with its rows, cursors,
selections, block rows, status row and dividers.

**Interfaces**: It reads the `Shaper` port (`shape`, `generation`,
`resolved`, `font`, `metrics`), which is small, and produces a value, not
a callback.

**Test layout**: Beside the code, in the module's `#[cfg(test)]` module
(about 2,360 lines), with integration tests under
`crates/editor-layout/tests/`.

**Verdict**: *acceptable as is*: test volume, not code, makes it large,
and the code is one concern behind a small port.

### The process service: `crates/editor-process/src/service.rs`

**Cohesion**: 2,988 lines, 1,476 non-test. One concern: the service above
the process port, which owns a process from spawn to reap, for runs to
their end and for streaming children. The two shapes share the waiter,
the readers and the completion rule, so they are one concern.

**Interfaces**: The `Processes` port (`crates/editor-process/src/lib.rs`)
is four small traits: `Processes` (`spawn`), `Child` (`id`, `take_output`,
`take_input`, `wait`, `kill`), `Output` (`read`) and `ChildInput`
(`write`). The service's own surface is requests by an id the caller
chose, answered once.

**Test layout**: Beside the code, in two `#[cfg(test)]` modules (about
1,510 lines), with the crate's contract run on the fake.

**Verdict**: *acceptable as is*: one concern over a small port, made large
by its tests.

### The window adapter: `crates/editor-ffi/src/window.rs`

**Cohesion**: 2,913 lines, 1,364 non-test. The adapter from
`editor-platform`'s window port to the editor queue: the word layouts
of each event kind (a table in its module docs), the encoding and decoding
of inputs, the run on the main thread, the presentation slot and the
window's renderer, and the tags of window requests. These are the parts of
one adapter, and the module's docs are the one place the layouts are
recorded.

**Interfaces**: Its port is `InputClock`, one method (`now_ns`), with a
real and a counting adapter. It adapts the platform's port rather than
defining a wide one.

**Test layout**: Beside the code (about 1,550 lines), and
`crates/editor-ffi/tests/window.rs`.

**Verdict**: *acceptable as is*: one adapter, made large by its tests and
its layout table.

### The winit translation: `crates/editor-platform-winit/src/translate.rs`

**Cohesion**: 2,168 lines, 545 non-test, about 180 of which are module
docs on how winit's reports become the port's `Input`. One concern: the
translation (`KeyParts`, `Seen`, `Told`).

**Interfaces**: None of its own; it fills `editor-platform`'s `Input`,
which the platform crate owns and grows with data.

**Test layout**: Beside the code, about 1,620 lines: three quarters of the
file.

**Verdict**: *acceptable as is*: the smallest code of the audited files;
its size is its tests.

### The text port's contract: `lean/Editor/Text/Contract.lean`

**Cohesion**: 3,189 lines. One concern: the list of properties every
implementation of the text port keeps, run against the model by
`model-test` and against the real binding by `contract-test`. It is
already sectioned by request family, one property list each (edit,
revision, snapshot, position, release, transaction, log, forget, marker,
extent, inverse, copy, read, motion, search, pair, script, excerpt,
excerpt edit, adopt), gathered by `properties` at its end.

**Interfaces**: It defines none; it is the contract AGENTS.md requires of
a port with a pure model, and it imports only the port.

**Test layout**: It is test content compiled into the library, so the two
executables share it. That is the intended arrangement.

**Verdict**: *acceptable as is*: its size tracks the text port's breadth.
If it grows, the property families are the seams
(`lean/Editor/Text/Contract/<Family>.lean`, gathered by this module).

### The text port's model: `lean/Editor/Text/Model.lean`

**Cohesion**: 2,771 lines, about 115 of them module docs. One concern,
the text store as a value answering every text request, in parts with
their own namespaces: `TextModel` (texts, snapshots, transactions,
excerpts), `TextLog` (the edit log), `TextHistory` and `TextM`'s model run,
with a section on a text in step and undoing an accepted edit.

**Interfaces**: It is the pure model of the text port; its surface is the
port's.

**Test layout**: Held to the library by the contract; tested from
ModelTest.

**Verdict**: *acceptable as is*: one model of one port, whose size tracks
the port's breadth. `TextLog` and `TextHistory` are the seams if it grows.

### The command loop: `lean/Editor/Loop.lean`

**Cohesion**: 2,482 lines, about 1,060 of them module docs, one section
per rule of the loop (running an invocation, a command run inside another,
jobs from commands, prompts, reload, theme switch, quit, rollback, the
interrupt, what each event does, after each event, files changed on disk,
auto-reload, decorations, following the cursor, insert sessions, a refused
publish). One concern: what the editor does with each event, as pure
programs over the editor's port.

**Interfaces**: It is the core above the editor's port and its sub-ports.
New behaviour is added as an event handler, and the module says where
("Where a new event handler goes").

**Test layout**: Tested from ModelTest (`loopChecks` and its peers).

**Verdict**: *acceptable as is*: one concern, and close to half of its
size is its documentation. Its outbox sections become shorter once
`group-editor-state-fields` lands.

### The headless host: `lean/Editor/Headless.lean`

**Cohesion**: 2,399 lines, about 620 of them module docs, 32 imports, and
its own `Request` of 8 variants from its driver. It is the composition
root of the headless mode: it wires the real text binding, a display
recorder, an in-process clipboard, the job runner and the config session
around the command loop. Its code falls into the host's display
(`Host.Display`, about 320 lines), the editor thread's state (`Running`,
about 760 lines) and the driver with its script reader (`Host`).

**Interfaces**: It defines no port the core depends on; it adapts. Its
driver's `Request` grows by variant.

**Test layout**: Driven in-process from ConfigTest and run as an
executable over the fixtures under `tests/headless`.

**Verdict**: *acceptable as is*: wiring belongs at the edge, and a
composition root imports widely. `Host.Display` is the seam if the file
grows (`lean/Editor/Headless/Display.lean`, beside the existing
`lean/Editor/Headless/CommandLine.lean`).

### The editor API: `lean/Editor/Api.lean`

**Cohesion**: 1,991 lines, about 720 of them module docs. One concern:
the operations a command is written with, one section per family (asking
the state, buffers, edits, selections, undo, windows, scrolling, values
and modes, messages, giving up and breaking off, registers, ex bindings,
running another command, quit, reload, themes, jobs, prompts, files,
workspaces).

**Interfaces**: Each operation is a program over the editor's port, close
to one request each, so its breadth is `StateRequest`'s and the text
port's. Its shape is right; what it forwards to is narrowed by
`narrow-state-request-port`, which leaves it unchanged from a command's
side.

**Test layout**: Tested from ModelTest and `lean/Editor/Api/Cases.lean`.

**Verdict**: *acceptable as is*: its size tracks the operations commands
need.

### The text port: `lean/Editor/Text.lean`

**Cohesion**: 1,730 lines, about 630 of them module docs (the port's
rules, excerpt texts, and how to add to the port). One concern: the text
port, `TextRequest` with 21 variants, and its data types (positions,
selections, motions, searches, brackets, quotes, transactions, changes,
anchors, markers, excerpts, spans).

**Interfaces**: Grown with data: a new motion is a `Motion` variant, a new
question a `TextQuery` variant, so the request type stays at 21.

**Test layout**: Held by its contract on the model and the binding.

**Verdict**: *acceptable as is*: a port that grows by data, as AGENTS.md
asks; its size is its vocabulary and its documentation.

### The process contract: `crates/editor-process/src/contract.rs`

**Cohesion**: 1,663 lines, 1,651 non-test. It is the published contract of
the process port with the service's rules that only a real process shows:
30 named properties and the scripts each runs, over a `Ground` the caller
supplies. The port's properties and the service's are two parts of one
check that every real adapter runs.

**Interfaces**: `Ground` has seven methods (`make_file`, `written`,
`exists`, `alive`, `end`, `escapes`, `deadline`), each a question the
check needs of the machine. A trait is the right shape for it, since the
fake and the real adapter each supply their own.

**Test layout**: It is test content compiled into the library, as
AGENTS.md asks of a port's contract; it is run by
`crates/editor-process/tests/contract.rs` on the fake and by
`editor-process-std`'s on real processes.

**Verdict**: *acceptable as is*: a contract is a list of properties, and
this one covers one port and the service over it. The port's properties
and the service's are the seam if it grows.

## Test layout

Rust's tests sit beside the code they test, in a module's
`#[cfg(test)] mod tests` or, once that outgrows the file, in a `tests.rs`
beside it (`crates/editor-render-wgpu/src/painter/tests.rs`), with
integration tests under each crate's `tests/`. A change to one module
rebuilds and reformats one file's tests.

Lean's tests are collected into four executable roots: `ModelTest` (38,031
lines), `ConfigTest` (5,764), `FfiTest` (4,340) and `ContractTest`
(3,378). Lean has no test-only code like `#[cfg(test)]`, so a test cannot
live in the module's own file without being compiled into `Editor`. A
published contract (`Editor/Text/Contract.lean`) is the exception that is
meant to ship, because two executables run it.

The rule that follows is a test module per module, mirrored under the
test executable's root, with a root that only imports its test modules and
runs their checks. It is recorded in `AGENTS.md` under "Testing with
hand-written mocks". The ModelTest split (`ci-flakes`,
`phase-3-lean-fmt-modeltest-timeout-ci`) follows it, and so does
`split-lean-integration-test-roots` for the other three roots.

## Not audited

Files from about 1,200 to 1,500 non-test lines were not audited, so a
later audit knows where the line was drawn: `crates/editor-ffi/src/syntax.rs`
(1,321), `crates/editor-syntax/src/contract.rs` (1,290),
`lean/Editor/Job/Contract.lean` (1,367), `lean/Editor/Compile.lean`
(1,242) and `crates/editor-release/src/nightly.rs` (1,232).

No limit on file size is checked in CI. It would push toward arbitrary
splits, while the problems found here are structural.
