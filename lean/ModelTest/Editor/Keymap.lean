import Editor.Event
import Editor.Keymap
import ModelTest.Check
import ModelTest.Support.Keys

/-!
# Model tests: `Editor/Keymap.lean`

The model tests of `Editor/Keymap.lean`: `keymapChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of a keymap's lookup (`Editor/Keymap.lean`): what a sequence
is bound to, which sequences a binding begins with, and the form of a key a
binding names. -/
def keymapLookupChecks : List Check :=
  let save : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "s"] 1
  let other : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "s"] 2
  let find : Keymap Nat := Keymap.empty.bind [charKey "f"] 3
  let long : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "r", charKey "t"] 4
  let prefixBound : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "r"] 5
  [{  name := "a key sequence bound in a keymap is found, bound to what it was given"
      run := pure (save.find? [controlKey "x", controlKey "s"] == some 1) },
    { name :=
        "a strict prefix of a bound sequence is not found, and a binding begins with it; a binding begins with the bound sequence too"
      run :=
        pure
          (save.find? [controlKey "x"] == none && save.continues [controlKey "x"] &&
            save.continues [controlKey "x", controlKey "s"]) },
    { name :=
        "a sequence no binding begins with is not found and nothing begins with it: another key, a bound sequence's second key, and a bound sequence with a key after it"
      run :=
        pure <|
          [[charKey "x"], [controlKey "s"], [controlKey "x", controlKey "x"],
                [controlKey "x", controlKey "s", controlKey "s"]].all
            fun keys => save.find? keys == none && !save.continues keys },
    { name := "binding a sequence a second time replaces what it was bound to"
      run :=
        let again := save.bind [controlKey "x", controlKey "s"] 2
        pure
          (again.find? [controlKey "x", controlKey "s"] == some 2 && again.bindings.length == 1) },
    { name := "a keymap made from a list binds each sequence, a later entry replacing an earlier"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofList [([charKey "a"], 1), ([charKey "b"], 2), ([charKey "a"], 3)]
        pure
          (keymap.find? [charKey "a"] == some 3 && keymap.find? [charKey "b"] == some 2 &&
            keymap.bindings.length == 2) },
    { name := "the empty sequence binds nothing"
      run :=
        let keymap : Keymap Nat := Keymap.empty.bind [] 1
        pure (keymap.bindings.isEmpty && keymap.find? [] == none && !keymap.continues []) },
    { name :=
        "a key from a window finds a binding by its chord: its physical code, whether it was repeated, and shift on a character are not part of it"
      run :=
        let typed : Key :=
          { logical := .character "A"
            physical := .code "KeyA"
            modifiers := { shift := true }
            repeated := true }
        let written : Keymap Nat := Keymap.empty.bind [charKey "A"] 1
        let fromWindow : Keymap Nat := Keymap.empty.bind [typed] 1
        pure
          (typed.chord == charKey "A" && written.find? [typed.chord] == some 1 &&
            fromWindow.find? [charKey "A"] == some 1 &&
            (controlKey "x").chord == controlKey "x") },
    { name :=
        "shift on a named key is part of its chord: the shifted key does not find the unshifted key's binding"
      run :=
        let shifted : Key :=
          { logical := .named .tab, physical := .code "Tab", modifiers := { shift := true } }
        let keymap : Keymap Nat := Keymap.empty.bind [namedKey .tab] 1
        pure
          (shifted.chord == namedKey .tab { shift := true } &&
            keymap.find? [shifted.chord] == none &&
            keymap.find? [namedKey .tab] == some 1 &&
            (keymap.bind [shifted] 2).find? [shifted.chord] == some 2) },
    { name := "of two keymaps that bind one sequence, the earlier in the list gives its binding"
      run :=
        pure
          (Keymap.resolve [other, save] [controlKey "x", controlKey "s"] == .bound 2 &&
            Keymap.resolve [save, other] [controlKey "x", controlKey "s"] == .bound 1) },
    { name :=
        "a sequence that begins a binding is pending, whichever keymap of the list the binding is in, and one that begins none is unbound"
      run :=
        pure
          (Keymap.resolve [save, find] [controlKey "x"] == .pending &&
            Keymap.resolve [save, long] [controlKey "x", controlKey "r"] == .pending &&
            Keymap.resolve [save, long] [controlKey "x", controlKey "q"] == .unbound &&
            Keymap.resolve ([] : List (Keymap Nat)) [controlKey "x"] == .unbound) },
    { name :=
        "a sequence a later keymap binds is bound although an earlier keymap has a longer binding that begins with it"
      run :=
        pure (Keymap.resolve [long, prefixBound] [controlKey "x", controlKey "r"] == .bound 5) },
    { name := "the walk given a key that begins a binding keeps it pending and yields nothing"
      run :=
        let (first, firstBound) := Keymap.walk [long] [] (controlKey "x")
        let (second, secondBound) := Keymap.walk [long] first (controlKey "r")
        pure
          (first == [controlKey "x"] && firstBound == none &&
            second == [controlKey "x", controlKey "r"] &&
            secondBound == none) },
    { name :=
        "the walk given the last key of a bound sequence yields its binding and leaves nothing pending"
      run :=
        pure
          (Keymap.walk [save] [controlKey "x"] (controlKey "s") == ([], some 1) &&
            Keymap.walk [find] [] (charKey "f") == ([], some 3)) },
    { name :=
        "the walk given an unbound key after a pending prefix yields nothing and leaves nothing pending"
      run :=
        pure
          (Keymap.walk [save] [controlKey "x"] (charKey "z") == ([], none) &&
            Keymap.walk [save] [] (charKey "z") == ([], none)) },
    { name := "the walk takes a key by its chord"
      run :=
        let typed : Key :=
          { logical := .character "s"
            physical := .code "KeyS"
            modifiers := { control := true }
            repeated := true }
        pure
          (Keymap.walk [save] [controlKey "x"] typed == ([], some 1) &&
            Keymap.walk [save] [] { controlKey "x" with physical := .code "KeyX" } ==
              ([controlKey "x"], none)) },
    { name :=
        "filtering a keymap keeps exactly the bindings whose binding is kept, in order, and what it binds is found by find? and continues"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofList
            [([charKey "a"], 1), ([controlKey "x", charKey "b"], 2), ([charKey "c"], 3),
              ([controlKey "x", charKey "d"], 4)]
        let odd := keymap.filter (· % 2 == 1)
        pure
          (odd.bindings == [([charKey "a"], 1), ([charKey "c"], 3)] &&
            odd.find? [charKey "c"] == some 3 &&
            odd.find? [controlKey "x", charKey "b"] == none &&
            !odd.continues [controlKey "x"] &&
            (keymap.filter (· > 3)).continues [controlKey "x"] &&
            (keymap.filter fun _ => true).bindings == keymap.bindings) },
    { name :=
        "keysFor gives the sequences bound to the bindings a predicate keeps, in the order each was last bound, and a sequence rebound to another binding is not among them"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofList
            [([charKey "a"], 1), ([charKey "b"], 2), ([controlKey "x", charKey "c"], 1),
              ([charKey "d"], 1), ([charKey "a"], 1), ([charKey "d"], 2)]
        pure
          (keymap.keysFor (· == 1) == [[controlKey "x", charKey "c"], [charKey "a"]] &&
            keymap.keysFor (· == 2) == [[charKey "b"], [charKey "d"]] &&
            keymap.keysFor (· == 3) == []) },
    { name :=
        "the walk over specific keymaps and defaults: a specific prefix shadows a default binding of the same keys, so C-w is pending where the specific maps bind C-w h and the defaults bind C-w alone, and h then gives the specific binding"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [controlKey "w", charKey "h"] 1
        let defaults : Keymap Nat := Keymap.empty.bind [controlKey "w"] 2
        let (first, firstBound) := Keymap.walkOver [specific] [defaults] [] (controlKey "w")
        pure
          (first == [controlKey "w"] && firstBound == none &&
            Keymap.walkOver [specific] [defaults] first (charKey "h") == ([], some 1) &&
            Keymap.walkOver [] [defaults] [] (controlKey "w") == ([], some 2)) },
    { name :=
        "the walk over specific keymaps and defaults gives the specific binding of a sequence both bind exactly, and the default binding of one the specific maps leave unbound"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [charKey "x"] 1
        let defaults : Keymap Nat := (Keymap.empty.bind [charKey "x"] 2).bind [charKey "b"] 3
        pure
          (Keymap.walkOver [specific] [defaults] [] (charKey "x") == ([], some 1) &&
            Keymap.walkOver [specific] [defaults] [] (charKey "b") == ([], some 3)) },
    { name :=
        "the walk over specific keymaps and defaults merges prefixes: with g r specific and g g default, g is pending, then g g gives the default and g r the specific binding"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [charKey "g", charKey "r"] 1
        let defaults : Keymap Nat := Keymap.empty.bind [charKey "g", charKey "g"] 2
        let (pending, bound) := Keymap.walkOver [specific] [defaults] [] (charKey "g")
        pure
          (pending == [charKey "g"] && bound == none &&
            Keymap.walkOver [specific] [defaults] pending (charKey "g") == ([], some 2) &&
            Keymap.walkOver [specific] [defaults] pending (charKey "r") == ([], some 1)) },
    { name :=
        "the walk over specific keymaps and defaults resets on a sequence neither binds nor begins: alone, after a specific prefix, and after a prefix of both"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [controlKey "w", charKey "h"] 1
        let defaults : Keymap Nat :=
          (Keymap.empty.bind [controlKey "w"] 2).bind [charKey "g", charKey "g"] 3
        pure
          (Keymap.walkOver [specific] [defaults] [] (charKey "z") == ([], none) &&
            Keymap.walkOver [specific] [defaults] [controlKey "w"] (charKey "x") == ([], none) &&
            Keymap.walkOver [specific] [defaults] [charKey "g"] (charKey "q") == ([], none)) }]

/-- The checks of a keymap's descriptions: each one is on the binding it
describes, set by `bind` and `ofDescribed`, and dropped with the binding. -/
def descriptionChecks : List Check :=
  let described : Keymap Nat :=
    Keymap.empty.bind [controlKey "x", controlKey "s"] 1 (desc := some "Save")
  [{  name := "a sequence bound with a description is described by it"
      run :=
        pure
          (described.describe? [controlKey "x", controlKey "s"] == some "Save" &&
            described.describe? [controlKey "x"] == none &&
            (Keymap.empty.bind [charKey "f"] (3 : Nat)).describe? [charKey "f"] == none) },
    { name := "binding a described sequence again without a description drops the description"
      run :=
        let again := described.bind [controlKey "x", controlKey "s"] 2
        let relabelled := described.bind [controlKey "x", controlKey "s"] 2 (desc := some "Write")
        pure
          (again.describe? [controlKey "x", controlKey "s"] == none && again.descriptions.isEmpty &&
            relabelled.describe? [controlKey "x", controlKey "s"] == some "Write" &&
            relabelled.descriptions.length == 1) },
    { name :=
        "filtering a keymap drops the description of a binding it removes and keeps the others"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofDescribed
            [([charKey "a"], 1, some "one"), ([charKey "b"], 2, some "two"),
              ([charKey "c"], 3, none)]
        let odd := keymap.filter (· % 2 == 1)
        pure
          (odd.describe? [charKey "a"] == some "one" && odd.describe? [charKey "b"] == none &&
            odd.descriptions == [([charKey "a"], "one")]) },
    { name :=
        "a keymap made from a described list binds each sequence with its row's description, a later row replacing an earlier"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofDescribed
            [([charKey "a"], 1, some "one"), ([charKey "b"], 2, none),
              ([charKey "a"], 3, some "three")]
        pure
          (keymap.find? [charKey "a"] == some 3 && keymap.describe? [charKey "a"] == some "three" &&
            keymap.find? [charKey "b"] == some 2 &&
            keymap.describe? [charKey "b"] == none &&
            keymap.bindings.length == 2) }]

/-- Whether every continuation of `listed`, walked by `walk` after
`pending`, gives what it says it leads to (`Keymap.Continuation.walked`). -/
def walksAsListed {β : Type} [BEq β] (walk : List Key → Key → List Key × Option β)
    (pending : List Key) (listed : List (Keymap.Continuation β)) : Bool :=
  listed.all fun c => walk pending c.key == c.walked pending

/-- The checks of what can follow a pending prefix (`Keymap.continuations`,
`Keymap.continuationsOver`): the keys listed, in order, what each leads to,
and that the walk agrees. -/
def continuationChecks : List Check :=
  let g := charKey "g"
  let r := charKey "r"
  let cw := controlKey "w"
  let cx := controlKey "x"
  [{  name :=
        "with g g bound in the defaults and g r in the specific keymaps, the keys after g are r and then g, the specific tier's first, each leading to its binding"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [g, r] 1
        let defaults : Keymap Nat := Keymap.empty.bind [g, g] 2
        let listed := Keymap.continuationsOver [specific] [defaults] [g]
        pure
          (listed == [⟨r, .bound 1 none⟩, ⟨g, .bound 2 none⟩] &&
            walksAsListed (Keymap.walkOver [specific] [defaults]) [g] listed) },
    { name :=
        "with C-w l bound in the specific keymaps over C-w bound alone in the defaults, the only key after C-w is l"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [cw, charKey "l"] 1
        let defaults : Keymap Nat := Keymap.empty.bind [cw] 2
        let listed := Keymap.continuationsOver [specific] [defaults] [cw]
        pure
          (listed == [⟨charKey "l", .bound 1 none⟩] &&
            walksAsListed (Keymap.walkOver [specific] [defaults]) [cw] listed) },
    { name :=
        "with C-w l bound in the specific keymaps and C-w h and C-w l in the defaults, the keys after C-w are l, once and the specific binding, and h"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [cw, charKey "l"] 1
        let defaults : Keymap Nat :=
          (Keymap.empty.bind [cw, charKey "h"] 3).bind [cw, charKey "l"] 4
        let listed := Keymap.continuationsOver [specific] [defaults] [cw]
        pure
          (listed == [⟨charKey "l", .bound 1 none⟩, ⟨charKey "h", .bound 3 none⟩] &&
            walksAsListed (Keymap.walkOver [specific] [defaults]) [cw] listed) },
    { name :=
        "a key the list leaves out walks to nothing pending and nothing bound: one no binding has, and one bound only alone"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [g, r] 1
        let defaults : Keymap Nat := (Keymap.empty.bind [g, g] 2).bind [charKey "f"] 3
        let listed := Keymap.continuationsOver [specific] [defaults] [g]
        pure
          (listed.all (fun c => c.key != charKey "z" && c.key != charKey "f") &&
            Keymap.walkOver [specific] [defaults] [g] (charKey "z") == ([], none) &&
            Keymap.walkOver [specific] [defaults] [g] (charKey "f") == ([], none) &&
            (Keymap.continuations [defaults] [g]).all (·.key != charKey "f") &&
            Keymap.walk [defaults] [g] (charKey "f") == ([], none)) },
    { name :=
        "a key that leads to a prefix is listed with the prefix's name and the number of bindings the walk can reach under it, leaving out one under a shorter bound sequence"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofList
            [([cx, charKey "a", charKey "b"], 1), ([cx, charKey "a", charKey "b", charKey "c"], 2),
              ([cx, charKey "a", charKey "d"], 3)]
        let names (keys : List Key) : Option String :=
          if keys == [cx, charKey "a"] then some "alpha" else none
        let listed := Keymap.continuations [keymap] [cx] names
        pure
          (listed == [⟨charKey "a", .prefix (some "alpha") 2⟩] &&
            Keymap.continuations [keymap] [cx] == [⟨charKey "a", .prefix none 2⟩] &&
            walksAsListed (Keymap.walk [keymap]) [cx] listed) },
    { name :=
        "a prefix's count leaves out a default binding the specific tier hides under a binding of its own"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [cx, charKey "a", charKey "b"] 1
        let defaults : Keymap Nat := Keymap.empty.bind [cx, charKey "a", charKey "b", charKey "c"] 2
        let listed := Keymap.continuationsOver [specific] [defaults] [cx]
        pure
          (listed == [⟨charKey "a", .prefix none 1⟩] &&
            walksAsListed (Keymap.walkOver [specific] [defaults]) [cx] listed) },
    { name :=
        "a listed binding carries the description of the keymap whose binding the walk reaches: the deciding tier's, not the defaults' of the same keys"
      run :=
        let specific : Keymap Nat := Keymap.empty.bind [charKey "x"] 1 (desc := some "specific")
        let defaults : Keymap Nat :=
          Keymap.ofDescribed [([charKey "x"], 2, some "default"), ([charKey "b"], 3, some "bee")]
        let first : Keymap Nat := Keymap.empty.bind [charKey "x"] 4
        pure
          (Keymap.continuationsOver [specific] [defaults] [] ==
              [⟨charKey "x", .bound 1 (some "specific")⟩, ⟨charKey "b", .bound 3 (some "bee")⟩] &&
            Keymap.continuations [first, defaults] [] ==
              [⟨charKey "x", .bound 4 none⟩, ⟨charKey "b", .bound 3 (some "bee")⟩]) },
    { name := "with nothing pending, the list is every first key, each once, in the order bound"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofList [([cx, controlKey "s"], 1), ([charKey "f"], 2), ([cx, controlKey "f"], 3)]
        let listed := Keymap.continuations [keymap] []
        pure
          (listed == [⟨cx, .prefix none 2⟩, ⟨charKey "f", .bound 2 none⟩] &&
            walksAsListed (Keymap.walk [keymap]) [] listed) }]

/-- The checks of a keymap (`Editor/Keymap.lean`): its lookup, its
descriptions, and what can follow a pending prefix. -/
def keymapChecks : List Check :=
  keymapLookupChecks ++ descriptionChecks ++ continuationChecks

end ModelTest
