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

# The github-pages environment, which release.yml's `pages` job deploys to.
# GitHub created it when Pages was enabled; it is imported, and declared
# with its live values as of 2026-11-17: no reviewers, no wait timer, admins
# may bypass, and a custom branch policy, not protected branches. Import ID
# `<repository>:<environment>` (provider 6.13.0).
import {
  for_each = var.import_existing ? toset(["leanmacs:github-pages"]) : toset([])
  to       = github_repository_environment.github_pages
  id       = each.value
}

resource "github_repository_environment" "github_pages" {
  environment = "github-pages"
  repository  = github_repository.leanmacs.name

  can_admins_bypass   = true
  prevent_self_review = false

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

# The whole custom policy: main, and nothing else, so only a run on main
# may deploy the page. Its import ID is `<repository>:<environment>:<id>`,
# and the id is a number only the live API knows, so it has no import
# block: it is imported by hand, once (README.md, "Taking over
# github-pages").
resource "github_repository_environment_deployment_policy" "github_pages_main" {
  repository     = github_repository.leanmacs.name
  environment    = github_repository_environment.github_pages.environment
  branch_pattern = "main"
}
