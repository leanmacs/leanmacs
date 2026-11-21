//! The system clipboard, on demand: the adapter held to the clipboard
//! port's contract (`editor_platform::clipboard::contract`), and the two
//! halves of a round trip across processes.
//!
//! This reads and writes the clipboard of the desktop it runs on, so it is
//! an example and not a test: the gate builds it and never runs it. Two
//! opt-in tasks run it: `mise run linux-window`, in a container under Xvfb,
//! whose clipboard is the container's own, and `mise run
//! clipboard-contract`, on the desktop it is started from.
//!
//! ```text
//! clipboard contract                 hold the clipboard to the port's contract
//! clipboard hold <text>              write <text>, and stay until stdin closes
//! clipboard read                     print the text on the clipboard
//! ```
//!
//! `contract` keeps the text it finds on the clipboard, runs the contract,
//! which writes texts of its own, and puts the text it found back. **Only
//! text is put back**: anything else that was on the clipboard (an image, a
//! file) is lost, and a clipboard that held no text is left holding the
//! contract's last text. It prints each property with whether it holds, and
//! its exit status is 0 when all hold and 1 otherwise, which includes a
//! clipboard that could not be opened.
//!
//! `hold` and `read` are for a second process to read what a first wrote,
//! which one process cannot show: on Linux the text is served by the
//! process that wrote it, so `hold` prints a line once the text is written
//! and stays alive until its standard input closes: the process that reads
//! closes it once it has read, so the order is the pipe's and no time is
//! waited out. `read` prints the text and nothing else, and exits 1 when
//! the clipboard holds none.

use std::io::{Read, Write};
use std::process::ExitCode;

use editor_platform::clipboard::{Clipboard, ClipboardError, contract};
use editor_platform_arboard::SystemClipboard;

/// The clipboard of this desktop.
fn open() -> Result<SystemClipboard, ClipboardError> {
    #[expect(
        clippy::disallowed_methods,
        reason = "this example is the one place the system clipboard is opened: it is the adapter's check, run on demand"
    )]
    SystemClipboard::open()
}

/// Holds `clipboard` to the port's contract, putting back the text it
/// found. Whether every property held.
fn held_to_the_contract(clipboard: &SystemClipboard) -> bool {
    // A read that fails is the contract's to report: nothing is kept then.
    let found = clipboard.read().ok().flatten();
    let failed = contract::check(clipboard);
    for property in contract::PROPERTIES {
        let verdict = if failed.contains(&property) {
            "FAILS"
        } else {
            "holds"
        };
        println!("clipboard-contract: {verdict}: {property}");
    }
    let restored = match &found {
        Some(text) => clipboard.write(text).is_ok(),
        None => true,
    };
    match (&found, restored) {
        (Some(_), true) => {
            println!("clipboard-contract: the text found on the clipboard was put back");
        }
        (Some(_), false) => {
            println!("clipboard-contract: FAILED: the text found could not be put back");
        }
        (None, _) => println!(
            "clipboard-contract: the clipboard held no text, and now holds the contract's last"
        ),
    }
    if failed.is_empty() && restored {
        println!("clipboard-contract: the system clipboard keeps the clipboard port's contract");
    } else {
        println!(
            "clipboard-contract: FAILED: {} of {} properties fail",
            failed.len(),
            contract::PROPERTIES.len()
        );
    }
    failed.is_empty() && restored
}

/// What the command line asks for, done on `clipboard`. Whether it was
/// done; `None` when the command line is not understood.
fn run(clipboard: &SystemClipboard, arguments: &[String]) -> Option<bool> {
    let arguments: Vec<&str> = arguments.iter().map(String::as_str).collect();
    match arguments.as_slice() {
        ["contract"] => Some(held_to_the_contract(clipboard)),
        ["hold", text] => {
            if let Err(error) = clipboard.write(text) {
                eprintln!("clipboard: FAILED: the text could not be written: {error}");
                return Some(false);
            }
            println!("clipboard: holding the text until stdin closes");
            // Said before the wait, so the reader knows the text is there.
            let _ = std::io::stdout().flush();
            // The text is served for as long as this process lives: until
            // the reader closes this end of the pipe, with no time limit.
            let _ = std::io::stdin().read_to_end(&mut Vec::new());
            Some(true)
        }
        ["read"] => match clipboard.read() {
            Ok(Some(text)) => {
                println!("{text}");
                Some(true)
            }
            Ok(None) => {
                eprintln!("clipboard: the clipboard holds no text");
                Some(false)
            }
            Err(error) => {
                eprintln!("clipboard: FAILED: the clipboard could not be read: {error}");
                Some(false)
            }
        },
        _ => None,
    }
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let clipboard = match open() {
        Ok(clipboard) => clipboard,
        Err(error) => {
            println!("clipboard: FAILED: the system clipboard could not be opened: {error}");
            return ExitCode::FAILURE;
        }
    };
    match run(&clipboard, &arguments) {
        Some(true) => ExitCode::SUCCESS,
        Some(false) => ExitCode::FAILURE,
        None => {
            eprintln!("usage: clipboard contract | hold <text> | read");
            ExitCode::from(2)
        }
    }
}
