//! The C functions the package's glue (`ffi/glue.c`) calls: the process's
//! one [`Acp`] over the real completer and the real connector, the service
//! [`SERVICE`], whose completions go to the process's completion queue,
//! which the editor's completion pump reads.
//!
//! Plain data only, as `editor-ffi`'s bindings are: a text crosses as a
//! pointer and a length, borrowed for the call
//! ([`editor_service::buffer::borrow`]); a reply crosses as one [`RawReply`]
//! filled in one call, its text the encoding `event.rs` defines, whose
//! buffer the caller hands back with [`acp_ffi_free`]. A session's MCP
//! servers cross as text too, one server a line ([`servers_of`]).

use std::sync::LazyLock;

use editor_service::Service;
use editor_service::buffer;

use crate::event::fields;
use crate::session::{McpServer, Order, Setup};
use crate::{Acp, Threads};

/// The service, as the completion queue names it.
pub static SERVICE: Service = Service::named("acp");

/// The process's service.
pub(crate) static ACP: LazyLock<Acp<&'static Service, Threads>> =
    LazyLock::new(|| Acp::new(&SERVICE, Threads::new()));

/// A reply as it crosses the boundary.
#[repr(C)]
pub struct RawReply {
    /// The reply's text: a buffer of `text_len` bytes of UTF-8, owned by the
    /// caller until it is handed back with [`acp_ffi_free`].
    pub text: *mut u8,
    /// The length of `text` in bytes.
    pub text_len: usize,
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

/// The text of `len` bytes at `text`, U+FFFD in place of each invalid
/// sequence; a Lean string is UTF-8.
///
/// # Safety
///
/// `text` points to `len` readable bytes.
unsafe fn text_of(text: *const u8, len: usize) -> String {
    // SAFETY: the caller guarantees the pointer and the length.
    String::from_utf8_lossy(unsafe { buffer::borrow(text, len) }).into_owned()
}

/// Opens a session on the streaming child `child`, in the directory of the
/// `cwd_len` bytes at `cwd`, with the MCP servers the `mcp_len` bytes at
/// `mcp` list ([`servers_of`]), as the request `request` ([`Acp::open`]):
/// whether it started.
///
/// # Safety
///
/// `cwd` points to `cwd_len` readable bytes, and `mcp` to `mcp_len`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acp_ffi_open(
    request: u64,
    child: u64,
    cwd: *const u8,
    cwd_len: usize,
    mcp: *const u8,
    mcp_len: usize,
) -> bool {
    // SAFETY: the caller guarantees both pointers and lengths.
    let (cwd, mcp) = unsafe { (text_of(cwd, cwd_len), text_of(mcp, mcp_len)) };
    let Some(servers) = servers_of(&mcp) else {
        return false;
    };
    ACP.open(request, child, Setup { cwd, servers })
}

/// Waits for the session `session`'s next events, as the request
/// `request` ([`Acp::next`]): whether it started.
#[unsafe(no_mangle)]
pub extern "C" fn acp_ffi_next(request: u64, session: u64) -> bool {
    ACP.next(request, session)
}

/// Sends the session `session` a prompt of the `len` bytes at `text`, as the
/// request `request` ([`Acp::send`]): whether it started.
///
/// # Safety
///
/// `text` points to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acp_ffi_prompt(
    request: u64,
    session: u64,
    text: *const u8,
    len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let text = unsafe { text_of(text, len) };
    ACP.send(request, session, Order::Prompt(text))
}

/// Cancels the session `session`'s current turn, as the request `request`
/// ([`Acp::send`]): whether it started.
#[unsafe(no_mangle)]
pub extern "C" fn acp_ffi_cancel_turn(request: u64, session: u64) -> bool {
    ACP.send(request, session, Order::Cancel)
}

/// Sets the session `session`'s mode to the `len` bytes at `id`, as the
/// request `request` ([`Acp::send`]): whether it started.
///
/// # Safety
///
/// `id` points to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acp_ffi_set_mode(
    request: u64,
    session: u64,
    id: *const u8,
    len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let id = unsafe { text_of(id, len) };
    ACP.send(request, session, Order::SetMode(id))
}

/// Answers the session `session`'s parked permission request `ticket` with
/// the option of the `len` bytes at `option`, as the request `request`
/// ([`Acp::answer`]): whether it started.
///
/// # Safety
///
/// `option` points to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acp_ffi_answer(
    request: u64,
    session: u64,
    ticket: u64,
    option: *const u8,
    len: usize,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let option = unsafe { text_of(option, len) };
    ACP.answer(request, session, ticket, &option)
}

/// Takes the reply to the request `request` ([`Acp::take`]): returns whether
/// there was one, and if so fills `out` with its text.
///
/// # Safety
///
/// `out` points to a writable [`RawReply`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acp_ffi_take(request: u64, out: *mut RawReply) -> bool {
    let Some(reply) = ACP.take(request) else {
        return false;
    };
    let (text, text_len) = buffer::lend(reply.encode().into_bytes());
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawReply { text, text_len }) };
    true
}

/// Withdraws the request `request` ([`Acp::cancel`]), and returns whether it
/// was in use.
#[unsafe(no_mangle)]
pub extern "C" fn acp_ffi_withdraw(request: u64) -> bool {
    ACP.cancel(request)
}

/// Asks for `request` to be completed on the completion queue once every
/// `open` and order started before has been ([`Acp::flush`]).
#[unsafe(no_mangle)]
pub extern "C" fn acp_ffi_flush(request: u64) {
    ACP.flush(request);
}

/// Takes back a buffer a [`RawReply`] lent, and frees it.
///
/// # Safety
///
/// `text` and `len` are the pointer and length of a reply's text, which has
/// not been handed back and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn acp_ffi_free(text: *mut u8, len: usize) {
    // SAFETY: the caller guarantees the buffer was lent and is handed back
    // once.
    unsafe { buffer::reclaim(text, len) };
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
    fn a_line_that_is_not_a_server_or_a_variable_with_no_value_is_refused() {
        assert_eq!(servers_of("client\tname=x"), None);
        assert_eq!(servers_of("server\tname=x\tenv.name=KEY"), None);
        assert_eq!(servers_of("server\tname=x\tcolour=red"), None);
    }
}
