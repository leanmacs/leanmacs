import Editor.Command.Dispatch
import Editor.Link
import Editor.Links
import Editor.Role
import Editor.Test.Driver
import Editor.Test.Prompts
import ModelTest.Check
import ModelTest.Support.Jumps
import ModelTest.Support.Links

/-!
# Model tests: `Editor/Links.lean`

The model tests of `Editor/Links.lean`: `linkFollowChecks` and
`linkMoveChecks`, on the link checks' driver (`ModelTest/Support/Links.lean`).
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The URL of the row `url` of `linkRows`. -/
def linkUrl : String :=
  "https://example.com/a b?x=1&y=2#frag"

/-- The names of the jobs `driver` holds that have not finished. -/
def pendingNames (driver : TestDriver) : Array String :=
  driver.pending.map (·.name)

/-- `program` run in `driver`'s editor, its requests answered as the loop
answers them (the registry's questions from what the loop was told is
registered, the state's from its state, the rest from its models), except
that a command it runs inside itself is not run: its name is added to
`ran` and it is answered as run. The names it ran and the driver after its
last request; `none` once it has made `fuel` requests. -/
def ranInside {α : Type} :
    Nat → TestDriver → Array String → Program editorPort α → Option (Array String × TestDriver)
  | 0, _, _, _ => none
  | _ + 1, driver, ran, .done _ => some (ran, driver)
  | fuel + 1, driver, ran, .step (.control (.runCommand name _)) next =>
    ranInside fuel driver (ran.push name) (next true)
  | fuel + 1, driver, ran, .step (.registry request) next =>
    ranInside fuel driver ran (next (driver.keys.registered.answer request))
  | fuel + 1, driver, ran, .step (.state request) next =>
    let (reply, state) := driver.loop.state.handle request
    ranInside fuel { driver with loop := { driver.loop with state } } ran (next reply)
  | fuel + 1, driver, ran, .step request next =>
    let (reply, model) := driver.model.handle request
    ranInside fuel { driver with model } ran (next reply)

/-- The checks of following a link (`Editor/Links.lean`, "Following" and
"Each kind of target"), on the link checks' driver, `activate`'s key pressed
on the start of a row of the buffer `links`, whose mode `listing` fills
`activate` itself. -/
def linkFollowChecks : List Check :=
  [{  name :=
        "a package's command gives a span of its read-only buffer a file-location target, which the buffer then holds"
      run :=
        pure <|
          match onLinkRow "location" with
          | none => false
          | some driver =>
            match driver.loop.state.target? ⟨0⟩ with
            | none => false
            | some target =>
              target.buffer.readOnly &&
                target.buffer.links.any (·.target == .location jumpsPath 2 3) &&
                target.buffer.links == linkBuffer.2 },
    { name :=
        "activate on a URL target starts url-open with the URL, which hands that URL, and nothing else, to the system opener's model, and says nothing once it is taken"
      run :=
        pure <|
          match onLinkRow "url" with
          | none => false
          | some driver =>
            let pressed := (fedTo driver (rolePresses Role.activate)).1
            let settled := hostedSettled pressed
            pendingNames pressed == #[Links.openJobName] &&
              settled.jobs.urlOpener.opened == #[linkUrl] &&
              linkEcho settled == "" },
    { name := "a URL the system opener refuses is said in the echo area with its reason"
      run :=
        pure <|
          match onLinkRow "url" with
          | none => false
          | some driver =>
            let refusing :=
              { driver with
                jobs := { driver.jobs with urlOpener := { refusal := some "no handler" } } }
            let settled := linkPressed refusing (rolePresses Role.activate)
            settled.jobs.urlOpener.opened.isEmpty &&
              linkEcho settled == s!"link-follow: could not open {linkUrl}: no handler" },
    { name := "activate on a URL with no scheme says it is not a URL and starts no job"
      run :=
        pure <|
          match onLinkRow "noscheme" with
          | none => false
          | some driver =>
            let pressed := (fedTo driver (rolePresses Role.activate)).1
            pressed.pending.isEmpty && pressed.jobs.urlOpener.opened.isEmpty &&
              linkEcho pressed == "link-follow: `example.com` is not a URL" },
    { name :=
        "activate on a command target runs that command with its argument, and in a mode that fills activate the mode's handler does not run"
      run := pure <| (activatedOn "command").map linkEcho == some "hello" },
    { name := "in a mode that fills activate, activate off a target runs the mode's handler"
      run := pure <| (activatedOn "plain").map linkEcho == some "visited" },
    { name :=
        "activate on a file location opens the file at its row and its column in characters, and records the link's place as a jump"
      run :=
        pure <|
          match activatedOn "location" with
          | none => false
          | some driver =>
            let file := driver.loop.state.target? ⟨0⟩ |>.bind (·.buffer.file) |>.map (·.path)
            -- The row starts with a two-byte character: its character 3 is
            -- its byte 4, as the cursor is written.
            file == some jumpsPath && cursorOf driver == some "2@2:4" &&
              (jumpsOf driver).map (·.1.getLast?) == some (some "1@2:0") },
    { name :=
        "after following a file location, C-o shows the buffer again, the cursor on the link's first byte"
      run :=
        pure <|
          match activatedOn "location" with
          | none => false
          | some driver => cursorOf (linkRan driver "back") == some "1@2:0" },
    { name := "activate on a location whose path is relative says so, and goes nowhere"
      run :=
        pure <|
          match activatedOn "relative" with
          | none => false
          | some driver =>
            linkEcho driver == "link-follow: `relative.txt` is not an absolute path" &&
              cursorOf driver == some "1@7:0" },
    { name :=
        "activate on a scheme reference calls the resolver registered for its scheme with its rest, and one with no resolver says nothing follows its scheme"
      run :=
        pure <|
          (activatedOn "reference").map linkEcho == some "resolved abc" &&
            (activatedOn "nope").map linkEcho ==
              some "link-follow: nothing follows `nope:` links" },
    { name :=
        "activate on a link inside a folded range does not follow it: the link is hidden, so the buffer's own activate runs"
      run :=
        pure <|
          (linkDriver.map fun driver =>
              linkEcho
                (linkPressed (linkRan (linkRan driver "fill-folded") "at" [.nat 8])
                  (rolePresses Role.activate))) ==
            some "visited" },
    { name := "activate on a command no one registered says there is no such command"
      run := pure <| (activatedOn "ghost").map linkEcho == some "ghost: no such command" },
    { name :=
        "activate off a link in a buffer whose modes fill no activate says there is no link at the cursor"
      run :=
        pure <|
          (linkDriver.map fun driver =>
              linkEcho (linkPressed (linkRan driver "fill-moves") (rolePresses Role.activate))) ==
            some "link-follow: no link at the cursor" },
    { name :=
        "activate off a link in a buffer whose own mode fills activate with link-follow says there is no link at the cursor, and does not run link-follow again"
      run :=
        pure <|
          let said := "link-follow: no link at the cursor"
          match linkDriver.map fun driver => linkRan (linkRan driver "fill-self") "at" [.nat 0] with
          | none => false
          | some off =>
            match off.loop.state.target? ⟨0⟩ with
            | none => false
            | some target =>
              -- `link-follow` run by hand first, a command it runs inside
              -- itself recorded and not run: were it to run itself again,
              -- that fails here, where pressing the key would never come
              -- back. Only once it does not is the key pressed.
              match ranInside 100 off #[] (Links.follow { target }).run with
              | none => false
              | some (ran, followed) =>
                if ran.isEmpty && linkEcho followed == said then
                  linkEcho (linkPressed off (rolePresses Role.activate)) == said
                else false }]

/-- The head of the cursor of the view 0 of `driver`, as a byte offset. -/
def linkHead (driver : TestDriver) : Option Nat :=
  (selectionOf driver).bind fun selection => selection.ranges[0]?.map (·.head)

/-- The link checks' driver on the buffer `moves`, its cursor at the byte
`offset`. -/
def onMoves (offset : Nat) : Option TestDriver :=
  linkDriver.map fun driver => linkRan (linkRan driver "fill-moves") "at" [.nat offset]

/-- The checks of moving between links (`Editor/Links.lean`, "Moving"), on
the link checks' driver in the buffer `moves`, which holds three links, by
the keys of the roles `next-link` and `previous-link`. -/
def linkMoveChecks : List Check :=
  let next := rolePresses Role.nextLink
  let previous := rolePresses Role.previousLink
  [{  name :=
        "next-link steps across the three links to each one's first byte, and at the last says there is none after the cursor and leaves it"
      run :=
        pure <|
          match onMoves 0 with
          | none => false
          | some driver =>
            let one := linkPressed driver next
            let two := linkPressed one next
            let three := linkPressed two next
            let past := linkPressed three next
            linkHead one == some 2 && linkHead two == some 8 && linkHead three == some 14 &&
              linkHead past == some 14 &&
              linkEcho past == "link-next: no link after the cursor" },
    { name :=
        "previous-link steps back across the three links to each one's first byte, and at the first says there is none before the cursor and leaves it"
      run :=
        pure <|
          match onMoves 21 with
          | none => false
          | some driver =>
            let three := linkPressed driver previous
            let two := linkPressed three previous
            let one := linkPressed two previous
            let past := linkPressed one previous
            linkHead three == some 14 && linkHead two == some 8 && linkHead one == some 2 &&
              linkHead past == some 2 &&
              linkEcho past == "link-previous: no link before the cursor" },
    { name :=
        "from inside a link, next-link lands on the next link's first byte and previous-link on the first byte of the link it is in"
      run :=
        pure <|
          (onMoves 3).bind (linkHead <| linkPressed · next) == some 8 &&
            (onMoves 9).bind (linkHead <| linkPressed · previous) == some 8 },
    { name :=
        "next-link and previous-link pass over a link inside a folded range, to the first link after it and the last before it"
      run :=
        pure <|
          let onFolded (offset : Nat) : Option TestDriver :=
            linkDriver.map fun driver => linkRan (linkRan driver "fill-folded") "at" [.nat offset]
          (onFolded 2).bind (linkHead <| linkPressed · next) == some 14 &&
            (onFolded 14).bind (linkHead <| linkPressed · previous) == some 2 &&
            (onFolded 0).bind (linkHead <| linkPressed · next) == some 2 }]

end ModelTest
