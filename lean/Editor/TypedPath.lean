/-!
# A path as a person types it

What a file prompt's text means as a path, read as Emacs reads a file name
typed in the minibuffer. It is pure, and imports nothing: the file source
(`Editor/Completion/Paths.lean`) reads the directory part of the text with
it, and `open-file` resolves its answer with it (`Files.resolve`,
`Editor/Files.lean`).

- **`split`** gives the directory part, through the last `/`, and the last
  component, which is what is matched. With no `/` the directory part is
  empty.
- **`restart`** applies Emacs's `substitute-in-file-name` restarts: after a
  `//` the text starts again at its second `/`, and after a `/~/` (or a
  trailing `/~`) at the `~`, whichever comes later. So `~/proj//etc/` is
  `/etc/`, and `/srv/a/~/notes` is `~/notes`.
- **`normalize`** drops `.` components and lets `..` take back the
  component before it, lexically, as Emacs's `expand-file-name` does, with
  no file system asked. It keeps the start (`/`, `~/` or a relative text)
  and a trailing `/`. A `..` with nothing before it is kept in a relative
  text and after `~`, and dropped at the root.
- **`tidy`** is `normalize` after `restart`. It is idempotent.
- **`expand`** makes an absolute path of a text: tidied, then `~` read under
  the home directory, an absolute text as it is, and anything else under
  the directory it is read from, then normalized again, with no trailing
  `/` but for the root. With no home a `~` is refused, and with no
  directory a relative text is.
- **`abbreviate`** writes a path under the home directory with `~`, and
  `directoryText` is that with one `/` after it: a prompt's initial text.
- **`~user` is not expanded**: it is a name like any other.

## Where an addition goes

| Addition | Where | Pinned by |
|---|---|---|
| A new form of path (`~user`, an environment variable) | A case of `expand`, and of `restart` if it restarts the text | `ModelTest.typedPathChecks` |
-/

namespace Editor.TypedPath

/-- The string of `chars`. -/
private def ofChars (chars : List Char) : String :=
  String.ofList chars

/-- The directory part of `text`, through its last `/`, and its last
component; the directory part is `""` when there is no `/`. -/
def split (text : String) : String × String :=
  let chars := text.toList
  let last := (chars.reverse.takeWhile (· != '/')).reverse
  (ofChars (chars.take (chars.length - last.length)), ofChars last)

/-- `text` from its last restart: after the last `//`, from its second `/`;
after the last `/~/` or a trailing `/~`, from the `~`; whichever comes later.
A text with neither is as it is. -/
def restart (text : String) : String :=
  let chars := text.toList.toArray
  let start :=
    (List.range chars.size).foldl
      (fun start index =>
        if chars[index]? != some '/' then start
        else
          match chars[index + 1]? with
          | some '/' => index + 1
          | some '~' =>
            if chars[index + 2]? == none || chars[index + 2]? == some '/' then index + 1 else start
          | _ => start)
      0
  ofChars (chars.toList.drop start)

/-- `text` with its `.` components dropped and each `..` taking back the
component before it, lexically. Its start (`/`, `~`, `~/` or none) and a
trailing `/` are kept; a `..` with nothing before it is kept but at the
root, where it is dropped. Empty components are dropped. -/
def normalize (text : String) : String :=
  let absolute := text.startsWith "/"
  let tilde := text == "~" || text.startsWith "~/"
  let rest := if tilde then ofChars (text.toList.drop 1) else text
  let components := (rest.splitOn "/").filter (!·.isEmpty)
  let kept :=
    components.foldl
      (fun (kept : Array String) component =>
        if component == "." then kept
        else
          if component == ".." then
            match kept.back? with
            | some last => if last == ".." then kept.push component else kept.pop
            | none => if absolute then kept else kept.push component
          else kept.push component)
      #[]
  let body := "/".intercalate kept.toList
  let trailing := text.endsWith "/" && !body.isEmpty
  let start := if absolute then "/" else if text == "~" then "~" else if tilde then "~/" else ""
  start ++ body ++ if trailing then "/" else ""

/-- `text` restarted, then normalized: what it means, written tidily. -/
def tidy (text : String) : String :=
  normalize (restart text)

/-- The absolute path `text` means, read with the directory `directory` and
the home directory `home`: tidied, then `~` read under the home, an
absolute text as it is, and anything else under the directory, normalized
again, with no trailing `/` but for the root. Why not, as a sentence, when
the text needs a home or a directory there is none of. -/
def expand (text : String) (directory home : Option System.FilePath) :
    Except String System.FilePath := do
  let tidied := tidy text
  let joined ←
    if tidied == "~" || tidied.startsWith "~/" then
      match home with
      | some home =>
        pure (home.toString ++ "/" ++ ofChars (tidied.toList.drop 1))
      | none =>
        throw "the home directory is not known"
    else
      if tidied.startsWith "/" then
        pure tidied
      else
        match directory with
        | some directory =>
          pure (directory.toString ++ "/" ++ tidied)
        | none =>
          throw "no directory to read it from"
  let normal := normalize joined
  let path :=
    if normal != "/" && normal.endsWith "/" then ofChars normal.toList.dropLast else normal
  return path

/-- `path` written under the home directory `home` with `~`: `~` for the
home itself, `~/…` for a path under it, and the path as it is otherwise or
with no home. -/
def abbreviate (path : System.FilePath) (home : Option System.FilePath) : String :=
  let text := path.toString
  match home with
  | some home =>
    let homeText := home.toString
    if text == homeText then "~"
    else
      let under := if homeText.endsWith "/" then homeText else homeText ++ "/"
      if text.startsWith under then "~/" ++ ofChars (text.toList.drop under.length) else text
  | none => text

/-- The text a file prompt starts with for the directory `path`: its
abbreviation (`abbreviate`) with one `/` after it. -/
def directoryText (path : System.FilePath) (home : Option System.FilePath) : String :=
  let text := abbreviate path home
  if text.endsWith "/" then text else text ++ "/"

end Editor.TypedPath
