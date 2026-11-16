# Development practices

How to build, run and check the editor, in the detail the top-level
[`README.md`](../../README.md) leaves out. The rules every change follows
are in [`AGENTS.md`](../../AGENTS.md); what is being built and why is in
[`docs/design/`](../design/README.md).

| Document | Says |
|---|---|
| [`building.md`](building.md) | What `mise run lean` does, why it must be used in place of a bare `lake build`, and how the executables are linked and started. |
| [`the-gate.md`](the-gate.md) | `mise run ci`: everything that must pass before review and before landing, what each part of it tests and where, and the formatting tasks. |
| [`on-demand-checks.md`](on-demand-checks.md) | The tasks that are never part of the gate: the overflow check, the benchmarks, the keyboard check, the window's contract, the window's scale and fullscreen by hand (steps for the owner, not yet run by a person), the gate and the window on Linux, the renderer on a real GPU and on Linux, and making the renderer's reference image; and the steps, not yet run, by which the present mode will be measured on a window. |
| [`finder-session.md`](finder-session.md) | The owner's checklist for the installed app: the window, requests to it, opening from Finder and the Dock, and an edit, a save and a config command in a session started from Finder; how to prepare it and restore the machine after. |
| [`headless-mode.md`](headless-mode.md) | `editor headless`: the editor with no window, for integration tests. What a config and a script are, and every line it can print. |
