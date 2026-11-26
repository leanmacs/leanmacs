# Remote clients: an iOS client over a server-side editor

How the editor could reach a phone or a tablet: a client app on iOS that
shows agent work, carries the review, and draws code with the editor's own
display, talking to a server that runs everything else (the Lean editor,
processes, git, search, language servers and the agents themselves). The
goal is supervising and reviewing agent work away from the desk, better
than driving a terminal session from a phone.

Status: **proposal**. Nothing below is built. It records the research
pass of 2026-11-26 and the spikes recommended to settle its open
questions. The notes and the report behind it are local
(`reports/Mobile editor shell over remote server.md` and
`research_notes/Mobile editor shell over remote server/`, untracked, see
[publishing](../dev-practices/publishing.md#research_notes-and-reports-stay-local));
some of their sources are secondary and are marked so here.

## What the phone is for

What [review-interface.md](review-interface.md) and the mobile review
research say fits a phone:

- **Supervision**: which agents are running, which wait on a decision,
  answering a permission ticket, steering or stopping a turn, by voice
  where typing is poor.
- **Triage and review**: reading a change at a commit, hunk by hunk in the
  editor's order, marking hunks viewed, leaving anchored comments, seeing
  diagnostics and other evidence beside the change, sending a comment back
  to the agent, and a verdict.
- **Small edits**, later and rarely.

Deep review of a large change stays on the laptop. The hand-off between
the two (viewed marks, drafts and comments shared) matters as much as the
phone's screen.

## Where the line falls

In this editor the Lean core, the `editor-text` rope and `editor-layout`
form one synchronous unit. Layout queries (`rows`, `move`, `spot`,
`heights`) are answered in the same call and Lean keeps no copy of layout,
because of Xi's experience ([text-and-display.md](text-and-display.md),
"the scene"). The published scene names text by snapshot handle and its
scroll anchor and selections by marker. Every system surveyed that stays
responsive over a slow link keeps the buffer and layout beside the code
that asks about them, and sends services over the wire: sam's terminal
([Pike](https://9p.io/sys/doc/sam/sam.html)), Zed's remote development
([Zed](https://zed.dev/blog/remote-development)), Lapce's proxy, VS Code's
remote server. The ones that kept typing assistance on the server pay a
round trip per key or are moving away from it (JetBrains' split mode,
[IntelliJ SDK](https://plugins.jetbrains.com/docs/intellij/split-mode-and-remote-development.html.md)).
Xi's author concluded the front-end/core process split "was not a good
idea" ([retrospective](https://raphlinus.github.io/xi/2020/06/27/xi-retrospective.html)).

The rule this gives: **no network inside the edit, layout and render
loop**. The places a cut can fall:

| Cut | Phone runs | Server runs | Verdict |
|---|---|---|---|
| Frames | `editor-render`, wgpu, a window | the whole editor | Works, and reuses the most, but every key waits a round trip with no local echo. Fine on a home network with a keyboard, poor on cellular (loaded latency of 300 to 1000 ms is common, secondary source). Kept as a later option |
| Scene and layout, Lean on the server | layout, replicated ropes | Lean core | **Rejected**: a command would block on the network, or layout would be duplicated on the server, the Xi failure |
| The whole editor | Lean runtime and the Rust library | processes, git, grep, watch, agents | The faithful analogue of Zed, but Lean has no official iOS target. Kept as a research question (spike 6) |
| Semantic UI | a native app per concern | everything | **Recommended** for supervision and review |
| Read-only viewer | the Rust display stack and a small viewer core, no Lean | everything, including the source of truth | **Recommended** for drawing code inside the semantic client |

The last two go together. The client is a native app whose lists,
tickets, notifications and text fields are SwiftUI, and whose code views
are the editor's own display, driven by a viewer core on the phone.
Read-only is what lets layout move to the phone: the questions layout
answers come from the phone's own scrolling, taps and range selection, so
they stay local and synchronous. Text at a commit never changes, so it is
sent once and cached; a file an agent is changing arrives as new snapshots
or edit-log patches applied to a copy the phone never writes, which is
one-way replication, not merging.

## The server: a long-lived host

Everything the phone talks to has to outlive a connection, because iOS
suspends an app and closes its sockets whenever it leaves the foreground.
Today:

- The headless mode runs a script file. It is the window mode's loop with
  a recorder or a CPU-rendered display, and it has no socket. Its host
  takes its pieces as `Collaborators` (`lean/Editor/Headless.lean`), so
  an input source fed from the network, the real clock and a display that
  forwards are pieces it can be handed.
- The editor queue is process-wide, so one editor loop runs per process.
  A server runs one host process per session or per workspace.
- ACP sessions are tied to the client process, and whether agents should
  be children of the editor or of a detached supervisor is open
  ([agent-hosting.md](agent-hosting.md), open questions). A long-lived
  host answers it: the host is the supervisor.
- The agent table persists in the project's store; transcripts do not,
  and resume goes through the agent's own `session/load`. A client that
  reconnects needs the transcript from the host, so the host keeps it.

The `reachable` workspace location is modelled with no adapter
([projects.md](projects.md)); the remote host and that adapter meet when a
laptop drives a workspace on another machine, so work on one pays off for
the other.

## The protocol

A new UI port in the sense of `AGENTS.md`: it grows by data (frame fields,
command variants, event variants, query variants), each adapter forwards
to one call into the core, and the client's components are tested on a
hand-written fake of it.

- **Transport**: a message-stream port, with a WebSocket adapter first
  (every tunnel carries it) and a scripted stream as its fake. A QUIC
  adapter can follow behind the same port. The ACP client already takes
  its stream through an interface in this way
  ([agent-hosting.md](agent-hosting.md), "Remote agents and sandboxes").
- **Vocabularies**, each plain data:
  - the agents `Request`/`Order`/`Event` vocabulary and the agent table
    (`packages/agents-api/AgentsApi/`), which already crosses a boundary
    as text lines and has its protocol rules proved on a model;
  - permission tickets from the cross-agent queue, with the exact command
    or hunk each asks about, and their outcome (granted, refused,
    withdrawn when answered elsewhere);
  - review: change sets by commit, hunks in the review order, viewed
    marks, comments, verdicts, rdm document reviews once the rdm client
    exists;
  - text for the viewer: file bytes at a commit, or snapshots and patches
    of a live buffer, keyed by revision;
  - diagnostics and agent-directed content (below).
- **Resume**: every server event carries a per-session sequence number,
  and the host keeps a bounded log. A client reconnects with the last
  number it saw and gets the gap, or a snapshot when the gap is gone
  (mosh's numbered states, [paper](https://mosh.org/mosh-paper.pdf)).
  ACP's `session/resume` reattaches without replay, so the gap replay is
  ours. Written as a Lean model with a contract check, as the agents
  protocol is.
- **Commands** carry a client-made id and are deduplicated. Flags (viewed,
  resolved) are idempotent and applied optimistically. Comments append.
  An approval names its ticket and is refused once the ticket is stale. A
  small edit, when it comes, is "replace this span at revision R", mapped
  through later edits by the server and refused if the span changed; the
  server's change sets already compose and map positions, so this is
  optimistic concurrency, not OT or a CRDT.
- **Anchors resolve on the server.** The phone never computes where a
  comment now lands. A comment keeps a live marker and a quote with its
  revision, as rdm reviews do.
- **Versions**: the App Store, or TestFlight, decides when the client
  updates, so the server cannot demand an exact match as Zed and VS Code
  do. Each vocabulary is versioned and an unknown variant has a fallback
  the client can show.

## The read-only viewer

`editor-layout`'s input is Rust data that does not depend on Lean. Its
`Scene` (`crates/editor-layout/src/scene.rs`) is Lean's scene "with the
handles … already resolved by the binding": a view's text is a `TextRef`,
its scroll anchor and selections plain values. It already carries what a
review view draws: **blocks** between text rows (an excerpt's header, and
the documented place for hunk controls and comment threads), **gutter
marks** (the version-control gutter), decorations, faces, and the text's
own syntax spans.

The crates the phone would run depend on nothing of Lean's:
`editor-text` (ropey), `editor-layout`, `editor-shape-parley` (Parley,
fontique), `editor-render` and `editor-render-wgpu` (wgpu, swash,
etagere), `editor-raster`, and `editor-syntax-treesitter`, whose grammars
are compiled in.

What is new:

- A **viewer core** crate: builds a `Scene` from what the server sends (a
  file at a commit, a change as excerpts with hunk blocks, diagnostics as
  gutter marks and decorations, comments as blocks, the theme's face
  definitions), keeps the scroll position and a selected range, and
  answers taps through layout's `spot`. Its tests run on the host with
  `cargo`, on layout's fake shaper.
- A **UIKit window variant**. `NativeWindow` in `editor-platform` has
  `AppKit` and X11 variants; a `UiKit { view }` variant lets the wgpu
  renderer make a surface from a view the Swift app owns. Hosting the
  Metal layer from Swift avoids winit on iOS, whose text input is basic
  (the `UITextInput` pull request, winit #4595, is unmerged) and whose
  support for the UIScene lifecycle that the iOS 27 SDK requires was not
  found.
- **Platform gates**: `editor-raster-coretext` and parts of
  `editor-render-wgpu/src/gpu.rs` are gated on `target_os = "macos"`.
  Core Text exists on iOS; until the gates widen, swash is the fallback
  every platform already has.

What it does not have: anything Lean decides. No keymaps, evil, config or
packages run on the phone. Policy reaches it as data: the theme's faces,
the review order, which hunks are viewed.

## Diagnostics in the review

Diagnostics are computed where the code and toolchains are, on the server,
and sent as data: path, revision, range, severity, message, source. They
are anchored like comments, to a file at a commit, so the diagnostics of a
change are fixed once computed and can be cached. Sources:

- checks run in a worktree at the reviewed commit over the process
  service (`cargo clippy --message-format=json`, `lake build`, tests);
- a language server opened on the files at that commit, once the LSP
  client exists;
- the agent's own build and test output from its session record, shown as
  what the agent saw, which can differ from what is true now;
- CI results for the branch.

Running the checks on the change's base and head lets the review show what
the change introduced and what it fixed, which is the useful part for
agent work. This is the "evidence beside the change" goal of
[review-and-navigation.md](review-and-navigation.md). On the phone a
diagnostic is a gutter mark and a decoration in the viewer, a summary per
change, and a "send to agent" action.

## Agent-directed content

Agents should be able to call functions inside the editor, both to act
and to shape how results come back to the reviewer (benchmark results, a
table of what changed, a chart). The calls land in the editor on the
server; what crosses to any client is content in a typed vocabulary,
never code.

- **How agents call in**: the editor exposes tools to each session as an
  MCP server, passed explicitly at `session/new` as
  [agent-hosting.md](agent-hosting.md) already decides for MCP servers.
  A package registers tools, so a benchmarks package adds
  `bench.compare`.
- **Two kinds of tool**: tools the editor computes (`bench.compare` reads
  the benchmark output at two commits and builds the table itself), and a
  `present` tool whose content the agent writes. Every content value
  records which it was and the session step that made it. A number the
  editor computed is evidence; the same number written by the agent is a
  claim to check. This is the provenance rule review already applies to
  edits.
- **The vocabulary**: markdown, a table, a chart spec, a code block, a
  diff, an image, a metric with its baseline, and links to a hunk, a file
  or a plan item. Each value carries several representations down to
  plain text, and a client draws the richest it knows, as Jupyter's MIME
  bundles do, so an old client never breaks on new content.
- **Interaction as commands**: a button in content ("rerun on main",
  "open hunk") carries a command that goes back to the host. The client
  runs no agent code.
- **Anchored and kept**: content belongs to a session step, a commit or a
  hunk, and appears in the review timeline. The desktop draws it through
  the scene (blocks, views of their own); the phone draws it natively or
  in the viewer.

HTML in a sandboxed web view, as MCP's Apps extension does, would be easy
on the phone and impossible on the desktop, which has no web engine, and
it would put agent-written code on the reviewer's device. It stays out
unless a need appears that the vocabulary cannot meet.

## Transport and security

Anyone who can speak the protocol can run code on the server, so it gets
SSH's care.

- **No public listener.** First the host binds only to a tailnet address
  (Tailscale's app gives WireGuard with no code of ours). iroh, a QUIC
  library addressed by public key with relays that cannot read traffic
  and Swift bindings, is the embedded alternative
  ([iroh](https://iroh.computer/blog/v1)).
- **Pairing**: the host shows a QR code with its public key and a
  one-time secret, the phone makes a key in the Secure Enclave, and every
  later connection authenticates both ends inside the application
  protocol, so it survives any tunnel. Sequence numbers bind messages
  against replay. A biometric step before approving or running, and a
  per-device audit log beside the ACP audit log.
- **Push**: the owner's own app holds its APNs key, so the host can push
  directly. A Notification Service Extension decrypts an end-to-end
  encrypted payload before display. Pending decisions push; progress
  stays silent, in a Live Activity.

## iOS facts that shape this

- Apps cannot fork or exec. Everything that spawns a process stays on the
  server: git, grep, `mise`, agents, language servers.
- A suspended app's sockets close, and background URL sessions do not
  carry WebSockets. Every backgrounding is a disconnect; the client
  resumes on foreground.
- App Review guideline 2.5.2 forbids downloading code that changes
  features. A client that exchanges only data does not touch it, and for
  a single owner TestFlight or development signing makes review moot.
- Text input in a custom view needs `UITextInput` and `UITextInteraction`.
  Comments and prompts use native text fields, which also bring dictation;
  the viewer, being read-only, needs neither.
- Lean on iOS: two third-party 2026 projects link the runtime
  (paulcadman/lean-ios, LeanNative, the latter self-described as
  experimental). Lean's interpreter needs no JIT, but finds native code
  through `dlsym`, so a static iOS build that elaborates config at run
  time must keep every boxed `@[extern]` symbol exported. Nobody has run
  this editor on a device.

## Touch-first review

The pattern mobile review has settled on: unified diffs only, a wrap
toggle, a file at a time, long-press to select a range for a comment, an
inbox, and one-tap verdicts. Linear's mobile diffs add narrated sections
reviewed one at a time and viewed marks shared with the desktop. The one
small controlled study found phone reviewers found as many valuable
issues but lost the big picture, so the client shows intent, sections and
files touched first. Complaints about phone clients for agents are about
state: stop that does not stop, idle sessions shown working, a ticket
answered elsewhere still shown. Acknowledged state from the host's
vocabularies is the fix.

## Recommended spikes

Spikes answer questions; their code is thrown away or rewritten
test-first. Each says what it settles. Spikes 1 and 3 are independent and
cheap and come first; 2, 4 and 5 follow; 6 and 7 wait until the client has
been used.

### 1. The display stack builds for iOS

Settles: whether the read-only viewer is a port of what exists or a
rewrite.

- Add the `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets and
  build `editor-text`, `editor-layout`, `editor-shape-parley`,
  `editor-raster`, `editor-render`, `editor-render-wgpu` and
  `editor-syntax-treesitter` for them.
- List what breaks: `cfg(target_os = "macos")` gates, build scripts that
  compile C (tree-sitter and its grammars), fontique's system font
  lookup.
- Measure the size the compiled grammars add (the Lean grammar's
  `parser.c` is 49 MB of source).

### 2. A read-only viewer on the simulator

Settles: whether the editor's display can be embedded in a native app and
driven by touch, and what it costs.

- A viewer core that builds a `Scene` from one file at a commit plus a
  change's hunks as blocks, with scroll and tap-to-position, tested on the
  host on the fake shaper.
- A `UiKit` variant of `NativeWindow` and a minimal Swift app hosting the
  Metal layer, embedded in a SwiftUI screen beside native controls.
- Measure frame time while scrolling, memory, and launch time; check
  fonts and highlighting match the desktop.

### 3. The headless mode as a long-lived host

Settles: the shape of the server, and the detached-supervisor question.

- A host that takes input from a message-stream port instead of a script
  and keeps running with no client attached, with the real clock.
- A WebSocket adapter and a scripted fake of the port.
- The resume protocol (sequence numbers, bounded log, snapshot on a
  trimmed gap, deduplicated commands) as a Lean model with a contract
  check.
- A command-line client on the desktop that attaches, lists agents, reads
  events, detaches and resumes without losing any.

### 4. Supervision end to end

Settles: whether the agents vocabulary is enough for a phone client, and
whether push works from a self-hosted host.

- A SwiftUI client developed on a hand-written fake of the protocol,
  then pointed at spike 3's host over a tailnet.
- The agent list with attention states, a permission ticket approved from
  the phone, a stop whose effect is acknowledged, a ticket answered on
  the desktop shown withdrawn.
- QR pairing, and an APNs push from the host decrypted by a Notification
  Service Extension.

### 5. Editor tools for agents and a content vocabulary

Settles: the shape of agent-directed content, and whether one vocabulary
serves the desktop scene and the phone.

- The editor serves an MCP server to an ACP session; one computed tool
  (`bench.compare` over saved benchmark output) and `present`.
- The content type with representations and fallbacks, and its
  provenance (computed or asserted, and the session step).
- Drawn on the desktop through scene blocks, and on the phone natively.

### 6. Lean on an iOS device (later, research)

Settles: whether the whole editor can run on the phone, the only cut that
allows editing with no network wait.

- Build the Lean runtime with one of the third-party ports and run a
  minimal Lean program, then the headless host's core, on a device.
- Check what `dlsym` finds in a static build, the bundle size, and start-up
  time.

### 7. Frame streaming over a tailnet (later, optional)

Settles: whether the full editor on an iPad at home is worth it as a
cheaper route than spike 6.

- Serialise the frame `editor-layout` produces (glyph ids and font bytes,
  with the row hash as the delta key) and draw it on the simulator.
- Feed input back through `editor_ffi_window_post_input`, which posts to
  the editor queue as a window would.
- Measure key-to-pixel time on a home network and on cellular.

## Prior art

| System | Split | What it shows |
|---|---|---|
| sam (`-r`) | text cache and typing in the terminal, files on the host | A model-level protocol made a 9600 bps link usable ([paper](https://9p.io/sys/doc/sam/sam.html)) |
| Zed remote development | buffers, parsing, layout local; language servers, tasks, terminals, git remote | Buffer replication keeps the UI local ([blog](https://zed.dev/blog/remote-development)) |
| VS Code Remote | UI and UI extensions local, workspace extensions on a server | Exact version match between client and server |
| JetBrains split mode | backend analysis, thin client | Backend-only typing assistance "is subject to latency issues" ([SDK](https://plugins.jetbrains.com/docs/intellij/split-mode-and-remote-development.html.md)) |
| Neovim remote UI | cell grid over msgpack-RPC, all state on the server | The grid grew semantic extensions ([docs](https://neovim.io/doc/user/api-ui-events/)) |
| xi-editor | core and front end in separate processes | The split "was not a good idea" ([retrospective](https://raphlinus.github.io/xi/2020/06/27/xi-retrospective.html)) |
| mosh | server-authoritative state, predictive echo, numbered states | Resume and roaming as a protocol property ([paper](https://mosh.org/mosh-paper.pdf)) |
| Happy, Agmente, Codex mobile, Claude Code Remote Control | phone clients for agents | The surface is common; state and authority are where they fail |
| Linear mobile diffs, GitHub Mobile | phone code review | Unified diffs, wrap toggle, sections, synced viewed marks |
| Jupyter MIME bundles | outputs with several representations | Clients draw the richest they understand |

## Open questions

- One host per workspace or per session, and who starts it: a login
  service on the owner's machine, or the desktop editor handing its
  agents over when it quits.
- Whether the desktop editor is itself a client of the host, so phone and
  desktop see one state, or the host is a separate process beside it.
- How often an agent and the reviewer edit the same region; it decides
  whether span replacement with a precondition is enough or live merging
  is ever needed.
- The content vocabulary's first set, and whether a chart spec is an
  existing format or our own.
- Whether the viewer core should share code with the Lean side's view
  logic, or stay a small independent consumer of the scene.
