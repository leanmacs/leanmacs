//! The files the system asks the app to open: the pure translation from the
//! paths it gives to the port's [`Input::OpenFiles`], and the holding of
//! them until the window has opened.
//!
//! On macOS the paths come from the application delegate (`delegate.rs`),
//! which hands each list it is given to `Handing::hand`: onto a channel,
//! then a wake-up of the loop. The loop takes the lists off the channel
//! when it is woken and when its window opens, and passes each through
//! [`Arrivals`]. Every decision is here:
//!
//! - **Each list the system gives is one input**, its paths in the order
//!   given ([`open_files`]). Two lists are never merged.
//! - **A path that is not UTF-8 is left out**, since it cannot reach Lean as
//!   text, and **a list left with no path is no input**: the port never
//!   reports an empty list.
//! - **Files that arrive before the window has opened are held**, and
//!   delivered once it has, after `Opened` and the `Resized` that follows it:
//!   what was held first, in the order it arrived, then what was still
//!   waiting on the channel, oldest first ([`Arrivals::open`]). From then on
//!   a list is reported as it arrives.

use std::path::PathBuf;
#[cfg(any(target_os = "macos", test))]
use std::sync::mpsc;

use editor_platform::Input;
#[cfg(any(target_os = "macos", test))]
use winit::event_loop::EventLoopProxy;

/// The input asking for `paths` to be opened, in the order given; `None`
/// when no path is left. A path that is not UTF-8 is left out.
pub(crate) fn open_files(paths: impl IntoIterator<Item = PathBuf>) -> Option<Input> {
    let paths: Vec<String> = paths
        .into_iter()
        .filter_map(|path| path.into_os_string().into_string().ok())
        .collect();
    (!paths.is_empty()).then_some(Input::OpenFiles(paths))
}

/// Files to open as they arrive, held until the window has opened.
#[derive(Debug, Default)]
pub(crate) struct Arrivals {
    /// Whether the window has opened.
    opened: bool,
    /// What arrived before it had, oldest first.
    held: Vec<Input>,
}

impl Arrivals {
    /// `paths` arrived: the input to report now, once the window has
    /// opened; before that it is held, and nothing is reported now.
    pub(crate) fn arrive(&mut self, paths: Vec<PathBuf>) -> Option<Input> {
        let input = open_files(paths)?;
        if self.opened {
            return Some(input);
        }
        self.held.push(input);
        None
    }

    /// The window opened: what was held, then each list in `waiting` (taken
    /// off the channel now), oldest first. From now on
    /// [`arrive`](Self::arrive) reports at once.
    pub(crate) fn open(&mut self, waiting: impl Iterator<Item = Vec<PathBuf>>) -> Vec<Input> {
        self.opened = true;
        let mut inputs = std::mem::take(&mut self.held);
        inputs.extend(waiting.filter_map(open_files));
        inputs
    }
}

/// Where the application delegate and the menu bar's target hand what they
/// are given: the paths to open, the system's asks to terminate and the
/// command items chosen, each on a channel the loop takes them from when
/// it is woken, and the loop's waker.
#[cfg(any(target_os = "macos", test))]
#[derive(Clone)]
pub(crate) struct Handing {
    /// Where the paths go.
    pub(crate) files: mpsc::Sender<Vec<PathBuf>>,
    /// Where each ask to terminate goes (`terminate.rs` decides what comes
    /// of it).
    pub(crate) terminations: mpsc::Sender<()>,
    /// Where the name of each command item chosen goes.
    pub(crate) menus: mpsc::Sender<String>,
    /// What wakes the loop.
    pub(crate) proxy: EventLoopProxy,
}

#[cfg(any(target_os = "macos", test))]
impl Handing {
    /// Sends `paths`, then wakes the loop, as a request is sent before the
    /// wake-up, so the loop that wakes finds them. A loop that has ended has
    /// dropped its end of the channel, and the paths go nowhere.
    pub(crate) fn hand(&self, paths: Vec<PathBuf>) {
        let _ = self.files.send(paths);
        self.proxy.wake_up();
    }

    /// Sends an ask to terminate, then wakes the loop, as `hand` does.
    pub(crate) fn terminate(&self) {
        let _ = self.terminations.send(());
        self.proxy.wake_up();
    }

    /// Sends the name of a command item chosen, then wakes the loop, as
    /// `hand` does.
    pub(crate) fn choose(&self, name: String) {
        let _ = self.menus.send(name);
        self.proxy.wake_up();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    fn paths(names: &[&str]) -> Vec<PathBuf> {
        names.iter().map(PathBuf::from).collect()
    }

    fn files(names: &[&str]) -> Input {
        Input::OpenFiles(names.iter().map(|&name| name.to_owned()).collect())
    }

    #[test]
    fn a_list_of_paths_becomes_the_open_files_input_with_those_paths_in_order() {
        assert_eq!(
            open_files(paths(&[
                "/Users/me/b.txt",
                "/Users/me/a.txt",
                "/tmp/é ü.lean"
            ])),
            Some(files(&[
                "/Users/me/b.txt",
                "/Users/me/a.txt",
                "/tmp/é ü.lean"
            ]))
        );
    }

    #[test]
    fn no_path_is_no_input() {
        assert_eq!(open_files(Vec::new()), None);
    }

    #[test]
    fn a_path_that_is_not_utf8_is_left_out_and_the_rest_keep_their_order() {
        let not_utf8 = PathBuf::from(OsStr::from_bytes(b"/tmp/\xff"));
        assert_eq!(
            open_files([
                PathBuf::from("/tmp/a"),
                not_utf8.clone(),
                PathBuf::from("/tmp/b")
            ]),
            Some(files(&["/tmp/a", "/tmp/b"]))
        );
        assert_eq!(open_files([not_utf8]), None, "none is left");
    }

    #[test]
    fn paths_that_arrive_once_the_window_has_opened_are_reported_at_once() {
        let mut arrivals = Arrivals::default();
        assert_eq!(arrivals.open(std::iter::empty()), []);

        assert_eq!(
            arrivals.arrive(paths(&["/tmp/a"])),
            Some(files(&["/tmp/a"]))
        );
        assert_eq!(arrivals.arrive(Vec::new()), None, "no path is no input");
    }

    #[test]
    fn paths_that_arrive_before_the_window_opened_are_held_and_delivered_when_it_opens_in_the_order_they_arrived()
     {
        let mut arrivals = Arrivals::default();

        assert_eq!(arrivals.arrive(paths(&["/tmp/a", "/tmp/b"])), None);
        assert_eq!(arrivals.arrive(paths(&["/tmp/c"])), None);

        assert_eq!(
            arrivals.open(std::iter::empty()),
            [files(&["/tmp/a", "/tmp/b"]), files(&["/tmp/c"])]
        );
    }

    #[test]
    fn paths_waiting_on_the_channel_when_the_window_opens_come_after_those_held() {
        let mut arrivals = Arrivals::default();
        assert_eq!(arrivals.arrive(paths(&["/tmp/held"])), None);

        assert_eq!(
            arrivals
                .open([paths(&["/tmp/waiting"]), Vec::new(), paths(&["/tmp/last"])].into_iter()),
            [
                files(&["/tmp/held"]),
                files(&["/tmp/waiting"]),
                files(&["/tmp/last"])
            ]
        );
    }

    #[test]
    fn opening_twice_delivers_nothing_more() {
        let mut arrivals = Arrivals::default();
        assert_eq!(arrivals.arrive(paths(&["/tmp/a"])), None);
        assert_eq!(arrivals.open(std::iter::empty()), [files(&["/tmp/a"])]);

        assert_eq!(arrivals.open(std::iter::empty()), []);
    }
}
