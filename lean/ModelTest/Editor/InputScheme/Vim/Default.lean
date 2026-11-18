import Editor.Config.Registry
import Editor.Event
import Editor.Evil.Compiled
import Editor.InputScheme
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Keymap
import Editor.Minibuffer
import Editor.Minibuffer.Compiled
import Editor.Role
import Editor.Scene
import Editor.Shell
import Editor.TabCommands
import Editor.TabCommands.Compiled
import Editor.Text
import Editor.WindowCommands
import Editor.WindowCommands.Compiled
import ModelTest.Check
import ModelTest.Support.Keys
import ModelTest.Support.Vim

/-!
# Model tests: `Editor/InputScheme/Vim/Default.lean`

The model tests of `Editor/InputScheme/Vim/Default.lean`: `vimDefaultChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The record of the default Vim state view 0 is in after the keys `text`
names. -/
def vimDefaultRecord (text : String) : Vim.StateRecord :=
  (vimDefault text).1.record Vim.Default.states ⟨0⟩

/-- Whether each of `texts` runs a command under the default Vim scheme,
each a command of another name. -/
def vimDefaultCommands (texts : List String) : Bool :=
  let names := (texts.filterMap vimDefaultCommand).map (·.name)
  names.length == texts.length && names.eraseDups.length == texts.length

/-- The checks of the Vim scheme's default states and bindings
(`Editor/InputScheme/Vim/Default.lean`). They observe the defaults through
the grammar, by what the default keys parse to, and restate no table: a
check names a key, and no vocabulary or command name. -/
def vimDefaultChecks : List Check :=
  [{  name :=
        "after an operator's key, i or a and the key after it are a text object, the operator's target: i alone still runs the command that enters insert, d i <Escape> and d i x reset and leave nothing pending, the counts of 2 d 3 i w multiply, a register named before the operator is kept, and d z t still yields nothing and leaves nothing pending"
      run :=
        let objectOver (text : String) : Option (String × Option Nat × Option String) :=
          match vimDefaultEdit text with
          | some (.operate _ (.textObject name) count register) => some (name, count, register)
          | _ => none
        let resets (text : String) : Bool :=
          (vimDefault text).2.getLast? == some .nothing && (vimDefault text).1.typed == []
        pure
          ((objectOver "d i w").isSome && (objectOver "c a (").isSome &&
            (objectOver "y i \"").isSome &&
            (vimDefaultCommand "i").bind (·.enters) == some (vimDefaultRecord "i").name &&
            (vimDefaultRecord "i").insertsText &&
            resets "d i <Escape>" &&
            resets "d i x" &&
            resets "d z t" &&
            (objectOver "2 d 3 i w").map (·.2.1) == some (some 6) &&
            (objectOver "\" a d a w").map (·.2.2) == some (some "a")) },
    { name :=
        "each alias of a block object after an operator yields what its primary key yields: i ) and i b as i (, a ) and a b as a (, i ] as i [, a ] as a [, i } and i B as i {, a } and a B as a {"
      run :=
        let aliases :=
          [("i )", "i ("), ("i b", "i ("), ("a )", "a ("), ("a b", "a ("), ("i ]", "i ["),
            ("a ]", "a ["), ("i }", "i {"), ("i B", "i {"), ("a }", "a {"), ("a B", "a {")]
        pure <|
          aliases.all fun (alias, primary) =>
            (vimDefaultEdit s!"d {alias}").isSome &&
              vimDefaultEdit s!"d {alias}" == vimDefaultEdit s!"d {primary}" &&
              vimDefaultEdit s!"d {alias}" != vimDefaultEdit "d i w" },
    { name :=
        "in a visual state a text object's keys select it: v i w yields an edit that is not the last change and leaves the view in v's state, v 2 i w carries the count, a register named before it is dropped, and V a ( leaves the view in v's state"
      run :=
        let selects (text : String) : Option (Option Nat) :=
          match vimDefaultEdit text with
          | some (.select _ count) => some count
          | _ => none
        pure
          (selects "v i w" == some none && (vimDefault "v i w").1.lastChange == none &&
            (vimDefaultRecord "v i w").name == (vimDefaultRecord "v").name &&
            selects "v 2 i w" == some (some 2) &&
            selects "v \" a i w" == some none &&
            (vimDefault "v \" a i w").1.register == none &&
            selects "V a (" == some none &&
            (vimDefaultRecord "V a (").name == (vimDefaultRecord "v").name &&
            (vimDefaultRecord "V").name != (vimDefaultRecord "v").name) },
    { name :=
        "C-g in the initial state runs the interrupt command, which changes no text and enters no state"
      run :=
        pure
          ((vimDefaultCommand "C-g").map
              (fun command => (command.name, command.changes, command.enters)) ==
            some (Shell.interruptName, false, none)) },
    { name := "every row of each default table binds its keys, and no table is empty"
      run :=
        pure <|
          [Vim.Default.motions, Vim.Default.operators, Vim.Default.objects,
                Vim.Default.normalCommands, Vim.Default.insertCommands, Vim.Default.visualCommands,
                Vim.Default.visualLineCommands, Vim.Default.minibufferCommands,
                Vim.Default.scrollCommands].all
            fun table =>
            !table.isEmpty && (Vim.Default.keymap table).bindings.length == table.length },
    { name :=
        "each of the default keys C-d C-u C-f C-b runs a command of its own that changes no text and enters no state, in the initial state and, the same command, in each visual state, which the view stays in; a count typed before one is that command's count; after an operator's key each yields nothing and drops the operator; in the state i enters none runs a command; and in the minibuffer's state C-d C-f C-b run none and C-u runs the minibuffer's command that deletes to the input's start"
      run :=
        let scrollKeys := ["C-d", "C-u", "C-f", "C-b"]
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ Vim.Default.scheme.init
        let runsNone (parsed : List Vim.Parsed) : Bool :=
          match parsed.getLast? with
          | some (.edit _) => false
          | _ => true
        pure
          (vimDefaultCommands scrollKeys &&
            scrollKeys.all fun text =>
              let command := vimDefaultCommand text
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange == none &&
                (["v", "V"].all fun state =>
                  vimDefaultCommand s!"{state} {text}" == command &&
                    (vimDefault s!"{state} {text}").1.current == (vimDefault state).1.current &&
                    (vimDefault s!"{state} {text}").1.lastChange == none) &&
                (match vimDefaultEdit s!"5 {text}" with
                | some (.run counted (some 5) none) => some counted == command
                | _ => false) &&
                (vimDefault s!"d {text}").2.getLast? == some .nothing &&
                vimDefaultEdit s!"d {text} w" == vimDefaultEdit "w" &&
                (vimDefaultEdit "w").isSome &&
                runsNone (vimDefault s!"i {text}").2 &&
                let inMinibuffer :=
                  (vimParsedFrom told text (view := ⟨5⟩) (states := Vim.Default.states)).2
                if text == "C-u" then
                  match inMinibuffer.getLast? with
                  | some (.edit (.run command none none)) =>
                    command.name == Minibuffer.deleteToStartName
                  | _ => false
                else runsNone inMinibuffer) },
    { name :=
        "in the minibuffer's state <ArrowLeft> and <ArrowRight> yield a move by the motions left and right, with no count"
      run :=
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ Vim.Default.scheme.init
        let moved (text : String) : Option Vim.Edit :=
          match
            (vimParsedFrom told text (view := ⟨5⟩) (states := Vim.Default.states)).2.getLast? with
          | some (.edit edit) => some edit
          | _ => none
        pure
          (moved "<ArrowLeft>" == some (.move "left" none) &&
            moved "<ArrowRight>" == some (.move "right" none)) },
    { name :=
        "each of the default keys <Backspace> RET TAB <ArrowLeft> <ArrowRight> <ArrowUp> <ArrowDown>, after i, runs a command of its own that leaves the view in the state i enters and does not replace the last change"
      run :=
        let editingKeys :=
          ["<Backspace>", "RET", "TAB", "<ArrowLeft>", "<ArrowRight>", "<ArrowUp>", "<ArrowDown>"]
        pure
          (vimDefaultCommands (editingKeys.map (s!"i {·}")) &&
            editingKeys.all fun text =>
              (vimDefault s!"i {text}").1.current == (vimDefault "i").1.current &&
                (vimDefault s!"i {text}").1.lastChange == (vimDefault "i").1.lastChange) },
    { name :=
        "<Backspace>, RET and TAB in a session are kept with its typed text, in the order typed, for a repeat: <Backspace> as the backspace character, RET as a line feed and TAB as a tab"
      run :=
        pure
          ((vimDefault "i x <Backspace> y").1.inserted == some "x\x08y" &&
            (vimDefault "i x RET y").1.inserted == some "x\ny" &&
            (vimDefault "i x TAB y").1.inserted == some "x\ty" &&
            (vimDefault "c w <Backspace> <Backspace> y").1.inserted == some "\x08\x08y" &&
            (vimDefault "c w <Backspace>").1.lastChange == (vimDefault "c w").1.lastChange) },
    { name :=
        "an arrow key in a session restarts the last change as i once something is typed after it, as Vim 9.1's ins-special-special says: the text kept is what was typed since; with nothing typed after it the last change and its text stay as they were"
      run :=
        let arrows := ["<ArrowLeft>", "<ArrowRight>", "<ArrowUp>", "<ArrowDown>"]
        pure
          (arrows.all fun arrow =>
            (vimDefault s!"i x {arrow} y").1.inserted == some "y" &&
              (vimDefault s!"A x {arrow} y").1.lastChange == (vimDefault "i").1.lastChange &&
              (vimDefault s!"c w x {arrow} y z").1.inserted == some "yz" &&
              (vimDefault s!"c w x {arrow} <Backspace>").1.inserted == some "\x08" &&
              (vimDefault s!"c w x {arrow} RET").1.lastChange == (vimDefault "i").1.lastChange &&
              (vimDefault s!"c w x {arrow}").1.inserted == some "x" &&
              (vimDefault s!"c w x {arrow} <Escape>").1.lastChange ==
                (vimDefault "c w").1.lastChange &&
              (vimDefault s!"c w x {arrow} <Escape> y").1.inserted == some "x") },
    { name :=
        "every command a key of insert state's table or of the minibuffer's state's table runs is registered under its name by evil's commands or the minibuffer's"
      run :=
        let registered := (Evil.commands ++ Minibuffer.commands).map (·.name)
        pure
          ((Vim.Default.insertCommands ++ Vim.Default.minibufferCommands).all fun
            | (_, .command command) => registered.contains command.name
            | _ => true) },
    { name :=
        "each of the default key sequences z t, z z and z b runs a command of its own that changes no text and enters no state, in the initial state and, the same command, in each visual state, which the view stays in; z alone yields nothing and is pending; and in the state i enters and in the minibuffer's state z is typed text"
      run :=
        let sequences := ["z t", "z z", "z b"]
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ Vim.Default.scheme.init
        pure
          (vimDefaultCommands sequences &&
            (sequences.all fun text =>
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange == none &&
                (Vim.Default.scheme.pending (vimDefault text).1).isEmpty &&
                ["v", "V"].all fun state =>
                  vimDefaultCommand s!"{state} {text}" == vimDefaultCommand text &&
                    (vimDefault s!"{state} {text}").1.current == (vimDefault state).1.current &&
                    (vimDefault s!"{state} {text}").1.lastChange == none) &&
            (vimDefault "z").2 == [.nothing] &&
            Vim.Default.scheme.pending (vimDefault "z").1 == keys "z" &&
            (vimDefault "i z").2.getLast? == some (.text "z") &&
            (vimParsedFrom told "z" (view := ⟨5⟩) (states := Vim.Default.states)).2 ==
              [.text "z"]) },
    { name :=
        "each default motion key yields a move with no count, each by a motion of another name: h j k l w b e W B E 0 ^ $ gg G"
      run :=
        let motionKeys :=
          ["h", "j", "k", "l", "w", "b", "e", "W", "B", "E", "0", "^", "$", "g g", "G"]
        let names :=
          motionKeys.filterMap fun text =>
            match vimDefaultEdit text with
            | some (.move name none) => some name
            | _ => none
        pure (names.length == motionKeys.length && names.eraseDups.length == motionKeys.length) },
    { name :=
        "each default operator key followed by a motion operates over that motion, and typed twice over one line, each an operator of another name: d c y"
      run :=
        let operatorKeys := ["d", "c", "y"]
        let operators :=
          operatorKeys.filterMap fun text =>
            match vimDefaultEdit s!"{text} w", vimDefaultEdit s!"{text} {text}",
              vimDefaultEdit "w" with
            | some (.operate operator (.motion target) none none),
              some (.operate doubled .lines (some 1) none), some (.move motion none) =>
              if operator == doubled && target == motion then some operator.name else none
            | _, _, _ => none
        pure
          (operators.length == operatorKeys.length &&
            operators.eraseDups.length == operatorKeys.length) },
    { name :=
        "of the default operators c leaves the view in a state where typing is text and d and y leave it where it was, and d and c change text and y does not"
      run :=
        pure
          ((vimDefaultRecord "c w").insertsText && (vimDefault "d w").1.current == [] &&
            (vimDefault "y w").1.current == [] &&
            (vimDefault "d w").1.lastChange == vimDefaultEdit "d w" &&
            (vimDefault "c w").1.lastChange == vimDefaultEdit "c w" &&
            (vimDefault "d w").1.lastChange.isSome &&
            (vimDefault "y w").1.lastChange == none) },
    { name :=
        "each of the default keys i a I A o O runs a command of its own that changes text and leaves the view in a state where typing is text"
      run :=
        let insertKeys := ["i", "a", "I", "A", "o", "O"]
        pure
          (vimDefaultCommands insertKeys &&
            insertKeys.all fun text =>
              (vimDefaultRecord text).insertsText && (vimDefault text).1.lastChange.isSome &&
                (vimDefault text).1.lastChange == vimDefaultEdit text) },
    { name :=
        "each of the default keys x p P runs a command of its own that changes text and enters no state"
      run :=
        let changeKeys := ["x", "p", "P"]
        pure
          (vimDefaultCommands changeKeys &&
            changeKeys.all fun text =>
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange.isSome) },
    { name :=
        "each of the default keys u C-r : runs a command of its own that changes no text and enters no state"
      run :=
        let plainKeys := ["u", "C-r", ":"]
        pure
          (vimDefaultCommands plainKeys &&
            plainKeys.all fun text =>
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange == none) },
    { name :=
        "the default key . is the repeat key, and no command's: with no last change it yields nothing, and after x it yields the replay of that change and leaves it the last change"
      run :=
        let deleteChar : Vim.Edit := .run { name := "delete-char", changes := true } none none
        pure
          ((vimDefault ".").2 == [.nothing] && (vimDefault ".").1.lastChange == none &&
            (vimDefault "x .").2.getLast? == some (.edit (.replay deleteChar none)) &&
            (vimDefault "x .").1.lastChange == some deleteChar &&
            (vimDefault "x .").1.current == []) },
    { name :=
        "the default keys v and V enter two different states where operators act on the selection, change no text, and each key typed again, and the other, goes where it should: back to the initial state, or to the other visual state"
      run :=
        pure
          ((vimDefaultRecord "v").operatesOnSelection &&
            (vimDefaultRecord "V").operatesOnSelection &&
            (vimDefaultRecord "v").name != (vimDefaultRecord "V").name &&
            (vimDefault "v").1.lastChange == none &&
            (vimDefault "V").1.lastChange == none &&
            (vimDefault "v v").1.current == [] &&
            (vimDefault "V V").1.current == [] &&
            (vimDefault "v V").1.current == (vimDefault "V").1.current &&
            (vimDefault "V v").1.current == (vimDefault "v").1.current) },
    { name :=
        "the default <Escape> returns to the initial state from each state another default key enters: from the state i enters, and from the two v and V enter"
      run :=
        pure
          (["i", "v", "V"].all fun text =>
            !(vimDefault text).1.current.isEmpty &&
              (vimDefault s!"{text} <Escape>").1.current == []) },
    { name :=
        "in the default visual states an operator key operates over the selection at once and a motion key is a move"
      run :=
        pure
          (["v", "V"].all fun text =>
            (match vimDefaultEdit s!"{text} d" with
              | some (.operate _ .selection none none) => true
              | _ => false) &&
              (vimDefault s!"{text} d").1.current == [] &&
              vimDefaultEdit s!"{text} w" == vimDefaultEdit "w" &&
              (vimDefaultEdit "w").isSome) },
    { name :=
        "the default register prefix names a register for an operator in normal state and in each visual state"
      run :=
        let register (text : String) : Option String :=
          match vimDefaultEdit text with
          | some (.operate _ _ _ register) => register
          | _ => none
        pure
          (register "\" + y w" == some "+" && register "v \" a d" == some "a" &&
            register "V \" a d" == some "a" &&
            register "y w" == none) },
    { name :=
        "in the default state that i enters a key bound to a motion in the initial state is typed text, and after <Escape> it is that motion again"
      run :=
        pure
          ((vimDefault "i h").2.getLast? == some (.text "h") &&
            (vimDefault "i 0").2.getLast? == some (.text "0") &&
            vimDefaultEdit "i <Escape> h" == vimDefaultEdit "h" &&
            (vimDefaultEdit "h").isSome) },
    { name :=
        "the cursor of the default initial state is a block, and that of the state i enters a bar"
      run :=
        pure
          ((vimDefaultRecord "").cursor == .block && Vim.Default.states.initial.cursor == .block &&
            (vimDefaultRecord "i").cursor == .bar &&
            (vimDefaultRecord "i").name != (vimDefaultRecord "").name) },
    { name :=
        "under the default Vim scheme a view opened as the minibuffer's is in a state of its own, where typing is text and the cursor is a bar: a letter, a digit and a key the initial state binds to a motion are text there; RET and <Escape> each run a command, of two different names, that enters no state and leaves nothing pending; a view that was not opened as the minibuffer's is in the initial state"
      run :=
        let states := Vim.Default.states
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ (Vim.scheme states).init
        let record := told.record states ⟨5⟩
        let parsed (text : String) : Vim.State × List Vim.Parsed :=
          vimParsedFrom told text (view := ⟨5⟩) (states := states)
        let command (text : String) : Option String :=
          match (parsed text).2 with
          | [.edit (.run command none none)] => some command.name
          | _ => none
        pure
          (record.insertsText && record.cursor == .bar && record.name != states.initial.name &&
            record.name != (vimDefaultRecord "i").name &&
            (parsed "a 7 w").2 == [.text "a", .text "7", .text "w"] &&
            (vimDefaultEdit "w").isSome &&
            (command "RET").isSome &&
            (command "<Escape>").isSome &&
            command "RET" != command "<Escape>" &&
            (["RET", "<Escape>"].all fun text => (parsed text).1 == told) &&
            told.stateOf states ⟨0⟩ == states.initial.name) },
    { name :=
        "under the default Vim scheme the minibuffer's state binds the keys that move through a prompt's candidates: TAB and C-n each run the minibuffer's command that moves to the next, S-TAB and C-p the one that moves to the previous; each enters no state and leaves nothing pending, and none of the four is text"
      run :=
        let states := Vim.Default.states
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ (Vim.scheme states).init
        let parsed (text : String) : Vim.State × List Vim.Parsed :=
          vimParsedFrom told text (view := ⟨5⟩) (states := states)
        let command (text : String) : Option String :=
          match (parsed text).2 with
          | [.edit (.run command none none)] => some command.name
          | _ => none
        pure
          (command "TAB" == some Minibuffer.nextName && command "C-n" == some Minibuffer.nextName &&
            command "S-TAB" == some Minibuffer.previousName &&
            command "C-p" == some Minibuffer.previousName &&
            Minibuffer.nextName != Minibuffer.previousName &&
            ["TAB", "C-n", "S-TAB", "C-p"].all fun text => (parsed text).1 == told) },
    { name :=
        "the default Vim scheme reports a fresh view as a block with an inclusive selection, no selecting and no insert session; after i a bar, an exclusive selection, an insert session and a view that takes text; and after i and <Escape> what it reported first"
      run :=
        let fresh := vimDefaultReport ""
        let inserting := vimDefaultReport "i"
        pure
          (fresh.cursor.shape == .block && fresh.shape == .inclusive && !fresh.selecting &&
            !fresh.session &&
            !fresh.takesText &&
            inserting.cursor.shape == .bar &&
            inserting.shape == .exclusive &&
            !inserting.selecting &&
            inserting.session &&
            inserting.takesText &&
            inserting.cursor.face != fresh.cursor.face &&
            vimDefaultReport "i <Escape>" == fresh) },
    { name :=
        "the default Vim scheme reports selecting in the states v and V enter, with an inclusive selection after v and a line-shaped one after V, neither an insert session; v then V is reported as V is, and V then v as v is"
      run :=
        let visual := vimDefaultReport "v"
        let line := vimDefaultReport "V"
        pure
          (visual.selecting && visual.shape == .inclusive && !visual.session && !visual.takesText &&
            line.selecting &&
            line.shape == .line &&
            !line.session &&
            !line.takesText &&
            vimDefaultReport "v V" == line &&
            vimDefaultReport "V v" == visual &&
            vimDefaultReport "v v" == vimDefaultReport "" &&
            vimDefaultReport "V V" == vimDefaultReport "") },
    { name :=
        "the default Vim scheme reports the minibuffer's view as a bar with an exclusive selection, in an insert session, taking text; and the status fields and the cursor faces of its five states all differ"
      run :=
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ Vim.Default.scheme.init
        let minibuffer := Vim.Default.scheme.report told ⟨5⟩
        let reports := minibuffer :: ["", "i", "v", "V"].map vimDefaultReport
        pure
          (minibuffer.cursor.shape == .bar && minibuffer.shape == .exclusive &&
            !minibuffer.selecting &&
            minibuffer.session &&
            minibuffer.takesText &&
            Vim.Default.scheme.report told ⟨0⟩ == vimDefaultReport "" &&
            reports.all (·.status.size == 1) &&
            (reports.map (·.status)).eraseDups.length == 5 &&
            (reports.map (·.cursor.face)).eraseDups.length == 5) },
    { name :=
        "criterion 2: in normal state C-w C-n, C-w C-p, C-w C-c and C-w C-w run the window commands Vim binds to C-w n, C-w p, C-w c and C-w w, each changing no text and entering no state"
      run :=
        pure <|
          [("C-w C-n", WindowCommands.newName), ("C-w C-p", WindowCommands.lastName),
                ("C-w C-c", WindowCommands.closeName), ("C-w C-w", WindowCommands.nextName)].all
            fun (text, name) =>
            vimDefaultCommand text == some { name } && (vimDefault text).2.head? == some .nothing },
    { name :=
        "criterion 4: in normal state each key of the tab table runs its tab command, changing no text and entering no state: C-w n the next tab, C-w p the previous, C-w c a new one, C-w & close, C-w w switch, and C-w 1 to C-w 9 the tab of that number"
      run :=
        pure <|
          let rows : List (String × String) :=
            [("C-w n", TabCommands.nextName), ("C-w p", TabCommands.previousName),
                ("C-w c", TabCommands.newName), ("C-w &", TabCommands.closeName),
                ("C-w w", TabCommands.switchName)] ++
              (List.range 9).map fun index =>
                (s!"C-w {index + 1}", TabCommands.selectName (index + 1))
          rows.all fun (text, name) =>
            vimDefaultCommand text == some { name } && (vimDefault text).2.head? == some .nothing },
    { name :=
        "every row of the tab commands' table binds its keys in normal state to the command it names, and every command it names is a tab command that is registered"
      run :=
        pure <|
          let registered := TabCommands.commands.map (·.name)
          Vim.Default.tabKeys.length == 14 &&
            (Vim.Default.keymap Vim.Default.tabCommands).bindings.length ==
              Vim.Default.tabKeys.length &&
            Vim.Default.tabKeys.all fun (text, name) =>
              vimDefaultCommand text == some { name } && registered.contains name },
    { name :=
        "C-w alone is pending in normal state; after an operator's key C-w s resets and leaves nothing pending; in the state i enters C-w runs a command that changes no text and enters no state, so the view stays there"
      run :=
        pure <|
          (vimDefault "C-w").2 == [.nothing] && (vimDefault "C-w").1.typed == keys "C-w" &&
            (vimDefault "d C-w s").2.getLast? == some .nothing &&
            (vimDefault "d C-w s").1.typed == [] &&
            (vimDefaultCommand "i C-w").any
              (fun command => !command.changes && command.enters.isNone) &&
            (vimDefaultRecord "i C-w").name == (vimDefaultRecord "i").name },
    { name :=
        "every row of the window commands' table binds its keys in normal state to the command it names, and every command it names is a window command that is registered"
      run :=
        pure <|
          let registered := WindowCommands.commands.map (·.name)
          !Vim.Default.windowKeys.isEmpty &&
            (Vim.Default.keymap Vim.Default.windowCommands).bindings.length ==
              Vim.Default.windowKeys.length &&
            Vim.Default.windowKeys.all fun (text, name) =>
              vimDefaultCommand text == some { name } && registered.contains name },
    { name :=
        "C-w H, C-w J, C-w K and C-w L run the commands that move a window to the left, bottom, top and right edge and back, each changing no text and entering no state"
      run :=
        pure <|
          [("C-w H", WindowCommands.edgeLeftName), ("C-w J", WindowCommands.edgeBottomName),
                ("C-w K", WindowCommands.edgeTopName), ("C-w L", WindowCommands.edgeRightName)].all
            fun (text, name) =>
            vimDefaultCommand text == some { name } && (vimDefault text).2.head? == some .nothing },
    { name :=
        "C-w F runs the command that moves a window between the tiles and the floating layer, changing no text and entering no state"
      run :=
        pure <|
          vimDefaultCommand "C-w F" == some { name := WindowCommands.floatName } &&
            (vimDefault "C-w F").2.head? == some .nothing }]

end ModelTest
