//! The ports' fakes, published for this crate's tests and for any crate
//! that drives the core: an environment that is a map ([`FakeEnv`]) and a
//! process that records each invocation and answers from a closure
//! ([`RecordingProcess`]).
//!
//! [`contract::answers`](crate::contract::answers) is what the system does
//! with each of the contract's invocations, so the contract runs on a
//! [`RecordingProcess`] over it as on the real adapter.

use std::collections::HashMap;
use std::ffi::OsString;

use crate::ports::{Env, Invocation, Process, RunError};

/// An environment that is a map of names to values; a name it does not
/// hold is unset.
#[derive(Debug, Clone, Default)]
pub struct FakeEnv(pub HashMap<String, OsString>);

impl FakeEnv {
    /// This environment with `name` set to `value`.
    #[must_use]
    pub fn with(mut self, name: &str, value: impl Into<OsString>) -> Self {
        self.0.insert(name.to_owned(), value.into());
        self
    }
}

impl Env for FakeEnv {
    fn var(&self, name: &str) -> Option<OsString> {
        self.0.get(name).cloned()
    }
}

/// A process that records every invocation, in order, and answers each
/// with what `respond` returns for it.
pub struct RecordingProcess<F> {
    /// Every invocation run, in order.
    pub runs: Vec<Invocation>,
    respond: F,
}

impl<F> RecordingProcess<F>
where
    F: FnMut(&Invocation) -> Result<Vec<u8>, RunError>,
{
    /// A process that has run nothing yet.
    pub fn new(respond: F) -> Self {
        Self {
            runs: Vec::new(),
            respond,
        }
    }
}

impl<F> Process for RecordingProcess<F>
where
    F: FnMut(&Invocation) -> Result<Vec<u8>, RunError>,
{
    fn run(&mut self, invocation: &Invocation) -> Result<Vec<u8>, RunError> {
        self.runs.push(invocation.clone());
        (self.respond)(invocation)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fake_env_holds_what_it_was_given_and_nothing_else() {
        let env = FakeEnv::default().with("A", "1");
        assert_eq!(env.var("A"), Some("1".into()));
        assert_eq!(env.var("B"), None);
    }

    #[test]
    fn the_recording_process_records_in_order_and_answers_from_its_closure() {
        let mut process = RecordingProcess::new(|i: &Invocation| {
            if i.program == "true" {
                Ok(Vec::new())
            } else {
                Err(RunError::Failed(Some(1)))
            }
        });
        assert_eq!(process.run(&Invocation::new("true")), Ok(Vec::new()));
        assert_eq!(
            process.run(&Invocation::new("false")),
            Err(RunError::Failed(Some(1)))
        );
        assert_eq!(
            process.runs,
            vec![Invocation::new("true"), Invocation::new("false")]
        );
    }
}
