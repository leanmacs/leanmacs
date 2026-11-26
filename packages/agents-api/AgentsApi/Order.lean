/-!
# What a client tells a session: its orders

The orders any job may send a session (`AgentsApi.Job.send`): a prompt,
which begins a turn and does not wait for its end; a cancel of the current
turn; a change of mode, which only a caller's order sends, never the
implementation by itself (the host's Claude settings are used as they are,
roadmap Decisions); and the answer to a parked permission request.
-/

namespace AgentsApi

/-- An order to a session. -/
inductive Order where
  /-- Send `text` as a prompt, beginning a turn. -/
  | prompt (text : String)
  /-- Cancel the current turn: its parked permission requests are answered
  `cancelled` (`Event.withdrawn`), then the agent is told. -/
  | cancel
  /-- Set the session's mode to `id`. -/
  | setMode (id : String)
  /-- Answer the parked permission request `ticket` with the option
  `optionId`. -/
  | answer (ticket : Nat) (optionId : String)
  deriving DecidableEq, Repr, Inhabited

end AgentsApi
