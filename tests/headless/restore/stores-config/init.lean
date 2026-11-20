import Editor
open Editor

-- Session restore of stores and jobs (`stores-script`,
-- `stores-restore-script`): `kept`, a number kept across a restart, and
-- `unkept`, one that is not, each with a command that adds one; and `hold`,
-- a job a person waits on, which sleeps a minute on the job clock, so it is
-- running when the process ends.

def kept : Store Nat :=
  { name := "kept", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

def unkept : Store Nat :=
  { kept with name := "unkept" }

def hold : Unit → JobM Unit := fun _ =>
  sleep 60000

def setup : SetupM Unit := do
  kept.declare
  kept.keptAcrossRestart
  kept.command "bump-kept" fun n => pure (n + 1)
  unkept.declare
  unkept.command "bump-unkept" fun n => pure (n + 1)
  workJob "hold" (fun _ => Work.of hold fun _ => pure ()) (reported := true)
