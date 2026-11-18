# Review and navigation

Tooling for reviewing agents' work (plans and code), for understanding a
codebase, and the two integrations those rest on: version control and rdm.
Almost all of it is Lean, on the primitives in
[text-and-display.md](text-and-display.md) and
[rust-library.md](rust-library.md).

The evidence here is uneven. The tool descriptions come from primary
documentation; many of the academic figures were read only as search
summaries or recalled from memory, and are marked "weak" in the research
report. No study was found that tests whether provenance or trajectory
views improve review accuracy. The design rests on plausible transfers, so
the editor should record enough about its own use (which hunks were viewed,
which findings led to a change) to check them.

## What review needs

Review is where a human builds a model of a change. With agents, the author
no longer holds that model either, so review is the only place it happens.
The research suggests review tooling should aim at understanding first and
defect-finding second.

| Need | Mechanism | Built on |
|---|---|---|
| See an agent's whole change in one place | An excerpt buffer of its hunks across files, editable in place | Excerpt buffers, diff |
| Accept or reject per hunk | Block decorations with controls; apply and revert hunk | Decorations, diff |
| Order hunks sensibly | Lean orders and groups them (by plan step, by dependency, tests first); not alphabetically, since position biases attention | Lean policy |
| Know who wrote a line and why | Per-edit origin: from a range of text to the agent session, tool call and transcript step that produced it | The edit log |
| See what changed since last review | A diff between review rounds | Version control |
| Know what was not looked at | Viewed-range tracking; unreviewed regions marked, not assumed clean | Instrumentation |
| See evidence beside the change | Test results, verification output and proof status in a panel linked to the hunks | Processes, tables |
| Comment on a plan or on code | Comment threads as block decorations, anchored to text | Anchors, decorations |
| Compare a plan with what was built | Plan steps linked to the hunks made while each was in progress | Edit log origin, the agent table |

No shipping tool was found that maps a plan step to its hunks, or jumps
from a hunk to the transcript step that wrote it. Both follow from owning
the edit log.

Of the per-edit origin, the first half is built (2026-11-13,
[text-and-display.md](text-and-display.md), "The edit log"): a range of a
text is traced to the log entries that wrote it, and each entry gives back
the origin its transaction was applied with, a number. The second half is
not: the table that says which agent session, tool call and transcript step
a number stands for arrives with the command loop and agent hosting.

### Anchoring comments

Two models exist and the editor needs both.

- **In the editor**, a comment is held by an anchor, which follows every
  edit made in the editor exactly.
- **Across sessions and for agents to read**, a comment is stored as a
  quote with surrounding context against a snapshot, and re-found when the
  text has changed outside the editor: exact position, then offset, then
  fuzzy match. A comment that cannot be placed is shown as drifted, not
  silently moved. This is rdm's model, and the only one an agent can
  consume, since the reader of a plan comment is usually an agent.

### Automated reviewers

AI review tools have converged on finding candidates in parallel,
verifying, de-duplicating and ranking, then posting inline with a severity.
Their findings arrive here as data: a location, a body, a severity, a
stable identity, and a disposition the human records (fixed, dismissed,
won't fix). Stable identity matters because the one detailed account of
reducing reviewer noise did it by suppressing findings similar to ones the
team had dismissed.

### Verification as the thing reviewed

One small study found that judging a few discriminating tests, instead of
reading the code, made people more accurate about AI-written code. Lean
gives this editor an unusual option: properties stated and proved about
commands and config. A constraint from the research: models currently
discharge far fewer Lean specifications than Dafny ones, so the design
should report which stated properties are proved, tested or unverified,
and not assume agents will routinely prove things.

## Version control

Lean, over the process service and the library's diff. The model is magit: every
operation is a git command and its parsed output.

- **Lean owns**: status, staging, commits, branches, worktree lifecycle,
  blame, log, file at a revision, range and round-to-round diffs, and the
  views for all of them.
- **The Rust library supplies**: text diff and hunks; read-only buffers for content
  Lean fetches (a file at a commit); gutter decorations; excerpt buffers.
- **Interface**: the Lean version-control package defines its own small
  interface, so jj or another system is another implementation of it.
- **Gutter marks** need the file's content at HEAD: Lean fetches it once
  per buffer and on ref changes (a watch on the git directory), and the
  library diffs against it as the buffer changes.

If process-per-query is too slow for status in large repositories, an
in-process library can sit behind the same interface.

The interface, its git implementation, the status buffer, a file at a
revision (`vc-show`) and the gutter marks as built are in
[version-control.md](version-control.md).

## rdm

rdm is a git-backed tool for roadmaps, phases, tasks, plans and reviews,
and the workflow agents follow in this project. Its client lives entirely
in Lean.

**Integration route: the CLI with `--format json`.** It is the only
complete surface, its JSON is pinned by golden-file tests, and rdm's own
Emacs package uses nothing else. The REST server omits plans, runs and
worktrees. Linking `rdm-core` is possible (both projects are
GPL-3.0-or-later) and would avoid a process per query, but the library has
no stated stability and its session and config wiring would have to be
redone; it stays open as a later optimisation. The Lean client sits behind
a small interface with a fake built from rdm's golden files, so a linked
adapter could replace it.

**What the client does:**
- Resolves context with `rdm info`; probes capabilities instead of trusting
  the version string (an installed build can lag `main` under the same
  version).
- Uses one rdm session per editor instance, so its staged changes are its
  own.
- Shows roadmaps, phases, tasks and plans as buffers and lists; follows
  `rdm:` links under the cursor.
- Shows and authors document reviews inline: rdm resolves each comment's
  position in the current text, so plan and phase comments need no anchor
  logic in the editor.
- Shows code reviews against the file at the reviewed commit, since rdm
  gives a comment's position there and not in the working file. Inline
  code-review display has no reference implementation in rdm's Emacs
  package and is new work.
- Marks files that plan items and comments point at (`rdm backlinks`).
- Starts work: "run this phase" starts an agent session with the right
  skill, in the right worktree, linked to the plan item.

**What rdm lacks today, and the workaround:**

| Gap | Workaround |
|---|---|
| No change notification on any surface | A file watch on the plan repo; the client re-queries on change. rdm writes atomically, which makes this safe. The watch it needs is built: a recursive directory watch from a job, which an atomic write, a rename over a file, does not lose ([rust-library.md](rust-library.md), "Watching, as built"). |
| Run records have no stage, heartbeat or process id | The agent table knows liveness for sessions the editor started |
| No position for code comments in the working file | Show the file at the reviewed commit |
| Finding severity and confidence are text in the comment body | Parse them, until rdm exposes fields |

These are candidates for changes in rdm itself.

## Navigation and understanding

The comprehension research (older, but the best supported) says developers
spend a large share of their time on navigation mechanics, lose the working
set they collected, and struggle most with reachability questions: what
calls this, what does this reach. Research interfaces that helped showed
callers and callees always, not on demand, and brought code to the reader.

| Feature | What it is | Built on |
|---|---|---|
| Pickers | Fuzzy finders over files, symbols, buffers, anything | Fuzzy matching, tables |
| Jump list | Positions held by anchors, so they survive edits | Anchors |
| Working sets | Named, pinned collections of locations that persist | Persistent tables, anchors |
| References and callers as excerpts | Results shown as code in an excerpt buffer, not a list of file names | Excerpt buffers, code index |
| Neighbour strip | Callers and callees of the function at the cursor, always visible | Code index, block decorations |
| Outline and breadcrumbs | The syntax tree's structure | Syntax queries |
| Tours and maps | An ordered set of locations with notes, written by a person or an agent, validated against the code | Excerpt buffers, anchors, quote re-anchoring |
| History views | Hotspots, churn and blame, with agent-authored changes distinguishable | Version control, edit log origin |

Tours deserve a note: an agent that has just built something can be asked
for a tour of it, and because a tour is anchored data, the editor can show
when the code has moved out from under it.

## Open questions

- **Hunk ordering**: nothing in the research says which order is best, only
  that alphabetical is bad. Start with plan-step order and measure.
- **Provenance storage**: the edit log is in memory. How is per-edit origin
  persisted and tied to commits? Agent Trace and git notes are existing
  formats; neither attributes at edit granularity. As built, the log is
  dropped only when Lean forgets it up to a revision, and nothing does yet;
  text older than what was forgotten is reported as older than the log
  reaches, not attributed to nobody. When review forgets, and what it
  writes down first, is part of this question.
- **Agents that write files directly**: their edits arrive as external
  changes. How reliably can origin be recovered from tool-call reports?
- **Structural diff**: tree-sitter-based diffing and move detection suppress
  noise, with known failure cases. After syntax support lands.
- **Proof and test status in review**: no existing UI to learn from.
- **rdm changes**: whether to add a watch command, run heartbeats and
  working-file comment placement to rdm, or keep the workarounds.
