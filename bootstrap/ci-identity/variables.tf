variable "aws_region" {
  description = "Region of the workloads the pipeline deploys. Every regional ARN in the pipeline policies is pinned to it."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-\\d$", var.aws_region))
    error_message = "aws_region must look like 'us-east-1' (geo-direction-number)."
  }
}

variable "resource_prefix" {
  description = "Project identifier, the same value as resource_prefix in the main configuration. Names the pipeline roles and policies, and builds the <prefix>-<environment> scope the apply role is limited to."
  type        = string
  default     = "pyrosense"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.resource_prefix))
    error_message = "resource_prefix must be lowercase alphanumeric and hyphens only."
  }
}

variable "deploy_environment" {
  description = "The one environment the apply role may change. It is also the name of the GitHub environment whose jobs may assume that role."
  type        = string
  default     = "demo"

  # prod is deliberately not accepted yet: it would get its own apply role,
  # GitHub environment and review rules (production readiness, section 9).
  validation {
    condition     = var.deploy_environment == "demo"
    error_message = "Only the demo environment has a pipeline apply role (ADR-0023)."
  }
}

variable "root_state_key" {
  description = "S3 key of the main configuration's state (the `key` in config/backend.hcl). The only state object the pipeline roles can read; the lock file is <key>.tflock."
  type        = string
  default     = "pyrosense/terraform.tfstate"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+\\.tfstate$", var.root_state_key))
    error_message = "root_state_key must be an S3 key ending in .tfstate."
  }
}

# -----------------------------------------------------------------------------
# GitHub identity of the repository allowed to assume the roles.
#
# Names AND numeric ids: names build the `sub` claim, ids are immutable. A
# trust policy that matches only names can be satisfied by whoever registers
# the name after a rename or deletion; the ids cannot be re-registered.
#   gh api repos/<owner>/<repo> --jq '.owner.login, .owner.id, .name, .id'
# -----------------------------------------------------------------------------

variable "github_owner" {
  description = "GitHub account that owns the repository (login, as in github.com/<owner>)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", var.github_owner))
    error_message = "github_owner must be a GitHub login (letters, digits, hyphens, max 39)."
  }
}

variable "github_owner_id" {
  description = "Numeric id of the repository owner (.owner.id in the GitHub API). Checked against the repository_owner_id claim and part of the immutable sub."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,15}$", var.github_owner_id))
    error_message = "github_owner_id must be the numeric GitHub account id."
  }
}

variable "github_repository" {
  description = "Repository name, without the owner."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,100}$", var.github_repository))
    error_message = "github_repository must be a repository name without the owner."
  }
}

variable "github_repository_id" {
  description = "Numeric id of the repository (.id in the GitHub API). Checked against the repository_id claim and part of the immutable sub."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,15}$", var.github_repository_id))
    error_message = "github_repository_id must be the numeric GitHub repository id."
  }
}

variable "github_actor_ids" {
  description = "Numeric ids of the GitHub users whose workflow runs may assume either role (actor_id claim). One maintainer today: a run started by anyone else, a fork pull request included, gets no AWS credentials."
  type        = list(string)

  validation {
    condition     = length(var.github_actor_ids) > 0 && alltrue([for id in var.github_actor_ids : can(regex("^[0-9]{1,15}$", id))])
    error_message = "github_actor_ids must list at least one numeric GitHub user id."
  }
}
