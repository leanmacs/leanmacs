# The gate is builds, tests and formatters; reviewers read the tests

The gate (`mise run ci`, `hk.pkl`, the CI workflows) builds the code, runs
its tests and checks its formatting. What a change must do is shown by Rust
and Lean tests over fakes and contract checks, which is what ports and
adapters are for, never by a script that drives the built program and reads
what it printed.

## The gate runs only these

- The builds: `cargo build`, `cargo doc` with broken intra-doc links
  denied, and `lake build` with the compiled Lean linter plugin
  (`lean/Lint/`).
- The Rust tests: `cargo test`, integration tests under `tests/` included.
- The Lean test executables, and the packages' linked tests and fixtures.
- The formatters: `cargo fmt`, lean-fmt, clang-format.
- The structural tools: clippy, `cargo-deny`, the Lean linter plugin, and
  the workflow linters.
- A thin driver that only invokes these and passes their exit status
  through is allowed. It decides nothing of its own.

Anything else is not a gate step, however useful its output.

## Each step passes by exit status

- A step passes when its command exits 0 and fails when it exits non-zero.
  Don't grep, diff, count or match a command's output to decide: no
  `grep -q` for an expected line, no pinned count line ("ran 12 linked
  tests"), no ledger of printed lines checked afterwards. Output is for
  people reading a log.

## A new check is a test

- Write a new check as a Rust or Lean test, in the crate or module that
  owns the behaviour, under `AGENTS.md`'s testing rules. The test that
  knows the property asserts it.
- Never write a shell script to check something: not one that drives the
  built editor, inspects the files or processes a run left behind, counts
  output, or probes another script. A script's check pins how the program
  is wired, breaks on changes that don't matter, and slows every change.
- Checking files a run wrote is fine inside an integration test, which owns
  its temporary directory; not in a script.
- Comparing a program's output with a checked-in expected file is a test of
  that program. Run the comparison inside a test program that exits
  non-zero on a difference, not as a shell pipeline in the gate.

## Tests stay narrow, and the seam is a contract

- Treat the Rust code as a library that Lean loads, as it would a
  third-party one (`docs/design/overview.md`, "Rules of the boundary").
  Test what the library owns in Rust, at its API and its C ABI, so a
  library change is caught by `cargo test`.
- Test Lean logic on its interfaces' pure models and fakes, so editor
  behaviour is caught by `lake test` with no Rust build.
- Hold the seam with one contract check per interface: the same properties
  run against the model and the real binding, pinning only what crosses
  the seam, so the model cannot drift from the library.
- Each test exercises one side of the seam, or the contract between them.
  No test drives the whole built program or reads its output: that pins
  wiring the ports exist to make unnecessary.

## Write criteria as behaviour

- Write an acceptance criterion as what a user or caller sees, not as how
  the gate runs: "a broken linked test fails the gate", not "the gate runs
  each linked test once". A criterion about the gate's own mechanics is not
  worth a check; drop it or restate it as behaviour.

## Reading the tests is enough evidence

- A reviewer confirms a criterion by reading the test that shows it and
  seeing the gate pass. That is the whole of the evidence.
- Don't ask for printed output, a count line, a ledger, a probe of the
  gate, or a bite check committed as a gate step, and don't offer them:
  each is a script check under another name.
- Judge a criterion no test can show by reading the code, never by adding
  a script to show it.
- Prefer a gap in coverage to a fragile check. Name the gap, and cover it
  with a real test later.

## A document is never evidence

- Never write a document as proof: no inventory, table, ledger, or record
  of what was checked or run, whether in an rdm item's body, a plan, a
  commit message, or a doc.
- Planning reads the code. The tests, read by a reviewer, are the
  evidence. A passing gate is the dispatch flow's own run of `mise run
  ci`, not something to record.
- Such documents go stale, pin details, and give review endless surface,
  the problem this rule exists to remove.

## A test is shown to bite by hand

- To show a test bites, the implementer breaks the code by hand, sees the
  test fail, and restores it. A reviewer may do the same.
- Keep no bite demonstration in the tree: no fixture that breaks the code
  on purpose, no probe, no "Seen to bite" record. It proves the test bit
  once and then pins how the test is built.

## Scripts in `tools/` are tools, not checks

- A script builds, bundles, stages, installs, or drives an on-demand run
  such as the stress loop. In the gate it is at most the thin driver
  above, deciding nothing beyond its own command's status.

## Structure rules are reviewer rules

- A structure rule (what a module may import, which layer may import
  which, where a module sits, which targets load the linters) that only a
  custom shell script could check is held by review, written in
  `.agents/rules/structure.md`, not a gate step. Automated enforcement
  comes only from a structural tool: `cargo-deny`, clippy, the compiler,
  Lake, or the Lean linter plugin.
