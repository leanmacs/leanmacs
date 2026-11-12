//! The process's main thread: a check for it, and a service that runs on it.
//!
//! Lean's generated `main` runs the Lean `main` on a thread Lean creates, so
//! Lean code is never on the process's main thread. macOS only lets a window
//! event loop run there. The executable's entry point (`editor_entry` in
//! `lean/ffi/glue.c`) therefore keeps the real main thread for Rust: it
//! opens the service, starts Lean on a second thread, and parks the main
//! thread in [`Service::serve`]. Lean then asks for main-thread work with a
//! [`Request`] and blocks until the [`Reply`].
//!
//! The service grows by data. A new kind of main-thread work is a
//! [`Request`] variant and its [`Reply`], answered in `answer`; "run the
//! window" arrives that way. The C functions at the bottom only forward to
//! the one process-wide `MAIN_THREAD` instance.
//!
//! This module lives in `editor-ffi` only until the window crate
//! (`editor-platform-winit`) exists. The check and the service are plain
//! Rust that knows nothing about Lean, and move there with the window loop;
//! the `extern "C"` wrappers stay here.

use std::collections::VecDeque;
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
compile_error!(
    "editor-ffi's main-thread check is written for macOS (`pthread_main_np`) and for Linux \
     (`getpid` and `gettid`). Windows needs a case of its own, with the port of the build to it."
);

#[cfg(target_os = "macos")]
unsafe extern "C" {
    /// Non-zero when the calling thread is the process's initial thread
    /// (`pthread_main_np(3)`). Declared by hand so the crate needs no
    /// dependency for one function.
    safe fn pthread_main_np() -> std::ffi::c_int;
}

/// Whether the calling thread is the process's main thread, as the operating
/// system reports it.
#[cfg(target_os = "macos")]
pub fn is_main_thread() -> bool {
    pthread_main_np() != 0
}

#[cfg(target_os = "linux")]
unsafe extern "C" {
    /// The process's id (`getpid(2)`), which on Linux is also the thread id
    /// of its initial thread. Declared by hand, like `pthread_main_np`.
    safe fn getpid() -> std::ffi::c_int;
    /// The calling thread's id (`gettid(2)`). glibc exports it from 2.30.
    safe fn gettid() -> std::ffi::c_int;
}

/// Whether the calling thread is the process's main thread, as the operating
/// system reports it: on Linux the initial thread is the one whose thread id
/// is the process's id.
#[cfg(target_os = "linux")]
pub fn is_main_thread() -> bool {
    getpid() == gettid()
}

/// Work the main thread does on behalf of another thread.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Request {
    /// Report whether the thread answering this is the process's main thread.
    Probe,
}

/// The result of a [`Request`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reply {
    /// The answer to [`Request::Probe`].
    OnMainThread(bool),
}

/// Does the work a [`Request`] names, on the calling thread.
fn answer(request: Request) -> Reply {
    match request {
        Request::Probe => Reply::OnMainThread(is_main_thread()),
    }
}

/// A rendezvous between one serving thread and the threads that ask it for
/// work: a caller's [`request`](Self::request) blocks until the serving
/// thread has run it and replied.
///
/// `A` does the work. The process-wide instance uses `answer`; tests supply
/// their own.
pub struct Service<A> {
    /// Runs a request on whichever thread calls it.
    answer: A,
    /// The requests waiting for the serving thread.
    queue: Mutex<Queue>,
    /// Signalled when a request joins the queue.
    arrived: Condvar,
}

/// What [`Service::queue`] guards.
struct Queue {
    /// Whether a thread has committed to serving.
    open: bool,
    /// Requests not yet taken by the serving thread, oldest first.
    waiting: VecDeque<Job>,
}

/// One request and the way back to its caller.
struct Job {
    /// The work to do.
    request: Request,
    /// Where the caller waits for the result.
    reply: SyncSender<Reply>,
}

impl<A: Fn(Request) -> Reply> Service<A> {
    /// A service that is not open yet and answers requests with `answer`.
    pub const fn new(answer: A) -> Self {
        Self {
            answer,
            queue: Mutex::new(Queue {
                open: false,
                waiting: VecDeque::new(),
            }),
            arrived: Condvar::new(),
        }
    }

    /// Commits the calling thread to serving: from here on, requests wait
    /// for [`serve_next`](Self::serve_next) or [`serve`](Self::serve).
    ///
    /// Call this before starting any thread that may make a request, so no
    /// request can slip in ahead of it and be answered on the wrong thread.
    pub fn open(&self) {
        self.queue().open = true;
    }

    /// Waits for the next request, runs it on the calling thread, and sends
    /// the result back to its caller.
    pub fn serve_next(&self) {
        let job = {
            let mut queue = self.queue();
            loop {
                if let Some(job) = queue.waiting.pop_front() {
                    break job;
                }
                queue = self
                    .arrived
                    .wait(queue)
                    .unwrap_or_else(PoisonError::into_inner);
            }
        };
        // The caller holds the receiving end until it has the reply, so the
        // send cannot fail; if the caller is gone there is nobody to tell.
        let _ = job.reply.send((self.answer)(job.request));
    }

    /// Serves requests on the calling thread forever.
    ///
    /// This does not open the service. Call [`open`](Self::open) first:
    /// until the service is open, requests are answered on their callers'
    /// threads and never reach this one.
    pub fn serve(&self) -> ! {
        loop {
            self.serve_next();
        }
    }

    /// Has the serving thread run `request`, and blocks until it replies.
    ///
    /// If the service is not open, nothing is going to serve, so the request
    /// is run on the calling thread instead of waiting forever. Do not call
    /// this from the serving thread once the service is open: it would wait
    /// for itself.
    pub fn request(&self, request: Request) -> Reply {
        let (reply, answered) = mpsc::sync_channel(1);
        {
            let mut queue = self.queue();
            if !queue.open {
                drop(queue);
                return (self.answer)(request);
            }
            queue.waiting.push_back(Job { request, reply });
        }
        self.arrived.notify_one();
        answered
            .recv()
            .expect("the serving thread replies to every request it takes")
    }

    /// Locks the queue. The lock is never held while a request runs, so a
    /// poisoned lock still guards a consistent queue.
    fn queue(&self) -> MutexGuard<'_, Queue> {
        self.queue.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The process's one main-thread service, served by the entry point's thread.
static MAIN_THREAD: Service<fn(Request) -> Reply> = Service::new(answer);

/// Whether the calling thread is the process's main thread.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_is_main_thread() -> bool {
    is_main_thread()
}

/// Opens the process's main-thread service. The entry point calls this on
/// the main thread before it starts the thread that runs Lean.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_main_thread_open() {
    MAIN_THREAD.open();
}

/// Parks the calling thread, which must be the process's main thread, serving
/// requests from other threads. Never returns; the process ends when another
/// thread exits it.
///
/// This does not open the service: call [`editor_ffi_main_thread_open`]
/// first, as the entry point does.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_main_thread_serve() -> ! {
    MAIN_THREAD.serve()
}

/// Whether work handed to the main-thread service runs on the process's main
/// thread. `false` when nothing is serving, unless the caller is itself on
/// the main thread.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_main_thread_probe() -> bool {
    match MAIN_THREAD.request(Request::Probe) {
        Reply::OnMainThread(on_main_thread) => on_main_thread,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::thread::{self, ThreadId};

    /// A service whose answer function records the thread it ran on and
    /// replies with a canned value.
    fn recording(answered_on: &Mutex<Vec<ThreadId>>) -> Service<impl Fn(Request) -> Reply + '_> {
        Service::new(move |request| {
            answered_on.lock().unwrap().push(thread::current().id());
            match request {
                Request::Probe => Reply::OnMainThread(true),
            }
        })
    }

    #[test]
    fn a_spawned_thread_is_not_the_main_thread() {
        assert!(!thread::spawn(is_main_thread).join().unwrap());
    }

    #[test]
    fn a_request_is_answered_on_the_serving_thread() {
        let answered_on = Mutex::new(Vec::new());
        let service = recording(&answered_on);
        service.open();

        thread::scope(|scope| {
            let server = scope.spawn(|| {
                service.serve_next();
                thread::current().id()
            });
            let reply = service.request(Request::Probe);
            let server = server.join().unwrap();

            assert_eq!(reply, Reply::OnMainThread(true));
            assert_eq!(*answered_on.lock().unwrap(), [server]);
            assert_ne!(server, thread::current().id());
        });
    }

    #[test]
    fn a_request_to_a_service_that_is_not_open_is_answered_on_the_calling_thread() {
        let answered_on = Mutex::new(Vec::new());
        let service = recording(&answered_on);

        let reply = service.request(Request::Probe);

        assert_eq!(reply, Reply::OnMainThread(true));
        assert_eq!(*answered_on.lock().unwrap(), [thread::current().id()]);
    }

    #[test]
    fn every_caller_gets_a_reply_when_requests_overlap() {
        const CALLERS: usize = 4;
        let answered_on = Mutex::new(Vec::new());
        let service = recording(&answered_on);
        service.open();

        thread::scope(|scope| {
            let server = scope.spawn(|| {
                for _ in 0..CALLERS {
                    service.serve_next();
                }
                thread::current().id()
            });
            let callers: Vec<_> = (0..CALLERS)
                .map(|_| scope.spawn(|| service.request(Request::Probe)))
                .collect();
            for caller in callers {
                assert_eq!(caller.join().unwrap(), Reply::OnMainThread(true));
            }
            let server = server.join().unwrap();

            assert_eq!(*answered_on.lock().unwrap(), [server; CALLERS]);
        });
    }
}
