# -----------------------------------------------------------------------------
# Workload permissions boundary
#
# The problem it solves: the apply role must create IAM roles (the IoT rule
# roles and the Lambda execution role) and write their inline policies. Any
# identity that can write an inline policy can write "Action": "*", and with
# iam:PassRole it can hand that role to a Lambda function it also creates.
# Restricting role NAMES does not help: pyrosense-demo-anything is a valid
# name. Without a boundary, "can deploy PyroSense" means "can become admin".
#
# A permissions boundary is a ceiling. A role's effective permissions are the
# INTERSECTION of its own policies and its boundary:
#
#   inline policy "Action": "*"   ∩   this boundary   =   this boundary
#
# The apply role may only create or edit roles that carry this exact
# boundary (iam:PermissionsBoundary in permissions.tf), and it can never
# change the boundary. So the most any role it creates can ever do is listed
# below: the data path of the pipeline, in the project's own resources.
#
# It is not a second copy of the modules' policies. Each module still grants
# exactly what its role needs, scoped to one queue, one table, one key; the
# boundary only caps what a role created by the pipeline could ever reach.
# It covers both environments (<prefix>-*): the cap is the same for demo
# and prod, so it is defined once.
#
# Changing it is an operator apply of this stack. A module that starts using
# a new action fails at runtime with AccessDenied until the action is added
# here: that is the intended friction (ADR-0023).
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "workload_boundary" {
  # modules/iot forward role (producer contract of modules/messaging) and
  # modules/ingest execution role (consumer contract).
  statement {
    sid    = "ProjectQueues"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = ["arn:${local.partition}:sqs:${local.region}:${local.account_id}:${var.resource_prefix}-*"]
  }

  # Lambda logs and the IoT rule error log group. "*" inside an ARN pattern
  # also matches "/", so /aws/*/<prefix>-* covers /aws/lambda/<prefix>-demo-
  # ingest and /aws/iot/<prefix>-demo/topic-rule-errors, plus their streams.
  statement {
    sid    = "ProjectLogStreams"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/*/${var.resource_prefix}-*"]
  }

  statement {
    sid       = "ProjectHotStore"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = ["arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table/${var.resource_prefix}-*"]
  }

  statement {
    sid       = "ProjectColdStore"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["arn:${local.partition}:s3:::${var.resource_prefix}-*/*"]
  }

  statement {
    sid       = "ProjectAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = ["arn:${local.partition}:sns:${local.region}:${local.account_id}:${var.resource_prefix}-*"]
  }

  # The pipeline CMK has no stable ARN (a new key id every cycle, ADR-0002),
  # so the cap is "keys of this account and region"; the modules narrow it to
  # one key and to one calling service each (kms:ViaService).
  statement {
    sid    = "ProjectKeyUse"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["arn:${local.partition}:kms:${local.region}:${local.account_id}:key/*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = local.boundary_name
  description = "Ceiling for every IAM role the PyroSense pipeline creates (ADR-0023). Never attach it as a permissions policy."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}
