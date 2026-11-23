/-!
# Inferred waits, marked

A wait that infers "done" from something shared rather than from a signal
for its own work (`docs/dev-practices/inferred-waits.md`) is a constant with
a mark beside it: a declaration named after the constant with
`inferredWait` added, of the type `InferredWait`, its value one of the four
kinds applied to the subject modules, the modules beside its own whose
subject the wait is: a literal list of them, or a constant whose value is
one, for marks that share it.

```
/-- `Activity.seen` is an inferred wait (`Editor/InferredWait.lean`). -/
def Activity.seen.inferredWait : InferredWait :=
  .count [`Editor.Job.Runner, `Editor.Headless]
```

The wait linter (`linter.inferredWait`, `lean/Lint/Wait.lean`) reads the
mark of each constant a command references, and refuses the reference
outside the constant's own module, its subject modules and the test
modules that mirror them. The mark is plain data, so this module imports
nothing and the config base stays plain Lean (`docs/design/overview.md`,
"Config is elaborated behind a port, and two adapters link Lean's
frontend"): the linter is a Lean plugin the build loads, never a module the
editor imports (`lean/lakefile.lean`, `lintPlugin`).

A mark is public, written as above (the linter reads its value, not what it
reduces to), and, for a declaration of a test module that hands a
restricted wait on, written before the declaration, which the linter reads
as it lints that declaration.

Its checks are the linter's fixtures (`ModelTest/Lint/Wait.lean`,
`ConfigTest/Lint/Wait.lean`, `ContractTest/Lint/Wait.lean`).
-/

namespace Editor

/-- What a marked wait infers "done" from, with its subject modules. -/
inductive InferredWait where
  /-- Kind a: the activity count read to know one piece of work has ended,
  or a service's pending count read before and after. -/
  | count (subjects : List Lean.Name := [])
  /-- Kind a: the host's idle, or a wait made of it. -/
  | idle (subjects : List Lean.Name := [])
  /-- Kind b: a "first X after Y" wait another thread's X can satisfy. -/
  | firstAfter (subjects : List Lean.Name := [])
  /-- Kind d: a real service's readout whose fake exists. -/
  | realEffect (subjects : List Lean.Name := [])

end Editor
