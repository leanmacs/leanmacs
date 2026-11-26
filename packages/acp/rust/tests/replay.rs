//! Each hand-written fixture (`tests/fixtures/<name>.jsonl`, see its
//! README) replayed through the session against a lockstep agent, and the
//! plain events the session produced checked against the fixture's
//! checked-in sequence (`tests/fixtures/<name>.events`), in the encoding
//! Lean decodes (`event.rs`).
//!
//! The replay agent (`Replay`) walks the fixture's lines in order, on a
//! `LocalPool` the test steps on its own thread:
//!
//! - **An agent line** is sent once every client line before it has
//!   arrived, a response's id rewritten to the id our client gave the
//!   request it answers (the SDK's request ids are UUIDs).
//! - **A client line** must be the next line our client wrote, equal to the
//!   fixture's but for a request's id: the fixtures are written to what our
//!   client sends, so nothing is skipped and no field may differ; so the
//!   `initialize` line pins that no `fs` and no `terminal` are offered, and
//!   no `session/set_mode` can slip through.
//! - **It acts as Lean, driven by the fixture**: before a client
//!   `session/prompt` it orders the prompt with that line's text; before a
//!   client answer `selected` it answers the ticket of that agent request
//!   with that option; before a client answer `cancelled` or a
//!   `session/cancel` that our client has not sent already, it orders one
//!   cancel.
//!
//! After the last line the agent's output ends, as an exit 0. The produced
//! lines are the `opened` reply's, then each event's; on a mismatch the
//! test prints them, so updating the expected file after a deliberate change
//! is a copy that review reads. The fixtures are read with `include_str!`,
//! so the test touches no file.

use std::io;
use std::sync::{Arc, Mutex};

use acp_service::event::{Ending, Reply};
use acp_service::session::{Link, Order, Outbox, Output, Setup, Transport, session};
use acp_service::stream::EndingCell;
use futures::SinkExt;
use futures::channel::mpsc;
use futures::executor::LocalPool;
use futures::task::LocalSpawnExt;
use serde_json::Value;

/// The placeholder values of the fixtures' auth notifications, which no
/// produced line may hold.
const AUTH: [&str; 3] = ["user@example.invalid", "Example Org", "Example Plan"];

/// A session on a pool, with the replay agent's side of its transport.
struct Replay {
    /// The pool the session runs on.
    pool: LocalPool,
    /// The lines our client wrote, not yet read.
    written: mpsc::UnboundedReceiver<String>,
    /// Where the agent's lines go.
    agent: mpsc::UnboundedSender<io::Result<String>>,
    /// How the child ended.
    ending: EndingCell,
    /// What the session posted.
    posted: Arc<Mutex<Vec<Output>>>,
    /// The session's link, as Lean holds it.
    link: Link,
    /// The ids our client gave its requests, by the fixture's id.
    ids: Vec<(Value, Value)>,
    /// The ids of the agent's permission requests, in order: the i-th is
    /// the session's ticket i + 1.
    asked: Vec<Value>,
    /// Whether the replay has ordered a cancel.
    cancelled: bool,
    /// The next request number Lean orders under.
    request: u64,
}

impl Replay {
    /// A session opened in the fixtures' directory with no MCP server.
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
        let setup = Setup {
            cwd: "/work/example".into(),
            servers: Vec::new(),
        };
        let (link, future) = session(transport, setup, outbox);
        let pool = LocalPool::new();
        pool.spawner().spawn_local(future).expect("spawned");
        Self {
            pool,
            written,
            agent,
            ending,
            posted,
            link,
            ids: Vec::new(),
            asked: Vec::new(),
            cancelled: false,
            request: 100,
        }
    }

    /// Orders `order` as Lean would, under a fresh request number.
    fn order(&mut self, order: Order) {
        self.request += 1;
        assert!(
            self.link.order(self.request, order),
            "the session has ended"
        );
    }

    /// What Lean does before the client line `expected`, as the fixture
    /// drives it.
    fn act(&mut self, expected: &Value) {
        let method = expected["method"].as_str();
        let outcome = expected["result"]["outcome"]["outcome"].as_str();
        if method == Some("session/prompt") {
            let text = expected["params"]["prompt"][0]["text"]
                .as_str()
                .expect("a prompt's text");
            self.order(Order::Prompt(text.to_owned()));
        } else if outcome == Some("selected") {
            let ticket = self
                .asked
                .iter()
                .position(|id| *id == expected["id"])
                .expect("the answer is to a permission request the agent made")
                + 1;
            let option = expected["result"]["outcome"]["optionId"]
                .as_str()
                .expect("an option");
            assert_eq!(
                self.link
                    .answer(u64::try_from(ticket).expect("a ticket"), option),
                Ok(())
            );
        } else if (outcome == Some("cancelled") || method == Some("session/cancel"))
            && !self.cancelled
        {
            self.cancelled = true;
            self.order(Order::Cancel);
        }
    }

    /// Reads the next line our client wrote and holds it to `expected`,
    /// recording the id it gave a request.
    fn expect(&mut self, expected: &Value, index: usize) {
        self.act(expected);
        self.pool.run_until_stalled();
        let line = self.written.try_recv().unwrap_or_else(|_| {
            panic!("line {index}: our client wrote nothing; the fixture expects {expected}")
        });
        let mut written: Value = serde_json::from_str(&line).expect("the client writes JSON");
        let mut wanted = expected.clone();
        if expected.get("method").is_some()
            && let (Some(ours), Some(theirs)) = (
                written.as_object_mut().and_then(|line| line.remove("id")),
                wanted.as_object_mut().and_then(|line| line.remove("id")),
            )
        {
            self.ids.push((theirs, ours));
        }
        assert_eq!(written, wanted, "line {index}: what our client wrote");
    }

    /// Sends the agent's line `line`, a response's id rewritten to our
    /// client's.
    fn send(&mut self, line: &Value) {
        let mut line = line.clone();
        let response = line.get("method").is_none();
        if response {
            let theirs = line["id"].clone();
            let ours = self
                .ids
                .iter()
                .find(|(fixture, _)| *fixture == theirs)
                .map(|(_, ours)| ours.clone())
                .unwrap_or_else(|| panic!("a response to {theirs}, which our client never sent"));
            line["id"] = ours;
        } else if line["method"] == "session/request_permission" {
            self.asked.push(line["id"].clone());
        }
        self.agent
            .unbounded_send(Ok(line.to_string()))
            .expect("the session reads");
        self.pool.run_until_stalled();
    }

    /// Replays `fixture`, ends the agent's output as an exit 0, and gives the
    /// produced lines.
    fn run(mut self, fixture: &str) -> Vec<String> {
        for (index, text) in fixture.lines().enumerate() {
            let entry: Value = serde_json::from_str(text).expect("a fixture line is JSON");
            match entry["from"].as_str() {
                Some("client") => self.expect(&entry["msg"], index + 1),
                Some("agent") => self.send(&entry["msg"]),
                other => panic!("line {}: from {other:?}", index + 1),
            }
        }
        *self.ending.lock().expect("unpoisoned") = Some(Ending::Exited(0));
        self.agent.close_channel();
        self.pool.run_until_stalled();
        let unread: Vec<String> = std::iter::from_fn(|| self.written.try_recv().ok()).collect();
        assert!(unread.is_empty(), "our client wrote more: {unread:?}");
        let posted = std::mem::take(&mut *self.posted.lock().expect("unpoisoned"));
        posted
            .into_iter()
            .filter_map(|output| match output {
                Output::Opened(opened) => Some(Reply::Opened(opened).encode()),
                Output::Event(event) => Some(event.encode()),
                Output::Sent(_, sent) => {
                    assert!(sent.is_ok(), "an order was refused: {sent:?}");
                    None
                }
            })
            .collect()
    }
}

/// Replays `fixture` and holds the produced lines to `expected`, printing
/// them on a mismatch, and to none of the auth placeholders.
fn replays_to(fixture: &str, expected: &str) {
    let produced = Replay::new().run(fixture);
    let text = produced.join("\n") + "\n";
    for secret in AUTH {
        assert!(
            !text.contains(secret),
            "{secret} in what the session produced"
        );
    }
    assert!(
        text == expected,
        "the produced lines differ from the checked-in ones; they are:\n{text}"
    );
}

#[test]
fn the_plain_fixture_replays_to_its_checked_in_events() {
    replays_to(
        include_str!("fixtures/plain.jsonl"),
        include_str!("fixtures/plain.events"),
    );
}

#[test]
fn the_permission_fixture_replays_to_its_checked_in_events() {
    replays_to(
        include_str!("fixtures/permission.jsonl"),
        include_str!("fixtures/permission.events"),
    );
}

#[test]
fn the_cancel_fixture_replays_to_its_checked_in_events() {
    replays_to(
        include_str!("fixtures/cancel.jsonl"),
        include_str!("fixtures/cancel.events"),
    );
}

#[test]
fn a_client_line_that_differs_from_the_fixture_s_fails_the_replay() {
    let fixture =
        include_str!("fixtures/plain.jsonl").replacen("\"terminal\":false", "\"terminal\":true", 1);
    let failed = std::panic::catch_unwind(move || Replay::new().run(&fixture));
    assert!(
        failed.is_err(),
        "a client offering a terminal would be caught"
    );
}
