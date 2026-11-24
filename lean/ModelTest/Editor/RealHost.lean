import Editor.RealHost
import ModelTest.Check

/-!
# Model tests: `Editor/RealHost.lean`

The model tests of a root's check set as data, `checkGroupChecks`: what a
normal run, a `--wiring` run and a listing of the wiring set's modules each
select from the groups, and how a root reads its mode from its
arguments. The root module `ModelTest` runs them; its module doc says what
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
        "a run's lines name the root, each module of the wiring set once and the number of its checks"
      run :=
        return CheckGroup.ranLines "config-test" (CheckGroup.wiring sampleGroups) 1 ==
            ["wiring-set: ran config-test W 3 checks", "wiring-set: ran config-test C 1 checks"] },
    { name :=
        "a root's arguments after its directories name its mode: none a normal run, `--wiring` alone the wiring set's, and anything else no mode"
      run :=
        return CheckGroup.Mode.ofArguments? [] == some .all &&
            CheckGroup.Mode.ofArguments? ["--wiring"] == some .wiring &&
            CheckGroup.Mode.ofArguments? ["--wiring", "--wiring"] == none &&
            CheckGroup.Mode.ofArguments? ["--wired"] == none &&
            CheckGroup.Mode.ofArguments? ["wiring"] == none },
    { name :=
        "a mode selects a normal run's checks or the wiring run's, each wiring module's checks in turn, and its count line calls them checks or wiring-set checks"
      run :=
        return CheckGroup.select .all sampleGroups 7 == CheckGroup.all sampleGroups 7 &&
            CheckGroup.select .wiring sampleGroups 3 == ["w1-3", "w2-3", "w3-3", "c3"] &&
            CheckGroup.Mode.all.what == "checks" &&
            CheckGroup.Mode.wiring.what == "wiring-set checks" }]

end ModelTest
