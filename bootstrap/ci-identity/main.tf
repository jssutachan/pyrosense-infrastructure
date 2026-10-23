# -----------------------------------------------------------------------------
# bootstrap/ci-identity
#
# How a GitHub Actions run gets AWS credentials without any stored key
# (ADR-0023):
#
#   job with `permissions: id-token: write`
#     -> asks GitHub for a signed OIDC token (JWT) describing the run:
#        repository, owner, actor, event, environment...
#     -> sts:AssumeRoleWithWebIdentity with that token
#     -> STS checks the signature against the IdP declared below and the
#        claims against the role's trust policy
#     -> temporary credentials, valid for one job (15-60 min)
#
# Two roles, because "see" and "change" are different risks:
#
#   <prefix>-ci-plan          pull requests     reads, never writes
#   <prefix>-ci-apply-<env>   GitHub env <env>  writes, only to <prefix>-<env>-*
#                             (human approval)  and only IAM roles that carry
#                                               the workload boundary
#
# This stack is long-lived and applied by the operator. The pipeline cannot
# change it: the apply role is denied every IAM action on the pipeline's own
# roles, policies and identity provider (permissions.tf, ProtectPipelineIdentity).
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.aws_region

  # Everything the apply role may create or change starts with this, the same
  # name_prefix the main configuration builds (pyrosense-demo).
  scope = "${var.resource_prefix}-${var.deploy_environment}"
  # IoT topic rule names cannot contain hyphens; modules/iot replaces them.
  iot_rule_scope = replace(local.scope, "-", "_")

  # The pipeline's own names start with <prefix>-ci-, never <prefix>-<env>-,
  # so no pattern granted to the apply role can match them.
  plan_role_name  = "${var.resource_prefix}-ci-plan"
  apply_role_name = "${var.resource_prefix}-ci-apply-${var.deploy_environment}"

  # Read by name from the main configuration (data "aws_iam_policy"), so the
  # name is the contract between the two configurations.
  boundary_name = "${var.resource_prefix}-workload-boundary"

  # Same expression as bootstrap/state-backend.
  state_bucket_arn = "arn:${local.partition}:s3:::${var.resource_prefix}-tfstate-${local.account_id}"
  state_object_arn = "${local.state_bucket_arn}/${var.root_state_key}"
  state_lock_arn   = "${local.state_object_arn}.tflock"

  oidc_host = "token.actions.githubusercontent.com"

  # Immutable subject format: owner and repository carry their numeric ids
  # (repo:<owner>@<id>/<repo>@<id>:<context>). Default for repositories
  # created on or after 2026-07-15; older ones must opt in (README).
  github_sub_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}"
}

# -----------------------------------------------------------------------------
# Identity provider
# -----------------------------------------------------------------------------

# One per account and URL. No thumbprint_list: for GitHub, IAM validates the
# IdP certificate against its own trusted CAs and ignores any thumbprint.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]

  # Removing it breaks every pipeline role at once.
  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Trust policies: WHO may assume each role
#
# Every condition is StringEquals on an exact value: no StringLike, no
# wildcard in `sub`. A missing or misspelled claim fails closed.
#   aud                  the token was minted for AWS STS
#   sub                  this repository AND this context (PR / environment)
#   repository_id        immutable repository id
#   repository_owner_id  immutable owner id
#   actor_id             the run was started by an allowed user
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "plan_trust" {
  statement {
    sid     = "GitHubPullRequestsOfThisRepository"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # A job that names an environment gets an environment sub instead, so
    # the deploy job (environment: demo) can never use this role, and this
    # role can never be used outside a pull request.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["${local.github_sub_prefix}:pull_request"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_id"
      values   = [var.github_repository_id]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_owner_id"
      values   = [var.github_owner_id]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:actor_id"
      values   = var.github_actor_ids
    }
  }
}

data "aws_iam_policy_document" "apply_trust" {
  statement {
    sid     = "GitHubEnvironmentOfThisRepository"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only a job running in the GitHub environment gets this sub. The
    # environment's protection rules (required reviewer, allowed branches)
    # run BEFORE the job starts, so no token exists until a human approves.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["${local.github_sub_prefix}:environment:${var.deploy_environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_id"
      values   = [var.github_repository_id]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_owner_id"
      values   = [var.github_owner_id]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:actor_id"
      values   = var.github_actor_ids
    }
  }
}

# -----------------------------------------------------------------------------
# Roles
# -----------------------------------------------------------------------------

# One hour is the IAM default and the ceiling; each workflow asks for less
# (role-duration-seconds) and the session ends with the job anyway.
resource "aws_iam_role" "plan" {
  name                 = local.plan_role_name
  description          = "PyroSense CI: terraform plan from pull requests. Read-only (ADR-0023)."
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role" "apply" {
  name                 = local.apply_role_name
  description          = "PyroSense CI: apply/destroy ${local.scope} from the ${var.deploy_environment} GitHub environment (ADR-0023)."
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan" {
  for_each = {
    read  = aws_iam_policy.read.arn
    state = aws_iam_policy.state_plan.arn
  }

  role       = aws_iam_role.plan.name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "apply" {
  for_each = {
    read  = aws_iam_policy.read.arn
    state = aws_iam_policy.state_apply.arn
    data  = aws_iam_policy.apply_data.arn
    infra = aws_iam_policy.apply_infra.arn
    iam   = aws_iam_policy.apply_iam.arn
  }

  role       = aws_iam_role.apply.name
  policy_arn = each.value
}
