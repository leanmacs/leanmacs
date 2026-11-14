-- Text 0 is the scratch buffer's text only because the editor loop makes its
-- frame at the first window event, before any command has made a text: the
-- script reloads, then sends keys, and runs no command by name.
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

def setup : SetupM Unit := do
  command "spin" spin
  command "mark" mark
  bindKey "C-c s" "spin"
  bindKey "C-c m" "mark"
