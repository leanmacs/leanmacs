def greet : EditorM Unit := do
  let text ← createText "hello"
  append text ", world"
