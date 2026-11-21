/-!
# Bindings: the document

The bindings of `crates/editor-ffi/src/document.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Handles", "Plain data").
-/

namespace Editor.Ffi

/-- The type behind `Document`. It is opaque, so the only ways to get a
document are `Document.new`, `Document.ofSnapshot` and
`Document.excerptsNew`. -/
opaque DocumentPointed : NonemptyType

/-- Text held by the Rust library, edited in place: a second handle, and the
example of a string going in and one coming back. It is the text of the
library's text storage (`crates/editor-text`) behind a lock. The text port's
real binding runs against it (`Editor/Text/Real.lean`), and the editor
reaches it only through that port. -/
def Document : Type :=
  DocumentPointed.type

instance : Nonempty Document :=
  DocumentPointed.property

/-- A new document holding `text`. -/
@[extern "editor_glue_document_new"]
opaque Document.new (text : @& String) : IO Document

/-- How the library ended a replace (`Document.replace`). Anything but `done`
changed nothing. -/
inductive ReplaceStatus where
  /-- Replaced. -/
  | done
  /-- An offset is not a character boundary of the text within it, or the
  start is after the stop. -/
  | badRange
  /-- The document is an excerpt document, and the range is not inside one
  excerpt, or meets two excerpts of one source. -/
  | outsideExcerpt
  /-- The document is an excerpt document, and the range is in an excerpt of
  a source that was freed. -/
  | noSuchSource
  deriving DecidableEq, Repr

/-- `Document.replace` as it crosses: the status as its number. -/
@[extern "editor_glue_document_replace"]
private opaque Document.replaceRaw (document : @& Document) (start stop : USize)
    (text : @& String) : IO UInt64

/-- Replaces the bytes of the document from `start` up to, not including,
`stop` with `text`, and says how it ended. An empty range inserts, and an
empty `text` deletes.

`badRange`, with nothing changed, unless both offsets are character
boundaries of the document's text, within it, and `start ≤ stop`. An excerpt
document's replace is its sources' edit (`crates/editor-ffi/src/excerpts.rs`),
refused after that with `outsideExcerpt` or `noSuchSource`. -/
def Document.replace (document : Document) (start stop : USize) (text : String) :
    IO ReplaceStatus := do
  match ← document.replaceRaw start stop text with
  | 0 =>
    return .done
  | 1 =>
    return .badRange
  | 2 =>
    return .outsideExcerpt
  | 3 =>
    return .noSuchSource
  | status =>
    throw (IO.userError s!"the library answered a replace with an unknown status {status}")

/-- A copy of the whole text of the document. -/
@[extern "editor_glue_document_read"]
opaque Document.read (document : @& Document) : IO String

/-- How many documents the Rust library holds that have not been freed.

This exists for tests: `FfiTest` uses it to see a document's finaliser run,
and `ContractTest` to see that the text port's table is the only holder of
its documents. -/
@[extern "editor_glue_document_live"]
opaque Document.live : IO UInt64

/-- `Document.awaitLive` as it crosses: the kind 2 names documents. -/
@[extern "editor_glue_live_await"]
private opaque Document.liveAwaitRaw (kind : UInt8) (target boundMs : UInt64) : IO Bool

/-- Waits until at most `target` documents the Rust library holds are not freed
(`Document.live`), and says whether that came: false once `boundMs`
milliseconds have passed first. A readout for tests, which use it to see a
finaliser run on another thread: it returns on the free, never by a poll of
`Document.live`. `boundMs` is a hang guard: only a handle that is never freed
reaches it. -/
def Document.awaitLive (target boundMs : UInt64) : IO Bool :=
  Document.liveAwaitRaw 2 target boundMs

end Editor.Ffi
