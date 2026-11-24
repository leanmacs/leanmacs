import Editor.RealHost
import Editor.Test.Linked.Host
import Editor.Test.Linked.Lines
import Files
import FilesTest.Check
import FilesTest.Linked.Files.Real

/-!
# Linked tests: the auto-reload benchmark

The auto-reload row of `config-bench`,
`FilesTest.Linked.Bench.autoReloadRow`: the linked test's opt-in argument
`bench-auto-reload`, which its root, `FilesTest/Linked.lean`, runs from
`main` (`mise run config-bench`), and the gate builds and never runs. It
measures and asserts nothing but that every sample was shown; it is the
files feature's (`Files.lean`, auto-reload). It was the config test's
(`ConfigTest.Bench.autoReloadRow`, `config-test bench-auto-reload`) while
the file commands were modules of the core, and is written on the linked
test kit (`Editor.Test.Linked`) and the file checks' real host
(`withRealFileHost`, `FilesTest/Linked/Files/Real.lean`).
-/

-- A bench measures real time: its clock reads, and the sleeps of its
-- cadence, are the measurement and never a wait, and it is never part of
-- `ci` (`linter.rawClock`, `lean/Lint/Wait.lean`).
set_option linter.rawClock false

namespace FilesTest.Linked.Bench

open Editor
open Editor.Test.Linked

/-- The mark of `autoReloadRow`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def autoReloadRow.realHost : Editor.RealHost :=
  .loop

/-- The auto-reload row of `config-bench` (`FilesTest-Linked
bench-auto-reload`): the latency, in milliseconds, from another process's
rewrite of an open, unmodified buffer's file (the rewriting process's exit,
its rename done) to the rewrite shown, over the library's real watch
service, `samples` times, each on a host and a directory of its own; printed
with its budget beside it, auto-reload's criterion 9, a second. It asserts
nothing: the criterion is real time, so it is measured here, never pass or
fail in a test (`FilesTest.Linked.autoReloadChecks`). The scene is asked
again at each job line (`Session.shownOn`), so a sample ends on the event
that shows it. Before the rewrite it waits, as the check does, on the
load's own end line and on the follow job's start line. -/
def autoReloadRow (context : HostContext) (samples : Nat) : Check :=
  { name := "the auto-reload row: the rewrite-to-shown latency over real watches"
    run := do
      let (old, new) := ("one\ntwo\n", "one\ntwo\nthree\n")
      let mut took : Array Nat := #[]
      for _ in [0:samples] do
        let sample ← IO.mkRef (none : Option Nat)
        discard <|
            context.withFiles (targets := [.files, .fileWatches]) fun files => do
              let path := files / "note.txt"
              IO.FS.writeBinFile path old.toUTF8
              withRealFileHost context (files / "config") [("open-note", path)] fun session => do
                  -- The load's own end line, then the follow job's start,
                  -- which the toggle's ask has waited for: the waits of
                  -- `criteria910RealCheck`, never the host's idle.
                  session.ask [.run "open-note"]
                  unless ← session.outputReaches (endedOk · Files.loadJob) do
                    return false
                  session.ask [.run Files.autoReloadName]
                  let armed :=
                    (← session.output.get).any fun line =>
                      line.startsWith "job " && line.endsWith s!" {FileJobs.followJob}: started"
                  unless armed do
                    return false
                  unless ← rewriteFromOutside path new do
                    return false
                  let rewritten ← IO.monoNanosNow
                  let (shown, _) ←
                    session.shownOn (·.startsWith "job ") (·.contains (viewLine new 0))
                  if shown then
                    sample.set (some (((← IO.monoNanosNow) - rewritten) / 1000000))
                  return shown
        if let some ms← sample.get then
          took := took.push ms
      let sorted := took.qsort (· < ·)
      let median := (sorted[sorted.size / 2]?).getD 0
      let most := (sorted.back?).getD 0
      IO.println
          s!"auto-reload: rewrite to shown over real watches, {took.size} of {samples} samples: median {median} ms, max {most} ms; budget 1000 ms (criterion 9)"
      return took.size == samples }

end FilesTest.Linked.Bench
