# Agents

How the editor dispatches coding agents and interacts with them. Reviewing
what they produce is in
[review-and-navigation.md](review-and-navigation.md).

This draws on a research pass over existing tools and on the `edmacs`
record of building agent tooling in Emacs. Protocol details first came from
fetched documentation that was machine-summarised; the ACP spike of
2026-11-23 ("The ACP spike", below) checked them against the Rust SDK's
source and against what Claude Code's adapter actually sent, and where they
differ the spike's are the ones to build on.

## Two front ends, one agent table

`edmacs` settled on keeping both a terminal and a protocol front end, and
the research agrees neither is enough alone.

| | Protocol (ACP) | Terminal |
|---|---|---|
| What it is | Structured messages between editor and agent | The agent's own terminal UI in a grid view |
| Strengths | Tool calls and diffs as data; permission requests as requests; sessions can be listed and resumed; the editor can build review UI on it | Every agent feature the day it ships; the agent's own hooks and config run; works for any agent |
| Weaknesses | Lags the agent's own UI; adapter-dependent; the agent's shell hooks do not run under the Claude adapter | State must be inferred from hooks and terminal escape sequences; no structured diffs |

Both write to the same agent table, so the agents list, attention order and
notifications do not care which front end a session uses. Notifications
and a global jump belong to rdm:task/global-attention-system, which agents
and compile both feed; the agent table keeps attention as data for it.

## ACP

The editor is an ACP client. ACP is JSON-RPC, normally over the stdio of an
agent subprocess. The agent streams session updates (message chunks, plans,
tool calls with diffs and locations, usage) and calls back into the editor
for permission, for file reads and writes, and to run commands.

**The ACP client (the package `acp`, its Rust crate and an interface
package `agents-api`; decided by the owner, 2026-11-23):**
- Spawning the agent process through the Rust process service, which
  owns it (environment, group kill, reaping, shutdown). A Lean job opens
  it as a streaming child (`Process.start`, `lean/Editor/Process.lean`),
  framed by line, and hands it to the package's crate, which takes its
  streams over and runs the protocol's Rust SDK on them, Rust to Rust
  (transport design "C"; the primitive is a proposal,
  [rust-library.md](rust-library.md), "Handing a streaming child to a
  package's crate"). Lean gets plain events from the crate (a message
  chunk, a tool call, a permission request), never JSON-RPC
  ([packages.md](packages.md), "Behind a port, so it stays replaceable").
- Serving the agent's requests while the editor's own prompt request is
  pending.
- Tracking outstanding requests, and answering every pending permission
  request "cancelled" when a turn is cancelled. This is a protocol rule, so
  it lives in the client, where config cannot get it wrong.
- Not built by rdm:roadmap/acp-agents: serving file reads from unsaved
  buffer text and routing file writes through the edit log. Claude Code's
  adapter never uses `fs/*` ("The ACP spike"), so both are later work, and
  per-edit provenance is to come from the tool calls' diffs, also later.
- Batching updates per frame before they reach the editor thread.

**Policy, overridable from config:**
- Which agents exist and how they are launched (command, arguments,
  environment, MCP servers).
- The conversation view: how messages, thoughts, plans and tool calls are
  shown and folded.
- Permission policy and presentation.
- Everything in the agent table.

### What ACP does not cover

| Gap | How it is filled |
|---|---|
| No interactive terminal (its terminal methods run commands; no input or resize were found in the documented set) | The terminal front end |
| Features lag the agent's own UI | Use the terminal for what the adapter lacks; advertise only what the agent reports |
| The agent's shell hooks do not run; MCP config is not auto-discovered | Status from session updates for ACP sessions; a local typed listener for hook callbacks from terminal sessions; pass MCP servers explicitly |
| Work that outlives a turn is invisible | The activity axis below has an explicit "unknown"; a stall timeout |
| Sessions are tied to the client process; no standard remote transport | Persist agent records and reattach with session resume; a detached supervisor process is a later option. For remote agents see below |
| No worktrees, checkpoints or provenance | Version control in Lean; per-edit origin from the tool call's diff, in later work (not rdm:roadmap/acp-agents) |

Diffs arrive as old and new text, not as hunks, so the editor computes
hunks itself and reconciles them with the buffer, since the agent may
already have written the file. Under Claude Code's adapter the text is
whole only in the update after the tool ran; before it, and in the
permission request, it is only the edit's own strings ("The ACP spike",
below).

### The ACP spike (2026-11-23)

A time-boxed spike checked the SDK, the stream hand-off and what Claude
Code's adapter sends. Its code and the scrubbed transcripts are on the
spike's branch under `spike/` (not landed); the transcripts are to seed
the client's fixture tests. Each fact says how it is known.

**The SDK** (read in the source of 5.5.1 and on crates.io; the stream point
proved by running code):

| | |
|---|---|
| Crates | `agent-client-protocol` 5.5.1 (2026-11-21), the connection, from github.com/agentclientprotocol/rust-sdk; it pins the wire types, `agent-client-protocol-schema`, exactly (`=1.21.2`) and re-exports them as `agent_client_protocol::v1::schema`, which is how they are to be named. Its `-derive` crate comes with it; `-rmcp`, `-conductor`, `-http` and others are separate and not needed |
| Licence | Apache-2.0 for the three crates it pulls in; the rest of its normal tree is MIT, Apache-2.0, Zlib, Unlicense OR MIT and Unicode-3.0. All are compatible with the editor's GPL-3.0-or-later. `deny.toml` checks bans only, no licences, so nothing in the gate would catch a change |
| Edition, MSRV | 2024, `rust-version = 1.88.0` |
| Runtime | None. No default features; tokio is a dev-dependency only. The connection is one future the caller polls (`futures::executor::block_on` on a plain thread in the spike); its tasks run inside that future. Everything is `Send`; no `spawn_local`, no `LocalSet` |
| Streams it did not open | Yes. `connect_with` takes any transport: `ByteStreams` over futures-io `AsyncRead`/`AsyncWrite`, `Lines` over a `Sink<String>` and a `Stream` of lines, or a channel of frames. The spike fed `Lines` from a plain thread doing blocking reads, as a consumer pulling a handed-over child would, and wrote through another plain thread |
| Incoming requests | Typed handlers registered on the builder (`on_receive_request` for `RequestPermissionRequest`, `ReadTextFileRequest`, `WriteTextFileRequest`, `CreateTerminalRequest` and the rest; `on_receive_notification` for `SessionNotification`). **A handler holds the dispatch loop until it returns**, so it must not await Lean's answer: it parks the request's `Responder` (`Send + 'static`, answered synchronously) under a ticket, posts a plain event and returns; the answer comes later from any thread. The spike answered a permission request so, from another thread, while the prompt was pending, then cancelled the turn and saw `stopReason: "cancelled"`. A dropped `Responder` answers with an error |
| Defaults to note | Request ids on the wire are UUID strings. The client's capabilities default to no fs and no terminal; they must be set to be offered |
| Protocol | Version 1. Version 2 is a draft behind `unstable_protocol_v2`; about thirteen more `unstable_*` flags exist |
| API churn | High. 0.8 to 0.15 broke between December 2025 and June 2026 (0.11 a new design); then 1.0.0 (2026-06-24), 2.0.0 (07-23), 3.0.0 (10-06) and 5.0.0 (11-02), with no 4. Minors come every few days. Semver is promised for the stable API from now on; the `unstable_*` API and the schema pin may move in a minor |

So the SDK fits design C: no runtime to host, any stream, and every
callback can become a parked request and a plain event. The cost is the
churn: pin it exactly in the root lock, keep its types inside the crate
behind the `agents-api` port, and expect a major upgrade every few months.

**Claude Code's adapter** (observed: two short runs on this machine, one
prompt each, from a fresh temporary directory, through a minimal client
script; the rest read in the installed package's source):

- **Package**: `@agentclientprotocol/claude-agent-acp` 0.110.0
  (Apache-2.0, github.com/agentclientprotocol/claude-agent-acp); the old
  `@zed-industries/claude-code-acp` and `@zed-industries/claude-agent-acp`
  are deprecated renames. It is the binary `claude-agent-acp` (`node
  dist/index.js`, no arguments), newline-delimited JSON-RPC on standard
  input and output, logs on standard error. It wraps
  `@anthropic-ai/claude-agent-sdk` 0.3.330 and starts that SDK's own
  bundled CLI, not the `claude` on the `PATH`. It reuses the local Claude
  Code login with no setup. `CLAUDE_AGENT_ACP_PROTOCOL`, `CLAUDE_CONFIG_DIR`
  and `CLAUDE_CODE_EXECUTABLE` among others change it.
- **`initialize`**: `protocolVersion: 1`; `agentCapabilities` with
  `loadSession`, `promptCapabilities` (`image`, `embeddedContext`),
  `mcpCapabilities` (`http`, `sse`, `acp`), `sessionCapabilities`
  (`list`, `resume`, `fork`, `close`, `delete`, `title` and more), and
  `_meta`; `agentInfo`; `authMethods: []` for a client that offers no
  terminal auth.
- **`session/new`** answers `sessionId` (a UUID), `modes` (`default`,
  `acceptEdits`, `plan`, `auto`, `bypassPermissions`) and `configOptions`
  (selects: `model`, `effort`, `fast`, `mode`, `agent` and others); no
  top-level `models`. **The session's mode is the user's own Claude
  settings'** (`auto` here), so a session may never ask permission at all;
  `session/set_mode` with `default` was accepted and made it ask.
- **Messages seen.** Client to agent: `initialize`, `session/new`,
  `session/set_mode`, `session/prompt`, and the permission answer. Agent
  to client: the responses, `session/update`, one
  `session/request_permission`, and two notifications outside the
  protocol, `auth/status_update` and `_auth/status_update`, three each a
  run, carrying the account's email, plan and organisation (scrubbed). The
  `sessionUpdate` kinds: `agent_message_chunk` (`content: {type: "text",
  text}`, `messageId`), `tool_call`, `tool_call_update`, `usage_update`
  (`used`, `size`, `cost: {amount, currency}`), `available_commands_update`,
  `session_info_update` (`title`, `updatedAt`) and `config_option_update`.
  No `plan`, `agent_thought_chunk` or `current_mode_update` in these runs.
- **Tool calls** open empty (`tool_call` with `toolCallId`, `title`,
  `kind` `read` or `edit`, `status: "pending"`, `rawInput: {}`, empty
  `content` and `locations`) and are filled in by **incremental**
  `tool_call_update`s that send only the fields that changed: `rawInput`
  in growing versions, then `title` and `locations` (`[{path, line?}]`),
  then the result, `status: "completed"` with `rawOutput` and `content`.
  Much rides in `_meta.claudeCode` (the CLI's tool name, and its tool
  response: for an edit the whole original file and a structured patch).
  The client must merge updates into a tool call, and replace a diff, never
  append to it.
- **The permission request** (observed once): `{sessionId, toolCall:
  {toolCallId, title: "Edit notes.txt", kind: "edit", status, rawInput,
  content: [{type: "diff", path, oldText, newText}], locations: [{path}],
  name}, options}`, with options `allow-once` ("Yes", `allow_once`),
  `allow-with-updates` ("Yes, allow all edits during this session",
  `allow_always`) and `reject` ("No", `reject_once`). `name` is outside the
  schema. The diff in it is the edit's own strings, not the file. The
  adapter's source builds the options per tool and input, and can also
  offer `allow-skill-*` and `exit-plan-*` ids; it never offers
  `reject_always`; a cancel answers pending requests as denied. So
  "the options are the agent's, per request" holds.
- **Diffs**: `content: [{type: "diff", path, oldText, newText}]`. Before
  the tool runs (an update with partial input, and the permission request)
  the texts are only the replaced and replacing strings; after it, the
  whole file before and after, its last line feed trimmed.
- **Files**: the client offered `fs/readTextFile` and `fs/writeTextFile`,
  and **the agent used neither**: the CLI read and edited the file itself
  in both runs, after permission in the second. Serving reads from buffers
  and routing writes through the edit log (planned for acp-agents before the spike, now later work) cannot
  rest on the fs methods with this agent; edits are external changes,
  attributed from the tool call's diff.
- **Sizes and rate**: 36 messages, 70,624 bytes in 7.3 s for the first
  run; 43 in 8.3 s for the second. The largest message was an
  `available_commands_update`, 27,490 bytes (the user's skills and
  commands); `session/new`'s answer about 5 kB; a whole-file edit update
  1.1 kB for a three-line file. The peak, agent to client, was 12 messages
  in a second and 7 in 100 ms. Both replies were one sentence, so this
  says nothing yet about a long streamed reply.
- **The user's environment leaks in**: mode, model, skills, commands and
  subagents all come from the user's Claude settings, unless the client
  passes its own (`CLAUDE_CONFIG_DIR`, `session/set_mode`,
  `session/set_config_option`). The owner decided on 2026-11-23 that the
  editor uses the host's Claude settings as they are: it sets no session
  mode (no `session/set_mode`) and passes no Claude config of its own (no
  `CLAUDE_CONFIG_DIR`, no `session/set_config_option`). A session whose
  settings resolve permissions itself may never ask; the queue tolerates
  that ("Permissions").

### Remote agents and sandboxes

Checked on 2026-11-11 from the ACP documentation and web search. The
status of the transport proposal and of the hosted products rests on weak
or missing sources, as marked. Remote transports are outside
rdm:roadmap/acp-agents: later work.

ACP's only stable transport is stdio. An agent running somewhere else
reaches the editor in one of three ways:

| Route | Status | For the editor |
|---|---|---|
| A tunnelled stdio: the agent launched through `ssh`, `docker exec`, `kubectl exec` or a sandbox provider's command | Works now | A different launch command to the process service; nothing else changes |
| ACP's remote transport (Streamable HTTP and WebSocket on one endpoint) | A proposal, not in the stable protocol; its stage could not be confirmed. Support in the SDKs is experimental | Not built on. The transport interface below keeps it possible |
| A local command that speaks ACP over stdio and forwards to a vendor's hosted agent | Starting to appear (one report, unconfirmed) | Ordinary stdio ACP. The likeliest way hosted agents arrive |

No hosted agent product was found to expose its cloud agents over ACP.
Several were not checked at all, so this is an absence of evidence.

Three rules follow:

- **The ACP client takes its message stream through an interface**, with
  the process service's stdio as the first implementation. A remote
  transport is then another implementation, and the model for tests is a
  scripted stream.
- **A session records where its workspace is**: a local worktree, or a
  remote one named by the git remote and branch its work comes back on.
  File reads, file writes and commands are capabilities the client offers
  only for a local workspace; a remote agent does that work itself.
- **A remote session is reviewed from its fetched branch** together with
  the session's record of tool calls and diffs. The edit log cannot
  attribute edits it never saw, so provenance for a remote session is per
  tool call from that record, not per edit.

A tunnelled session dies with its connection unless something on the far
side keeps the agent alive; session resume then reattaches to it. That is
the detached supervisor question below, on another machine.

## The agent table

A table held in compiled Lean state, persisted to disk, and updated by a
pure reducer over agent events (see [lean-runtime.md](lean-runtime.md)). Its shape comes from what
went wrong in `edmacs`.

**Identity is three separate things.** In `edmacs` one user-typed name was
the registry key, the hook routing key, the display label and part of the
buffer name, so it could not change.

| Field | Who sets it | Changes? |
|---|---|---|
| Agent id | The editor mints it | Never |
| Provider session id | The agent | Yes (for Claude Code, on `/clear`) |
| Display name | Derived from the title the agent writes | Freely |

**State is two axes.** One status field conflated two questions.

| Axis | Question | Values |
|---|---|---|
| Attention | Does this agent want me? | Waiting for input, finished and unread, working, idle |
| Activity | Does it still have work in flight? | A set of work items, or "unknown" |

Activity never feeds attention. An agent can be idle in the conversation
while a background task runs, and the list should say so.

**Ingress is typed.** Every update is an event with a mandatory agent id,
whether it came from ACP, from a hook callback on the local listener, or
from a terminal escape sequence. `edmacs` took updates through shell
interpolation into an eval channel, which produced an injection bug and
dropped updates when two sessions shared a directory.

**Other fields:** the source (which front end), the workspace root (one
canonical path, set once), where the workspace is (a local worktree, or a
remote and branch), and the plan item being worked on if there is one (set once dispatch is
built, in the roadmap after rdm:roadmap/acp-agents).

## Permissions

The sources pull in two directions. Tools that host many agents suffer from
permission fatigue and want an editor-side policy. The `edmacs` post-mortem
warns that an editor-side gate once denied every edit by default, and that
the set of options is chosen by the agent per request, so a fixed set of
keys is wrong by construction.

The design that satisfies both:

- The **ACP client** holds outstanding requests (it must, to speak the
  protocol), cancels them correctly, and appends every request and answer
  to an audit log.
- **Policy** is a function from the request to either one of the
  options the agent offered or "ask the user". Its return type makes
  inventing an answer impossible, and that property can be stated as a
  theorem on the model.
- The **default** is to ask.
- Pending requests across all agents are one queue the user can work
  through, not a prompt per window.
- Some agent modes resolve permissions themselves and never ask; the queue
  tolerates silence.

A pending request is compiled Lean state, so a config reload while a
request is waiting loses nothing.

## Sessions and workspaces

- **Sessions do not die with a window.** Agent records persist
  independently of window layout. After a restart, sessions are listed and
  resumed lazily on first visit, using the agent's own session store rather
  than a copy of its transcript. "Restore agents" and "restore window
  layout" are separate features.
- **One worktree, one branch, one agent per task** is the pattern nearly
  every orchestration tool uses. Worktree lifecycle is Lean, over git:
  the version-control interface's `addWorktree` and `removeWorktree`
  ([version-control.md](version-control.md)).
  Worktrees isolate files, not privileges: they are not a security boundary.
- **Workspace identity is one stored root.** `edmacs` rebuilt its workspace
  shell three times because project identity was stored in several places
  that had to agree. Here a workspace has one canonical root, set at
  creation; everything else is derived from it.
- **A session's workspace is a workspace of the editor's**
  ([projects.md](projects.md)): its location is `local` for a worktree on
  this machine, or `branchOnly`, the git remote and the branch, for a
  remote session. A remote session registers its workspace with
  `Workspace.register` (`StateRequest.registerWorkspace`), which puts it in
  the project of its remote, beside the local checkouts of the same
  repository; a location that is not local reports that it cannot read
  files or run commands.

## Attention

Practitioners report a ceiling of roughly three to six concurrent agents,
set by review attention. One small controlled study found that a
multi-agent dashboard raised awareness and throughput but not confidence in
the output (read through a secondary summary only). So the agents list and
notifications are necessary and cheap, and they are not where the value is.

- The agents list orders by attention (rdm:roadmap/acp-agents builds it,
  phase 7).
- A notification fires when an agent starts waiting or finishes, by rules
  in Lean. This is rdm:task/global-attention-system's, not
  rdm:roadmap/acp-agents'; the agent table keeps attention as data for it
  to read.
- A jump command goes to the agent that has waited longest; also
  rdm:task/global-attention-system's.

## Dispatch through rdm

rdm does not run agents; its dispatch is a set of skills an agent session
executes. "Run this phase" is therefore: start an agent session in the right
worktree with a prompt that invokes the skill, and record the plan item in
the agent table. See review-and-navigation.md for the rdm client.

Status: not built by rdm:roadmap/acp-agents. Dispatching rdm phases and
tasks from the editor is the roadmap after rdm:roadmap/acp-agents.

## An agent's write under an open buffer

An agent that writes through ACP's `fs/write_text_file` writes to the
buffer through the edit log ("ACP", above), so it never races the editor.
An agent that writes the file directly does, and so does any other
program; Claude Code's adapter is one, since it edits files itself even
when the client offers the fs methods ("The ACP spike", above). What happens then (decided by
the daily-driver floor's phase 5):

- **Keep mine, and offer two explicit resolutions.** A buffer with unsaved
  edits is never touched by a change on disk. The staleness check, one stat
  as the window gains the focus, as the buffer is switched to and at its
  first edit, marks it `[changed on disk]` in its status line and says the
  two resolutions; a buffer with no unsaved edits has its first edit
  refused once, naming `:e` (`lean/Editor/Loop.lean`, "Files that changed
  on disk"). A plain save of it is refused, since the file is not the one
  the buffer loaded (`lean/Editor/File.lean`, "A save says what it expects
  to find").
- **`:e!` takes theirs**: the file's text comes in as one edit, of origin
  `disk`, made from a line diff of the buffer and the file
  (`packages/files/Files.lean`, "Reload"), so `u` brings the buffer's own text
  back. Taking theirs loses nothing.
- **`:w!` writes mine over theirs**: the forced save, which expects
  whatever is on disk.
- **`:e`** on a buffer with no unsaved edits takes the file's text the same
  way; with unsaved edits it is refused and says that `:e!` discards them.
- **A diff of the two**, reviewed hunk by hunk, is the third resolution. It
  waits for the Diff service's review UI (`rust-library.md`,
  `review-and-navigation.md`) and is not built.

Why: neither side is ever lost in silence (the file is untouched until
`:w!`, and the buffer's text stays reachable by undo after `:e!`), and the
choice stays with the person, which keeps the owner's rule that reloading
is an explicit action.

**The invariant**: the editor watches no file unless auto-reload is on,
and it is off by default; the reload is explicit; a config's job may
watch, as a plugin would (`FileWatch.start` is a job request config can
use). With auto-reload on (`autoread`, or `autoReload` in `setup`), a
follow job watches each file buffer's file and a change reloads a buffer
with no unsaved edits, as Emacs's auto-revert does; a buffer with unsaved
edits is only marked, and a file that is gone is marked and never reloaded
(`lean/Editor/Loop.lean`, "Auto-reload"). `FilesTest.autoReloadChecks`
pins that with the mode off no watch is open; the phase is
`phase/daily-driver-floor/phase-5-follow-files-on-disk`.

## Open questions

- **JSON throughput**: answered by moving it. The ACP package's crate
  parses with the Rust SDK and Lean gets plain events; the SDK's licence
  and fit were checked ("The ACP spike"). Still open: Lean's cost per
  event under a long streamed reply, which the spike's one-sentence
  replies (12 messages a second at most) did not reach.
- **How edits are attributed** when the agent writes files itself, as
  Claude Code's adapter does: from the tool call's final diff and its
  `_meta` patch, reconciled with the buffer as an external change. Whether
  the adapter can be made to use `fs/write_text_file` is unchecked.
- **The line bound** for an agent's stream: a line is about three times
  the largest file an edit touches, and a line past the bound ends the
  agent ([rust-library.md](rust-library.md), "Handing a streaming child to
  a package's crate").
- **The user's Claude settings**: decided 2026-11-23, no longer open. The
  editor uses the host's Claude settings as they are, with no session mode
  and no config of its own ("The ACP spike", "The user's environment leaks
  in").
- **Non-standard notifications** (`auth/status_update`,
  `_auth/status_update`) carry account details; the client should ignore
  them and never log them unscrubbed.
- **Keeping up with the SDK**: four major versions in five months. Who
  upgrades it, and how the fixture transcripts catch a change of wire
  shape, is open.
- **A detached supervisor**: should agent processes be children of the
  editor, or of a small separate process that outlives it, as VS Code now
  does? Persisted records plus resume may be enough at first.
- **Context sharing**: how the selection, diagnostics and open files are
  offered to an agent.
- **Usage and cost**: where it comes from (ACP usage updates, the agent's
  own logs) and where it is shown.
- **Sandboxing** agents beyond worktrees.
- **Remote sessions**: how the editor learns which branch a remote agent
  pushed, whether the agent's files can be read before it pushes, and what
  keeps a tunnelled agent alive across a dropped connection.
- **Hosted agents** without ACP: whether any is worth a client of its own,
  or the terminal front end and a fetched branch are enough.
