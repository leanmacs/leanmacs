/-!
# Diagnostics

What went wrong with a config, as data. Elaborating a chunk, running `setup`,
reading the config's source and installing its stores all report this one
type, and a reload's report carries them. Nothing in the config session
throws to say a config is bad.
-/

namespace Editor.Config

/-- How bad a diagnostic is. Only an error rejects a reload. -/
inductive Severity where
  /-- Something worth knowing. -/
  | information
  /-- Something that is probably a mistake. The reload goes ahead. -/
  | warning
  /-- The config cannot be used. The reload is rejected. -/
  | error
  deriving DecidableEq, Repr

/-- One thing a reload has to say about a config. -/
structure Diagnostic where
  /-- What it is about: a chunk's name, `setup`, or another part of the
  reload. -/
  source : String
  /-- The line in the source's text, from 1; 0 when it is about no place in
  particular. -/
  line : Nat := 0
  /-- The column in that line, from 0. -/
  column : Nat := 0
  /-- How bad it is. -/
  severity : Severity
  /-- What happened, in words. It may run over several lines. -/
  message : String
  deriving DecidableEq, Repr

end Editor.Config
