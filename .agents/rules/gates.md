# Gates pass by exit status, never by their output

A gate step (anything `mise run ci`, a CI workflow or a hook runs) passes
when its command exits 0 and fails when it exits non-zero. It never decides
by reading what a command printed.

- Don't grep, diff, count or match a command's output to decide pass or
  fail: no `grep -q` for an expected line, no pinned count line ("ran 12
  linked tests"), no ledger of printed lines checked afterwards. Output is
  for people reading a log.
- A program that checks something exits non-zero when the check fails. If a
  property is worth gating, the program that knows it asserts it and sets
  its exit status.
- Make "it ran" a matter of structure, not of a report: one driver runs a
  set it reads from code, so an item can't be skipped or run twice, instead
  of each runner printing that it ran and a script counting the lines.
- Comparing a program's output with a checked-in expected file is a test of
  that program. Run the comparison inside a test that exits non-zero on a
  difference, not as a shell pipeline in the gate.
- Prefer a gap in coverage to a fragile gate. Remove a text-matching gate
  step rather than keep it, and cover what it checked with a real test
  later.
- A structure rule (what a module may import, which layer may import
  which, where a module sits, which targets load the linters) that only a
  custom shell script could check is a reviewer rule, written in
  `.agents/rules/` (`structure.md`), not a gate step. Automated
  enforcement comes only from a structural tool: `cargo-deny`, clippy, the
  compiler, Lake, or the Lean linter plugin.
