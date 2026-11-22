import CompileApi.Format
import CompileApiTest.Check
import Editor.Value

/-!
# Model tests: `CompileApi/Format.lean`

The model tests of `packages/compile-api/CompileApi/Format.lean`:
`formatDataChecks`, which were the core's (`ModelTest.formatDataChecks`)
while the vocabulary was. The test driver's root,
`CompileApiTest/Model.lean`, runs them; its module doc says what each
shows.
-/

namespace CompileApiTest

open Editor

/-- The checks of an error format as data (`packages/compile-api/CompileApi/Format.lean`):
pure, with no matcher. What a format reads in a line is the compile mode's
(`CompileTest.compileErrorChecks`). -/
def formatDataChecks : List Check :=
  [{  name :=
        "each severity's name reads back as that severity, no other word is one, and the words that name them are error, warning and note"
      run :=
        let all : List Compile.Severity := [.error, .warning, .note]
        pure
          (all.all (fun severity => Compile.Severity.ofName? severity.name == some severity) &&
            all.map (·.name) == ["error", "warning", "note"] &&
            Compile.Severity.ofName? "Error" == none &&
            Compile.Severity.ofName? "" == none &&
            Compile.Severity.words ==
              [("error", .error), ("warning", .warning), ("note", .note)]) },
    { name :=
        "a step holds its pieces and must match, and an optional step holds them and may be skipped"
      run :=
        let pieces : List Compile.Piece :=
          [{ atom := .literal ":" }, { atom := .digits, into := some .line }]
        pure
          (Compile.step pieces == { pieces, optional := false } &&
            Compile.optionalStep pieces == { pieces, optional := true }) },
    { name :=
        "a format given a name and a pattern alone counts columns from 1, takes a line that names no severity as an error, names severities by the shared words and has no continuation and no lead"
      run :=
        let format : Compile.Format :=
          { name := "f", pattern := [Compile.step [{ atom := .rest }]] }
        pure
          (format.columnBase == 1 && format.severity == .error &&
            format.severities == Compile.Severity.words &&
            format.continuation.isNone &&
            format.lead.isNone) },
    { name :=
        "the general format is named general, and its pattern captures a file and a line, then a column and a severity in steps that may be skipped, with the defaults of a format"
      run :=
        let general := Compile.Format.general
        pure
          (general.name == "general" &&
            general.pattern.flatMap (·.pieces.filterMap (·.into)) ==
              [.file, .line, .column, .severity] &&
            general.pattern.map (·.optional) == [false, true, false, true, false] &&
            general == { name := "general", pattern := general.pattern }) },
    { name :=
        "field answers the first field of a name and null for a name the fields do not hold, and optional writes a value with its encoder and none as null"
      run :=
        let fields : List (String × Value) := [("a", .nat 1), ("b", .str "x"), ("a", .nat 2)]
        pure
          (Compile.field fields "a" == .nat 1 && Compile.field fields "b" == .str "x" &&
            Compile.field fields "c" == .null &&
            Compile.optional Value.nat (some 3) == .nat 3 &&
            Compile.optional Value.nat none == .null) }]

end CompileApiTest
