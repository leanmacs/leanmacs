-- Text 0 is the scratch buffer's text: the editor loop makes its frame, and
-- that buffer, before it runs any command, so it is the first text made.
def scratch : TextId := ⟨0⟩

-- Inserts `spin`, then asks the text its revision a thousand million times:
-- a command that loops over requests, so the interrupt key stops it. Were it
-- not stopped, the gate's time limit would end the run.
def spin : EditorM Unit := do
  append scratch "spin"
  for _ in [0:1000000000] do
    discard <| scratch.revision

-- Inserts `mark`, and ends.
def mark : EditorM Unit :=
  append scratch "mark"

-- A job that takes one number: after a millisecond on the real clock, its
-- double.
def double : List Argument → JobM Nat := fun arguments => do
  let [.nat n] := arguments | throw "double takes one number"
  sleep 1
  return 2 * n

-- Starts `double` with 21. The job's result comes back as the command its
-- handler makes, which says it in the echo area.
def ask : EditorM Unit :=
  discard <| startJob "double" [.nat 21]

def setup : SetupM Unit := do
  command "spin" spin
  command "mark" mark
  command "ask" ask
  jobWith "double" double fun n => message s!"doubled to {n}"
  bindKey "C-c s" "spin"
  bindKey "C-c m" "mark"
  bindKey "C-c d" "ask"
