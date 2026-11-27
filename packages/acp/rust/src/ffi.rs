//! The library's C interface, declared with the package wrapper's macro
//! (`editor_package::package!`): its two exported symbols, its init
//! ([`editor_package_init`]) and its declaration
//! ([`editor_package_declaration`]: interface 1, the shape of
//! [`AcpFunctions`], which the glue's `ACP_INTERFACE` names, and the runtime
//! the wrapper needs), and the table of C functions it answers
//! ([`AcpFunctions`], behind the table's size), through which the package's
//! glue (`ffi/glue.c`) forwards acp's `@[extern]` calls. A change to the
//! table's shape is a new interface version, here and in the glue together.
//!
//! The init is the wrapper's ([`editor_package::Package::export`]): it
//! refuses no runtime and one smaller than the wrapper requires, the table
//! unwritten; otherwise it makes the library's state once ([`Loaded::new`]:
//! the service `acp` registered through the runtime, and the process's one
//! [`Acp`] over it and a connector that takes children over through the
//! runtime), writes the table and answers 0. A second init answers the same
//! table. Each table function reaches the state through [`PACKAGE`], and
//! answers false, or none, before the library is loaded.
//!
//! Plain data only, in the wrapper's FFI-safe types, so no function here has
//! `unsafe` of its own: each is declared with the wrapper's `functions!`,
//! whose body sees what the caller lent borrowed for the call alone. A text
//! crosses as [`Bytes`], read as its `&[u8]` with U+FFFD in place of each
//! invalid sequence (a Lean string is UTF-8); a reply as one [`RawReply`]
//! written through an [`Out`] in a single call, its text the encoding
//! `event.rs` defines, a [`Lent`] the glue hands back through the table's
//! `free` ([`editor_package::buffer::free`]), so this library's allocator
//! frees what it made. A session's MCP servers cross as text too, one server
//! a line ([`servers_of`]). The table is a static of the library, valid for
//! the life of the process, since the core never unloads the library.

use editor_package::buffer::{Bytes, Lent, Out};
use editor_package::{Package, Runtime, Service, functions, package};

use crate::event::fields;
use crate::session::{McpServer, Order, Setup};
use crate::{Acp, Threads};

/// The name acp's service registers under, through the runtime.
pub const SERVICE_NAME: &str = "acp";

/// The library, once its init has run: the process's acp service, which
/// reports through the runtime's service and takes children over through
/// the runtime.
pub struct Loaded {
    /// The process's acp service.
    acp: Acp<Service, Threads<Runtime>>,
}

impl Loaded {
    /// The library's init: registers the service `acp` through `runtime`
    /// and makes the process's one [`Acp`] over it, whose connector takes
    /// children over through `runtime`.
    pub fn new(runtime: Runtime) -> Self {
        Self {
            acp: Acp::new(runtime.register(SERVICE_NAME), Threads::new(runtime)),
        }
    }
}

/// The library's service, once its init has run; none before.
fn acp() -> Option<&'static Acp<Service, Threads<Runtime>>> {
    PACKAGE.state().map(|loaded| &loaded.acp)
}

/// A reply as it crosses the boundary, mirrored by the glue's
/// `acp_raw_reply`: `{ acp_lent text; }`.
#[repr(C)]
#[derive(Debug)]
pub struct RawReply {
    /// The reply's text, UTF-8, the encoding `event.rs` defines, lent by
    /// this library until it is handed back through the table's `free`.
    pub text: Lent,
}

/// acp's functions, behind the table's size, mirrored by the glue's
/// `acp_table` in this order.
#[repr(C)]
#[derive(Debug)]
pub struct AcpFunctions {
    /// Opens a new session on a child ([`Acp::open`]).
    pub open: extern "C" fn(request: u64, child: u64, cwd: Bytes<'_>, mcp: Bytes<'_>) -> bool,
    /// Loads a stored session on a child ([`Acp::open`] with
    /// [`Setup::load`]).
    pub load: extern "C" fn(
        request: u64,
        child: u64,
        cwd: Bytes<'_>,
        mcp: Bytes<'_>,
        session: Bytes<'_>,
    ) -> bool,
    /// Waits for a session's next events ([`Acp::next`]).
    pub next: extern "C" fn(request: u64, session: u64) -> bool,
    /// Sends a session a prompt ([`Acp::send`]).
    pub prompt: extern "C" fn(request: u64, session: u64, text: Bytes<'_>) -> bool,
    /// Cancels a session's turn ([`Acp::send`]).
    pub cancel_turn: extern "C" fn(request: u64, session: u64) -> bool,
    /// Sets a session's mode ([`Acp::send`]).
    pub set_mode: extern "C" fn(request: u64, session: u64, id: Bytes<'_>) -> bool,
    /// Answers a parked permission request ([`Acp::answer`]).
    pub answer: extern "C" fn(request: u64, session: u64, ticket: u64, option: Bytes<'_>) -> bool,
    /// Takes a request's reply into a [`RawReply`] ([`Acp::take`]).
    pub take: extern "C" fn(request: u64, out: Out<'_, RawReply>) -> bool,
    /// Withdraws a request ([`Acp::cancel`]).
    pub withdraw: extern "C" fn(request: u64) -> bool,
    /// Asks for a flush ([`Acp::flush`]).
    pub flush: extern "C" fn(request: u64),
    /// Hands back a reply's text, freed by this library's allocator
    /// ([`editor_package::buffer::free`]).
    pub free: extern "C" fn(text: Lent),
}

package! {
    interface 1;

    /// acp's library: its init ([`Loaded::new`]) and its table.
    pub static PACKAGE: Package<Loaded, AcpFunctions> = Package::new(
        Loaded::new,
        AcpFunctions {
            open,
            load,
            next,
            prompt,
            cancel_turn,
            set_mode,
            answer,
            take,
            withdraw,
            flush,
            free: editor_package::buffer::free,
        },
    );
}

/// The text of `bytes`, U+FFFD in place of each invalid sequence; a Lean
/// string is UTF-8.
fn text_of(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// The MCP servers `text` lists, one a line: `server`, then `name=`,
/// `command=`, an `arg=` for each argument and an `env.name=` then
/// `env.value=` for each variable; `None` for a line that is not one.
pub fn servers_of(text: &str) -> Option<Vec<McpServer>> {
    text.lines()
        .filter(|line| !line.is_empty())
        .map(|line| {
            let (kind, named) = fields(line)?;
            if kind != "server" {
                return None;
            }
            let mut server = McpServer {
                name: String::new(),
                command: String::new(),
                arguments: Vec::new(),
                environment: Vec::new(),
            };
            let mut variable = None;
            for (name, value) in named {
                match (name.as_str(), variable.take()) {
                    ("name", None) => server.name = value,
                    ("command", None) => server.command = value,
                    ("arg", None) => server.arguments.push(value),
                    ("env.name", None) => variable = Some(value),
                    ("env.value", Some(key)) => server.environment.push((key, value)),
                    _ => return None,
                }
            }
            variable.is_none().then_some(server)
        })
        .collect()
}

/// The setup of a session in `cwd` with the MCP servers `mcp` lists
/// ([`servers_of`]), loading the session `load` when there is one; `None`
/// when `mcp` does not read.
fn setup_of(cwd: String, mcp: &str, load: Option<String>) -> Option<Setup> {
    Some(Setup {
        cwd,
        servers: servers_of(mcp)?,
        load,
    })
}

functions! {
    /// Opens a new session on the streaming child `child`, in the directory
    /// `cwd`, with the MCP servers `mcp` lists ([`servers_of`]), as the
    /// request `request` ([`Acp::open`]): whether it started.
    extern "C" fn open(request: u64, child: u64, cwd: Bytes<'_>, mcp: Bytes<'_>) -> bool {
        acp().is_some_and(|acp| {
            setup_of(text_of(cwd), &text_of(mcp), None)
                .is_some_and(|setup| acp.open(request, child, setup))
        })
    }

    /// Loads the session whose agent's id is `session` (`session/load`) on
    /// the streaming child `child`, in the directory `cwd`, with the MCP
    /// servers `mcp` lists ([`servers_of`]), as the request `request`
    /// ([`Acp::open`]): whether it started. It completes as an open does,
    /// once the agent has replayed the session's history, which the
    /// session's first `next` takes.
    extern "C" fn load(
        request: u64,
        child: u64,
        cwd: Bytes<'_>,
        mcp: Bytes<'_>,
        session: Bytes<'_>,
    ) -> bool {
        acp().is_some_and(|acp| {
            setup_of(text_of(cwd), &text_of(mcp), Some(text_of(session)))
                .is_some_and(|setup| acp.open(request, child, setup))
        })
    }

    /// Waits for the session `session`'s next events, as the request
    /// `request` ([`Acp::next`]): whether it started.
    extern "C" fn next(request: u64, session: u64) -> bool {
        acp().is_some_and(|acp| acp.next(request, session))
    }

    /// Sends the session `session` a prompt of `text`, as the request
    /// `request` ([`Acp::send`]): whether it started.
    extern "C" fn prompt(request: u64, session: u64, text: Bytes<'_>) -> bool {
        acp().is_some_and(|acp| acp.send(request, session, Order::Prompt(text_of(text))))
    }

    /// Cancels the session `session`'s current turn, as the request
    /// `request` ([`Acp::send`]): whether it started.
    extern "C" fn cancel_turn(request: u64, session: u64) -> bool {
        acp().is_some_and(|acp| acp.send(request, session, Order::Cancel))
    }

    /// Sets the session `session`'s mode to `id`, as the request `request`
    /// ([`Acp::send`]): whether it started.
    extern "C" fn set_mode(request: u64, session: u64, id: Bytes<'_>) -> bool {
        acp().is_some_and(|acp| acp.send(request, session, Order::SetMode(text_of(id))))
    }

    /// Answers the session `session`'s parked permission request `ticket`
    /// with the option `option`, as the request `request` ([`Acp::answer`]):
    /// whether it started.
    extern "C" fn answer(request: u64, session: u64, ticket: u64, option: Bytes<'_>) -> bool {
        acp().is_some_and(|acp| acp.answer(request, session, ticket, &text_of(option)))
    }

    /// Takes the reply to the request `request` ([`Acp::take`]): returns
    /// whether there was one, and if so writes its text to `out`.
    extern "C" fn take(request: u64, out: Out<'_, RawReply>) -> bool {
        let Some(reply) = acp().and_then(|acp| acp.take(request)) else {
            return false;
        };
        out.put(RawReply {
            text: Lent::of(reply.encode().into_bytes()),
        });
        true
    }

    /// Withdraws the request `request` ([`Acp::cancel`]), and returns
    /// whether it was in use.
    extern "C" fn withdraw(request: u64) -> bool {
        acp().is_some_and(|acp| acp.cancel(request))
    }

    /// Asks for `request` to be completed through the runtime once every
    /// `open` and order started before has been ([`Acp::flush`]).
    extern "C" fn flush(request: u64) {
        if let Some(acp) = acp() {
            acp.flush(request);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_server_list_reads_back_with_its_arguments_and_variables_escapes_undone() {
        let servers = servers_of(
            "server\tname=example-server\tcommand=/usr/local/bin/example\targ=--a\targ=b\\tc\tenv.name=KEY\tenv.value=va\\nlue\nserver\tname=bare\tcommand=bare\n",
        );
        assert_eq!(
            servers,
            Some(vec![
                McpServer {
                    name: "example-server".into(),
                    command: "/usr/local/bin/example".into(),
                    arguments: vec!["--a".into(), "b\tc".into()],
                    environment: vec![("KEY".into(), "va\nlue".into())],
                },
                McpServer {
                    name: "bare".into(),
                    command: "bare".into(),
                    arguments: Vec::new(),
                    environment: Vec::new(),
                },
            ])
        );
        assert_eq!(servers_of(""), Some(Vec::new()));
    }

    #[test]
    fn a_load_s_setup_names_the_session_it_loads_and_an_open_s_none() {
        let servers = "server\tname=bare\tcommand=bare\n";
        let bare = McpServer {
            name: "bare".into(),
            command: "bare".into(),
            arguments: Vec::new(),
            environment: Vec::new(),
        };
        assert_eq!(
            setup_of("/work/example".into(), servers, Some("sess-0001".into())),
            Some(Setup {
                cwd: "/work/example".into(),
                servers: vec![bare.clone()],
                load: Some("sess-0001".into()),
            })
        );
        assert_eq!(
            setup_of("/work/example".into(), servers, None),
            Some(Setup {
                cwd: "/work/example".into(),
                servers: vec![bare],
                load: None,
            })
        );
        assert_eq!(
            setup_of("/work/example".into(), "client\tname=x", None),
            None
        );
    }

    #[test]
    fn a_line_that_is_not_a_server_or_a_variable_with_no_value_is_refused() {
        assert_eq!(servers_of("client\tname=x"), None);
        assert_eq!(servers_of("server\tname=x\tenv.name=KEY"), None);
        assert_eq!(servers_of("server\tname=x\tcolour=red"), None);
    }
}
