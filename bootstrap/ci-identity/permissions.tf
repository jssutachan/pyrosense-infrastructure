# -----------------------------------------------------------------------------
# WHAT each role may do
#
# Where the action list comes from: CloudTrail recorded every call Terraform
# made during the October 2026 deploy/destroy cycles (116 distinct API calls
# across 12 services, docs/ci-cd.md section 8). That list is necessary but not
# sufficient, so it was completed by hand:
#   - API names are not IAM action names (PutBucketEncryption is authorised by
#     s3:PutEncryptionConfiguration; CreateFunction20150331 by
#     lambda:CreateFunction);
#   - some permissions never appear as an event: iam:PassRole, the Tag*
#     actions a Create call with tags needs, kms:CreateGrant used by Lambda;
#   - data events (SQS GetQueueAttributes, S3 object calls) are not in the
#     90-day Event History at all.
# It is a first version: C3 (plan) exercises every read and C4 (apply/destroy)
# every write. An AccessDenied there is a missing line here, added on purpose
# with the reason, never a wildcard.
#
# Four sizes of scope, from tightest to widest:
#   1. exact object       state file and lock file
#   2. name prefix        <prefix>-demo-* queues, topics, tables, roles...
#   3. tag                KMS keys (their ARN is a random id): Project and
#                         Environment tags, checked at creation and on use
#   4. "*"                reads of configuration metadata, and the few create
#                         calls that have no resource ARN (kms:CreateKey,
#                         iot:CreateCertificateFromCsr, Lambda event sources)
# -----------------------------------------------------------------------------

locals {
  arn_regional = "${local.region}:${local.account_id}"

  # Resource patterns of the environment the apply role may change.
  scoped = {
    sqs        = "arn:${local.partition}:sqs:${local.arn_regional}:${local.scope}-*"
    sns        = "arn:${local.partition}:sns:${local.arn_regional}:${local.scope}-*"
    dynamodb   = "arn:${local.partition}:dynamodb:${local.arn_regional}:table/${local.scope}-*"
    bucket     = "arn:${local.partition}:s3:::${local.scope}-*"
    objects    = "arn:${local.partition}:s3:::${local.scope}-*/*"
    kms_alias  = "arn:${local.partition}:kms:${local.arn_regional}:alias/${local.scope}*"
    kms_key    = "arn:${local.partition}:kms:${local.arn_regional}:key/*"
    lambda     = "arn:${local.partition}:lambda:${local.arn_regional}:function:${local.scope}-*"
    log_groups = "arn:${local.partition}:logs:${local.arn_regional}:log-group:/aws/*/${local.scope}*"
    alarms     = "arn:${local.partition}:cloudwatch:${local.arn_regional}:alarm:${local.scope}-*"
    dashboards = "arn:${local.partition}:cloudwatch::${local.account_id}:dashboard/${local.scope}-*"
    iot_thing  = "arn:${local.partition}:iot:${local.arn_regional}:thing/${local.scope}-*"
    iot_policy = "arn:${local.partition}:iot:${local.arn_regional}:policy/${local.scope}-*"
    iot_rule   = "arn:${local.partition}:iot:${local.arn_regional}:rule/${local.iot_rule_scope}_*"
    roles      = "arn:${local.partition}:iam::${local.account_id}:role/${local.scope}-*"
  }
}

# -----------------------------------------------------------------------------
# Read: shared by both roles. What `terraform plan` calls to refresh state.
# -----------------------------------------------------------------------------

# Resource "*" on purpose: these are Describe/Get/List calls on CONFIGURATION
# (a queue's attributes, a role's policy, a bucket's lifecycle rules), and
# most of them cannot be scoped by ARN anyway. What is excluded is the DATA:
# no s3:GetObject on data buckets, no dynamodb:GetItem/Query/Scan, no
# sqs:ReceiveMessage, no logs:GetLogEvents, no kms:Decrypt. That is why this is
# a written list and not the AWS-managed ReadOnlyAccess policy, which grants
# reads of data as well.
data "aws_iam_policy_document" "read" {
  statement {
    sid    = "DescribeProjectConfiguration"
    effect = "Allow"
    actions = [
      "budgets:ListTagsForResource",
      "budgets:ViewBudget",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:GetDashboard",
      "cloudwatch:ListTagsForResource",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTable",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:ListTagsOfResource",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListPolicies",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      # Not read-only in CloudTrail's classification, but it only returns the
      # account's MQTT endpoint, and plan needs it (data.aws_iot_endpoint).
      "iot:DescribeEndpoint",
      "iot:DescribeCertificate",
      "iot:DescribeThing",
      "iot:GetPolicy",
      "iot:GetPolicyVersion",
      "iot:GetTopicRule",
      "iot:ListAttachedPolicies",
      "iot:ListPolicyVersions",
      "iot:ListTagsForResource",
      "iot:ListTargetsForPolicy",
      "iot:ListThingPrincipals",
      "iot:ListThingPrincipalsV2",
      "iot:ListTopicRules",
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListAliases",
      "kms:ListResourceTags",
      "lambda:GetEventSourceMapping",
      "lambda:GetFunction",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:ListTags",
      "lambda:ListVersionsByFunction",
      "logs:DescribeLogGroups",
      "logs:DescribeMetricFilters",
      "logs:ListTagsForResource",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketLogging",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketPolicy",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:GetBucketWebsite",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "sns:GetSubscriptionAttributes",
      "sns:GetTopicAttributes",
      "sns:ListSubscriptionsByTopic",
      "sns:ListTagsForResource",
      # Data events: Terraform calls them but they are not in Event History.
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ListQueueTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "read" {
  name        = "${var.resource_prefix}-ci-read"
  description = "PyroSense CI: read project configuration for terraform plan; no data reads (ADR-0023)."
  policy      = data.aws_iam_policy_document.read.json
}

# -----------------------------------------------------------------------------
# State: the only object either role touches in the state bucket.
# -----------------------------------------------------------------------------

# Plan takes the lock too (native S3 lockfile): a plan that reads state while
# an apply is writing it would compare against a half-written file. The lock
# is a separate object, so taking it needs no write on the state itself.
data "aws_iam_policy_document" "state_plan" {
  # The S3 backend lists the bucket during init. Listing reveals object
  # names, not contents; every object read below is scoped to one key.
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid       = "ReadState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.state_object_arn]
  }

  statement {
    sid       = "TakeAndReleaseTheLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_lock_arn]
  }
}

resource "aws_iam_policy" "state_plan" {
  name        = "${var.resource_prefix}-ci-state-plan"
  description = "PyroSense CI: read the main state and take its lock (ADR-0023)."
  policy      = data.aws_iam_policy_document.state_plan.json
}

# Same as plan, plus writing the state. No s3:DeleteObject on the state:
# Terraform never deletes it, and versioning keeps every earlier version.
data "aws_iam_policy_document" "state_apply" {
  source_policy_documents = [data.aws_iam_policy_document.state_plan.json]

  statement {
    sid       = "WriteState"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = [local.state_object_arn]
  }
}

resource "aws_iam_policy" "state_apply" {
  name        = "${var.resource_prefix}-ci-state-apply-${var.deploy_environment}"
  description = "PyroSense CI: read and write the main state, take its lock (ADR-0023)."
  policy      = data.aws_iam_policy_document.state_apply.json
}

# -----------------------------------------------------------------------------
# Apply, data layer: KMS, SQS, SNS, DynamoDB, S3.
# -----------------------------------------------------------------------------

# kms:CreateKey has no resource ARN (the key does not exist yet), hence "*";
# it is limited to keys born with the project and environment tags, which
# default_tags adds to every resource. Tagging is part of creating a tagged
# key, so kms:TagResource is required as well. Known limit of tag-based
# scoping: the same statement lets the role put these two tags on another
# customer managed key of the account, which would bring that key into scope.
# Accepted while every CMK in the account belongs to PyroSense (ADR-0023).
data "aws_iam_policy_document" "apply_data" {
  statement {
    sid       = "CreateProjectKeysOnly"
    effect    = "Allow"
    actions   = ["kms:CreateKey", "kms:TagResource"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = ["PyroSense"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = [var.deploy_environment]
    }
  }

  # Every later call on a key requires it to carry both tags. kms:CreateGrant
  # serves Lambda (environment encryption) and DynamoDB (table encryption),
  # which create grants for themselves when a CMK is configured; the
  # GrantIsForAWSResource condition stops the role from granting the key to
  # anyone directly.
  statement {
    sid    = "ManageProjectKeys"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:DisableKeyRotation",
      "kms:EnableKeyRotation",
      "kms:PutKeyPolicy",
      "kms:ScheduleKeyDeletion",
      "kms:UntagResource",
      "kms:UpdateKeyDescription",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = [local.scoped.kms_key]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["PyroSense"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.deploy_environment]
    }
  }

  statement {
    sid       = "GrantProjectKeysToAwsServicesOnly"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = [local.scoped.kms_key]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["PyroSense"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.deploy_environment]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  # An alias call is authorised on the alias AND on the key; the key half is
  # covered by ManageProjectKeys only when the key carries the tags, so this
  # statement cannot point a project alias at a foreign key.
  statement {
    sid       = "ManageProjectAliases"
    effect    = "Allow"
    actions   = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias"]
    resources = [local.scoped.kms_alias]
  }

  statement {
    sid    = "ManageEnvironmentQueues"
    effect = "Allow"
    actions = [
      "sqs:CreateQueue",
      "sqs:DeleteQueue",
      "sqs:SetQueueAttributes",
      "sqs:TagQueue",
      "sqs:UntagQueue",
    ]
    resources = [local.scoped.sqs]
  }

  # Subscriptions are <topic ARN>:<id>, so the topic pattern covers them.
  statement {
    sid    = "ManageEnvironmentTopics"
    effect = "Allow"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:SetSubscriptionAttributes",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:TagResource",
      "sns:Unsubscribe",
      "sns:UntagResource",
    ]
    resources = [local.scoped.sns]
  }

  statement {
    sid    = "ManageEnvironmentTables"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:UpdateTable",
      "dynamodb:UpdateTimeToLive",
    ]
    resources = [local.scoped.dynamodb]
  }

  # Bucket configuration. The state bucket is <prefix>-tfstate-*, outside
  # <prefix>-demo-*, so none of this reaches it.
  statement {
    sid    = "ManageEnvironmentBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
    ]
    resources = [local.scoped.bucket]
  }

  # Only for `destroy` when allow_data_destruction lets Terraform empty a
  # versioned bucket (force_destroy). Object calls are data events, which is
  # why the October CloudTrail history could not show them.
  statement {
    sid       = "EmptyEnvironmentBucketsOnDestroy"
    effect    = "Allow"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = [local.scoped.objects]
  }
}

resource "aws_iam_policy" "apply_data" {
  name        = "${var.resource_prefix}-ci-apply-${var.deploy_environment}-data"
  description = "PyroSense CI: manage ${local.scope} keys, queues, topics, tables and buckets (ADR-0023)."
  policy      = data.aws_iam_policy_document.apply_data.json
}

# -----------------------------------------------------------------------------
# Apply, compute and edge: Lambda, Logs, CloudWatch, IoT.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "apply_infra" {
  statement {
    sid    = "ManageEnvironmentFunctions"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
    ]
    resources = [local.scoped.lambda]
  }

  # An event source mapping gets its ARN (a random UUID) only after it is
  # created, so it is scoped by the function it invokes instead.
  statement {
    sid    = "ManageEnvironmentEventSources"
    effect = "Allow"
    actions = [
      "lambda:CreateEventSourceMapping",
      "lambda:DeleteEventSourceMapping",
      "lambda:UpdateEventSourceMapping",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "lambda:FunctionArn"
      values   = [local.scoped.lambda]
    }
  }

  # AssociateKmsKey: creating a log group with a CMK (kms_key_id).
  statement {
    sid    = "ManageEnvironmentLogGroups"
    effect = "Allow"
    actions = [
      "logs:AssociateKmsKey",
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DeleteMetricFilter",
      "logs:DeleteRetentionPolicy",
      "logs:DisassociateKmsKey",
      "logs:PutMetricFilter",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
    ]
    resources = [local.scoped.log_groups]
  }

  statement {
    sid    = "ManageEnvironmentAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DeleteDashboards",
      "cloudwatch:PutDashboard",
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
    ]
    resources = [local.scoped.alarms, local.scoped.dashboards]
  }

  statement {
    sid    = "ManageEnvironmentIot"
    effect = "Allow"
    actions = [
      "iot:CreatePolicy",
      "iot:CreatePolicyVersion",
      "iot:CreateThing",
      "iot:CreateTopicRule",
      "iot:DeletePolicy",
      "iot:DeletePolicyVersion",
      "iot:DeleteThing",
      "iot:DeleteTopicRule",
      "iot:ReplaceTopicRule",
      "iot:TagResource",
      "iot:UntagResource",
      "iot:UpdateThing",
    ]
    resources = [local.scoped.iot_thing, local.scoped.iot_policy, local.scoped.iot_rule]
  }

  # Certificates are named by a random id and cannot carry tags through
  # Terraform (aws_iot_certificate has no tags argument), so they are scoped
  # to the account and region only. Accepted (ADR-0023): every certificate
  # in this account belongs to PyroSense, and the residual risk is limited to
  # attaching or deactivating certificates, not issuing credentials for
  # another identity.
  statement {
    sid    = "ManageFleetCertificates"
    effect = "Allow"
    actions = [
      "iot:AttachPolicy",
      "iot:AttachThingPrincipal",
      "iot:CreateCertificateFromCsr",
      "iot:DeleteCertificate",
      "iot:DetachPolicy",
      "iot:DetachThingPrincipal",
      "iot:UpdateCertificate",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "apply_infra" {
  name        = "${var.resource_prefix}-ci-apply-${var.deploy_environment}-infra"
  description = "PyroSense CI: manage ${local.scope} functions, logs, alarms and IoT resources (ADR-0023)."
  policy      = data.aws_iam_policy_document.apply_infra.json
}

# -----------------------------------------------------------------------------
# Apply, IAM: the part that decides whether the pipeline can escalate.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "apply_iam" {
  # Create, edit and delete roles of this environment ONLY if they carry the
  # workload boundary. iam:PermissionsBoundary is evaluated on every action
  # listed: a role without the boundary, or with another one, cannot be
  # created, and its policies cannot be written or deleted.
  statement {
    sid    = "ManageBoundedEnvironmentRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:PutRolePolicy",
    ]
    resources = [local.scoped.roles]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.workload_boundary.arn]
    }
  }

  # Not granted: iam:UpdateAssumeRolePolicy. It would let the pipeline point
  # an existing role's trust at any principal, another account included.
  # Roles are created fresh every cycle (ADR-0002), so a trust change is a
  # replace or an operator task, never an in-place pipeline update.

  # CreateRole with tags (default_tags) also needs iam:TagRole.
  statement {
    sid       = "TagEnvironmentRoles"
    effect    = "Allow"
    actions   = ["iam:TagRole", "iam:UntagRole", "iam:UpdateRoleDescription"]
    resources = [local.scoped.roles]
  }

  # Handing a role to a service. Only to the two services that use roles in
  # this project: Lambda (ingest execution role) and IoT (topic rule roles).
  statement {
    sid       = "PassEnvironmentRolesToLambdaAndIot"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.scoped.roles]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "iot.amazonaws.com"]
    }
  }

  # Explicit denies win over any allow, including one added by mistake later.
  # No permission above grants these; the denies make the intent reviewable.
  statement {
    sid    = "NeverRemoveOrReplaceABoundary"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["*"]
  }

  # Every IAM write on the pipeline's own roles, its policies (the boundary
  # included) and the identity provider. Reads stay allowed: plan reads the
  # boundary by name (data "aws_iam_policy" in the main configuration).
  statement {
    sid    = "ProtectPipelineIdentity"
    effect = "Deny"
    actions = [
      "iam:Add*",
      "iam:Attach*",
      "iam:Create*",
      "iam:Delete*",
      "iam:Detach*",
      "iam:PassRole",
      "iam:Put*",
      "iam:Remove*",
      "iam:Set*",
      "iam:Tag*",
      "iam:Untag*",
      "iam:Update*",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/${var.resource_prefix}-ci-*",
      "arn:${local.partition}:iam::${local.account_id}:policy/${var.resource_prefix}-*",
      aws_iam_openid_connect_provider.github.arn,
    ]
  }
}

resource "aws_iam_policy" "apply_iam" {
  name        = "${var.resource_prefix}-ci-apply-${var.deploy_environment}-iam"
  description = "PyroSense CI: manage ${local.scope} roles that carry the workload boundary (ADR-0023)."
  policy      = data.aws_iam_policy_document.apply_iam.json
}
