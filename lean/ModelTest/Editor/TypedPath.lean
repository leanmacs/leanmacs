import Editor.TypedPath
import ModelTest.Check

/-!
# Model tests: `Editor/TypedPath.lean`

The model tests of `Editor/TypedPath.lean`: `typedPathChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of a path as a person types it (`Editor/TypedPath.lean`),
each a table. -/
def typedPathChecks : List Check :=
  [{  name := "split gives the directory part through the last / and the last component"
      run :=
        pure
          ([("", ("", "")), ("a", ("", "a")), ("a/", ("a/", "")), ("~/x/y", ("~/x/", "y"))].all
            fun (text, expected) => TypedPath.split text == expected) },
    { name :=
        "restart starts again after the last // or /~/, whichever is later, and a ~ not after a / or followed by a name restarts nothing"
      run :=
        pure
          ([("~/a//b/c", "/b/c"), ("/a/~/b", "~/b"), ("/a/~", "~"), ("a~/b", "a~/b"),
                ("~/a/~b/", "~/a/~b/"), ("~/proj//etc/", "/etc/"),
                ("/srv/a/~/notes", "~/notes")].all
            fun (text, expected) => TypedPath.restart text == expected) },
    { name :=
        "normalize drops . and lets .. take back the component before it, keeping the start and a trailing /, and a .. with nothing before it but at the root"
      run :=
        pure
          ([("/a/./b/../c/", "/a/c/"), ("../x/", "../x/"), ("~/../x", "~/../x"), ("/../a", "/a"),
                ("~/", "~/"), ("~", "~"), ("/", "/"), ("./", ""), ("/x//w/", "/x/w/")].all
            fun (text, expected) => TypedPath.normalize text == expected) },
    { name := "tidy is idempotent over the tables"
      run :=
        pure
          (["", "a", "a/", "~/x/y", "~/a//b/c", "/a/~/b", "/a/~", "a~/b", "~/a/~b/", "/a/./b/../c/",
                "../x/", "~/../x", "/../a", "~/proj//etc/", "/srv/a/~/notes"].all
            fun text => TypedPath.tidy (TypedPath.tidy text) == TypedPath.tidy text) },
    { name :=
        "expand reads a leading ~ under the home, a relative name under the directory and an absolute one as it is, with no restart, keeps .. at the root, drops a trailing /, and says why with no home or no directory; expandTyped restarts first"
      run :=
        let home : Option System.FilePath := some "/home/me"
        let here : Option System.FilePath := some "/w/src"
        let expanded (text : String) (directory home : Option System.FilePath) : Option String :=
          (TypedPath.expand text directory home).toOption.map (·.toString)
        let refusal (text : String) (directory home : Option System.FilePath) : Option String :=
          match TypedPath.expand text directory home with
          | .error why => some why
          | .ok _ => none
        pure
          (expanded "~" none home == some "/home/me" &&
            expanded "~/" none home == some "/home/me" &&
            expanded "~/notes/a.txt" none home == some "/home/me/notes/a.txt" &&
            expanded "main.lean" here none == some "/w/src/main.lean" &&
            expanded "../a/" here none == some "/w/a" &&
            expanded "/etc/hosts" none none == some "/etc/hosts" &&
            expanded "/../../a" none none == some "/a" &&
            expanded "/" none none == some "/" &&
            expanded "notes/" here none == some "/w/src/notes" &&
            expanded "/tmp/a//b.txt" none home == some "/tmp/a/b.txt" &&
            expanded "/srv/~/notes" none home == some "/srv/~/notes" &&
            expanded "~/x//etc/" none home == some "/home/me/x/etc" &&
            (TypedPath.expandTyped "~/x//etc/" none home).toOption.map (·.toString) ==
              some "/etc" &&
            (TypedPath.expandTyped "/srv/~/notes" none home).toOption.map (·.toString) ==
              some "/home/me/notes" &&
            refusal "~/a" here none == some "the home directory is not known" &&
            refusal "a" none home == some "no directory to read it from") },
    { name :=
        "abbreviate writes the home as ~ and a path under it as ~/…, and directoryText adds one /, with no home and for the root as well"
      run :=
        let home : Option System.FilePath := some "/home/me"
        pure
          (TypedPath.abbreviate "/home/me" home == "~" &&
            TypedPath.abbreviate "/home/me/proj" home == "~/proj" &&
            TypedPath.abbreviate "/home/meadow" home == "/home/meadow" &&
            TypedPath.abbreviate "/w" none == "/w" &&
            TypedPath.directoryText "/home/me" home == "~/" &&
            TypedPath.directoryText "/home/me/proj" home == "~/proj/" &&
            TypedPath.directoryText "/w" home == "/w/" &&
            TypedPath.directoryText "/w" none == "/w/" &&
            TypedPath.directoryText "/" home == "/" &&
            TypedPath.abbreviate "/home/me/proj" (some "/home/me/") == "~/proj" &&
            TypedPath.abbreviate "/home/me" (some "/home/me/") == "~") },
    { name :=
        "directoryText is a text the restart reads back as the directory, and empty, read under the directory, where there is none: /srv/~/proj and /w//x"
      run :=
        let home : Option System.FilePath := some "/home/me"
        let readBack (path : System.FilePath) : Bool :=
          let text := TypedPath.directoryText path home
          (TypedPath.expandTyped text (some path) home).toOption ==
            (TypedPath.expand path.toString none home).toOption
        pure
          (TypedPath.directoryText "/srv/~/proj" home == "" &&
            TypedPath.directoryText "/home/me/~/x" home == "" &&
            TypedPath.directoryText "/w//x" home == "/w/x/" &&
            (["/srv/~/proj", "/home/me/~/x", "/w//x", "/home/me", "/home/me/proj", "/w", "/"] :
                  List System.FilePath).all
              readBack) }]

end ModelTest
