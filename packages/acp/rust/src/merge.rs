//! Merging a tool call's updates into the call the session holds.
//!
//! An agent announces a tool call (`tool_call`) and then updates it
//! (`tool_call_update`), each update carrying only the fields that changed.
//! The session holds each call whole ([`Calls`]) and posts the merged whole
//! each time ([`Event::ToolCall`](crate::event::Event::ToolCall)), so Lean
//! never merges.
//!
//! - **Only the fields present** change the held call.
//! - **Content and locations replace** the held ones when present: a diff
//!   replaces the earlier diff, never appends to it, as the agent sends a
//!   whole-file diff in place of the diff of an edit's strings.
//! - **An update of a call never announced** is merged into an empty call
//!   ([`Call::empty`]), as a permission request's call may be the first the
//!   session hears of it.
//!
//! Plain data only: the session (`session.rs`) makes an [`Update`] of the
//! SDK's update.

use std::collections::HashMap;

use crate::event::{Call, Content};

/// The fields of a tool call an update carries: each `None` when absent.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Update {
    /// A new title.
    pub title: Option<String>,
    /// A new kind.
    pub kind: Option<String>,
    /// A new status.
    pub status: Option<String>,
    /// New locations, in place of the held ones.
    pub locations: Option<Vec<(String, Option<u32>)>>,
    /// New content, in place of the held one.
    pub content: Option<Vec<Content>>,
    /// A new raw input, as compact JSON text.
    pub raw_input: Option<String>,
}

impl Update {
    /// `call` with this update's fields merged in.
    pub fn merged(self, mut call: Call) -> Call {
        if let Some(title) = self.title {
            call.title = title;
        }
        if let Some(kind) = self.kind {
            call.kind = kind;
        }
        if let Some(status) = self.status {
            call.status = status;
        }
        if let Some(locations) = self.locations {
            call.locations = locations;
        }
        if let Some(content) = self.content {
            call.content = content;
        }
        if let Some(raw_input) = self.raw_input {
            call.raw_input = raw_input;
        }
        call
    }
}

/// The tool calls a session holds, by id.
#[derive(Debug, Default)]
pub struct Calls {
    /// The calls.
    held: HashMap<String, Call>,
}

impl Calls {
    /// No call held.
    pub fn new() -> Self {
        Self::default()
    }

    /// Holds `call` as announced, in place of any call of its id, and gives
    /// it back.
    pub fn announce(&mut self, call: Call) -> Call {
        self.held.insert(call.id.clone(), call.clone());
        call
    }

    /// Merges `update` into the call `id`, or into an empty call of `id` if
    /// none is held, holds the result and gives it back.
    pub fn update(&mut self, id: &str, update: Update) -> Call {
        let call = self.held.remove(id).unwrap_or_else(|| Call::empty(id));
        let merged = update.merged(call);
        self.held.insert(id.to_owned(), merged.clone());
        merged
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The read call of the plain fixture, as the agent announces it: empty
    /// but for its id and kind.
    fn announced() -> Call {
        Call {
            kind: "read".into(),
            ..Call::empty("call-read-1")
        }
    }

    #[test]
    fn an_empty_call_grows_its_raw_input_then_gains_a_title_and_locations_then_completes() {
        let mut calls = Calls::new();
        calls.announce(announced());
        let grown = calls.update(
            "call-read-1",
            Update {
                raw_input: Some(r#"{"file_path":"/work/example/notes.txt"}"#.into()),
                ..Update::default()
            },
        );
        assert_eq!(
            grown.raw_input,
            r#"{"file_path":"/work/example/notes.txt"}"#
        );
        assert_eq!(grown.kind, "read", "a field absent is kept");
        let titled = calls.update(
            "call-read-1",
            Update {
                title: Some("Read notes.txt".into()),
                locations: Some(vec![("/work/example/notes.txt".into(), None)]),
                ..Update::default()
            },
        );
        assert_eq!(titled.title, "Read notes.txt");
        assert_eq!(titled.raw_input, grown.raw_input);
        let completed = calls.update(
            "call-read-1",
            Update {
                status: Some("completed".into()),
                content: Some(vec![Content::Text("Example notes.".into())]),
                ..Update::default()
            },
        );
        assert_eq!(
            completed,
            Call {
                id: "call-read-1".into(),
                title: "Read notes.txt".into(),
                kind: "read".into(),
                status: "completed".into(),
                locations: vec![("/work/example/notes.txt".into(), None)],
                content: vec![Content::Text("Example notes.".into())],
                raw_input: r#"{"file_path":"/work/example/notes.txt"}"#.into(),
            }
        );
    }

    #[test]
    fn a_second_diff_replaces_the_first_and_new_locations_replace_the_old() {
        let mut calls = Calls::new();
        calls.announce(Call {
            kind: "edit".into(),
            ..Call::empty("call-edit-1")
        });
        calls.update(
            "call-edit-1",
            Update {
                content: Some(vec![Content::Diff {
                    path: "/work/example/notes.txt".into(),
                    old: Some("old words".into()),
                    new: "new words".into(),
                }]),
                locations: Some(vec![("/work/example/notes.txt".into(), None)]),
                ..Update::default()
            },
        );
        let replaced = calls.update(
            "call-edit-1",
            Update {
                content: Some(vec![Content::Diff {
                    path: "/work/example/notes.txt".into(),
                    old: Some("Example notes.\nold words\n".into()),
                    new: "Example notes.\nnew words\n".into(),
                }]),
                locations: Some(vec![("/work/example/notes.txt".into(), Some(2))]),
                ..Update::default()
            },
        );
        assert_eq!(
            replaced.content,
            vec![Content::Diff {
                path: "/work/example/notes.txt".into(),
                old: Some("Example notes.\nold words\n".into()),
                new: "Example notes.\nnew words\n".into(),
            }],
            "the whole-file diff replaced the strings' diff"
        );
        assert_eq!(
            replaced.locations,
            vec![("/work/example/notes.txt".into(), Some(2))]
        );
    }

    #[test]
    fn an_update_of_a_call_never_announced_is_merged_into_an_empty_call() {
        let mut calls = Calls::new();
        let merged = calls.update(
            "call-edit-2",
            Update {
                title: Some("Edit notes.txt again".into()),
                kind: Some("edit".into()),
                ..Update::default()
            },
        );
        assert_eq!(
            merged,
            Call {
                title: "Edit notes.txt again".into(),
                kind: "edit".into(),
                ..Call::empty("call-edit-2")
            }
        );
    }

    #[test]
    fn an_announcement_replaces_a_held_call_of_its_id() {
        let mut calls = Calls::new();
        calls.update(
            "call-1",
            Update {
                title: Some("old".into()),
                ..Update::default()
            },
        );
        calls.announce(Call::empty("call-1"));
        let merged = calls.update("call-1", Update::default());
        assert_eq!(merged, Call::empty("call-1"));
    }
}
