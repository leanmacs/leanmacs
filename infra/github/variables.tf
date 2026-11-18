variable "state_passphrase" {
  description = "The pbkdf2 passphrase that encrypts state and plan files. Set by `op run --env-file=op.env` as TF_VAR_state_passphrase; never stored in a file."
  type        = string
  sensitive   = true
}

variable "enable_security_and_analysis" {
  description = "Whether github_repository.leanmacs declares its security_and_analysis block (secret scanning and push protection). Left true everywhere except the first apply's first step, run with TF_VAR_enable_security_and_analysis=false while the repository is still private (README.md, \"The first apply\")."
  type        = bool
  default     = true
  nullable    = false
}

variable "import_existing" {
  description = "Whether the import blocks run. Left true everywhere except tests/*.tftest.hcl, because `tofu test` can't import."
  type        = bool
  default     = true
  nullable    = false
}
