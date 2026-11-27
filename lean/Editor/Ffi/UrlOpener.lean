/-!
# Bindings: the URL opener

The bindings of `crates/editor-ffi/src/url_opener.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Handles").
-/

namespace Editor.Ffi

/-- The type behind `UrlOpener`. It is opaque, so the only ways to get an
opener are `UrlOpener.recording`, `UrlOpener.failing` and
`UrlOpener.system`. -/
opaque UrlOpenerPointed : NonemptyType

/-- A URL opener held by the Rust library (`crates/editor-ffi/src/url_opener.rs`,
over the URL opener port of `crates/editor-platform`): the library's
recording opener, its failing one, or the desktop's. The URL opener's real
binding runs against it (`Editor/UrlOpener/Real.lean`). -/
def UrlOpener : Type :=
  UrlOpenerPointed.type

instance : Nonempty UrlOpener :=
  UrlOpenerPointed.property

/-- A new recording opener of the library's, which keeps each URL it is
handed and launches nothing: the port's fake, for tests. The editor never
makes one. -/
@[extern "editor_glue_url_opener_recording"]
opaque UrlOpener.recording : IO UrlOpener

/-- A new opener of the library's whose every open fails with `reason`: the
port's failing fake, for tests. The editor never makes one. -/
@[extern "editor_glue_url_opener_failing"]
opaque UrlOpener.failing (reason : @& String) : IO UrlOpener

/-- The desktop's URL opener. Only the window mode makes it: what it opens
is the person's. -/
@[extern "editor_glue_url_opener_system"]
opaque UrlOpener.system : IO UrlOpener

/-- Hands `url` to the opener: `none` when the system took it, and the
reason otherwise. It may block, so a job alone calls it. -/
@[extern "editor_glue_url_opener_open"]
opaque UrlOpener.openUrl (opener : @& UrlOpener) (url : @& String) : IO (Option String)

/-- For a recording opener, each URL it was handed, in order, each followed
by a NUL byte; `none` for any other opener. -/
@[extern "editor_glue_url_opener_opened"]
opaque UrlOpener.openedRaw (opener : @& UrlOpener) : IO (Option String)

/-- How many URL openers the Rust library holds that have not been freed. -/
@[extern "editor_glue_url_opener_live"]
opaque UrlOpener.live : IO UInt64

end Editor.Ffi
