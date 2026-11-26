//! The plain events a session produces, and the text they cross the C
//! boundary as: one event a line, which `agents-api`'s `Event` mirrors and
//! `acp`'s Lean library decodes (`Acp/Codec.lean`).
//!
//! # The encoding
//!
//! A line is a kind word, then tab-separated `name=value` fields. A value
//! escapes `\` as `\\`, a tab as `\t`, a line feed as `\n` and a carriage
//! return as `\r`, so a line holds no tab but between fields and no line
//! feed at all. A list repeats its fields in order, each item starting with
//! the same field: `location.path=` (then `location.line=` when it has
//! one), `content.text=` or `diff.path=` (then `diff.old=` when the file
//! existed, and `diff.new=`), `option.id=` (then `option.name=` and
//! `option.kind=`), `mode.id=` (then `mode.name=`, and `mode.description=`
//! when there is one). An optional field is left out when absent.
//!
//! The same golden lines are held as literals in this module's tests and in
//! `AcpTest/Acp/Codec.lean`, so the two sides cannot drift; and the replay
//! fixtures' expected files (`tests/fixtures/*.events`) are in this
//! encoding, so a fixture pins the bytes Lean decodes.
//!
//! No SDK type is here: the session (`session.rs`) makes these from the
//! SDK's.

use std::fmt::Write as _;

/// One item of a tool call's content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Content {
    /// Text the tool produced.
    Text(String),
    /// An edit of a file.
    Diff {
        /// The file's path.
        path: String,
        /// Its text before; none for a new file.
        old: Option<String>,
        /// Its text after.
        new: String,
    },
}

/// A tool call, with every update so far merged in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Call {
    /// The agent's id for it.
    pub id: String,
    /// What it does, as the agent words it.
    pub title: String,
    /// Its kind, as the protocol names it.
    pub kind: String,
    /// Its status, as the protocol names it.
    pub status: String,
    /// The places it touches: a path and, when given, a line.
    pub locations: Vec<(String, Option<u32>)>,
    /// What it produced.
    pub content: Vec<Content>,
    /// Its raw input, as compact JSON text; empty when none was sent.
    pub raw_input: String,
}

impl Call {
    /// A call of `id` that holds nothing yet: what an update of a call never
    /// announced is merged into.
    pub fn empty(id: &str) -> Self {
        Self {
            id: id.to_owned(),
            title: String::new(),
            kind: "other".to_owned(),
            status: "pending".to_owned(),
            locations: Vec::new(),
            content: Vec::new(),
            raw_input: String::new(),
        }
    }
}

/// One way to answer a permission request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PermissionOption {
    /// The id an answer names.
    pub id: String,
    /// What it is called.
    pub name: String,
    /// Its kind, as the protocol names it.
    pub kind: String,
}

/// How a session ended by itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ending {
    /// The agent exited with this status.
    Exited(i32),
    /// The agent was ended by this signal.
    Signalled(i32),
    /// A line was longer than the bound.
    LineTooLong,
    /// A read failed, or the child was ended by its job: the words.
    Failed(String),
    /// The connection failed: what the SDK said.
    ProtocolError(String),
}

/// One thing a session produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// A chunk of the agent's reply.
    Chunk {
        /// The agent's id of the message, when given.
        message_id: Option<String>,
        /// The text.
        text: String,
    },
    /// A tool call, whole.
    ToolCall(Call),
    /// A permission request, parked.
    Permission {
        /// Its ticket.
        ticket: u64,
        /// The turn it came in; none before the first prompt.
        turn: Option<u64>,
        /// The call it asks about, merged.
        call: Call,
        /// The ways to answer it.
        options: Vec<PermissionOption>,
    },
    /// A permission request answered `cancelled` by the client.
    Withdrawn {
        /// Its ticket.
        ticket: u64,
    },
    /// The context window's use, and the cost so far.
    Usage {
        /// Tokens used.
        used: u64,
        /// The window's size.
        size: u64,
        /// The cost: the amount as decimal text, and the currency.
        cost: Option<(String, String)>,
    },
    /// The session's title.
    Title(String),
    /// The session's current mode.
    Mode(String),
    /// A prompt turn ended.
    TurnEnded {
        /// The turn.
        turn: u64,
        /// The protocol's stop reason.
        stop_reason: String,
    },
    /// The session ended by itself: its last event.
    Ended(Ending),
}

/// A mode a session can be in, as `session/new` reported it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mode {
    /// Its id.
    pub id: String,
    /// What it is called.
    pub name: String,
    /// What it does, when the agent said.
    pub description: Option<String>,
}

/// What `open` answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opened {
    /// The service's number for the session.
    pub session: u64,
    /// The agent's session id.
    pub session_id: String,
    /// The current mode, when the agent reports modes.
    pub mode: Option<String>,
    /// The modes.
    pub modes: Vec<Mode>,
}

/// A request's reply, as it crosses the C boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reply {
    /// The session opened.
    Opened(Opened),
    /// A `next`'s events, at least one.
    Batch(Vec<Event>),
    /// An order on its way; a prompt's turn.
    Sent(Option<u64>),
    /// Why the request was not answered.
    Refused(String),
}

/// `value` escaped for a field.
pub fn escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '\\' => escaped.push_str("\\\\"),
            '\t' => escaped.push_str("\\t"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            other => escaped.push(other),
        }
    }
    escaped
}

/// `value` with its escapes undone; `None` for a backslash that starts no
/// escape.
pub fn unescape(value: &str) -> Option<String> {
    let mut plain = String::with_capacity(value.len());
    let mut characters = value.chars();
    while let Some(character) = characters.next() {
        if character == '\\' {
            plain.push(match characters.next()? {
                '\\' => '\\',
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                _ => return None,
            });
        } else {
            plain.push(character);
        }
    }
    Some(plain)
}

/// A line's kind word and its fields, in order, their values unescaped;
/// `None` for a field with no `=` or a bad escape.
pub fn fields(line: &str) -> Option<(String, Vec<(String, String)>)> {
    let mut parts = line.split('\t');
    let kind = parts.next()?.to_owned();
    let named = parts
        .map(|part| {
            let (name, value) = part.split_once('=')?;
            Some((name.to_owned(), unescape(value)?))
        })
        .collect::<Option<Vec<_>>>()?;
    Some((kind, named))
}

/// A line under construction: a kind word and its fields.
struct Line(String);

impl Line {
    /// A line of the kind `kind`.
    fn of(kind: &str) -> Self {
        Self(kind.to_owned())
    }

    /// Adds the field `name` of `value`.
    fn field(&mut self, name: &str, value: impl std::fmt::Display) -> &mut Self {
        let _ = write!(self.0, "\t{name}={}", escape(&value.to_string()));
        self
    }

    /// Adds the field `name` of `value`, when there is one.
    fn optional(&mut self, name: &str, value: Option<impl std::fmt::Display>) -> &mut Self {
        if let Some(value) = value {
            self.field(name, value);
        }
        self
    }

    /// Adds a tool call's fields.
    fn call(&mut self, call: &Call) -> &mut Self {
        self.field("id", &call.id)
            .field("title", &call.title)
            .field("kind", &call.kind)
            .field("status", &call.status);
        for (path, line) in &call.locations {
            self.field("location.path", path)
                .optional("location.line", *line);
        }
        for item in &call.content {
            match item {
                Content::Text(text) => {
                    self.field("content.text", text);
                }
                Content::Diff { path, old, new } => {
                    self.field("diff.path", path)
                        .optional("diff.old", old.as_ref())
                        .field("diff.new", new);
                }
            }
        }
        self.field("rawInput", &call.raw_input)
    }

    /// The line.
    fn done(&mut self) -> String {
        std::mem::take(&mut self.0)
    }
}

impl Event {
    /// The event's line.
    pub fn encode(&self) -> String {
        match self {
            Self::Chunk { message_id, text } => Line::of("chunk")
                .optional("message", message_id.as_ref())
                .field("text", text)
                .done(),
            Self::ToolCall(call) => Line::of("toolCall").call(call).done(),
            Self::Permission {
                ticket,
                turn,
                call,
                options,
            } => {
                let mut line = Line::of("permission");
                line.field("ticket", ticket)
                    .optional("turn", *turn)
                    .call(call);
                for option in options {
                    line.field("option.id", &option.id)
                        .field("option.name", &option.name)
                        .field("option.kind", &option.kind);
                }
                line.done()
            }
            Self::Withdrawn { ticket } => Line::of("withdrawn").field("ticket", ticket).done(),
            Self::Usage { used, size, cost } => {
                let mut line = Line::of("usage");
                line.field("used", used).field("size", size);
                if let Some((amount, currency)) = cost {
                    line.field("cost.amount", amount)
                        .field("cost.currency", currency);
                }
                line.done()
            }
            Self::Title(text) => Line::of("title").field("text", text).done(),
            Self::Mode(id) => Line::of("mode").field("id", id).done(),
            Self::TurnEnded { turn, stop_reason } => Line::of("turnEnded")
                .field("turn", turn)
                .field("stopReason", stop_reason)
                .done(),
            Self::Ended(ending) => {
                let mut line = Line::of("ended");
                match ending {
                    Ending::Exited(code) => line.field("how", "exited").field("code", code),
                    Ending::Signalled(signal) => {
                        line.field("how", "signalled").field("signal", signal)
                    }
                    Ending::LineTooLong => line.field("how", "lineTooLong"),
                    Ending::Failed(words) => line.field("how", "failed").field("words", words),
                    Ending::ProtocolError(words) => {
                        line.field("how", "protocolError").field("words", words)
                    }
                };
                line.done()
            }
        }
    }
}

impl Reply {
    /// The reply's text: one line, but a batch's, which is its events' lines
    /// joined by line feeds.
    pub fn encode(&self) -> String {
        match self {
            Self::Opened(opened) => {
                let mut line = Line::of("opened");
                line.field("session", opened.session)
                    .field("sessionId", &opened.session_id)
                    .optional("mode", opened.mode.as_ref());
                for mode in &opened.modes {
                    line.field("mode.id", &mode.id)
                        .field("mode.name", &mode.name)
                        .optional("mode.description", mode.description.as_ref());
                }
                line.done()
            }
            Self::Batch(events) => events
                .iter()
                .map(Event::encode)
                .collect::<Vec<_>>()
                .join("\n"),
            Self::Sent(turn) => Line::of("sent").optional("turn", *turn).done(),
            Self::Refused(reason) => Line::of("refused").field("reason", reason).done(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A call with every kind of field, an escape in its title.
    fn call() -> Call {
        Call {
            id: "call-edit-1".into(),
            title: "Edit\tnotes.txt".into(),
            kind: "edit".into(),
            status: "pending".into(),
            locations: vec![
                ("/work/example/notes.txt".into(), None),
                ("/work/example/b.txt".into(), Some(3)),
            ],
            content: vec![
                Content::Text("line one\nline two".into()),
                Content::Diff {
                    path: "/work/example/notes.txt".into(),
                    old: Some("a\\b".into()),
                    new: "c\r\n".into(),
                },
                Content::Diff {
                    path: "/work/example/new.txt".into(),
                    old: None,
                    new: "fresh".into(),
                },
            ],
            raw_input: r#"{"path":"/work/example/notes.txt"}"#.into(),
        }
    }

    // The golden lines: the same literals are in `AcpTest/Acp/Codec.lean`.

    #[test]
    fn each_event_encodes_to_its_golden_line() {
        let cases: Vec<(Event, &str)> = vec![
            (
                Event::Chunk {
                    message_id: Some("msg-1".into()),
                    text: "Done.".into(),
                },
                "chunk\tmessage=msg-1\ttext=Done.",
            ),
            (
                Event::Chunk {
                    message_id: None,
                    text: "a\tb".into(),
                },
                "chunk\ttext=a\\tb",
            ),
            (
                Event::ToolCall(call()),
                "toolCall\tid=call-edit-1\ttitle=Edit\\tnotes.txt\tkind=edit\tstatus=pending\tlocation.path=/work/example/notes.txt\tlocation.path=/work/example/b.txt\tlocation.line=3\tcontent.text=line one\\nline two\tdiff.path=/work/example/notes.txt\tdiff.old=a\\\\b\tdiff.new=c\\r\\n\tdiff.path=/work/example/new.txt\tdiff.new=fresh\trawInput={\"path\":\"/work/example/notes.txt\"}",
            ),
            (
                Event::Permission {
                    ticket: 1,
                    turn: Some(1),
                    call: Call::empty("call-2"),
                    options: vec![PermissionOption {
                        id: "allow-once".into(),
                        name: "Allow".into(),
                        kind: "allow_once".into(),
                    }],
                },
                "permission\tticket=1\tturn=1\tid=call-2\ttitle=\tkind=other\tstatus=pending\trawInput=\toption.id=allow-once\toption.name=Allow\toption.kind=allow_once",
            ),
            (Event::Withdrawn { ticket: 2 }, "withdrawn\tticket=2"),
            (
                Event::Usage {
                    used: 1200,
                    size: 200_000,
                    cost: None,
                },
                "usage\tused=1200\tsize=200000",
            ),
            (
                Event::Usage {
                    used: 1300,
                    size: 200_000,
                    cost: Some(("0.0123".into(), "USD".into())),
                },
                "usage\tused=1300\tsize=200000\tcost.amount=0.0123\tcost.currency=USD",
            ),
            (
                Event::Title("Example title".into()),
                "title\ttext=Example title",
            ),
            (Event::Mode("mode-auto".into()), "mode\tid=mode-auto"),
            (
                Event::TurnEnded {
                    turn: 1,
                    stop_reason: "end_turn".into(),
                },
                "turnEnded\tturn=1\tstopReason=end_turn",
            ),
            (Event::Ended(Ending::Exited(0)), "ended\thow=exited\tcode=0"),
            (
                Event::Ended(Ending::Signalled(9)),
                "ended\thow=signalled\tsignal=9",
            ),
            (Event::Ended(Ending::LineTooLong), "ended\thow=lineTooLong"),
            (
                Event::Ended(Ending::Failed("gone".into())),
                "ended\thow=failed\twords=gone",
            ),
            (
                Event::Ended(Ending::ProtocolError("bad".into())),
                "ended\thow=protocolError\twords=bad",
            ),
        ];
        for (event, line) in cases {
            assert_eq!(event.encode(), line, "{event:?}");
        }
    }

    #[test]
    fn each_reply_encodes_to_its_golden_line() {
        let opened = Reply::Opened(Opened {
            session: 1,
            session_id: "sess-0001".into(),
            mode: Some("mode-ask".into()),
            modes: vec![
                Mode {
                    id: "mode-ask".into(),
                    name: "Ask".into(),
                    description: Some("Asks first".into()),
                },
                Mode {
                    id: "mode-auto".into(),
                    name: "Auto".into(),
                    description: None,
                },
            ],
        });
        assert_eq!(
            opened.encode(),
            "opened\tsession=1\tsessionId=sess-0001\tmode=mode-ask\tmode.id=mode-ask\tmode.name=Ask\tmode.description=Asks first\tmode.id=mode-auto\tmode.name=Auto"
        );
        assert_eq!(Reply::Sent(Some(2)).encode(), "sent\tturn=2");
        assert_eq!(Reply::Sent(None).encode(), "sent");
        assert_eq!(
            Reply::Refused("no\nsuch".into()).encode(),
            "refused\treason=no\\nsuch"
        );
        assert_eq!(
            Reply::Batch(vec![
                Event::Withdrawn { ticket: 2 },
                Event::Title("t".into())
            ])
            .encode(),
            "withdrawn\tticket=2\ntitle\ttext=t"
        );
    }

    #[test]
    fn an_escaped_value_holds_no_tab_and_no_line_feed_and_reads_back() {
        let escaped = escape("a\tb\nc\rd\\e");
        assert_eq!(escaped, "a\\tb\\nc\\rd\\\\e");
        assert!(!escaped.contains(['\t', '\n', '\r']));
        assert_eq!(unescape(&escaped).as_deref(), Some("a\tb\nc\rd\\e"));
        assert_eq!(unescape("bad\\x"), None);
    }

    #[test]
    fn a_line_reads_back_as_its_kind_and_fields() {
        assert_eq!(
            fields("usage\tused=1\tcost.currency=U\\tSD"),
            Some((
                "usage".to_owned(),
                vec![
                    ("used".to_owned(), "1".to_owned()),
                    ("cost.currency".to_owned(), "U\tSD".to_owned())
                ]
            ))
        );
        assert_eq!(fields("usage\tused"), None);
    }
}
