-- Quoted whole in docs/packages/writing-a-package.md, "Developing it live,
-- as config": change the guide with it.
import Editor
import Config.WordCount
open Editor

def setup : SetupM Unit := do
  Config.WordCount.setup
