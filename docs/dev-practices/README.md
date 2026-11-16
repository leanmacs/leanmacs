# Development practices

How to build, run and check the editor, in the detail the top-level
[`README.md`](../../README.md) leaves out. The rules every change follows
are in [`AGENTS.md`](../../AGENTS.md); what is being built and why is in
[`docs/design/`](../design/README.md).

| Document | Says |
|---|---|
| [`building.md`](building.md) | What `mise run lean` does, why it must be used in place of a bare `lake build`, and how the executables are linked and started. |
| [`the-gate.md`](the-gate.md) | `mise run ci`: everything that must pass before review and before landing, what each part of it tests and where, and the formatting tasks. |
| [`on-demand-checks.md`](on-demand-checks.md) | The tasks that are never part of the gate: the overflow check, the benchmarks, the keyboard check, the window's contract and what its desktop runs found, a window and the editor to try, the gate and the window on Linux, the clipboard, the renderer on a real GPU and on Linux, making the reference images (the renderer's and the shipped themes'), milestone 1's headless figures, and what a window's report gives for measuring the present mode. |
| [`headless-mode.md`](headless-mode.md) | `editor headless`: the editor with no window, for integration tests. What a config and a script are, and every line it can print. |
