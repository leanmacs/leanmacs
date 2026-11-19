import Editor.ModuleLookup

/-!
# What build the running editor is

`editor --version` (`Editor/Executable.lean`, `Editor/Main.lean`) says the app's
version, its build ID and the commit it was built from. All three are in
the bundle's `Contents/Info.plist`, where `editorApp` (lean/lakefile.lean,
`appInfoPlist`) writes them: `CFBundleShortVersionString`, the line of
`lean/app/version`; `CFBundleVersion`, the build ID; and `LeanmacsCommit`,
the commit (`plistKeys`).

This module is pure. It reads the plist through a reader function, the
port (`read`): `Editor.Main.run` passes the real file read, and the model tests
(`ModelTest.versionChecks`) a fake. An executable outside a bundle, as in
the build tree, is a development build and reads nothing. Its plist
reader (`stringOf?`) is narrow: it reads the XML text `editorApp` writes,
and refuses anything else with the reason rather than guess.

It imports only `Editor.ModuleLookup`, which says where a bundle is, and
`Editor` does not import it, so it adds nothing to what config is
elaborated on or to the bundle's modules.
-/

namespace Editor.Version

/-- What a bundle's `Info.plist` says of its build. -/
structure Stamp where
  /-- The version, `CFBundleShortVersionString`. -/
  version : String
  /-- The build ID, `CFBundleVersion`. -/
  build : String
  /-- The commit's full SHA, `LeanmacsCommit`. -/
  commit : String
  deriving DecidableEq, Repr

/-- What the running executable is. -/
inductive Build where
  /-- Run from a bundle whose `Info.plist` gave the stamp. -/
  | stamped (stamp : Stamp)
  /-- Run from outside a bundle, as from the build tree. -/
  | development
  /-- Run from a bundle whose `Info.plist` at `path` could not be read, or
  did not hold the stamp, for `reason`. -/
  | unreadable (path reason : String)
  deriving DecidableEq, Repr

/-- The keys of the version, the build ID and the commit. They must be the
ones lakefile `appInfoPlist` writes; `mise run app-check` (step 5b) runs
`editor --version` on the real plist, which shows they are. -/
def plistKeys : String × String × String :=
  ("CFBundleShortVersionString", "CFBundleVersion", "LeanmacsCommit")

/-- The string value of `key` in `plist`, the text of an XML property list:
the text between `<string>` and `</string>` after `<key>key</key>` and any
whitespace. A binary plist (one that starts `bplist`), a key that is
missing or given twice, a value that is not a `<string>`, and a value that
holds `<` or `&` (markup or an entity, which this reader does not decode)
are refused, each with a clause naming the key. -/
def stringOf? (plist key : String) : Except String String := do
  if plist.startsWith "bplist" then
    throw s!"{key}: the property list is binary, not XML"
  match plist.splitOn s!"<key>{key}</key>" with
  | [_] =>
    throw s!"{key} is missing"
  | [_, rest] =>
    let rest := rest.trimAsciiStart.toString
    let open_ := "<string>"
    unless rest.startsWith open_ do
      throw s!"{key} is not a <string>"
    match (rest.drop open_.length).toString.splitOn "</string>" with
    | value :: _ :: _ =>
      if value.any (fun c => c == '<' || c == '&') then
        throw s!"{key} holds markup or an entity: {value}"
      pure value
    | _ =>
      throw s!"{key} is not a <string>"
  | _ =>
    throw s!"{key} is given more than once"

/-- The stamp in the text of an `Info.plist`, or the first key's reason it
is not there (`stringOf?`). -/
def ofInfoPlist (plist : String) : Except String Stamp := do
  let (versionKey, buildKey, commitKey) := plistKeys
  return {
      version := ← stringOf? plist versionKey, build := ← stringOf? plist buildKey
      commit := ← stringOf? plist commitKey }

/-- The `Info.plist` of the bundle an executable at `appPath` is in, or none
outside a bundle (`ModuleLookup.bundle?`). -/
def plistPath? (appPath : String) : Option System.FilePath :=
  (ModuleLookup.bundle? appPath).map (· / "Contents" / "Info.plist")

/-- What the executable at `appPath` is, reading its bundle's `Info.plist`
with `readFile`, the port: the edge passes the real file read, with its
error as a string, and tests a fake. Outside a bundle nothing is read. -/
def read [Monad m] (appPath : String) (readFile : System.FilePath → m (Except String String)) :
    m Build := do
  match plistPath? appPath with
  | none =>
    pure .development
  | some path =>
    match ← readFile path with
    | .error reason =>
      pure (.unreadable path.toString reason)
    | .ok text =>
      match ofInfoPlist text with
      | .ok stamp =>
        pure (.stamped stamp)
      | .error reason =>
        pure (.unreadable path.toString reason)

/-- What `editor --version` prints for `build`, and its exit status: three
lines and 0 for a stamped build, one line and 0 for a development build,
and one line naming the plist and the reason, and 1, for one that could not
be read. -/
def report : Build → String × UInt32
  | .stamped stamp => (s!"Leanmacs {stamp.version}\nbuild {stamp.build}\ncommit {stamp.commit}", 0)
  | .development =>
    ("Leanmacs, a development build: not run from an app bundle, so it has no version, build ID or commit",
      0)
  | .unreadable path reason => (s!"Leanmacs: {path}: {reason}", 1)

end Editor.Version
