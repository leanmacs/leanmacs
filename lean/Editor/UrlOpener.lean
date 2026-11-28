/-!
# The URL opener port

What a job asks of the system's URL opener: hand a URL to the desktop's
handler for it, the default browser for `https:`. A link's URL target is
followed this way (`Editor/Links.lean`): `link-follow` checks the URL
(`Link.urlScheme?`, `Editor/Link.lean`) and starts the job `url-open`, which
asks this port.

- **It is reached from a job, never a command.** An open may block: on
  macOS `/usr/bin/open` returns once LaunchServices has the request, and on
  Linux each launcher is watched for up to 250 ms for an early failure. A
  command may not wait and a job may (`Editor/Process.lean`), so the port is
  a job service (`JobRequest.urlOpener`, `Editor/Job.lean`), answered on the
  job's own thread, as the matcher is.
- **A refusal is a value.** `openUrl` answers `.error` with the system's
  reason when the URL could not be handed over, and the job goes on: it
  says the reason in the echo area.
- **Only the window mode has the desktop's opener**
  (`UrlOpener.Real.system`, `Editor/UrlOpener/Real.lean`). Every other host,
  the headless mode among them, has `UrlOpener.absent`, which refuses every
  URL, so nothing they run launches a program.

Its pure model is `Editor/UrlOpener/Model.lean`, which records what it is
handed; the real binding is `Editor/UrlOpener/Real.lean`, over the Rust
library's handle (`crates/editor-ffi/src/url_opener.rs`). The job port's
contract holds both to the same answers (`JobContract.urlOpenerProperties`).

## Where an addition goes

| Addition | Where |
|---|---|
| Something more an open says (the application to open it with) | An argument of `openUrl`, and of the Rust port's `open` |
| A new request of the opener | A constructor of `UrlOpenerRequest`, its `Reply`, its `thrown`, its model's clause, and a property of `JobContract.urlOpenerProperties` |
-/

namespace Editor

/-- What a job may ask of the system's URL opener. -/
inductive UrlOpenerRequest where
  /-- Hand `url` to the desktop's handler for it: answered once the system
  has taken it, or with the reason it was refused. -/
  | openUrl (url : String)
  deriving DecidableEq, Repr

/-- The type of the reply to each request. -/
abbrev UrlOpenerRequest.Reply : UrlOpenerRequest → Type
  | .openUrl _ => Except String Unit

/-- The reply to `request` when the service that answers it threw `reason`:
a refusal, as a value. -/
def UrlOpenerRequest.thrown : (request : UrlOpenerRequest) → String → request.Reply
  | .openUrl _, reason => .error reason

/-- An answerer of the URL opener's requests in `IO`. -/
abbrev UrlOpenerHandler :=
  (request : UrlOpenerRequest) → IO request.Reply

namespace UrlOpener

/-- No opener: every URL is refused `no system opener`. It is what a job
runner has when it was given none (`Job.Services.urlOpener`), so a host
with no window launches nothing. -/
def absent : UrlOpenerHandler
  | .openUrl _ => pure (.error "no system opener")

end UrlOpener

end Editor
