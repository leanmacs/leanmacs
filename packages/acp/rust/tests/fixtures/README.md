# Replay fixtures

The transcripts `tests/replay.rs` replays through the session, each with
the plain events it must produce.

## Provenance

The `.jsonl` files are written by hand and are synthetic. They reproduce
the message shapes of `@agentclientprotocol/claude-agent-acp` 0.110.0 as
seen in a local recording made on 2026-11-23, which is not in the
repository and never will be (owner decision, 2026-11-26: the repository
is public, and no recorded transcript is committed, verbatim or
scrubbed). The two shapes that recording lacks, a cancel and
`current_mode_update`, and `load.jsonl`'s `session/load` and
`user_message_chunk`, follow schema 1.21.2 under SDK 5.5.1.

Every value is a placeholder written for these files: the session id
`sess-0001`, the working directory `/work/example` and its file
`/work/example/notes.txt`, the tool-call ids `call-read-1` and
`call-edit-1`, the message ids `msg-1` and `msg-u1`, the modes `mode-ask`
and `mode-auto`, one command `example-command`, one configuration option
`example-option`, the auth values `user@example.invalid`, `Example Org` and
`Example Plan`, the title `Example title`, the cost `0.0123` `USD`, and the
prompt, reply and file text.

## The format

One JSON object a line: `{"from": "client" | "agent", "msg": <JSON-RPC
message>}`, with no timestamps or byte counts. A client request's id is a
small integer, which the replay rewrites to the id our client gave it (the
SDK's are UUIDs); the agent's request ids are `0` and `1`, as the adapter
numbers them. A client line is exactly what our client writes, but for a
request's id.

The replay opens the session with the setup the second client line asks
for: a `session/new` opens a new one, and a `session/load` loads the
session it names.

A `.events` file is what the session produced: the `opened` reply's line
and each event's, in the order the session posted them, in the encoding
`src/event.rs` defines and `acp`'s Lean library decodes. A new session's
file starts with `opened`; a load's starts with the history the agent
replays before it answers, then `opened`. The replay ends the agent's
output after the last line as an exit 0, so each file ends with
`ended how=exited code=0`.

## What each file covers

- `plain.jsonl`: `initialize`, the client offering no `fs` and no
  `terminal`, and a result with `_meta`, capability fields outside the
  schema (`auth`, `providers`, `sessionCapabilities`) and `authMethods: []`;
  `session/new` and its result with two modes and a configuration option;
  both auth notifications (twice), the commands list and the configuration
  options, all dropped; a prompt turn with `session_info_update`,
  `usage_update` without and then with `cost`, a `read` tool call that
  starts empty (with `name` and `_meta`), gains its raw input, title and
  location, and completes with text content, a `current_mode_update` the
  agent sends unasked, two chunks of one message, and the response
  `end_turn` with `usage` and `_meta`.
- `permission.jsonl`: an `edit` tool call whose raw input grows over two
  updates; an update adding a diff of the edit's strings;
  `session/request_permission` (id `0`) with the merged call and three
  options; the client's `selected` `allow-once`; an update whose whole-file
  diff and location with a line replace the earlier ones; the completed
  update with `rawOutput`; chunks, usage with cost, and `end_turn`.
- `cancel.jsonl`: a prompt turn with a tool call and
  `session/request_permission` (id `0`) parked; the client's `cancelled`
  answer to it before `session/cancel`; a late `session/request_permission`
  (id `1`) of the same turn, answered `cancelled` at once; and the prompt's
  response `cancelled`.
- `load.jsonl`: `initialize` with `loadSession: true`; `session/load` of
  `sess-0001` in `/work/example`, in place of `session/new`; the history
  the agent replays before it answers, as `session/update` notifications:
  a `user_message_chunk` `Read notes.txt.` (`msg-u1`), an
  `agent_message_chunk` `Done.` (`msg-1`), a completed `edit` tool call
  `call-edit-1` announced whole with its raw input, location and a
  whole-file diff of `/work/example/notes.txt`, and a `session_info_update`
  titled `Example title`; then the load's result with the modes `mode-ask`
  and `mode-auto` and a configuration option. Its `.events` holds the
  history before `opened`, whose `sessionId` is the loaded one.

## Editing one

Edit the `.jsonl` file by hand, with placeholder values only, and run
`cargo test -p acp-service --test replay`. When the produced lines differ,
the test prints them; read them against the fixture, and copy them into the
`.events` file once they are what the session should produce. Treat any
change to a `.events` file on an SDK upgrade as a change of wire shape to
review (`docs/design/agent-hosting.md`, "Upgrading the SDK").
