//! The service on `editor-service`'s recording completer, its sessions
//! started by a connector that runs each on a `LocalPool` the test steps on
//! its own thread, over a scripted transport whose agent side is the test.
//! So every report the service makes is made on the test's thread, during a
//! call of the test's or a step of the pool, and the test reads them in
//! order.

use std::cell::RefCell;
use std::io;
use std::rc::{Rc, Weak};
use std::sync::Arc;

use editor_service::RecordingCompleter;
use futures::SinkExt;
use futures::channel::mpsc;
use futures::executor::{LocalPool, LocalSpawner};
use futures::task::LocalSpawnExt;
use serde_json::{Value, json};

use super::*;
use crate::event::{Ending, Opened};
use crate::stream::EndingCell;

/// The agent's side of one session's transport.
struct AgentSide {
    /// The lines the client wrote, not yet read.
    written: mpsc::UnboundedReceiver<String>,
    /// Where the agent's lines go.
    lines: mpsc::UnboundedSender<io::Result<String>>,
    /// How the child ended, as the pump would record it.
    ending: EndingCell,
}

/// A child number the stepped connector refuses, as a refused take-over.
const REFUSED: u64 = 404;

/// A connector whose sessions run on the test's pool, each agent's side kept
/// for the test.
struct Stepped {
    /// Where a session's future is spawned.
    spawner: LocalSpawner,
    /// Each session's agent side, in the order connected.
    agents: Rc<RefCell<Vec<AgentSide>>>,
}

impl Connector for Stepped {
    fn connect(&self, child: u64, setup: Setup, outbox: Outbox) -> Result<Link, String> {
        if child == REFUSED {
            return Err("the take-over was refused".to_owned());
        }
        let (outgoing, written) = mpsc::unbounded::<String>();
        let (lines, incoming) = mpsc::unbounded();
        let ending: EndingCell = Arc::default();
        let transport = session::Transport {
            outgoing: outgoing.sink_map_err(|_| io::Error::from(io::ErrorKind::BrokenPipe)),
            incoming,
            ending: Arc::clone(&ending),
        };
        let (link, future) = session::session(transport, setup, outbox);
        self.spawner
            .spawn_local(future)
            .map_err(|_| "the pool is shut down".to_owned())?;
        self.agents.borrow_mut().push(AgentSide {
            written,
            lines,
            ending,
        });
        Ok(link)
    }
}

/// The service over a recording completer and the stepped connector, its
/// pool, and the agents' sides.
struct Rig {
    /// The service.
    acp: Acp<&'static RecordingCompleter, Stepped>,
    /// The pool its sessions run on.
    pool: LocalPool,
    /// The agents' sides.
    agents: Rc<RefCell<Vec<AgentSide>>>,
}

impl Rig {
    /// A service with no request, over a recording completer of its own.
    fn new() -> Self {
        let pool = LocalPool::new();
        let agents: Rc<RefCell<Vec<AgentSide>>> = Rc::default();
        let connector = Stepped {
            spawner: pool.spawner(),
            agents: Rc::clone(&agents),
        };
        let completer: &'static RecordingCompleter = Box::leak(Box::new(RecordingCompleter::new()));
        Self {
            acp: Acp::new(completer, connector),
            pool,
            agents,
        }
    }

    /// The requests reported since the last read, in order, without a step.
    fn reported_now(&self) -> Vec<u64> {
        self.acp.shared.completer.take()
    }

    /// Steps the sessions until nothing can run, and gives the requests the
    /// service reported since the last read, in order.
    fn reported(&mut self) -> Vec<u64> {
        self.pool.run_until_stalled();
        self.reported_now()
    }

    /// Steps the sessions, and reads every line the client of session
    /// `session` wrote since the last read.
    fn lines(&mut self, session: usize) -> Vec<Value> {
        self.pool.run_until_stalled();
        let mut agents = self.agents.borrow_mut();
        let mut lines = Vec::new();
        while let Ok(line) = agents[session - 1].written.try_recv() {
            lines.push(serde_json::from_str(&line).expect("the client writes JSON"));
        }
        lines
    }

    /// Sends the agent of session `session` the line `line`.
    fn send(&self, session: usize, line: &Value) {
        self.agents.borrow()[session - 1]
            .lines
            .unbounded_send(Ok(line.to_string()))
            .expect("the session reads");
    }

    /// Answers the client's request `request` of session `session`.
    fn answer(&self, session: usize, request: &Value, result: Value) {
        self.send(
            session,
            &json!({"jsonrpc": "2.0", "id": request["id"], "result": result}),
        );
    }

    /// Ends the agent's output of session `session`, its child having ended
    /// as `ending` says.
    fn end(&self, session: usize, ending: Ending) {
        let agents = self.agents.borrow();
        *agents[session - 1].ending.lock().expect("unpoisoned") = Some(ending);
        agents[session - 1].lines.close_channel();
    }

    /// Opens a session as the request `id` and answers its `initialize` and
    /// `session/new`: the session's number, from its reply.
    fn opened(&mut self, id: u64) -> u64 {
        assert!(self.acp.open(id, 7, setup()));
        let session = self.agents.borrow().len();
        let initialize = self.lines(session).remove(0);
        self.answer(session, &initialize, json!({"protocolVersion": 1}));
        let new = self.lines(session).remove(0);
        self.answer(session, &new, json!({"sessionId": "sess-0001"}));
        assert_eq!(self.reported(), [id]);
        match self.acp.take(id) {
            Some(Reply::Opened(opened)) => opened.session,
            other => panic!("not opened: {other:?}"),
        }
    }

    /// Sends the agent of session `session` a chunk of `text`.
    fn chunk(&self, session: usize, text: &str) {
        self.send(
            session,
            &json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "sess-0001",
                "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}}),
        );
    }
}

/// The setup the tests open with.
fn setup() -> Setup {
    Setup {
        cwd: "/work/example".into(),
        servers: Vec::new(),
        load: None,
    }
}

/// A chunk of `text` with no message id.
fn chunk(text: &str) -> Event {
    Event::Chunk {
        message_id: None,
        text: text.into(),
    }
}

#[test]
fn an_open_completes_once_the_agent_has_a_session_with_the_service_s_number_for_it() {
    let mut rig = Rig::new();
    assert!(rig.acp.open(1, 7, setup()));
    assert!(!rig.acp.open(1, 7, setup()), "the id is in use");
    let initialize = rig.lines(1).remove(0);
    assert!(rig.reported().is_empty(), "not before the agent answers");
    rig.answer(1, &initialize, json!({"protocolVersion": 1}));
    let new = rig.lines(1).remove(0);
    rig.answer(1, &new, json!({"sessionId": "sess-0001"}));
    assert_eq!(rig.reported(), [1]);
    assert_eq!(
        rig.acp.take(1),
        Some(Reply::Opened(Opened {
            session: 1,
            session_id: "sess-0001".into(),
            mode: None,
            modes: Vec::new(),
        }))
    );
    assert_eq!(rig.acp.take(1), None, "taken once");
}

#[test]
fn an_open_whose_take_over_is_refused_is_not_started_and_keeps_nothing() {
    let rig = Rig::new();
    assert!(!rig.acp.open(1, REFUSED, setup()));
    assert_eq!(rig.acp.sessions(), 0);
    assert!(rig.acp.open(1, 7, setup()), "the id is free again");
}

#[test]
fn a_session_that_ends_before_it_opens_answers_its_open_refused() {
    let mut rig = Rig::new();
    assert!(rig.acp.open(1, 7, setup()));
    rig.end(1, Ending::Exited(3));
    assert_eq!(rig.reported(), [1]);
    assert!(matches!(rig.acp.take(1), Some(Reply::Refused(_))));
}

#[test]
fn a_next_completes_at_once_with_every_event_held_and_otherwise_once_one_comes() {
    let mut rig = Rig::new();
    let session = rig.opened(1);
    assert!(rig.acp.next(2, session));
    assert!(
        !rig.acp.next(3, session),
        "a second next is refused at its start"
    );
    assert!(rig.reported().is_empty(), "nothing to say yet");
    rig.chunk(1, "one");
    rig.chunk(1, "two");
    assert_eq!(rig.reported(), [2]);
    assert_eq!(
        rig.acp.take(2),
        Some(Reply::Batch(vec![chunk("one"), chunk("two")])),
        "both chunks, posted before the take"
    );
    rig.chunk(1, "three");
    assert!(rig.reported().is_empty());
    assert!(rig.acp.next(4, session));
    assert_eq!(rig.reported_now(), [4], "at once, on the caller's thread");
    assert_eq!(rig.acp.take(4), Some(Reply::Batch(vec![chunk("three")])));
    assert!(!rig.acp.next(5, 99), "no such session");
}

#[test]
fn a_prompt_completes_once_on_its_way_with_its_turn_and_an_answer_completes_at_once() {
    let mut rig = Rig::new();
    let session = rig.opened(1);
    assert!(rig.acp.send(2, session, Order::Prompt("ask".into())));
    assert_eq!(rig.reported(), [2]);
    assert_eq!(rig.acp.take(2), Some(Reply::Sent(Some(1))));
    let prompt = rig.lines(1).remove(0);
    assert_eq!(prompt["method"], "session/prompt");
    rig.send(
        1,
        &json!({"jsonrpc": "2.0", "id": 0, "method": "session/request_permission", "params": {
            "sessionId": "sess-0001", "toolCall": {"toolCallId": "call-1"},
            "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"}]}}),
    );
    assert!(rig.acp.next(3, session));
    assert_eq!(rig.reported(), [3]);
    assert!(matches!(
        rig.acp.take(3),
        Some(Reply::Batch(events)) if matches!(events[..], [Event::Permission { ticket: 1, .. }])
    ));
    assert!(rig.acp.answer(4, session, 1, "allow"));
    assert_eq!(rig.reported_now(), [4]);
    assert_eq!(rig.acp.take(4), Some(Reply::Sent(None)));
    assert!(rig.acp.answer(5, session, 1, "allow"));
    assert!(
        matches!(rig.acp.take(5), Some(Reply::Refused(_))),
        "answered once"
    );
    assert!(rig.acp.answer(6, session, 9, "allow"));
    assert!(
        matches!(rig.acp.take(6), Some(Reply::Refused(_))),
        "never asked"
    );
    assert_eq!(rig.lines(1).len(), 1, "one answer went out");
}

#[test]
fn a_withdrawn_next_is_never_completed_and_its_events_go_to_the_next_one() {
    let mut rig = Rig::new();
    let session = rig.opened(1);
    assert!(rig.acp.next(2, session));
    assert!(rig.acp.cancel(2));
    assert!(!rig.acp.cancel(2), "withdrawn once");
    rig.chunk(1, "late");
    assert!(
        rig.reported().is_empty(),
        "the withdrawn next gets no completion"
    );
    assert!(rig.acp.next(3, session));
    assert_eq!(rig.reported_now(), [3]);
    assert_eq!(rig.acp.take(3), Some(Reply::Batch(vec![chunk("late")])));
}

#[test]
fn a_flush_is_reported_behind_the_orders_it_covers_and_never_waits_for_a_pending_next() {
    let mut rig = Rig::new();
    let session = rig.opened(1);
    assert!(rig.acp.next(2, session));
    rig.acp.flush(3);
    assert_eq!(rig.reported_now(), [3], "the pending next is a long poll");
    assert!(rig.acp.send(4, session, Order::Prompt("ask".into())));
    rig.acp.flush(5);
    assert!(rig.reported_now().is_empty(), "held by the prompt");
    assert_eq!(rig.reported(), [4, 5], "behind it");
}

#[test]
fn the_session_s_last_event_ends_it_a_next_after_is_refused_and_its_state_is_freed() {
    let mut rig = Rig::new();
    let session = rig.opened(1);
    rig.end(1, Ending::Exited(0));
    assert!(rig.reported().is_empty());
    assert!(rig.acp.next(2, session));
    assert_eq!(rig.reported_now(), [2]);
    assert_eq!(
        rig.acp.take(2),
        Some(Reply::Batch(vec![Event::Ended(Ending::Exited(0))]))
    );
    assert_eq!(rig.acp.sessions(), 0, "freed once its last event is taken");
    assert!(!rig.acp.next(3, session), "no such session any more");
    assert!(rig.acp.send(4, session, Order::Cancel));
    assert!(matches!(rig.acp.take(4), Some(Reply::Refused(_))));
}

#[test]
fn a_session_whose_job_withdrew_its_next_is_freed_once_it_ends() {
    let mut rig = Rig::new();
    let session = rig.opened(1);
    assert!(rig.acp.next(2, session));
    // The job's cancel: its wait withdrawn first, then its child ended.
    assert!(rig.acp.cancel(2));
    rig.end(1, Ending::Signalled(9));
    assert!(
        rig.reported().is_empty(),
        "nothing completes for the withdrawn job"
    );
    assert_eq!(rig.acp.sessions(), 0);
}

#[test]
fn an_open_withdrawn_before_it_completes_ends_its_session_once_open_and_frees_it() {
    let mut rig = Rig::new();
    assert!(rig.acp.open(1, 7, setup()));
    let initialize = rig.lines(1).remove(0);
    // The job's cancel: its open withdrawn before the agent answered.
    assert!(rig.acp.cancel(1));
    rig.answer(1, &initialize, json!({"protocolVersion": 1}));
    let new = rig.lines(1).remove(0);
    rig.answer(1, &new, json!({"sessionId": "sess-0001"}));
    rig.chunk(1, "nobody reads this");
    assert!(
        rig.reported().is_empty(),
        "nothing completes for the withdrawn open"
    );
    assert_eq!(
        rig.acp.sessions(),
        0,
        "no job knows its number, so it ends and is freed"
    );
}

#[test]
fn an_open_withdrawn_once_ready_and_never_taken_ends_its_session_and_frees_it() {
    let mut rig = Rig::new();
    assert!(rig.acp.open(1, 7, setup()));
    let initialize = rig.lines(1).remove(0);
    rig.answer(1, &initialize, json!({"protocolVersion": 1}));
    let new = rig.lines(1).remove(0);
    rig.answer(1, &new, json!({"sessionId": "sess-0001"}));
    assert_eq!(rig.reported(), [1]);
    assert!(rig.acp.cancel(1), "ready, not yet taken");
    assert!(rig.reported().is_empty());
    assert_eq!(rig.acp.sessions(), 0);
    assert_eq!(rig.acp.take(1), None, "withdrawn, so never taken");
}

#[test]
fn an_open_withdrawn_whose_child_ends_before_it_opens_frees_its_session() {
    let mut rig = Rig::new();
    assert!(rig.acp.open(1, 7, setup()));
    assert!(rig.acp.cancel(1));
    rig.end(1, Ending::Signalled(9));
    assert!(rig.reported().is_empty());
    assert_eq!(rig.acp.sessions(), 0);
}

/// A connector that starts its session as [`Stepped`] does and then, before
/// it returns, withdraws the open `id` through the service: a cancel from
/// another job's thread landing while the connector runs.
struct Withdrawing {
    /// What starts the session.
    stepped: Stepped,
    /// The service, once it is made.
    acp: RefCell<Weak<Acp<&'static RecordingCompleter, Withdrawing>>>,
    /// The open it withdraws.
    id: u64,
}

impl Connector for Withdrawing {
    fn connect(&self, child: u64, setup: Setup, outbox: Outbox) -> Result<Link, String> {
        let link = self.stepped.connect(child, setup, outbox)?;
        let acp = self.acp.borrow().upgrade().expect("the service is made");
        assert!(acp.cancel(self.id), "withdrawn while the connector runs");
        Ok(link)
    }
}

#[test]
fn an_open_withdrawn_while_its_connector_runs_ends_its_session_once_open_and_frees_it() {
    let mut pool = LocalPool::new();
    let agents: Rc<RefCell<Vec<AgentSide>>> = Rc::default();
    let completer: &'static RecordingCompleter = Box::leak(Box::new(RecordingCompleter::new()));
    let acp = Rc::new(Acp::new(
        completer,
        Withdrawing {
            stepped: Stepped {
                spawner: pool.spawner(),
                agents: Rc::clone(&agents),
            },
            acp: RefCell::new(Weak::new()),
            id: 1,
        },
    ));
    *acp.connector.acp.borrow_mut() = Rc::downgrade(&acp);
    assert!(acp.open(1, 7, setup()));
    let mut agent = agents.borrow_mut().remove(0);
    let mut read = |pool: &mut LocalPool| {
        pool.run_until_stalled();
        let line = agent.written.try_recv().expect("the client wrote");
        serde_json::from_str::<Value>(&line).expect("the client writes JSON")
    };
    let initialize = read(&mut pool);
    let answer = |request: &Value, result: Value| {
        agent
            .lines
            .unbounded_send(Ok(
                json!({"jsonrpc": "2.0", "id": request["id"], "result": result}).to_string(),
            ))
            .expect("the session reads");
    };
    answer(&initialize, json!({"protocolVersion": 1}));
    let new = read(&mut pool);
    answer(&new, json!({"sessionId": "sess-0001"}));
    pool.run_until_stalled();
    assert!(completer.take().is_empty(), "nothing completes for it");
    assert_eq!(acp.sessions(), 0, "it ended once open, and was freed");
}

/// The setup that loads the session `sess-0002`.
fn loading() -> Setup {
    Setup {
        load: Some("sess-0002".into()),
        ..setup()
    }
}

impl Rig {
    /// Starts a load as the request `id`, answers its `initialize` offering
    /// `session/load`, and gives the `session/load` line.
    fn loading(&mut self, id: u64) -> Value {
        assert!(self.acp.open(id, 7, loading()));
        let session = self.agents.borrow().len();
        let initialize = self.lines(session).remove(0);
        self.answer(
            session,
            &initialize,
            json!({"protocolVersion": 1, "agentCapabilities": {"loadSession": true}}),
        );
        let load = self.lines(session).remove(0);
        assert_eq!(load["method"], "session/load");
        load
    }

    /// Sends the agent of session `session` the user's chunk `text`, as a
    /// load's history replays it.
    fn user_chunk(&self, session: usize, text: &str) {
        self.send(
            session,
            &json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "sess-0002",
                "update": {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": text}}}}),
        );
    }
}

#[test]
fn a_load_s_history_posted_before_its_open_is_held_for_the_first_next() {
    let mut rig = Rig::new();
    let load = rig.loading(1);
    rig.user_chunk(1, "Read notes.txt.");
    rig.chunk(1, "Done.");
    assert!(rig.reported().is_empty(), "not before the agent answers");
    rig.answer(1, &load, json!({}));
    assert_eq!(rig.reported(), [1]);
    let Some(Reply::Opened(opened)) = rig.acp.take(1) else {
        panic!("not opened");
    };
    assert_eq!(opened.session_id, "sess-0002");
    assert!(rig.acp.next(2, opened.session));
    assert_eq!(rig.reported_now(), [2], "at once: the history is held");
    assert_eq!(
        rig.acp.take(2),
        Some(Reply::Batch(vec![
            Event::UserChunk {
                message_id: None,
                text: "Read notes.txt.".into()
            },
            chunk("Done."),
        ]))
    );
}

#[test]
fn a_load_whose_agent_answers_an_error_refuses_the_open_and_sessions_is_0_once_the_refusal_is_taken()
 {
    let mut rig = Rig::new();
    let load = rig.loading(1);
    rig.user_chunk(1, "Read notes.txt.");
    rig.send(
        1,
        &json!({"jsonrpc": "2.0", "id": load["id"],
            "error": {"code": -32603, "message": "an example failure"}}),
    );
    assert_eq!(rig.reported(), [1]);
    assert!(matches!(rig.acp.take(1), Some(Reply::Refused(_))));
    assert_eq!(
        rig.acp.sessions(),
        0,
        "no job knows its number, so its history is freed, not held"
    );
}
