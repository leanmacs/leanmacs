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
# so the first plan changes only those two. Changing one here changes the
# live repository on the next apply.
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
  # If the first apply rejects this block because the provider sent it
  # before the change of visibility, run `mise run infra-apply` again: the
  # repository is public by then.
  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }

  lifecycle {
    prevent_destroy = true
    # Cosmetic settings are out of scope (README.md).
    ignore_changes = [description, homepage_url, topics]
  }
}
