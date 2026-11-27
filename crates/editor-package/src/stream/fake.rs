//! The stream port's published fakes: a child whose deliveries a test
//! scripts ([`ScriptedChild`]), and a source that hands scripted children
//! out by number ([`ScriptedSource`]), so a package's crate tests what it
//! does with a taken-over child with `cargo test` alone, and with no
//! process.
//!
//! A scripted child keeps the port's rules, which its contract
//! ([`super::contract::check`]) holds it to beside the runtime's real
//! child:
//!
//! - It delivers what the test scripted, in order
//!   ([`ScriptedChild::delivers`]). A delivery that carries an end is its
//!   last; every pull after it answers [`Pulled::Cancelled`].
//! - A pull with nothing scripted and no end **parks**, as the core's
//!   child's does, until the test scripts a delivery or an end, a write
//!   makes one deliverable ([`ScriptedChild::answers`]), or the test
//!   cancels the child ([`ScriptedChild::cancel`], the job's cancel). It is
//!   never answered cancelled merely because the script is empty. A pull
//!   still parked once [`PARK`] has run out panics: a test that forgot to
//!   script an end or a cancel fails as a hang.
//! - It records every write ([`ScriptedChild::written`]), and refuses one
//!   with [`CLOSED`] when it has no input, after its last delivery was
//!   pulled, or once it was cancelled.
//! - Its handle is cheap to clone: a test keeps one while the consumer
//!   holds another, and scripts or cancels through it.
//!
//! [`ScriptedChild::wait_pulling`] says whether a reader is parked in a
//! pull with nothing to deliver. It is a readout for the stream contract's
//! grounds and the fake's own tests alone, banned elsewhere (the root
//! `clippy.toml`).

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use editor_wait::HangGuard;

use super::contract::{Ground, Scenario};
use super::{ChildStreams, Delivery, Ended, InputClosed, Pulled, Refused, StreamSource};
use crate::frame::Frames;

/// The words a write a scripted child cannot take is refused with.
pub const CLOSED: &str = "the scripted child's input is closed";

/// hang guard: a scripted pull's park, which ends on a delivery, an end or
/// a cancel the test scripts; only a test that never scripts one reaches
/// the bound, and the pull then panics as a hang.
pub const PARK: HangGuard = HangGuard::on(
    "a delivery, an end or a cancel the test scripts for a parked pull",
    Duration::from_secs(60),
);

/// What a scripted child holds.
#[derive(Debug, Default)]
struct Script {
    /// Whether it has an input.
    input: bool,
    /// The deliveries scripted and not yet pulled, oldest first.
    deliveries: VecDeque<Delivery>,
    /// The deliveries a write makes deliverable: each the bytes written
    /// and what they make deliverable, used once.
    answers: Vec<(Vec<u8>, Delivery)>,
    /// Every write, oldest first.
    written: Vec<Vec<u8>>,
    /// Whether its last delivery, one carrying an end, was pulled.
    over: bool,
    /// Whether it was cancelled.
    cancelled: bool,
    /// How many readers are parked in a pull with nothing to deliver.
    parked: usize,
}

impl Script {
    /// Whether nothing more comes: its last delivery was pulled, or it was
    /// cancelled.
    const fn gone(&self) -> bool {
        self.over || self.cancelled
    }
}

/// What a scripted child's handles share.
#[derive(Debug, Default)]
struct Shared {
    /// The script.
    script: Mutex<Script>,
    /// Signalled at each change of the script: a delivery, a cancel, a
    /// reader parked.
    changed: Condvar,
}

/// A child whose deliveries a test scripts: the stream port's fake. A cheap
/// handle: clones share one script.
#[derive(Debug, Clone, Default)]
pub struct ScriptedChild {
    /// The script its handles share.
    shared: Arc<Shared>,
}

/// A delivery of `lines` of standard output, none of standard error, and
/// `ended`.
fn delivery(lines: &[&str], ended: Option<Ended>) -> Delivery {
    Delivery {
        out: Frames::Lines(lines.iter().map(|line| line.as_bytes().to_vec()).collect()),
        err: Frames::Lines(Vec::new()),
        ended,
    }
}

impl ScriptedChild {
    /// A child with an input if `input`, with nothing scripted.
    pub fn new(input: bool) -> Self {
        let child = Self::default();
        child.script().input = input;
        child
    }

    /// Locks the script. The lock is never held while a caller's code runs.
    fn script(&self) -> MutexGuard<'_, Script> {
        self.shared
            .script
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    /// Scripts a delivery of `lines` of standard output next, and the end
    /// `ended` with them, and answers a handle of this child, so scripting
    /// chains.
    pub fn delivers(&self, lines: &[&str], ended: Option<Ended>) -> Self {
        self.delivery(delivery(lines, ended))
    }

    /// Scripts `delivery` next, and answers a handle of this child.
    pub fn delivery(&self, delivery: Delivery) -> Self {
        self.script().deliveries.push_back(delivery);
        self.shared.changed.notify_all();
        self.clone()
    }

    /// Scripts what a write of exactly `written` makes deliverable: `lines`
    /// of standard output, and the end `ended` with them, once. Answers a
    /// handle of this child.
    pub fn answers(&self, written: &[u8], lines: &[&str], ended: Option<Ended>) -> Self {
        self.script()
            .answers
            .push((written.to_vec(), delivery(lines, ended)));
        self.clone()
    }

    /// Cancels it, as the job's end does: a pull, parked or not, answers
    /// cancelled, a write is refused, and a take-over is no such child.
    pub fn cancel(&self) {
        self.script().cancelled = true;
        self.shared.changed.notify_all();
    }

    /// Every write, oldest first, refused ones included.
    pub fn written(&self) -> Vec<Vec<u8>> {
        self.script().written.clone()
    }

    /// Waits until a reader is parked in a pull of this child with nothing
    /// to deliver, and says whether one is: false only once `guard` has run
    /// out first. A readout for the stream contract's grounds and this
    /// module's tests alone (the root `clippy.toml`).
    pub fn wait_pulling(&self, guard: HangGuard) -> bool {
        let script = self.script();
        let (_script, parked) =
            editor_wait::wait_while(&self.shared.changed, script, guard, |script| {
                script.parked == 0
            });
        parked
    }

    /// Whether nothing more comes from it.
    fn gone(&self) -> bool {
        self.script().gone()
    }
}

impl ChildStreams for ScriptedChild {
    fn pull(&self) -> Pulled {
        let mut script = self.script();
        if !script.gone() && script.deliveries.is_empty() {
            script.parked += 1;
            self.shared.changed.notify_all();
            let (mut woken, answered) =
                editor_wait::wait_while(&self.shared.changed, script, PARK, |script| {
                    !script.gone() && script.deliveries.is_empty()
                });
            woken.parked -= 1;
            if !answered {
                drop(woken);
                panic!("{}", PARK.hang());
            }
            script = woken;
        }
        if script.gone() {
            return Pulled::Cancelled;
        }
        let Some(delivery) = script.deliveries.pop_front() else {
            return Pulled::Cancelled;
        };
        if delivery.ended.is_some() {
            script.over = true;
        }
        Pulled::Delivered(delivery)
    }

    fn write(&self, bytes: Vec<u8>) -> Result<(), InputClosed> {
        let mut script = self.script();
        script.written.push(bytes.clone());
        if !script.input || script.gone() {
            return Err(InputClosed(CLOSED.to_owned()));
        }
        if let Some(at) = script.answers.iter().position(|(on, _)| *on == bytes) {
            let (_, answer) = script.answers.remove(at);
            script.deliveries.push_back(answer);
            self.shared.changed.notify_all();
        }
        Ok(())
    }
}

/// A source whose children are scripted, handed out by number: the stream
/// port's fake source. A cheap handle: clones share one set of children.
#[derive(Debug, Clone, Default)]
pub struct ScriptedSource {
    /// The children its handles share.
    children: Arc<Mutex<Children>>,
}

/// A scripted source's children.
#[derive(Debug, Default)]
struct Children {
    /// The last number handed out.
    last: u64,
    /// Each child, by its number, and whether it was taken over.
    by_number: HashMap<u64, (ScriptedChild, bool)>,
}

/// hang guard: nothing of the scripted source's waits but a parked pull,
/// which the contract's write or cancel ends at once, so only a contract
/// that waits on something that never comes reaches it, and the property
/// then fails as a hang.
const SCRIPTED_DEADLINE: HangGuard = HangGuard::on(
    "a scripted pull's return or park, which the scripted child answers at once",
    Duration::from_secs(10),
);

impl ScriptedSource {
    /// A source with no child.
    pub fn new() -> Self {
        Self::default()
    }

    /// Locks the children. The lock is never held while a caller's code
    /// runs.
    fn children(&self) -> MutexGuard<'_, Children> {
        self.children.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Adds `child` as a live streaming child, and answers its number,
    /// which a take-over names: from 1 up, never [`super::contract::UNUSED`].
    pub fn add(&self, child: ScriptedChild) -> u64 {
        let mut children = self.children();
        children.last += 1;
        let number = children.last;
        children.by_number.insert(number, (child, false));
        number
    }

    /// The child of the number `child`, as the test scripts it.
    pub fn child(&self, child: u64) -> Option<ScriptedChild> {
        self.children()
            .by_number
            .get(&child)
            .map(|(scripted, _)| scripted.clone())
    }
}

impl StreamSource for ScriptedSource {
    fn take_over(&self, child: u64) -> Result<Box<dyn ChildStreams>, Refused> {
        let mut children = self.children();
        let Some((scripted, taken)) = children.by_number.get_mut(&child) else {
            return Err(Refused::NoSuchChild);
        };
        if scripted.gone() {
            return Err(Refused::NoSuchChild);
        }
        if *taken {
            return Err(Refused::Taken);
        }
        *taken = true;
        Ok(Box::new(scripted.clone()))
    }
}

/// The scripted child of `scenario`, as the stream contract describes it.
fn scenario(scenario: Scenario) -> ScriptedChild {
    let exited = |code| Some(Ended::Exited { code });
    match scenario {
        Scenario::TwoLines => ScriptedChild::new(false)
            .delivers(&["one"], None)
            .delivers(&["two"], exited(2)),
        Scenario::OneLine => ScriptedChild::new(false).delivers(&["taken"], exited(0)),
        Scenario::AwaitsLine => ScriptedChild::new(true).answers(b"go\n", &["go"], exited(0)),
        Scenario::Silent => ScriptedChild::new(true),
    }
}

impl Ground for ScriptedSource {
    fn source(&self) -> &dyn StreamSource {
        self
    }

    fn open(&self, scenario_of: Scenario) -> Option<u64> {
        Some(self.add(scenario(scenario_of)))
    }

    fn cancel(&self, child: u64) {
        if let Some(scripted) = self.child(child) {
            scripted.cancel();
        }
    }

    #[expect(
        clippy::disallowed_methods,
        reason = "the stream contract's ground over the scripted source: whether a reader is parked in a pull, on `ScriptedChild::wait_pulling`"
    )]
    fn wait_pulling(&self, child: u64) -> bool {
        self.child(child)
            .is_some_and(|scripted| scripted.wait_pulling(self.deadline()))
    }

    fn deadline(&self) -> HangGuard {
        SCRIPTED_DEADLINE
    }
}

#[cfg(test)]
mod tests;
