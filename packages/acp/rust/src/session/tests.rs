//! The session on a `LocalPool` the test steps on its own thread, over a
//! scripted transport whose agent side is the test: every line the client
//! writes is read once the pool has stalled, and every line the agent sends
//! is sent between steps, so each interleaving is forced by the order of
//! the steps, never by timing.

use std::io;
use std::sync::{Arc, Mutex};

use futures::SinkExt;
use futures::channel::mpsc;
use futures::executor::LocalPool;
use futures::task::LocalSpawnExt;
use serde_json::{Value, json};

use super::*;
use crate::event::Call;

/// A session on a pool, and the agent's side of its transport.
struct Rig {
    /// The pool the session runs on.
    pool: LocalPool,
    /// The lines the client wrote, not yet read.
    written: mpsc::UnboundedReceiver<String>,
    /// Where the agent's lines go.
    agent: mpsc::UnboundedSender<io::Result<String>>,
    /// How the child ended, as the pump would record it.
    ending: EndingCell,
    /// What the session posted, not yet read.
    posted: Arc<Mutex<Vec<Output>>>,
    /// The session's link.
    link: Link,
}

/// The setup the tests open with: one MCP server.
fn setup() -> Setup {
    Setup {
        cwd: "/work/example".into(),
        servers: vec![McpServer {
            name: "example-server".into(),
            command: "/usr/local/bin/example".into(),
            arguments: vec!["--flag".into()],
            environment: vec![("KEY".into(), "value".into())],
        }],
    }
}

impl Rig {
    /// A session over a scripted transport, spawned on a fresh pool and not
    /// yet stepped.
    fn new() -> Self {
        let (outgoing, written) = mpsc::unbounded::<String>();
        let (agent, incoming) = mpsc::unbounded();
        let ending: EndingCell = Arc::default();
        let posted: Arc<Mutex<Vec<Output>>> = Arc::default();
        let into = Arc::clone(&posted);
        let outbox: Outbox = Arc::new(move |output| into.lock().expect("unpoisoned").push(output));
        let transport = Transport {
            outgoing: outgoing.sink_map_err(|_| io::Error::from(io::ErrorKind::BrokenPipe)),
            incoming,
            ending: Arc::clone(&ending),
        };
        let (link, future) = session(transport, setup(), outbox);
        let pool = LocalPool::new();
        pool.spawner().spawn_local(future).expect("spawned");
        Self {
            pool,
            written,
            agent,
            ending,
            posted,
            link,
        }
    }

    /// Steps the pool until nothing can run, and reads every line the client
    /// wrote since the last read.
    fn lines(&mut self) -> Vec<Value> {
        self.pool.run_until_stalled();
        let mut lines = Vec::new();
        while let Ok(line) = self.written.try_recv() {
            lines.push(serde_json::from_str(&line).expect("the client writes JSON"));
        }
        lines
    }

    /// Steps the pool until nothing can run, and gives what the session
    /// posted since the last call.
    fn posted(&mut self) -> Vec<Output> {
        self.pool.run_until_stalled();
        std::mem::take(&mut *self.posted.lock().expect("unpoisoned"))
    }

    /// Sends the agent's line `line`.
    fn send(&self, line: &Value) {
        self.agent
            .unbounded_send(Ok(line.to_string()))
            .expect("the session reads");
    }

    /// Answers the client's request `request` with `result`.
    fn answer(&self, request: &Value, result: Value) {
        self.send(&json!({"jsonrpc": "2.0", "id": request["id"], "result": result}));
    }

    /// Sends the update `update` of the session.
    fn update(&self, update: Value) {
        self.send(&json!({"jsonrpc": "2.0", "method": "session/update",
            "params": {"sessionId": "sess-0001", "update": update}}));
    }

    /// Asks permission for the call `call` under the agent's id `id`.
    fn ask(&self, id: u64, call: &str) {
        self.send(
            &json!({"jsonrpc": "2.0", "id": id, "method": "session/request_permission",
            "params": {"sessionId": "sess-0001",
                "toolCall": {"toolCallId": call, "title": "Edit notes.txt", "kind": "edit"},
                "options": [
                    {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]}}),
        );
    }

    /// Ends the agent's output, the child having ended as `ending` says.
    fn end(&mut self, ending: Ending) {
        *self.ending.lock().expect("unpoisoned") = Some(ending);
        self.agent.close_channel();
    }

    /// Ends the agent's output with no ending recorded, as no pump would:
    /// the transport closed without saying how the child ended.
    fn close(&mut self) {
        self.agent.close_channel();
    }

    /// Opens the session: answers `initialize` and `session/new` with two
    /// modes, and gives the two lines the client wrote and what it posted.
    fn open(&mut self) -> (Value, Value, Vec<Output>) {
        let initialize = self.lines().remove(0);
        self.answer(
            &initialize,
            json!({"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}),
        );
        let new = self.lines().remove(0);
        self.answer(
            &new,
            json!({"sessionId": "sess-0001", "modes": {"currentModeId": "mode-ask",
                "availableModes": [{"id": "mode-ask", "name": "Ask"},
                    {"id": "mode-auto", "name": "Auto", "description": "Acts alone"}]}}),
        );
        let posted = self.posted();
        (initialize, new, posted)
    }

    /// A rig opened and prompted `ask` as the request 10, and the prompt's
    /// line.
    fn prompted() -> (Self, Value) {
        let mut rig = Self::new();
        rig.open();
        assert!(rig.link.order(10, Order::Prompt("ask".into())));
        let prompt = rig.lines().remove(0);
        assert_eq!(prompt["method"], "session/prompt");
        assert_eq!(rig.posted(), vec![Output::Sent(10, Ok(Some(1)))]);
        (rig, prompt)
    }
}

/// The permission event of `ticket`, for the call `call-<ticket>`, as the
/// rig asks it.
fn permission(ticket: u64) -> Output {
    Output::Event(Event::Permission {
        ticket,
        turn: Some(1),
        call: Call {
            title: "Edit notes.txt".into(),
            kind: "edit".into(),
            ..Call::empty(&format!("call-{ticket}"))
        },
        options: vec![
            PermissionOption {
                id: "allow".into(),
                name: "Allow".into(),
                kind: "allow_once".into(),
            },
            PermissionOption {
                id: "reject".into(),
                name: "Reject".into(),
                kind: "reject_once".into(),
            },
        ],
    })
}

/// The client's answer `cancelled` to the agent's request `id`.
fn cancelled_answer(id: u64) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": {"outcome": {"outcome": "cancelled"}}})
}

#[test]
fn the_session_initializes_offering_no_fs_and_no_terminal_then_opens_with_its_directory_and_servers()
 {
    let mut rig = Rig::new();
    let (initialize, new, posted) = rig.open();
    assert_eq!(initialize["method"], "initialize");
    assert_eq!(initialize["params"]["protocolVersion"], 1);
    let capabilities = &initialize["params"]["clientCapabilities"];
    assert_eq!(
        capabilities["fs"],
        json!({"readTextFile": false, "writeTextFile": false})
    );
    assert_eq!(capabilities["terminal"], false);
    assert_eq!(new["method"], "session/new");
    assert_eq!(
        new["params"],
        json!({"cwd": "/work/example", "mcpServers": [{"name": "example-server",
            "command": "/usr/local/bin/example", "args": ["--flag"],
            "env": [{"name": "KEY", "value": "value"}]}]})
    );
    assert_eq!(
        posted,
        vec![Output::Opened(Opened {
            session: 0,
            session_id: "sess-0001".into(),
            mode: Some("mode-ask".into()),
            modes: vec![
                Mode {
                    id: "mode-ask".into(),
                    name: "Ask".into(),
                    description: None
                },
                Mode {
                    id: "mode-auto".into(),
                    name: "Auto".into(),
                    description: Some("Acts alone".into())
                },
            ],
        })]
    );
    assert!(
        rig.lines().is_empty(),
        "no set_mode and no config of its own"
    );
}

#[test]
fn a_permission_request_is_answered_while_the_prompt_is_pending_and_the_response_ends_the_turn() {
    let (mut rig, prompt) = Rig::prompted();
    rig.update(json!({"sessionUpdate": "agent_message_chunk",
        "content": {"type": "text", "text": "I will edit."}, "messageId": "msg-1"}));
    rig.ask(0, "call-1");
    assert_eq!(
        rig.posted(),
        vec![
            Output::Event(Event::Chunk {
                message_id: Some("msg-1".into()),
                text: "I will edit.".into()
            }),
            permission(1),
        ]
    );
    // The prompt is still pending: its answer goes out from this thread.
    assert_eq!(rig.link.answer(1, "allow"), Ok(()));
    assert_eq!(
        rig.lines(),
        vec![json!({"jsonrpc": "2.0", "id": 0,
            "result": {"outcome": {"outcome": "selected", "optionId": "allow"}}})]
    );
    assert!(
        rig.link.answer(1, "allow").is_err(),
        "a ticket is answered once"
    );
    assert!(rig.posted().is_empty(), "the turn is still open");
    rig.answer(&prompt, json!({"stopReason": "end_turn"}));
    assert_eq!(
        rig.posted(),
        vec![Output::Event(Event::TurnEnded {
            turn: 1,
            stop_reason: "end_turn".into()
        })]
    );
}

#[test]
fn a_cancel_withdraws_the_parked_request_before_it_sends_session_cancel_and_a_late_request_is_answered_cancelled_at_once()
 {
    let (mut rig, prompt) = Rig::prompted();
    rig.ask(0, "call-1");
    assert_eq!(rig.posted(), vec![permission(1)]);
    assert!(rig.link.order(11, Order::Cancel));
    assert_eq!(
        rig.lines(),
        vec![
            cancelled_answer(0),
            json!({"jsonrpc": "2.0", "method": "session/cancel",
                "params": {"sessionId": "sess-0001"}}),
        ],
        "the parked request is answered before the agent is told"
    );
    assert_eq!(
        rig.posted(),
        vec![
            Output::Event(Event::Withdrawn { ticket: 1 }),
            Output::Sent(11, Ok(None))
        ]
    );
    assert!(rig.link.answer(1, "allow").is_err(), "withdrawn");
    // A request of the cancelled turn that comes after the cancel.
    rig.ask(1, "call-2");
    assert_eq!(rig.lines(), vec![cancelled_answer(1)]);
    assert_eq!(
        rig.posted(),
        vec![Output::Event(Event::Withdrawn { ticket: 2 })],
        "posted withdrawn, never as a permission"
    );
    rig.answer(&prompt, json!({"stopReason": "cancelled"}));
    assert_eq!(
        rig.posted(),
        vec![Output::Event(Event::TurnEnded {
            turn: 1,
            stop_reason: "cancelled".into()
        })]
    );
}

#[test]
fn a_response_to_a_request_the_client_never_sent_is_dropped_and_the_session_goes_on() {
    let (mut rig, _prompt) = Rig::prompted();
    rig.send(
        &json!({"jsonrpc": "2.0", "id": "no-such-request", "result": {"stopReason": "end_turn"}}),
    );
    rig.update(json!({"sessionUpdate": "current_mode_update", "currentModeId": "mode-auto"}));
    assert_eq!(
        rig.posted(),
        vec![Output::Event(Event::Mode("mode-auto".into()))],
        "no turn ended for it, and the session still reads"
    );
    assert!(rig.lines().is_empty(), "nothing answered it");
    rig.end(Ending::Exited(0));
    assert_eq!(
        rig.posted(),
        vec![Output::Event(Event::Ended(Ending::Exited(0)))]
    );
}

#[test]
fn the_end_of_the_agent_s_output_lets_its_parked_requests_go_and_says_how_the_child_ended_last() {
    let (mut rig, _prompt) = Rig::prompted();
    rig.ask(0, "call-1");
    assert_eq!(rig.posted(), vec![permission(1)]);
    rig.end(Ending::Signalled(9));
    assert_eq!(
        rig.posted(),
        vec![Output::Event(Event::Ended(Ending::Signalled(9)))],
        "the prompt never answered posts no turn's end"
    );
    assert!(rig.link.answer(1, "allow").is_err(), "the close let it go");
    assert!(!rig.link.order(12, Order::Cancel), "the session has ended");
}

#[test]
fn a_prompt_answered_just_before_the_output_ends_still_posts_its_turn_s_end_before_the_session_s() {
    let (mut rig, prompt) = Rig::prompted();
    rig.answer(&prompt, json!({"stopReason": "cancelled"}));
    rig.end(Ending::Exited(0));
    assert_eq!(
        rig.posted(),
        vec![
            Output::Event(Event::TurnEnded {
                turn: 1,
                stop_reason: "cancelled".into()
            }),
            Output::Event(Event::Ended(Ending::Exited(0))),
        ]
    );
}

#[test]
fn the_agent_s_auth_notifications_are_dropped_and_no_event_or_word_of_the_session_holds_their_text()
{
    let mut rig = Rig::new();
    rig.open();
    for method in ["_auth/status_update", "auth/status_update"] {
        rig.send(&json!({"jsonrpc": "2.0", "method": method, "params": {
            "account": {"email": "user@example.invalid", "organization": "Example Org"},
            "plan": "Example Plan"}}));
    }
    rig.update(json!({"sessionUpdate": "available_commands_update",
        "availableCommands": [{"name": "example-command", "description": "An example command.", "input": null}]}));
    rig.update(json!({"sessionUpdate": "config_option_update", "configOptions": []}));
    rig.update(json!({"sessionUpdate": "session_info_update", "title": "Example title"}));
    let posted = rig.posted();
    assert_eq!(
        posted,
        vec![Output::Event(Event::Title("Example title".into()))]
    );
    assert!(rig.lines().is_empty(), "a notification is never answered");
    rig.end(Ending::Exited(0));
    let all = format!("{posted:?} {:?}", rig.posted());
    for secret in ["user@example.invalid", "Example Org", "Example Plan"] {
        assert!(!all.contains(secret), "{secret} in {all}");
    }
}

#[test]
fn a_mode_is_set_only_when_a_caller_orders_it() {
    let mut rig = Rig::new();
    rig.open();
    assert!(rig.lines().is_empty());
    assert!(rig.link.order(13, Order::SetMode("mode-auto".into())));
    let lines = rig.lines();
    assert_eq!(lines.len(), 1);
    assert_eq!(lines[0]["method"], "session/set_mode");
    assert_eq!(
        lines[0]["params"],
        json!({"sessionId": "sess-0001", "modeId": "mode-auto"})
    );
    assert_eq!(rig.posted(), vec![Output::Sent(13, Ok(None))]);
    rig.answer(&lines[0], json!({}));
    assert!(rig.posted().is_empty());
}

#[test]
fn a_prompt_the_agent_answers_with_an_error_ends_its_turn_with_the_stop_reason_error() {
    let (mut rig, prompt) = Rig::prompted();
    rig.send(&json!({"jsonrpc": "2.0", "id": prompt["id"],
        "error": {"code": -32603, "message": "an example failure"}}));
    assert_eq!(
        rig.posted(),
        vec![Output::Event(Event::TurnEnded {
            turn: 1,
            stop_reason: "error".into()
        })],
        "the failed turn ends, and the session goes on"
    );
    assert!(rig.link.order(14, Order::Prompt("again".into())));
    assert_eq!(rig.lines()[0]["method"], "session/prompt");
    assert_eq!(rig.posted(), vec![Output::Sent(14, Ok(Some(2)))]);
}

#[test]
fn an_initialize_the_agent_answers_with_an_error_fails_the_connection_and_ends_the_session_as_a_protocol_error()
 {
    let mut rig = Rig::new();
    let initialize = rig.lines().remove(0);
    rig.send(&json!({"jsonrpc": "2.0", "id": initialize["id"],
        "error": {"code": -32603, "message": "an example failure"}}));
    let posted = rig.posted();
    assert!(
        matches!(&posted[..], [Output::Event(Event::Ended(Ending::ProtocolError(words)))]
            if words.contains("an example failure")),
        "{posted:?}"
    );
    assert!(!rig.link.order(15, Order::Cancel), "the session has ended");
}

#[test]
fn an_output_that_ends_with_no_ending_recorded_ends_the_session_failed_as_closed() {
    let (mut rig, _prompt) = Rig::prompted();
    rig.close();
    assert_eq!(
        rig.posted(),
        vec![Output::Event(Event::Ended(Ending::Failed(
            "the session was closed".into()
        )))]
    );
}
