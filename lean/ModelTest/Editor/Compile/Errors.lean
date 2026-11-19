import Editor.Compile
import Editor.Compile.Errors
import Editor.ProjectMode.Format
import Editor.Store
import Editor.Value
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Compile

/-!
# Model tests: `Editor/Compile/Errors.lean`

The model tests of `Editor/Compile/Errors.lean`: `compileErrorChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The format `general` with a continuation: a following line that starts
with blanks continues a location. -/
def indentedFormat : Compile.Format :=
  { Compile.Format.general with
    name := "indented"
    continuation := some [{ pieces := [{ atom := .blanks }] }, { pieces := [{ atom := .rest }] }] }

/-- The checks of error formats, the matcher, sites and `resolve`
(`Editor/Compile/Errors.lean`): pure, with no driver. -/
def compileErrorChecks : List Check :=
  let general := Compile.Format.general
  [{  name :=
        "a format with a lead makes the line before a location its site's first row, with the lead's severity and message; in one scan, across two with the previous line handed in, and with no lead before it a plain site"
      run :=
        let lines := #["warning: unused x", "  at a.rs:4"]
        let one := Compile.scan #[leadFormat] "/r" #[] 1 100 lines
        let two :=
          Compile.scan #[leadFormat] "/r" (Compile.scan #[leadFormat] "/r" #[] 1 100 #[lines[0]!]) 2
            118 #[lines[1]!] (previous := some lines[0]!)
        let bare := Compile.scan #[leadFormat] "/r" #[] 1 100 #["plain", "  at a.rs:4"]
        pure
          (one ==
              #[{ file := "/r/a.rs", line := 4, column := none, columnBase := 1
                  severity := .warning, format := "t-lead", first := 1, last := 2, start := 123
                  stop := 129, message := some "unused x" }] &&
            two == one &&
            bare.map (fun site => (site.first, site.last, site.severity, site.message)) ==
              #[(2, 2, .error, none)]) },
    { name :=
        "a lead whose row the last site covers is not joined to the next location, and a lead's severity yields to one the location line captured"
      run :=
        let earlier : Compile.Site :=
          { file := "/r/b.rs", line := 1, column := none, columnBase := 1, severity := .error
            format := "general", first := 1, last := 1, start := 0, stop := 6 }
        let covered :=
          Compile.scan #[leadFormat] "/r" #[earlier] 2 9 #["  at a.rs:4"] (previous :=
            some "error: e")
        let captured := Compile.scan #[leadFormat] "/r" #[] 1 0 #["error: e", "  at a.rs:4 note"]
        pure
          (covered.map
                (fun site => (site.format, site.first, site.last, site.severity, site.message)) ==
              #[("general", 1, 1, .error, none), ("t-lead", 2, 2, .error, none)] &&
            captured.map (fun site => (site.first, site.severity, site.message)) ==
              #[(1, .note, some "e")]) },
    { name :=
        "a site with a message crosses as a tree and back, and a site's tree with no message field, written before messages were kept, reads with none"
      run :=
        let site : Compile.Site :=
          { file := "/r/a.rs", line := 4, column := some 2, columnBase := 1, severity := .error
            format := "t-lead", first := 3, last := 5, start := 40, stop := 48
            message := some "mismatched types" }
        let older :=
          match ({ site with message := none } : Compile.Site).encode with
          | .record fields => Value.record (fields.filter (·.1 != "message"))
          | other => other
        pure
          (Compile.Site.decode site.encode == some site &&
            Compile.Site.decode older == some { site with message := none }) },
    { name :=
        "locations criterion 1: the general format reads src/main.rs:12:5: error: expected one of as src/main.rs, line 12, column 5, an error, and lib.lean:3: warning: unused with no column"
      run :=
        pure
          (general.read? "src/main.rs:12:5: error: expected one of" ==
              some
                { file := "src/main.rs", line := 12, column := some 5, severity := .error
                  start := 0, stop := 16 } &&
            general.read? "lib.lean:3: warning: unused" ==
              some
                { file := "lib.lean", line := 3, column := none, severity := .warning, start := 0
                  stop := 10 }) },
    { name :=
        "the general format reads a note as a note and a line with no severity word as an error, and the header, a help line, the last line and an empty line as no location"
      run :=
        pure
          ((general.read? "note.txt:7: note: here").map (·.severity) == some .note &&
            (general.read? "a.c:3: something").map (·.severity) == some .error &&
            ["r@main in /r: make", "  = help: add a semicolon", "Compilation finished after 1.5 s",
                  ""].all
              (general.read? · == none)) },
    { name :=
        "a location's start and stop are byte offsets: αβ.rs:3:4: error: x reads its location text as bytes 0 to 11, the bytes of its nine characters"
      run :=
        pure
          (general.read? "αβ.rs:3:4: error: x" ==
            some
              { file := "αβ.rs", line := 3, column := some 4, severity := .error, start := 0
                stop := 11 }) },
    { name :=
        "scan steps each line on by its bytes: after a line of two-byte characters the next location starts and stops at its bytes, and a location in a line of them stops at its bytes"
      run :=
        let lines := #["größe wär", "a.rs:1:2: error: x", "αβ.rs:3: warning: y"]
        pure
          ((Compile.scan #[Compile.Format.general] "/r" #[] 1 100 lines).map
              (fun site => (site.file.toString, site.first, site.start, site.stop)) ==
            #[("/r/a.rs", 2, 113, 121), ("/r/αβ.rs", 3, 132, 141)]) },
    { name :=
        "locations criterion 2: a format with a continuation joins a location line and its following indented line into one location, in one scan or across two; with the general format they stay apart, and a line that matches nothing stops the join"
      run :=
        let lines := #["a.rs:1:2: error: x", "    more", "b.rs:3: warning: y"]
        let joined := Compile.scan #[indentedFormat] "/r" #[] 1 100 lines
        let inTwo :=
          Compile.scan #[indentedFormat] "/r"
            (Compile.scan #[indentedFormat] "/r" #[] 1 100 #["a.rs:1:2: error: x"]) 2 119
            #["    more", "b.rs:3: warning: y"]
        let apart := Compile.scan #[general] "/r" #[] 1 100 lines
        let stopped :=
          Compile.scan #[indentedFormat] "/r" #[] 1 100 #["a.rs:1:2: error: x", "plain", "    more"]
        pure
          (joined ==
              #[{ file := "/r/a.rs", line := 1, column := some 2, columnBase := 1
                  severity := .error, format := "indented", first := 1, last := 2, start := 100
                  stop := 108 },
                { file := "/r/b.rs", line := 3, column := none, columnBase := 1
                  severity := .warning, format := "indented", first := 3, last := 3
                  start := 128, stop := 134 }] &&
            inTwo == joined &&
            apart.map (fun site => (site.first, site.last)) == #[(1, 1), (3, 3)] &&
            stopped.map (fun site => (site.first, site.last)) == #[(1, 1)]) },
    { name :=
        "locations criterion 6: a relative file resolves against the directory, with . and .. taken lexically, and an absolute one is kept"
      run :=
        pure
          (Compile.resolve "/r" "src/main.rs" == "/r/src/main.rs" &&
            Compile.resolve "/r" "./src/b.lean" == "/r/src/b.lean" &&
            Compile.resolve "/r" "../w/src/b.lean" == "/w/src/b.lean" &&
            Compile.resolve "/r/sub" "../src/a.lean" == "/r/src/a.lean" &&
            Compile.resolve "/r" "/abs/x.rs" == "/abs/x.rs") },
    { name := "a site crosses as a tree and back, with a column and without"
      run :=
        let site : Compile.Site :=
          { file := "/r/a.rs", line := 4, column := some 2, columnBase := 0, severity := .note
            format := "general", first := 3, last := 5, start := 40, stop := 48 }
        pure
          (Compile.Site.decode site.encode == some site &&
            Compile.Site.decode { site with column := none }.encode ==
              some { site with column := none } &&
            Compile.Site.decode (.str "a.rs") == none) },
    { name :=
        "a scope's record crosses as a tree and back with its locations and its current one, and a tree of the record's old shape, with neither, is none"
      run :=
        let site : Compile.Site :=
          { file := "/r/a.rs", line := 4, column := some 2, columnBase := 1, severity := .error
            format := "general", first := 1, last := 1, start := 20, stop := 28 }
        let record : Compile.Record :=
          { buffer := some 2, last := some ("make", "/r"), runs := 3
            locations :=
              #[site,
                { site with
                  first := 2, last := 2 }],
            current := some 1 }
        pure
          (Compile.Record.decode record.encode == some record &&
            Compile.Record.decode
                { record with
                    current := none, locations := #[] }.encode ==
              some
                { record with
                  current := none, locations := #[] } &&
            Compile.Record.decode
                (.record
                  [("buffer", .null), ("last", .null), ("runs", .nat 0), ("running", .null)]) ==
              none &&
            Compile.store.version == 3 &&
            Compile.directoryStore.version == 3) }]

end ModelTest
