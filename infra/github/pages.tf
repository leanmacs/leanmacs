# Enabled on purpose, not the live value: Pages is off, and unavailable on a
# private repository on the free plan. `repository` refers to
# github_repository.leanmacs, so this is created after the visibility change
# in the same apply. The site is deployed from an Actions artifact, so no
# branch holds built files and there is no `source` block. A resource of its
# own because provider 6.13.0 deprecates the `pages` block on
# github_repository. No `cname`.
#
# No import block: Pages is created by this config. After a lost state,
# import it before applying (README.md, "State").
resource "github_repository_pages" "leanmacs" {
  repository = github_repository.leanmacs.name
  build_type = "workflow"
}
