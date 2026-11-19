import Editor.Setup

/-!
# Packages

A package is how a feature registers with the editor: a name, and a `setup`
(`Editor/Setup.lean`), the program config's own `setup` is. So a feature
says what it registers with the operations config uses, and names none of
the registry's types.

```lean
def package : Package :=
  { name := "greeting"
    setup := do
      command "greet" (discard <| createText "hello")
      bindKey "C-c g" "greet" }
```

- **Its name names its owner** (`Package.owner`,
  `Editor/Config/Packages.lean`): what a package registers belongs to the
  owner called as the package is, so a reload, which replaces config's
  registrations, leaves a package's.
- **A host is handed its packages as an array**, and registers them in the
  array's order when it starts, before any config
  (`Config.State.ofPackages`). Of two packages that register one name, the
  later is the one found, and config's is found before either.
- **What a package's `setup` may say** is what config's may, less the
  settings only config chooses. What is refused, and what a package's
  `useStyleFor` means, is in `Editor/Config/Packages.lean`.

A package is plain data in `Type`: its `setup` is a program over the setup
port, which holds no `IO`. So an array of packages can be a field of what a
host is handed, and a test reads what a package registers with no host
(`Package.registered`).

This module imports the setup port alone, so that a package's module needs
nothing of the config session.
-/

namespace Editor

/-- A feature's registrations, by name: what a host is handed to register
(`Editor/Config/Packages.lean`). -/
structure Package where
  /-- The package's name, which names the owner of what it registers. It is
  not empty, not `config` and not `compiled`, and no two packages a host is
  handed share it. -/
  name : String
  /-- What the package registers: a program over the setup port, as
  config's `setup` is. -/
  setup : SetupM Unit

end Editor
