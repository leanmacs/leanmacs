import Editor.Command.Registry
import ModelTest.Check

/-!
# Model tests: `Editor/Command/Registry.lean`

The model tests of `Editor/Command/Registry.lean`: `registryRequestChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of what a runner answers a question to the registry and
config where no loop dispatched the command (`RegistryRequest.bare`,
`Editor/Command/Registry.lean`). -/
def registryRequestChecks : List Check :=
  [{  name :=
        "with no loop to answer, a registry question is answered as with nothing registered: no ex binding and no ex name, no theme, no command name and no key sequence for a view, auto-reload off, config's default workspace settings under generation 0, no display rule, no shell time limit and no syntax refresh delay, no language and no indent unit, no source in a category and no at-point source, and the inherited base of a child's environment; and any job name is taken, as a start of any name is"
      run :=
        pure <|
          RegistryRequest.bare (.ex "w") == none && (RegistryRequest.bare .exNames).isEmpty &&
            (RegistryRequest.bare .themeNames).isEmpty &&
            (RegistryRequest.bare .commandNames).isEmpty &&
            (RegistryRequest.bare (.keyBindings ⟨0⟩)).isEmpty &&
            RegistryRequest.bare .autoReload == false &&
            RegistryRequest.bare .workspaceSettings == ({}, 0) &&
            (RegistryRequest.bare .displayRules).isEmpty &&
            RegistryRequest.bare .shellTimeLimit == none &&
            RegistryRequest.bare .syntaxRefreshDelay == none &&
            RegistryRequest.bare (.languageOf "/p/main.rs") == none &&
            RegistryRequest.bare (.indentUnitOf "rust") == none &&
            (RegistryRequest.bare (.categorySources "buffer")).isEmpty &&
            (RegistryRequest.bare (.atPointSources (some "notes") #["one"] .key)).isEmpty &&
            (RegistryRequest.bare (.atPointSources none #[] .key)).isEmpty &&
            RegistryRequest.bare .environmentBase == Process.inheritedName &&
            RegistryRequest.bare (.hasJob "nope") == true },
    { name := "with no loop to answer, a store's codec is asked and none is answered"
      run := pure ((RegistryRequest.bare (.storeCodec "shell-history")).isNone) }]

end ModelTest
