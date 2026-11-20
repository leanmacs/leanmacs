//! A [`Service`] over the process's real completion queue: what it
//! completes arrives there as the completion of its request, from the
//! library's source with the service's id, and the real completer keeps the
//! contract the fake keeps.
//!
//! An integration test of its own, because the completion queue is
//! process-wide: no other test of this crate pushes to it or pulls from it.
//! The two checks share one test so that they never run at once.

use editor_service::queue::{COMPLETION, Event, Source, SourceKind};
use editor_service::{Completer, Service, completer_contract};

/// The service the test completes requests of.
static ECHOES: Service = Service::named("queue-test");

/// Every completion queued since the last call, in order, taken off the
/// queue without parking a pull on it.
fn drained() -> Vec<Event> {
    let mut events = Vec::new();
    while COMPLETION.queued() > 0 {
        events.push(COMPLETION.next());
    }
    events
}

#[test]
fn a_service_completes_its_requests_on_the_completion_queue() {
    let source = Source {
        kind: SourceKind::Library,
        id: ECHOES.id(),
    };

    assert!(ECHOES.complete(42));
    assert_eq!(drained(), [Event::completion(source, 42)]);

    let requests = || {
        drained()
            .into_iter()
            .filter(|event| event.source == source)
            .map(|event| event.code)
            .collect()
    };
    assert_eq!(completer_contract(&&ECHOES, requests), [] as [&str; 0]);
    let completer: &dyn Completer = &ECHOES;
    assert!(completer.complete(1));
    assert_eq!(drained(), [Event::completion(source, 1)]);
}
