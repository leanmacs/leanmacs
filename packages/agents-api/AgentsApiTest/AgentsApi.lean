import AgentsApi
import AgentsApiTest.Check
import Editor.Config.Packages

/-!
# Model tests: `AgentsApi.lean`

`agentsApiChecks`: the service's request vocabulary read back as it was
written, a malformed request refused, and the agent registration point a
choice by name. The test driver's root, `AgentsApiTest/Model.lean`, runs
them.
-/

namespace AgentsApiTest

open Editor
open AgentsApi

/-- Two MCP servers, one with arguments and variables, one with none. -/
def servers : Array McpServer :=
  #[{ name := "example-server", command := "/usr/local/bin/example", arguments := #["--a", "b c"]
      environment := #[("KEY", "value"), ("EMPTY", "")] }, { name := "bare", command := "bare" }]

/-- Every request the vocabulary has, with each order. -/
def requests : List Request :=
  [.open 7 "/work/example" servers, .open 8 "/" #[], .next 3, .send 3 (.prompt "Read notes.txt."),
    .send 3 .cancel, .send 3 (.setMode "mode-ask"), .send 3 (.answer 2 "allow-once")]

/-- A package named `name` that registers each of `agents`. -/
def registering (name : String) (agents : List Agent) : Package :=
  { name, setup := agents.forM Extension.add }

/-- The agents `packages` register, in registration order. -/
def registeredAgents (packages : Array Package) : Array Agent :=
  packages.flatMap fun package =>
    package.registered.extensions.filterMap fun (key, value) =>
      if key == TypeName.typeName Agent then value.get? Agent else none

/-- The checks of `AgentsApi.lean`. -/
def agentsApiChecks : List Check :=
  [{  name :=
        "every request of the service agents, open with its MCP servers, next and send with each order, is read back as it was written"
      run := do
        let back := requests.map fun request => Request.ofPackage? request.toPackage
        saw (back == requests.map some) s!"{repr back}" },
    { name :=
        "a request of another service, an unknown operation, a missing or extra argument and an order of an unknown kind are read as no request of the service"
      run := do
        let opened := (Request.open 7 "/w" servers).toPackage
        let malformed : List PackageRequest :=
          [{ opened with service := "echo" }, { opened with operation := "close" },
            { opened with arguments := opened.arguments.dropLast },
            { opened with arguments := opened.arguments ++ [.nat 1] },
            { service := serviceName, operation := "next", arguments := [] },
            { service := serviceName, operation := "next", arguments := [.str "3"] },
            { service := serviceName, operation := "send", arguments := [.nat 3, .str "shout"] },
            { service := serviceName, operation := "send",
              arguments := [.nat 3, .str "answer", .nat 1] }]
        let read := malformed.map Request.ofPackage?
        saw (read.all (·.isNone)) s!"{repr read}" },
    { name :=
        "the agent registration point is a choice by name: the latest agent of a name is chosen, a later agent of another name is not, and a name nobody registered has none"
      run := do
        let first : Agent := { name := "claude", program := "first" }
        let second : Agent := { name := "claude", program := "second" }
        let other : Agent := { name := "other", program := "other" }
        let agents := registeredAgents #[registering "a" [first], registering "b" [second, other]]
        let chosen := (Agent.choose agents "claude").map (·.program)
        saw
            (agents.size == 3 && chosen == some "second" &&
              (Agent.choose agents "other").map (·.program) == some "other" &&
              (Agent.choose agents "nobody").isNone)
            s!"registered {agents.map (·.program)}, chosen {chosen}" },
    { name :=
        "an agent's command runs its program with its arguments and environment in the session's directory, and the line bound is sixteen mebibytes"
      run := do
        let agent : Agent :=
          { name := "claude", program := "agent", arguments := #["--acp"]
            environment := { set := #[("A", "1")] } }
        let command := agent.command "/work/example"
        saw
            (command ==
                { program := "agent", arguments := #["--acp"],
                  environment := { set := #[("A", "1")] }
                  directory := "/work/example" } &&
              lineBound == 16777216)
            s!"{repr command}" }]

end AgentsApiTest
