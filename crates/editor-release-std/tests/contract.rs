//! The `std::process` adapter held to the process port's contract, on real
//! programs: the same check the core's fake passes
//! (`editor_release::contract::check_process`). Its programs are `true`,
//! `false` and `printf`, and a path nothing is at; none writes a file, so
//! the test needs no directory of its own.

use editor_release::contract::check_process;
use editor_release_std::StdProcess;

#[test]
fn the_std_adapter_keeps_the_process_contract() {
    assert_eq!(check_process(&mut StdProcess), Vec::<&str>::new());
}
