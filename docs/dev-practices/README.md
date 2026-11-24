# Development practices

How to build, run and check the editor, in the detail the top-level
[`README.md`](../../README.md) leaves out. The rules every change follows
are in [`AGENTS.md`](../../AGENTS.md); what is being built and why is in
[`docs/design/`](../design/README.md).

| Document | Says |
|---|---|
| [`building.md`](building.md) | What `mise run lean` does, why it must be used in place of a bare `lake build`, and how the executables are linked and started. |
| [`the-gate.md`](the-gate.md) | `mise run ci`: everything that must pass before review and before landing, what each part of it tests and where, and the formatting tasks. |
| [`ci.md`](ci.md) | The CI workflow (`.github/workflows/ci.yml`): the gate on `macos-26` and `ubuntu-24.04`, the secret scan job, what each cache holds and where it is saved (from `main` only), the workflow lint (`mise run workflow-lint`), and how to add or bump an action. |
| [`on-demand-checks.md`](on-demand-checks.md) | The tasks that are never part of the gate: the overflow check, the benchmarks, the user-side link check, the keyboard check, the window's contract and what its desktop runs found, a window and the editor to try, the gate and the window on Linux, the clipboard, the renderer on a real GPU and on Linux, making the reference images (the renderer's and the shipped themes'), milestone 1's headless figures, and what a window's report gives for measuring the present mode. |
| [`publishing.md`](publishing.md) | What the public repository holds and leaves out (`research_notes/`, `reports/`), the secret scan (`mise run secrets-scan`) and what to do with a finding, and the repository's GitHub settings as code (`infra/github`, `mise run infra-check`). |
| [`inferred-waits.md`](inferred-waits.md) | Every test wait that infers "done" from something shared, with its kind, its collaborator and the phase that removes it or why it stays; how the types, the Lean linters and clippy hold them; and what replaced the wait inventory. |
| [`real-thread-checks.md`](real-thread-checks.md) | The wiring set: the rule that a check runs a real editor loop thread or a real service only in a module that declares itself one, the marks and the declaration `lake build`'s `linter.realHost` reads, where such a module goes, the modules by adapter and reason, what is outside the rule, the CLI's runs in the gate, and config-test's wall time before and after the stepped hosts. |
| [`headless-mode.md`](headless-mode.md) | `editor headless`: the editor with no window, for integration tests. What a config and a script are, and every line it can print. |
