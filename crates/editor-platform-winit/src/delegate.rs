//! The application delegate: where macOS hands the files it asks the app to
//! open, and asks it to terminate. AppKit is named in this module, in
//! `menu_bar` and in `corner`, and in no other library code in the
//! workspace; the crate's contract example names it too, to ask what the
//! system asks.
//!
//! When Finder opens a file with the app ("Open With", a double-click on a
//! document of a type the app claims, or a drop on its Dock icon), AppKit
//! calls the application delegate's `application:openURLs:`. winit 0.31
//! passes none of this on, and guarantees that it never registers an
//! application delegate of its own (winit-appkit 0.31's crate docs,
//! "Custom `NSApplicationDelegate`"), which this module relies on: it
//! registers its own, as those docs show.
//!
//! It must be installed after winit's `EventLoop` is built (winit-appkit:
//! "Call `sharedApplication` after `EventLoop::new`") and before the loop
//! runs. The open-documents event of a cold start is delivered during
//! `-[NSApplication run]`'s `finishLaunching`, before winit makes the
//! window, so a delegate installed later would miss it.
//!
//! It never decides. Every decision of the files is in `files.rs`, and
//! every decision of the system's quit in `terminate.rs`. Three forwards
//! are untested:
//!
//! - `application:openURLs:`, which reads each URL's file path (a URL that
//!   is not a file's gives none) and hands the list to `Handing::hand`;
//! - `applicationShouldTerminate:`, which hands the ask to
//!   `Handing::terminate` and always answers `NSTerminateLater`, so that
//!   AppKit waits for the editor's answer;
//! - [`reply`], which makes the reply `terminate.rs` gives
//!   (`replyToApplicationShouldTerminate:`).
//!
//! [`install`] also registers two defaults in the volatile registration
//! domain, which writes nothing to disk:
//!
//! - `NSTreatUnknownArgumentsAsOpen = NO`. Otherwise AppKit would take a
//!   command-line argument it does not know (`editor notes.txt`) for a file
//!   to open, once a delegate can open files, and the command line is the
//!   program's.
//! - `NSFullScreenMenuItemEverywhere = NO`. Otherwise AppKit would add an
//!   "Enter Full Screen" item of its own to the windows menu, which calls
//!   `toggleFullScreen:` and bypasses the editor's `toggle-fullscreen`: the
//!   menu bar is the editor's (`menu.rs`).

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, ProtocolObject};
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{NSApplication, NSApplicationDelegate, NSApplicationTerminateReply};
use objc2_foundation::{
    NSArray, NSDictionary, NSObject, NSObjectProtocol, NSString, NSURL, NSUserDefaults,
};

use crate::files::Handing;
use crate::terminate::Reply;

define_class!(
    /// The app's delegate: it hands the files it is asked to open on.
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "EditorPlatformWinitApplicationDelegate"]
    #[ivars = Handing]
    struct Delegate;

    unsafe impl NSObjectProtocol for Delegate {}

    unsafe impl NSApplicationDelegate for Delegate {
        /// The files the system asks the app to open.
        #[unsafe(method(application:openURLs:))]
        fn open_urls(&self, _application: &NSApplication, urls: &NSArray<NSURL>) {
            self.ivars()
                .hand(urls.iter().filter_map(|url| url.to_file_path()).collect());
        }

        /// The system asks the app to terminate: Command-Q's `terminate:`,
        /// the Dock's Quit, a logout, restart or shutdown. AppKit is told
        /// to wait for a reply, and the ask is handed on.
        #[unsafe(method(applicationShouldTerminate:))]
        fn should_terminate(&self, _application: &NSApplication) -> NSApplicationTerminateReply {
            self.ivars().terminate();
            NSApplicationTerminateReply::TerminateLater
        }
    }
);

/// Makes `reply` to a terminate AppKit waits on. After [`Reply::Now`]
/// AppKit ends the process, so nothing the caller does after it is
/// counted on. It does nothing off the main thread, where AppKit cannot be
/// asked.
pub(crate) fn reply(reply: Reply) {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let should_terminate = match reply {
        Reply::Cancel => false,
        Reply::Now => true,
    };
    NSApplication::sharedApplication(mtm).replyToApplicationShouldTerminate(should_terminate);
}

/// The installed delegate. The application does not retain its delegate,
/// so this keeps it alive; dropping it clears the application's delegate.
pub(crate) struct Installed {
    /// The delegate the application was given, kept alive and never read.
    _delegate: Retained<Delegate>,
    /// The thread it was installed on, the main one.
    mtm: MainThreadMarker,
}

impl Drop for Installed {
    fn drop(&mut self) {
        // The application holds its delegate weakly: it is taken away
        // before the delegate goes.
        NSApplication::sharedApplication(self.mtm).setDelegate(None);
    }
}

/// Makes the delegate that hands its files to `handing` the application's.
/// `None` off the main thread, where AppKit cannot be asked.
pub(crate) fn install(handing: Handing) -> Option<Installed> {
    let mtm = MainThreadMarker::new()?;
    let unknown_arguments = NSString::from_str("NSTreatUnknownArgumentsAsOpen");
    let full_screen_item = NSString::from_str("NSFullScreenMenuItemEverywhere");
    let no = NSString::from_str("NO");
    let defaults: Retained<NSDictionary<NSString, AnyObject>> = NSDictionary::from_slices(
        &[&*unknown_arguments, &*full_screen_item],
        &[no.as_ref(), no.as_ref()],
    );
    // SAFETY: the dictionary's keys are strings and its values strings,
    // property-list objects, as `registerDefaults:` asks.
    unsafe { NSUserDefaults::standardUserDefaults().registerDefaults(&defaults) };

    let this = Delegate::alloc(mtm).set_ivars(handing);
    // SAFETY: `init` is `NSObject`'s initialiser, called once on the
    // allocation, as `define_class!` asks.
    let delegate: Retained<Delegate> = unsafe { msg_send![super(this), init] };
    NSApplication::sharedApplication(mtm).setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
    Some(Installed {
        _delegate: delegate,
        mtm,
    })
}
