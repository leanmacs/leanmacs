import Editor.Invocation
import Editor.Scene

/-!
# Links

A *link* is a byte range of a buffer's text that names a target to follow
(`docs/design/text-and-display.md`, "Followable spans, as built"). A
buffer's owner sets its links beside its spans and stops
(`Buffer.links`, `BufferId.setLinks`), and, like them, nothing moves a link
on an edit: links are for a generated buffer its owner alone writes. Every
view of the buffer draws each link as a decoration in `Link.face`, under
the owner's own spans (`Editor/Loop.lean`, "Decorations").

This module is plain data and the pure lookups over it: which link holds an
offset (`Link.at?`), the next and previous link from an offset
(`Link.after`, `Link.before`), and whether a URL target is one the system
opener may be handed (`Link.urlScheme?`). Following a link and moving
between links is `Editor/Links.lean`'s.

- A target (`LinkTarget`) is a file location, a URL, a scheme reference
  (`rdm:task/x`, resolved by a registered `Links.Resolver`) or a command with
  its arguments. It is Lean data alone: it never crosses into the scene,
  which carries only the drawn decoration.
- Where two links hold the same offset, the later one in the array is the
  one followed, as a later span is drawn over an earlier one.
- A URL is followed only when it starts with a scheme, a letter then
  letters, digits, `+`, `-` or `.`, and a colon (RFC 3986's `scheme ":"`),
  and holds no ASCII control character, so a NUL or a line break never
  reaches the system opener.
- `Links.modeName` is the name of the links mode here, beside the data, so
  the registry can put that mode's keymaps first for a buffer with links
  without importing the mode (`Editor/Config/Registry.lean`, `activeMaps`).

## Where an addition goes

| Addition | Where |
|---|---|
| A new kind of target | A constructor of `LinkTarget`, its arm in `Links.followTarget` (`Editor/Links.lean`) and a check |
| A new lookup over a buffer's links | A function here, pinned in `ModelTest.linkChecks` |

Pinned by `ModelTest.linkChecks`.
-/

namespace Editor

/-- What a link names, to be followed. -/
inductive LinkTarget where
  /-- The file at `path`, at the row `row`, from 0, and the column `column`,
  in characters from the row's start, as `Place.file` names a place. The
  path is absolute: the producer resolves it. -/
  | location (path : System.FilePath) (row column : Nat)
  /-- A URL, handed to the system opener. -/
  | url (url : String)
  /-- A reference in a scheme of its own, such as `rdm:task/x` (`scheme`
  `rdm`, `rest` `task/x`), followed by the resolver registered for the
  scheme. -/
  | reference (scheme rest : String)
  /-- A command, run with its arguments. -/
  | command (invocation : Invocation)
  deriving DecidableEq, Repr

/-- A link: the bytes `start` to `stop` of a buffer's text, `stop` not
included, and the target they name. -/
structure Link where
  /-- The byte offset where it starts. -/
  start : Nat
  /-- The byte offset where it stops, not included. -/
  stop : Nat
  /-- What it names. -/
  target : LinkTarget
  deriving DecidableEq, Repr

/-- The name of the links mode (`Editor/Links.lean`, `Links.mode`), whose
keymaps go first for a buffer with links. -/
def Links.modeName : String :=
  "links"

/-- The face every link is drawn in. -/
def Link.face : FaceName :=
  ⟨"text.link"⟩

/-- The link that holds the byte `offset`, its stop not included: the last of
`links` in order that does; `none` off every link. -/
def Link.at? (links : Array Link) (offset : Nat) : Option Link :=
  links.reverse.find? fun link => link.start ≤ offset && offset < link.stop

/-- The link that starts first after the byte `offset`; `none` when none
starts after it. Of two that start at the same byte, the first in order. -/
def Link.after (links : Array Link) (offset : Nat) : Option Link :=
  links.foldl
    (fun found link =>
      if offset < link.start then
        match found with
        | some best => if link.start < best.start then some link else found
        | none => some link
      else found)
    none

/-- The link that starts last before the byte `offset`, so from inside a link
or at its first byte it is an earlier one; `none` when none starts before
it. Of two that start at the same byte, the first in order. -/
def Link.before (links : Array Link) (offset : Nat) : Option Link :=
  links.foldl
    (fun found link =>
      if link.start < offset then
        match found with
        | some best => if best.start < link.start then some link else found
        | none => some link
      else found)
    none

/-- Whether `c` may come after a scheme's first letter. -/
private def schemeChar (c : Char) : Bool :=
  c.isAlphanum || c == '+' || c == '-' || c == '.'

/-- The scheme of `url`, when it is one the system opener may be handed: it
starts with a letter then letters, digits, `+`, `-` or `.`, and a colon, and
holds no ASCII control character (below U+0020, or U+007F); `none`
otherwise. -/
def Link.urlScheme? (url : String) : Option String :=
  let chars : List Char := url.toList
  let scheme : List Char := chars.takeWhile fun c => c != ':'
  let control : Bool := chars.any fun c => c.toNat < 0x20 || c.toNat == 0x7f
  let colon : Bool := scheme.length < chars.length
  match scheme with
  | first :: rest =>
    if !control && colon && first.isAlpha && rest.all schemeChar then some (String.ofList scheme)
    else none
  | [] => none

end Editor
