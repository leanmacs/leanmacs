# Mocked-provider tests for repository.tf: no credentials, no GitHub API,
# no network beyond the provider download `tofu init` already did. Run by
# `mise run infra-check`.

variables {
  state_passphrase = "test-only-not-a-secret"
  # `tofu test` panics planning an import, even against a mock provider.
  import_existing = false
}

mock_provider "github" {}

run "repository_is_leanmacs_and_public" {
  command = plan

  assert {
    condition     = github_repository.leanmacs.name == "leanmacs"
    error_message = "The managed repository must be leanmacs."
  }

  assert {
    condition     = github_repository.leanmacs.visibility == "public"
    error_message = "The repository must be public."
  }
}

run "repository_declares_the_live_features" {
  command = plan

  assert {
    condition = (
      github_repository.leanmacs.has_issues &&
      github_repository.leanmacs.has_projects &&
      !github_repository.leanmacs.has_wiki &&
      !github_repository.leanmacs.has_discussions &&
      !github_repository.leanmacs.is_template &&
      !github_repository.leanmacs.archived
    )
    error_message = "Issues and projects on; wiki, discussions, template and archived off: the live values."
  }
}

run "repository_declares_the_live_merge_settings" {
  command = plan

  assert {
    condition = (
      github_repository.leanmacs.allow_merge_commit &&
      github_repository.leanmacs.allow_squash_merge &&
      github_repository.leanmacs.allow_rebase_merge
    )
    error_message = "Merge, squash and rebase merges must all stay enabled."
  }

  assert {
    condition = (
      !github_repository.leanmacs.allow_auto_merge &&
      !github_repository.leanmacs.allow_update_branch &&
      !github_repository.leanmacs.delete_branch_on_merge &&
      !github_repository.leanmacs.web_commit_signoff_required
    )
    error_message = "Auto-merge, update-branch, delete-on-merge and web sign-off must stay off."
  }

  assert {
    condition = (
      github_repository.leanmacs.merge_commit_title == "MERGE_MESSAGE" &&
      github_repository.leanmacs.merge_commit_message == "PR_TITLE" &&
      github_repository.leanmacs.squash_merge_commit_title == "COMMIT_OR_PR_TITLE" &&
      github_repository.leanmacs.squash_merge_commit_message == "COMMIT_MESSAGES"
    )
    error_message = "The merge and squash commit titles and messages must be the live values."
  }
}

run "secret_scanning_and_push_protection_enabled" {
  command = plan

  assert {
    condition     = github_repository.leanmacs.security_and_analysis[0].secret_scanning[0].status == "enabled"
    error_message = "Secret scanning must be enabled."
  }

  assert {
    condition     = github_repository.leanmacs.security_and_analysis[0].secret_scanning_push_protection[0].status == "enabled"
    error_message = "Push protection must be enabled: it refuses a pushed credential."
  }
}

# The first apply's first step (README.md, "The first apply"): no
# security_and_analysis block, so the provider's first PATCH carries none
# and the visibility change is not blocked behind it; the repository is
# still made public.
run "first_step_declares_no_security_and_analysis" {
  command = plan

  variables {
    enable_security_and_analysis = false
  }

  assert {
    condition     = github_repository.leanmacs.visibility == "public"
    error_message = "The first step must still make the repository public."
  }

  assert {
    condition     = length(github_repository.leanmacs.security_and_analysis) == 0
    error_message = "With enable_security_and_analysis false, no security_and_analysis block may be declared."
  }
}
