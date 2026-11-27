import Editor.Config.Registry
import Editor.Extension
import Editor.InputScheme.Test
import Editor.Jumps.Go
import Editor.Link
import Editor.Links
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Package
import Editor.Test.Driver
import Editor.Test.Editing
import Editor.Test.Files
import Editor.Test.Hosted
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Prompts
import FilesApiTest.Fake
import ModelTest.Support.Jumps

/-!
# Model tests: support: Links

The driver of the link checks: a hosted driver (`Editor.Test.Hosted`) over a
test package whose `setup` is the core's `Links.setup`, so its commands, the
job `url-open` and the links mode are registered as the package
`link-commands` registers them, beside `files-api`'s fake, which a location
is visited through, and the commands of the checks:

- `fill-links` makes a read-only buffer `links` of `linkRows`, one row a
  kind of target, its link over the row's word, sets its links
  (`BufferId.setLinks`) and its major mode `listing`, and shows it;
- `fill-moves` makes a buffer `moves`, `movesText`, with three links and no
  mode, and shows it;
- `fill-self` makes a buffer `self` of the same text and links, its major
  mode `self-follow`, and shows it;
- `listing` fills `activate` with `listing-visit`, which says `visited`;
- `self-follow` fills `activate` with `link-follow` itself;
- `say` says its string argument; `at` puts the cursor at the byte its
  argument names, `row` at the start of the row its argument names
  (`ModelTest/Support/Jumps.lean`), and `back` moves back through the jump
  list (`Jumps.move`);
- the resolver of the scheme `test` says `resolved` and the reference's
  rest.

The active keymaps are the registry's (`Config.Registry.activeMaps`), so a
role's key reaches the links mode first in a buffer with links. The core's
tests register the core's own functions, as `ModelTest/Support/JumpsGo.lean`
does, and never import the package. It holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The rows of the buffer `links`, each a word and the target of the link
over it; the first has none. The location is `jumpsPath`'s row 2, column 3,
in characters: that row starts with a two-byte character
(`Editor.Test.jumpFiles`), so the cursor lands on its byte 4. -/
def linkRows : List (String × Option LinkTarget) :=
  [("plain", none), ("command", some (.command { command := "say", arguments := [.str "hello"] })),
    ("location", some (.location jumpsPath 2 3)),
    ("url", some (.url "https://example.com/a b?x=1&y=2#frag")),
    ("noscheme", some (.url "example.com")), ("reference", some (.reference "test" "abc")),
    ("nope", some (.reference "nope" "x")), ("relative", some (.location "relative.txt" 0 0)),
    ("ghost", some (.command { command := "ghost" }))]

/-- The row of `linkRows` whose word is `word`, from 0. -/
def linkRow? (word : String) : Option Nat :=
  linkRows.findIdx? (·.1 == word)

/-- The text of the buffer `links`, one row of `linkRows` a line, and its
links, each over its row's word. -/
def linkBuffer : String × Array Link :=
  linkRows.foldl
    (fun (text, links) (word, target) =>
      let start := text.utf8ByteSize
      let links :=
        match target with
        | some target => links.push { start, stop := start + word.utf8ByteSize, target }
        | none => links
      (text ++ word ++ "\n", links))
    ("", #[])

/-- The text of the buffer `moves`: three links, over `one` (bytes 2 to 5),
`two` (8 to 11) and `three` (14 to 19). -/
def movesText : String :=
  "x one y two z three w\n"

/-- The links of the buffer `moves`. -/
def movesLinks : Array Link :=
  #[(2, 5, "one"), (8, 11, "two"), (14, 19, "three")].map fun (start, stop, word) =>
    { start, stop, target := .command { command := "say", arguments := [.str word] } }

/-- Makes the buffer `name` of `text` with `links`, read-only, shows it in
the call's window and sets its major mode `major`, when given. -/
def fillLinked (name text : String) (links : Array Link) (major : Option String) (call : Call) :
    EditorM Unit := do
  let .ok id ← createBuffer name text | return
  discard <| id.setLinks links
  discard <| id.setReadOnly true
  let view := call.target.window.id
  discard <| view.show id
  if let some major := major then
    discard <| view.setMajorMode major

/-- The mode `listing`, which fills `activate` with `listing-visit`. -/
def linkListing : Mode :=
  { name := "listing", roles := [(Role.activate, "listing-visit")] }

/-- The mode `self-follow`, which fills `activate` with `link-follow`
itself, as a mode that reuses the links mode's roles would. -/
def linkSelfFollow : Mode :=
  { name := "self-follow", roles := [(Role.activate, Links.followName)] }

/-- The test package of the link checks: the core's `Links.setup`, and the
commands, the mode and the resolver of the module docs. -/
def linksTestPackage : Package :=
  { name := "links-test"
    setup := do
      Links.setup
      commandWith "fill-links" fun call =>
          fillLinked "links" linkBuffer.1 linkBuffer.2 (some linkListing.name) call
      commandWith "fill-moves" (fillLinked "moves" movesText movesLinks none)
      commandWith "fill-self" (fillLinked "self" movesText movesLinks (some linkSelfFollow.name))
      commandWith "listing-visit" fun _ => message "visited"
      commandWith "say" fun call =>
          match call.arguments with
          | [.str said] => message said
          | _ => message "say: what?"
      commandWith "at" fun call =>
          match call.arguments with
          | [.nat offset] => Jumps.placeCursor call.target.window.id offset
          | _ => pure ()
      commandWith "row" fun call => do
          let row :=
            match call.arguments with
            | .nat row :: _ => row
            | _ => 0
          Jumps.placeCursor call.target.window.id (← call.target.buffer.text.offsetOf ⟨row, 0⟩)
      commandWith "back" fun call => discard <| Jumps.move call.target.window.id (-1)
      defineMode linkListing
      defineMode linkSelfFollow
      Extension.add
          ({ scheme := "test", follow := fun _ rest => message s!"resolved {rest}" } :
            Links.Resolver) }

/-- The registry of the link checks: the test package's registrations and
`files-api`'s fake's, installed as a host installs them. -/
def linkRegistry : Config.Registry :=
  hostedRegistry #[linksTestPackage, FilesApiTest.fake]

/-- The driver of the link checks over `linkRegistry`, on a buffer that
holds `jumpScratch`, with `jumpFiles` as the files its jobs reach; `none` if
making the state was refused. -/
def linkDriver : Option TestDriver :=
  let registry := linkRegistry
  let keys := hostedKeys registry
  let jobs (name : String) : Option (List Argument → Work) :=
    (registry.findJob? name).map (·.registration.workWith registry.extensionsAt)
  (Loop.Driver.over { keys with maps := registry.activeMaps TestScheme.scheme } jobs
        (holding jumpScratch #[⟨0, 0⟩]) editorModel).toOption.map
    fun driver => { driver with jobs := { files := jumpFiles } }

/-- `driver` once `name` has run with `arguments`, and every job it started
has settled (`hostedRan`). -/
def linkRan (driver : TestDriver) (name : String) (arguments : List Argument := []) : TestDriver :=
  hostedRan driver { command := name, arguments }

/-- `driver` fed the key events `events`, and every job they started
settled (`hostedSettled`). -/
def linkPressed (driver : TestDriver) (events : List Event) : TestDriver :=
  hostedSettled (fedTo driver events).1

/-- The link checks' driver once `fill-links` has shown the buffer `links`
and the cursor is at the start of the row of `word` (`linkRow?`). -/
def onLinkRow (word : String) : Option TestDriver := do
  let driver ← linkDriver
  let row ← linkRow? word
  return linkRan (linkRan driver "fill-links") "row" [.nat row]

/-- The link checks' driver once `fill-links` has shown the buffer `links`,
the cursor has been put at the start of the row of `word`, and `activate`'s
key has been pressed. -/
def activatedOn (word : String) : Option TestDriver :=
  (onLinkRow word).map (linkPressed · (rolePresses Role.activate))

/-- The echo area of `driver`. -/
def linkEcho (driver : TestDriver) : String :=
  driver.loop.state.echo

end ModelTest
