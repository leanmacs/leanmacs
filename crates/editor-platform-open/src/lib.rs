//! The URL opener port's real adapter: [`SystemOpener`], a [`UrlOpener`]
//! over the `open` crate.
//!
//! The port, its fakes and its contract are `editor-platform`'s
//! (`editor_platform::url_opener`). This crate is thin: it hands a URL to
//! `open::that_detached`, which starts the platform's launcher detached and
//! reaps it, and turns its answer into the port's. No type of `open`'s is
//! public, and no other crate depends on it (`deny.toml`).
//!
//! What it decides:
//!
//! - **A failure says why, in the system's words.** `open` answers an
//!   `io::Error`; its text is the port's reason, and an error with no text
//!   is said as one.
//! - **An open may block.** On macOS `/usr/bin/open` returns once
//!   LaunchServices has the request; on Linux each launcher is watched for
//!   up to 250 ms for an early failure. So the port is asked from a job,
//!   never from a command (`lean/Editor/UrlOpener.lean`).
//!
//! # Tests
//!
//! The gate runs [`SystemOpener`] against the port's contract alone, whose
//! one property hands it a URL holding a NUL byte: the launcher's `Command`
//! refuses that argument at spawn (`InvalidInput`), before any program
//! starts, so nothing is launched. That a well-formed URL reaches the
//! desktop's handler is the one call below, held by review; any other run
//! would open a browser on the machine running the gate.
//! [`SystemOpener::system`] is banned by the root `clippy.toml` everywhere
//! but its two sites, the library's binding for Lean's window mode and this
//! crate's contract check, each at an `#[expect]`.

use editor_platform::url_opener::{UrlOpenError, UrlOpener};

/// The desktop's handler for a URL, through the platform's launcher.
#[derive(Debug)]
pub struct SystemOpener {
    /// Made only by [`SystemOpener::system`].
    _private: (),
}

impl SystemOpener {
    /// The opener of the desktop this process runs on.
    ///
    /// What it opens is the desktop's own, so it is made in two places
    /// alone, each at an `#[expect]` the root `clippy.toml` asks for: the
    /// library's binding Lean's window mode calls, and this crate's run of
    /// the contract, which launches nothing.
    pub fn system() -> Self {
        Self { _private: () }
    }
}

impl UrlOpener for SystemOpener {
    fn open(&self, url: &str) -> Result<(), UrlOpenError> {
        #[expect(
            clippy::disallowed_methods,
            reason = "this is the one place a URL is handed to the desktop's handler"
        )]
        let opened = open::that_detached(url);
        answer(opened)
    }
}

/// What the port answers an open with, from what `open` answered.
fn answer(opened: std::io::Result<()>) -> Result<(), UrlOpenError> {
    opened.map_err(|error| {
        let said = error.to_string();
        UrlOpenError {
            reason: if said.is_empty() {
                "the system could not open the URL".to_owned()
            } else {
                said
            },
        }
    })
}

#[cfg(test)]
mod tests {
    use std::io;

    use super::{SystemOpener, answer};
    use editor_platform::url_opener::{UrlOpenError, contract};

    #[test]
    fn the_contract_holds_of_the_system_opener() {
        #[expect(
            clippy::disallowed_methods,
            reason = "the contract's one property hands it a URL holding a NUL byte, which the launcher's spawn refuses before any program starts, so nothing is launched"
        )]
        let opener = SystemOpener::system();
        assert_eq!(contract::check(&opener), [""; 0]);
    }

    #[test]
    fn an_open_the_system_took_is_taken() {
        assert_eq!(answer(Ok(())), Ok(()));
    }

    #[test]
    fn a_refusal_says_the_systems_words_and_one_with_none_says_so() {
        assert_eq!(
            answer(Err(io::Error::new(
                io::ErrorKind::NotFound,
                "no launcher: é"
            ))),
            Err(UrlOpenError {
                reason: "no launcher: é".into()
            })
        );
        assert_eq!(
            answer(Err(io::Error::other(""))),
            Err(UrlOpenError {
                reason: "the system could not open the URL".into()
            })
        );
    }
}
