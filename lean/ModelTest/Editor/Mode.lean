import Editor.Command
import Editor.Event
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Keymap
import Editor.Language
import Editor.Mode
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Keys

/-!
# Model tests: `Editor/Mode.lean`

The model tests of `Editor/Mode.lean`: `modeRecordChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A mode the mode checks run on: `listing`, which fills two roles and has
one suffix, each with a command of its own. -/
def listing : Mode :=
  { name := "listing"
    roles := [(Role.nextItem, "listing-next"), (Role.previousItem, "listing-previous")]
    locals := [("x", "listing-execute")] }

/-- The test scheme with keymaps of its own, which bind `C-x C-s` and
`C-x C-f`, and a hand-tuned key for `listing` that they do not bind: what
`Mode.check` is run against. -/
def checkedScheme : InputScheme :=
  { TestScheme.scheme with
    defaults :=
      [Keymap.ofList [(keys "C-x C-s", invoke "save")],
        Keymap.ofList [(keys "C-x C-f", invoke "find")]]
    tuned := [("listing", keys "C-t", invoke "tuned-t")] }

/-- What the keymaps `mode` makes for the test scheme `scheme` make of
`keys`. -/
def modeLookup (mode : Mode) (keys : List Key) (scheme : InputScheme := TestScheme.scheme)
    (same : scheme.Binding = Invocation := by rfl) : Lookup Invocation :=
  Keymap.resolve (same ▸ mode.keymaps scheme) keys

/-- The checks of roles and of the mode record (`Editor/Role.lean`,
`Editor/Mode.lean`): the roles the core registers, and the keymaps a mode
makes for a scheme, read through the test scheme's role table and leader. -/
def modeRecordChecks : List Check :=
  [{  name := "a mode's role is bound at the scheme's key for the role to the mode's command"
      run :=
        pure
          (modeLookup listing (roleKeys Role.nextItem) == .bound (invoke "listing-next") &&
            modeLookup listing (roleKeys Role.previousItem) == .bound (invoke "listing-previous") &&
            modeLookup listing (roleKeys Role.quit) == .unbound) },
    { name := "a mode's suffix is bound under the scheme's localleader to the mode's command"
      run :=
        let localLeader := TestScheme.scheme.leaders.localLeader
        pure
          (modeLookup listing (localLeader ++ keys "x") == .bound (invoke "listing-execute") &&
            modeLookup listing localLeader == .pending &&
            modeLookup listing (keys "x") == .unbound) },
    { name :=
        "a mode's suffix is bound under the localleader of the leaders it is given, and only there"
      run :=
        let leaders : Key.Leaders := { leader := keys "C-x", localLeader := keys "C-x m" }
        let lookup (keys : List Key) : Lookup Invocation :=
          Keymap.resolve (listing.keymaps TestScheme.scheme leaders) keys
        pure
          (lookup (keys "C-x m x") == .bound (invoke "listing-execute") &&
            lookup (keys "C-x m") == .pending &&
            lookup (TestScheme.scheme.leaders.localLeader ++ keys "x") == .unbound) },
    { name := "a suffix written with <leader> is not keys, and is reported so"
      run :=
        let leading : Mode := { name := "leading", locals := [("<leader> x", "leading-x")] }
        pure (leading.problems == [.unreadableSuffix "<leader> x"]) },
    { name := "a role the scheme has no key for binds nothing"
      run :=
        let marking : Mode := { name := "marking", roles := [(Role.mark, "marking-mark")] }
        pure
          ((marking.keymaps roleless).all (·.bindings.isEmpty) &&
            modeLookup marking (roleKeys Role.mark) == .bound (invoke "marking-mark")) },
    { name :=
        "a scheme's hand-tuned key for the mode is in the keymap ahead of the roles and suffixes, and wins over a role on the same key; another mode's is not"
      run :=
        let tuned : InputScheme :=
          { TestScheme.scheme with
            tuned :=
              [("listing", roleKeys Role.nextItem, invoke "tuned-next"),
                ("listing", keys "C-t", invoke "tuned-t"),
                ("other", keys "C-o", invoke "other-o")] }
        pure
          (modeLookup listing (roleKeys Role.nextItem) tuned == .bound (invoke "tuned-next") &&
            modeLookup listing (keys "C-t") tuned == .bound (invoke "tuned-t") &&
            modeLookup listing (roleKeys Role.previousItem) tuned ==
              .bound (invoke "listing-previous") &&
            modeLookup listing (keys "C-o") tuned == .unbound &&
            ((listing.keymaps tuned).head?.map (·.bindings.length)) == some 2) },
    { name :=
        "a mode says nothing of a syntax tree by default, and a lineage's is its nearest mode's that says"
      run :=
        let json : Mode := { name := "json", syntaxTree := some { grammar := "json" } }
        let five : Mode :=
          { name := "five", syntaxTree := some { grammar := "json", highlights := some "x" } }
        pure
          (listing.syntaxTree == none && Mode.syntaxTreeOf [listing] == none &&
            Mode.syntaxTreeOf [json, listing] == some { grammar := "json" } &&
            Mode.syntaxTreeOf [json, five, listing] == five.syntaxTree) },
    { name :=
        "the code mode's syntax tree is its buffer's language's: the nearest mode of a lineage that has its own tree or takes the language's, and has one to give, says; with no language the code mode says nothing, and a mode that does not take the language's never gives it"
      run :=
        let rustTree : Mode.SyntaxTree := { grammar := "rust" }
        let code := Language.codeMode
        let own : Mode :=
          { name := "own-json", parent := some "code", syntaxTree := some { grammar := "json" } }
        let derived : Mode := { name := "derived", parent := some "code" }
        let json : Mode := { name := "json", syntaxTree := some { grammar := "json" } }
        pure
          (code.name == Language.codeName && Language.codeName == "code" &&
            code.syntaxTree == none &&
            code.syntaxTreeOfLanguage &&
            !listing.syntaxTreeOfLanguage &&
            Language.modes.map (·.name) == #["code"] &&
            Mode.syntaxTreeOf [code] (some rustTree) == some rustTree &&
            Mode.syntaxTreeOf [code] none == none &&
            Mode.syntaxTreeOf [code] == none &&
            Mode.syntaxTreeOf [code, own] (some rustTree) == own.syntaxTree &&
            Mode.syntaxTreeOf [code, derived] (some rustTree) == some rustTree &&
            Mode.syntaxTreeOf [json, code] none == json.syntaxTree &&
            Mode.syntaxTreeOf [json, listing] (some rustTree) == json.syntaxTree &&
            Mode.syntaxTreeOf [listing] (some rustTree) == none) },
    { name := "Mode.check reports nothing for a mode with no problem, under a scheme that tunes it"
      run := pure (listing.check TestScheme.scheme == [] && listing.check checkedScheme == []) },
    { name := "Mode.check reports a role that is not registered, by its name"
      run :=
        let mode := { listing with roles := listing.roles ++ [(Role.mk "frobnicate", "f")] }
        pure
          (mode.check checkedScheme == [.unregisteredRole { name := "frobnicate" }] &&
            mode.problems == [.unregisteredRole { name := "frobnicate" }]) },
    { name :=
        "Mode.check reports a suffix used twice once, comparing suffixes as keys, so that two spellings of one key are one suffix"
      run :=
        let twice := { listing with locals := [("x", "a"), ("x", "b"), ("x", "c"), ("y", "d")] }
        let spelled := { listing with locals := [("TAB", "a"), ("<Tab>", "b")] }
        pure
          (twice.check checkedScheme == [.duplicateSuffix (keys "x")] &&
            spelled.check checkedScheme == [.duplicateSuffix (keys "TAB")]) },
    { name := "Mode.check reports a suffix that is not keys, and one that names no keys"
      run :=
        let mode := { listing with locals := listing.locals ++ [("S-a", "a"), ("", "b")] }
        pure (mode.check checkedScheme == [.unreadableSuffix "S-a", .unreadableSuffix ""]) },
    { name :=
        "Mode.check reports a hand-tuned key of the mode that the scheme's own keymaps bind exactly, and not one they bind longer, nor another mode's"
      run :=
        let shadowing : InputScheme :=
          { checkedScheme with
            tuned :=
              [("listing", keys "C-t", invoke "tuned-t"),
                ("listing", keys "C-x C-s", invoke "tuned-save"),
                ("listing", keys "C-x", invoke "tuned-prefix"),
                ("other", keys "C-x C-f", invoke "other-find")] }
        pure
          (listing.check shadowing == [.shadowsScheme (keys "C-x C-s")] &&
            listing.problems == []) },
    { name := "each problem Mode.check reports is described by a sentence naming it"
      run :=
        let described :=
          [Mode.Problem.unregisteredRole { name := "frobnicate" }, .duplicateSuffix (keys "C-x"),
                .unreadableSuffix "S-a", .shadowsScheme (keys "C-x C-s")].map
            Mode.Problem.describe
        pure
          ([("frobnicate", 0), ("C-x", 1), ("S-a", 2), ("C-x C-s", 3)].all fun (name, index) =>
            ((described[index]?).getD "").contains name) },
    { name :=
        "the registered roles are next-item, previous-item, activate, quit, refresh, toggle and mark, each a name of its own"
      run :=
        pure
          (Role.registered.map (·.name) ==
              ["next-item", "previous-item", "activate", "quit", "refresh", "toggle", "mark"] &&
            [Role.nextItem, Role.previousItem, Role.activate, Role.quit, Role.refresh, Role.toggle,
                Role.mark] ==
              Role.registered) }]

/-- The checks of a mode's descriptions (`Mode.roleDescs`,
`Mode.localDescs`): each is on its key in the mode's keymaps. -/
def modeDescriptionChecks : List Check :=
  [{  name :=
        "a mode's described role and described suffix carry their descriptions in its keymaps, a suffix matched as parsed chords, and an undescribed one has none"
      run :=
        let described : Mode :=
          { listing with
            locals := listing.locals ++ [("TAB", "listing-tab")]
            roleDescs := [(Role.nextItem, "Next")]
            localDescs := [("<Tab>", "Tab it")] }
        let localLeader := TestScheme.scheme.leaders.localLeader
        let roles := (described.keymaps TestScheme.scheme).getLast?.getD Keymap.empty
        pure
          (roles.describe? (roleKeys Role.nextItem) == some "Next" &&
            roles.describe? (localLeader ++ keys "TAB") == some "Tab it" &&
            roles.describe? (roleKeys Role.previousItem) == none &&
            roles.describe? (localLeader ++ keys "x") == none) }]

end ModelTest
