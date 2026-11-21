import ModelTest.Check
import ShellApi
import ShellApiTest.Contract
import ShellApiTest.Fake

/-!
# Model tests: `ShellApi.lean`

`shellApiChecks`: the interface library `shell-api`'s names, its fake held
to its contract, and the contract biting on implementations that leave a
command out, register no codec for the history, or record nothing. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of `shell-api`'s contract that do not hold over `package`. -/
def shellFailing (package : Package) : List String :=
  ((ShellApiTest.contractChecks package).filter (!·.2)).map (·.1)

/-- The fake, but for `dropped`, which it leaves out of its setup: command
names, and `codec` for the history's codec. -/
def shellFakeLacking (dropped : List String) : Package :=
  { name := ShellApiTest.fake.name, setup := ShellApiTest.fakeSetup dropped }

/-- A package of the shell's name that registers the three commands and the
history's codec, and whose `shell-command` records nothing. -/
def forgetfulShell : Package :=
  { name := ShellApiTest.fake.name
    setup := do
      for name in ShellApi.names do
        command name (message "forgets")
      Shell.historyStore.keptAcrossRestart }

/-- The checks of `shell-api` (`ShellApi.lean`). -/
def shellApiChecks : List Check :=
  [{  name :=
        "the names shell-api declares: shell-command, shell-filter and keyboard-quit, the text of a :! with nothing after it, and the history's store shell-history"
      run :=
        pure <|
          ShellApi.names == #["shell-command", "shell-filter", "keyboard-quit"] &&
            ShellApi.noCommand == "!: no command" &&
            Shell.historyStore.name == "shell-history" &&
            Shell.historyLimit == 100 },
    { name := "the fake keeps the contract: every check of it holds"
      run := pure (shellFailing ShellApiTest.fake).isEmpty },
    { name :=
        "a package that registers every command but keyboard-quit fails the contract, on keyboard-quit's check alone"
      run :=
        pure <|
          let failing := shellFailing (shellFakeLacking [ShellApi.interruptName])
          failing.length == 1 &&
            failing.all fun sentence =>
              (sentence.splitOn s!"`{ShellApi.interruptName}`").length > 1 },
    { name :=
        "a package that registers no codec for the history fails the contract, on the codec's check alone"
      run :=
        pure <|
          let failing := shellFailing (shellFakeLacking ["codec"])
          failing.length == 1 &&
            failing.all fun sentence => (sentence.splitOn Shell.historyStore.name).length > 1 },
    { name :=
        "a package whose shell-command records nothing in the history fails the contract, on the history's check alone"
      run :=
        pure <|
          let failing := shellFailing forgetfulShell
          failing.length == 1 &&
            failing.all fun sentence => (sentence.splitOn "history holds").length > 1 },
    { name :=
        "remember puts a line first, keeps no other copy of it, and keeps at most historyLimit lines"
      run :=
        pure <|
          Shell.remember "b" #["a", "b", "c"] == #["b", "a", "c"] &&
            (Shell.remember "new" ((List.range 100).map toString).toArray).size == 100 &&
            (Shell.remember "new" ((List.range 100).map toString).toArray)[0]? == some "new" }]

end ModelTest
