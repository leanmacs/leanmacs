import Editor.Config.Lakefile
import Lake.Toml.Load

/-!
# A lakefile's requires, read with Lake's TOML loader

The adapter that reads the names a `lakefile.toml` requires from its text
(`requires`), for the read-only package port of the config session
(`Config.PackageFiles.requires`, `Editor/Config/Session.lean`). The session
core asks it when a config file imports a module that is not linked, to
say whether the module belongs to a package the config's lakefile names
(`Editor/Config/Lakefile.lean`).

It reads the text with Lake's own loader (`Lake.Toml.loadToml`), so a
lakefile is read here as Lake reads it. Lake is not run: no workspace is
loaded, no manifest read and nothing fetched or built. A `lakefile.lean`
is not read at all: it is a program, and only Lake can say what it
requires.

It is the only module of the editor that names a Lake type, and, with the
elaborator adapter (`Editor/Config/Elaborate.lean`), one of the two that
link Lean's parser and elaborator: Lake's loader parses TOML with Lean's
parser and elaborates it. It is a core module (`Editor/Core.lean` reaches
it through the hosts, which pass `requires` to the session) and no part of
the config base: `Editor` (`Editor.lean`) does not import it, so config
cannot name it. An executable that links it already links the elaborator
adapter, so it adds Lake's TOML modules and nothing else of weight.

`config-test` runs its checks (`ConfigTest.lakefileChecks`), on lakefile
texts written in the checks.
-/

namespace Editor.Config.Lakefile.Toml

/-- The first line of what Lake's loader has to say about a text it cannot
read. -/
def reason (messages : Lean.MessageLog) : IO String := do
  let texts ← messages.toList.mapM (·.data.toString)
  return ((" ".intercalate texts).splitOn "\n").headD ""

/-- The names of the packages the lakefile whose text is `text` requires,
in order: the `name` of each table of its `require` array. A table with no
name that is a string is left out. With no `require` there is none. A text
that is not TOML is an error, in one line. -/
def requires (text : String) : IO (Except String (Array String)) := do
  let input := Lean.Parser.mkInputContext text "lakefile.toml"
  match ← (Lake.Toml.loadToml input).toBaseIO with
  | .error messages =>
    return .error (← reason messages)
  | .ok table =>
    match table.find? `require with
    | some (.array _ entries) =>
      return .ok
          (entries.filterMap fun entry =>
            match entry with
            | .table _ fields =>
              match fields.find? `name with
              | some (.string _ name) => some name
              | _ => none
            | _ => none)
    | _ =>
      return .ok #[]

end Editor.Config.Lakefile.Toml
