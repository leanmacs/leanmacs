# The review interface: supervising agent work

How one person supervises a stream of agent-written plans and changes
from inside the editor: builds a working model of each change, holds it
to the plan and to their standards for clean code, sees how it and the
review itself can fail, and explains the result to someone else. This
document gives the evidence and the proposal. What is already built
(`vc-review`, its order, viewed-hunk tracking, rounds, rdm's document
reviews) is in [review-and-navigation.md](review-and-navigation.md) and
[version-control.md](version-control.md), and is not repeated here.

Status: **proposal**. Nothing below is built unless it says so.

## The evidence

From a research pass on 2026-11-18. The notes are local
(`reports/Review interface research.md`, untracked, see
[publishing](../dev-practices/publishing.md#research_notes-and-reports-stay-local)).
Claims marked **verified** came from a primary source and survived three
independent refutation attempts. **Read** means extracted from the
primary source but not cross-checked. **Vendor** means a product's own
account, with no data behind it.

### What review is for

| Finding | Source | Strength |
|---|---|---|
| Understanding the change is the main activity of review. It delivers knowledge transfer, awareness and alternative designs more than defects, and tools serve understanding poorly | Bacchelli & Bird, ICSE 2013 ([MSR](https://www.microsoft.com/en-us/research/?p=164195)); corroborated by Czerwonka 2015 (~15% of comments are about functional defects) and Sadowski et al., Google, ICSE-SEIP 2018 ([Google](https://research.google/pubs/pub47025/)) | Verified, 3-0 |
| Reviewers' information needs, most frequent first: is an alternative better, is my understanding correct, what is the rationale. Then context, necessity, expertise, whether the change can be split. Answers take a median of ~7 hours to arrive | Pascarella et al., CSCW 2018, 900 comments from Android, OpenStack and Qt ([PDF](https://dibt.unimol.it/staff/fpalomba/documents/C41.pdf)) | Verified, 3-0 |
| Authors annotate their own changesets less than 5% of the time, although reviewers say annotations help | Barnett et al., ICSE 2015 | Read |

With agents, nobody holds the model of the change except whatever the
reviewer builds. "Knowledge transfer" becomes the supervisor learning code
that nobody wrote. That is an inference, but it is the premise of this
document.

### Presenting a change

| Finding | Source | Strength |
|---|---|---|
| Reviewers follow the tool's order: in 53% of 292 logged sessions they started with the first file listed, and 73% use the tool's order often or always. So the default order matters | Baum, Schneider & Bacchelli, ICSME 2017 ([PDF](https://tobiasbaum.github.io/rp/optimalordering.pdf)) | Verified |
| Only 10.2% of 1,355 developers think alphabetical order is right; 57.6% say it adds context switches; 63.9% fear missing bugs; 66% want customisable, dependency-aware order | Rahman, Codabux & Roy, ICSE 2026 ([ICSE](https://conf.researchr.org/details/icse-2026/icse-2026-research-track/310/Breaking-the-Alphabet-Rethinking-File-Ordering-in-Code-Review)) | Verified; self-report, not measured outcome |
| The order's rule must be one the reviewer can understand (86% rated an order with no visible rule among the worst). Groups should be shown explicitly. Related parts are best on screen at the same time. Callee before caller was preferred by 85% | Baum et al. 2017, principles 2, 5, 6 | Verified for 5 and 6; single source. "The best order is mainly grouping by relatedness" was **refuted** 1-2 |
| Small changes are reviewed much better: 59% vs 35% of seeded defects found. Working memory predicts finding *delocalised* defects (ones that need several parts combined), tau 0.24. A better order trended better but was not significant (underpowered). The second large review was faster and shallower | Baum et al., EMSE 2019, n=50 ([PDF](https://tobiasbaum.github.io/rp/memoryCodeOrderAndReview.pdf)) | Verified |
| About 42% of 1,000 Office changesets split into more than one partition by def-use links, call sites and co-location. 16 of 20 developers judged the partitions correct | Barnett, Bird, Brunet & Lahiri, ICSE 2015, ClusterChanges ([MSR](https://www.microsoft.com/en-us/research/publication/helping-developers-help-themselves-automatic-decomposition-of-code-review-changesets/)) | Verified |
| Decomposing a tangled change cut false-positive comments, but did not raise defects found or understanding of rationale. Reviewers of the split change spent more effort seeking context | Di Biase et al., PeerJ CS 2019, n=28 ([PeerJ](https://peerj.com/articles/cs-193)) | Verified (defect part 2-1) |

What follows: keep changes small and split them by concern. Show the
order's rule in the buffer. Put a definition and its uses on screen
together. Expect splitting to reduce noise, not to find bugs on its own.
Since working memory limits delocalised defects, the tool should hold
what the reviewer has already understood, so they do not have to.

### Explanations, summaries and tours

| Finding | Source | Strength |
|---|---|---|
| PRs with Copilot-generated descriptions were reviewed 19.3 h faster and were 1.57x more likely to merge. Developers edited the text often, most often by deleting part of it | Xiao et al. 2024, 18,256 PRs ([arXiv](https://arxiv.org/html/2402.08967v1)) | Read. A higher merge rate is also what rubber-stamping looks like |
| An explanation of a change has two parts, *what* and *why*, and they should be rated separately. An LLM judge matched human raters better on *why* (Spearman 0.78) than BLEU-style metrics did (0.20), but scores drifted between runs | Li et al. 2025 ([arXiv](https://arxiv.org/html/2507.10906v1)); see also [arXiv 2401.05926](https://arxiv.org/html/2401.05926v2) | Read |
| Code tours made readers skip irrelevant files, but did not improve task success. Readers treated what the tour left out as irrelevant, and missed a bug that was an *absent* call | Taylor & Clarke, PPIG 2022, n=15 ([PPIG](https://www.ppig.org/papers/2022-ppig-33rd-taylor/)) | Read |
| Tours that experts curated (which locations, which order) with AI-written prose scored 83% on comprehension quizzes vs 57% for AI-only tours | LACY, 2026 ([arXiv](https://arxiv.org/abs/2603.25391)) | Read |
| A tour can be generated along a failing test's stack trace, but the LLM's prose was often redundant and too low-level | Balfroid et al., NLBSE 2024 ([PDF](https://researchportal.unamur.be/files/93244689/balfroid-2024.pdf)) | Read |

What follows: an agent's narrative is useful for orientation, but it is
a claim, not evidence. The human should pick what a tour covers, and the
tool should show what the tour leaves out.

### How AI-assisted review fails

| Finding | Source | Strength |
|---|---|---|
| Given an LLM review first, reviewers concentrated on the locations it flagged. They found more low-severity issues but no more high-severity ones, saved no time and gained no confidence | Tufano et al., ICSE 2025, n=29, 50+ hours recorded ([ICSE](https://conf.researchr.org/details/icse-2025/icse-2025-research-track/72/Deep-Learning-based-Code-Reviews-A-Paradigm-Shift-or-a-Double-Edged-Sword-)) | Verified; one lab study with a 2024 model |
| Reviewers preferred AI-led review, but said false positives bury the real issues and suggestions pull attention away from what was not flagged. Preference depended on familiarity with the code and the PR's severity | Adalsteinsson et al. 2025, WirelessCar, n=10 ([arXiv](https://arxiv.org/abs/2505.16339)) | Verified; qualitative, one company |
| Framing a change as bug-free in its metadata cut LLM vulnerability detection by 16 to 93 points (GPT-4o-mini: 97.2% to 3.6%). PRs that reverted security fixes while claiming to improve security got past Claude Code as a CI reviewer 15 of 17 times. Hiding the description and reviewing the diff alone restored detection to 16 of 17 | 2026 ([arXiv](https://arxiv.org/html/2603.18740v1)) | Read |
| People using an AI assistant wrote less secure code *and* were more confident it was secure. Those who trusted it less did better | Perry et al., CCS 2023 ([arXiv](https://arxiv.org/abs/2211.03622)) | Read |
| Experienced developers on their own repositories were 19% slower with early-2025 AI tools, and afterwards believed they had been 20% faster | METR RCT, n=16, 246 tasks ([arXiv](https://arxiv.org/abs/2507.09089)) | Read |
| On average 5.2% (commercial) and 21.7% (open) of the packages models recommend do not exist: 205,474 unique invented names, each a name an attacker can register | Spracklen et al., USENIX Security 2025 ([USENIX](https://www.usenix.org/conference/usenixsecurity25/presentation/spracklen)) | Read |
| 67.9% of rejected PRs, agent and human, close with no stated reason. Some reasons occur only for agent PRs: too large to review (every size rejection was an agent's), no confidence in AI code, adds no value, more complex than needed | Nakashima et al. 2026, AIDev, 654 PRs ([arXiv](https://www.arxiv.org/pdf/2602.04226)) | Verified finding; preprint |

What follows:

- **Anchoring**: whatever is flagged first narrows the search. The
  reviewer's own pass should come before the machine's, and the regions
  nobody flagged should be visible as such.
- **Framing**: the author's story biases both human and machine
  reviewers. The diff should be reviewable without it, and the machine
  reviewer should be shown the diff alone.
- **Confidence is not evidence**: self-reports, the reviewer's and the
  agent's, run opposite to measured outcomes. The tool should measure
  what was looked at and what was found, and show it.
- **Plausible-but-absent references**: dependencies, APIs and files that
  do not exist are a failure of generated code that a mechanical check
  catches better than a reader.
- **Unrecorded verdicts**: when reasons are not captured, neither the
  agent nor anyone else learns from a rejection.

### Plans and specs before code

Only practitioner sources were found, so this section rests on reasoning
and on vendors, not on studies:
[Plannotator](https://docs.plannotator.ai/learn/planning/spec-driven-development-for-ai-coding-agents.md),
[Augment](https://www.augmentcode.com/guides/ai-coding-agents-for-spec-driven-development-automation),
[dev.to](https://dev.to/rosgluk/what-is-spec-driven-development-the-spec-as-source-of-truth-4gdd).
They agree on four points:

- Gate a plan in stages (requirements, design, tasks).
- Accept the implementation against evidence for the accepted criteria,
  not the agent's summary.
- Scale how deeply you review to risk (auth, migrations, billing and
  public interfaces need more).
- Have the agent stop when a new decision changes behaviour, risk or
  scope.

They also name the failure modes of the spec itself: stale specs, task
lists that lose the reason for each edit, a spec that looks complete and
so gives false confidence, and specs too large to review.

## Where human attention goes

The tools below are not a review pipeline that every change passes
through. Before the tools, this section says where the owner's attention
goes at all. It rests on this project's own record, and on a debate
among practitioners.

### What this project's record shows

Every one of the 466 reviews in the plan repo, up to 2026-11-19, was
run by an agent: 251 of changes, 138 of implementation plans, 66 of
phases and 11 of roadmaps. Of the 215 reviews of plans, phases and
roadmaps, 35 asked for changes (about 15%). Their findings fall into
four kinds:

- **A criterion nobody can check**: "tests for each feature", "where it
  is cheap", "easy to read".
- **Order across roadmaps**: a phase that needs a type or a buffer that
  only an unlanded roadmap builds.
- **A contradiction with a recorded decision**: spawning with
  `IO.Process` against the process-service rule, Lean merging faces
  against "Rust merges", a test pinning another crate's rule.
- **Feasibility**: an import cycle, an unbounded diff on the editor
  thread.

All four are found by reading the plan against the rules and the code,
which agents do. None asks whether the work is the right work, or
whether another approach is better, which is reviewers' most frequent
need in Pascarella's study. Those questions were answered by the owner
in other places:

- in the roadmap's *Intent* (goal, non-goals, what done looks like) and
  its interview;
- in the Decisions table of [README.md](README.md), where about two
  dozen entries are "the owner's";
- in feedback the agents keep as memory.

Asking the owner for something else caused failures. Several change
reviews asked for changes only because a criterion required an
owner-run check that had not been recorded. A phase that puts the owner
in the verification path waits on the owner.

### Planning is not the plan document

The essay "Plan mode is dead" (Ayman Nadeem, 2026-09; read from
summaries, not the original) argues the same split:

- Planning is the activity; a plan is the artifact.
- The plan document's first job, making the agent's instructions
  precise, is mostly done by the model now.
- Approving a plan does not catch what goes wrong in the code.
- Conventions belong in persistent context files.
- Human checkpoints belong at action boundaries and on work that is hard
  to undo.

Second-hand accounts say members of the Claude Code team considered
replacing plan mode with effort levels. Those attributions are
unconfirmed.

### Three surfaces for the owner

So the owner's attention goes to three places, and nothing else asks
for it:

1. **The roadmap** (tool 1): what to build, why, what is out of scope,
   what done looks like, and in what order. This is where steering
   happens, and it is the surface most worth a better interface.
2. **Decisions raised from below** (tool 2): when an implementation plan
   or a change makes a choice that no rule covers, that one choice comes
   up as a question with its options. The plan that contains it does
   not.
3. **What a change did to the system** (tool 3): a brief of how the code
   now differs, checked against the roadmap's intent, which the owner
   reads to understand the change and to steer the next phase.

Implementation plans are written by agents for agents. They turn a
phase into units that follow the rules, and agents review them against
those rules. The owner does not read them, except for a question one of
them raises. The line-level tools (4 to 12) are views the owner opens
when the brief or a question makes them want to look. They are not
gates.

### Examining the code: what changed and why

The three surfaces are where the owner steers. The other half is reading
the code itself, and understanding each part of a change by the reason
it exists. Every hunk should answer "why is this here?" with a chain
back to something the owner wrote or approved, and say so plainly when
it cannot.

**The why chain.** In the review buffer each hunk, or each group of
hunks (tool 4), has a *why* pane beside it, a chain from the code
upward:

```
hunk     lean/Editor/Workspace/FindFile.lean @@ +1,40 @@
commit   feat(lean): find-file-in-workspace over the workspace's lister and fzf
step     plan step 4 · "The finder" (Design §4)
tests    criteria 1, 4, 5, 7 → findFileChecks
phase    project-navigation / phase 2 · find file in a workspace
intent   roadmap scenario: "WHEN I press SPC f f THEN …"
decided  "the label is name@branch" (answered 2026-11-17)
review   change review b9b4, comment 1 (wont-fix): golden tests red for five commits
```

Each link is one key to open: the commit, the plan at that step's
section, the tests, the phase, the roadmap, the decision, the review
comment. The reverse works too: from a plan step, a criterion or a
roadmap scenario, open the hunks that serve it as a review buffer. This
is the "compare a plan with what was built" row of
[review-and-navigation.md](review-and-navigation.md#what-review-needs).

**Where the links come from**, strongest first:

1. **Per-edit provenance**, once rdm:roadmap/acp-agents phase 5 lands:
   the agent session, tool call and transcript step that wrote a range,
   and the plan step that session was on.
2. **Commits matched to plan steps.** rdm implementation plans already
   list their commits by subject under "TDD order and commits", and
   their criteria by test name under "Acceptance criteria → tests". A
   commit whose subject is a step's is that step; a test named under a
   criterion links the criterion to the hunks that change the test and
   the code it covers. A `Plan-Step:` trailer would make the match exact
   (an rdm convention to add); until then the match is by subject and is
   shown as such.
3. **Commits after a review**: a fix or refactor commit made while a
   change review was open links to the comment it addresses, through
   the review's `--applied-commit`.
4. **Inferred**: an agent groups the remaining hunks and says why it
   thinks they belong together. As in Guided Review, the model only
   groups hunks and writes commentary; it never supplies the code shown,
   and a reference to a hunk that does not exist is dropped. Inferred
   links are drawn as inferred.

A hunk with no link is **unexplained**, drawn so, and counted in the
status line beside *not examined*. In this design an unexplained hunk is
a finding of its own: either the plan missed something or the change
did something it was not asked to.

**Two modes, one review.** The review buffer must work on any change,
with rdm or without it: a branch of this project's agents, a colleague's
pull request, a commit in another repository. So the review core knows
nothing about rdm. It talks to two interfaces, each with several
implementations, chosen per review:

| Interface | Asks | Implementations |
|---|---|---|
| **Rationale** | For a change's scope: the units of intent (plan steps, commits, PR sections), their parents (phase, roadmap, issue), and which hunks each covers | rdm (plans, phases, roadmaps, decisions, change reviews); git alone (commit messages, trailers, Conventional Commit scopes); a forge (a PR's description and linked issue, through `gh`); provenance (the edit log's origin and the agent table); inferred (the grouping agent) |
| **Review sink** | Where comments, verdicts and reasons go, and where earlier ones are read back | rdm change reviews (`rdm review start --on change/<sha>`); the workspace's review store (built, `reviewStore`); a forge's PR review; a markdown export |

Rationale implementations compose: a review in this project uses
provenance, then rdm, then git, then inferred, each filling the links
the stronger ones left empty, and each link records which one made it.
A review of someone else's pull request uses the forge, git and inferred
alone. A review started without rdm can be attached to an rdm item later
("this branch implements that phase"), and its comments move to an rdm
change review.

Narrative stays labelled in both modes: a PR description, like an
agent's summary, is the author's claim (principle 5), and it is a
source of links, not of conclusions.

Both interfaces follow [overview.md](overview.md): each is a Lean
interface with a real binding and a pure model, so the review core's
tests run on the models, and rdm's golden JSON files are the rdm
binding's fixtures.

## Principles

1. **Understanding first, defects second.** The interface is built to
   leave the reviewer with a correct model of the change: what, why,
   which alternatives were rejected. Finding defects follows from that.
2. **Small, split and ordered by a rule the reviewer can see.** Every
   group in a review says why it is there and why it comes where it does.
3. **Related parts on one screen.** A definition and its uses, a test
   and what it tests, and a plan step and its hunks are shown together,
   not reached by navigation.
4. **The human looks first.** Machine findings and the author's narrative
   are hidden until the reviewer has made their own pass, unless they
   choose otherwise for this change. The choice is recorded.
5. **The diff stands alone.** Narrative (descriptions, summaries, tours)
   is shown beside the code, labelled as the author's claim, and is never
   given to a machine reviewer by default.
6. **Measure, don't ask.** What was on screen, for how long, what was
   flagged and what was decided are recorded. The reviewer's feeling of
   having understood is not.
7. **Every verdict has a reason.** A reject, a revert or a finding's
   dismissal takes a reason from a small fixed set, plus optional text.
   The set is shared with the agent and with the reports.
8. **Evidence over assertion.** A plan's acceptance criteria are checked
   against test results, proofs and checks the editor ran, not against
   the agent's statement that they pass.
9. **Ask for decisions, not documents.** The owner is asked questions
   with options, never asked to approve a plan, and each answer becomes
   a rule that the next question is checked against.

## The proposal

Each tool says what it is built on. Most of them are Lean policy over
primitives that exist: excerpt buffers, anchors, the edit log's origin,
the review record, rdm's reviews.

### 1. Roadmap review: the steering surface

A roadmap opens as a buffer built for steering, not for reading
top to bottom. rdm roadmaps already hold the parts; the buffer gives
each one a place and a key.

- **Intent at the top, editable in place**: the goal, the non-goals and
  each *done looks like* scenario (`WHEN … THEN …`) as separate blocks.
  A comment or an edit on one is a document review comment on that
  block, which the agent working the roadmap reads.
- **Phases as an outline**, each one line with its status, its
  difficulty, and a one-line *what it changes for me*: the change to
  the owner's picture of the editor, not the task list. Phases can be
  reordered, split, merged or cut from the outline; each such edit is
  staged through rdm.
- **The interview**: the questions the owner was asked when the roadmap
  was made and the answers given, and below them the open questions
  raised from below (tool 2) for this roadmap.
- **Progress against intent**: for each *done looks like* scenario,
  which phases serve it and whether a change has yet shown it, from the
  change briefs (tool 3). A scenario no phase serves is marked.
- **Drift**: a phase whose body has moved away from the intent (it does
  something in the non-goals, or serves no scenario) is marked, from an
  agent's check of each phase against the intent.
- **Steering verbs**: comment, approve, request changes; *reprioritise*
  (move a phase or a roadmap); *narrow* (move something to the
  non-goals); *park* (block a phase on a question). Each one is a staged
  rdm change, committed as one batch with `rdm commit`.

Built on: rdm roadmaps and phases as JSON, its document reviews (anchors
that resolve or drift), block decorations, the plan repo watch. Nothing
here needs a new rdm field.

### 2. The decision queue

Implementation plans and changes make choices. A judge, an agent run at
plan review and at change review, extracts each choice and sorts it:

| Kind | Example | Where it goes |
|---|---|---|
| Covered by a rule | "Spawn the child through the process service" | Resolved; the rule is cited in the plan review |
| Contradicts a rule | "Merge faces in Lean" | Back to the planning agent, as today's plan review does |
| Not covered, and reversible and local | A helper's name, a test fixture's shape | Resolved by the agent; listed in the change brief |
| Not covered, and a default the owner will live with, or hard to undo, or a change of scope | A default layout, an on-disk format, a deferral to a later phase | **A question to the owner** |

A question carries the choice, two or three options with their
consequences, the plan's pick and why, and links to the phase and the
roadmap's intent. The owner answers with one key. The plan that raised
it waits on that one question, and other work goes on.

The rules the judge reads are the project's own: `AGENTS.md`, the design
documents, the Decisions table, and memory feedback. An answer is written
back to one of them (a design document's decision, or a roadmap's
interview), so the same question is not asked twice. The number of
questions per phase is the measure that this works: it should fall as
the rules grow.

The judge is held honest the same way the reviewers are:

- **It does not read the agent's account of risk.** No "this is simple"
  or "low risk" from the planning agent is an input, which applies the
  framing result to triage.
- **Spot checks**: one plan in N (config) shows the owner every
  decision it resolved, as a list to skim, not the plan.
- **Escapes**: when a dogfooding bug or a later rework traces back to a
  choice the judge resolved, the ledger (tool 10) records it against the
  rule it relied on, and that rule is fixed.

### 3. The change brief

What a change did to the system, in the owner's terms, read before or
instead of the diff:

- **The model delta**: new and removed types, interfaces, ports, crates
  and Lean modules; changed public signatures; new dependency edges and
  new third-party dependencies. Derived from the syntax tree and the
  build, not written by the agent.
- **Against the intent**: which *done looks like* scenarios this change
  shows, with the evidence the editor ran (tests, checks, proofs).
- **Against the decisions**: each answered question it touched, and
  whether the change follows the answer.
- **Choices the agent made alone**: the third row of the judge's table.
- **Surprises**: files outside the phase's scope, tests deleted, skipped
  or loosened, findings of high severity, anything left as a TODO.
- **The agent's summary**, last and labelled as its claim.

From any line of the brief, one key opens the review buffer at the
hunks behind it. The brief is also what the explain view (tool 10) is
built from, so what the owner read is what they can show someone else.

### 4. The change stack (`vc-review`, grouped)

`vc-review` already orders hunks, tests first and then by dependency. Its
test rule (`isTest`) guesses from the path, and the guess misses this
repository's own tests (`lean/ModelTest/...`, a Rust `<module>/tests.rs`,
an inline `#[cfg(test)] mod tests`). A classifier for every language
cannot be kept up, and a wrong guess that does not say so is worse than
none. So the editor does not classify tests. It orders by history:

- **Plan step, then commit.** Agent work is test-first (AGENTS.md), so a
  step's failing-test commit comes before the code that passes it.
  Showing each hunk in the order of the commit that introduced it puts
  the promise before the implementation in any language, inline test
  modules included, with nothing to classify. A hunk's commit comes from
  git (the branch's blame against the merge base). Steps come from the
  `Plan-Step:` trailer, or from matching commit subjects to the plan's
  "TDD order and commits" until the trailer exists.
- **Without that history** (a squashed change, someone else's branch, a
  forge PR), there is no promise-before-how order to recover, and the
  editor does not pretend: files go by dependency, and the brief or the
  PR description comes first.
- **A project that wants tests grouped** supplies a function in its
  config, `review.isTest : Path → Bool`. With it, tests come first within
  each group; without it, nothing is guessed. The knowledge of a
  language's test layout lives in the project's config, not in the
  editor.
- Where a change has no tests for a scenario, that is a finding (the
  `untested` reason), not something the order hides.

The proposal groups the hunks and says why:

- **Groups ("cohorts")** in this order of preference:
  1. By plan step, from the edit log's origin once
     rdm:roadmap/acp-agents lands.
  2. Otherwise by def-use clusters from the syntax tree and the code
     index (ClusterChanges' links: a definition with its call sites,
     shared uses, the same method).
  3. Otherwise by file dependency, as now.
- **Each group's header states its rule**: `step 2 · "parse the config
  header" · 3 hunks · callee before caller`. Within a group, a callee
  comes before its callers, and the header names the rule that ordered
  the group (`plan step`, `commit order`, `config isTest`, `dependency`).
- **Side by side**: a group's hunks are one excerpt buffer, so a
  definition and its uses are on one screen. A neighbour strip shows the
  callers of a changed function that the change did *not* touch,
  because "absent" defects live there.
- **Order is overridable** (66% asked) and the override is recorded with
  the round, so the order the reviewer chose can be compared with the
  default.

### 5. Blind-first review mode

When the owner opens a change's code, the round has a mode, chosen by
the owner and remembered per roadmap:

| Mode | Shown first | When |
|---|---|---|
| **Blind first** | The diff alone. Machine findings and narrative are hidden until the reviewer ends their pass (one key) | Hard to undo; unfamiliar code |
| **Assisted** | Diff and findings together, findings ranked by severity and confidence, duplicates and previously dismissed ones suppressed | Familiar code |
| **Evidence only** | Criteria, tests and checks; hunks open on demand | Trivial changes, such as docs and generated files |

The reviewer's comments from the blind pass are kept apart, so each round
records which findings the human made unaided and which the machine
added. That is the calibration data (tool 9).

### 6. The coverage map

The status line already counts hunks *not examined*. The proposal extends
this to a map over the change, one cell per hunk, with four states:

- **examined**: on screen long enough;
- **flagged**: a human or machine comment;
- **glanced**: on screen too briefly to have been read;
- **never shown**.

The map sits in the review's margin. It gates nothing: an approval
records how much of the change was never shown, and the explain view
says so. A *glanced* threshold is a heuristic with no study behind it;
it is config and is measured, not asserted.

The map also covers what the change did not touch: callers of changed
functions and files the plan names but the change does not.

### 7. Understanding checks (teach-back)

Pascarella's second most frequent need is "is my understanding correct".
For each group the reviewer can write one line, *what* and *why*, in a
slot in the header. Then:

- the agent's own explanation of that group, hidden until now, is shown
  beside it;
- a machine check compares the two, separately for *what* and for *why*,
  and marks disagreement;
- disagreement is either a misunderstanding (the reviewer reads again)
  or a claim the code does not support (a finding).

Optional and cheap: one line per group, skippable. A skipped group shows
as *unexplained* in the round's report. The written lines become the
change's explanation for other people (tool 10). They are the reviewer's
words, checked against the code, not the agent's.

### 8. The trace matrix

One table per change: rows are the plan's acceptance criteria, columns
are *hunks*, *evidence* (tests that cover it and their result, checks
run, Lean proofs: proved, tested or unverified) and *status*. Two
derived lists sit under it:

- **Unplanned hunks**: hunks linked to no criterion. Each is either
  scope creep or a missing criterion, and the reviewer says which.
- **Unmet criteria**: criteria with no hunk or no passing evidence.

Evidence comes from runs the editor started (compile mode, `cargo test`,
`lake`), not from the agent's report that they passed.

### 9. Machine reviewers, contained

- A machine reviewer is given the diff, the plan's criteria and the
  repository, and **not** the PR description or the agent's summary
  (the framing result). Whether to add the narrative is a per-reviewer
  setting, off by default.
- Findings arrive as data, as
  [review-and-navigation.md](review-and-navigation.md#automated-reviewers)
  says: location, severity, confidence, stable identity, disposition.
- **Mechanical checks** run before any reader: every new dependency is
  looked up in its registry (invented packages), every new import
  resolves, every referenced path exists, every TODO and stubbed body
  added by the agent is listed.
- **Calibration**: for each machine reviewer, a running record of how
  many of its findings were kept or dismissed, and how many findings the
  humans made that it did not. The record is shown in the findings panel
  next to its comments.

### 10. Verdicts with reasons, and the failure ledger

Every reject, revert, dismissal and request for changes takes one reason
from a fixed set, extended from the AIDev categories and the failure
modes above:

`too-large` · `tangled` · `unnecessary` · `over-complex` · `spec-drift`
(does something the plan did not ask) · `spec-miss` (misses a criterion) ·
`invented-reference` (API, package, path) · `untested` · `tests-weakened`
(a test was deleted, skipped or made looser) · `unsafe` · `style` ·
`wrong-approach` · `other`.

The reasons are stored on the rdm review comment or on the round, and go
back to the agent with the comment. They feed a **failure ledger** per
roadmap: counts by reason, by agent and model, and by plan phase, each
entry linking back through finding to hunk, to the transcript step that
wrote it, and to the plan step it served. The ledger is what you show
someone else: "this agent drifts from spec on migrations", with the
cases one key away.

**Explain view**: for a change or a whole roadmap, a generated page made
of the reviewer's teach-back lines, the trace matrix, the coverage map,
the verdicts with reasons and the ledger's entries. It is assembled from
recorded data, not written fresh by a model, so it cannot claim more
than the review did. It exports as markdown for rdm or a PR.

### 11. Fatigue and pace

From the round's record: lines per minute, time per hunk, hunks reviewed
in this sitting, time since the last break. When pace rises past the
reviewer's own median, or a sitting has run long, the
status line says so. A nudge, not a gate. Baum's second large review was
faster and worse; METR's developers misjudged their own speed. No
threshold here comes from a study, so all of them are config and are
logged.

### 12. Tours

An agent can be asked for a tour of what it built. Tours are anchored
data, as [review-and-navigation.md](review-and-navigation.md#navigation-and-understanding)
says. Two additions from the evidence:

- the reviewer picks or reorders the stops, and the agent writes the
  prose (the hybrid scored 83% vs 57%);
- the tour shows what it leaves out: changed hunks and callers outside
  the tour are listed at its end, because readers treat omitted code as
  irrelevant.

## What is always on, and what is pulled

An earlier draft gave each change a scrutiny level from fixed rules and
switched tools on and off by level. It is set aside: it decides how
hard to read lines, when the owner's goal is to understand changes and
steer, and the line-level reading is the agents'. What remains of it:

- **Always on, for every change**, because they cost the owner nothing
  and every later choice is measured from them: the mechanical checks
  (tool 9), the recording of what was on screen (tool 6), and a reason
  on every reject, revert and dismissal (tool 10).
- **Pushed to the owner**: questions from the decision queue (tool 2),
  and a change brief (tool 3) when a phase's change is ready.
- **Pulled by the owner**: everything else. The change stack, the
  coverage map, blind-first mode, teach-back, the trace matrix and tours
  open from a line of the brief or a question, when the owner wants to
  look closer.
- **Escalation is a question, not a gate.** A high-severity finding, a
  change outside the phase's scope, a deleted test or a contradiction of
  an answered decision becomes an item in the decision queue, with the
  hunks one key away. It does not switch on review tools.
- **When the owner does read the code**, principle 4 holds: the agent's
  account and the machine's findings wait until the owner's own pass,
  unless they choose otherwise.

## What rdm needs

Checked against rdm as installed on 2026-11-19 (`rdm describe`, the
CLI's help, the plan repo's reviews). The editor can start on what rdm
has; each gap below has a workaround, and is a candidate change in rdm.

### What rdm already gives

| Need | rdm today |
|---|---|
| Roadmap, phases, body, dependencies | `roadmap show`/`update`, `phase list`/`show`/`update`, `depend`, `deps`, `split`, `promote`, all with `--format json` |
| Comments on a roadmap or one of its phases | Document reviews, quote or line anchors that resolve or drift, `--doc phase/<n>` on a roadmap review |
| Park a phase on a question | `phase update --status blocked --reason` (`blocked_reason`) |
| Review a change, anchored in its hunks | `review start --on change/<sha>`, `--quote` with `--path`, inside a hunk the change touches |
| Follow-up rounds of a change review | `--follows <id>` covers the commits since the followed review's head |
| A fix linked to the comment it answers | `review update --comment <n> --status addressed --applied-commit <sha>` |
| A change's plan and the plan's phase | A plan's `Implements:` and its *Change reviews*; `implements` on the change review |
| Which plan items and comments mention a file or a commit | `rdm backlinks rdm:src/<path>` and `rdm:src@<sha>` |
| Batching steering edits | Staged changes, `rdm status`, `rdm commit` |

So the roadmap buffer (tool 1), the review sink's rdm binding and most
of the why chain need nothing new. A review made without rdm is attached
later by replaying its comments into a new change review through the
CLI.

### Gaps, in the order the editor would hit them

| Gap | Workaround until then | Change in rdm |
|---|---|---|
| **Agents review under the owner's name.** All 466 reviews have author `edward`, so a human comment cannot be told from an agent's | None that is reliable | The dispatch and review skills set `RDM_REVIEW_AUTHOR` to the agent and model; the owner's stay the user. Needed before any calibration or "human-unaided" count means anything |
| **Severity, confidence and reason are text** in a comment's body (`severity: concern`, `confidence: 85`) | Parse the body's leading `key: value` lines | Fields on a comment: `severity`, `confidence`, and `reason` from a fixed set, also taken by `--status wont-fix` and by a request-changes verdict |
| **Plan steps and criteria are prose**: "TDD order and commits" and "Acceptance criteria → tests" are conventions of the plan body | Parse those headings; match commits to steps by subject, shown as a weaker link | Plan steps and criteria with ids in the plan's JSON (`steps: [{id, commit_subject}]`, `criteria: [{id, text, tests}]`), and a `Plan-Step: <plan>/<id>` commit trailer that the implementing skill writes and the change review checks |
| **Intent is prose**: Goal, Non-goals, Done looks like and Interview are headings in the roadmap body | Parse the headings | Intent sections in the roadmap's JSON, each *done looks like* scenario with an id, so a phase can say which it serves and a change brief which it shows |
| **No decisions**: an answered question lives in a roadmap's interview text or a design doc | The decision queue as review comments of a marked kind on the roadmap, answered by reply | A `decision` entity: question, options, the plan's pick, scope (roadmap or phase), the plan or change that raised it, status (open, answered, deferred), the answer, and where the answer was recorded. `rdm decision list --open` is the queue; a phase parked on one names it |
| **No phase reorder**: phases are created and removed, not moved | Remove and re-create, which loses the phase's history | `rdm phase move <stem> --to <n>` |
| **No change notification** | A recursive watch on the plan repo (built), as [review-and-navigation.md](review-and-navigation.md#rdm) says | A watch or event stream, as before |
| **The judge** is not a skill yet: plan review finds rule violations but does not extract choices | Run it from the editor as a job over an agent | rdm's plan-review skill emits each choice with its sorting, and writes owner-bound ones as decisions |
| **Escapes**: nothing ties a later fix to the decision or plan choice it corrects | A task that cites both | A link from a commit or task to a decision (`Corrects: rdm:decision/<id>`), counted per rule |

The first two are small and unblock the measurements everything else
is judged by, so they come first. The plan, intent and decision
structure can follow one at a time; the editor's parsing workaround for
each is dropped when rdm's field lands, since the rdm binding is the only
code that reads them.

## Where each piece lives

| Piece | Lean (policy) | Rust (primitive) | rdm |
|---|---|---|---|
| Roadmap review | The buffer, steering verbs, drift and progress against intent | Block decorations, anchors | Roadmaps, phases, reviews; staged changes |
| Decision queue | The judge's job, the sorting, writing answers back | Processes | Questions as review comments or interview entries; a decision record (open question) |
| Change brief | The model delta, the cross-checks, the layout | Syntax tree | Phase scope; intent; decisions |
| Why pane, Rationale and review sink | The chain, composing the sources, unexplained hunks | Excerpt buffers, block decorations | Plans' commit and criteria lists, change reviews; a `Plan-Step:` trailer (new convention) |
| Change stack | Grouping and order, header text | Excerpt buffers; syntax tree for def-use | Plan step from the phase |
| Blind-first mode | Mode, what is hidden, round record | Decorations shown or hidden | None |
| Coverage map | States, thresholds, the gate | Viewed ranges (built) | None |
| Teach-back | Slots, compare job | None | Stored as review comments |
| Trace matrix | The table, derivation | Tables as text | Criteria; links |
| Machine reviewers | Prompting, suppression, calibration | Processes | Findings as review comments |
| Verdict reasons, ledger, explain view | The set, the reports | None | Reason field (new); export |
| Pace | Measures, nudge | Clock, viewed time (built) | None |
| Tours | Coverage of the tour | Excerpt buffers, anchors | None |

Rules from [overview.md](overview.md) hold: the decisions are Lean,
pinned by the model's tests; each adapter forwards. Machine reviewers and
the compare job are jobs over the process service.

## Suggested order

1. **The roadmap buffer** (tool 1) over what rdm already has: intent,
   phases, interview, document reviews, the steering verbs. It needs no
   new rdm field and moves the owner's existing steering into the
   editor.
2. **The why pane and the two interfaces** (Rationale and review sink)
   in the review buffer, with the rdm and git implementations first:
   commits matched to plan steps, criteria to tests, fixes to review
   comments, and unexplained hunks counted. It works on any branch, with
   or without rdm, from the start.
3. **Verdict reasons and the round's record** (tool 10, first half),
   cheap, and the data every later choice is measured from.
4. **The change brief** (tool 3), starting with the model delta and the
   surprises, which need no judge.
5. **The decision queue** (tool 2): the judge, the questions, and
   writing answers back to the rules.
6. **The pulled views**: change-stack headers (4), the coverage map (6),
   blind-first and diff-only machine review (5, 9).
7. **Teach-back, the trace matrix, the ledger, the explain view and
   tours** (7, 8, 10, 12).

## Open questions

- **Does any of this restore high-severity detection?** The evidence that
  blind-first, coverage maps and diff-only review counter anchoring is an
  inference from what anchoring is. The rounds the editor keeps can test
  it on the owner's own reviews: severity of human-unaided findings in
  blind-first rounds against assisted ones.
- **Does grouping help on agent changes?** For human changes, splitting
  cut noise but not defects, and order was not significant. Agent
  changes are larger and more tangled, so the effect may be larger. That
  is the hypothesis to measure, not a finding.
- **The judge's line**: which uncovered choices are the owner's. The
  table's fourth row is a starting rule; the spot checks and escapes
  are how it is tuned.
- **Which rdm gaps to close, and in what order**: see "What rdm needs".
  Each can be worked around in the editor's rdm binding first.
- **The reason set**: is thirteen too many to pick from under time
  pressure? Start with it, count which are used, and merge the rare ones.
- **Teach-back cost**: will a busy supervisor write one line per group?
  Make it optional and measure how often it is used and whether its
  disagreements lead to findings.
- **What counts as "examined"**: time on screen is a weak proxy for
  reading. Eye tracking is out of scope; cursor movement within a hunk
  might be a better signal.
