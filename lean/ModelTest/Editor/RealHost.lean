import Editor.RealHost
import ModelTest.Check

/-!
# Model tests: `Editor/RealHost.lean`

The model tests of a root's check set as data, `checkGroupChecks`: what a
normal run, a `--wiring` run and a listing of the wiring set's modules each
select from the groups, how a root reads its mode from its arguments,
and that a wiring run that selects nothing passes without the root's run. The root module `ModelTest` runs them; its module doc says what
they show.
-/

namespace ModelTest

open Editor

-- A sample of the data, not a root's check set: its modules are names
-- alone, which `linter.wiringSet` would refuse as tags.
set_option linter.wiringSet false in
/-- A check set over the context `Nat` whose checks are strings, each
naming its group and the context: a plain group, a module of the wiring
set's two groups with an edge's and another module's between them, a
contract's, and a plain group last. -/
def sampleGroups : List (CheckGroup Nat String) :=
  [.plain fun n => [s!"p{n}"], .wired "W" (.wiring "a" "b") fun n => [s!"w1-{n}", s!"w2-{n}"],
    .wired "E" (.edge "e") fun n => [s!"e{n}"], .wired "C" (.contract "c") fun n => [s!"c{n}"],
    .wired "W" (.wiring "a" "b") fun n => [s!"w3-{n}"], .plain fun n => [s!"q{n}"]]

/-- The checks of a check set's selections (`CheckGroup`). -/
def checkGroupChecks : List Check :=
  [{  name :=
        "a normal run runs every group's checks over the context, in the order of the groups, an edge's and the plain ones' among them"
      run :=
        return CheckGroup.all sampleGroups 7 == ["p7", "w1-7", "w2-7", "e7", "c7", "w3-7", "q7"] },
    { name :=
        "a wiring run takes the wiring and contract modules, each once in the order its first group comes, with its groups' checks in order, and drops the plain groups and an edge's"
      run :=
        let wiring := CheckGroup.wiring sampleGroups
        return wiring.map (·.1) == ["W", "C"] &&
            wiring.map (·.2 3) == [["w1-3", "w2-3", "w3-3"], ["c3"]] },
    { name :=
        "the modules a root lists are its wiring run's, named once each, and a check set with no wiring group lists none"
      run :=
        return CheckGroup.modules sampleGroups == ["W", "C"] &&
            CheckGroup.modules ([.plain fun _ => ["x"], .wired "E" (.edge "e") fun _ => ["y"]] :
                  List (CheckGroup Unit String)) ==
                [] },
    { name :=
        "a root's arguments after its directories name its mode: none a normal run, `--wiring` alone the wiring set's, and anything else no mode"
      run :=
        return CheckGroup.Mode.ofArguments? [] == some .all &&
            CheckGroup.Mode.ofArguments? ["--wiring"] == some .wiring &&
            CheckGroup.Mode.ofArguments? ["--wiring", "--wiring"] == none &&
            CheckGroup.Mode.ofArguments? ["--wired"] == none &&
            CheckGroup.Mode.ofArguments? ["wiring"] == none },
    { name :=
        "a root that takes more after its mode reads the mode first, `--wiring` or none, and hands the rest to its own reader, and anything its reader refuses is no mode"
      run :=
        let rest? : List String → Option (Option String)
          | [] => some none
          | ["--timings", file] => some (some file)
          | _ => none
        return CheckGroup.Mode.read? rest? [] == some (.all, none) &&
            CheckGroup.Mode.read? rest? ["--timings", "t"] == some (.all, some "t") &&
            CheckGroup.Mode.read? rest? ["--wiring"] == some (.wiring, none) &&
            CheckGroup.Mode.read? rest? ["--wiring", "--timings", "t"] == some (.wiring, some "t") &&
            CheckGroup.Mode.read? rest? ["--timings", "t", "--wiring"] == none &&
            CheckGroup.Mode.read? rest? ["--wiring", "--wiring"] == none &&
            CheckGroup.Mode.read? rest? ["wiring"] == none },
    { name :=
        "a root that names its runs by subcommands names its mode by them: none a normal run, `wiring` alone the wiring set's, and anything else no mode"
      run :=
        return CheckGroup.Mode.ofSubcommand? [] == some .all &&
            CheckGroup.Mode.ofSubcommand? ["wiring"] == some .wiring &&
            CheckGroup.Mode.ofSubcommand? ["--wiring"] == none &&
            CheckGroup.Mode.ofSubcommand? ["wiring", "x"] == none &&
            CheckGroup.Mode.ofSubcommand? ["wiring-modules"] == none },
    { name :=
        "a mode selects a normal run's checks or the wiring run's, each wiring module's checks in turn, and its count line calls them checks or wiring-set checks"
      run :=
        return CheckGroup.select .all sampleGroups 7 == CheckGroup.all sampleGroups 7 &&
            CheckGroup.select .wiring sampleGroups 3 == ["w1-3", "w2-3", "w3-3", "c3"] &&
            CheckGroup.Mode.all.what == "checks" &&
            CheckGroup.Mode.wiring.what == "wiring-set checks" },
    { name :=
        "a wiring run of a check set with no module of the wiring set selects nothing and passes, status 0, without the root's run, so it builds no context; a normal run of it, and a wiring run of a set with such a module, are the root's run"
      run := do
        let unwired : List (CheckGroup Nat String) :=
          [.plain fun n => [s!"p{n}"], .wired "E" (.edge "e") fun n => [s!"e{n}"]]
        let runs ← IO.mkRef 0
        let run : IO UInt32 := do
          runs.modify (· + 1)
          return 7
        let empty ← CheckGroup.running .wiring unwired run
        let ranForEmpty ← runs.get
        let normal ← CheckGroup.running .all unwired run
        let wired ← CheckGroup.running .wiring sampleGroups run
        return CheckGroup.select .wiring unwired 3 == [] && CheckGroup.selectsNothing .wiring unwired &&
            empty == 0 && ranForEmpty == 0 && !CheckGroup.selectsNothing .all unwired &&
            normal == 7 && !CheckGroup.selectsNothing .wiring sampleGroups && wired == 7 &&
            (← runs.get) == 2 }]

end ModelTest
