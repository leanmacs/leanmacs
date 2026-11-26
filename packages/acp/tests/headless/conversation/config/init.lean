import Editor
open Editor

-- A config that registers nothing, so the conversation is acp's own, with
-- Claude Code's adapter as its agent and the default view.
def setup : SetupM Unit :=
  pure ()
