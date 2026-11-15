//! The port's contract held against its fake, and against fakes written to
//! break one rule each, which shows that the contract bites.
//!
//! The directory is made up: nothing here is a real process or a real
//! file. Each fake is scripted with [`contract::scripts`], what the
//! contract claims each of its commands does.

use std::path::Path;

use editor_process::contract::{
    self, AFTER_REAP, CANCEL, ESCAPED, KILL, RUN, SHUTDOWN, SIGNAL, STRAGGLERS, TOO_LARGE,
};
use editor_process::fake::{FakeChild, FakeInput, FakeOutput, FakeProcesses, Flaws};
use editor_process::{Child, Command, Exit, Output, Processes, Refusal, Stream};

/// The made-up directory the contract runs in.
const DIR: &str = "/fake/contract";

/// A fake that breaks the rules `flaws` names, scripted as the contract
/// claims.
fn fake(flaws: Flaws) -> FakeProcesses {
    let fake = FakeProcesses::flawed(flaws);
    for (command, script) in contract::scripts(Path::new(DIR)) {
        fake.script(command, script);
    }
    fake
}

/// The properties `processes` fails, with the ground of `fake`.
fn failures(
    processes: &(impl Processes + Clone + 'static),
    fake: &FakeProcesses,
) -> Vec<&'static str> {
    contract::check(processes, &fake.ground(), Path::new(DIR))
}

#[test]
fn the_fake_keeps_the_contract() {
    let fake = fake(Flaws::default());

    assert_eq!(failures(&fake, &fake), [""; 0]);
    assert_eq!(fake.made(), [Path::new(DIR).join("made")]);
}

#[test]
fn a_fake_whose_group_kill_ends_only_the_child_is_reported() {
    let fake = fake(Flaws {
        kill_leader_only: true,
        ..Flaws::default()
    });

    assert_eq!(
        failures(&fake, &fake),
        [KILL, STRAGGLERS, CANCEL, SHUTDOWN, TOO_LARGE]
    );
}

#[test]
fn a_fake_whose_wait_does_not_reap_is_reported() {
    let fake = fake(Flaws {
        no_reap: true,
        ..Flaws::default()
    });

    assert_eq!(
        failures(&fake, &fake),
        [KILL, STRAGGLERS, CANCEL, SHUTDOWN, TOO_LARGE, ESCAPED]
    );
}

#[test]
fn a_fake_whose_wait_leaves_the_group_alive_at_a_normal_end_is_reported() {
    let fake = fake(Flaws {
        members_survive: true,
        ..Flaws::default()
    });

    assert_eq!(failures(&fake, &fake), [STRAGGLERS]);
}

/// A child of a wrapped fake, with each of the wrapper's flaws.
struct Bent {
    /// The fake's child.
    child: FakeChild,
    /// Whether its standard error reads as nothing.
    drops_stderr: bool,
    /// Whether a signal is reported as the shell's status for it.
    signal_as_code: bool,
}

/// A stream that reads as nothing.
struct Nothing;

impl Output for Nothing {
    fn read(&mut self, _: &mut [u8]) -> Result<usize, Refusal> {
        Ok(0)
    }
}

/// A stream of a bent child: the fake's, or nothing.
enum BentOutput {
    /// The fake's stream.
    Fake(FakeOutput),
    /// Nothing.
    Nothing(Nothing),
}

impl Output for BentOutput {
    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, Refusal> {
        match self {
            Self::Fake(output) => output.read(buffer),
            Self::Nothing(output) => output.read(buffer),
        }
    }
}

impl Child for Bent {
    type Output = BentOutput;
    type Input = FakeInput;

    fn id(&self) -> u32 {
        self.child.id()
    }

    fn take_output(&mut self, stream: Stream) -> Option<BentOutput> {
        let output = self.child.take_output(stream)?;
        Some(if self.drops_stderr && stream == Stream::Err {
            BentOutput::Nothing(Nothing)
        } else {
            BentOutput::Fake(output)
        })
    }

    fn take_input(&mut self) -> Option<FakeInput> {
        None
    }

    fn wait(&self) -> Exit {
        match self.child.wait() {
            Exit::Signal(signal) if self.signal_as_code => Exit::Code(128 + signal),
            exit => exit,
        }
    }

    fn kill(&self) {
        self.child.kill();
    }
}

/// A fake whose children are bent.
#[derive(Clone)]
struct Bending {
    /// The fake.
    fake: FakeProcesses,
    /// Whether its children's standard error reads as nothing.
    drops_stderr: bool,
    /// Whether its children report a signal as the shell's status for it.
    signal_as_code: bool,
}

impl Processes for Bending {
    type Child = Bent;

    fn spawn(&self, command: &Command) -> Result<Bent, Refusal> {
        Ok(Bent {
            child: self.fake.spawn(command)?,
            drops_stderr: self.drops_stderr,
            signal_as_code: self.signal_as_code,
        })
    }
}

#[test]
fn a_fake_that_drops_standard_error_is_reported() {
    let fake = fake(Flaws::default());
    let bending = Bending {
        fake: fake.clone(),
        drops_stderr: true,
        signal_as_code: false,
    };

    assert_eq!(failures(&bending, &fake), [RUN]);
}

#[test]
fn a_fake_that_reports_a_signal_as_a_status_is_reported() {
    let fake = fake(Flaws::default());
    let bending = Bending {
        fake: fake.clone(),
        drops_stderr: false,
        signal_as_code: true,
    };

    assert_eq!(failures(&bending, &fake), [SIGNAL, KILL]);
}

#[test]
fn a_wait_asked_again_and_a_kill_after_the_reap_are_part_of_the_contract() {
    // A fake whose second wait answers otherwise is reported.
    #[derive(Clone)]
    struct Forgetful(FakeProcesses);
    struct Once(FakeChild, std::sync::atomic::AtomicBool);
    impl Child for Once {
        type Output = FakeOutput;
        type Input = FakeInput;
        fn id(&self) -> u32 {
            self.0.id()
        }
        fn take_output(&mut self, stream: Stream) -> Option<FakeOutput> {
            self.0.take_output(stream)
        }
        fn take_input(&mut self) -> Option<FakeInput> {
            None
        }
        fn wait(&self) -> Exit {
            let exit = self.0.wait();
            if self.1.swap(true, std::sync::atomic::Ordering::SeqCst) {
                Exit::Code(-1)
            } else {
                exit
            }
        }
        fn kill(&self) {
            self.0.kill();
        }
    }
    impl Processes for Forgetful {
        type Child = Once;
        fn spawn(&self, command: &Command) -> Result<Once, Refusal> {
            Ok(Once(
                self.0.spawn(command)?,
                std::sync::atomic::AtomicBool::new(false),
            ))
        }
    }
    let fake = fake(Flaws::default());

    assert_eq!(failures(&Forgetful(fake.clone()), &fake), [AFTER_REAP]);
}
