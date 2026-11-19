import Editor
import Compile
open Editor

-- A config that names the compile mode's declarations, so it elaborates
-- only on a base that holds them: a shipped contribution with one field
-- overridden, a contribution of its own with a format of its own, the
-- commands of one project, and a command that reads a line with that
-- format and names the modes that ship.

/-- A format of config's own: `at <file> line <n>`. -/
def atFormat : Compile.Format :=
  { name := "at"
    pattern :=
      [Compile.step
          [{ atom := .literal "at " }, { atom := .noneOf [' '], into := some .file },
            { atom := .literal " line " }, { atom := .digits, into := some .line }]] }

/-- Says what `atFormat` reads of a line, and the modes of the shipped
contributions, in the echo area. -/
def reading : EditorM Unit :=
  let read := (atFormat.read? "at src/x.rs line 4").map fun reading => (reading.file, reading.line)
  message s!"at reads {read}; the shipped modes are {Compile.shipped.map (·.mode)}"

def setup : SetupM Unit := do
  compileContribution
      { Compile.cargoMode with commands := #[{ name := "build", line := "cargo build --release" }] }
  compileContribution
      { mode := "a-mode", markers := #["a.toml"], commands := #[{ name := "build", line := "make" }]
        formats := #[atFormat] }
  projectCommands (.remote "github.com/o/r") "a-mode" [("lint", "make lint")]
      [("profile", .str "dev")]
  command "compile-reading" reading
