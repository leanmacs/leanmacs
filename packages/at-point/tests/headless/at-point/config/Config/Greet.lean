import Editor
open Editor

def greet : EditorM Unit := do
  let text ← createText "hello"
  append text ", world"

def count : Unit → JobM Nat := fun _ => do
  sleep 1
  return 42
