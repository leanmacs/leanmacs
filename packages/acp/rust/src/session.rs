//! One session with an agent: the SDK's client connection over a transport
//! of lines ([`Transport`]), the orders a client gives it ([`Link`]), and the
//! plain output it posts ([`Output`]).
//!
//! [`session`] makes the session's [`Link`] and its future. The future is
//! the whole connection: whoever runs it runs the SDK. In production it is
//! one thread of the crate's own, blocked on it ([`crate::Threads`]); in the
//! tests it is a `LocalPool` the test steps on its own thread, over a
//! scripted transport, so every interleaving a test asserts is forced by
//! the order of its steps.
//!
//! # What the session does
//!
//! - **It opens.** `initialize`, offering no `fs` and no `terminal` (the
//!   SDK's defaults: Claude Code's adapter edits files itself), then
//!   `session/new` with the working directory and the MCP servers, and posts
//!   [`Output::Opened`]. It sends no `session/set_mode`, no
//!   `session/set_config_option` and no config of its own: the host's Claude
//!   settings are used as they are (roadmap Decisions). A mode is set only
//!   when a caller orders it ([`Order::SetMode`]).
//! - **A handler returns at once.** A `session/update` is made plain
//!   ([`crate::filter`]), its tool calls merged ([`crate::merge`]), and
//!   posted. A `session/request_permission` is parked under a ticket
//!   ([`crate::tickets`]) and posted as [`Event::Permission`]; its answer
//!   comes later, from whichever thread asks ([`Link::answer`]), straight
//!   through the parked `Responder` under the tickets' lock.
//! - **Orders keep flowing during a turn.** The connection's main future
//!   waits on the orders and on the prompts' responses together: a prompt
//!   ([`Order::Prompt`]) begins a turn and is answered once it is on its way
//!   ([`Output::Sent`]); its response is the turn's end
//!   ([`Event::TurnEnded`]).
//! - **A cancel** ([`Order::Cancel`]) answers every parked request of the
//!   current turn `cancelled`, posting [`Event::Withdrawn`] for each, marks
//!   the turn cancelled, so a later request of it is answered `cancelled` at
//!   once and posted as withdrawn, and then sends `session/cancel`.
//! - **It ends** when the agent's output ends: the prompts already answered
//!   post their turn's end, every parked request is let go, and the last
//!   event says how the child ended ([`Event::Ended`]), or that the
//!   connection failed.
//!
//! A prompt the agent answers with an error ends its turn with the stop
//! reason `error`, and the session goes on. A request of the opening the
//! agent answers with an error fails the connection, which ends the
//! session as [`Ending::ProtocolError`] with the error's words. A session
//! that ends with no ending recorded (every [`Link`] to it dropped, or an
//! output that ends without the pump having said how the child ended) ends
//! as [`Ending::Failed`]: the session was closed.
//!
//! A response whose id matches no request the client sent is dropped by the
//! SDK, which routes it to nobody, and the session goes on.

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use agent_client_protocol::schema::ProtocolVersion;
use agent_client_protocol::v1::schema::{
    CancelNotification, ContentBlock, EnvVariable, InitializeRequest, McpServer as SdkServer,
    McpServerStdio, NewSessionRequest, NewSessionResponse, PromptRequest, PromptResponse,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse,
    SelectedPermissionOutcome, SessionNotification, SessionUpdate, SetSessionModeRequest,
    TextContent,
};
use agent_client_protocol::v1::{ConnectionTo, Responder};
use agent_client_protocol::{Agent, Client, Lines};
use futures::channel::mpsc;
use futures::stream::FuturesUnordered;
use futures::{FutureExt, Sink, Stream, StreamExt};

use crate::event::{Ending, Event, Mode, Opened, PermissionOption};
use crate::filter::{self, Note};
use crate::merge::Calls;
use crate::stream::EndingCell;
use crate::tickets::{Asked, Tickets};

/// An MCP server a session is given.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpServer {
    /// Its name.
    pub name: String,
    /// The command the agent runs.
    pub command: String,
    /// Its arguments.
    pub arguments: Vec<String>,
    /// Its environment's variables, each a name and a value.
    pub environment: Vec<(String, String)>,
}

/// What a session is opened with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Setup {
    /// The working directory.
    pub cwd: String,
    /// The MCP servers.
    pub servers: Vec<McpServer>,
}

/// An order the session's main future carries out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Order {
    /// Send a prompt of this text, beginning a turn.
    Prompt(String),
    /// Cancel the current turn.
    Cancel,
    /// Set the mode.
    SetMode(String),
}

/// What a session posts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Output {
    /// It opened: what `session/new` answered (its `session` number is the
    /// service's to fill).
    Opened(Opened),
    /// An event.
    Event(Event),
    /// The order of the request `request` is on its way: a prompt's turn, or
    /// why it was refused.
    Sent(u64, Result<Option<u64>, String>),
}

/// Where a session posts, from its own thread.
pub type Outbox = Arc<dyn Fn(Output) + Send + Sync>;

/// The lines a session runs over: what it writes, what it reads, and how
/// the child ended once the reading has ended.
pub struct Transport<O, I> {
    /// The sink each line the SDK sends goes to.
    pub outgoing: O,
    /// The stream of the agent's lines.
    pub incoming: I,
    /// How the child ended, recorded before `incoming` ends.
    pub ending: EndingCell,
}

/// The requests a session parks, under their tickets.
type Parked = Tickets<Responder<RequestPermissionResponse>>;

/// What a session's handlers, its main future and its link share.
struct Shared {
    /// The parked permission requests.
    tickets: Mutex<Parked>,
    /// The tool calls, merged.
    calls: Mutex<Calls>,
    /// Where it posts.
    outbox: Outbox,
}

impl Shared {
    /// The tickets, locked. The lock is never held while other code than
    /// the session's runs, so a poisoned lock still guards a consistent
    /// state.
    fn tickets(&self) -> MutexGuard<'_, Parked> {
        self.tickets.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The calls, locked.
    fn calls(&self) -> MutexGuard<'_, Calls> {
        self.calls.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Posts `event`.
    fn post(&self, event: Event) {
        (self.outbox)(Output::Event(event));
    }

    /// Posts what the session keeps of `update`, its tool calls merged.
    fn note(&self, update: &SessionUpdate) {
        match filter::note(update) {
            Some(Note::Event(event)) => self.post(event),
            Some(Note::Announced(call)) => {
                let call = self.calls().announce(call);
                self.post(Event::ToolCall(call));
            }
            Some(Note::Updated(id, update)) => {
                let call = self.calls().update(&id, update);
                self.post(Event::ToolCall(call));
            }
            None => {}
        }
    }

    /// Parks the permission request `request` and posts it, or, when its
    /// turn is cancelled, answers it `cancelled` at once and posts it
    /// withdrawn.
    fn ask(
        &self,
        request: &RequestPermissionRequest,
        responder: Responder<RequestPermissionResponse>,
    ) {
        let call = self.calls().update(
            &request.tool_call.tool_call_id.0,
            filter::update_of(&request.tool_call.fields),
        );
        let options = request
            .options
            .iter()
            .map(|option| PermissionOption {
                id: option.option_id.0.to_string(),
                name: option.name.clone(),
                kind: filter::wire_name(&option.kind),
            })
            .collect();
        let mut tickets = self.tickets();
        match tickets.ask(responder) {
            Asked::Parked { ticket, turn } => self.post(Event::Permission {
                ticket,
                turn,
                call,
                options,
            }),
            Asked::Cancelled { ticket, request } => {
                // Answered once: a refusal here means the connection is
                // gone, and the session's end says so.
                let _ = request.respond(cancelled());
                self.post(Event::Withdrawn { ticket });
            }
        }
    }

    /// Cancels the current turn: answers each of its parked requests
    /// `cancelled` and posts it withdrawn.
    fn cancel(&self) {
        let mut tickets = self.tickets();
        for (ticket, responder) in tickets.cancel() {
            let _ = responder.respond(cancelled());
            self.post(Event::Withdrawn { ticket });
        }
    }
}

/// The answer `cancelled`.
fn cancelled() -> RequestPermissionResponse {
    RequestPermissionResponse::new(RequestPermissionOutcome::Cancelled)
}

/// How a caller reaches a session: its orders, and the answers to its
/// permission requests. A cheap handle: clones reach one session.
#[derive(Clone)]
pub struct Link {
    /// The orders, each with the request it answers.
    orders: mpsc::UnboundedSender<(u64, Order)>,
    /// What the session shares.
    shared: Arc<Shared>,
}

impl std::fmt::Debug for Link {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("Link").finish_non_exhaustive()
    }
}

impl Link {
    /// Hands the session `order`, for the request `request`, whose
    /// [`Output::Sent`] comes once it is on its way: false when the session
    /// has ended.
    pub fn order(&self, request: u64, order: Order) -> bool {
        self.orders.unbounded_send((request, order)).is_ok()
    }

    /// Answers the parked permission request `ticket` with the option
    /// `option`, from the caller's thread, under the tickets' lock.
    ///
    /// # Errors
    ///
    /// Why it was not answered: the ticket is not parked (answered already,
    /// withdrawn by a cancel, or never asked), or the connection is gone.
    pub fn answer(&self, ticket: u64, option: &str) -> Result<(), String> {
        let mut tickets = self.shared.tickets();
        let responder = tickets
            .answer(ticket)
            .ok_or_else(|| format!("the ticket {ticket} is not parked"))?;
        responder
            .respond(RequestPermissionResponse::new(
                RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                    option.to_owned(),
                )),
            ))
            .map_err(|_| "the connection is gone".to_owned())
    }
}

/// What `session/new` answered, made plain.
fn opened_of(new: &NewSessionResponse) -> Opened {
    let (mode, modes) = new.modes.as_ref().map_or((None, Vec::new()), |modes| {
        (
            Some(modes.current_mode_id.0.to_string()),
            modes
                .available_modes
                .iter()
                .map(|mode| Mode {
                    id: mode.id.0.to_string(),
                    name: mode.name.clone(),
                    description: mode.description.clone(),
                })
                .collect(),
        )
    });
    Opened {
        session: 0,
        session_id: new.session_id.0.to_string(),
        mode,
        modes,
    }
}

/// An MCP server as `session/new` carries it.
fn server_of(server: &McpServer) -> SdkServer {
    SdkServer::Stdio(
        McpServerStdio::new(server.name.clone(), server.command.clone())
            .args(server.arguments.clone())
            .env(
                server
                    .environment
                    .iter()
                    .map(|(name, value)| EnvVariable::new(name.clone(), value.clone()))
                    .collect(),
            ),
    )
}

/// A prompt's response, awaited, with its turn.
type Turn =
    Pin<Box<dyn Future<Output = (u64, agent_client_protocol::Result<PromptResponse>)> + Send>>;

/// A response a session does not wait on, awaited and dropped.
type Ignored = Pin<Box<dyn Future<Output = ()> + Send>>;

/// The connection's main future: opens the session, then carries out the
/// orders and posts each prompt's end, until the agent's output ends or the
/// orders do.
async fn main(
    cx: ConnectionTo<Agent>,
    setup: Setup,
    mut orders: mpsc::UnboundedReceiver<(u64, Order)>,
    shared: Arc<Shared>,
) -> agent_client_protocol::Result<()> {
    cx.send_request(InitializeRequest::new(ProtocolVersion::V1))
        .block_task()
        .await?;
    let new = cx
        .send_request(
            NewSessionRequest::new(setup.cwd.clone())
                .mcp_servers(setup.servers.iter().map(server_of).collect()),
        )
        .block_task()
        .await?;
    let session_id = new.session_id.clone();
    (shared.outbox)(Output::Opened(opened_of(&new)));
    let mut prompts: FuturesUnordered<Turn> = FuturesUnordered::new();
    let mut ignored: FuturesUnordered<Ignored> = FuturesUnordered::new();
    let mut turns = 0;
    let closed = cx.incoming_closed().fuse();
    futures::pin_mut!(closed);
    loop {
        futures::select_biased! {
            (turn, response) = prompts.select_next_some() => ended(&shared, turn, response),
            () = ignored.select_next_some() => {},
            order = orders.next() => {
                let Some((request, order)) = order else {
                    return Ok(());
                };
                let sent = match order {
                    Order::Prompt(text) => {
                        turns += 1;
                        shared.tickets().begin(turns);
                        let turn = turns;
                        let response = cx
                            .send_request(PromptRequest::new(
                                session_id.clone(),
                                vec![ContentBlock::Text(TextContent::new(text))],
                            ))
                            .block_task();
                        prompts.push(Box::pin(response.map(move |response| (turn, response))));
                        Ok(Some(turn))
                    }
                    Order::Cancel => {
                        shared.cancel();
                        cx.send_notification(CancelNotification::new(session_id.clone()))
                            .map(|()| None)
                            .map_err(|error| error.message)
                    }
                    Order::SetMode(id) => {
                        let response = cx
                            .send_request(SetSessionModeRequest::new(session_id.clone(), id))
                            .block_task();
                        ignored.push(Box::pin(response.map(drop)));
                        Ok(None)
                    }
                };
                (shared.outbox)(Output::Sent(request, sent));
            },
            () = closed => {
                // The prompts the agent answered before its output ended are
                // ready; the rest fail at once, as every pending request
                // does at the end of the input.
                while let Some(Some((turn, response))) = prompts.next().now_or_never() {
                    ended(&shared, turn, response);
                }
                return Ok(());
            },
        }
    }
}

/// Posts the end of the turn `turn` its prompt's `response` says: the stop
/// reason; nothing when the connection ended first.
fn ended(shared: &Shared, turn: u64, response: agent_client_protocol::Result<PromptResponse>) {
    match response {
        Ok(response) => shared.post(Event::TurnEnded {
            turn,
            stop_reason: filter::wire_name(&response.stop_reason),
        }),
        Err(error)
            if agent_client_protocol::is_connection_terminated(&error)
                || agent_client_protocol::is_incoming_transport_closed(&error) => {}
        Err(_) => shared.post(Event::TurnEnded {
            turn,
            stop_reason: "error".to_owned(),
        }),
    }
}

/// A session over `transport`, opened with `setup`, posting to `outbox`:
/// its link, and the future that runs it to its end, whose last post is
/// [`Event::Ended`].
pub fn session<O, I>(
    transport: Transport<O, I>,
    setup: Setup,
    outbox: Outbox,
) -> (Link, impl Future<Output = ()> + Send + 'static)
where
    O: Sink<String, Error = io::Error> + Send + 'static,
    I: Stream<Item = io::Result<String>> + Send + 'static,
{
    let (orders, received) = mpsc::unbounded();
    let shared = Arc::new(Shared {
        tickets: Mutex::new(Tickets::new()),
        calls: Mutex::new(Calls::new()),
        outbox,
    });
    let link = Link {
        orders,
        shared: Arc::clone(&shared),
    };
    let Transport {
        outgoing,
        incoming,
        ending,
    } = transport;
    let run = async move {
        let notified = Arc::clone(&shared);
        let asked = Arc::clone(&shared);
        let driven = Arc::clone(&shared);
        let result = Client
            .v1()
            .on_receive_notification(
                async move |notification: SessionNotification, _cx| {
                    notified.note(&notification.update);
                    Ok(())
                },
                agent_client_protocol::on_receive_notification!(),
            )
            .on_receive_request(
                async move |request: RequestPermissionRequest,
                            responder: Responder<RequestPermissionResponse>,
                            _cx| {
                    asked.ask(&request, responder);
                    Ok(())
                },
                agent_client_protocol::on_receive_request!(),
            )
            .connect_with(Lines::new(outgoing, incoming), async move |cx| {
                main(cx, setup, received, driven).await
            })
            .await;
        // The close: every request still parked is let go, as the model's
        // close answers it; the connection that would carry an answer is
        // gone.
        drop(shared.tickets().close());
        let recorded = ending.lock().unwrap_or_else(PoisonError::into_inner).take();
        let how = match (recorded, result) {
            (Some(ending), _) => ending,
            (None, Err(error)) => Ending::ProtocolError(error.message),
            (None, Ok(())) => Ending::Failed("the session was closed".to_owned()),
        };
        shared.post(Event::Ended(how));
    };
    (link, run)
}

#[cfg(test)]
mod tests;
