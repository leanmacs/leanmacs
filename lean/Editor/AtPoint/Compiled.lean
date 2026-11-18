import Editor.AtPoint
import Editor.Completion.Words
import Editor.Config.Registry

/-!
# Completion at point's compiled registrations

What compiled code registers for completion at point, for a host to hand
its registry before any config: its commands (`AtPoint.commands`,
`Editor/AtPoint.lean`), which the Vim scheme's insert state binds; and the
job of the shipped `words` source
(`Words.jobs`), registered compiled so its owner is `compiled` and a reload
does not cancel it (`Editor/Completion/Words.lean`). `Headless.shippedOver`
registers it with the shipped at-point source (`Completion.AtPoint.shipped`),
the shipped source (`Completion.Words.shipped`) and the use of `words` for
every buffer.
-/

namespace Editor.AtPoint

/-- Completion at point's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := completeName, action := .call complete },
    { name := nextName, action := .call (stepOrAsk .next) },
    { name := previousName, action := .call (stepOrAsk .previous) },
    { name := tabName, action := .call tab }, { name := backtabName, action := .call backtab },
    { name := returnName, action := .call «return» }, { name := quitName, action := .call quit },
    { name := triggeredName, action := .call triggered },
    { name := pausedName, action := .call paused }]

end Editor.AtPoint

namespace Editor.Completion.Words

/-- The job of the source `words`, registered under `Words.job`. -/
def jobs : Array Config.JobRegistration :=
  #[{ name := job, work := Completion.answering gather }]

end Editor.Completion.Words
