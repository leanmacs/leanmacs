# Agents

How the editor dispatches coding agents and interacts with them. Reviewing
what they produce is in
[review-and-navigation.md](review-and-navigation.md).

This draws on a research pass over existing tools and on the `edmacs`
record of building agent tooling in Emacs. Protocol details below came from
fetched documentation that was machine-summarised, so field names must be
re-checked against the ACP schema before implementation.

## Two front ends, one agent table

`edmacs` settled on keeping both a terminal and a protocol front end, and
the research agrees neither is enough alone.

| | Protocol (ACP) | Terminal |
|---|---|---|
| What it is | Structured messages between editor and agent | The agent's own terminal UI in a grid view |
| Strengths | Tool calls and diffs as data; permission requests as requests; sessions can be listed and resumed; the editor can build review UI on it | Every agent feature the day it ships; the agent's own hooks and config run; works for any agent |
| Weaknesses | Lags the agent's own UI; adapter-dependent; the agent's shell hooks do not run under the Claude adapter | State must be inferred from hooks and terminal escape sequences; no structured diffs |

Both write to the same agent table, so the agents list, attention order and
notifications do not care which front end a session uses.

## ACP

The editor is an ACP client. ACP is JSON-RPC, normally over the stdio of an
agent subprocess. The agent streams session updates (message chunks, plans,
tool calls with diffs and locations, usage) and calls back into the editor
for permission, for file reads and writes, and to run commands.

**The ACP client (a compiled Lean package over the process service):**
- Spawning the agent process through the Rust process service, which
  frames its output; JSON-RPC on top. As built, the service frames a
  streaming child's output by line, delivers it to the job that started
  the child a read at a time, one completion a read however fast the agent
  writes, holds the agent at a bound by not reading, and takes a write to
  its standard input as a request (`Process.start`, `Process.read`,
  `Process.writeLine`, `lean/Editor/Process.lean`). A JSON-RPC message is a
  line; the client parses the lines in Lean.
- Serving the agent's requests while the editor's own prompt request is
  pending.
- Tracking outstanding requests, and answering every pending permission
  request "cancelled" when a turn is cancelled. This is a protocol rule, so
  it lives in the client, where config cannot get it wrong.
- Serving file reads from unsaved buffer text, and routing file writes
  through the edit log with the agent session and tool call as origin.
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
| No worktrees, checkpoints or provenance | Version control in Lean; per-edit origin in the edit log |

Diffs arrive as whole old and new text, so the editor computes hunks itself
and reconciles them with the buffer, since the agent may already have
written the file.

### Remote agents and sandboxes

Checked on 2026-11-11 from the ACP documentation and web search. The
status of the transport proposal and of the hosted products rests on weak
or missing sources, as marked.

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
remote and branch), and the plan item being worked on if there is one.

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
  every orchestration tool uses. Worktree lifecycle is Lean, over git.
  Worktrees isolate files, not privileges: they are not a security boundary.
- **Workspace identity is one stored root.** `edmacs` rebuilt its workspace
  shell three times because project identity was stored in several places
  that had to agree. Here a workspace has one canonical root, set at
  creation; everything else is derived from it.

## Attention

Practitioners report a ceiling of roughly three to six concurrent agents,
set by review attention. One small controlled study found that a
multi-agent dashboard raised awareness and throughput but not confidence in
the output (read through a secondary summary only). So the agents list and
notifications are necessary and cheap, and they are not where the value is.

- The agents list orders by attention.
- A notification fires when an agent starts waiting or finishes, by rules
  in Lean.
- A jump command goes to the agent that has waited longest.

## Dispatch through rdm

rdm does not run agents; its dispatch is a set of skills an agent session
executes. "Run this phase" is therefore: start an agent session in the right
worktree with a prompt that invokes the skill, and record the plan item in
the agent table. See review-and-navigation.md for the rdm client.

## An agent's write under an open buffer

An agent that goes through ACP writes to the buffer through the edit log
("ACP", above), so it never races the editor. An agent that writes the file
directly does, and so does any other program. What happens then (decided by
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
  (`lean/Editor/Files.lean`, "Reload"), so `u` brings the buffer's own text
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
(`lean/Editor/Loop.lean`, "Auto-reload"). `ModelTest.autoReloadChecks`
pins that with the mode off no watch is open; the phase is
`phase/daily-driver-floor/phase-5-follow-files-on-disk`.

## Open questions

- **JSON throughput** of the ACP client in Lean under a fast-streaming
  agent. If it is too slow, parsing moves into the Rust library (where the
  ACP Rust SDK, licence and fit unchecked, becomes an option).
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
