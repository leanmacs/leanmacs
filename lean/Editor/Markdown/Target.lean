import Editor.Link

/-!
# Link targets of rendered Markdown

What a Markdown link's destination, and a bare reference in rendered text,
names to follow (`LinkTarget`, `Editor/Link.lean`), for the rendered view
(`docs/design/text-and-display.md`, "Rendered markdown, as built"). Pure.

## A destination (`targetOf`)

- **As written**: a destination in angle brackets (`<a b.md>`) is read
  without them, and a backslash before an ASCII punctuation character is
  that character (`a\_b.md` is `a_b.md`). Percent-encoding is not decoded.
- **A web scheme** (`http`, `https`, `mailto`, `ftp`, `file`, in any case)
  is a URL, as it is.
- **A path with a line** is a location: `path:line` or
  `path:line:column`, the path holding a `/` or a `.` and no `:`, the line
  (and the column, if given) whole numbers of at least 1. Its row is
  `line - 1` and its column `column - 1`, or 0.
- **Any other scheme** (a letter, then letters, digits, `+`, `-` or `.`,
  and a colon, as `Link.urlScheme?` reads one) is a reference in that
  scheme: `rdm:task/x` is `.reference "rdm" "task/x"`, which the scheme's
  resolver follows.
- **Anything else is a path**, at its first row and column.
- **A path's fragment and query are left out**: everything from its first
  `#` or `?` is dropped before its line is read, so `x.md:3#sec` is row 2
  of `x.md`. A URL and a reference keep theirs, for whatever follows them.
- **A path is absolute or resolved against the root**: an absolute one is
  used as it is, a relative one is joined to `root`, and with no root it is
  not linked.
- An empty destination, and one that starts with `#` (a heading in the
  same document), are not linked.

## A reference in text (`references`)

In rendered prose and inside code spans (never in fenced code), a *token*
is a run of characters that are not blanks and not one of `()[]<>"'` or a
backtick, with any trailing `.,;:!?` dropped. A token is a link when it is:

- a URL: it starts with `http://` or `https://` and has more after;
- a location: `path:line` or `path:line:column`, by the rule above, its
  path resolved against the root as above.

Each is answered as its byte range in the text and its target.

## Where an addition goes

| Addition | Where |
|---|---|
| A scheme followed as a URL | `webSchemes` |
| Another kind of bare reference | `referenceOf?`, and a check |

Pinned by `ModelTest.markdownTargetChecks`.
-/

namespace Editor.Markdown

/-- The schemes a destination is followed as a URL in, lower case. -/
def webSchemes : List String :=
  ["http", "https", "mailto", "ftp", "file"]

/-- `path` resolved against `root`: as it is when absolute, joined to
`root` when relative, and `none` when relative with no root. -/
def resolve (root : Option System.FilePath) (path : String) : Option System.FilePath :=
  if path.startsWith "/" then some path else root.map (· / path)

/-- The whole number `text` spells, when it is one of at least 1. -/
private def positive? (text : String) : Option Nat :=
  if !text.isEmpty && text.all Char.isDigit then
    match text.toNat? with
    | some number => if number ≥ 1 then some number else none
    | none => none
  else none

/-- The path, row and column of `text` when it is `path:line` or
`path:line:column` ("A destination", in the module docs), before the path
is resolved. -/
def lineOf? (text : String) : Option (String × Nat × Nat) :=
  let pathOk (path : String) : Bool := (path.any (· == '/') || path.any (· == '.'))
  match text.splitOn ":" with
  | [path, line] =>
    if pathOk path then (positive? line).map fun line => (path, line - 1, 0) else none
  | [path, line, column] =>
    if pathOk path then do
      let line ← positive? line
      let column ← positive? column
      return (path, line - 1, column - 1)
    else none
  | _ => none

/-- The location `text` names when it is `path:line` or
`path:line:column`, its path resolved against `root`. -/
def locationOf? (root : Option System.FilePath) (text : String) : Option LinkTarget := do
  let (path, row, column) ← lineOf? text
  let file ← resolve root path
  return .location file row column

/-- `text` with each backslash before an ASCII punctuation character made
that character ("A destination", in the module docs); any other backslash
is kept. -/
def unescape (text : String) : String :=
  let punctuation := "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
  let (chars, escaping) :=
    text.toList.foldl
      (fun (chars, escaping) c =>
        if escaping then
          if punctuation.any (· == c) then (chars.push c, false)
          else ((chars.push '\\').push c, false)
        else if c == '\\' then (chars, true) else (chars.push c, false))
      ((#[] : Array Char), false)
  String.ofList (if escaping then chars.push '\\' else chars).toList

/-- `destination` as written ("A destination", in the module docs): its
blanks at either end and one pair of enclosing angle brackets left out, and
its backslash escapes decoded. -/
def written (destination : String) : String :=
  let destination := destination.trimAscii.toString
  let bare :=
    if destination.length ≥ 2 && destination.startsWith "<" && destination.endsWith ">" then
      String.ofList (destination.toList.drop 1).dropLast
    else destination
  unescape bare

/-- The path of a path destination: everything from its first `#` or `?`
left out. -/
def pathPart (destination : String) : String :=
  String.ofList (destination.toList.takeWhile fun c => c != '#' && c != '?')

/-- The location the path destination `destination` names, its fragment
and query left out, resolved against `root`: at its line, if it has one,
or at its first row. -/
def pathTarget (root : Option System.FilePath) (destination : String) : Option LinkTarget :=
  let path := pathPart destination
  if path.isEmpty then none
  else
    match lineOf? path with
    | some _ => locationOf? root path
    | none => (resolve root path).map fun file => .location file 0 0

/-- What the destination `destination` of a link names ("A destination",
in the module docs), resolved against `root`; `none` when it is not
linked. -/
def targetOf (root : Option System.FilePath) (destination : String) : Option LinkTarget :=
  let destination := written destination
  if destination.isEmpty || destination.startsWith "#" then none
  else
    match Link.urlScheme? destination with
    | some scheme =>
      if webSchemes.contains scheme.toLower then some (.url destination)
      else
        match lineOf? (pathPart destination) with
        | some _ => pathTarget root destination
        | none => some (.reference scheme (destination.drop (scheme.length + 1)).toString)
    | none => pathTarget root destination

/-- Whether `c` ends a token ("A reference in text", in the module docs). -/
private def delimits (c : Char) : Bool :=
  c.isWhitespace || "()[]<>\"'`".any (· == c)

/-- What the token `token` names as a bare reference, resolved against
`root`: a URL or a location; `none` for any other token. -/
def referenceOf? (root : Option System.FilePath) (token : String) : Option LinkTarget :=
  let web :=
    ["http://", "https://"].any fun scheme =>
      token.startsWith scheme && token.length > scheme.length
  if web then some (.url token) else locationOf? root token

/-- The bare references of `text` ("A reference in text", in the module
docs), each as its byte range and its target, in order. -/
def references (root : Option System.FilePath) (text : String) : Array (Nat × Nat × LinkTarget) :=
  let close (found : Array (Nat × Nat × LinkTarget)) (token : List Char) (stop : Nat) :
    Array (Nat × Nat × LinkTarget) :=
    let kept := (token.reverse.dropWhile fun c => ".,;:!?".any (· == c)).reverse
    let dropped := (token.drop kept.length).foldl (fun size c => size + c.utf8Size) 0
    let word := String.ofList kept
    let start := stop - (token.foldl (fun size c => size + c.utf8Size) 0)
    match referenceOf? root word with
    | some target => if kept.isEmpty then found else found.push (start, stop - dropped, target)
    | none => found
  let (found, token, offset) :=
    text.toList.foldl
      (fun (found, token, offset) c =>
        if delimits c then (close found token offset, [], offset + c.utf8Size)
        else (found, token ++ [c], offset + c.utf8Size))
      (#[], [], 0)
  close found token offset

end Editor.Markdown
