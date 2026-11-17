# Imported, not created: a lost state file is rebuilt by a plain apply.
# `tofu test` can't plan an import even against a mock provider (OpenTofu
# 1.13 panics), so the tests turn it off with var.import_existing.
import {
  for_each = var.import_existing ? toset(["leanmacs"]) : toset([])
  to       = github_repository.leanmacs
  id       = each.value
}

# Every value below except `visibility` and `security_and_analysis` is the
# live repository's value as of 2026-11-17 (`gh api repos/leanmacs/leanmacs`),
# so the two steps of the first apply change only those two (README.md,
# "The first apply"). Changing one here changes the live repository on the
# next apply.
resource "github_repository" "leanmacs" {
  name = "leanmacs"
  # On purpose, not the live value (`private`): the first apply makes the
  # repository public (docs/dev-practices/publishing.md). `mise run
  # infra-apply` runs `mise run secrets-scan` first.
  visibility = "public"

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false
  archived        = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = false
  allow_update_branch         = false
  delete_branch_on_merge      = false
  web_commit_signoff_required = false

  merge_commit_title          = "MERGE_MESSAGE"
  merge_commit_message        = "PR_TITLE"
  squash_merge_commit_title   = "COMMIT_OR_PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"

  # Enabled on purpose, not the live value (none: the repository is private
  # on the free plan). Free on a public repository, and a credential pushed
  # to one is exposed at once, so push protection refuses the push. Only
  # these two are sent by provider 6.13.0. No advanced_security: the
  # provider refuses it on a public repository.
  #
  # The provider's update (6.13.0, resourceGithubRepositoryUpdate in
  # github/resource_github_repository.go) sends this block in its first
  # PATCH, with the visibility left out, and sends the visibility in a
  # second PATCH only after the first succeeds. On the still-private
  # free-plan repository GitHub can refuse this block, and then the update
  # fails before the visibility changes, on every retry. So the first apply
  # is two steps (README.md, "The first apply"): with
  # var.enable_security_and_analysis false this block is not declared
  # (the attribute is Optional and Computed, so its absence plans no
  # change) and the apply makes the repository public; the second, with
  # the default true, enables these two on the now-public repository.
  dynamic "security_and_analysis" {
    for_each = var.enable_security_and_analysis ? [1] : []
    content {
      secret_scanning {
        status = "enabled"
      }
      secret_scanning_push_protection {
        status = "enabled"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
    # Cosmetic settings are out of scope (README.md).
    ignore_changes = [description, homepage_url, topics]
  }
}
