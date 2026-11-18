/-!
# Config tests: support: Candidates

Candidates for long prompts: paths of about 40 bytes, as many as a check or the
prompt benchmark lists. Shared by the prompt checks
(`ConfigTest/Editor/Minibuffer.lean`) and the benchmark
(`ConfigTest/Bench.lean`); it holds no checks of its own.
-/

namespace ConfigTest

/-- `count` paths of about 40 bytes, the size the matcher was measured at
(`docs/design/rust-library.md`): what the checks and the benchmark of long
prompts list. -/
def manyPaths (count : Nat) : Array String :=
  (Array.range count).map fun index =>
    s!"src/area-{index % 97}/module-{index % 1009}/file-{index}.lean"

end ConfigTest
