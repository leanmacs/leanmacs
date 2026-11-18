# Mocked-provider tests for pages.tf. Run by `mise run infra-check`.

variables {
  state_passphrase = "test-only-not-a-secret"
  # `tofu test` panics planning an import, even against a mock provider.
  import_existing = false
}

mock_provider "github" {}

run "pages_deploys_from_workflow" {
  command = plan

  assert {
    condition     = github_repository_pages.leanmacs.repository == github_repository.leanmacs.name
    error_message = "Pages must be configured on the managed repository."
  }

  assert {
    condition     = github_repository_pages.leanmacs.build_type == "workflow"
    error_message = "Pages must be built from Actions (build_type workflow)."
  }

  assert {
    condition     = length(github_repository_pages.leanmacs.source) == 0
    error_message = "Pages must have no source branch: no branch holds built files."
  }
}
