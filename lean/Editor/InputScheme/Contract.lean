import Editor.InputScheme
import Editor.Role

/-!
# The contract of an input scheme

What every input scheme (`Editor/InputScheme.lean`) does, whatever its
grammar, as one list of properties (`properties`). It is published for every
scheme to run: the test scheme (`Editor/InputScheme/Test.lean`) is held to
it by `model-test`, and a scheme that ships runs the same list in its own
tests. This module imports only the scheme interface, so the contract never
depends on a scheme.

## How a scheme is run

A scheme's author supplies a `Subject`: the scheme, keymaps for it, a view,
some inputs the author says are complete (`sequences`), each a key sequence
whose last key yields an invocation, and one key that goes on with none of
them (`unbound`). A property is a pure function of the subject: it steps
the scheme from its initial state and looks at what each key yields and at
the pending keys the scheme reports. Nothing here knows what a binding is.

## The properties

- `hasPrefixes`: some sequence has two keys or more. The properties below
  are about strict prefixes, so without one they would hold with nothing to
  show.
- `strictPrefixEmitsNothing`: no key of a strict prefix of a sequence
  yields an invocation.
- `strictPrefixIsPending`: after a strict prefix, the scheme reports that
  prefix's chords as pending.
- `completeEmits`: the last key of a sequence yields an invocation, and
  nothing is then pending.
- `unboundResets`: after a strict prefix, the unbound key yields nothing
  and leaves nothing pending, and the sequence typed next yields what it
  yields from the initial state.
- `namedCommandRuns`: the unbound key, bound to `scheme.command` of a name
  in a keymap put before the subject's, yields an invocation of the command
  of that name when typed from the initial state, and leaves nothing
  pending. It is what lets a registry bind a key sequence to a command name
  under a scheme whose binding type it does not know.
- `everyRoleHasKey`: every registered role (`Role.registered`) has a key
  sequence, not empty, in the scheme's role table.
- `leaderAndRolesApart`: the leader is not empty, no two roles are on one
  key sequence, and no role's keys begin with the leader or are a prefix of
  it. A role key that collided with a leader suffix would make one of them
  unreachable, and no check of one mode can see it.
- `modeCommandRuns`: as `namedCommandRuns`, for `scheme.modeCommand`, what
  a key a mode binds (a role, a suffix) is bound to.

The contract compares no states: a scheme's state may hold what a reset
must keep, such as its last edit, and the record carries no equality on it.
A reset is seen in the pending keys and in what the scheme does next.

## Where an addition goes

Something every scheme must do is a property here, added to `properties`,
with a scheme in `ModelTest.schemeContractChecks` that breaks it and is
reported. Something one scheme does is that scheme's own test.
-/

namespace Editor.SchemeContract

/-- A scheme, and what its author gives the contract to run it on. -/
structure Subject where
  /-- The scheme. -/
  scheme : InputScheme
  /-- The active keymaps of each view, in precedence order. -/
  maps : ViewId → List (Keymap scheme.Binding)
  /-- The view the keys are for. -/
  view : ViewId
  /-- Inputs the author says are complete: the last key of each yields an
  invocation, typed from the initial state. One of them has two keys or
  more. -/
  sequences : List (List Key)
  /-- A key that goes on with no strict prefix of a sequence. -/
  unbound : Key

/-- One property of an input scheme. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Whether it holds of a subject. -/
  holds : Subject → Bool

/-- The subject's scheme stepped from `state` through `keys`: the state it
is left in, and what each key yielded. -/
def Subject.feedFrom (subject : Subject) (state : subject.scheme.State) (keys : List Key) :
    subject.scheme.State × List (Option Invocation) :=
  subject.scheme.feed subject.maps subject.view state keys

/-- The subject's scheme stepped from its initial state through `keys`. -/
def Subject.feed (subject : Subject) (keys : List Key) :
    subject.scheme.State × List (Option Invocation) :=
  subject.feedFrom subject.scheme.init keys

/-- The strict prefixes of `keys` that are not empty, shortest first. -/
def strictPrefixes (keys : List Key) : List (List Key) :=
  ((List.range keys.length).drop 1).map keys.take

/-- Whether `holds` of every strict prefix of every sequence of the subject,
given the sequence and the prefix. -/
def Subject.allPrefixes (subject : Subject) (holds : List Key → List Key → Bool) : Bool :=
  subject.sequences.all fun sequence => (strictPrefixes sequence).all (holds sequence)

/-- Some sequence has two keys or more, so the properties about strict
prefixes have a prefix to hold of. -/
def hasPrefixes : Property :=
  { name := "the subject has a sequence of two keys or more, so that it has a strict prefix"
    holds := fun subject => subject.sequences.any (·.length ≥ 2) }

/-- No key of a strict prefix of a sequence yields an invocation. -/
def strictPrefixEmitsNothing : Property :=
  { name := "a strict prefix of a complete input yields no invocation"
    holds := fun subject =>
      subject.allPrefixes fun _ typed => (subject.feed typed).2.all (·.isNone) }

/-- After a strict prefix, the scheme reports that prefix's chords as
pending. -/
def strictPrefixIsPending : Property :=
  { name := "after a strict prefix of a complete input, the scheme reports its keys as pending"
    holds := fun subject =>
      subject.allPrefixes fun _ typed =>
        subject.scheme.pending (subject.feed typed).1 == typed.map Key.chord }

/-- The last key of a sequence yields an invocation, and nothing is then
pending. -/
def completeEmits : Property :=
  { name :=
      "the last key of a complete input yields an invocation, and the scheme then reports no pending keys"
    holds := fun subject =>
      subject.sequences.all fun sequence =>
        let (state, yields) := subject.feed sequence
        (yields.getLast?.join).isSome && (subject.scheme.pending state).isEmpty }

/-- After a strict prefix, the unbound key yields nothing and leaves nothing
pending, and the sequence typed next yields what it yields from the initial
state. -/
def unboundResets : Property :=
  { name :=
      "an unbound key after a strict prefix yields no invocation and leaves no pending keys, and the input typed next yields what it yields from the initial state"
    holds := fun subject =>
      subject.allPrefixes fun sequence typed =>
        let (state, yields) := subject.feed (typed ++ [subject.unbound])
        yields.getLast? == some none && (subject.scheme.pending state).isEmpty &&
          (subject.feedFrom state sequence).2 == (subject.feed sequence).2 }

/-- The command name `namedCommandRuns` binds a key to. No scheme knows
it. -/
def namedCommand : String :=
  "contract-named-command"

/-- With the unbound key bound to `scheme.command` of a name in a keymap put
before the subject's, that key, typed from the initial state, yields an
invocation of the command of that name and leaves nothing pending. -/
def namedCommandRuns : Property :=
  { name :=
      "a key bound to what the scheme says runs a named command yields an invocation of the command of that name, and the scheme then reports no pending keys"
    holds := fun subject =>
      let bound : Keymap subject.scheme.Binding :=
        Keymap.ofList [([subject.unbound], subject.scheme.command namedCommand)]
      let (state, yielded) :=
        subject.scheme.step (fun view => bound :: subject.maps view) subject.view
          subject.scheme.init subject.unbound
      yielded.map (·.command) == some namedCommand && (subject.scheme.pending state).isEmpty }

/-- Every registered role has a key in the scheme's role table: a row, on a
sequence that is not empty. -/
def everyRoleHasKey : Property :=
  { name := "every registered role has a key in the scheme's role table"
    holds := fun subject =>
      Role.registered.all fun role =>
        match subject.scheme.roleKey role with
        | some keys => !keys.isEmpty
        | none => false }

/-- The leader is not empty, no two rows of the role table are on one key
sequence, and no role's keys begin with the leader or are a prefix of it. A
role key that collided with a leader suffix would make one of them
unreachable. -/
def leaderAndRolesApart : Property :=
  { name :=
      "the scheme has a leader, no two roles are on one key sequence, and no role's keys begin with the leader or begin it"
    holds := fun subject =>
      let leader := subject.scheme.leader.map Key.chord
      let sequences :=
        (subject.scheme.roles.map fun (_, keys) => keys.map Key.chord).filter (!·.isEmpty)
      !leader.isEmpty && sequences.eraseDups.length == sequences.length &&
        sequences.all fun keys => !leader.isPrefixOf keys && !keys.isPrefixOf leader }

/-- With the unbound key bound to `scheme.modeCommand` of a name in a keymap
put before the subject's, that key, typed from the initial state, yields an
invocation of the command of that name and leaves nothing pending. -/
def modeCommandRuns : Property :=
  { name :=
      "a key bound to what the scheme says a mode's key is bound to yields an invocation of the command of that name, and the scheme then reports no pending keys"
    holds := fun subject =>
      let bound : Keymap subject.scheme.Binding :=
        Keymap.ofList [([subject.unbound], subject.scheme.modeCommand namedCommand)]
      let (state, yielded) :=
        subject.scheme.step (fun view => bound :: subject.maps view) subject.view
          subject.scheme.init subject.unbound
      yielded.map (·.command) == some namedCommand && (subject.scheme.pending state).isEmpty }

/-- Every property of the contract. -/
def properties : List Property :=
  [hasPrefixes, strictPrefixEmitsNothing, strictPrefixIsPending, completeEmits, unboundResets,
    namedCommandRuns, everyRoleHasKey, leaderAndRolesApart, modeCommandRuns]

/-- The names of the properties that do not hold of `subject`; none when the
scheme keeps the contract. -/
def failures (subject : Subject) : List String :=
  (properties.filter (!·.holds subject)).map (·.name)

end Editor.SchemeContract
