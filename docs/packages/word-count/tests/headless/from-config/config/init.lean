-- Quoted whole in docs/packages/writing-a-package.md, "Moving it into a
-- package": change the guide with it.
import Editor
import WordCount
open Editor

def setup : SetupM Unit := do
  command "word-count-scratch" (message s!"{WordCount.count "a b c d"} words")
  bindKey "C-c w" "word-count"
