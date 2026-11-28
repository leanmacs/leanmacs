import Editor.Extension
import Editor.Jumps.Go
import Editor.Link
import Editor.Mode

/-!
# Following links, and moving between them

A buffer's links are its owner's data (`Buffer.links`, `Editor/Link.lean`);
this module follows the one under the cursor and moves between them, from
the keyboard (`docs/design/text-and-display.md`, "Followable spans, as
built"). The core holds every decision and declares the names; the package
`link-commands` registers them (`Links.setup`), as `restore` and
`package-set` register under names the core declares. Leaving the package
out leaves link following out: links are still drawn, and a mode keeps its
own `activate`.

- **The links mode** (`mode`, named `Links.modeName`) fills `activate` with
  `link-follow`, `next-link` with `link-next` and `previous-link` with
  `link-previous`. Its keymaps go before a buffer's minor and major modes'
  in a buffer with links (`Config.Registry.activeMaps`), so on a link
  following takes precedence over the mode's own `activate`.
- **Following** (`follow`, `link-follow`) reads the link at the head of the
  primary range of the call's window (`Link.at?`) and follows its target
  (`followTarget`). Off a link it runs the command the buffer's own modes
  fill `activate` with (`RegistryRequest.roleCommand`), inside itself, with
  the same call; with none it says `link-follow: no link at the cursor`.
  In a buffer with links whose mode fills no `activate`, `RET` off a link
  therefore no longer reaches the scheme's own `RET`: generated buffers are
  read-only lists, where that was accepted.
- **Each kind of target** (`followTarget`):
  - a location is gone to as a jump (`Jumps.goTo`): the cursor's place in
    the buffer is recorded, then the file is visited in the same window at
    the row and column, through `FilesApi.files?`, so `C-o` comes back to
    the link. A relative path is refused with a message: the producer
    resolves paths, as compile does;
  - a URL is handed to the job `url-open`, once it passes the URL check
    (`Link.urlScheme?`: a scheme and no control character), since an open
    may block and a command may not wait (`Editor/UrlOpener.lean`). The
    job says the system's refusal in the echo area. One that fails the
    check is refused with a message and starts no job;
  - a reference is followed by the resolver registered for its scheme
    (`Resolver`, a choice read with `Extension.named`, so config's resolver
    of a scheme replaces a package's), which is handed the call and the
    reference's rest. A resolver acts, and may follow a target it resolved
    with `followTarget`. A scheme with no resolver is refused with a
    message;
  - a command is run inside `link-follow` with the target's arguments
    (`runCommand`); one no one registered is refused with a message.
- **Moving** (`next`, `previous`) puts the cursor on the first byte of the
  link that starts after it (`Link.after`) or before it (`Link.before`), so
  from inside a link `previous` goes to that link's start. It does not
  wrap: at the last link `link-next` says `link-next: no link after the
  cursor` and leaves the cursor, and `link-previous` does the same at the
  first.
- **A link inside a shown fold is hidden** (`shownLinks`): a link whose
  start a shown fold's rows hold (`BufferId.shownFolds`) is passed over by
  `link-next` and `link-previous`, and is not followed, so `link-follow` on
  a placeholder runs the buffer's own `activate`
  (`docs/design/text-and-display.md`, "Folds, as built").

## Where an addition goes

| Addition | Where |
|---|---|
| A new kind of target | A constructor of `LinkTarget` (`Editor/Link.lean`), its arm in `followTarget`, and a check in `ModelTest.linkFollowChecks` |
| A new scheme of references | A `Resolver` a package registers; nothing here |
| A new movement | A role (`Editor/Role.lean`), a command here, its entry in `mode` and `setup` |

Pinned by `ModelTest.linkFollowChecks` and `ModelTest.linkMoveChecks`, and
the package's registrations by `LinkCommandsTest.linkCommandsChecks`.
-/

namespace Editor.Links

/-- The name `follow` is registered under. -/
def followName : String :=
  "link-follow"

/-- The name `next` is registered under. -/
def nextName : String :=
  "link-next"

/-- The name `previous` is registered under. -/
def previousName : String :=
  "link-previous"

/-- The name of the job that hands a URL to the system's opener
(`openWork`). -/
def openJobName : String :=
  "url-open"

/-- The resolver of a scheme of references, such as `rdm`: a choice
extension point the core declares, read by name (`Extension.named`), so
config's resolver of a scheme replaces a package's. `follow` is handed the
call and the reference's rest (`task/x` of `rdm:task/x`), and acts. -/
structure Resolver where
  /-- The scheme it resolves, without its colon. -/
  scheme : String
  /-- Follows a reference of the scheme, given its rest. -/
  follow : Call → String → EditorM Unit
  deriving TypeName

/-- The links mode: it fills `activate`, `next-link` and `previous-link`
with the commands here, and its keymaps go first in a buffer with links
(`Config.Registry.activeMaps`). -/
def mode : Mode :=
  { name := modeName
    roles :=
      [(Role.activate, followName), (Role.nextLink, nextName), (Role.previousLink, previousName)]
    roleDescs :=
      [(Role.activate, "Follow the link"), (Role.nextLink, "Next link"),
        (Role.previousLink, "Previous link")] }

/-- Follows `target` from the call's window ("Each kind of target", in the
module docs). -/
def followTarget (call : Call) (target : LinkTarget) : EditorM Unit :=
  match target with
  | .location path row column =>
    if path.isAbsolute then Jumps.goTo call.target.window.id (.file path row column) false
    else message s!"{followName}: `{path}` is not an absolute path"
  | .url url => do
    match Link.urlScheme? url with
    | some _ =>
      if let .error refusal← startJob openJobName [.str url] then
        message s!"{followName}: {refusal.describe}"
    | none =>
      message s!"{followName}: `{url}` is not a URL"
  | .reference scheme rest => do
    match ← Extension.named Resolver (·.scheme) scheme with
    | some resolver =>
      resolver.follow call rest
    | none =>
      message s!"{followName}: nothing follows `{scheme}:` links"
  | .command invocation => do
    unless ← runCommand invocation.command { call with arguments := invocation.arguments } do
      message s!"{invocation.command}: no such command"

/-- The byte offset of the cursor of the call's window: the head of its
selection's primary range; `none` when it has none. -/
def headOf (call : Call) : EditorM (Option Nat) := do
  let selection ← call.target.selection
  return selection.ranges[selection.primary]?.map (·.head)

/-- The links of the call's buffer that no shown fold hides: those whose
start no shown fold's rows hold ("A link inside a shown fold is hidden", in
the module docs). -/
def shownLinks (call : Call) : EditorM (Array Link) := do
  let buffer := call.target.buffer
  let shown ← call.target.window.buffer.shownFolds
  if shown.isEmpty then
    return buffer.links
  let size ← buffer.text.byteLength
  buffer.links.filterM fun link => do
      return (Fold.cover shown (← Fold.rowOf buffer.text size link.start)).isNone

/-- `link-follow`: follows the link at the cursor, or, off a link, runs the
command the buffer's own modes fill `activate` with ("Following", in the
module docs). -/
def follow (call : Call) : EditorM Unit := do
  let links ← shownLinks call
  let link := (← headOf call).bind (Link.at? links)
  match link with
  | some link =>
    followTarget call link.target
  | none =>
    let buffer := call.target.buffer
    match ← RegistryRequest.ask (.roleCommand buffer.major buffer.minors Role.activate) with
    | some name =>
      -- A mode of the buffer's own that names this command would run it
      -- again for ever.
      if name == followName then
        message s!"{followName}: no link at the cursor"
      else
        discard <| runCommand name call
    | none =>
      message s!"{followName}: no link at the cursor"

/-- `link-next`: puts the cursor on the first byte of the link that starts
after it, or says there is none ("Moving", in the module docs). -/
def next (call : Call) : EditorM Unit := do
  let some head ← headOf call | return
  match Link.after (← shownLinks call) head with
  | some link =>
    Jumps.placeCursor call.target.window.id link.start
  | none =>
    message s!"{nextName}: no link after the cursor"

/-- `link-previous`: puts the cursor on the first byte of the link that
starts before it, or says there is none ("Moving", in the module docs). -/
def previous (call : Call) : EditorM Unit := do
  let some head ← headOf call | return
  match Link.before (← shownLinks call) head with
  | some link =>
    Jumps.placeCursor call.target.window.id link.start
  | none =>
    message s!"{previousName}: no link before the cursor"

/-- The work of `url-open`, started with the URL: it hands the URL to the
system's opener (`Job.openUrl`), and its command says a refusal in the echo
area and nothing once the system took it. -/
def openWork : List Argument → Work
  | [.str url] =>
    Work.of (fun _ => Job.openUrl url) fun
      | .ok () => pure ()
      | .error reason => message s!"{followName}: could not open {url}: {reason}"
  | _ => fun _ => throw s!"{openJobName}: started with no URL"

/-- Registers the commands `link-follow`, `link-next` and `link-previous`,
the job `url-open` and the links mode, under the names the core declares:
the package `link-commands`'s `setup`, and the core's tests'. -/
def setup : SetupM Unit := do
  commandWith followName follow
  commandWith nextName next
  commandWith previousName previous
  workJob openJobName openWork
  defineMode mode

end Editor.Links
