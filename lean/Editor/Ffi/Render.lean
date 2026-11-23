import Editor.Bound
import Editor.Ffi.Words

/-!
# Bindings: the render session

The bindings of `crates/editor-ffi/src/render.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("The window").
-/

namespace Editor.Ffi

open Words

/-- What starting the headless render session answers, as the glue builds
it: what the library says, then how it went (0 started, 1 one runs
already, 2 its render thread could not be started). Object fields first,
so the order here is the layout the glue writes. -/
private structure RawRenderStart where
  /-- Why nothing started, in the library's words; empty when it started. -/
  reason : String
  /-- How it went. -/
  status : UInt64

/-- `renderHeadless` as it crosses. -/
@[extern "editor_glue_render_headless"]
private opaque renderHeadlessRaw : IO RawRenderStart

/-- Starts the headless mode's render session: a render loop with no window,
on a thread of the library's, over the CPU renderer, which draws what a
bound display publishes at each scene's size. Refused, starting nothing,
with the library's reason: when one runs already, and when its render
thread could not be started, in the system's words. -/
def renderHeadless : IO (Except String Unit) := do
  let raw ← renderHeadlessRaw
  return if raw.status == 0 then .ok () else .error raw.reason

/-- Stops the headless render session and waits for its thread. Its journal
and counters stay readable. `false` when none runs. -/
@[extern "editor_glue_render_stop"]
opaque renderStop : IO Bool

/-- One frame drawn and presented, as the render loop's journal records it,
on the clock that stamps window input. -/
structure JournalEntry where
  /-- Its place in the journal, from 1. -/
  serial : UInt64
  /-- When the input it answers was stamped. -/
  inputNs : UInt64
  /-- When its draw began. -/
  drawNs : UInt64
  /-- When the renderer returned, having presented it. -/
  presentNs : UInt64
  /-- The rows it built. -/
  rowsRebuilt : UInt64
  /-- The rows it drew from what was kept. -/
  rowsReused : UInt64
  deriving DecidableEq, Repr

/-- `renderJournal` as it crosses. -/
@[extern "editor_glue_render_journal"]
private opaque renderJournalRaw (after : UInt64) : IO RawWords

/-- The journal entries of the latest render session, ended or not, whose
serial is above `after`, oldest first; `none` when no session has started. -/
def renderJournal (after : UInt64) : IO (Option (Array JournalEntry)) := do
  let raw ← renderJournalRaw after
  if raw.status != 0 then
    return none
  let some words := wordsOf? raw.words
    | throw (IO.userError "the library's journal is not whole words")
  let count := (words[0]?.getD 0).toNat
  unless words.size == 1 + 6 * count do
    throw (IO.userError "the library's journal does not spell its count")
  return some <|
      (Array.range count).map fun index =>
        let at_ (field : Nat) := words[1 + 6 * index + field]!
        { serial := at_ 0, inputNs := at_ 1, drawNs := at_ 2, presentNs := at_ 3
          rowsRebuilt := at_ 4, rowsReused := at_ 5 }

/-- What the latest render session has done, as its counters say. -/
structure RenderCounters where
  /-- The draws that presented a frame. -/
  draws : UInt64
  /-- The draws that did not. -/
  drawsFailed : UInt64
  /-- The frames submitted. -/
  framesSubmitted : UInt64
  /-- The frames a newer one replaced before they were drawn. -/
  framesReplaced : UInt64
  /-- The rows built, over every presented draw. -/
  rowsRebuilt : UInt64
  /-- The rows drawn from what was kept. -/
  rowsReused : UInt64
  /-- The glyph images rasterised. -/
  glyphsRasterised : UInt64
  /-- The glyph images asked for and already held. -/
  glyphsReused : UInt64
  /-- The glyph images dropped to make room. -/
  glyphsEvicted : UInt64
  /-- The glyphs that could not be drawn. -/
  glyphsSkipped : UInt64
  /-- The bytes the glyph images took up at the last draw. -/
  atlasBytes : UInt64
  /-- The journal entries let go to make room. -/
  journalDropped : UInt64
  deriving DecidableEq, Repr

/-- `renderCounters` as it crosses. -/
@[extern "editor_glue_render_counters"]
private opaque renderCountersRaw : IO RawWords

/-- The counters of the latest render session, ended or not; `none` when no
session has started. -/
def renderCounters : IO (Option RenderCounters) := do
  let raw ← renderCountersRaw
  if raw.status != 0 then
    return none
  match wordsOf? raw.words with
  |
  some
      #[draws, drawsFailed, framesSubmitted, framesReplaced, rowsRebuilt, rowsReused,
        glyphsRasterised, glyphsReused, glyphsEvicted, glyphsSkipped, atlasBytes, journalDropped] =>
    return some
        { draws, drawsFailed, framesSubmitted, framesReplaced, rowsRebuilt, rowsReused
          glyphsRasterised, glyphsReused, glyphsEvicted, glyphsSkipped, atlasBytes
          journalDropped }
  | _ =>
    throw (IO.userError "the library's counters are not twelve words")

/-- `renderResting` as it crosses: 0 for no session, 1 busy, 2 at rest. -/
@[extern "editor_glue_render_resting"]
private opaque renderRestingRaw : IO UInt8

/-- Whether the latest render session's loop is at rest: its last step found
nothing asked and nothing to wait for, and nothing has been asked since;
`none` when no session has started. -/
def renderResting : IO (Option Bool) := do
  return match ← renderRestingRaw with
    | 0 => none
    | 2 => some true
    | _ => some false

/-- `renderAwaitRest` as it crosses: 0 for no session, 1 when the bound
passed first, 2 at rest. -/
@[extern "editor_glue_render_await_rest"]
private opaque renderAwaitRestRaw (boundMs : UInt64) : IO UInt8

/-- Waits until the latest render session's loop is at rest, and says
whether it came to rest: `some true` once it is, `some false` when
`guard` ran out first, `none` at once when no session has
started. A readout for tests: it returns on the step that records rest,
never by a poll of `renderResting`. Only a loop that never comes to rest
reaches the guard. -/
def renderAwaitRest (guard : HangGuard) : IO (Option Bool) := do
  return match ← renderAwaitRestRaw guard.ms.toUInt64 with
    | 0 => none
    | 2 => some true
    | _ => some false

end Editor.Ffi
