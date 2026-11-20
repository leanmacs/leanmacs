import Editor.Restore.Document
import ModelTest.Check

/-!
# Model tests: `Editor/Restore/Document.lean`

The model tests of `Editor/Restore/Document.lean`: `restoreDocumentChecks`,
pure. The root module `ModelTest` runs them; its module doc says what each
shows.
-/

namespace ModelTest

open Editor
open Editor.Restore

namespace RestoreDocumentTest

/-- An index of run 3 with a file buffer in two windows and a scratch buffer
with a journal. -/
def sample : Document :=
  { run := 3, focused := some 2
    buffers :=
      #[{ key := 1, name := "a.txt"
          file :=
            some { path := "/r/a.txt", stamp := { seconds := 9, nanoseconds := 1, size := 40 } }
          lineEnding := .crlf, major := some "code", minors := #["outline", "spell"]
          language := some "lean", journal := some { key := 1, generation := 2 }
          views :=
            #[{ view := 0, anchor := ⟨1, 2⟩, head := ⟨3, 4⟩, top := 1 },
              { view := 2, anchor := ⟨0, 0⟩, head := ⟨0, 5⟩, top := 0 }] },
        { key := 0, name := "scratch", journal := some { key := 0, generation := 1 } }] }

/-- An index of a newer format, with keys this editor does not know at the
top and in a buffer, and an entry that does not parse. -/
def newerText : String :=
  "{\"format\":99,\"run\":5,\"ended\":false,\"layouts\":[1,2],\"buffers\":[{\"key\":0,\"name\":\"b.txt\",\"lineEnding\":\"lf\",\"folds\":[],\"views\":[]},{\"key\":\"x\"}]}"

/-- `sample` with every key format 2 added: a frame, the workspace table, a
declared store's cell, a running job, and a view's jumps. -/
def full : Document :=
  { sample with
    buffers :=
      sample.buffers.modify 0 fun buffer =>
        { buffer with
          views :=
            buffer.views.modify 0 fun place =>
              { place with
                jumps :=
                  some
                    { entries := #[.kept 1 0 2, .file "/r/b.txt" 4 0], index := 1
                      previous := some (.kept 0 3 3) } } }
    frame :=
      some
        { selected := 1, chosen := some .monocle
          tabs :=
            #[{ windows := #[0], focused := 0 },
              { name := some "two", windows := #[2, 5],
                layout := .splits (.split .rows 1 1 .tile .tile)
                focused := 2, lastFocused := some 5 }]
          elsewhere := #[(5, "*restore*")] }
    workspaces :=
      some
        { workspaces :=
            #[{ location := .local "/r", branch := some (.named "main"), project := .root "/r"
                cells :=
                  #[{ owner := "shell", name := "shell-history", version := 1,
                      value := .list [.str "make"] }] }]
          projects := #[{ identity := .root "/r", name := "r" }] }
    stores := #[{ owner := "config", name := "kept", version := 1, value := .nat 2 }]
    jobs :=
      #[{ owner := "shell", name := "shell-run", key := some "shell outside" },
        { owner := "x", name := "y" }] }

/-- An index as phase 1 wrote it, format 1, kept as it was written. -/
def formatOne : String :=
  "{\"format\":1,\"run\":4,\"ended\":false,\"focused\":0,\"buffers\":[{\"key\":0,\"name\":\"scratch\",\"lineEnding\":\"lf\",\"journal\":{\"key\":0,\"generation\":1},\"views\":[{\"view\":0,\"anchor\":[0,1],\"head\":[0,1],\"top\":0}]}]}"

/-- What reading `text` as `name` came to. -/
def readAs (name text : String) : Document.Read :=
  Document.read name text

end RestoreDocumentTest

open RestoreDocumentTest in
/-- The checks of the session index (`Editor/Restore/Document.lean`). -/
def restoreDocumentChecks : List Check :=
  [{  name :=
        "an index of this editor's format written and read again is the index, with nothing to say"
      run :=
        pure <|
          let read := readAs "session-3.json" sample.render
          read.document == some sample && !read.newer && read.report.isEmpty },
    { name :=
        "an index of a newer format is read leniently: its known fields read, each key it does not know named, at the top and in a buffer"
      run :=
        pure <|
          let read := readAs "session-5.json" newerText
          read.newer &&
            (read.document.map fun document =>
                (document.format, document.run, document.buffers.map (·.name))) ==
              some (99, 5, #["b.txt"]) &&
            read.report ==
              #["session-5.json is of format 99, newer than this editor's 2: what is known of it is restored, and it is left as it is",
                "session-5.json: the key layouts is not known",
                "session-5.json: buffer 0: the key folds is not known",
                "session-5.json: buffer entry 2 does not parse and is skipped"] },
    { name :=
        "an index of format 2 with every key it added round-trips: the frame, the workspaces, the stores, the jobs and a view's jumps, with nothing to say"
      run :=
        pure <|
          let read := readAs "session-3.json" full.render
          read.document == some full && read.report.isEmpty && !read.newer },
    { name :=
        "an index of format 1, as phase 1 wrote it, is read fully: no frame, no workspaces, no stores, no jobs, nothing to say"
      run :=
        pure <|
          let read := readAs "session-4.json" formatOne
          !read.newer && read.report.isEmpty &&
            read.document ==
              some
                { format := 1, run := 4, focused := some 0
                  buffers :=
                    #[{ key := 0, name := "scratch", journal := some { key := 0, generation := 1 }
                        views :=
                          #[{ view := 0, anchor := ⟨0, 1⟩, head := ⟨0, 1⟩, top := 0 }] }] } },
    { name :=
        "an index of format 3 with keys this editor does not know inside the frame is read leniently: the frame read, the top keys named"
      run :=
        pure <|
          let text :=
            "{\"format\":3,\"run\":6,\"buffers\":[],\"frame\":{\"selected\":0,\"stacks\":[],\"tabs\":[{\"windows\":[0],\"docked\":[],\"floats\":[],\"layout\":\"monocle\",\"focused\":0,\"pane\":1}]},\"later\":1}"
          let read := readAs "session-6.json" text
          read.newer &&
            (read.document.bind (·.frame)) ==
              some { tabs := #[{ windows := #[0], layout := .monocle, focused := 0 }] } &&
            read.report ==
              #["session-6.json is of format 3, newer than this editor's 2: what is known of it is restored, and it is left as it is",
                "session-6.json: the key later is not known"] },
    { name :=
        "a format-2 index with the keys format 2 added removed and its format set to 1 reads as the same buffers"
      run :=
        pure <|
          let stripped : Document :=
            { full with
              format := 1, frame := none, workspaces := none, stores := #[], jobs := #[]
              buffers :=
                full.buffers.map fun buffer =>
                  { buffer with views := buffer.views.map ({ · with jumps := none }) } }
          let read := readAs "session-3.json" stripped.render
          let plain := readAs "session-3.json" full.render
          (read.document.map (·.buffers)) ==
              (plain.document.map fun document =>
                document.buffers.map fun buffer =>
                  { buffer with views := buffer.views.map ({ · with jumps := none }) }) &&
            read.report.isEmpty },
    { name :=
        "a store or a job entry that does not parse is skipped and said, and a frame or workspaces that do not parse are read as none and said"
      run :=
        pure <|
          let text :=
            "{\"format\":2,\"run\":2,\"buffers\":[],\"frame\":{\"tabs\":1},\"workspaces\":{\"workspaces\":3},\"stores\":[{\"owner\":\"config\"},{\"owner\":\"config\",\"name\":\"n\",\"version\":1,\"value\":null}],\"jobs\":[{\"name\":1}]}"
          let read := readAs "session-2.json" text
          (read.document.map fun document =>
                (document.frame.isNone, document.workspaces.isNone, document.stores.map (·.name),
                  document.jobs.size)) ==
              some (true, true, #["n"], 0) &&
            read.report ==
              #["session-2.json: its frame does not parse and is not restored",
                "session-2.json: its workspaces do not parse and are not restored",
                "session-2.json: store entry 1 does not parse and is skipped",
                "session-2.json: job entry 1 does not parse and is skipped"] },
    { name := "a buffer entry that does not parse is skipped and said; the others are read"
      run :=
        pure <|
          let text :=
            "{\"format\":1,\"run\":2,\"buffers\":[{\"name\":1},{\"key\":4,\"name\":\"n\",\"lineEnding\":\"lf\"}]}"
          let read := readAs "session-2.json" text
          (read.document.map (·.buffers.map (·.key))) == some #[4] &&
            read.report == #["session-2.json: buffer entry 1 does not parse and is skipped"] },
    { name := "a file that is not JSON is said and read as nothing"
      run :=
        pure <|
          let read := readAs "session-4.json" "not json"
          read.document.isNone && read.report.size == 1 &&
            (read.report[0]!).startsWith "session-4.json does not parse (" &&
            (read.report[0]!).endsWith "): it is left as it is" },
    { name :=
        "choosing: the index of the highest run is restored whatever its format; those of a format this editor understands are to be removed, and a newer or unreadable one is left and said once"
      run :=
        pure <|
          let choice :=
            Document.choose
              #[(5, readAs "session-5.json" newerText),
                (2, readAs "session-2.json" { sample with run := 2 }.render),
                (4, readAs "session-4.json" "not json"), (3, readAs "session-3.json" sample.render)]
          (choice.restored.map (·.run)) == some 5 && choice.remove == #[2, 3] &&
            choice.report.size == 5 &&
            (choice.report.filter (·.startsWith "session-4.json")).size == 1 },
    { name := "choosing: a highest index that says ended restores none, and is still to be removed"
      run :=
        pure <|
          let choice :=
            Document.choose
              #[(3, readAs "session-3.json" { sample with ended := true }.render),
                (2, readAs "session-2.json" { sample with run := 2 }.render)]
          choice.restored.isNone && choice.remove == #[2, 3] },
    { name :=
        "choosing: an unreadable highest index restores none, and an understood lower one is not taken in its place"
      run :=
        pure <|
          let choice :=
            Document.choose
              #[(4, readAs "session-4.json" "{"),
                (2, readAs "session-2.json" { sample with run := 2 }.render)]
          choice.restored.isNone && choice.remove == #[2] },
    { name :=
        "the next run is one more than the largest found in index names, index runs and journal names; names of neither are passed over"
      run :=
        pure <|
          nextRun #["session-3.json", "7-2-1.log", "7-2-1.base", "notes.txt", "session-x.json"]
                #[4] ==
              8 &&
            nextRun #[] #[] == 1 &&
            nextRun #["session-12.json"] #[30] == 31 },
    { name := "journal names and index names are read back"
      run :=
        pure <|
          journalOf? s!"{journalStem 3 4 5}.base" == some (3, 4, 5, true) &&
            journalOf? s!"{journalStem 3 4 5}.log" == some (3, 4, 5, false) &&
            journalOf? "3-4.log" == none &&
            runOfIndex? (indexName 9) == some 9 &&
            runOfIndex? "session-.json" == none }]

end ModelTest
