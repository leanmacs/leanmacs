//! The URL opener port: a URL handed to the system's handler for it, the
//! default browser for `https:`, with a fake and a contract.
//!
//! A [`UrlOpener`] is what a system opener can do, and no more: it is handed
//! a URL and says whether the system took it. Which URLs the editor opens,
//! and when, is not decided here: a link's target is checked and followed
//! in Lean (`lean/Editor/Links.lean`), which hands a URL to a job that asks
//! this port, since an open may block until the system has the request.
//! `editor-platform-open` is the real adapter.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Something more an open says (the application to open it with) | An argument of [`UrlOpener::open`], as data | The fakes' tests here, and a property of [`contract`] if every opener must keep it |
//! | A rule every opener keeps | A property of [`contract`] | Its own tests, on the fakes and on openers written to break it |
//!
//! # Where the real adapter is held to the contract
//!
//! The contract holds only what an opener can be held to without launching
//! anything: a URL that holds a NUL byte cannot be handed to the system and
//! is refused with a reason. [`RecordingOpener`] keeps that rule too, so the
//! fake accepts nothing the system refuses. Everything above the port is
//! tested on [`RecordingOpener`] and [`FailingOpener`]; the real adapter runs
//! [`contract::check`] in its own tests, where the refusal comes before any
//! program starts. That a well-formed URL reaches the desktop's handler is
//! the adapter's one call into its library, held by review: any other run
//! would open a browser on the machine running the gate.

use std::error::Error;
use std::fmt;
use std::sync::{Mutex, MutexGuard, PoisonError};

/// Why a URL could not be handed to the system.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UrlOpenError {
    /// The reason, in the opener's words.
    pub reason: String,
}

impl fmt::Display for UrlOpenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.reason)
    }
}

impl Error for UrlOpenError {}

/// The port: something that hands a URL to the system's handler for it.
///
/// The rules every implementation keeps are [`contract::check`].
pub trait UrlOpener: Send + Sync {
    /// Hands `url` to the system's handler for it. `Ok` once the system has
    /// taken it, which says nothing of whether a program then opened it.
    fn open(&self, url: &str) -> Result<(), UrlOpenError>;
}

/// The reason the fakes refuse a URL that holds a NUL byte with, as the
/// system does.
const NUL_REASON: &str = "a URL holding a NUL byte cannot be handed to the system";

/// The recording fake: each URL it is handed, kept in order, and never the
/// system's.
///
/// It refuses a URL that holds a NUL byte, as the system does, and records
/// nothing for it, so it keeps [`contract::check`]. It is public, not
/// `cfg(test)`, so the tests of any crate above the port run on it.
#[derive(Debug, Default)]
pub struct RecordingOpener {
    /// The URLs taken, in order.
    opened: Mutex<Vec<String>>,
}

impl RecordingOpener {
    /// An opener that has been handed nothing.
    pub fn new() -> Self {
        Self::default()
    }

    /// The URLs it has taken, in the order it was handed them.
    pub fn opened(&self) -> Vec<String> {
        self.urls().clone()
    }

    /// Locks the URLs. The lock is never held while other code runs, so a
    /// poisoned lock still guards a whole value.
    fn urls(&self) -> MutexGuard<'_, Vec<String>> {
        self.opened.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl UrlOpener for RecordingOpener {
    fn open(&self, url: &str) -> Result<(), UrlOpenError> {
        if url.contains('\0') {
            return Err(UrlOpenError {
                reason: NUL_REASON.to_owned(),
            });
        }
        self.urls().push(url.to_owned());
        Ok(())
    }
}

/// The failing fake: an opener whose every open fails with the one reason
/// it was made with.
///
/// It is public, not `cfg(test)`, so a crate above the port tests what it
/// does when the system refuses, as a desktop with no handler for a scheme
/// can, without a desktop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailingOpener {
    /// The reason every open fails with.
    reason: String,
}

impl FailingOpener {
    /// An opener whose every open fails with `reason`.
    pub fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }
}

impl UrlOpener for FailingOpener {
    fn open(&self, _url: &str) -> Result<(), UrlOpenError> {
        Err(UrlOpenError {
            reason: self.reason.clone(),
        })
    }
}

pub mod contract {
    //! The contract of the URL opener port: the rules every [`UrlOpener`]
    //! keeps, as a check that runs one.
    //!
    //! [`check`] hands the opener only URLs the system refuses before it
    //! starts anything, so it launches nothing, on a real opener too.

    use super::UrlOpener;

    /// A URL that holds a NUL byte is refused, with a reason that is not
    /// empty.
    pub const NUL_REFUSED: &str =
        "a URL that holds a NUL byte is refused, with a reason that is not empty";

    /// Every property, by name.
    pub const PROPERTIES: [&str; 1] = [NUL_REFUSED];

    /// Holds `opener` to the contract, and returns the names of the
    /// properties that fail: none when it keeps them all.
    pub fn check(opener: &impl UrlOpener) -> Vec<&'static str> {
        let nul_refused = matches!(
            opener.open("https://example.com/\0held"),
            Err(error) if !error.reason.is_empty()
        );
        [(NUL_REFUSED, nul_refused)]
            .into_iter()
            .filter_map(|(name, holds)| (!holds).then_some(name))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::contract::{self, NUL_REFUSED, PROPERTIES};
    use super::{FailingOpener, RecordingOpener, UrlOpenError, UrlOpener};

    #[test]
    fn a_recording_opener_keeps_each_url_in_order_and_intact() {
        let opener = RecordingOpener::new();
        assert_eq!(opener.opened(), Vec::<String>::new());
        let urls = [
            "https://example.com/a b?x=1&y=2#frag",
            "mailto:café@example.com",
            "https://例え.jp/日本語",
            "https://example.com/a b?x=1&y=2#frag",
        ];
        for url in urls {
            assert_eq!(opener.open(url), Ok(()));
        }
        assert_eq!(opener.opened(), urls);
    }

    #[test]
    fn a_recording_opener_refuses_a_url_with_a_nul_byte_and_records_nothing_for_it() {
        let opener = RecordingOpener::new();
        let refused = opener.open("https://a\0b");
        assert!(matches!(refused, Err(UrlOpenError { reason }) if !reason.is_empty()));
        assert_eq!(opener.opened(), Vec::<String>::new());
    }

    #[test]
    fn the_contract_holds_of_the_recording_opener_and_of_a_failing_one_with_a_reason() {
        assert_eq!(contract::check(&RecordingOpener::new()), [""; 0]);
        assert_eq!(contract::check(&FailingOpener::new("no handler")), [""; 0]);
    }

    #[test]
    fn a_failing_opener_fails_every_open_with_its_reason() {
        let opener = FailingOpener::new("aucun gestionnaire: é");
        let failed = Err(UrlOpenError {
            reason: "aucun gestionnaire: é".into(),
        });
        assert_eq!(opener.open("https://example.com"), failed.clone());
        assert_eq!(opener.open("mailto:x@example.com"), failed);
    }

    /// An opener that takes every URL, a NUL byte and all.
    struct TakesAnything;

    impl UrlOpener for TakesAnything {
        fn open(&self, _url: &str) -> Result<(), UrlOpenError> {
            Ok(())
        }
    }

    #[test]
    fn an_opener_that_takes_a_nul_byte_fails_the_contract() {
        assert_eq!(contract::check(&TakesAnything), [NUL_REFUSED]);
    }

    #[test]
    fn an_opener_that_refuses_with_no_reason_fails_the_contract() {
        assert_eq!(contract::check(&FailingOpener::new("")), PROPERTIES);
    }

    #[test]
    fn a_url_open_error_says_its_reason() {
        let error = UrlOpenError {
            reason: "no handler for the scheme".into(),
        };
        assert_eq!(error.to_string(), "no handler for the scheme");
    }
}
