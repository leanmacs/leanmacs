//! What the session keeps of the agent's `session/update` notifications,
//! made plain: the one place an SDK update becomes the crate's own data.
//!
//! Kept: a chunk of the agent's reply and of the user's message (text
//! only; a loaded session's history replays the user's prompts as the
//! latter, and the conversation decides when to show them), a tool call and
//! its updates, the context window's usage and cost, the session's title,
//! and its current mode. Dropped, as no event the editor shows: the agent's
//! list of commands (`available_commands_update`), its configuration
//! options (`config_option_update`), the agent's thought chunks, plans, and
//! every kind the SDK adds; every `_meta`; any content of a chunk that is
//! not text; and any content of a call that is neither text nor a diff.
//!
//! The agent's non-standard notifications, `auth/status_update` and
//! `_auth/status_update`, never reach here: the session registers no
//! handler for them, and the SDK ignores a notification no handler claims,
//! so nothing formats them; the crate installs no logger, so the SDK's
//! traces go nowhere. `session.rs`'s tests show that no event and no words
//! of the session hold their text.

use agent_client_protocol::v1::schema::{
    ContentBlock, SessionUpdate, ToolCall, ToolCallContent, ToolCallLocation, ToolCallUpdateFields,
};
use serde::Serialize;

use crate::event::{Call, Content, Event};
use crate::merge::Update;

/// What the session keeps of one update.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Note {
    /// An event that stands on its own: a chunk of either side's message,
    /// usage, a title, a mode.
    Event(Event),
    /// A tool call announced, whole.
    Announced(Call),
    /// An update of the tool call of this id.
    Updated(String, Update),
}

/// The protocol's name of `value`, an SDK enum of names (a kind, a status, a
/// stop reason): its serialized text, so the names are the wire's.
pub fn wire_name(value: &impl Serialize) -> String {
    match serde_json::to_value(value) {
        Ok(serde_json::Value::String(name)) => name,
        _ => String::new(),
    }
}

/// The text of a content block, when it is text.
fn text_of(block: &ContentBlock) -> Option<String> {
    match block {
        ContentBlock::Text(text) => Some(text.text.clone()),
        _ => None,
    }
}

/// A call's content, made plain: text and diffs, in order.
pub fn content_of(content: &[ToolCallContent]) -> Vec<Content> {
    content
        .iter()
        .filter_map(|item| match item {
            ToolCallContent::Content(content) => text_of(&content.content).map(Content::Text),
            ToolCallContent::Diff(diff) => Some(Content::Diff {
                path: diff.path.display().to_string(),
                old: diff.old_text.clone(),
                new: diff.new_text.clone(),
            }),
            _ => None,
        })
        .collect()
}

/// A call's locations, made plain.
pub fn locations_of(locations: &[ToolCallLocation]) -> Vec<(String, Option<u32>)> {
    locations
        .iter()
        .map(|location| (location.path.display().to_string(), location.line))
        .collect()
}

/// A raw input as compact JSON text, its keys in the wire's order.
fn raw_text(raw: &serde_json::Value) -> String {
    raw.to_string()
}

/// A tool call as announced, made plain.
pub fn call_of(call: &ToolCall) -> Call {
    Call {
        id: call.tool_call_id.0.to_string(),
        title: call.title.clone(),
        kind: wire_name(&call.kind),
        status: wire_name(&call.status),
        locations: locations_of(&call.locations),
        content: content_of(&call.content),
        raw_input: call.raw_input.as_ref().map(raw_text).unwrap_or_default(),
    }
}

/// A tool call's update, made plain: only the fields it carries.
pub fn update_of(fields: &ToolCallUpdateFields) -> Update {
    Update {
        title: fields.title.clone(),
        kind: fields.kind.as_ref().map(wire_name),
        status: fields.status.as_ref().map(wire_name),
        locations: fields.locations.as_deref().map(locations_of),
        content: fields.content.as_deref().map(content_of),
        raw_input: fields.raw_input.as_ref().map(raw_text),
    }
}

/// What the session keeps of `update`: `None` for a kind it drops.
pub fn note(update: &SessionUpdate) -> Option<Note> {
    match update {
        SessionUpdate::AgentMessageChunk(chunk) => text_of(&chunk.content).map(|text| {
            Note::Event(Event::Chunk {
                message_id: chunk.message_id.as_ref().map(|id| id.0.to_string()),
                text,
            })
        }),
        SessionUpdate::UserMessageChunk(chunk) => text_of(&chunk.content).map(|text| {
            Note::Event(Event::UserChunk {
                message_id: chunk.message_id.as_ref().map(|id| id.0.to_string()),
                text,
            })
        }),
        SessionUpdate::ToolCall(call) => Some(Note::Announced(call_of(call))),
        SessionUpdate::ToolCallUpdate(update) => Some(Note::Updated(
            update.tool_call_id.0.to_string(),
            update_of(&update.fields),
        )),
        SessionUpdate::UsageUpdate(usage) => Some(Note::Event(Event::Usage {
            used: usage.used,
            size: usage.size,
            // The amount in the shortest decimal text that reads back as the
            // same number: the wire's own text for every amount an agent
            // writes with a few decimals.
            cost: usage
                .cost
                .as_ref()
                .map(|cost| (cost.amount.to_string(), cost.currency.clone())),
        })),
        SessionUpdate::SessionInfoUpdate(info) => match &info.title {
            agent_client_protocol::schema::MaybeUndefined::Value(title) => {
                Some(Note::Event(Event::Title(title.clone())))
            }
            _ => None,
        },
        SessionUpdate::CurrentModeUpdate(mode) => {
            Some(Note::Event(Event::Mode(mode.current_mode_id.0.to_string())))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The update a line of a fixture's `session/update` carries.
    fn update(json: &str) -> SessionUpdate {
        serde_json::from_str(json).expect("an update")
    }

    #[test]
    fn the_commands_list_the_config_options_and_thought_chunks_are_dropped() {
        for dropped in [
            r#"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"example-command","description":"An example command.","input":null}]}"#,
            r#"{"sessionUpdate":"config_option_update","configOptions":[]}"#,
            r#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}}"#,
            r#"{"sessionUpdate":"user_message_chunk","content":{"type":"image","data":"AA==","mimeType":"image/png"}}"#,
        ] {
            assert_eq!(note(&update(dropped)), None, "{dropped}");
        }
    }

    #[test]
    fn a_chunk_of_the_user_s_message_is_kept_with_its_message_id_when_given() {
        assert_eq!(
            note(&update(
                r#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Read notes.txt."},"messageId":"msg-u1","_meta":{"example":1}}"#
            )),
            Some(Note::Event(Event::UserChunk {
                message_id: Some("msg-u1".into()),
                text: "Read notes.txt.".into()
            }))
        );
        assert_eq!(
            note(&update(
                r#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"mine"}}"#
            )),
            Some(Note::Event(Event::UserChunk {
                message_id: None,
                text: "mine".into()
            }))
        );
    }

    #[test]
    fn a_chunk_usage_a_title_and_a_mode_are_kept_as_events_their_meta_dropped() {
        assert_eq!(
            note(&update(
                r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."},"messageId":"msg-1","_meta":{"example":1}}"#
            )),
            Some(Note::Event(Event::Chunk {
                message_id: Some("msg-1".into()),
                text: "Done.".into()
            }))
        );
        assert_eq!(
            note(&update(
                r#"{"sessionUpdate":"usage_update","used":1300,"size":200000,"cost":{"amount":0.0123,"currency":"USD"},"_meta":{"example":1}}"#
            )),
            Some(Note::Event(Event::Usage {
                used: 1300,
                size: 200_000,
                cost: Some(("0.0123".into(), "USD".into()))
            }))
        );
        assert_eq!(
            note(&update(
                r#"{"sessionUpdate":"session_info_update","title":"Example title","updatedAt":"2026-01-01T00:00:00Z"}"#
            )),
            Some(Note::Event(Event::Title("Example title".into())))
        );
        assert_eq!(
            note(&update(
                r#"{"sessionUpdate":"current_mode_update","currentModeId":"mode-auto"}"#
            )),
            Some(Note::Event(Event::Mode("mode-auto".into())))
        );
    }

    #[test]
    fn a_tool_call_with_a_name_and_meta_outside_the_schema_is_announced_and_an_update_carries_only_its_fields()
     {
        assert_eq!(
            note(&update(
                r#"{"sessionUpdate":"tool_call","toolCallId":"call-read-1","title":"Read","kind":"read","status":"pending","rawInput":{},"content":[],"locations":[],"name":"Read","_meta":{"example":1}}"#
            )),
            Some(Note::Announced(Call {
                title: "Read".into(),
                kind: "read".into(),
                raw_input: "{}".into(),
                ..Call::empty("call-read-1")
            }))
        );
        assert_eq!(
            note(&update(
                r#"{"sessionUpdate":"tool_call_update","toolCallId":"call-edit-1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"Edited."}},{"type":"diff","path":"/work/example/notes.txt","oldText":"a","newText":"b"}]}"#
            )),
            Some(Note::Updated(
                "call-edit-1".into(),
                Update {
                    status: Some("completed".into()),
                    content: Some(vec![
                        Content::Text("Edited.".into()),
                        Content::Diff {
                            path: "/work/example/notes.txt".into(),
                            old: Some("a".into()),
                            new: "b".into()
                        }
                    ]),
                    ..Update::default()
                }
            ))
        );
    }

    #[test]
    fn a_raw_input_keeps_its_keys_in_the_wire_s_order() {
        let Some(Note::Updated(_, update)) = note(&update(
            r#"{"sessionUpdate":"tool_call_update","toolCallId":"c","rawInput":{"zeta":1,"alpha":"two"}}"#,
        )) else {
            panic!("an update");
        };
        assert_eq!(
            update.raw_input.as_deref(),
            Some(r#"{"zeta":1,"alpha":"two"}"#)
        );
    }
}
