import UserLinkFixture

/-!
# The entry module of the Lake package `user-link`

The module the package-set build reads (`docs/design/packages.md`, "The
package set and its build"): a Lake package named `p` lists its packages as
`packages` in `<P>.EditorPackage`. The root generated for the set in
`tests/user-link` imports this module after the core's entry module and
hands the hosts the core's packages and then these, so the package's
command registers after the shipped ones.
-/

namespace UserLink.EditorPackage

/-- The packages of the Lake package `user-link`, in the order a host
registers them. -/
def packages : Array Editor.Package :=
  #[UserLinkFixture.package]

end UserLink.EditorPackage
