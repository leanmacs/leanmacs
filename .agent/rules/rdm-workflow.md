# Working with rdm plans

How agent work is steered, planned and parked in this repository's rdm plans.

## The owner steers at the roadmap

The owner sets a roadmap's intent, non-goals, what done looks like and the
order of its phases. A phase's implementation plan is written by one agent
for another, to turn the phase into units that follow the rules in
`AGENTS.md`; the owner does not read it.

- Put steering at the roadmap level. Raise an important steering decision
  found while planning as a question with options, never as a plan document
  for the owner to approve.
- Make a code review the owner reads trace each change's "why" back to the
  plan it came from, so they can understand it and steer at a high level
  rather than review it line by line. Prefer judgement over rigid,
  rule-based scrutiny tiers.

## Plan automated checks, not owner-run ones

Finish every phase and task on automated tests (`AGENTS.md`, "Iterate and
dogfood"). Make every phase, task and acceptance criterion one that
automated tests check, never a person by hand, and hand the owner no list
of manual test steps: they use the editor day to day, and that finds the
breaking bugs. When work is ready to try, make it one command to install
and say in a line what is new.

## What does not block a run

- Treat the `needs-plan-review` tag as a reminder, not a gate: start work
  and run a roadmap (autopilot) whether or not it is present. Judge whether
  a roadmap is clear to run on real blockers: unmet dependencies, blocked
  or in-progress phases, conflicting worktrees, open change requests.
  Mention the tag at most in passing.
- Treat a review comment whose anchor is lost (`anchorsParkRequired=yes`,
  from an ambiguous or not-found quote) as a whole-document comment, not a
  reason to park the phase: triage it like any other, say in the reply that
  its anchor was not placed and why, carry on to the follow-up review and
  gated write, and mention the lost anchor in the run report. Park on real
  blockers: an escalated outcome, `failure`, exhausted budgets, gate
  refusals.
